#!/usr/bin/env node
// =============================================================================
// ${CORP_NAME} — Strip Proxy v2
//
// HTTP middleware between Claude Code CLI and the corporate gateway.
// Handles ALL 4 known SSE/HTTP artefacts emitted by Bedrock / LiteLLM
// that crash the CLI parser or get rejected upstream:
//
//   1. Phantom empty text block: content_block_start with text:"" immediately
//      followed by content_block_stop. Both events dropped.
//   2. Post-message_stop events: any event after message_stop is suppressed
//      and the stream is closed cleanly.
//   3. anthropic-beta / x-anthropic-beta header: stripped from outgoing request
//      (some gateways HTTP-400 on unrecognised beta flags).
//   4. context_management body field: stripped from outgoing JSON body
//      (Bedrock rejects with "Extra inputs not permitted").
//
// Bonus over v1:
//   - Non-SSE upstream responses (HTML 5xx error pages, plain-text errors)
//     are converted to a proper JSON error envelope the CLI understands,
//     instead of being piped raw (which crashes the parser).
//   - Model auto-detection: scans every event for a "model" field, so usage
//     logged in message_delta still gets attributed to the right model.
//   - Multiple usage events: merges input_tokens (message_start) with
//     output_tokens (message_delta) before final logging.
//   - Optional session_id from ${CORP_SLUG_UPPER}_SESSION_ID env var, recorded
//     in usage log so cost-tracker.py can filter "current session".
//   - Hardened against malformed JSON bodies, partial chunks, client aborts.
//
// Env vars:
//   STRIP_PROXY_PORT       default 9876
//   STRIP_PROXY_UPSTREAM   default ${CC_PRIMARY_URL}
//   STRIP_PROXY_VERBOSE    1 for per-event logs
//   STRIP_PROXY_USAGE_LOG  default /tmp/${CORP_SLUG}-usage.jsonl
//   ${CORP_SLUG_UPPER}_SESSION_ID  optional, tags each entry for session reports
// =============================================================================

const http = require('http');
const https = require('https');
const fs = require('fs');
const { URL } = require('url');

// tpl: strippable — runtime configuration
const PORT = parseInt(process.env.STRIP_PROXY_PORT || '9876', 10);
const UPSTREAM = new URL(process.env.STRIP_PROXY_UPSTREAM || '${CC_PRIMARY_URL}');
const VERBOSE = process.env.STRIP_PROXY_VERBOSE === '1';
const USAGE_LOG = process.env.STRIP_PROXY_USAGE_LOG || '/tmp/${CORP_SLUG}-usage.jsonl';
const SESSION = process.env['${CORP_SLUG_UPPER}_SESSION_ID'] || null;

// tpl: pricing table — edit to match your gateway's contracted rates
// Format mirrors cost-tracker.py.tpl: per 1M tokens, in ${COST_CURRENCY}
const PRICING = {
    '${CC_PRIMARY_MODEL}': { input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25 },
    '${CC_HAIKU_MODEL}':   { input: 1.0, output:  5.0, cache_read: 0.1, cache_write: 1.25 },
};

// tpl: SSE event detection
const STOP_RE             = /"type"\s*:\s*"message_stop"/;
const EMPTY_TEXT_START_RE = /"type"\s*:\s*"content_block_start"[\s\S]*?"content_block"\s*:\s*\{\s*"type"\s*:\s*"text"\s*,\s*"text"\s*:\s*""\s*\}/;
const BLOCK_STOP_RE       = /"type"\s*:\s*"content_block_stop"/;
const MODEL_RE            = /"model"\s*:\s*"([^"]+)"/;
const USAGE_RE            = /"usage"\s*:\s*(\{[^{}]*\})/;

function vlog(...args) { if (VERBOSE) console.error('[strip]', ...args); }

// -----------------------------------------------------------------------------
// Pricing helpers (artefact #N/A — for usage logging)
// -----------------------------------------------------------------------------
function priceFor(model) {
    if (!model) return null;
    if (PRICING[model]) return PRICING[model];
    // tpl: fuzzy match — gateway may prefix with region / version (e.g. eu.anthropic...)
    for (const k of Object.keys(PRICING)) {
        if (model.includes(k) || k.includes(model)) return PRICING[k];
    }
    return null;
}

function costOf(usage, model) {
    const p = priceFor(model);
    if (!p) return null;
    const i  = usage.input_tokens                || 0;
    const o  = usage.output_tokens               || 0;
    const cr = usage.cache_read_input_tokens     || 0;
    const cw = usage.cache_creation_input_tokens || 0;
    return (i / 1e6) * p.input
         + (o / 1e6) * p.output
         + (cr / 1e6) * p.cache_read
         + (cw / 1e6) * p.cache_write;
}

