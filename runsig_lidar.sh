#!/bin/bash
# Run signalserverLIDAR and generate outputs + KMZ.
#
# Area coverage:
#   ./runsig_lidar.sh -lat LAT -lon LON -txh H -f FREQ -erp ERP -R RADIUS \
#       [-txn "Nombre TX"] [-rxn "Nombre RX"] [-resample N] -o /ruta/salida
#
# Point-to-point:
#   ./runsig_lidar.sh -lat LAT -lon LON -txh H \
#       -rla RXLAT -rlo RXLON [-rxh H] \
#       -f FREQ -erp ERP -o /ruta/salida \
#       [-txn "Nombre TX"] [-rxn "Nombre RX"] \
#       [-coverage -R RADIO_km]   # también calcula cobertura y la añade al KMZ como "Plot"
#
# Requires: imagemagick  (sudo apt install imagemagick)
#           zip          (sudo apt install zip)
#           gnuplot      (sudo apt install gnuplot)   [P2P only]

# --- Fix CRLF si el script se guardó en Windows ---
case "$(head -1 "$0" | cat -A)" in *'^M'*) sed -i 's/\r//' "$0"; exec bash "$0" "$@";; esac

SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="${SCRIPTDIR}/src/signalserverLIDAR"
DTM_DIR="${SCRIPTDIR}/utils/DTM_models"

if [[ $# -eq 0 ]]; then
    echo "Uso: $0 [opciones] -o RUTA_SALIDA"
    exit 1
fi

# ---------- Parsear argumentos ----------
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
    echo "Error: -o RUTA_SALIDA es obligatorio" >&2; exit 1
fi

# Crear subcarpeta con el nombre del output: .../BASENAME/BASENAME.*
_BASE_PARENT="$(dirname "$OUTPATH")"
BASENAME="$(basename "$OUTPATH")"
OUTDIR="${_BASE_PARENT}/${BASENAME}"
OUTPATH="${OUTDIR}/${BASENAME}"
mkdir -p "$OUTDIR"

# ---------- Construir listas de argumentos para el binario ----------
# BINARY_ARGS: args para el run P2P/cobertura.
#   Excluye: -coverage, -txn, -rxn (solo script), -R (se gestiona abajo)
BINARY_ARGS=()
skip_next=0
for i in "${!args[@]}"; do
    if [[ $skip_next -eq 1 ]]; then skip_next=0; continue; fi
    case "${args[$i]}" in
        -coverage)              ;;                    # solo script, sin valor
        -txn|-rxn|-R)           skip_next=1 ;;        # solo script / se añade abajo
        -covresample|-covpm)    skip_next=1 ;;        # solo script
        -o)          BINARY_ARGS+=("${args[$i]}" "$OUTPATH"); skip_next=1 ;;
        *)           BINARY_ARGS+=("${args[$i]}") ;;
    esac
done

# -R para BINARY_ARGS (run P2P o cobertura directa):
#   · Si el usuario pasó -R: usar ese valor.
#   · Si es P2P sin -R: calcular distancia TX→RX + 1 km de margen para que
#     el binario cargue todos los tiles del trayecto (Signal Server usa -R
#     para determinar el área de carga de tiles incluso en modo P2P).
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

# COV_ARGS: run de cobertura — elimina flags P2P, sustituye -R por el del usuario.
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

# Resample para cobertura: si el usuario pasó -covresample úsalo;
# si no, aplica 5 por defecto (25m efectivo en MDT de 5m → 25× más rápido).
# Pasar -covresample 1 desactiva el resample.
_COV_RESAMPLE="${COV_RESAMPLE:-5}"
[[ "$_COV_RESAMPLE" -gt 1 ]] 2>/dev/null && COV_ARGS+=("-resample" "$_COV_RESAMPLE")

# Modelo de propagación para cobertura (opcional, independiente del P2P):
# -covpm 1=ITM (preciso, lento), 3=Hata, 6=COST-Hata, 7=FSPL (rápido).
[[ -n "$COV_PM" ]] && COV_ARGS+=("-pm" "$COV_PM")

