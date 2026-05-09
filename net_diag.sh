#!/usr/bin/env bash
# =============================================================
#  isp_diagnostic.sh — Comprehensive ISP Diagnostic Tool
#  Usage: bash isp_diagnostic.sh [ROUTER_IP]
#  Default router IP: 192.168.1.1
# =============================================================

ROUTER_IP="${1:-192.168.2.1}"
TEST_HOST="8.8.8.8"
TEST_HOST2="1.1.1.1"
TEST_HOST_IPV6="2001:4860:4860::8888"  # Google IPv6 DNS
DOWNLOAD_URL="http://speed.cloudflare.com/__down?bytes=10000000"  # 10MB test file

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_DIR="./isp_diagnostic_logs"
REPORT_FILE="${LOG_DIR}/isp_report_${TIMESTAMP}.txt"
mkdir -p "$LOG_DIR"

# ── Colors (terminal only, not in log) ─────────────────────────
if [ -t 1 ]; then
    RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

# ── Helpers ────────────────────────────────────────────────────
# log() writes plain text to both terminal and file (no color codes in file)
log()      { echo "$1" | tee -a "$REPORT_FILE"; }
log_raw()  { tee -a "$REPORT_FILE"; }
section()  { log ""; log ""; log "╔══════════════════════════════════════════════════════════════╗"; log "║  $1"; log "╚══════════════════════════════════════════════════════════════╝"; }
divider()  { log "  ────────────────────────────────────────────────────────────"; }
# ok/warn/fail/info: print color to terminal, plain text to file separately
ok()       { echo -e "  ${GREEN}✓${RESET} $1"; echo "  [OK]   $1" >> "$REPORT_FILE"; }
warn()     { echo -e "  ${YELLOW}⚠${RESET}  $1"; echo "  [WARN] $1" >> "$REPORT_FILE"; }
fail()     { echo -e "  ${RED}✗${RESET}  $1"; echo "  [FAIL] $1" >> "$REPORT_FILE"; }
info()     { echo -e "  ${CYAN}→${RESET}  $1"; echo "  [INFO] $1" >> "$REPORT_FILE"; }
skip()     { echo -e "  ${YELLOW}–${RESET}  $1 (tool not available, skipping)"; echo "  [SKIP] $1 (tool not available, skipping)" >> "$REPORT_FILE"; }

cmd_exists() { command -v "$1" &>/dev/null; }

# ── System Info ────────────────────────────────────────────────
OS_NAME=$(uname -s)
OS_KERNEL=$(uname -r)
OS_ARCH=$(uname -m)
if [ -f /etc/os-release ]; then
    OS_PRETTY=$(grep -m1 "^PRETTY_NAME=" /etc/os-release | cut -d= -f2 | tr -d '"')
elif [ "$OS_NAME" = "Darwin" ]; then
    OS_PRETTY="macOS $(sw_vers -productVersion)"
else
    OS_PRETTY="$OS_NAME"
fi
HOSTNAME_VAL=$(hostname)
RUN_DATE=$(date)

# ══════════════════════════════════════════════════════════════
#  REPORT HEADER
# ══════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}  ISP Diagnostic Tool — Starting...${RESET}"
echo -e "  Report will be saved to: ${CYAN}$REPORT_FILE${RESET}"
echo ""

log "╔══════════════════════════════════════════════════════════════════╗"
log "║         ISP COMPREHENSIVE DIAGNOSTIC REPORT                     ║"
log "╚══════════════════════════════════════════════════════════════════╝"
log ""
log "  Generated   : $RUN_DATE"
log "  Hostname    : $HOSTNAME_VAL"
log "  OS          : $OS_PRETTY"
log "  Kernel      : $OS_NAME $OS_KERNEL"
log "  Arch        : $OS_ARCH"
log "  Bash        : $BASH_VERSION"
log "  Router IP   : $ROUTER_IP"
log "  Test Target : $TEST_HOST (Google DNS), $TEST_HOST2 (Cloudflare DNS)"
log ""
log "  NOTE: This report is intended for ISP support/escalation use."
log "        All tests were run without VPN or proxy interference."