function logUsage(model, usage) {
    if (!model || !usage) return;
    const entry = {
        ts:      new Date().toISOString(),
        session: SESSION,
        model:   model,
        usage:   usage,
        cost:    costOf(usage, model),
    };
    try {
        fs.appendFileSync(USAGE_LOG, JSON.stringify(entry) + '\n');
    } catch (err) {
        vlog('failed to append usage log:', err.message);
    }
}

// -----------------------------------------------------------------------------
// Artefact #4: strip context_management from outgoing body
// -----------------------------------------------------------------------------
function sanitizeRequestBody(buf) {
    if (!buf || buf.length === 0) return buf;
    let body;
    try {
        body = JSON.parse(buf.toString('utf-8'));
    } catch (_) {
        // tpl: non-JSON body — leave it alone (could be multipart, etc.)
        return buf;
    }
    let mutated = false;
    if ('context_management' in body) {
        delete body.context_management;
        mutated = true;
        vlog('stripped context_management from request body');
    }
    // tpl: defensive — strip from nested system messages too if seen there
    if (Array.isArray(body.system)) {
        for (const blk of body.system) {
            if (blk && typeof blk === 'object' && 'context_management' in blk) {
                delete blk.context_management;
                mutated = true;
            }
        }
    }
    return mutated ? Buffer.from(JSON.stringify(body)) : buf;
}

// -----------------------------------------------------------------------------
// Artefact #3: strip anthropic-beta headers from outgoing request
// -----------------------------------------------------------------------------
function sanitizeRequestHeaders(headers) {
    const out = {};
    for (const [k, v] of Object.entries(headers)) {
        const lk = k.toLowerCase();
        // tpl: header blacklist — gateways HTTP-400 on unrecognised betas
        if (lk === 'anthropic-beta')   { vlog('stripped header anthropic-beta');   continue; }
        if (lk === 'x-anthropic-beta') { vlog('stripped header x-anthropic-beta'); continue; }
        if (lk === 'accept-encoding')  continue;  // tpl: we want plain SSE, no gzip
        if (lk === 'host')             continue;  // tpl: rewritten below
        if (lk === 'content-length')   continue;  // tpl: recomputed after body mutation
        out[k] = v;
    }
    out['host'] = UPSTREAM.host;
    return out;
}

// -----------------------------------------------------------------------------
// Non-SSE upstream response → JSON error envelope (bonus over v1)
// -----------------------------------------------------------------------------
function pipeNonSseAsError(upstreamRes, clientRes, requestedSse) {
    const chunks = [];
    upstreamRes.on('data', c => chunks.push(c));
    upstreamRes.on('end', () => {
        const raw = Buffer.concat(chunks).toString('utf-8');
        const status = upstreamRes.statusCode || 502;
        // tpl: if the client did not ask for SSE, just forward as-is
        if (!requestedSse) {
            clientRes.writeHead(status, upstreamRes.headers);
            clientRes.end(raw);
            return;
        }
        // tpl: client expected SSE but got HTML/text — synthesise a JSON error
        vlog(`non-SSE upstream (status=${status}, ctype=${upstreamRes.headers['content-type']}) — converting to JSON error`);
        const snippet = raw.slice(0, 500).replace(/\s+/g, ' ').trim();
        const envelope = {
            type: 'error',
            error: {
                type: 'strip_proxy_non_sse_upstream',
                status: status,
                message: `Upstream returned non-SSE response (status ${status}): ${snippet}`,
            },
        };
        clientRes.writeHead(status >= 400 ? status : 502, {
            'content-type': 'application/json',
        });
        clientRes.end(JSON.stringify(envelope));
    });
    upstreamRes.on('error', err => {
        if (!clientRes.headersSent) {
            clientRes.writeHead(502, { 'content-type': 'application/json' });
        }
        clientRes.end(JSON.stringify({
            type: 'error',
            error: { type: 'strip_proxy_upstream_read_error', message: err.message },
        }));
    });
}