# ---------- Filtro de mensajes ruidosos del binario ----------
# Suprime líneas de carga/reproyección/depuración internas; conserva errores y warnings.
_filter_log() {
    grep -v -E \
        '^(Loading |Reprojecting |Loaded GDAL |res |mw:|Mnw:|totalh:|north_pixel|mn:|Offset |Height:|Setting IPPD|LIDAR LOADED|fc |ppd |field strength|Finished PlotProp|Cropping )'
}

# ---------- Comprobar dependencias ANTES de ejecutar ----------
for dep in convert zip; do
    if ! command -v "$dep" &>/dev/null; then
        echo "ERROR: '$dep' no encontrado. Instala con: sudo apt install ${dep/convert/imagemagick}" >&2
        exit 1
    fi
done
if [[ $PPA -eq 1 ]] && ! command -v gnuplot &>/dev/null; then
    echo "ERROR: 'gnuplot' no encontrado. Instala con: sudo apt install gnuplot" >&2
    exit 1
fi

# ---------- Generar .dcf (color definitions para mapas dBm) ----------
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

# ============================================================
# MODO PUNTO A PUNTO
# ============================================================
if [[ $PPA -eq 1 ]]; then

    # -------- Ejecutar análisis P2P --------
    TMPLOG="$(mktemp)"
    { time "$BINARY" -lid "$DTM_DIR" "${BINARY_ARGS[@]}"; } 2>"$TMPLOG"
    _filter_log < "$TMPLOG" >&2
    rm -f "$TMPLOG"
    # El auto-radio puede generar un .ppm como efecto secundario; eliminarlo
    # cuando no se ha solicitado cobertura explícita.
    [[ $COVERAGE -eq 0 ]] && rm -f "${OUTPATH}.ppm"

    TXT="${OUTPATH}.txt"
    if [[ ! -f "$TXT" ]]; then
        echo "ERROR: no se encontró el informe: $TXT" >&2; exit 1
    fi

    # Generar .dcf siempre como archivo de salida
    generate_dcf "${OUTPATH}.dcf"

    # -------- Ejecutar cobertura adicional (flag -coverage) --------
    COV_PNG="" BBOX_NORTH="" BBOX_EAST="" BBOX_SOUTH="" BBOX_WEST=""
    if [[ $COVERAGE -eq 1 ]]; then
        if [[ -z "$RADIUS" ]]; then
            echo "ERROR: -coverage requiere también -R RADIO_km" >&2; exit 1
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
            echo "AVISO: -coverage activo pero no se generó PPM. ¿Falta -R o falla el binario?" >&2
        fi
        rm -f "$TMPLOG_COV"
    fi

    # -------- Parsear .txt --------
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

    # Aplicar nombres personalizados si se proporcionaron
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

    # -------- Generar JSON --------
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
        "_fraction_of_situation": $(echo "scale=4; ${FSIT:-50}/100" | bc),
        "_fraction_of_time": $(echo "scale=4; ${FTIM:-90}/100" | bc),
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

    # -------- Gráfico de perfil (gnuplot) --------
    PROFILE_PNG="${OUTPATH}_profile.png"
    GP_TERRAIN="${OUTPATH}_terrain_abs"
    GP_LOS="${OUTPATH}_los_abs"
    GP_F1="${OUTPATH}_fresnel_abs"
    GP_F60="${OUTPATH}_fresnel60_abs"

    if [[ -f "$GP_TERRAIN" && -f "$GP_LOS" ]]; then
        GPLOT_SCRIPT="$(mktemp --suffix=.gp)"

        PLOT_CMD="\"${GP_TERRAIN}\" using 1:2 with filledcurves y1=0 title 'Terrain Profile' lc rgb '#A0826D' fs solid 0.7"
        PLOT_CMD+=", \"${GP_TERRAIN}\" using 1:2 with lines lc rgb '#6B4F3A' lw 1 notitle"
        PLOT_CMD+=", \"${GP_LOS}\" using 1:2 with lines lw 2 dt 2 lc 'black' title 'Line of Sight'"
        [[ -f "$GP_F1"  ]] && PLOT_CMD+=", \"${GP_F1}\"  using 1:2 with lines lw 1 lc 'green' title 'First Fresnel Zone (100%)'"
        [[ -f "$GP_F60" ]] && PLOT_CMD+=", \"${GP_F60}\" using 1:2 with lines lw 1 lc 'red'   title 'First Fresnel Zone (60%)'"

        cat > "$GPLOT_SCRIPT" <<GNUPLOT_EOF
