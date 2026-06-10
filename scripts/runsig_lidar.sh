#!/bin/bash
# Run signalserverLIDAR and generate outputs + KMZ.
#
# Area coverage:
#   ./runsig_lidar.sh -lat LAT -lon LON -txh H -f FREQ -erp ERP -R RADIUS \
#       [-txn "TX Name"] [-rxn "RX Name"] [-resample N] -o /path/output
#
# Point-to-point:
#   ./runsig_lidar.sh -lat LAT -lon LON -txh H \
#       -rla RXLAT -rlo RXLON [-rxh H] \
#       -f FREQ -erp ERP -o /path/output \
#       [-txn "TX Name"] [-rxn "RX Name"] \
#       [-coverage -R RADIUS_km]   # also computes coverage and adds it to the KMZ as "Plot"
#
# Requires: imagemagick  (sudo apt install imagemagick)
#           zip          (sudo apt install zip)
#           gnuplot      (sudo apt install gnuplot)   [P2P only]

# --- Fix CRLF line endings if the script was saved on Windows ---
case "$(head -1 "$0" | cat -A)" in *'^M'*) sed -i 's/\r//' "$0"; exec bash "$0" "$@";; esac

SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPTDIR/.." && pwd)"
BINARY="${ROOT}/src/signalserverLIDAR"
DTM_DIR="${ROOT}/data/dtm"

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 [options] -o OUTPUT_PATH"
    exit 1
fi

# ---------- Parse arguments ----------
OUTPATH="" TX_LAT="" TX_LON="" TX_H="" RX_LAT="" RX_LON="" RX_H=""
PPA=0 METRIC=0 COVERAGE=0 TX_NAME="" RX_NAME="" RADIUS=""
COV_RESAMPLE="" COV_PM=""

args=("$@")
for i in "${!args[@]}"; do
    val="${args[$((i+1))]:-}"
    case "${args[$i]}" in
        -o)           OUTPATH="$val"       ;;
        -lat)         TX_LAT="$val"        ;;
        -lon)         TX_LON="$val"        ;;
        -txh)         TX_H="$val"          ;;
        -rla)         RX_LAT="$val"; PPA=1 ;;
        -rlo)         RX_LON="$val"        ;;
        -rxh)         RX_H="$val"          ;;
        -m)           METRIC=1             ;;
        -coverage)    COVERAGE=1           ;;
        -txn)         TX_NAME="$val"       ;;
        -rxn)         RX_NAME="$val"       ;;
        -R)           RADIUS="$val"        ;;
        -covresample) COV_RESAMPLE="$val"  ;;
        -covpm)       COV_PM="$val"        ;;
    esac
done

if [[ -z "$OUTPATH" ]]; then
    echo "Error: -o OUTPUT_PATH is required" >&2; exit 1
fi

# Create a subfolder named after the output: .../BASENAME/BASENAME.*
_BASE_PARENT="$(dirname "$OUTPATH")"
BASENAME="$(basename "$OUTPATH")"
OUTDIR="${_BASE_PARENT}/${BASENAME}"
OUTPATH="${OUTDIR}/${BASENAME}"
mkdir -p "$OUTDIR"
# Make paths absolute so steps that run from a temp dir (the KMZ zip) work
# even when -o / OUTBASE is a relative path.
OUTDIR="$(cd "$OUTDIR" && pwd)"
OUTPATH="${OUTDIR}/${BASENAME}"

# ---------- Build argument lists for the binary ----------
# BINARY_ARGS: args for the P2P/coverage run.
#   Excludes: -coverage, -txn, -rxn (script-only), -R (handled below)
BINARY_ARGS=()
skip_next=0
for i in "${!args[@]}"; do
    if [[ $skip_next -eq 1 ]]; then skip_next=0; continue; fi
    case "${args[$i]}" in
        -coverage)              ;;                    # script-only, no value
        -txn|-rxn|-R)           skip_next=1 ;;        # script-only / added below
        -covresample|-covpm)    skip_next=1 ;;        # script-only
        -o)          BINARY_ARGS+=("${args[$i]}" "$OUTPATH"); skip_next=1 ;;
        *)           BINARY_ARGS+=("${args[$i]}") ;;
    esac
done

# -R for BINARY_ARGS (P2P run or direct coverage):
#   - If the user passed -R: use that value.
#   - If P2P without -R: compute TX->RX distance + 1 km margin so that
#     the binary loads every tile along the path (Signal Server uses -R
#     to determine the tile-loading area even in P2P mode).
if [[ -n "$RADIUS" ]]; then
    BINARY_ARGS+=("-R" "$RADIUS")
elif [[ $PPA -eq 1 && -n "$TX_LAT" && -n "$TX_LON" && -n "$RX_LAT" && -n "$RX_LON" ]]; then
    _AUTO_R=$(python3 -c "
import math
lat1,lon1,lat2,lon2 = $TX_LAT,$TX_LON,$RX_LAT,$RX_LON
p1,p2 = math.radians(lat1),math.radians(lat2)
a = math.sin((p2-p1)/2)**2 + math.cos(p1)*math.cos(p2)*math.sin(math.radians(lon2-lon1)/2)**2
print(round(6371*2*math.asin(math.sqrt(a))+1, 1))
" 2>/dev/null || echo "10")
    BINARY_ARGS+=("-R" "$_AUTO_R")
fi

# COV_ARGS: coverage run — removes P2P flags, replaces -R with the user value.
COV_ARGS=()
skip_next=0
for i in "${!BINARY_ARGS[@]}"; do
    if [[ $skip_next -eq 1 ]]; then skip_next=0; continue; fi
    case "${BINARY_ARGS[$i]}" in
        -rla|-rlo|-rxh|-R|-resample)  skip_next=1 ;;
        *)                            COV_ARGS+=("${BINARY_ARGS[$i]}") ;;
    esac
