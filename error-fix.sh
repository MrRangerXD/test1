#!/bin/bash

# ============================================================
# AetherCloud VMB
# error-fix.sh
# ============================================================

set +e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

clear 2>/dev/null || true

echo -e "${MAGENTA}${BOLD}"
echo "============================================================"
echo "                 AETHERCLOUD ERROR FIX"
echo "============================================================"
echo -e "${NC}"

# ------------------------------------------------------------
# ROOT CHECK
# ------------------------------------------------------------

if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}[ERROR]${NC} Please run this script as root."
    exit 1
fi

if ! command -v lxc >/dev/null 2>&1; then
    echo -e "${RED}[ERROR]${NC} LXD/LXC command not found."
    exit 1
fi

# ------------------------------------------------------------
# CONTAINER INPUT
# ------------------------------------------------------------

echo
echo -e "${CYAN}${BOLD}Enter Container Name -> ${NC}"
read -r CT

if [ -z "$CT" ]; then
    echo -e "${RED}[ERROR]${NC} Container name cannot be empty."
    exit 1
fi

echo
echo -e "${CYAN}[*] Checking container...${NC}"

if ! lxc info "$CT" >/dev/null 2>&1; then
    echo -e "${RED}[ERROR]${NC} Container '$CT' not found."
    echo
    echo "Available containers:"
    lxc list
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Container found: $CT"

# ------------------------------------------------------------
# START CONTAINER
# ------------------------------------------------------------

STATUS=$(lxc list "$CT" --format csv -c s 2>/dev/null)

if [ "$STATUS" != "RUNNING" ]; then
    echo -e "${YELLOW}[!]${NC} Container is stopped."
    echo -e "${CYAN}[*] Starting container...${NC}"

    lxc start "$CT"
    sleep 5

    STATUS=$(lxc list "$CT" --format csv -c s 2>/dev/null)

    if [ "$STATUS" = "RUNNING" ]; then
        echo -e "${GREEN}[OK]${NC} Container started."
    else
        echo -e "${RED}[ERROR]${NC} Could not start container."
        exit 1
    fi
else
    echo -e "${GREEN}[OK]${NC} Container is running."
fi

# ------------------------------------------------------------
# DETECT LXD NETWORK
# ------------------------------------------------------------

echo
echo -e "${CYAN}[*] Detecting container network...${NC}"

LXD_NETWORK=$(lxc config device get "$CT" eth0 network 2>/dev/null)

if [ -z "$LXD_NETWORK" ]; then
    LXD_NETWORK="lxdbr0"
fi

if ! lxc network show "$LXD_NETWORK" >/dev/null 2>&1; then
    echo -e "${RED}[ERROR]${NC} Network '$LXD_NETWORK' not found."
    echo
    lxc network list
    exit 1
fi

echo -e "${GREEN}[OK]${NC} LXD Network: $LXD_NETWORK"

# ------------------------------------------------------------
# DETECT HOST INTERFACE
# ------------------------------------------------------------

HOST_IFACE=$(ip -4 route get 1.1.1.1 2>/dev/null |
    awk '{
        for(i=1;i<=NF;i++)
            if($i=="dev") {
                print $(i+1)
                exit
            }
    }')

if [ -z "$HOST_IFACE" ]; then
    HOST_IFACE="eth0"
fi

echo -e "${GREEN}[OK]${NC} Host Interface: $HOST_IFACE"

# ------------------------------------------------------------
# DETECT LXD ADDRESS / SUBNET
# ------------------------------------------------------------

LXD_ADDRESS=$(lxc network get "$LXD_NETWORK" ipv4.address 2>/dev/null)

if [ -z "$LXD_ADDRESS" ]; then
    echo -e "${YELLOW}[!]${NC} IPv4 address missing on $LXD_NETWORK."

    if [ "$LXD_NETWORK" = "lxdbr0" ]; then
        lxc network set "$LXD_NETWORK" ipv4.address 10.63.232.1/24
        LXD_ADDRESS="10.63.232.1/24"
    else
        echo -e "${RED}[ERROR]${NC} Cannot safely determine custom network subnet."
        exit 1
    fi
fi

LXD_IP="${LXD_ADDRESS%/*}"

LXD_PREFIX="${LXD_ADDRESS#*/}"

# IPv4 /24 subnet detection
if [ "$LXD_PREFIX" = "24" ]; then
    LXD_SUBNET=$(echo "$LXD_IP" | awk -F. '{print $1"."$2"."$3".0"}')
else
    LXD_SUBNET=$(ipcalc -n "$LXD_ADDRESS" 2>/dev/null |
        awk -F': ' '/Network/ {print $2}' |
        cut -d/ -f1)

    if [ -z "$LXD_SUBNET" ]; then
        LXD_SUBNET=$(echo "$LXD_IP" | awk -F. '{print $1"."$2"."$3".0"}')
    fi
fi

echo -e "${GREEN}[OK]${NC} LXD Address: $LXD_ADDRESS"
echo -e "${GREEN}[OK]${NC} LXD Subnet: ${LXD_SUBNET}/${LXD_PREFIX}"