set terminal pngcairo size 800,450 background "white" font "sans,10"
set output "${PROFILE_PNG}"
set title "Site to Site Analysis"
set xlabel "Distance (km)"
set ylabel "Elevation (m AMSL)"
set key right top
set grid
set style fill transparent solid 0.7 noborder
plot ${PLOT_CMD}
GNUPLOT_EOF
        gnuplot "$GPLOT_SCRIPT" 2>/dev/null || echo "AVISO: gnuplot no pudo generar el perfil" >&2
        rm -f "$GPLOT_SCRIPT"
    fi
    # Eliminar archivos intermedios _abs (solo se usan como input de gnuplot)
    rm -f "$GP_TERRAIN" "$GP_LOS" "$GP_F1" "$GP_F60"

    # -------- Preparar descripción compartida --------
    # En KMZ, las imágenes en globos de descripción se referencian como
    # "files/nombre.png" (ruta relativa desde doc.kml en la raíz del ZIP).
    # GE Desktop resuelve correctamente estas rutas cuando el KML raíz
    # se llama "doc.kml" (convención estándar de KMZ).
    PROFILE_IMG_REF=""
    [[ -f "$PROFILE_PNG" ]] && PROFILE_IMG_REF="files/$(basename "$PROFILE_PNG")"

    TXT_HTML="$(sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g' "${OUTPATH}.txt")"

    # Emite el HTML de descripción a stdout (imagen + informe completo)
    write_full_desc() {
        [[ -n "$PROFILE_IMG_REF" ]] && \
            printf '<img src="%s" width="560"/><br/><br/>' "$PROFILE_IMG_REF"
        printf '<pre>'
        printf '%s' "$TXT_HTML"
        printf '</pre>'
    }

    # -------- Construir segmentos de enlace (coordenadas, sin descripción) --------
    # Se usa relativeToGround + AGL para que línea y pines sean coherentes con el
    # terreno de Google Earth, evitando que la línea se hunda bajo el DEM de GE.
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

    # -------- Escribir KML --------
    # Pins: altitudeMode=relativeToGround con altura AGL → siempre visibles sobre el
    # terreno de Google Earth aunque su DEM difiera del MDT de Navarra.
    # Líneas: altitudeMode=absolute con AMSL reales del análisis.
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<kml xmlns="http://www.opengis.net/kml/2.2">\n<Document><name>%s</name>\n' "$BASENAME"

        # GroundOverlay de cobertura (solo si se ejecutó -coverage con éxito)
        if [[ -n "$COV_PNG" && -n "$BBOX_NORTH" ]]; then
            printf '  <GroundOverlay>\n    <name>Plot</name>\n'
            printf '    <Icon><href>files/%s</href></Icon>\n' "$(basename "$COV_PNG")"
            printf '    <LatLonBox>\n'
            printf '      <north>%s</north>\n      <east>%s</east>\n' "$BBOX_NORTH" "$BBOX_EAST"
            printf '      <south>%s</south>\n      <west>%s</west>\n' "$BBOX_SOUTH" "$BBOX_WEST"
            printf '    </LatLonBox>\n  </GroundOverlay>\n'
        fi

        # Pin TX (verde) — relativeToGround
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

        # Pin RX (rojo) — relativeToGround — misma descripción
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

        # Segmentos de enlace — relativeToGround + AGL — misma descripción
        # Coherente con los pines: ambos usan el DEM de Google Earth como referencia,
        # evitando que la línea se hunda bajo el terreno de GE.
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

        # Pines de obstáculos
        echo -n "$OBS_PINS"

        printf '</Document>\n</kml>\n'
    } > "${OUTPATH}.kml"

    # -------- Crear KMZ --------
    KMZ_TMP="$(mktemp -d)"
    mkdir -p "${KMZ_TMP}/files"
    # El KML raíz debe llamarse doc.kml para que GE resuelva rutas "files/..." en descripciones
    cp "${OUTPATH}.kml"  "${KMZ_TMP}/doc.kml"
    cp "${OUTPATH}.txt"  "${KMZ_TMP}/${BASENAME}.txt"
    cp "${OUTPATH}.json" "${KMZ_TMP}/${BASENAME}.json"
    [[ -f "$PROFILE_PNG" ]]              && cp "$PROFILE_PNG" "${KMZ_TMP}/files/"
    [[ -n "$COV_PNG" && -f "$COV_PNG" ]] && cp "$COV_PNG"     "${KMZ_TMP}/files/"
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
# MODO COBERTURA DE AREA
# ============================================================
generate_dcf "${OUTPATH}.dcf"