done
[[ -n "$RADIUS" ]] && COV_ARGS+=("-R" "$RADIUS")

# Coverage resample: if the user passed -covresample use it;
# otherwise default to 5 (25 m effective on a 5 m DTM -> 25x faster).
# Passing -covresample 1 disables resampling.
_COV_RESAMPLE="${COV_RESAMPLE:-5}"
[[ "$_COV_RESAMPLE" -gt 1 ]] 2>/dev/null && COV_ARGS+=("-resample" "$_COV_RESAMPLE")

# Propagation model for coverage (optional, independent of P2P):
# -covpm 1=ITM (accurate, slow), 3=Hata, 6=COST-Hata, 7=FSPL (fast).
[[ -n "$COV_PM" ]] && COV_ARGS+=("-pm" "$COV_PM")

# ---------- Filter noisy messages from the binary ----------
# Suppresses internal load/reprojection/debug lines; keeps errors and warnings.
_filter_log() {
    grep -v -E \
        '^(Loading |Reprojecting |Loaded GDAL |res |mw:|Mnw:|totalh:|north_pixel|mn:|Offset |Height:|Setting IPPD|LIDAR LOADED|fc |ppd |field strength|Finished PlotProp|Cropping )'
}

# ---------- Check dependencies BEFORE running ----------
for dep in convert zip; do
    if ! command -v "$dep" &>/dev/null; then
        echo "ERROR: '$dep' not found. Install with: sudo apt install ${dep/convert/imagemagick}" >&2
        exit 1
    fi
done
if [[ $PPA -eq 1 ]] && ! command -v gnuplot &>/dev/null; then
    # gnuplot is only needed for the profile chart; do NOT abort the whole run.
    echo "WARNING: 'gnuplot' not found; the profile chart will be skipped." >&2
    echo "         Install it with: sudo apt install gnuplot" >&2
fi

# ---------- Generate .dcf (color definitions for dBm maps) ----------
generate_dcf() {
    cat > "$1" << 'DCFEOF'
       +0: 255,   0,   0
      -10: 255, 128,   0
      -20: 255, 165,   0
      -30: 255, 206,   0
      -40: 255, 255,   0
      -50: 184, 255,   0
      -60:   0, 255,   0
      -70:   0, 208,   0
      -80:   0, 196, 196
      -90:   0, 148, 255
     -100:  80,  80, 255
     -110:   0,  38, 255
     -120: 142,  63, 255
     -130: 196,  54, 255
     -140: 255,   0, 255
     -150: 255, 194, 204
DCFEOF
}

# ---------- Generate a legend PNG (colour -> dBm) from a .dcf palette ----------
generate_legend() {
    # $1 = .dcf palette file, $2 = output PNG. Needs ImageMagick (convert).
    local dcf="$1" out="$2"
    command -v convert >/dev/null 2>&1 || return 1
    [[ -f "$dcf" ]] || return 1
    local rowh=18 sw=24 x0=8 y=28 n=0 line val rgb r g b
    # Draw INLINE (no '-draw @file': some ImageMagick policies block indirect
    # MVG reads, which would leave the legend blank).
    local draw="fill black stroke none font-size 13 text 8,18 'Signal level (dBm)'"
    while IFS= read -r line; do
        val="$(printf '%s' "$line" | sed -nE 's/^[[:space:]]*([+-]?[0-9]+)[[:space:]]*:.*/\1/p')"
        [[ -n "$val" ]] || continue
        rgb="$(printf '%s' "$line" | sed -E 's/^[^:]*:[[:space:]]*//')"
        r="$(printf '%s' "$rgb" | cut -d, -f1 | tr -dc '0-9')"
        g="$(printf '%s' "$rgb" | cut -d, -f2 | tr -dc '0-9')"
        b="$(printf '%s' "$rgb" | cut -d, -f3 | tr -dc '0-9')"
        [[ -n "$r" && -n "$g" && -n "$b" ]] || continue
        draw+=" fill rgb($r,$g,$b) stroke black stroke-width 0.6 rectangle $x0,$y $((x0+sw)),$((y+rowh-4))"
        draw+=" fill black stroke none text $((x0+sw+6)),$((y+rowh-7)) '$val'"
        y=$((y+rowh)); n=$((n+1))
    done < "$dcf"
    [[ $n -gt 0 ]] || return 1
    local W=142 H=$((y+6))
    # Opaque, 8-bit PNG so Google Earth accepts it as an overlay.
    convert -size "${W}x${H}" xc:white -fill none -stroke black -strokewidth 1 -draw "rectangle 0,0 $((W-1)),$((H-1))" -draw "$draw" -alpha off -depth 8 "$out" 2>/dev/null
}

