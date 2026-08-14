#!/bin/bash

# ----------------- Colors -----------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# ----------------- Constants -----------------
NETPLAN_FILE="/etc/netplan/gre-tunnel.yaml"
SERVICE_NAME="gretunnel-connector.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
CONNECTOR_SCRIPT="/root/gre-connector.sh"
TUNNEL_NAME="gre0858"

# ----------------- Root check -----------------
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Fatal error:${NC} Please run this script with root privilege.\n"
    exit 1
fi

install_jq() {
    if command -v jq &> /dev/null; then
        return
    fi

    if command -v apt-get &> /dev/null; then
        echo -e "${YELLOW}jq is not installed. Installing...${NC}"
        apt-get update
        apt-get install -y jq
    else
        echo -e "${RED}Error:${NC} Unsupported package manager. Please install jq manually."
        exit 1
    fi
}

netplan_setup() {
    if command -v netplan &> /dev/null; then
        return
    fi

    if command -v apt-get &> /dev/null; then
        echo -e "${YELLOW}netplan is not installed. Installing...${NC}"
        apt-get update
        apt-get install -y netplan.io
    else
        echo -e "${RED}Error:${NC} netplan is not installed and automatic installation is only supported with apt-get."
        exit 1
    fi
}

check_core_status() {
    if [ -f "$NETPLAN_FILE" ] && ip link show "$TUNNEL_NAME" &>/dev/null; then
        echo "Installed"
    else
        echo "Not installed"
    fi
}

# Generates a private /30 GRE subnet base such as 10.73.142.0
# IRAN = .1, KHAREJ = .2
generate_gre_subnet() {
    local oct2 oct3
    oct2=$((RANDOM % 256))
    oct3=$(((RANDOM % 63) * 4))
    echo "10.${oct2}.${oct3}"
}

get_tunnel_ipv4() {
    if ip link show "$TUNNEL_NAME" &>/dev/null; then
        ip -4 addr show dev "$TUNNEL_NAME" 2>/dev/null \
            | awk '/inet / {print $2}' \
            | cut -d/ -f1 \
            | head -n1
    fi
}

create_service() {
    cat > "$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=GRE Tunnel Keepalive Connector
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash $CONNECTOR_SCRIPT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_SERVICE

    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"
}

remove_service() {
    if systemctl is-enabled "$SERVICE_NAME" &>/dev/null; then
        systemctl disable --now "$SERVICE_NAME"
    else
        systemctl stop "$SERVICE_NAME" &>/dev/null || true
    fi

    [ -f "$SERVICE_FILE" ] && rm -f "$SERVICE_FILE"
    systemctl daemon-reload
}

ensure_systemd_networkd() {
    if ! systemctl list-unit-files | grep -q '^systemd-networkd.service'; then
        echo -e "${YELLOW}systemd-networkd.service not found. Skipping networkd check.${NC}"
        return
    fi

    systemctl unmask systemd-networkd.service 2>/dev/null || true
    systemctl enable --now systemd-networkd.service 2>/dev/null || {
        echo -e "${RED}Failed to enable/start systemd-networkd.${NC}"
        return 1
    }
}

apply_netplan_safe() {
    netplan_setup
    ensure_systemd_networkd || return 1

    echo -e "${YELLOW}Checking netplan configuration...${NC}"
    if ! netplan generate 2>/tmp/netplan_error.log; then
        echo -e "${RED}netplan generate failed!${NC}"
        cat /tmp/netplan_error.log
        return 1
    fi

    echo -e "${YELLOW}Applying netplan...${NC}"
    if ! netplan apply 2>/tmp/netplan_error.log; then
        echo -e "${RED}netplan apply failed!${NC}"
        echo "------ netplan error output ------"
        cat /tmp/netplan_error.log
        echo "----------------------------------"
        return 1
    fi
}

