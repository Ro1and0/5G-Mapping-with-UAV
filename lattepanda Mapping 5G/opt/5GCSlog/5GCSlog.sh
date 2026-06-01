#!/bin/bash

LOG_FILE="/tmp/mm_debug.log" # logs del modem 5g estando en modo debug
OUTPUT_FILE="/opt/5GCSlog/logs/metrics_$(date +'%Y%m%d_%H%M%S').json" # este es el archivo con la inf en json que se podria plotear al final
DEBUG_LOG="/tmp/metrics_debug_$(date +'%Y%m%d_%H%M%S').log" #aca se guardan debugs de este archivoi 5GCSlog.sh, no el json y no es MM debug

# Enviar salida estándar (stdout) y errores (stderr) a DEBUG_LOG,
# pero mantener la salida JSON limpia
exec 3>&1 1>>"$DEBUG_LOG" 2>&1

# Configuración
MODEM_LOG="/tmp/mm_debug.log"
IPERF_SERVER="192.168.88.10"   # Cambia por la IP de tu servidor iperf3
PING_HOST="192.168.88.10"            # Destino para medir RTT
SAMPLE_TIME=3 #sample time para tomar cada muestra; el minimo es 2s por la forma en la que leo el gps con "ros echo", el cual tiene un delay al inicio

source /opt/ros/humble/setup.bash
source /home/btu/ros2_ws/install/setup.bash
export ROS_DOMAIN_ID=1

echo "Waiting for Modem..."
while ! mmcli -m 0 >/dev/null 2>&1; do sleep 1; done && echo "Modem Ready"

echo "Apagar modem y correr en modo debug..."
#sudo systemctl stop ModemManager.service #esta es la que funcionaba antes, por ver si funciona pkill:
sudo pkill -f ModemManager
sleep 3

nohup sudo ModemManager --debug >> /tmp/mm_debug.log 2>&1 &
disown #nohup disown sirven para que la salida no se imprima cuando hago journalctl 5GCS_log.service -f aunque la verdad no funciona
echo "Iniciando ModemManager --debug ..."
sleep 12

# Función para leer métricas 5G del log de MM
get_nr_metrics() {
    # Tomar solo las últimas líneas del log para buscar lo más nuevo
    local rsrp="" rsrq="" snr=""
    local recent
    recent=$(tail -n 300 "$LOG_FILE")

    local line
    line=$(echo "$recent" | grep "translated = \[ rsrp" | tail -n 1)
    if [[ -n "$line" ]]; then
        rsrp=$(echo "$line" | grep -o "rsrp = '[^']*'" | awk -F"'" '{print $2}')
        local snr_raw
        snr_raw=$(echo "$line" | grep -o "snr = '[^']*'" | awk -F"'" '{print $2}')
        if [[ -n "$snr_raw" ]]; then
            snr=$(awk -v val="$snr_raw" 'BEGIN { printf "%.1f", val/10 }')
        fi
    fi
    # Buscar RSRQ: el bloque con "5G Signal Strength Extended"
    local rsrq_block
    rsrq_block=$(echo "$recent" | grep -A3 "type       = \"5G Signal Strength Extended\"" | tail -n 1)
    if [[ -n "$rsrq_block" ]]; then
        rsrq=$(echo "$rsrq_block" | awk '{print $4}')
    fi

    # Valores por defecto si no se encontró nada
    rsrp=${rsrp:-0}
    rsrq=${rsrq:-0}
    snr=${snr:-0}
    echo "$rsrp" "$rsrq" "$snr"
}

    # Función para obtener throughput iperf3 (un solo segundo)
get_iperf() {
    echo "inicio iperf"
    iperf3 -c "$IPERF_SERVER" -t 1 -J 2>/dev/null | \
    jq '.end.sum_received.bits_per_second' 2>/dev/null
    echo "fin iperf"
}

    # Función para medir RTT promedio de un ping corto
get_rtt() {
    ping -c 1 -W 0.1 "$PING_HOST" -I wwan0 2>/dev/null | \
    grep "time=" | awk -F'time=' '{print $2}' | awk '{print $1}'
}