# ------------------------------------------------------------
# ENABLE NAT
# ------------------------------------------------------------

echo
echo -e "${CYAN}[*] Enabling LXD IPv4 NAT...${NC}"

lxc network set "$LXD_NETWORK" ipv4.nat true 2>/dev/null

echo -e "${GREEN}[OK]${NC} IPv4 NAT enabled."

# ------------------------------------------------------------
# IP FORWARDING
# ------------------------------------------------------------

echo
echo -e "${CYAN}[*] Enabling IPv4 forwarding...${NC}"

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1

mkdir -p /etc/sysctl.d

cat > /etc/sysctl.d/99-aethercloud-ip-forward.conf <<EOF
net.ipv4.ip_forward=1
EOF

echo -e "${GREEN}[OK]${NC} IPv4 forwarding enabled."

# ------------------------------------------------------------
# FORWARD RULES
# ------------------------------------------------------------

echo
echo -e "${CYAN}[*] Repairing firewall forwarding...${NC}"

iptables -C FORWARD \
    -i "$LXD_NETWORK" \
    -o "$HOST_IFACE" \
    -j ACCEPT 2>/dev/null

if [ $? -ne 0 ]; then
    iptables -I FORWARD 1 \
        -i "$LXD_NETWORK" \
        -o "$HOST_IFACE" \
        -j ACCEPT
fi

iptables -C FORWARD \
    -i "$HOST_IFACE" \
    -o "$LXD_NETWORK" \
    -m conntrack \
    --ctstate RELATED,ESTABLISHED \
    -j ACCEPT 2>/dev/null

if [ $? -ne 0 ]; then
    iptables -I FORWARD 1 \
        -i "$HOST_IFACE" \
        -o "$LXD_NETWORK" \
        -m conntrack \
        --ctstate RELATED,ESTABLISHED \
        -j ACCEPT
fi

echo -e "${GREEN}[OK]${NC} FORWARD rules repaired."

# ------------------------------------------------------------
# MASQUERADE
# ------------------------------------------------------------

echo
echo -e "${CYAN}[*] Repairing NAT/MASQUERADE...${NC}"

iptables -t nat -C POSTROUTING \
    -s "${LXD_SUBNET}/${LXD_PREFIX}" \
    -o "$HOST_IFACE" \
    -j MASQUERADE 2>/dev/null

if [ $? -ne 0 ]; then
    iptables -t nat -I POSTROUTING 1 \
        -s "${LXD_SUBNET}/${LXD_PREFIX}" \
        -o "$HOST_IFACE" \
        -j MASQUERADE
fi

echo -e "${GREEN}[OK]${NC} MASQUERADE configured."

# ------------------------------------------------------------
# CONTAINER NETWORK
# ------------------------------------------------------------

echo
echo -e "${CYAN}[*] Container network information:${NC}"

lxc exec "$CT" -- bash -c '
echo "--------------------------------"
echo "IP ADDRESS"
ip -4 addr show eth0 2>/dev/null

echo
echo "ROUTE"
ip -4 route 2>/dev/null

echo
echo "DNS"
cat /etc/resolv.conf 2>/dev/null
echo "--------------------------------"
'

# ------------------------------------------------------------
# DNS FIX
# ------------------------------------------------------------

echo
echo -e "${CYAN}[*] Repairing DNS...${NC}"

lxc exec "$CT" -- bash -c '
cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 9.9.9.9
EOF
' >/dev/null 2>&1

echo -e "${GREEN}[OK]${NC} DNS repaired."

# ------------------------------------------------------------
# APT CONFIG
# ------------------------------------------------------------

echo
echo -e "${CYAN}[*] Configuring APT...${NC}"

lxc exec "$CT" -- bash -c '
mkdir -p /etc/apt/apt.conf.d

cat > /etc/apt/apt.conf.d/99-aethercloud-network <<EOF
Acquire::ForceIPv4 "true";
Acquire::Retries "2";
Acquire::http::Timeout "10";
Acquire::https::Timeout "10";
EOF
'

echo -e "${GREEN}[OK]${NC} APT IPv4 + timeout configuration applied."

# ------------------------------------------------------------
# HOST INTERNET TEST
# ------------------------------------------------------------

echo
echo -e "${CYAN}[*] Testing host internet...${NC}"

if timeout 8 curl -4 -fsSI https://deb.debian.org >/dev/null 2>&1; then
    echo -e "${GREEN}[OK]${NC} Host internet is working."
else
    echo -e "${YELLOW}[!]${NC} Host HTTPS test failed."
fi

# ------------------------------------------------------------
# CONTAINER GATEWAY
# ------------------------------------------------------------

echo
echo -e "${CYAN}[*] Detecting container gateway...${NC}"

GATEWAY=$(lxc exec "$CT" -- bash -c \
    "ip -4 route | awk '/default/ {print \$3; exit}'" 2>/dev/null)