# ══════════════════════════════════════════════════════════════
#  TEST 1 — PACKET LOSS & LATENCY (Ping)
# ══════════════════════════════════════════════════════════════
section "TEST 1 — PACKET LOSS & LATENCY (Ping)"
log ""

run_ping_test() {
    local label="$1"
    local host="$2"
    local count=50
    info "Pinging $label ($host) with $count packets..."
    local out
    out=$(ping -c $count -W 3 "$host" 2>&1)
    local loss avg_ms
    loss=$(echo "$out" | grep -oE '[0-9]+(\.[0-9]+)?% packet loss' | grep -oE '^[0-9]+(\.[0-9]+)?')
    avg_ms=$(echo "$out" | awk -F'/' '/rtt|round-trip/{print $5}')
    loss=${loss:-100}
    avg_ms=${avg_ms:-N/A}
    loss_int=$(printf "%.0f" "$loss")
    log "  [$label] Packet Loss: ${loss}%  |  Avg Latency: ${avg_ms} ms"
    if [ "$loss_int" -ge 30 ]; then
        fail "CRITICAL packet loss to $label"
    elif [ "$loss_int" -ge 10 ]; then
        warn "Elevated packet loss to $label"
    else
        ok "Packet loss acceptable to $label"
    fi
    # Save raw output for evidence
    log ""; log "  Raw ping output ($label):"; echo "$out" | sed 's/^/    /' | tee -a "$REPORT_FILE"; log ""
}

run_ping_test "Router (local)"         "$ROUTER_IP"
run_ping_test "Google DNS (8.8.8.8)"   "$TEST_HOST"
run_ping_test "Cloudflare (1.1.1.1)"   "$TEST_HOST2"

# ══════════════════════════════════════════════════════════════
#  TEST 2 — JITTER MEASUREMENT
# ══════════════════════════════════════════════════════════════
section "TEST 2 — JITTER MEASUREMENT"
log ""
info "Measuring jitter to $TEST_HOST (20 pings, collecting RTT values)..."

ping_out=$(ping -c 20 -W 3 "$TEST_HOST" 2>&1)
rtts=$(echo "$ping_out" | grep "icmp_seq\|bytes from" | grep -oE 'time=[0-9.]+' | cut -d= -f2)

