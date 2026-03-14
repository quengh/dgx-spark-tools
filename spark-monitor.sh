#!/usr/bin/env bash
# spark-monitor.sh — DGX Spark TUI Monitor
# Usage: ./spark-monitor.sh [interval_seconds]
# Default interval: 2 seconds

INTERVAL=${1:-2}

# Colors
BOLD="\033[1m"
DIM="\033[2m"
RST="\033[0m"
RED="\033[31m"
YEL="\033[33m"
GRN="\033[32m"
CYN="\033[36m"
WHT="\033[37m"
BLU="\033[34m"
MAG="\033[35m"

# Network interfaces to monitor
NET_IFACES=(enP7s7 enp1s0f0np0 enp1s0f1np1 enP2p1s0f0np0 enP2p1s0f1np1)
NET_LABELS=("Mgmt 2.5G" "QSFP-1 200G" "QSFP-2 200G" "QSFP-3 200G" "QSFP-4 200G")

# Previous network counters (for rate calc)
declare -A PREV_RX PREV_TX

temp_color() {
    local t=$1
    if [ "$t" -ge 85 ]; then echo -e "${RED}${BOLD}"
    elif [ "$t" -ge 70 ]; then echo -e "${YEL}"
    else echo -e "${GRN}"
    fi
}

bar() {
    local val=$1 max=$2 width=${3:-30}
    local filled=$(( val * width / max ))
    [ $filled -gt $width ] && filled=$width
    local empty=$(( width - filled ))
    local pct=$(( val * 100 / max ))
    local bar_color
    if [ $pct -ge 80 ]; then bar_color="${RED}"
    elif [ $pct -ge 50 ]; then bar_color="${YEL}"
    else bar_color="${GRN}"
    fi
    printf "${bar_color}"
    for ((i=0; i<filled; i++)); do printf '█'; done
    printf "${DIM}"
    for ((i=0; i<empty; i++)); do printf '░'; done
    printf "${RST}"
}

# Format bytes/s to human readable
fmt_rate() {
    local bps=$1
    if [ "$bps" -ge 1073741824 ]; then
        printf "%.1f GB/s" "$(echo "$bps / 1073741824" | bc -l)"
    elif [ "$bps" -ge 1048576 ]; then
        printf "%.1f MB/s" "$(echo "$bps / 1048576" | bc -l)"
    elif [ "$bps" -ge 1024 ]; then
        printf "%.1f KB/s" "$(echo "$bps / 1024" | bc -l)"
    else
        printf "%d B/s" "$bps"
    fi
}

fmt_uptime() {
    local secs=$(cut -d. -f1 /proc/uptime)
    local days=$((secs / 86400))
    local hrs=$(( (secs % 86400) / 3600 ))
    local mins=$(( (secs % 3600) / 60 ))
    echo "${days}d ${hrs}h ${mins}m"
}

HOST=$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "spark")

