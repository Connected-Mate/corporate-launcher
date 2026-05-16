# tpl: shared module — extract corporate root CAs from OS trust store
# tpl: Sourced from install.sh.tpl when ${CA_DETECT_AUTO}=yes.
# tpl: NOT executed standalone — no shebang, no set -e. Caller controls flow.
#
# Exports:
#   CA_BUNDLE_PATH   absolute path to the concatenated PEM bundle
#
# Functions:
#   extract_corp_ca       — detect OS, dump root CAs, filter, write bundle
#   check_ca_freshness    — warn if the bundle is older than 90 days

# tpl: Heuristic patterns matching common TLS-inspection / corporate CA issuers.
# tpl: Extend via ${CA_FILTER_EXTRA} (space-separated additional patterns).
_CORP_CA_PATTERNS="Zscaler Bluecoat Blue Coat Netskope Forcepoint Symantec Proxy MITM Palo Alto Cisco Umbrella Fortinet McAfee Trend Micro Sophos Check Point Trustwave Imperva ${CORP_NAME} ${CORP_CA_ORG}"

# tpl: Filter a multi-PEM stream on stdin, keep only blocks whose Subject CN /
# tpl: Issuer matches one of the patterns. Writes filtered PEM to stdout.
# tpl: If no pattern matches at all, falls back to passing the input through
# tpl: (better to ship the full system bundle than an empty file).
_filter_corp_ca() {
    local tmp_in tmp_out kept=0 total=0
    tmp_in=$(mktemp -t corpca-in.XXXXXX) || return 1
    tmp_out=$(mktemp -t corpca-out.XXXXXX) || { rm -f "$tmp_in"; return 1; }
    cat > "$tmp_in"

    # tpl: Split into individual cert files via awk, then grep each one's
    # tpl: human-readable form (openssl x509 -noout -subject -issuer).
    local certdir
    certdir=$(mktemp -d -t corpca-split.XXXXXX) || {
        rm -f "$tmp_in" "$tmp_out"; return 1;
    }

    awk 'BEGIN{n=0;out=""} \
         /-----BEGIN CERTIFICATE-----/{n++; out=sprintf("'"$certdir"'/c%04d.pem", n)} \
         {if (out!="") print >> out} \
         /-----END CERTIFICATE-----/{out=""}' "$tmp_in"

    local patterns_re
    patterns_re=$(printf '%s\n' $_CORP_CA_PATTERNS ${CA_FILTER_EXTRA} \
                  | sed 's/[][\\.*^$/]/\\&/g' \
                  | tr '\n' '|' | sed 's/|$//')

    local f info
    for f in "$certdir"/*.pem; do
        [ -r "$f" ] || continue
        total=$((total + 1))
        info=$(openssl x509 -in "$f" -noout -subject -issuer 2>/dev/null) || continue
        if [ -z "$patterns_re" ] || printf '%s' "$info" | grep -Eqi "$patterns_re"; then
            cat "$f" >> "$tmp_out"
            kept=$((kept + 1))
        fi
    done

    # tpl: Fallback: no match -> ship the full input so TLS doesn't break
    if [ "$kept" -eq 0 ] && [ "$total" -gt 0 ]; then
        cp "$tmp_in" "$tmp_out"
        kept="$total"
    fi

    cat "$tmp_out"
    rm -rf "$certdir" "$tmp_in" "$tmp_out"

    # tpl: Communicate kept count to caller via env (subshell-safe via file).
    printf '%s' "$kept" > "${_CORP_CA_COUNT_FILE:-/dev/null}" 2>/dev/null || true
    return 0
}

extract_corp_ca() {
    # 1. Determine output path
    local out="${CA_BUNDLE_PATH:-${INSTALL_DIR}/corp-ca-bundle.pem}"
    local outdir
    outdir=$(dirname "$out")
    mkdir -p "$outdir" 2>/dev/null || {
        echo "extract_corp_ca: cannot create $outdir" >&2
        return 1
    }

    local raw
    raw=$(mktemp -t corpca-raw.XXXXXX) || return 1

    # 2. Detect OS and dump trust store(s) into $raw
    local uname_s
    uname_s=$(uname -s 2>/dev/null || echo unknown)
    local is_wsl=0
    if [ -r /proc/version ] && grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
        is_wsl=1
    fi

    case "$uname_s" in
        Darwin)
            security find-certificate -a -p \
                /System/Library/Keychains/SystemRootCertificates.keychain \
                >> "$raw" 2>/dev/null || true
            security find-certificate -a -p \
                /Library/Keychains/System.keychain \
                >> "$raw" 2>/dev/null || true
            # tpl: User keychain may carry MDM-pushed corp CAs
            security find-certificate -a -p \
                "$\{HOME\}/Library/Keychains/login.keychain-db" \
                >> "$raw" 2>/dev/null || true
            ;;
        Linux)
            # Debian / Ubuntu / Arch
            if [ -r /etc/ssl/certs/ca-certificates.crt ]; then
                cat /etc/ssl/certs/ca-certificates.crt >> "$raw" 2>/dev/null || true
            fi
            # RHEL / Fedora / CentOS — anchors dir (PEM files)
            if [ -d /etc/pki/ca-trust/source/anchors ]; then
                local af
                for af in /etc/pki/ca-trust/source/anchors/*.crt \
                          /etc/pki/ca-trust/source/anchors/*.pem; do
                    [ -r "$af" ] && cat "$af" >> "$raw" 2>/dev/null
                done
            fi
            # RHEL / Fedora — consolidated bundle
            if [ -r /etc/pki/tls/certs/ca-bundle.crt ]; then
                cat /etc/pki/tls/certs/ca-bundle.crt >> "$raw" 2>/dev/null || true
            fi
            # SUSE
            if [ -r /var/lib/ca-certificates/ca-bundle.pem ]; then
                cat /var/lib/ca-certificates/ca-bundle.pem >> "$raw" 2>/dev/null || true
            fi

            # WSL — also pull from the Windows host store via certutil
            if [ "$is_wsl" -eq 1 ]; then
                local wcertutil="/mnt/c/Windows/System32/certutil.exe"
                if [ -x "$wcertutil" ]; then
                    local wintmp
                    wintmp=$(mktemp -t corpca-win.XXXXXX)
                    # tpl: certutil -store Root dumps the LocalMachine root store
                    "$wcertutil" -store Root 2>/dev/null \
                        | tr -d '\r' > "$wintmp" || true
                    # Convert any BEGIN/END blocks present
                    grep -E -A1000 '^-----BEGIN CERTIFICATE-----' "$wintmp" \
                        >> "$raw" 2>/dev/null || true
                    rm -f "$wintmp"
                fi
                # Best-effort: enterprise store exported by IT
                if [ -r "/mnt/c/ProgramData/${CORP_SLUG}/corp-ca.pem" ]; then
                    cat "/mnt/c/ProgramData/${CORP_SLUG}/corp-ca.pem" \
                        >> "$raw" 2>/dev/null || true
                fi
            fi
            ;;
        *)
            echo "extract_corp_ca: unsupported OS: $uname_s" >&2
            rm -f "$raw"
            return 1
            ;;
    esac

    if [ ! -s "$raw" ]; then
        echo "extract_corp_ca: no certificates found in OS trust store" >&2
        rm -f "$raw"
        return 1
    fi

    # 3. Filter for likely corp CAs
    local count_file
    count_file=$(mktemp -t corpca-cnt.XXXXXX)
    _CORP_CA_COUNT_FILE="$count_file" _filter_corp_ca < "$raw" > "$out"
    local kept=0
    [ -r "$count_file" ] && kept=$(cat "$count_file" 2>/dev/null || echo 0)
    rm -f "$raw" "$count_file"

    # 4. Validate: must be parseable PEM, must be non-empty
    if [ ! -s "$out" ]; then
        echo "extract_corp_ca: WARNING — bundle is empty ($out)" >&2
        return 1
    fi
    if command -v openssl >/dev/null 2>&1; then
        if ! openssl x509 -in "$out" -noout 2>/dev/null; then
            # tpl: openssl x509 reads only the first cert; do a fuller probe
            if ! openssl crl2pkcs7 -nocrl -certfile "$out" 2>/dev/null \
                  | openssl pkcs7 -print_certs -noout 2>/dev/null \
                  | grep -q subject; then
                echo "extract_corp_ca: WARNING — bundle does not parse as PEM" >&2
            fi
        fi
    fi

    # 5. Permissions: world-readable so Node / Python / Codex can read it
    chmod 644 "$out" 2>/dev/null || true

    # 6. Export
    export CA_BUNDLE_PATH="$out"

    # 7. Report
    echo "Extracted ${kept} corporate root CAs to $out"
    return 0
}

check_ca_freshness() {
    local bundle="${1:-${CA_BUNDLE_PATH}}"
    [ -n "$bundle" ] && [ -r "$bundle" ] || return 0

    local now mtime age_days
    now=$(date +%s 2>/dev/null) || return 0

    case "$(uname -s 2>/dev/null)" in
        Darwin|*BSD)
            mtime=$(stat -f %m "$bundle" 2>/dev/null)
            ;;
        *)
            mtime=$(stat -c %Y "$bundle" 2>/dev/null)
            ;;
    esac
    [ -n "$mtime" ] || return 0

    age_days=$(( (now - mtime) / 86400 ))
    if [ "$age_days" -gt 90 ]; then
        echo "check_ca_freshness: WARNING — CA bundle is ${age_days} days old (${bundle})." >&2
        echo "  Corporate CAs may have rotated. Refresh with: ${CORP_SLUG} --refresh-ca" >&2
        return 1
    fi
    return 0
}