if [ -n "$rtts" ]; then
    jitter_result=$(echo "$rtts" | awk '
    BEGIN { min=999999; max=0; sum=0; n=0 }
    {
        val=$1+0; sum+=val; n++;
        if(val<min) min=val;
        if(val>max) max=val;
        vals[n]=val;
    }
    END {
        avg=sum/n;
        var=0;
        for(i=1;i<=n;i++) var+=(vals[i]-avg)^2;
        jitter=sqrt(var/n);
        printf "Min: %.2f ms | Max: %.2f ms | Avg: %.2f ms | Jitter (StdDev): %.2f ms", min, max, avg, jitter;
    }')
    log "  $jitter_result"
    jitter_val=$(echo "$jitter_result" | grep -oE 'Jitter.*: [0-9.]+' | grep -oE '[0-9.]+$')
    jitter_int=$(printf "%.0f" "${jitter_val:-0}")
    if [ "$jitter_int" -ge 30 ]; then
        fail "HIGH jitter — will cause severe call/streaming issues"
    elif [ "$jitter_int" -ge 10 ]; then
        warn "Moderate jitter — may affect voice/video quality"
    else
        ok "Jitter within acceptable range"
    fi
else
    fail "Could not reach $TEST_HOST for jitter test"
fi

# ══════════════════════════════════════════════════════════════
#  TEST 3 — TRACEROUTE (Hop-by-hop path analysis)
# ══════════════════════════════════════════════════════════════
section "TEST 3 — TRACEROUTE (Network Path Analysis)"
log ""
info "Tracing route to $TEST_HOST — this identifies WHERE loss occurs..."
log ""

if cmd_exists traceroute; then
    traceroute -m 20 -w 3 "$TEST_HOST" 2>&1 | tee -a "$REPORT_FILE"
elif cmd_exists tracepath; then
    tracepath "$TEST_HOST" 2>&1 | tee -a "$REPORT_FILE"
else
    skip "traceroute / tracepath"
fi

log ""
info "Tracing route to $TEST_HOST2 (Cloudflare)..."
log ""
if cmd_exists traceroute; then
    traceroute -m 20 -w 3 "$TEST_HOST2" 2>&1 | tee -a "$REPORT_FILE"
elif cmd_exists tracepath; then
    tracepath "$TEST_HOST2" 2>&1 | tee -a "$REPORT_FILE"
fi

# ══════════════════════════════════════════════════════════════
#  TEST 4 — DNS RESOLUTION SPEED
# ══════════════════════════════════════════════════════════════
section "TEST 4 — DNS RESOLUTION SPEED"
log ""

resolve_dns() {
    local label="$1"
    local server="$2"
    local domain="google.com"

    # Skip if no server IP was found (e.g. empty ISP DNS)
    if [ -z "$server" ]; then
        skip "DNS via $label — could not detect server IP"
        return
    fi

    local resolved=false

    # ── Try dig ───────────────────────────────────────────────
    if cmd_exists dig; then
        local result ms
        # -4 forces IPv4 transport; +stats needed for "Query time" line
        result=$(dig -4 @"$server" "$domain" +time=5 +tries=1 +stats 2>&1)
        ms=$(echo "$result" | grep -i "Query time" | grep -oE '[0-9]+ msec' | grep -oE '[0-9]+')

        if [ -n "$ms" ]; then
            log "  DNS via $label ($server): ${ms} ms"
            if [ "$ms" -gt 300 ]; then
                warn "Slow DNS from $label (${ms} ms)"
            else
                ok "DNS from $label OK (${ms} ms)"
            fi
            resolved=true
        else
            # dig ran but got no Query time — log raw output for debugging
            log "  DNS via $label ($server): dig returned no timing info"
            log "  Raw dig output:"
            echo "$result" | head -20 | sed 's/^/    /' | tee -a "$REPORT_FILE"
            log "  Falling back to nslookup..."
        fi
    fi

    # ── Try nslookup if dig didn't resolve ────────────────────
    if [ "$resolved" = false ] && cmd_exists nslookup; then
        local out
        out=$(nslookup "$domain" "$server" 2>&1)
        if echo "$out" | grep -qE "Address:.*[0-9]{1,3}\.[0-9]"; then
            log "  DNS via $label ($server): resolved OK (via nslookup)"
            ok "DNS from $label OK (via nslookup)"
            resolved=true
        else
            log "  nslookup raw output:"
            echo "$out" | sed 's/^/    /' | tee -a "$REPORT_FILE"
        fi
    fi

    # ── Final failure ─────────────────────────────────────────
    if [ "$resolved" = false ]; then
        log "  DNS via $label ($server): FAILED"
        fail "DNS resolution failed via $label ($server)"
    fi
}

resolve_dns "ISP Default"            "$(cat /etc/resolv.conf 2>/dev/null | grep nameserver | head -1 | awk '{print $2}')"
resolve_dns "Google DNS"             "8.8.8.8"
resolve_dns "Cloudflare DNS"         "1.1.1.1"
resolve_dns "OpenDNS"                "208.67.222.222"

# ══════════════════════════════════════════════════════════════
#  TEST 5 — MTU / PACKET FRAGMENTATION
# ══════════════════════════════════════════════════════════════
section "TEST 5 — MTU / PACKET FRAGMENTATION"
log ""
info "Testing maximum packet size that passes without fragmentation..."
log ""

mtu_test() {
    local size="$1"
    # Linux ping uses -s for payload size; total IP packet = size + 28 (ICMP+IP headers)
    local out
    if [[ "$OS_NAME" == "Darwin" ]]; then
        out=$(ping -c 3 -W 2000 -D -s "$size" "$TEST_HOST" 2>&1)
    else
        out=$(ping -c 3 -W 2 -M do -s "$size" "$TEST_HOST" 2>&1)
    fi
    if echo "$out" | grep -qiE "0% packet loss|0 packets lost|bytes from"; then
        echo "$size"
        return 0
    fi
    return 1
}

found_mtu=""
for size in 1472 1464 1452 1440 1400 1300 1200; do
    if mtu_test "$size" &>/dev/null; then
        found_mtu=$size
        break
    fi
done

if [ -n "$found_mtu" ]; then
    total_mtu=$(( found_mtu + 28 ))
    log "  Largest working payload size : ${found_mtu} bytes"
    log "  Effective MTU (payload + headers) : ${total_mtu} bytes"
    if [ "$total_mtu" -lt 1480 ]; then
        warn "MTU is below standard 1500 — fragmentation may cause issues"
        warn "Standard Ethernet MTU is 1500. Your ISP may have misconfigured PPPoE MTU."
    else
        ok "MTU appears normal"
    fi
else
    warn "Could not determine MTU (ICMP may be blocked by host)"
fi

# ══════════════════════════════════════════════════════════════
#  TEST 6 — IPV4 vs IPV6 COMPARISON
# ══════════════════════════════════════════════════════════════
section "TEST 6 — IPv4 vs IPv6 COMPARISON"
log ""

info "Testing IPv4 connectivity..."
ipv4_out=$(ping -c 10 -W 3 "$TEST_HOST" 2>&1)
ipv4_loss=$(echo "$ipv4_out" | grep -oE '[0-9]+% packet loss' | grep -oE '^[0-9]+')
ipv4_loss=${ipv4_loss:-100}
log "  IPv4 ($TEST_HOST) packet loss: ${ipv4_loss}%"

info "Testing IPv6 connectivity..."
ipv6_out=$(ping6 -c 10 -W 3 "$TEST_HOST_IPV6" 2>&1 || ping -6 -c 10 -W 3 "$TEST_HOST_IPV6" 2>&1)
if echo "$ipv6_out" | grep -q "packet loss"; then
    ipv6_loss=$(echo "$ipv6_out" | grep -oE '[0-9]+% packet loss' | grep -oE '^[0-9]+')
    ipv6_loss=${ipv6_loss:-100}
    log "  IPv6 ($TEST_HOST_IPV6) packet loss: ${ipv6_loss}%"
    ipv4_int=$(printf "%.0f" "$ipv4_loss")
    ipv6_int=$(printf "%.0f" "$ipv6_loss")
    if [ "$ipv4_int" -gt 5 ] && [ "$ipv6_int" -le 5 ]; then
        warn "IPv4 has loss but IPv6 is clean — ISP may have IPv4-specific routing issue"
    elif [ "$ipv6_int" -gt 5 ] && [ "$ipv4_int" -le 5 ]; then
        warn "IPv6 has loss but IPv4 is clean — ISP may have IPv6 routing issue"
    elif [ "$ipv4_int" -le 5 ] && [ "$ipv6_int" -le 5 ]; then
        ok "Both IPv4 and IPv6 appear healthy"
    else
        fail "Both IPv4 and IPv6 show packet loss — likely a general upstream issue"
    fi
else
    log "  IPv6: Not available or blocked on this connection"
    info "No IPv6 connectivity detected (may be normal depending on ISP plan)"
fi

# ══════════════════════════════════════════════════════════════
#  TEST 7 — PORT REACHABILITY
# ══════════════════════════════════════════════════════════════
section "TEST 7 — PORT REACHABILITY"
log ""
info "Testing if key ports are reachable (rules out ISP port blocking)..."
log ""

test_port() {
    local host="$1"
    local port="$2"
    local label="$3"
    if cmd_exists nc; then
        if nc -z -w 5 "$host" "$port" &>/dev/null; then
            ok "Port $port ($label) → OPEN"
            log "    Host: $host | Port: $port | Status: OPEN"
        else
            fail "Port $port ($label) → BLOCKED or unreachable"
            log "    Host: $host | Port: $port | Status: BLOCKED"
        fi
    elif cmd_exists curl; then
        result=$(curl -s --connect-timeout 5 -o /dev/null -w "%{http_code}" "http://$host:$port" 2>&1)
        if [ "$result" != "000" ]; then
            ok "Port $port ($label) → reachable (HTTP $result)"
        else
            fail "Port $port ($label) → BLOCKED or unreachable"
        fi
    else
        skip "Port reachability test (nc/curl not found)"
        return
    fi
}

test_port "google.com"    80   "HTTP"
test_port "google.com"    443  "HTTPS"
test_port "8.8.8.8"       53   "DNS"
test_port "smtp.gmail.com" 587 "SMTP/email"

# ══════════════════════════════════════════════════════════════
#  TEST 8 — DOWNLOAD/UPLOAD SPEED
# ══════════════════════════════════════════════════════════════
section "TEST 8 — DOWNLOAD / UPLOAD SPEED"
log ""

if cmd_exists speedtest-cli || cmd_exists speedtest; then
    # Determine which binary is available
    ST_CMD="speedtest-cli"
    cmd_exists speedtest && ST_CMD="speedtest"

    info "Running speedtest-cli (multi-stream, most accurate)..."
    info "This may take 30–60 seconds..."
    log ""

    # --simple gives clean 3-line output: Ping / Download / Upload
    st_out=$($ST_CMD --simple 2>&1)
    st_exit=$?

    if [ $st_exit -ne 0 ] || echo "$st_out" | grep -qi "error\|cannot\|failed"; then
        warn "speedtest-cli encountered an error:"
        log "$st_out" | sed 's/^/    /'
        warn "Falling back to curl single-stream test..."
        USE_CURL_FALLBACK=true
    else
        echo "$st_out" | sed 's/^/  /' | tee -a "$REPORT_FILE"
        log ""

        # Parse results
        ping_ms=$(echo "$st_out"  | grep -i "ping"     | grep -oE '[0-9.]+' | head -1)
        dl_mbps=$(echo "$st_out"  | grep -i "download" | grep -oE '[0-9.]+' | head -1)
        ul_mbps=$(echo "$st_out"  | grep -i "upload"   | grep -oE '[0-9.]+' | head -1)

        [ -n "$ping_ms" ] && log "  Ping        : ${ping_ms} ms"
        [ -n "$dl_mbps" ] && log "  Download    : ${dl_mbps} Mbps"
        [ -n "$ul_mbps" ] && log "  Upload      : ${ul_mbps} Mbps"
        log ""
        log "  [NOTE] speedtest-cli uses multiple parallel streams —"
        log "         these values are more credible for ISP dispute evidence."
        log ""

        dl_int=$(printf "%.0f" "${dl_mbps:-0}")
        if [ "$dl_int" -lt 1 ]; then
            fail "Download below 1 Mbps — severely degraded"
        elif [ "$dl_int" -lt 10 ]; then
            warn "Download below 10 Mbps — significantly lower than typical broadband"
        else
            ok "Download: ${dl_mbps} Mbps | Upload: ${ul_mbps} Mbps"
        fi
        USE_CURL_FALLBACK=false
    fi
else
    warn "speedtest-cli not found — install it for more accurate results:"
    log "    pip install speedtest-cli   OR   sudo apt install speedtest-cli"
    USE_CURL_FALLBACK=true
fi

# ── curl fallback ──────────────────────────────────────────────
if [ "${USE_CURL_FALLBACK}" = "true" ]; then
    if cmd_exists curl; then
        info "Running single-stream curl download test (less accurate than speedtest)..."
        info "URL: $DOWNLOAD_URL"
        log ""
        dl_result=$(curl -o /dev/null \
            -w "Downloaded: %{size_download} bytes\nTime total: %{time_total}s\nSpeed: %{speed_download} bytes/sec\nHTTP Status: %{http_code}" \
            --max-time 60 --silent "$DOWNLOAD_URL" 2>&1)
        echo "$dl_result" | sed 's/^/  /' | tee -a "$REPORT_FILE"
        speed_bps=$(echo "$dl_result" | grep "Speed:" | grep -oE '[0-9.]+' | head -1)
        if [ -n "$speed_bps" ]; then
            speed_mbps=$(awk "BEGIN {printf \"%.2f\", $speed_bps * 8 / 1000000}")
            log ""
            log "  Calculated speed : ${speed_mbps} Mbps (single-stream estimate)"
            log "  [WARNING] Single-stream curl often underreports real speed."
            log "            Install speedtest-cli for accurate multi-stream results."
            speed_int=$(printf "%.0f" "$speed_mbps")
            if [ "$speed_int" -lt 1 ]; then
                fail "Speed below 1 Mbps — severely degraded"
            elif [ "$speed_int" -lt 10 ]; then
                warn "Speed below 10 Mbps — may be degraded (or curl underreporting)"
            else
                ok "Estimated download: ${speed_mbps} Mbps"
            fi
        fi
    else
        skip "Speed test (neither speedtest-cli nor curl found)"
    fi
fi

# ══════════════════════════════════════════════════════════════
#  TEST 9 — ROUTE CONSISTENCY (Route Flapping Detection)
# ══════════════════════════════════════════════════════════════
section "TEST 9 — ROUTE CONSISTENCY (Flapping Detection)"
log ""
info "Running 3 traceroutes 30 seconds apart to detect route instability..."
log ""

if cmd_exists traceroute || cmd_exists tracepath; then
    for i in 1 2 3; do
        log "  ── Traceroute run $i / 3 — $(date +"%H:%M:%S") ──"
        if cmd_exists traceroute; then
            traceroute -m 15 -w 2 -q 1 "$TEST_HOST" 2>&1 | sed 's/^/  /' | tee -a "$REPORT_FILE"
        else
            tracepath "$TEST_HOST" 2>&1 | head -20 | sed 's/^/  /' | tee -a "$REPORT_FILE"
        fi
        log ""
        if [ "$i" -lt 3 ]; then
            info "Waiting 30 seconds before next run..."
            sleep 30
        fi
    done
    log ""
    warn "Compare the 3 traceroutes above — if hops change between runs, route flapping is occurring."
    info "Stable routes = same hops each time. Flapping = different IPs at the same hop number."
else
    skip "Route flapping detection (traceroute/tracepath not available)"
fi

# ══════════════════════════════════════════════════════════════
#  TEST 10 — NETWORK INTERFACE & IP INFO
# ══════════════════════════════════════════════════════════════
section "TEST 10 — NETWORK INTERFACE & CONNECTION INFO"
log ""

info "Network interfaces:"
log ""
if cmd_exists ip; then
    ip addr show 2>&1 | sed 's/^/  /' | tee -a "$REPORT_FILE"
elif cmd_exists ifconfig; then
    ifconfig 2>&1 | sed 's/^/  /' | tee -a "$REPORT_FILE"
fi

log ""
info "Routing table:"
log ""
if cmd_exists ip; then
    ip route 2>&1 | sed 's/^/  /' | tee -a "$REPORT_FILE"
elif cmd_exists netstat; then
    netstat -rn 2>&1 | sed 's/^/  /' | tee -a "$REPORT_FILE"
fi

log ""
info "Public IP address:"
if cmd_exists curl; then
    pub_ip=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null)
    [ -n "$pub_ip" ] && log "  Public IP: $pub_ip" || log "  Could not retrieve public IP"
fi

log ""
info "DNS servers in use:"
grep "^nameserver" /etc/resolv.conf 2>/dev/null | sed 's/^/  /' | tee -a "$REPORT_FILE"

# ══════════════════════════════════════════════════════════════
#  FINAL SUMMARY
# ══════════════════════════════════════════════════════════════
section "DIAGNOSTIC COMPLETE"
log ""
log "  All tests finished at: $(date)"
log "  Full report saved to : $REPORT_FILE"
log ""
log "  ── HOW TO SEND THIS TO YOUR ISP ────────────────────────────"
log "  1. Attach the report file to your support ticket or email"
log "  2. Request escalation to Tier 2/3 network support"
log "  3. Ask them to check nodes shown in the traceroute output"
log "  4. Reference Test 1 (packet loss %) and Test 3 (traceroute)"
log "     as primary evidence of the problem"
log ""
log "  Report file: $REPORT_FILE"
log "══════════════════════════════════════════════════════════════════"
echo ""
echo -e "${GREEN}${BOLD}  ✓ Diagnostic complete!${RESET}"
echo -e "  Report saved to: ${CYAN}$REPORT_FILE${RESET}"
echo ""