while true; do
    # --- Gather GPU data ---
    GPU_DATA=$(nvidia-smi --query-gpu=temperature.gpu,power.draw,utilization.gpu,clocks.current.graphics,clocks.max.graphics --format=csv,noheader,nounits 2>/dev/null)
    GPU_TEMP=$(echo "$GPU_DATA" | cut -d',' -f1 | tr -d ' ')
    GPU_POWER=$(echo "$GPU_DATA" | cut -d',' -f2 | tr -d ' ')
    GPU_UTIL=$(echo "$GPU_DATA" | cut -d',' -f3 | tr -d ' ')
    GPU_CLK=$(echo "$GPU_DATA" | cut -d',' -f4 | tr -d ' ')
    GPU_CLK_MAX=$(echo "$GPU_DATA" | cut -d',' -f5 | tr -d ' ')
    GPU_POWER_INT=${GPU_POWER%.*}; [ -z "$GPU_POWER_INT" ] && GPU_POWER_INT=0
    GPU_TEMP_INT=${GPU_TEMP:-0}

    # --- Fan ---
    # Note: DGX Spark fan is controlled by closed-source EC firmware.
    # No fan speed sensor is exposed to Linux userspace.
    FAN_LEVEL="N/A"

    # --- Thermal sensors ---
    # SoC zones (acpitz) — multiple unnamed zones across GB10 die
    SOC_TEMPS=(); SOC_MAX=0; SOC_MIN=999
    for z in /sys/class/thermal/thermal_zone*; do
        t=$(($(cat "$z/temp" 2>/dev/null) / 1000))
        SOC_TEMPS+=($t)
        [ $t -gt $SOC_MAX ] && SOC_MAX=$t
        [ $t -lt $SOC_MIN ] && SOC_MIN=$t
    done
    # NVMe
    NVME_TEMP=$(cat /sys/class/hwmon/hwmon1/temp1_input 2>/dev/null)
    NVME_TEMP=${NVME_TEMP:+$((NVME_TEMP / 1000))}
    NVME_TEMP=${NVME_TEMP:-N/A}
    # ConnectX-7 NIC (ASIC)
    NIC_TEMP=$(cat /sys/class/hwmon/hwmon2/temp1_input 2>/dev/null)
    NIC_TEMP=${NIC_TEMP:+$((NIC_TEMP / 1000))}
    NIC_TEMP=${NIC_TEMP:-N/A}
    # ConnectX-7 QSFP Module (if present)
    QSFP_TEMP=$(cat /sys/class/hwmon/hwmon3/temp2_input 2>/dev/null)
    QSFP_TEMP=${QSFP_TEMP:+$((QSFP_TEMP / 1000))}
    QSFP_TEMP=${QSFP_TEMP:-N/A}

    # --- CPU usage ---
    # /proc/stat: cpu user nice system idle iowait irq softirq steal ...
    read -r _ cpu_user cpu_nice cpu_sys cpu_idle cpu_iow cpu_irq cpu_sirq cpu_steal _ < /proc/stat
    total=$((cpu_user + cpu_nice + cpu_sys + cpu_idle + cpu_iow + cpu_irq + cpu_sirq + cpu_steal))
    idle=$((cpu_idle + cpu_iow))
    if [ -n "$PREV_CPU_TOTAL" ]; then
        diff_total=$((total - PREV_CPU_TOTAL))
        diff_idle=$((idle - PREV_CPU_IDLE))
        if [ $diff_total -gt 0 ]; then
            CPU_UTIL=$((100 * (diff_total - diff_idle) / diff_total))
        else
            CPU_UTIL=0
        fi
    else
        CPU_UTIL=0
    fi
    PREV_CPU_TOTAL=$total; PREV_CPU_IDLE=$idle

    # --- Memory ---
    MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print int($2/1048576)}')
    MEM_AVAIL=$(grep MemAvailable /proc/meminfo | awk '{print int($2/1048576)}')
    MEM_USED=$((MEM_TOTAL - MEM_AVAIL))
    MEM_PCT=$((MEM_USED * 100 / MEM_TOTAL))

    # --- Network rates ---
    declare -A CUR_RX CUR_TX NET_RX_RATE NET_TX_RATE
    for iface in "${NET_IFACES[@]}"; do
        if [ -d "/sys/class/net/$iface" ]; then
            CUR_RX[$iface]=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null)
            CUR_TX[$iface]=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null)
            if [ -n "${PREV_RX[$iface]}" ]; then
                NET_RX_RATE[$iface]=$(( (${CUR_RX[$iface]} - ${PREV_RX[$iface]}) / INTERVAL ))
                NET_TX_RATE[$iface]=$(( (${CUR_TX[$iface]} - ${PREV_TX[$iface]}) / INTERVAL ))
            else
                NET_RX_RATE[$iface]=0
                NET_TX_RATE[$iface]=0
            fi
            PREV_RX[$iface]=${CUR_RX[$iface]}
            PREV_TX[$iface]=${CUR_TX[$iface]}
        fi
    done

    # --- Process count ---
    VLLM_PROCS=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | wc -l)

    LOADAVG=$(cut -d' ' -f1-3 /proc/loadavg)
    UPTIME=$(fmt_uptime)
    NOW=$(date '+%Y-%m-%d %H:%M:%S')

    # =========== Render ===========
    clear

    # Title bar
    echo ""
    echo -e "  ⚡ ${BOLD}${CYN}DGX Spark Monitor${RST} — ${WHT}${HOST}${RST}  ${DIM}${NOW}${RST}"
    echo -e "  ${CYN}$(printf -- '─%.0s' $(seq 1 58))${RST}"
    echo ""

    # --- GPU ---
    echo -e "  ${BOLD}${MAG}🔲 GPU${RST} ${DIM}NVIDIA GB10${RST}"
    tc=$(temp_color $GPU_TEMP_INT)
    printf "    🌡  Temp     ${tc}%3d°C${RST}    " "$GPU_TEMP_INT"
    bar $GPU_TEMP_INT 100 30; echo ""

    printf "    ⚡ Power   %5.1fW    " "$GPU_POWER"
    bar $GPU_POWER_INT 100 30; echo ""

    printf "    📊 Util     %3d%%     " "$GPU_UTIL"
    bar $GPU_UTIL 100 30; echo ""

    printf "    🔄 Clock   %4s / %4s MHz\n" "$GPU_CLK" "$GPU_CLK_MAX"

    printf "    🔧 Procs    ${BOLD}%d${RST} GPU compute\n" "$VLLM_PROCS"
    echo ""

    # --- CPU ---
    echo -e "  ${BOLD}${BLU}🖥  CPU${RST} ${DIM}20-core ARM (Cortex-X925 + A725)${RST}"
    printf "    📊 Util     %3d%%     " "$CPU_UTIL"
    bar $CPU_UTIL 100 30; echo ""
    printf "    📈 Load    %s\n" "$LOADAVG"
    echo ""

    # --- Thermal ---
    echo -e "  ${BOLD}${RED}🌡  THERMAL${RST}"
    tc=$(temp_color $SOC_MAX)
    printf "    🧠 SoC      ${tc}%d°C${RST}  ${DIM}(${SOC_MIN}~${SOC_MAX}°C across ${#SOC_TEMPS[@]} zones)${RST}\n" "$SOC_MAX"
    if [ "$NVME_TEMP" != "N/A" ]; then
        ntc=$(temp_color $NVME_TEMP)
        printf "    💽 NVMe     ${ntc}%d°C${RST}\n" "$NVME_TEMP"
    fi
    if [ "$NIC_TEMP" != "N/A" ]; then
        ctc=$(temp_color $NIC_TEMP)
        printf "    🔌 CX-7     ${ctc}%d°C${RST}\n" "$NIC_TEMP"
    fi
    if [ "$QSFP_TEMP" != "N/A" ]; then
        qtc=$(temp_color $QSFP_TEMP)
        printf "    🔗 QSFP     ${qtc}%d°C${RST}\n" "$QSFP_TEMP"
    fi
    printf "    🌀 Fan      ${DIM}EC-controlled (not readable)${RST}\n"
    echo ""

    # --- Memory ---
    echo -e "  ${BOLD}${GRN}💾 MEMORY${RST} ${DIM}(Unified CPU+GPU)${RST}"
    printf "    📦 %dG / %dG (%d%%)  " "$MEM_USED" "$MEM_TOTAL" "$MEM_PCT"
    bar $MEM_PCT 100 30; echo ""
    echo ""

    # --- Network ---
    echo -e "  ${BOLD}${CYN}🌐 NETWORK${RST}"
    idx=0
    for iface in "${NET_IFACES[@]}"; do
        if [ -d "/sys/class/net/$iface" ]; then
            state=$(cat /sys/class/net/$iface/operstate 2>/dev/null)
            label="${NET_LABELS[$idx]}"
            rx_rate=${NET_RX_RATE[$iface]:-0}
            tx_rate=${NET_TX_RATE[$iface]:-0}
            rx_str=$(fmt_rate $rx_rate)
            tx_str=$(fmt_rate $tx_rate)

            if [ "$state" = "up" ]; then
                state_str="${GRN}●${RST}"
            else
                state_str="${RED}○${RST}"
            fi

            printf "    %b %-13s  ⬇ %-12s  ⬆ %-12s\n" "$state_str" "$label" "$rx_str" "$tx_str"
        fi
        idx=$((idx+1))
    done
    echo ""

    echo -e "  ${DIM}Uptime: ${UPTIME}  │  Refresh: ${INTERVAL}s  │  Ctrl+C to exit${RST}"

    sleep "$INTERVAL"
done
