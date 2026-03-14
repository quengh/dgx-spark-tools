#!/usr/bin/env bash
# spark-netcfg.sh — DGX Spark 管理口网络配置工具
# 用于设置/查看/恢复管理网口 (enP7s7) 的 IP/网关/DNS
#
# Usage:
#   spark-netcfg.sh show                          # 查看当前配置
#   spark-netcfg.sh set IP/MASK GATEWAY [DNS]     # 设置静态 IP
#   spark-netcfg.sh dhcp                          # 恢复 DHCP
#
# Examples:
#   spark-netcfg.sh show
#   spark-netcfg.sh set 192.168.103.221/24 192.168.103.1 192.168.103.1
#   spark-netcfg.sh set 192.168.103.221/24 192.168.103.3 "192.168.103.3,223.5.5.5"
#   spark-netcfg.sh dhcp

set -euo pipefail

# ===== 配置 =====
IFACE="enP7s7"
# 自动检测 NetworkManager 连接名
CONN_NAME=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | grep ":${IFACE}$" | cut -d: -f1)

if [ -z "$CONN_NAME" ]; then
    echo "❌ 未找到 ${IFACE} 的活跃连接"
    echo "当前连接列表："
    nmcli -t -f NAME,DEVICE,TYPE con show --active
    exit 1
fi

RED="\033[31m"
GRN="\033[32m"
YEL="\033[33m"
CYN="\033[36m"
BOLD="\033[1m"
DIM="\033[2m"
RST="\033[0m"

show_config() {
    echo -e "${BOLD}${CYN}DGX Spark Network Config${RST}"
    echo -e "${DIM}──────────────────────────────────${RST}"
    echo -e "  Interface:   ${BOLD}${IFACE}${RST}"
    echo -e "  Connection:  ${CONN_NAME}"
    echo ""

    local method=$(nmcli -t -f ipv4.method con show "$CONN_NAME" | cut -d: -f2)
    local addrs=$(nmcli -t -f ipv4.addresses con show "$CONN_NAME" | cut -d: -f2)
    local gw=$(nmcli -t -f ipv4.gateway con show "$CONN_NAME" | cut -d: -f2)
    local dns=$(nmcli -t -f ipv4.dns con show "$CONN_NAME" | cut -d: -f2)

    # 实际生效的 IP
    local actual_ip=$(ip -4 addr show "$IFACE" 2>/dev/null | grep -oP 'inet \K[\d./]+')
    local actual_gw=$(ip route show default dev "$IFACE" 2>/dev/null | grep -oP 'via \K[\d.]+' | head -1)
    local actual_dns=$(resolvectl status "$IFACE" 2>/dev/null | grep "Current DNS Server" | awk '{print $NF}')
    local all_dns=$(resolvectl status "$IFACE" 2>/dev/null | grep "DNS Servers" | sed 's/.*DNS Servers: //')

    if [ "$method" = "auto" ]; then
        echo -e "  Mode:        ${GRN}DHCP${RST}"
        echo ""
        echo -e "  ${BOLD}当前地址（DHCP 分配）：${RST}"
        echo -e "    IP/Mask:   ${actual_ip:---}"
        echo -e "    Gateway:   ${actual_gw:---}"
        echo -e "    DNS:       ${actual_dns:---}"
    else
        echo -e "  Mode:        ${YEL}Static${RST}"
        echo ""
        echo -e "  ${BOLD}静态配置：${RST}"
        echo -e "    IP/Mask:   ${addrs:---}"
        echo -e "    Gateway:   ${gw:---}"
        echo -e "    DNS:       ${dns:---}"
        # 检查配置和实际是否一致
        if [ "$actual_ip" != "$addrs" ] || [ "$actual_gw" != "$gw" ]; then
            echo ""
            echo -e "  ${BOLD}实际生效值：${RST}"
            echo -e "    IP/Mask:   ${actual_ip:---}"
            echo -e "    Gateway:   ${actual_gw:---}"
            echo -e "    DNS:       ${actual_dns:---}"
        fi
    fi
    if [ -n "$all_dns" ] && [ "$all_dns" != "$actual_dns" ]; then
        echo -e "    DNS (all): ${DIM}${all_dns}${RST}"
    fi
    echo ""
}