# ============================================================
# POINT-TO-POINT MODE
# ============================================================
if [[ $PPA -eq 1 ]]; then

    # -------- Run P2P analysis --------
    TMPLOG="$(mktemp)"
    { time "$BINARY" -lid "$DTM_DIR" "${BINARY_ARGS[@]}"; } 2>"$TMPLOG"
    _filter_log < "$TMPLOG" >&2
    rm -f "$TMPLOG"
    # The auto-radius may produce a .ppm as a side effect; remove it
    # when explicit coverage was not requested.
    [[ $COVERAGE -eq 0 ]] && rm -f "${OUTPATH}.ppm"

    TXT="${OUTPATH}.txt"
    if [[ ! -f "$TXT" ]]; then
        echo "ERROR: report not found: $TXT" >&2; exit 1
    fi

    # Always generate .dcf as an output file
    generate_dcf "${OUTPATH}.dcf"

    # -------- Run additional coverage (-coverage flag) --------
    COV_PNG="" BBOX_NORTH="" BBOX_EAST="" BBOX_SOUTH="" BBOX_WEST=""
    if [[ $COVERAGE -eq 1 ]]; then
        if [[ -z "$RADIUS" ]]; then
            echo "ERROR: -coverage also requires -R RADIUS_km" >&2; exit 1
        fi
        TMPLOG_COV="$(mktemp)"
        { time "$BINARY" -lid "$DTM_DIR" "${COV_ARGS[@]}" -dbg; } 2>"$TMPLOG_COV"
        _filter_log < "$TMPLOG_COV" >&2
        PPM_COV="${OUTPATH}.ppm"
        if [[ -f "$PPM_COV" ]]; then
            COV_PNG="${OUTPATH}.png"
            convert "$PPM_COV" -transparent white "$COV_PNG"
            convert "$PPM_COV" "${OUTPATH}.tiff"
            BBOX="$(grep '^|' "$TMPLOG_COV" | tail -1)" || true
            if [[ -n "$BBOX" ]]; then
                IFS='|' read -ra PARTS <<< "$BBOX"
                BBOX_NORTH="${PARTS[1]}"
                BBOX_EAST="${PARTS[2]}"
                BBOX_SOUTH="${PARTS[3]}"
                BBOX_WEST="${PARTS[4]}"
            fi
        else
            echo "WARNING: -coverage active but no PPM produced. Missing -R or binary failure?" >&2
        fi
        rm -f "$TMPLOG_COV"
    fi

    # Legend (colour -> dBm) for the coverage overlay, if any.
    LEGEND_PNG=""
    if [[ -n "$COV_PNG" && -f "$COV_PNG" ]]; then
        LEGEND_PNG="${OUTPATH}_legend.png"
        generate_legend "${OUTPATH}.dcf" "$LEGEND_PNG" || LEGEND_PNG=""
    fi

    # -------- Parse .txt --------
    units="true"
    [[ $METRIC -eq 0 ]] && units="false"

    TX_SITE=$(grep "^Transmitter site:" "$TXT" | sed 's/Transmitter site: //')
    TX_LOC=$(awk '/^Transmitter site:/{f=1} f && /^Site location:/{print; exit}' "$TXT" \
             | sed 's/Site location: //')
    TX_GROUND=$(awk '/^Transmitter site:/{f=1} f && /^Ground elevation:/{print; exit}' "$TXT" \
                | grep -oP '[\-0-9.]+(?= meters AMSL)' | head -1)
    TX_ANT_AGL=$(awk '/^Transmitter site:/{f=1} f && /^Antenna height:/{print; exit}' "$TXT" \
                 | grep -oP '[\-0-9.]+(?= meters AGL)' | head -1)
    TX_ANT_AMSL=$(awk '/^Transmitter site:/{f=1} f && /^Antenna height:/{print; exit}' "$TXT" \
                  | grep -oP '[\-0-9.]+(?= meters AMSL)' | head -1)
    TX_DIST=$(awk '/^Transmitter site:/{f=1} f && /^Distance to Rx:/{print; exit}' "$TXT" \
              | grep -oP '[\-0-9.]+(?= kilo)' | head -1)
    TX_AZ=$(awk '/^Transmitter site:/{f=1} f && /^Azimuth to Rx:/{print; exit}' "$TXT" \
            | grep -oP '[\-0-9.]+(?= degrees)' | head -1)
    TX_TILT=$(awk '/^Transmitter site:/{f=1} f && /^Downtilt angle to Rx:/{print; exit}' "$TXT" \
              | grep -oP '[+\-0-9.]+(?= degrees)' | head -1)
    TX_LAT_TXT=$(echo "$TX_LOC" | cut -d',' -f1 | tr -d ' ')
    TX_LON_TXT=$(echo "$TX_LOC" | cut -d',' -f2 | tr -d ' ')

    RX_SITE=$(grep "^Receiver site:" "$TXT" | sed 's/Receiver site: //')
    RX_LOC=$(awk '/^Receiver site:/{f=1} f && /^Site location:/{print; exit}' "$TXT" \
             | sed 's/Site location: //')
    RX_GROUND=$(awk '/^Receiver site:/{f=1} f && /^Ground elevation:/{print; exit}' "$TXT" \
                | grep -oP '[\-0-9.]+(?= meters AMSL)' | head -1)
    RX_ANT_AGL=$(awk '/^Receiver site:/{f=1} f && /^Antenna height:/{print; exit}' "$TXT" \
                 | grep -oP '[\-0-9.]+(?= meters AGL)' | head -1)
    RX_ANT_AMSL=$(awk '/^Receiver site:/{f=1} f && /^Antenna height:/{print; exit}' "$TXT" \
                  | grep -oP '[\-0-9.]+(?= meters AMSL)' | head -1)
    RX_DIST=$(awk '/^Receiver site:/{f=1} f && /^Distance to Tx:/{print; exit}' "$TXT" \
              | grep -oP '[\-0-9.]+(?= kilo)' | head -1)
    RX_AZ=$(awk '/^Receiver site:/{f=1} f && /^Azimuth to Tx:/{print; exit}' "$TXT" \
            | grep -oP '[\-0-9.]+(?= degrees)' | head -1)
    RX_TILT=$(awk '/^Receiver site:/{f=1} f && /^Downtilt angle to Tx:/{print; exit}' "$TXT" \
              | grep -oP '[+\-0-9.]+(?= degrees)' | head -1)
    RX_LAT_TXT=$(echo "$RX_LOC" | cut -d',' -f1 | tr -d ' ')
    RX_LON_TXT=$(echo "$RX_LOC" | cut -d',' -f2 | tr -d ' ')

    # Apply custom names if provided
    [[ -n "$TX_NAME" ]] && TX_SITE="$TX_NAME"
    [[ -n "$RX_NAME" ]] && RX_SITE="$RX_NAME"

    PROP_MODEL=$(grep "^Propagation model:" "$TXT" | sed 's/Propagation model: //')
    SUBTYPE=$(grep "^Model sub-type:" "$TXT" | sed 's/Model sub-type: //')
    FREQ=$(grep "^Frequency:" "$TXT" | grep -oP '[\-0-9.]+(?= MHz)' | head -1)
    DIELEC=$(grep "^Earth.s Dielectric" "$TXT" | grep -oP '[\-0-9.]+' | head -1)
    CONDUCT=$(grep "^Earth.s Conductivity" "$TXT" | grep -oP '[\-0-9.]+' | head -1)
    ATMO=$(grep "^Atmospheric" "$TXT" | grep -oP '[\-0-9.]+(?= ppm)' | head -1)
    CLIMATE=$(grep "^Radio Climate:" "$TXT" | sed 's/.*(\(.*\))/\1/')
    POLAR=$(grep "^Polarisation:" "$TXT" | sed 's/.*(\(.*\))/\1/')
    FSIT=$(grep "^Fraction of Situations:" "$TXT" | grep -oP '[\-0-9.]+' | head -1)
    FTIM=$(grep "^Fraction of Time:" "$TXT" | grep -oP '[\-0-9.]+' | head -1)
    RX_GAIN=$(grep "^Receiver gain:" "$TXT" | grep -oP '^[\-0-9.]+' | head -1)
    TX_ERP_PLUS=$(grep "^Transmitter ERP plus" "$TXT" | grep -oP '[\-0-9.]+(?= Watts)' | head -1)
    TX_ERP_MINUS=$(grep "^Transmitter ERP minus" "$TXT" | grep -oP '[\-0-9.]+(?= dBm)' | head -1)
    TX_EIRP_PLUS=$(grep "^Transmitter EIRP plus" "$TXT" | grep -oP '[\-0-9.]+(?= Watts)' | head -1)
    TX_EIRP_MINUS=$(grep "^Transmitter EIRP minus" "$TXT" | grep -oP '[\-0-9.]+(?= dBm)' | head -1)
    FSPL=$(grep "^Free space path loss:" "$TXT" | grep -oP '[\-0-9.]+(?= dB)' | head -1)
    CPLOSS=$(grep "^Computed path loss:" "$TXT" | grep -oP '[\-0-9.]+(?= dB)' | head -1)
    SHIELD=$(grep "^Attenuation due to terrain" "$TXT" | grep -oP '[+\-0-9.]+(?= dB)' | head -1)
    FSRX=$(grep "^Field strength at Rx:" "$TXT" | grep -oP '[\-0-9.]+(?= dBuV)' | head -1)
    PRXDBM=$(grep "^Signal power level at Rx:" "$TXT" | grep -oP '[\-0-9.]+(?= dBm)' | head -1)
    PRXDENSITY=$(grep "^Signal power density at Rx:" "$TXT" | grep -oP '[\-0-9.]+(?= dBW)' | head -1)
    V50=$(grep "^Voltage across 50 ohm" "$TXT" | grep -oP '[\-0-9.]+(?= uV)' | head -1)
    V75=$(grep "^Voltage across 75 ohm" "$TXT" | grep -oP '[\-0-9.]+(?= uV)' | head -1)
    LR_ERR=$(grep "^Longley-Rice model error number:" "$TXT" | grep -oP '^[0-9]+' | head -1)

    RAISE_OBST=$(grep "to clear all obstructions" "$TXT" | grep -oP '[\-0-9.]+(?= meters AGL)' | head -1)
    RAISE_FRESNEL=$(grep "to clear the first Fresnel zone" "$TXT" | grep -oP '[\-0-9.]+(?= meters AGL)' | head -1)
    [[ -z "$RAISE_OBST" ]]    && RAISE_OBST="0.0"
    [[ -z "$RAISE_FRESNEL" ]] && RAISE_FRESNEL="0.0"

    OBSTRUCTED=false
    OBS_JSON="[]"
    if grep -q "obstructions were detected" "$TXT"; then
        OBSTRUCTED=true
        OBS_JSON="["
        first_obs=1
        while IFS= read -r line; do
            obs_lat=$(echo "$line" | grep -oP '^[\-0-9.]+(?= N)')
            obs_lon_raw=$(echo "$line" | grep -oP '[\-0-9.]+(?= W)')
            obs_dist=$(echo "$line" | grep -oP '[\-0-9.]+(?= kilo)')
            obs_elev=$(echo "$line" | grep -oP '[\-0-9.]+(?= meters AMSL)')
            [[ -z "$obs_lat" ]] && continue
            obs_lon="-${obs_lon_raw}"
            [[ $first_obs -eq 0 ]] && OBS_JSON+=","
            OBS_JSON+="{\"lat\":$obs_lat,\"lon\":$obs_lon,\"dist_km\":$obs_dist,\"elev_m\":$obs_elev}"
            first_obs=0
        done < <(awk '/obstructions were detected/{f=1;next} f && /^[0-9]/{print} f && !/^[0-9]/ && NF>0{f=0}' "$TXT")
        OBS_JSON+="]"
    fi

    # JSON-valid numbers: leading zero on fractions (bc drops it) and no
    # leading '+' on angles/attenuation (invalid JSON).
    FSIT_J=$(awk "BEGIN{printf \"%.4f\", (${FSIT:-50})/100}")
    FTIM_J=$(awk "BEGIN{printf \"%.4f\", (${FTIM:-90})/100}")
    TX_TILT="${TX_TILT#+}"; RX_TILT="${RX_TILT#+}"; SHIELD="${SHIELD#+}"

    # -------- Generate JSON --------
    cat > "${OUTPATH}.json" <<JSON_EOF
{
    "_link": {
        "_computed_path_loss": ${CPLOSS:-0},
        "_free_space_path_loss": ${FSPL:-0},
        "_longley_rice_errors": ${LR_ERR:-0},
        "_obstructions": ${OBS_JSON},
        "_power_density_at_rx": ${PRXDENSITY:-0},
        "_power_level_at_rx": ${PRXDBM:-0},
        "_rx_adjustment_to_clear_first_fresnel_zone": ${RAISE_FRESNEL},
        "_rx_adjustment_to_clear_first_fresnel_zone60": 0.0,
        "_rx_adjustment_to_clear_obstructions": ${RAISE_OBST},
        "_terrain_shielding_attenuation": ${SHIELD:-0},
        "_use_metric": ${units},
        "_voltage_50ohm_dipole": ${V50:-0},
        "_voltage_75ohm_dipole": ${V75:-0},
        "field_strength_at_rx": ${FSRX:-0}
    },
    "_model": {
        "_atmospheric_bending": ${ATMO:-0},
        "_dielectric_constant": ${DIELEC:-0},
        "_earth_conductivity": ${CONDUCT:-0},
        "_fraction_of_situation": ${FSIT_J:-0.5},
        "_fraction_of_time": ${FTIM_J:-0.9},
        "_frequency": ${FREQ:-0},
        "_model": "${PROP_MODEL}",
        "_polarization": "${POLAR}",
        "_radio_climate": "${CLIMATE}",
        "_rx_gain": ${RX_GAIN:-0},
        "_subtype": "${SUBTYPE}",
        "_tx_eirp_minus_rx_gain": ${TX_EIRP_MINUS:-0},
        "_tx_eirp_plus_rx_gain": ${TX_EIRP_PLUS:-0},
        "_tx_erp_minus_rx_gain": ${TX_ERP_MINUS:-0},
        "_tx_erp_plus_rx_gain": ${TX_ERP_PLUS:-0}
    },
    "_receiver": {
        "_azimuth": ${RX_AZ:-0},
        "_distance": ${RX_DIST:-0},
        "_downtilt": ${RX_TILT:-0},
        "_elevation": ${RX_GROUND:-0},
        "_height": ${RX_ANT_AGL:-0},
        "_latitude": ${RX_LAT_TXT:-0},
        "_longitude": ${RX_LON_TXT:-0},
        "_metric": ${units},
        "_site": "${RX_SITE}"
    },
    "_transmitter": {
        "_azimuth": ${TX_AZ:-0},
        "_distance": ${TX_DIST:-0},
        "_downtilt": ${TX_TILT:-0},
        "_elevation": ${TX_GROUND:-0},
        "_height": ${TX_ANT_AGL:-0},
        "_latitude": ${TX_LAT_TXT:-0},
        "_longitude": ${TX_LON_TXT:-0},
        "_metric": ${units},
        "_site": "${TX_SITE}"
    }
}
JSON_EOF

    # -------- Profile chart (gnuplot) --------
    PROFILE_PNG="${OUTPATH}_profile.png"
    GP_TERRAIN="${OUTPATH}_terrain_abs"
    GP_LOS="${OUTPATH}_los_abs"
    GP_F1="${OUTPATH}_fresnel_abs"
    GP_F60="${OUTPATH}_fresnel60_abs"

    if [[ -f "$GP_TERRAIN" && -f "$GP_LOS" ]]; then
        GPLOT_SCRIPT="$(mktemp --suffix=.gp)"

        # Y-axis baseline: 100 m below the lowest terrain point on the path.
        YMIN=$(awk 'NF>=2 && $2 ~ /^-?[0-9.]+$/ { if (m=="" || $2<m) m=$2 } END { if (m=="") m=0; printf "%.1f", m-100 }' "$GP_TERRAIN")

        PLOT_CMD="\"${GP_TERRAIN}\" using 1:2 with filledcurves y1=${YMIN} title 'Terrain Profile' lc rgb '#A0826D' fs solid 0.7"
        PLOT_CMD+=", \"${GP_TERRAIN}\" using 1:2 with lines lc rgb '#6B4F3A' lw 1 notitle"
        PLOT_CMD+=", \"${GP_LOS}\" using 1:2 with lines lw 2 dt 2 lc 'black' title 'Line of Sight'"
        [[ -f "$GP_F1"  ]] && PLOT_CMD+=", \"${GP_F1}\"  using 1:2 with lines lw 1 lc 'green' title 'First Fresnel Zone (100%)'"
        [[ -f "$GP_F60" ]] && PLOT_CMD+=", \"${GP_F60}\" using 1:2 with lines lw 1 lc 'red'   title 'First Fresnel Zone (60%)'"

        # pngcairo requires libcairo support; fall back to the basic png terminal
        if gnuplot -e "set terminal pngcairo" 2>/dev/null; then
            _GP_TERM='pngcairo size 800,450 background "white" font "sans,10"'
        else
            _GP_TERM='png size 800,450'
        fi

        cat > "$GPLOT_SCRIPT" <<GNUPLOT_EOF