// -----------------------------------------------------------------------------
// Artefacts #1 & #2: SSE cleaner
// -----------------------------------------------------------------------------
function pipeSseClean(upstreamRes, clientRes) {
    upstreamRes.setEncoding('utf-8');
    let stopped = false;
    let model = null;
    let usage = {};
    let buf = '';
    let pendingEmptyStart = null;  // tpl: holds a content_block_start with text:"" pending pair check

    const flushPending = () => {
        if (pendingEmptyStart) {
            clientRes.write(pendingEmptyStart);
            pendingEmptyStart = null;
        }
    };

    const finalize = () => {
        if (stopped) return;
        stopped = true;
        flushPending();
        if (Object.keys(usage).length > 0) logUsage(model, usage);
        try { clientRes.end(); } catch (_) {}
        try { upstreamRes.destroy(); } catch (_) {}
    };

    upstreamRes.on('data', chunk => {
        if (stopped) return;
        buf += chunk;

        // tpl: SSE events terminated by a blank line
        let idx;
        while ((idx = buf.indexOf('\n\n')) !== -1) {
            const event = buf.slice(0, idx + 2);
            buf = buf.slice(idx + 2);

            // tpl: artefact #1 — phantom empty text block (two-event pattern)
            if (EMPTY_TEXT_START_RE.test(event)) {
                // tpl: hold the start; if next event is content_block_stop, drop both
                pendingEmptyStart = event;
                vlog('holding phantom empty content_block_start');
                continue;
            }
            if (pendingEmptyStart && BLOCK_STOP_RE.test(event)) {
                // tpl: matched pair — drop both
                vlog('dropped phantom empty content_block pair');
                pendingEmptyStart = null;
                continue;
            }
            // tpl: pending start without matching stop — flush it (be conservative)
            flushPending();

            // tpl: capture model + merge usage across events (message_start + message_delta)
            const mModel = event.match(MODEL_RE);
            if (mModel) model = mModel[1];
            const mUsage = event.match(USAGE_RE);
            if (mUsage) {
                try {
                    const u = JSON.parse(mUsage[1]);
                    for (const k of Object.keys(u)) {
                        if (typeof u[k] === 'number') usage[k] = u[k];  // tpl: latest wins
                    }
                } catch (_) { /* tpl: malformed usage — skip */ }
            }

            clientRes.write(event);

            // tpl: artefact #2 — end stream immediately on message_stop
            if (STOP_RE.test(event)) {
                vlog('message_stop — closing stream, ignoring any further events');
                finalize();
                return;
            }
        }
    });

    upstreamRes.on('end', () => {
        if (stopped) return;
        flushPending();
        if (buf.length > 0) clientRes.write(buf);
        if (Object.keys(usage).length > 0) logUsage(model, usage);
        stopped = true;
        try { clientRes.end(); } catch (_) {}
    });

    upstreamRes.on('error', err => {
        console.error('[strip] upstream stream error:', err.message);
        if (!stopped) {
            stopped = true;
            try { clientRes.end(); } catch (_) {}
        }
    });

    clientRes.on('close', () => {
        // tpl: client hung up — abort upstream so we don't waste tokens
        if (!stopped) {
            vlog('client closed — aborting upstream');
            stopped = true;
            try { upstreamRes.destroy(); } catch (_) {}
        }
    });
}

// -----------------------------------------------------------------------------
// HTTP server entry point
// -----------------------------------------------------------------------------
const server = http.createServer((clientReq, clientRes) => {
    const chunks = [];
    clientReq.on('data', c => chunks.push(c));
    clientReq.on('error', err => {
        console.error('[strip] client request error:', err.message);
    });
    clientReq.on('end', () => {
        const rawBody = Buffer.concat(chunks);
        const body = sanitizeRequestBody(rawBody);
        const headers = sanitizeRequestHeaders(clientReq.headers);
        if (body && body.length > 0) headers['content-length'] = String(body.length);

        const requestedSse = (clientReq.headers['accept'] || '').includes('text/event-stream');

        const upstreamReq = https.request({
            hostname: UPSTREAM.hostname,
            port:     UPSTREAM.port || 443,
            path:     clientReq.url,
            method:   clientReq.method,
            headers:  headers,
        }, upstreamRes => {
            const ctype = (upstreamRes.headers['content-type'] || '').toLowerCase();
            const isSse = ctype.includes('text/event-stream');

            if (isSse) {
                clientRes.writeHead(upstreamRes.statusCode, upstreamRes.headers);
                pipeSseClean(upstreamRes, clientRes);
            } else {
                // tpl: bonus — non-SSE upstream (HTML 5xx, plain error) → JSON envelope
                pipeNonSseAsError(upstreamRes, clientRes, requestedSse);
            }
        });

        upstreamReq.on('error', err => {
            console.error('[strip] request error:', err.message);
            if (clientRes.headersSent) {
                try { clientRes.end(); } catch (_) {}
                return;
            }
            clientRes.writeHead(502, { 'content-type': 'application/json' });
            clientRes.end(JSON.stringify({
                type: 'error',
                error: {
                    type: 'strip_proxy_upstream_error',
                    message: err.message,
                    upstream: UPSTREAM.href,
                },
            }));
        });

        if (body && body.length > 0) upstreamReq.write(body);
        upstreamReq.end();
    });
});

server.on('clientError', (err, socket) => {
    // tpl: malformed client HTTP — respond cleanly instead of crashing
    try {
        socket.end('HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n\r\n'
            + JSON.stringify({ type: 'error', error: { type: 'strip_proxy_bad_client_request', message: err.message }}));
    } catch (_) { /* socket already gone */ }
});

server.listen(PORT, '127.0.0.1', () => {
    console.error(`[${CORP_NAME} strip-proxy v2] listening on http://127.0.0.1:$\{PORT\} -> ${UPSTREAM.href}`);
    if (VERBOSE) console.error('[strip] verbose mode ON');
    if (SESSION) console.error(`[strip] session=$\{SESSION\}`);
});