set_static() {
    local ip_mask="$1"
    local gateway="$2"
    local dns="${3:-}"

    # 验证 IP 格式
    if ! echo "$ip_mask" | grep -qP '^\d+\.\d+\.\d+\.\d+/\d+$'; then
        echo "❌ IP 格式错误，需要 x.x.x.x/mask 格式，如 192.168.103.221/24"
        exit 1
    fi

    # 验证网关格式
    if ! echo "$gateway" | grep -qP '^\d+\.\d+\.\d+\.\d+$'; then
        echo "❌ 网关格式错误，如 192.168.103.1"
        exit 1
    fi

    echo -e "${BOLD}设置静态 IP${RST}"
    echo -e "  Interface:  ${IFACE}"
    echo -e "  Connection: ${CONN_NAME}"
    echo -e "  IP/Mask:    ${CYN}${ip_mask}${RST}"
    echo -e "  Gateway:    ${CYN}${gateway}${RST}"
    echo -e "  DNS:        ${CYN}${dns:-auto}${RST}"
    echo ""

    # 备份当前配置
    local backup_file="/tmp/spark-netcfg-backup-$(date +%Y%m%d%H%M%S).txt"
    nmcli con show "$CONN_NAME" > "$backup_file" 2>/dev/null
    echo -e "${DIM}当前配置已备份到 ${backup_file}${RST}"

    # 应用配置（必须一条命令同时设 method + address，否则 NM 报错）
    local use_dns="${dns:-$gateway}"
    sudo nmcli con mod "$CONN_NAME" \
        ipv4.method manual \
        ipv4.addresses "$ip_mask" \
        ipv4.gateway "$gateway" \
        ipv4.dns "$use_dns"

    echo -e "${YEL}正在重新激活连接...${RST}"
    sudo nmcli con up "$CONN_NAME" 2>&1 || true

    sleep 2
    echo ""
    echo -e "${GRN}✅ 配置完成${RST}"
    echo ""
    show_config
}

set_dhcp() {
    echo -e "${BOLD}恢复 DHCP${RST}"
    echo -e "  Interface:  ${IFACE}"
    echo -e "  Connection: ${CONN_NAME}"
    echo ""

    sudo nmcli con mod "$CONN_NAME" ipv4.method auto
    sudo nmcli con mod "$CONN_NAME" ipv4.addresses ""
    sudo nmcli con mod "$CONN_NAME" ipv4.gateway ""
    sudo nmcli con mod "$CONN_NAME" ipv4.dns ""

    echo -e "${YEL}正在重新激活连接...${RST}"
    sudo nmcli con up "$CONN_NAME" 2>&1 || true

    sleep 3
    echo ""
    echo -e "${GRN}✅ 已恢复 DHCP${RST}"
    echo ""
    show_config
}

# ===== Main =====
case "${1:-show}" in
    show|status|info)
        show_config
        ;;
    set|static)
        if [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
            echo "Usage: $0 set IP/MASK GATEWAY [DNS]"
            echo "Example: $0 set 192.168.103.221/24 192.168.103.1 192.168.103.1"
            exit 1
        fi
        set_static "$2" "$3" "${4:-}"
        ;;
    dhcp|auto)
        set_dhcp
        ;;
    -h|--help|help)
        echo "DGX Spark 管理口网络配置工具"
        echo ""
        echo "Usage:"
        echo "  $0 show                          查看当前配置"
        echo "  $0 set IP/MASK GATEWAY [DNS]     设置静态 IP"
        echo "  $0 dhcp                          恢复 DHCP"
        echo ""
        echo "Examples:"
        echo "  $0 set 192.168.103.221/24 192.168.103.3 192.168.103.3"
        echo "  $0 set 192.168.10.50/24 192.168.10.1 \"192.168.10.1,223.5.5.5\""
        echo "  $0 dhcp"
        ;;
    *)
        echo "未知命令: $1"
        echo "Usage: $0 {show|set|dhcp|help}"
        exit 1
        ;;
esac
