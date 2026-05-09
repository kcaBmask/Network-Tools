#!/usr/bin/env bash
# =============================================================
#  ping_monitor.sh — ISP Packet Loss Monitor & Logger
#  Usage: bash ping_monitor.sh [HOST] [DURATION_MINUTES]
#  Defaults: host=8.8.8.8, duration=60 minutes
# =============================================================

# ── Configuration ─────────────────────────────────────────────
HOST="${1:-8.8.8.8}"           # Target host (default: Google DNS)
DURATION_MIN="${2:-60}"         # How long to run in minutes
PING_COUNT=50                   # Pings per test cycle
INTERVAL_SEC=120                 # Seconds between each test cycle
ALERT_THRESHOLD=10              # Packet loss % to flag as WARNING
CRITICAL_THRESHOLD=30           # Packet loss % to flag as CRITICAL

# ── Log file setup ─────────────────────────────────────────────
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_DIR="./ping_logs"
LOG_FILE="${LOG_DIR}/ping_report_${TIMESTAMP}.log"
SUMMARY_FILE="${LOG_DIR}/ping_summary_${TIMESTAMP}.txt"

mkdir -p "$LOG_DIR"

# ── Helpers ────────────────────────────────────────────────────
log() { echo "$1" | tee -a "$LOG_FILE"; }

print_header() {
    local line="============================================================"
    log "$line"
    log "  ISP PACKET LOSS MONITOR — $(date)"
    log "$line"
    log "  Target Host   : $HOST"
    log "  Test Duration : ${DURATION_MIN} minutes"
    log "  Pings/Cycle   : $PING_COUNT"
    log "  Cycle Interval: ${INTERVAL_SEC}s"
    log "  Log File      : $LOG_FILE"
    log "$line"
    log ""
}

# ── Main monitoring loop ───────────────────────────────────────
run_monitor() {
    local end_time=$(( $(date +%s) + DURATION_MIN * 60 ))
    local cycle=0
    local total_loss=0
    local warn_count=0
    local crit_count=0
    local ok_count=0

    print_header

    while [ "$(date +%s)" -lt "$end_time" ]; do
        cycle=$(( cycle + 1 ))
        local now
        now=$(date +"%Y-%m-%d %H:%M:%S")

        # Run ping and capture output
        local ping_output
        ping_output=$(ping -c "$PING_COUNT" -W 2 "$HOST" 2>&1)
        local ping_exit=$?

        # Parse packet loss
        local loss_pct
        if echo "$ping_output" | grep -q "packet loss"; then
            loss_pct=$(echo "$ping_output" | grep -oE '[0-9]+(\.[0-9]+)?% packet loss' | grep -oE '^[0-9]+(\.[0-9]+)?')
        else
            loss_pct=100  # Host unreachable = 100% loss
        fi

        # Parse latency (avg)
        local avg_ms="N/A"
        if echo "$ping_output" | grep -q "rtt\|round-trip"; then
            avg_ms=$(echo "$ping_output" | grep -oE 'rtt[^=]+=\s*[0-9.]+/[0-9.]+' | grep -oE '[0-9.]+/[0-9.]+' | cut -d/ -f2)
            [ -z "$avg_ms" ] && avg_ms=$(echo "$ping_output" | grep -oE '[0-9.]+/[0-9.]+/[0-9.]+' | cut -d/ -f2)
        fi

        # Determine status label
        local status
        loss_int=$(printf "%.0f" "$loss_pct")
        if [ "$loss_int" -ge "$CRITICAL_THRESHOLD" ]; then
            status="[CRITICAL]"
            crit_count=$(( crit_count + 1 ))
        elif [ "$loss_int" -ge "$ALERT_THRESHOLD" ]; then
            status="[WARNING] "
            warn_count=$(( warn_count + 1 ))
        else
            status="[  OK   ] "
            ok_count=$(( ok_count + 1 ))
        fi

        total_loss=$(echo "$total_loss + $loss_pct" | bc)

        # Log the result line
        log "$(printf 'Cycle %03d | %s | %s | Loss: %5s%% | Avg Latency: %s ms' \
            "$cycle" "$now" "$status" "$loss_pct" "${avg_ms:-N/A}")"

        # Log raw ping if there's packet loss for evidence
        if [ "$loss_int" -ge "$ALERT_THRESHOLD" ]; then
            log "           Raw ping output:"
            echo "$ping_output" | sed 's/^/           /' | tee -a "$LOG_FILE"
            log ""
        fi

        sleep "$INTERVAL_SEC"
    done

    # ── Summary ──────────────────────────────────────────────
    local avg_loss=0
    [ "$cycle" -gt 0 ] && avg_loss=$(echo "scale=2; $total_loss / $cycle" | bc)

    {
        echo "============================================================"
        echo "  MONITORING SUMMARY REPORT"
        echo "  Generated: $(date)"
        echo "============================================================"
        echo ""
        echo "  Target Host      : $HOST"
        echo "  Test Duration    : ${DURATION_MIN} minutes"
        echo "  Total Cycles     : $cycle"
        echo "  Pings per Cycle  : $PING_COUNT"
        echo "  Total Pings Sent : $(( cycle * PING_COUNT ))"
        echo ""
        echo "  ── Results ────────────────────────────────────────────"
        echo "  OK  cycles  (loss < ${ALERT_THRESHOLD}%)    : $ok_count"
        echo "  WARN cycles (loss ${ALERT_THRESHOLD}-${CRITICAL_THRESHOLD}%)  : $warn_count"
        echo "  CRIT cycles (loss >= ${CRITICAL_THRESHOLD}%) : $crit_count"
        echo "  Average Packet Loss        : ${avg_loss}%"
        echo ""
        echo "  ── Verdict ─────────────────────────────────────────────"
        if [ "$crit_count" -gt 0 ]; then
            echo "  ⚠  CRITICAL issues detected in $crit_count cycle(s)."
            echo "     Strong evidence of ISP-side packet loss problem."
        elif [ "$warn_count" -gt 0 ]; then
            echo "  ⚠  WARNING: Elevated packet loss in $warn_count cycle(s)."
        else
            echo "  ✓  No significant packet loss detected during this session."
        fi
        echo ""
        echo "  Full log file: $LOG_FILE"
        echo "============================================================"
    } | tee -a "$LOG_FILE" > "$SUMMARY_FILE"

    echo ""
    echo "✓ Done! Files saved:"
    echo "  Full log : $LOG_FILE"
    echo "  Summary  : $SUMMARY_FILE"
}

# ── Run ────────────────────────────────────────────────────────
run_monitor