if [ -n "$GATEWAY" ]; then
    echo -e "${GREEN}[OK]${NC} Gateway: $GATEWAY"

    if lxc exec "$CT" -- bash -c \
        "timeout 5 ping -4 -c 2 '$GATEWAY' >/dev/null 2>&1"; then
        echo -e "${GREEN}[OK]${NC} Gateway reachable."
    else
        echo -e "${RED}[ERROR]${NC} Gateway unreachable."
    fi
else
    echo -e "${RED}[ERROR]${NC} Gateway could not be detected."
fi

# ------------------------------------------------------------
# CONTAINER HTTPS TEST
# ------------------------------------------------------------

echo
echo -e "${CYAN}[*] Testing container internet...${NC}"

if lxc exec "$CT" -- bash -c '
if command -v curl >/dev/null 2>&1; then
    timeout 12 curl -4 -fsSI https://deb.debian.org >/dev/null
elif command -v wget >/dev/null 2>&1; then
    timeout 12 wget -4 --spider -q https://deb.debian.org
else
    exit 127
fi
'; then
    echo -e "${GREEN}[OK]${NC} Container internet is working."
else
    echo -e "${YELLOW}[!]${NC} HTTPS test failed or curl/wget is unavailable."
fi

# ------------------------------------------------------------
# APT UPDATE
# ------------------------------------------------------------

echo
echo -e "${CYAN}[*] Updating package lists...${NC}"
echo -e "${YELLOW}Maximum timeout: 45 seconds${NC}"
echo

timeout 45 lxc exec "$CT" -- bash -c '
apt-get clean
rm -rf /var/lib/apt/lists/*

apt-get \
    -o Acquire::ForceIPv4=true \
    -o Acquire::Retries=2 \
    -o Acquire::http::Timeout=10 \
    -o Acquire::https::Timeout=10 \
    update
'

APT_STATUS=$?

if [ $APT_STATUS -eq 0 ]; then
    echo
    echo -e "${GREEN}[OK] APT UPDATE SUCCESSFUL${NC}"
else
    echo
    echo -e "${RED}[ERROR] APT UPDATE FAILED${NC}"

    echo
    echo "========== NETWORK DIAGNOSTICS =========="

    echo
    echo "HOST ROUTE:"
    ip -4 route get 1.1.1.1 2>/dev/null

    echo
    echo "NAT COUNTERS:"
    iptables -t nat -L POSTROUTING -n -v 2>/dev/null

    echo
    echo "FORWARD COUNTERS:"
    iptables -L FORWARD -n -v 2>/dev/null

    echo
    echo "LXD NETWORK:"
    lxc network show "$LXD_NETWORK" 2>/dev/null

    echo
    echo "CONTAINER ROUTE:"
    lxc exec "$CT" -- ip -4 route 2>/dev/null

    echo
    echo "CONTAINER DNS:"
    lxc exec "$CT" -- cat /etc/resolv.conf 2>/dev/null

    echo
    echo "TCP TEST:"
    lxc exec "$CT" -- bash -c '
    if command -v curl >/dev/null 2>&1; then
        timeout 10 curl -4 -vI https://deb.debian.org 2>&1 | tail -30
    else
        echo "curl is not installed."
    fi
    '
fi

# ------------------------------------------------------------
# TMATE
# ------------------------------------------------------------

if [ $APT_STATUS -eq 0 ]; then

    echo
    echo -e "${CYAN}[*] Installing tmate...${NC}"

    if lxc exec "$CT" -- bash -c \
        'command -v tmate >/dev/null 2>&1'; then

        echo -e "${GREEN}[OK]${NC} tmate is already installed."

    else

        timeout 60 lxc exec "$CT" -- bash -c '
        apt-get \
            -o Acquire::ForceIPv4=true \
            -o Acquire::Retries=2 \
            -o Acquire::http::Timeout=10 \
            -o Acquire::https::Timeout=10 \
            install -y tmate
        '

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}[OK]${NC} tmate installed successfully."
        else
            echo -e "${YELLOW}[!]${NC} tmate installation failed."
        fi
    fi
else
    echo
    echo -e "${YELLOW}[!]${NC} Skipping tmate because APT update failed."
fi

# ------------------------------------------------------------
# FINAL STATUS
# ------------------------------------------------------------

echo
echo -e "${MAGENTA}${BOLD}"
echo "============================================================"
echo "                    FINAL STATUS"
echo "============================================================"
echo -e "${NC}"

echo "Container : $CT"
echo "Network   : $LXD_NETWORK"
echo "Interface : $HOST_IFACE"
echo "Subnet    : ${LXD_SUBNET}/${LXD_PREFIX}"
echo

echo "Container status:"
lxc list "$CT"

echo

if lxc exec "$CT" -- bash -c \
    'command -v tmate >/dev/null 2>&1'; then

    echo -e "${GREEN}[OK] tmate installed.${NC}"
    lxc exec "$CT" -- tmate -V 2>/dev/null

else
    echo -e "${YELLOW}[!] tmate is not installed.${NC}"
fi

echo
echo -e "${GREEN}${BOLD}Error fix completed.${NC}"
echo