valid_ipv4() {
    local ip=$1 IFS=.
    local -a octets
    read -ra octets <<< "$ip"
    [[ ${#octets[@]} -eq 4 ]] || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        ((octet >= 0 && octet <= 255)) || return 1
    done
}

gv_menu() {
    clear

    local SERVER_IP SERVER_COUNTRY SERVER_ISP IP_INFO
    SERVER_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    [ -z "$SERVER_IP" ] && SERVER_IP=$(hostname -I | awk '{print $1}')
    SERVER_COUNTRY="Unknown"
    SERVER_ISP="Unknown"

    if command -v curl &>/dev/null && command -v jq &>/dev/null; then
        IP_INFO=$(curl -fsS --max-time 4 "http://ip-api.com/json/$SERVER_IP" 2>/dev/null || true)
        if [ -n "$IP_INFO" ]; then
            SERVER_COUNTRY=$(echo "$IP_INFO" | jq -r '.country // "Unknown"')
            SERVER_ISP=$(echo "$IP_INFO" | jq -r '.isp // "Unknown"')
        fi
    fi

    local GRE_CORE TUN_IPV4 core_color
    GRE_CORE=$(check_core_status)
    TUN_IPV4=$(get_tunnel_ipv4)

    if [ "$GRE_CORE" = "Installed" ]; then
        core_color="$GREEN"
    else
        core_color="$RED"
    fi

    echo "+-------------------------------------------------------------------------+"
    echo "|                              GRE TUNNEL                                 |"
    echo "|                                                       version :  1.0.0  |"
    echo "+-------------------------------------------------------------------------+"
    echo -e "|${GREEN}Server Country    |${NC} $SERVER_COUNTRY"
    echo -e "|${GREEN}Server ISP        |${NC} $SERVER_ISP"
    echo -e "|${GREEN}Server IP         |${NC} $SERVER_IP"
    if [ -n "$TUN_IPV4" ]; then
        echo -e "|${GREEN}Tunnel IPv4       |${NC} $TUN_IPV4"
    fi
    echo -e "|${GREEN}GRE Tunnel        |${NC} ${core_color}${GRE_CORE}${NC}"
    echo "+-------------------------------------------------------------------------+"
    echo -e "|${YELLOW}Please choose an option:${NC}"
    echo "+-------------------------------------------------------------------------+"
    echo -e "$1"
    echo "+-------------------------------------------------------------------------+"
    echo -e "${NC}"
}

check_service_status() {
    gv_menu "| 3  - Check Service Status\n"

    echo "----- GRE interface -----"
    if ip link show "$TUNNEL_NAME" &>/dev/null; then
        ip -d link show "$TUNNEL_NAME"
        ip -4 addr show dev "$TUNNEL_NAME"
    else
        echo -e "${RED}GRE interface not found.${NC}"
    fi

    echo
    echo "----- $SERVICE_NAME status -----"
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}Service is ACTIVE${NC}"
    else
        echo -e "${RED}Service is INACTIVE or not installed${NC}"
    fi

    systemctl --no-pager --full status "$SERVICE_NAME" 2>/dev/null | sed -n '1,15p'
    echo
    read -rp "Press Enter to go back to menu..."
}

setup_tunnel() {
    local role="$1"
    local iran_ip kharej_ip subnet
    local local_public_ip remote_public_ip
    local local_tunnel_ip remote_tunnel_ip
    local side_text other_side_text

    read -rp "Enter IRAN Public IPv4         : " iran_ip
    read -rp "Enter Kharej Public IPv4       : " kharej_ip

    if ! valid_ipv4 "$iran_ip" || ! valid_ipv4 "$kharej_ip"; then
        echo -e "${RED}Invalid IPv4 address.${NC}"
        read -rp "Press Enter to return to menu..."
        return 1
    fi

    case "$role" in
        iran)
            local_public_ip="$iran_ip"
            remote_public_ip="$kharej_ip"
            side_text="IRAN GRE IPv4"
            other_side_text="Use the same GRE subnet on the KHAREJ side"
            ;;
        kharej)
            local_public_ip="$kharej_ip"
            remote_public_ip="$iran_ip"
            side_text="Kharej GRE IPv4"
            other_side_text="Use the same GRE subnet on the IRAN side"
            ;;
        *)
            echo "Unknown role: $role"
            return 1
            ;;
    esac

    echo
    echo "GRE internal subnet example: 10.50.100"
    echo "IRAN will use .1/30 and KHAREJ will use .2/30"
    read -rp "Enter GRE subnet base (blank = auto): " subnet

    if [ -z "$subnet" ]; then
        subnet=$(generate_gre_subnet)
        echo -e "${YELLOW}Auto-generated GRE subnet:${NC} ${subnet}.0/30"
    else
        subnet="${subnet%.}"
        if ! [[ "$subnet" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ ]]; then
            echo -e "${RED}Invalid subnet base. Example: 10.50.100${NC}"
            read -rp "Press Enter to return to menu..."
            return 1
        fi
    fi

    if [ "$role" = "iran" ]; then
        local_tunnel_ip="${subnet}.1"
        remote_tunnel_ip="${subnet}.2"
    else
        local_tunnel_ip="${subnet}.2"
        remote_tunnel_ip="${subnet}.1"
    fi

    # Load GRE kernel module when available
    modprobe ip_gre 2>/dev/null || true

    cat > "$NETPLAN_FILE" <<EOF_NETPLAN