# Función para leer última posición del tópico ROS2
get_position() {
    # Valores por defecto
    local lat="0.0"
    local lon="0.0"
    local alt="0.0"
    # Intentar leer datos de ROS2 (timeout 1 segundo)
    local ros2_data
    ros2_data=$(timeout $SAMPLE_TIME ros2 topic echo /lp3d5gbtu/global_position/global --once 2>/dev/null)
    if [[ -n "$ros2_data" ]]; then
        # Extraer valores si existen
        local lat_val lon_val alt_val
        lat_val=$(echo "$ros2_data" | grep "latitude" | awk '{print $2}')
        lon_val=$(echo "$ros2_data" | grep "longitude" | awk '{print $2}')
        alt_val=$(echo "$ros2_data" | grep "altitude" | awk '{print $2}')
        # Si hay valores válidos, usarlos
        [[ -n "$lat_val" ]] && lat="$lat_val"
        [[ -n "$lon_val" ]] && lon="$lon_val"
        [[ -n "$alt_val" ]] && alt="$alt_val"
    fi
    # Generar JSON de posición
    jq -nc --arg lat "$lat" \
           --arg lon "$lon" \
           --arg alt "$alt" \
           '{lat: ($lat|tonumber),
             lon: ($lon|tonumber),
             alt: ($alt|tonumber)}'
}

while ! mmcli -m 0 >/dev/null 2>&1; do 
    echo " [INFO] mmcli aun no detecta el modem..."
    sudo pkill ModemManager 2>dev/null
    sudo ModemManager --debug >> /tmp/mm_debug.log 2>&1 &
    echo "[INFO] ModemManager iniciando en modo debut"
    sleep 15
done
echo "[OK] Modem Listo en modo debug"


sudo ip addr add 192.168.6.25/28 dev wwan0
sleep 1
sudo ip addr del 192.168.6.25/30 dev wwan0
sleep 1

echo "launching iperf3 by Keyvan to save KPIs for TCP/IP tests"
source home/btu/ipref3Environment/myenv/bin/activate
python3 home/btu/ipref3Environment/Client/Client.py &


echo "Switching on Signal Reporting"
sudo mmcli -m 0 --signal-setup=1
while true; do
    timestamp=$(date +%s)
    timestamp_ms=$(date +%s%3N)
    time0=$(date +%s%3N)
    echo "$timestamp_ms time0"
    read rsrp rsrq snr <<< "$(get_nr_metrics)"
    #throughput=$(get_iperf)
    throughput="0.0"
    rtt=$(get_rtt)
    position=$(get_position)
    rsrp=${rsrp:-0}
    rsrq=${rsrq:-0}
    snr=${snr:-0}
    throughput=${throughput:-0}
    rtt=${rtt:-0}
    #echo "metricas , rtt, y gps leidos"
    echo "t=$timestamp pow=$rsrp qual=$rsrq nois=$snr pref=$throughput rtt=$rtt pos=$position"
    # Armar JSON
    json=$(jq -nc \
        --arg ts "$timestamp" \
        --arg rsrp "$rsrp" \
        --arg rsrq "$rsrq" \
        --arg snr "$snr" \
        --arg thr "$throughput" \
        --arg rtt "$rtt" \
        --argjson pos "$position" \
        '{timestamp: ($ts|tonumber),
          rsrp: ($rsrp|tonumber),
          rsrq: ($rsrq|tonumber),
          snr: ($snr|tonumber),
          throughput_bps: ($thr|tonumber),
          rtt_ms: ($rtt|tonumber),
          position: $pos }')

    echo "$json" >> "$OUTPUT_FILE"      # JSON al archivo de métricas

    end_ms=$(date +%s%3N)
    elapsed=$((end_ms - time0))
    # Calcular cuánto dormir (en ms)
    sleep_ms=$((1000*SAMPLE_TIME - elapsed))
    if (( sleep_ms > 0 )); then
        sleep_sec=$(awk -v ms="$sleep_ms" 'BEGIN { printf "%.3f", ms/1000 }')
        sleep "$sleep_sec"
    fi

done