TMPLOG="$(mktemp)"
{ time "$BINARY" -lid "$DTM_DIR" "${BINARY_ARGS[@]}" -dbg; } 2>"$TMPLOG"
_filter_log < "$TMPLOG" >&2

PPM="${OUTPATH}.ppm"
if [[ ! -f "$PPM" ]]; then
    echo "ERROR: fichero PPM no encontrado: $PPM" >&2; rm -f "$TMPLOG"; exit 1
fi

convert "$PPM" -transparent white "${OUTPATH}.png"
convert "$PPM" "${OUTPATH}.tiff"

BBOX="$(grep '^|' "$TMPLOG" | tail -1)" || true
rm -f "$TMPLOG"

if [[ -z "$BBOX" ]]; then
    echo "AVISO: bounding box no encontrado. KMZ no generado." >&2
    echo "Archivos generados: ${OUTPATH}.ppm  ${OUTPATH}.png  ${OUTPATH}.tiff  ${OUTPATH}.dcf" >&2
    exit 0
fi

IFS='|' read -ra PARTS <<< "$BBOX"
NORTH="${PARTS[1]}" EAST="${PARTS[2]}" SOUTH="${PARTS[3]}" WEST="${PARTS[4]}"

TX_LABEL="${TX_NAME:-TX}"
[[ -n "$TX_H" ]] && TX_LABEL="${TX_LABEL} (${TX_H}m AGL)"
RX_LABEL="${RX_NAME:-RX}"
[[ -n "$RX_H" ]] && RX_LABEL="${RX_LABEL} (${RX_H}m AGL)"

{
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<kml xmlns="http://www.opengis.net/kml/2.2">\n<Document><name>%s</name>\n' "$BASENAME"
    printf '  <GroundOverlay>\n    <name>Plot</name>\n'
    printf '    <Icon><href>files/%s.png</href></Icon>\n' "$BASENAME"
    printf '    <LatLonBox>\n'
    printf '      <north>%s</north>\n      <east>%s</east>\n' "$NORTH" "$EAST"
    printf '      <south>%s</south>\n      <west>%s</west>\n' "$SOUTH" "$WEST"
    printf '    </LatLonBox>\n  </GroundOverlay>\n'
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

# KMZ con estructura files/
KMZ_TMP="$(mktemp -d)"
mkdir -p "${KMZ_TMP}/files"
cp "${OUTPATH}.kml" "${KMZ_TMP}/${BASENAME}.kml"
cp "${OUTPATH}.png" "${KMZ_TMP}/files/${BASENAME}.png"
(cd "$KMZ_TMP" && zip -qr "${OUTPATH}.kmz" .)
rm -rf "$KMZ_TMP"

echo ""
echo "Archivos generados:"
echo "  ${OUTPATH}.ppm"
echo "  ${OUTPATH}.png"
echo "  ${OUTPATH}.tiff"
echo "  ${OUTPATH}.dcf"
echo "  ${OUTPATH}.kml"
echo "  ${OUTPATH}.kmz  <- Google Earth"
echo "Bounding box: N=${NORTH} E=${EAST} S=${SOUTH} W=${WEST}"
