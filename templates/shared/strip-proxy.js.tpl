#!/usr/bin/env node
// =============================================================================
// ${CORP_NAME} — Strip Proxy
//
// HTTP middleware placed between the Claude Code CLI and the corporate gateway.
// Cleans 4 known SSE artefacts emitted by Bedrock / LiteLLM that crash the CLI
// parser with "Content block is not a text block":
//
//   1. Phantom empty text block: content_block_start with text:"" + immediate
//      content_block_stop. Drop both.
//   2. Events emitted after message_stop: ignored.
//   3. anthropic-beta header rejected by some gateways: stripped from request.
//   4. context_management body field rejected by Bedrock: stripped from request.
//
// Also records per-request usage to /tmp/${CORP_SLUG}-usage.jsonl for the
// cost tracker.
//
// Env vars:
//   STRIP_PROXY_PORT       default 9876
//   STRIP_PROXY_UPSTREAM   default ${CC_PRIMARY_URL}
//   STRIP_PROXY_VERBOSE    1 for per-event logs
//   STRIP_PROXY_USAGE_LOG  default /tmp/${CORP_SLUG}-usage.jsonl
// =============================================================================

const http = require('http');
const https = require('https');
const fs = require('fs');
const { URL } = require('url');

const PORT = parseInt(process.env.STRIP_PROXY_PORT || '9876', 10);
const UPSTREAM = new URL(process.env.STRIP_PROXY_UPSTREAM || '${CC_PRIMARY_URL}');
const VERBOSE = process.env.STRIP_PROXY_VERBOSE === '1';
const USAGE_LOG = process.env.STRIP_PROXY_USAGE_LOG || '/tmp/${CORP_SLUG}-usage.jsonl';

// tpl: pricing table — edit to match your gateway's contracted rates
const PRICING = {
    // model_id: { input, output, cache_read, cache_write }  per 1M tokens, in ${COST_CURRENCY}
    '${CC_PRIMARY_MODEL}': { input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25 },
    '${CC_HAIKU_MODEL}':   { input: 1.0, output:  5.0, cache_read: 0.1, cache_write: 1.25 },
};

const STOP_RE = /"type"\s*:\s*"message_stop"/;
const EMPTY_TEXT_START_RE = /"type"\s*:\s*"content_block_start"[\s\S]*?"content_block"\s*:\s*\{\s*"type"\s*:\s*"text"\s*,\s*"text"\s*:\s*""\s*\}/;

function priceFor(model) {
    if (!model) return null;
    if (PRICING[model]) return PRICING[model];
    for (const k of Object.keys(PRICING)) if (model.includes(k)) return PRICING[k];
    return null;
}

function costOf(usage, model) {
    const p = priceFor(model);
    if (!p) return null;
    const i = usage.input_tokens || 0;
    const o = usage.output_tokens || 0;
    const cr = usage.cache_read_input_tokens || 0;
    const cw = usage.cache_creation_input_tokens || 0;
    return (i/1e6)*p.input + (o/1e6)*p.output + (cr/1e6)*p.cache_read + (cw/1e6)*p.cache_write;
}

function logUsage(model, usage) {
    if (!model || !usage) return;
    const entry = {
        ts:    new Date().toISOString(),
        model: model,
        usage: usage,
        cost:  costOf(usage, model),
    };
    try {
        fs.appendFileSync(USAGE_LOG, JSON.stringify(entry) + '\n');
    } catch (_) { /* non-fatal */ }
}

function sanitizeRequestBody(buf) {
    try {
        const body = JSON.parse(buf.toString('utf-8'));
        // tpl: strip Bedrock-rejected fields
        delete body.context_management;
        return Buffer.from(JSON.stringify(body));
    } catch (_) {
        return buf;
    }
}

function sanitizeRequestHeaders(headers) {
    const out = { ...headers };
    // tpl: strip headers some gateways reject
    delete out['anthropic-beta'];
    delete out['x-anthropic-beta'];
    out['host'] = UPSTREAM.host;
    delete out['accept-encoding'];
    return out;
}

function pipeSseClean(upstreamRes, clientRes) {
    upstreamRes.setEncoding('utf-8');
    let stopped = false;
    let model = null;
    let usage = null;
    let buf = '';

    upstreamRes.on('data', chunk => {
        if (stopped) return;
        buf += chunk;

        // tpl: split on SSE event boundary (blank line)
        let idx;
        while ((idx = buf.indexOf('\n\n')) !== -1) {
            const event = buf.slice(0, idx + 2);
            buf = buf.slice(idx + 2);

            // tpl: drop phantom empty text block events
            if (EMPTY_TEXT_START_RE.test(event)) {
                if (VERBOSE) console.error('[strip] dropped phantom empty content_block');
                continue;
            }

            // tpl: capture model + usage for cost tracking
            const mModel = event.match(/"model"\s*:\s*"([^"]+)"/);
            if (mModel) model = mModel[1];
            const mUsage = event.match(/"usage"\s*:\s*(\{[^}]+\})/);
            if (mUsage) { try { usage = JSON.parse(mUsage[1]); } catch (_) {} }

            clientRes.write(event);

            if (STOP_RE.test(event)) {
                stopped = true;
                if (VERBOSE) console.error('[strip] message_stop — closing stream');
                logUsage(model, usage);
                clientRes.end();
                upstreamRes.destroy();
                return;
            }
        }
    });

    upstreamRes.on('end', () => {
        if (!stopped) {
            if (buf) clientRes.write(buf);
            clientRes.end();
            logUsage(model, usage);
        }
    });
    upstreamRes.on('error', err => {
        if (!stopped) clientRes.end();
        console.error('[strip] upstream error', err.message);
    });
}

const server = http.createServer((clientReq, clientRes) => {
    const chunks = [];
    clientReq.on('data', c => chunks.push(c));
    clientReq.on('end', () => {
        const body = sanitizeRequestBody(Buffer.concat(chunks));
        const headers = sanitizeRequestHeaders(clientReq.headers);
        headers['content-length'] = body.length;

        const upstreamReq = https.request({
            hostname: UPSTREAM.hostname,
            port: UPSTREAM.port || 443,
            path: clientReq.url,
            method: clientReq.method,
            headers: headers,
        }, upstreamRes => {
            clientRes.writeHead(upstreamRes.statusCode, upstreamRes.headers);
            const ctype = upstreamRes.headers['content-type'] || '';
            if (ctype.includes('text/event-stream')) {
                pipeSseClean(upstreamRes, clientRes);
            } else {
                upstreamRes.pipe(clientRes);
            }
        });

        upstreamReq.on('error', err => {
            console.error('[strip] request error', err.message);
            clientRes.writeHead(502, { 'content-type': 'application/json' });
            clientRes.end(JSON.stringify({ error: { type: 'strip_proxy_upstream_error', message: err.message }}));
        });

        upstreamReq.write(body);
        upstreamReq.end();
    });
});

server.listen(PORT, '127.0.0.1', () => {
    console.error(`[${CORP_NAME} strip-proxy] listening on http://127.0.0.1:${PORT} -> ${UPSTREAM.href}`);
});