set terminal ${_GP_TERM}
set output "${PROFILE_PNG}"
set title "Site to Site Analysis"
set xlabel "Distance (km)"
set ylabel "Elevation (m AMSL)"
set yrange [${YMIN}:*]
set key right top
set grid
set style fill transparent solid 0.7 noborder
plot ${PLOT_CMD}
GNUPLOT_EOF
        gnuplot "$GPLOT_SCRIPT" 2>&1 | grep -v '^$' >&2 || true
        [[ -f "$PROFILE_PNG" ]] || echo "WARNING: gnuplot did not generate the profile (check that gnuplot is installed)" >&2
        rm -f "$GPLOT_SCRIPT"
    fi
    # Remove intermediate _abs files (used only as gnuplot input)
    rm -f "$GP_TERRAIN" "$GP_LOS" "$GP_F1" "$GP_F60"

    # -------- Prepare shared description --------
    # GE does not reliably resolve "files/..." paths inside CDATA across all
    # versions. The image is embedded as a base64 data URI to avoid the issue.
    PROFILE_IMG_REF=""
    [[ -f "$PROFILE_PNG" ]] && PROFILE_IMG_REF="data:image/png;base64,$(base64 -w 0 "$PROFILE_PNG")"

    TXT_HTML="$(sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g' "${OUTPATH}.txt")"

    # Emit the description HTML to stdout (image + full report)
    write_full_desc() {
        [[ -n "$PROFILE_IMG_REF" ]] && \
            printf '<img src="%s" width="560"/><br/><br/>' "$PROFILE_IMG_REF"
        printf '<pre>'
        printf '%s' "$TXT_HTML"
        printf '</pre>'
    }

    # -------- Build link segments (coordinates, no description) --------
    # Uses relativeToGround + AGL so the line and pins match the
    # Google Earth terrain, preventing the line from sinking below GE's DEM.
    TX_COORD="${TX_LON_TXT},${TX_LAT_TXT},${TX_ANT_AGL:-0}"
    RX_COORD="${RX_LON_TXT},${RX_LAT_TXT},${RX_ANT_AGL:-0}"
    SEG_COLORS=(); SEG_NAMES=(); SEG_COORDS=()
    OBS_PINS=""

    write_obs_pin() {
        # args: lon lat elev_amsl n dist_from_tx_km total_d_km
        local lon="$1" lat="$2" elev="$3" n="$4" d_tx="$5" d_total="$6"
        local d_rx
        d_rx=$(printf '%.3f' "$(echo "scale=3; $d_total - $d_tx" | bc)")
        printf '  <Placemark>\n    <name>Obstruction #%s</name>\n' "$n"
        printf '    <description><![CDATA['
        printf '<b>Obstruction #%s</b><br/><br/>' "$n"
        printf 'Location: %s N, %s W<br/>' "$lat" "${lon#-}"
        printf 'Height: %.0f m AMSL<br/>' "$elev"
        printf 'Distance from TX (%s): %.3f km<br/>' "$TX_SITE" "$d_tx"
        printf 'Distance to RX (%s): %s km<br/>' "$RX_SITE" "$d_rx"
        printf ']]></description>\n'
        printf '    <Style><IconStyle><color>ff0000ff</color><scale>1.1</scale>'
        printf '<Icon><href>http://maps.google.com/mapfiles/kml/paddle/red-stars.png</href></Icon>'
        printf '</IconStyle></Style>\n'
        printf '    <Point><altitudeMode>absolute</altitudeMode>'
        printf '<coordinates>%s,%s,%s</coordinates></Point>\n  </Placemark>\n' "$lon" "$lat" "$elev"
    }

    if [[ "$OBSTRUCTED" == "false" ]]; then
        SEG_COLORS+=("ff00ff00")
        SEG_NAMES+=("Clear Line of Sight Path")
        SEG_COORDS+=("${TX_COORD} ${RX_COORD}")
    else
        TOTAL_D="$RX_DIST"
        PREV_COORD="$TX_COORD"
        OBS_N=0

        while IFS=',' read -r obs_lat obs_lon obs_dist obs_elev; do
            [[ -z "$obs_lat" ]] && continue
            OBS_N=$((OBS_N + 1))
            OBS_COORD="${obs_lon},${obs_lat},0"
            SEG_COLORS+=("ff00ff00")
            SEG_NAMES+=("Clear Line of Sight Path")
            SEG_COORDS+=("${PREV_COORD} ${OBS_COORD}")
            PREV_COORD="$OBS_COORD"
            OBS_PINS+=$(write_obs_pin "$obs_lon" "$obs_lat" "$obs_elev" "$OBS_N" "$obs_dist" "$TOTAL_D")$'\n'
        done < <(python3 -c "
import re, sys
txt = open('${TXT}').read()
m = re.findall(r'([\d.]+) N, ([\d.]+) W, ([\d.]+) kilometers, ([\d.]+) meters AMSL', txt)
for lat,lon,dist,elev in m:
    print(lat+',-'+lon+','+dist+','+elev)
" 2>/dev/null)

        SEG_COLORS+=("ff0000ff")
        SEG_NAMES+=("Obstructed Line of Sight Path")
        SEG_COORDS+=("${PREV_COORD} ${RX_COORD}")
    fi

    # -------- Write KML --------
    # Pins: altitudeMode=relativeToGround with AGL height -> always visible above
    # Google Earth terrain even if its DEM differs from the source MDT.
    # Lines: altitudeMode=absolute with real AMSL values from the analysis.
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<kml xmlns="http://www.opengis.net/kml/2.2">\n<Document><name>%s</name>\n' "$BASENAME"

        # Coverage GroundOverlay (only if -coverage ran successfully)
        if [[ -n "$COV_PNG" && -n "$BBOX_NORTH" ]]; then
            printf '  <GroundOverlay>\n    <name>Plot</name>\n'
            printf '    <Icon><href>files/%s</href></Icon>\n' "$(basename "$COV_PNG")"
            printf '    <LatLonBox>\n'
            printf '      <north>%s</north>\n      <east>%s</east>\n' "$BBOX_NORTH" "$BBOX_EAST"
            printf '      <south>%s</south>\n      <west>%s</west>\n' "$BBOX_SOUTH" "$BBOX_WEST"
            printf '    </LatLonBox>\n  </GroundOverlay>\n'
        fi

        if [[ -n "$LEGEND_PNG" && -f "$LEGEND_PNG" ]]; then
            printf '  <ScreenOverlay>\n    <name>Legend</name>\n'
            printf '    <Icon><href>files/legend.png</href></Icon>\n'
            printf '    <overlayXY x="0" y="0" xunits="fraction" yunits="fraction"/>\n'
            printf '    <screenXY x="0.012" y="0.04" xunits="fraction" yunits="fraction"/>\n'
            printf '    <size x="0" y="0" xunits="fraction" yunits="fraction"/>\n'
            printf '  </ScreenOverlay>\n'
        fi

        # TX pin (green) — relativeToGround
        printf '  <Placemark>\n    <name>Station 1: %s</name>\n' "$TX_SITE"
        printf '    <description><![CDATA['
        write_full_desc
        printf ']]></description>\n'
        printf '    <Style><IconStyle><color>ff00ff00</color><scale>1.3</scale>'
        printf '<Icon><href>http://maps.google.com/mapfiles/kml/paddle/grn-circle.png</href></Icon>'
        printf '</IconStyle></Style>\n'
        printf '    <Point><altitudeMode>relativeToGround</altitudeMode>'
        printf '<coordinates>%s,%s,%s</coordinates></Point>\n  </Placemark>\n' \
            "$TX_LON_TXT" "$TX_LAT_TXT" "${TX_ANT_AGL:-0}"

        # RX pin (red) — relativeToGround — same description
        printf '  <Placemark>\n    <name>Station 2: %s</name>\n' "$RX_SITE"
        printf '    <description><![CDATA['
        write_full_desc
        printf ']]></description>\n'
        printf '    <Style><IconStyle><color>ff0000ff</color><scale>1.3</scale>'
        printf '<Icon><href>http://maps.google.com/mapfiles/kml/paddle/red-circle.png</href></Icon>'
        printf '</IconStyle></Style>\n'
        printf '    <Point><altitudeMode>relativeToGround</altitudeMode>'
        printf '<coordinates>%s,%s,%s</coordinates></Point>\n  </Placemark>\n' \
            "$RX_LON_TXT" "$RX_LAT_TXT" "${RX_ANT_AGL:-0}"

        # Link segments — relativeToGround + AGL — same description
        # Consistent with the pins: both use Google Earth's DEM as reference,
        # preventing the line from sinking below GE's terrain.
        for i in "${!SEG_COORDS[@]}"; do
            printf '  <Placemark>\n    <name>%s</name>\n' "${SEG_NAMES[$i]}"
            printf '    <description><![CDATA['
            write_full_desc
            printf ']]></description>\n'
            printf '    <Style><LineStyle><color>%s</color><width>3</width></LineStyle></Style>\n' \
                "${SEG_COLORS[$i]}"
            printf '    <LineString><altitudeMode>relativeToGround</altitudeMode><tessellate>0</tessellate>\n'
            printf '      <coordinates>%s</coordinates>\n    </LineString>\n  </Placemark>\n' \
                "${SEG_COORDS[$i]}"
        done

        # Obstruction pins
        echo -n "$OBS_PINS"

        printf '</Document>\n</kml>\n'
    } > "${OUTPATH}.kml"

    # -------- Create KMZ --------
    KMZ_TMP="$(mktemp -d)"
    mkdir -p "${KMZ_TMP}/files"
    # The root KML must be named doc.kml so GE resolves "files/..." paths in descriptions
    cp "${OUTPATH}.kml"  "${KMZ_TMP}/doc.kml"
    cp "${OUTPATH}.txt"  "${KMZ_TMP}/${BASENAME}.txt"
    cp "${OUTPATH}.json" "${KMZ_TMP}/${BASENAME}.json"
    [[ -f "$PROFILE_PNG" ]]              && cp "$PROFILE_PNG" "${KMZ_TMP}/files/"
    [[ -n "$COV_PNG" && -f "$COV_PNG" ]] && cp "$COV_PNG"     "${KMZ_TMP}/files/"
    [[ -n "$LEGEND_PNG" && -f "$LEGEND_PNG" ]] && cp "$LEGEND_PNG" "${KMZ_TMP}/files/legend.png"
    (cd "$KMZ_TMP" && zip -qr "${OUTPATH}.kmz" .)
    rm -rf "$KMZ_TMP"

    echo ""
    echo "Point-to-point analysis complete:"
    echo "  ${OUTPATH}.txt"
    echo "  ${OUTPATH}.json"
    echo "  ${OUTPATH}.dcf"
    [[ -f "$PROFILE_PNG" ]]              && echo "  ${PROFILE_PNG}"
    [[ -n "$COV_PNG" && -f "$COV_PNG" ]] && echo "  ${COV_PNG}  (coverage / Plot)"
    [[ -f "${OUTPATH}.tiff" ]]           && echo "  ${OUTPATH}.tiff"
    echo "  ${OUTPATH}.kmz"
    exit 0
