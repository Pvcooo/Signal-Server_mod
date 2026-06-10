#!/usr/bin/env bash
#
# launch_simulations.sh
# -----------------------------------------------------------------------------
# Reads a data file and launches Signal-Server (runsig_lidar.sh):
#   - COVERAGE : one per HOME              x each Tx height.
#   - P2P      : one per HOME x each POINT x each Tx height x each Rx height.
#                (only if the location has at least one non-HOME point)
#
#                   DATA FILE FORMAT (.txt)
#   tx_height: 1.75, 3, 5      <- transmitter heights (list)
#   rx_height: 1.75            <- P2P receiver heights (list)
#
#   Location1.bin
#   HOME:    lat, lon, -R 16   <- HOME with its coordinates and parameters
#   Relay_1: lat, lon, -R 7    <- receiver point with a free name and parameters
#   km_2.5:  lat, lon, -R 4
#   ...
#
#   - Each "Name: lat, lon, <extra>" line is a point. Whatever follows the 2nd
#     comma (<extra>, e.g. "-R 7") is appended VERBATIM to THAT command.
#       * COVERAGE uses the HOME <extra>.
#       * P2P uses the receiver point <extra>.
#   - The point name (before the colon) can be anything; it is used as -rxn and
#     in the output file name. Names must be unique within each location
#     (duplicates get _2, _3, ... appended).
#
# USAGE:
#   ./launch_simulations.sh [data_file.txt]
#
# OPTIONS (environment variables):
#   DRY_RUN=1        -> only print the commands, do NOT run anything
#   SKIP_EXISTING=1  -> skip a simulation if its output file already exists
#   STOP_ON_ERROR=1  -> abort the batch if a command fails (default: continue)
#   ONLY=coverage | ONLY=p2p  -> run only one type
#   JOBS=N           -> run up to N simulations in parallel (default: 1).
#                       Each simulation is already multi-threaded, so a safe
#                       value is roughly (CPU cores / threads-per-sim). To use
#                       every core cleanly, set JOBS=$(nproc) and add -nothreads
#                       to COMMON_PARAMS (one thread per job, N jobs at once).
#
# EXAMPLES:
#   DRY_RUN=1 ./launch_simulations.sh example_input.txt
#   ./launch_simulations.sh example_input.txt 2>&1 | tee log.txt
# -----------------------------------------------------------------------------
set -uo pipefail

# ============================== CONFIGURATION ================================
# All paths are derived from this script's location, so there are no hardcoded
# machine-specific folders.
SS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SS_DIR/.." && pwd)"
RUNSIG="$SS_DIR/runsig_lidar.sh"
ANT="$REPO/data/antennas/Monopole/Monopole_9dBi"
# Output base folder. Override with the OUTBASE environment variable.
OUTBASE="${OUTBASE:-$REPO/results}"

# If running from /mnt/c gives "Permission denied", uncomment:
RUNNER=()
# RUNNER=(bash)

# Parameters common to COVERAGE and P2P.
# Note: the -R radius is NOT set here; each data-file line provides it.
COMMON_PARAMS=(-f 2450 -erp 9.683 -pm 1 -pe 3 -rel 70 -conf 70 -cl 5 -te 4 -resample 2 -m -dbm)

# Receiver gain (-rxg).
RXG="2.86"

# Default P2P Rx height, used if the file has no 'rx_height' line.
P2P_RXH="5"
# =============================================================================

DATA_FILE="${1:-example_input.txt}"
DRY_RUN="${DRY_RUN:-0}"
SKIP_EXISTING="${SKIP_EXISTING:-0}"
STOP_ON_ERROR="${STOP_ON_ERROR:-0}"
ONLY="${ONLY:-all}"
JOBS="${JOBS:-1}"
[[ "$JOBS" =~ ^[0-9]+$ ]] || JOBS=1
(( JOBS < 1 )) && JOBS=1

# Parallel execution pool (opt-in via JOBS>1). DRY_RUN always stays serial.
PARALLEL=0; RESDIR=""
if (( JOBS > 1 )) && [[ "$DRY_RUN" != "1" ]]; then
    PARALLEL=1
    RESDIR="$(mktemp -d)"
fi

if [[ ! -f "$DATA_FILE" ]]; then
    echo "ERROR: data file not found: '$DATA_FILE'" >&2
    exit 1