network:
  version: 2
  renderer: networkd
  tunnels:
    $TUNNEL_NAME:
      mode: gre
      local: $local_public_ip
      remote: $remote_public_ip
      addresses:
        - ${local_tunnel_ip}/30
EOF_NETPLAN

    chmod 600 "$NETPLAN_FILE"

    if ! apply_netplan_safe; then
        echo -e "${RED}GRE configuration could not be applied.${NC}"
        read -rp "Press Enter to return to menu..."
        return 1
    fi

    cat > "$CONNECTOR_SCRIPT" <<EOF_CONNECTOR
#!/bin/bash
REMOTE_TUNNEL_IP="$remote_tunnel_ip"
TUNNEL_NAME="$TUNNEL_NAME"

while true; do
    if ip link show "\$TUNNEL_NAME" &>/dev/null; then
        ping -4 -I "\$TUNNEL_NAME" -c 3 -W 2 "\$REMOTE_TUNNEL_IP" >/dev/null 2>&1 || true
    fi
    sleep 5
done
EOF_CONNECTOR

    chmod +x "$CONNECTOR_SCRIPT"
    create_service

    echo
    echo -e "${GREEN}GRE tunnel configured successfully.${NC}"
    echo "############################################"
    printf "# %-24s : %-14s #\n" "$side_text" "$local_tunnel_ip"
    printf "# %-24s : %-14s #\n" "Remote GRE IPv4" "$remote_tunnel_ip"
    echo "############################################"
    echo
    echo "$other_side_text: ${subnet}.0/30"
    echo -e "${YELLOW}Important:${NC} GRE uses IP protocol 47. Make sure it is allowed by both servers/provider firewalls."
    echo
    read -rp "Press Enter to return to menu..."
}

install_tunnel() {
    gv_menu "| 1  - IRAN\n| 2  - Kharej\n| 0  - Back"

    read -rp "Enter option number: " setup
    case $setup in
        1) setup_tunnel "iran" ;;
        2) setup_tunnel "kharej" ;;
        0) return ;;
        *) echo "Not valid"; sleep 1 ;;
    esac
}

uninstall_tunnel() {
    echo -e "${GREEN}Uninstalling GRE tunnel in 3 seconds...${NC}"
    sleep 1 && echo -e "${GREEN}2...${NC}"
    sleep 1 && echo -e "${GREEN}1...${NC}"
    sleep 1

    remove_service
    [ -f "$NETPLAN_FILE" ] && rm -f "$NETPLAN_FILE"
    [ -f "$CONNECTOR_SCRIPT" ] && rm -f "$CONNECTOR_SCRIPT"

    netplan generate >/dev/null 2>&1 || true
    netplan apply >/dev/null 2>&1 || true

    # Remove leftover interface if it still exists
    ip link del "$TUNNEL_NAME" 2>/dev/null || true

    clear
    echo 'GRE Tunnel Uninstalled.'
}

loader() {
    gv_menu "| 1  - Config GRE Tunnel\n| 2  - Uninstall\n| 3  - Check Service\n| 0  - Exit"

    read -rp "Enter option number: " choice
    case $choice in
        1) install_tunnel ;;
        2) uninstall_tunnel ;;
        3) check_service_status ;;
        0)
            echo -e "${GREEN}Exiting program...${NC}"
            exit 0
            ;;
        *)
            echo "Not valid"
            sleep 1
            ;;
    esac
}

init() {
    install_jq
    netplan_setup

    if ! command -v ip &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            echo -e "${YELLOW}iproute2 is not installed. Installing...${NC}"
            apt-get update
            apt-get install -y iproute2
        else
            echo -e "${RED}Error:${NC} 'ip' command is required."
            exit 1
        fi
    fi

    modprobe ip_gre 2>/dev/null || true
}

# ---- main ----
init
while true; do
    loader
done