fi

# ============================================================
# AREA COVERAGE MODE
# ============================================================
generate_dcf "${OUTPATH}.dcf"

TMPLOG="$(mktemp)"
{ time "$BINARY" -lid "$DTM_DIR" "${BINARY_ARGS[@]}" -dbg; } 2>"$TMPLOG"
_filter_log < "$TMPLOG" >&2

PPM="${OUTPATH}.ppm"
if [[ ! -f "$PPM" ]]; then
    echo "ERROR: PPM file not found: $PPM" >&2; rm -f "$TMPLOG"; exit 1
fi

# PNG: cap at 8192 px (GE does not use more in a GroundOverlay) to avoid
# ImageMagick cache exhaustion on high-resolution images.
# '8192x8192>' only downscales if the image is larger; keeps the aspect ratio.
if ! convert -limit memory 2GiB -limit disk 32GiB \
        "$PPM" -resize '8192x8192>' -transparent white "${OUTPATH}.png" 2>&1; then
    echo "WARNING: PNG conversion failed. Try reducing resolution with -resample." >&2
    rm -f "${OUTPATH}.png"
fi

# TIFF: full resolution with LZW compression for GIS use
if ! convert -limit memory 2GiB -limit disk 32GiB -compress LZW \
        "$PPM" "${OUTPATH}.tiff" 2>&1; then
    echo "WARNING: TIFF conversion failed." >&2
    rm -f "${OUTPATH}.tiff"