fi

trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

# split "a, b, c" into an array (by reference)
split_list() {
    local -n _dest="$1"; local v
    _dest=()
    IFS=',' read -ra _arr <<< "$2"
    for v in "${_arr[@]}"; do
        v="$(printf '%s' "$v" | tr -d '[:space:]')"
        [[ -n "$v" ]] && _dest+=("$v")
    done
}

# from "  lat , lon , -R 16 " extract PLAT, PLON and PEXTRA (after the 2nd comma)
PLAT=""; PLON=""; PEXTRA=""
parse_point() {
    local rest="$1"
    PLAT="$(trim "$(printf '%s' "$rest" | cut -d',' -f1)")"
    PLON="$(trim "$(printf '%s' "$rest" | cut -d',' -f2)")"
    PEXTRA="$(trim "$(printf '%s' "$rest" | cut -d',' -f3-)")"
}

# ------------------------------ DATA PARSING ---------------------------------
HEIGHTS=()      # Tx heights
RX_HEIGHTS=()   # Rx heights (P2P)
LOC_NAMES=()
LOC_HOME=()     # "lat|lon|extra"
LOC_RX=()       # "name|lat|lon|extra;name|lat|lon|extra;..."  (may be empty)

cur=-1
while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="${raw%$'\r'}"            # strip CR (CRLF)
    line="$(trim "$line")"

    [[ -z "$line" ]] && continue          # empty line
    [[ "$line" == \#* ]] && continue       # comment

    # stop at a separator or an example command line
    if [[ "$line" =~ ^-{3,} ]] || [[ "$line" == ../* ]] || [[ "$line" == *runsig_lidar.sh* ]]; then
        break
    fi

    lc="${line,,}"

    # heights (Tx or Rx) — the key before ':' contains "height";
    # Rx is distinguished by the presence of "rx" in that key.
    if [[ "$line" == *:* && "${lc%%:*}" == *height* ]]; then
        if [[ "${lc%%:*}" == *rx* ]]; then
            split_list RX_HEIGHTS "${line#*:}"
        else
            split_list HEIGHTS "${line#*:}"
        fi
        continue
    fi

    # HOME
    if [[ "${line^^}" == HOME:* ]]; then
        parse_point "${line#*:}"
        [[ $cur -ge 0 ]] && LOC_HOME[$cur]="$PLAT|$PLON|$PEXTRA"
        continue
    fi

    # any other line with ":" => receiver point (free name)
    if [[ "$line" == *:* ]]; then
        label="$(trim "${line%%:*}")"
        parse_point "${line#*:}"
        if [[ $cur -ge 0 ]]; then
            rec="$label|$PLAT|$PLON|$PEXTRA"
            if [[ -z "${LOC_RX[$cur]}" ]]; then
                LOC_RX[$cur]="$rec"
            else
                LOC_RX[$cur]="${LOC_RX[$cur]};$rec"
            fi
        fi
        continue
    fi

    # line without ":" => new location (the .bin suffix is stripped)
    name="${line%.bin}"
    cur=$((cur+1))
    LOC_NAMES[$cur]="$name"
    LOC_HOME[$cur]=""
    LOC_RX[$cur]=""
done < "$DATA_FILE"

# If the file has no Rx heights, use the default value
[[ ${#RX_HEIGHTS[@]} -eq 0 ]] && RX_HEIGHTS=("$P2P_RXH")

# ------------------------------ VALIDATION -----------------------------------
if [[ ${#HEIGHTS[@]} -eq 0 ]]; then
    echo "ERROR: no Tx height found (line 'tx_height: ...')." >&2
    exit 1
fi
if [[ ${#LOC_NAMES[@]} -eq 0 ]]; then
    echo "ERROR: no location found." >&2
    exit 1
fi

# ------------------------------ TOTAL COUNT ----------------------------------
H=${#HEIGHTS[@]}
HRX=${#RX_HEIGHTS[@]}
NLOC=${#LOC_NAMES[@]}

COB_N=0
P2P_N=0
for li in "${!LOC_NAMES[@]}"; do
    [[ -n "${LOC_HOME[$li]}" ]] && COB_N=$((COB_N + H))
    s="${LOC_RX[$li]}"
    if [[ -n "$s" && -n "${LOC_HOME[$li]}" ]]; then
        nr=$(awk -F';' '{print NF}' <<< "$s")
        P2P_N=$((P2P_N + nr * H * HRX))
    fi
done

case "$ONLY" in
    coverage) TOTAL=$COB_N ;;
    p2p)      TOTAL=$P2P_N ;;
    *)        TOTAL=$((COB_N + P2P_N)) ;;
esac

# ------------------------------ PRE-RUN SUMMARY ------------------------------
echo "============================================================"
echo " Data file        : $DATA_FILE"
echo " Tx heights       : ${HEIGHTS[*]}"
echo " Rx heights (P2P) : ${RX_HEIGHTS[*]}"
echo " Locations        : $NLOC"
echo " Coverage         : $COB_N"
echo " P2P              : $P2P_N"
echo " TOTAL to run     : $TOTAL   (ONLY=$ONLY)"
[[ "$DRY_RUN" == "1" ]]       && echo " MODE             : DRY_RUN (nothing is executed)"
[[ "$SKIP_EXISTING" == "1" ]] && echo " SKIP_EXISTING    : yes (skips already-existing outputs)"
[[ "$STOP_ON_ERROR" == "1" ]] && echo " STOP_ON_ERROR    : yes (aborts on failure)"
[[ "$PARALLEL" == "1" ]]      && echo " PARALLEL         : up to $JOBS simulation(s) at once"
echo "============================================================"

IDX=0
FAILS=()
SKIPPED=0
START_ALL=$SECONDS

summary() {
    local dur=$((SECONDS - START_ALL))
    echo
    echo "============================================================"
    echo " Launched : $IDX / $TOTAL"
    echo " Skipped  : $SKIPPED"
    echo " Failures : ${#FAILS[@]}"
    for f in "${FAILS[@]:-}"; do [[ -n "$f" ]] && echo "    - $f"; done
    echo " Total time: ${dur}s"
    echo "============================================================"
}
trap 'echo; echo "Interrupted by user."; summary; exit 130' INT TERM

run_job() {
    local label="$1"; shift
    IDX=$((IDX+1))

    if [[ "$DRY_RUN" == "1" ]]; then
        printf '\n[%d/%d] %s\n' "$IDX" "$TOTAL" "$label"
        printf '    '; printf '%q ' "$@"; printf '\n'
        return 0
    fi

    if (( PARALLEL == 1 )); then
        # Throttle: wait until fewer than JOBS background jobs are running.
        while (( $(jobs -rp | wc -l) >= JOBS )); do
            wait -n 2>/dev/null || sleep 0.2
        done
        local idx=$IDX
        printf '\n[%d/%d] START  %s\n' "$idx" "$TOTAL" "$label"
        printf '%s' "$label" > "$RESDIR/$idx.label"
        (
            if "$@" > "$RESDIR/$idx.log" 2>&1; then
                printf 'OK'   > "$RESDIR/$idx.res"
            else
                printf 'FAIL' > "$RESDIR/$idx.res"
            fi
        ) &
        return 0
    fi

    # Serial mode.
    printf '\n[%d/%d] %s\n' "$IDX" "$TOTAL" "$label"
    local start=$SECONDS
    if "$@"; then
        printf '    OK (%ds)\n' "$((SECONDS - start))"
    else
        local rc=$?
        printf '    FAILED (rc=%d)\n' "$rc"
        FAILS+=("$label")
        if [[ "$STOP_ON_ERROR" == "1" ]]; then
            echo "STOP_ON_ERROR=1 -> aborting the batch."
            summary
            exit 1
        fi
    fi
}

# returns 0 (skip) if SKIP_EXISTING and an output already exists
already_exists() {
    [[ "$SKIP_EXISTING" == "1" ]] && compgen -G "$1*" >/dev/null 2>&1
}

# ------------------------------ COVERAGE -------------------------------------
if [[ "$ONLY" == "all" || "$ONLY" == "coverage" ]]; then
    for li in "${!LOC_NAMES[@]}"; do
        name="${LOC_NAMES[$li]}"
        [[ -z "${LOC_HOME[$li]}" ]] && { echo "WARNING: '$name' has no HOME, skipping coverage." >&2; continue; }
        IFS='|' read -r hlat hlon hextra <<< "${LOC_HOME[$li]}"
        read -ra hextra_arr <<< "$hextra"
        for h in "${HEIGHTS[@]}"; do
            out="$OUTBASE/$name/${name}_Home_${h}m"
            label="COVERAGE  $name  Home  txh=${h}m  [${hextra:-no extra}]"
            if already_exists "$out"; then
                IDX=$((IDX+1)); SKIPPED=$((SKIPPED+1))
                printf '\n[%d/%d] %s\n    (already exists, skipped)\n' "$IDX" "$TOTAL" "$label"
                continue
            fi
            cmd=( "${RUNNER[@]}" "$RUNSIG" -ant "$ANT" -rxg "$RXG"
                  -lat "$hlat" -lon "$hlon" -txh "$h"
                  -txn "Home $name"
                  "${hextra_arr[@]}"
                  "${COMMON_PARAMS[@]}"
                  -o "$out" )
            run_job "$label" "${cmd[@]}"
        done
    done
fi

# ------------------------------ P2P ------------------------------------------
if [[ "$ONLY" == "all" || "$ONLY" == "p2p" ]]; then
    for li in "${!LOC_NAMES[@]}"; do
        name="${LOC_NAMES[$li]}"
        [[ -z "${LOC_HOME[$li]}" ]] && continue
        rx_str="${LOC_RX[$li]}"
        [[ -z "$rx_str" ]] && continue        # no points => no P2P
        IFS='|' read -r hlat hlon _hextra <<< "${LOC_HOME[$li]}"
        IFS=';' read -ra recs <<< "$rx_str"
        declare -A namecount=()
        for rec in "${recs[@]}"; do
            IFS='|' read -r rxname rlat rlon rextra <<< "$rec"
            read -ra rextra_arr <<< "$rextra"

            # file-safe name (no spaces), unique within the location
            rxfs="${rxname// /_}"
            cnt=$(( ${namecount[$rxfs]:-0} + 1 )); namecount[$rxfs]=$cnt
            [[ $cnt -gt 1 ]] && rxfs="${rxfs}_${cnt}"

            for h in "${HEIGHTS[@]}"; do
                for rh in "${RX_HEIGHTS[@]}"; do
                    if [[ $HRX -gt 1 ]]; then
                        out="$OUTBASE/$name/${name}_P2P_${rxfs}_tx${h}m_rx${rh}m"
                    else
                        out="$OUTBASE/$name/${name}_P2P_${rxfs}_${h}m"
                    fi
                    label="P2P        $name -> $rxname  txh=${h}m rxh=${rh}m  [${rextra:-no extra}]"
                    if already_exists "$out"; then
                        IDX=$((IDX+1)); SKIPPED=$((SKIPPED+1))
                        printf '\n[%d/%d] %s\n    (already exists, skipped)\n' "$IDX" "$TOTAL" "$label"
                        continue
                    fi
                    cmd=( "${RUNNER[@]}" "$RUNSIG" -ant "$ANT" -rxg "$RXG"
                          -lat "$hlat" -lon "$hlon" -txh "$h"
                          -rla "$rlat" -rlo "$rlon" -rxh "$rh"
                          -txn "Home $name" -rxn "$rxname"
                          "${rextra_arr[@]}"
                          "${COMMON_PARAMS[@]}"
                          -o "$out" )
                    run_job "$label" "${cmd[@]}"
                done
            done
        done
        unset namecount
    done
fi

# Wait for any parallel jobs and collect their results.
if (( PARALLEL == 1 )); then
    wait
    if [[ -n "$RESDIR" ]]; then
        for rf in "$RESDIR"/*.res; do
            [[ -e "$rf" ]] || continue
            if [[ "$(cat "$rf" 2>/dev/null)" == "FAIL" ]]; then
                i="$(basename "$rf" .res)"
                FAILS+=("$(cat "$RESDIR/$i.label" 2>/dev/null)")
            fi
        done
    fi
fi

summary

# Keep per-job logs only if something failed (parallel mode); else clean up.
if (( PARALLEL == 1 )) && [[ -n "$RESDIR" ]]; then
    if (( ${#FAILS[@]} > 0 )); then
        echo "Per-job logs (for the failures) are in: $RESDIR"
    else
        rm -rf "$RESDIR"
    fi
fi