fi

BBOX="$(grep '^|' "$TMPLOG" | tail -1)" || true
rm -f "$TMPLOG"

if [[ -z "$BBOX" ]]; then
    echo "WARNING: bounding box not found. KMZ not generated." >&2
    echo "Generated files: ${OUTPATH}.ppm  ${OUTPATH}.dcf" >&2
    exit 0
fi

IFS='|' read -ra PARTS <<< "$BBOX"
NORTH="${PARTS[1]}" EAST="${PARTS[2]}" SOUTH="${PARTS[3]}" WEST="${PARTS[4]}"

TX_LABEL="${TX_NAME:-TX}"
[[ -n "$TX_H" ]] && TX_LABEL="${TX_LABEL} (${TX_H}m AGL)"
RX_LABEL="${RX_NAME:-RX}"
[[ -n "$RX_H" ]] && RX_LABEL="${RX_LABEL} (${RX_H}m AGL)"

# Legend (colour -> dBm) for the coverage overlay
LEGEND_PNG=""
if [[ -f "${OUTPATH}.png" ]]; then
    LEGEND_PNG="${OUTPATH}_legend.png"
    generate_legend "${OUTPATH}.dcf" "$LEGEND_PNG" || LEGEND_PNG=""
fi

{
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<kml xmlns="http://www.opengis.net/kml/2.2">\n<Document><name>%s</name>\n' "$BASENAME"
    if [[ -f "${OUTPATH}.png" ]]; then
        printf '  <GroundOverlay>\n    <name>Plot</name>\n'
        printf '    <Icon><href>files/%s.png</href></Icon>\n' "$BASENAME"
        printf '    <LatLonBox>\n'
        printf '      <north>%s</north>\n      <east>%s</east>\n' "$NORTH" "$EAST"
        printf '      <south>%s</south>\n      <west>%s</west>\n' "$SOUTH" "$WEST"
        printf '    </LatLonBox>\n  </GroundOverlay>\n'
    fi
    if [[ -n "$LEGEND_PNG" && -f "$LEGEND_PNG" ]]; then
        printf '  <ScreenOverlay>\n    <name>Legend</name>\n'
        printf '    <Icon><href>files/legend.png</href></Icon>\n'
        printf '    <overlayXY x="0" y="0" xunits="fraction" yunits="fraction"/>\n'
        printf '    <screenXY x="0.012" y="0.04" xunits="fraction" yunits="fraction"/>\n'
        printf '    <size x="0" y="0" xunits="fraction" yunits="fraction"/>\n'
        printf '  </ScreenOverlay>\n'
    fi
    if [[ -n "$TX_LAT" && -n "$TX_LON" ]]; then
        printf '  <Placemark>\n    <name>%s</name>\n' "$TX_LABEL"
        printf '    <Style><IconStyle><color>ff00ff00</color><scale>1.3</scale>'
        printf '<Icon><href>http://maps.google.com/mapfiles/kml/paddle/grn-circle.png</href></Icon>'
        printf '</IconStyle></Style>\n'
        printf '    <Point><coordinates>%s,%s,0</coordinates></Point>\n  </Placemark>\n' \
            "$TX_LON" "$TX_LAT"
    fi
    if [[ -n "$RX_LAT" && -n "$RX_LON" ]]; then
        printf '  <Placemark>\n    <name>%s</name>\n' "$RX_LABEL"
        printf '    <Style><IconStyle><color>ff0000ff</color><scale>1.3</scale>'
        printf '<Icon><href>http://maps.google.com/mapfiles/kml/paddle/red-circle.png</href></Icon>'
        printf '</IconStyle></Style>\n'
        printf '    <Point><coordinates>%s,%s,0</coordinates></Point>\n  </Placemark>\n' \
            "$RX_LON" "$RX_LAT"
    fi
    printf '</Document>\n</kml>\n'
} > "${OUTPATH}.kml"

# KMZ with files/ structure
KMZ_TMP="$(mktemp -d)"
mkdir -p "${KMZ_TMP}/files"
cp "${OUTPATH}.kml" "${KMZ_TMP}/${BASENAME}.kml"
[[ -f "${OUTPATH}.png" ]] && cp "${OUTPATH}.png" "${KMZ_TMP}/files/${BASENAME}.png"
[[ -n "$LEGEND_PNG" && -f "$LEGEND_PNG" ]] && cp "$LEGEND_PNG" "${KMZ_TMP}/files/legend.png"
(cd "$KMZ_TMP" && zip -qr "${OUTPATH}.kmz" .)
rm -rf "$KMZ_TMP"

echo ""
echo "Generated files:"
echo "  ${OUTPATH}.ppm"
[[ -f "${OUTPATH}.png"  ]] && echo "  ${OUTPATH}.png"
[[ -f "${OUTPATH}.tiff" ]] && echo "  ${OUTPATH}.tiff"
echo "  ${OUTPATH}.dcf"
echo "  ${OUTPATH}.kml"
echo "  ${OUTPATH}.kmz  <- Google Earth"
echo "Bounding box: N=${NORTH} E=${EAST} S=${SOUTH} W=${WEST}"
