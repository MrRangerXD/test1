cat > /root/error-fix.sh <<'EOF'
#!/usr/bin/env bash

# ============================================================
# AetherCloud VMB-V1
# ERROR-FIX.SH
# Developer: ZenseiBabe
#
# Purpose:
#   Repair common LXD/LXC VPS networking, DNS and APT issues.
#
# IMPORTANT:
#   - Does NOT delete containers
#   - Does NOT recreate containers
#   - Does NOT destroy LXD storage
#   - Does NOT modify the VPS filesystem unnecessarily
# ============================================================

set -u

# ---------------- COLORS ----------------

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

info() {
    echo -e "${CYAN}[*]${NC} $1"
}

ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

err() {
    echo -e "${RED}[ERROR]${NC} $1"
}

step() {
    echo
    echo -e "${MAGENTA}${BOLD}============================================================${NC}"
    echo -e "${MAGENTA}${BOLD}$1${NC}"
    echo -e "${MAGENTA}${BOLD}============================================================${NC}"
}

# ---------------- ROOT CHECK ----------------

if [[ $EUID -ne 0 ]]; then
    err "Run this script as root."
    echo "Example:"
    echo "  sudo bash error-fix.sh"
    exit 1
fi

# ---------------- LXC CHECK ----------------

if ! command -v lxc >/dev/null 2>&1; then
    err "LXC/LXD command 'lxc' was not found."
    exit 1
fi

# ============================================================
# CONTAINER INPUT
# ============================================================

clear 2>/dev/null || true

echo -e "${MAGENTA}${BOLD}"
echo "============================================================"
echo "              AETHERCLOUD ERROR FIX"
echo "============================================================"
echo -e "${NC}"

echo
echo -e "${CYAN}Enter Container Name -> ${NC}"
read -r CT

if [[ -z "$CT" ]]; then
    err "Container name cannot be empty."
    exit 1
fi

# ---------------- CONTAINER EXISTS ----------------

step "CHECKING CONTAINER"

if ! lxc info "$CT" >/dev/null 2>&1; then
    err "Container '$CT' was not found."
    echo
    echo "Available containers:"
    lxc list
    exit 1
fi

ok "Container found: $CT"

# ============================================================
# CONTAINER STATUS
# ============================================================

step "CHECKING CONTAINER STATUS"

STATUS="$(lxc list "$CT" --format csv -c s 2>/dev/null || true)"

if [[ "$STATUS" != "RUNNING" ]]; then
    warn "Container is not running."
    info "Starting container..."

    if lxc start "$CT"; then
        sleep 4
        ok "Container started."
    else
        err "Failed to start container."
        exit 1
    fi
else
    ok "Container is already running."
fi

# ============================================================
# LXD NETWORK
# ============================================================

step "CHECKING LXD NETWORK"

LXD_NETWORK=""

# Find the network attached to eth0
LXD_NETWORK="$(
    lxc config device get "$CT" eth0 network 2>/dev/null || true
)"

if [[ -z "$LXD_NETWORK" ]]; then
    warn "Could not determine eth0 network automatically."
    LXD_NETWORK="lxdbr0"
fi

info "Detected network: $LXD_NETWORK"

if lxc network show "$LXD_NETWORK" >/dev/null 2>&1; then
    ok "LXD network exists: $LXD_NETWORK"
else
    err "LXD network '$LXD_NETWORK' does not exist."
    echo
    echo "Available networks:"
    lxc network list
    exit 1
fi

# ============================================================
# NETWORK CONFIGURATION
# ============================================================

step "CHECKING LXD NETWORK CONFIGURATION"

IPV4_ADDR="$(
    lxc network get "$LXD_NETWORK" ipv4.address 2>/dev/null || true
)"

IPV4_NAT="$(
    lxc network get "$LXD_NETWORK" ipv4.nat 2>/dev/null || true
)"

info "IPv4 address: ${IPV4_ADDR:-not configured}"
info "IPv4 NAT: ${IPV4_NAT:-not configured}"

if [[ -z "$IPV4_ADDR" ]]; then
    warn "LXD network has no IPv4 address."
    warn "Attempting to configure a private IPv4 network..."

    if [[ "$LXD_NETWORK" == "lxdbr0" ]]; then
        lxc network set "$LXD_NETWORK" ipv4.address 10.63.232.1/24 || true
    else
        warn "Custom network detected; not changing its IPv4 address automatically."
    fi
fi

if [[ "$IPV4_NAT" != "true" ]]; then
    info "Enabling IPv4 NAT on $LXD_NETWORK..."
    lxc network set "$LXD_NETWORK" ipv4.nat true || true
fi

ok "LXD network configuration checked."

# ============================================================
# HOST FORWARDING
# ============================================================

step "ENABLING HOST IP FORWARDING"

sysctl -w net.ipv4.ip_forward=1 >/dev/null

mkdir -p /etc/sysctl.d

cat > /etc/sysctl.d/99-aethercloud-forward.conf <<SYSCTL
net.ipv4.ip_forward=1
SYSCTL

sysctl --system >/dev/null 2>&1 || true

if [[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]]; then
    ok "IPv4 forwarding is enabled."
else
    err "Could not enable IPv4 forwarding."
fi

# ============================================================
# DETECT HOST INTERFACE
# ============================================================

step "DETECTING HOST INTERNET INTERFACE"

HOST_IFACE="$(
    ip -4 route get 1.1.1.1 2>/dev/null |
    awk '{
        for(i=1;i<=NF;i++)
            if($i=="dev")
                print $(i+1)
    }' |
    head -n1
)"

if [[ -z "$HOST_IFACE" ]]; then
    warn "Could not automatically detect host interface."
    HOST_IFACE="eth0"
fi

info "Host internet interface: $HOST_IFACE"

# ============================================================
# LXD SUBNET
# ============================================================

LXD_SUBNET="$(
    lxc network get "$LXD_NETWORK" ipv4.address 2>/dev/null |
    sed 's#/.*##'
)"

if [[ -z "$LXD_SUBNET" ]]; then
    LXD_SUBNET="10.63.232.0"
else
    # Convert x.x.x.1 -> x.x.x.0
    LXD_SUBNET="$(echo "$LXD_SUBNET" | sed -E 's/[0-9]+$/0/')"
fi

info "Detected LXD subnet: $LXD_SUBNET/24"

# ============================================================
# IPTABLES FORWARD
# ============================================================

step "REPAIRING IPv4 FORWARDING RULES"

# LXD -> Internet
iptables -C FORWARD \
    -i "$LXD_NETWORK" \
    -o "$HOST_IFACE" \
    -j ACCEPT 2>/dev/null || \
iptables -I FORWARD 1 \
    -i "$LXD_NETWORK" \
    -o "$HOST_IFACE" \
    -j ACCEPT

# Internet -> LXD established traffic
iptables -C FORWARD \
    -i "$HOST_IFACE" \
    -o "$LXD_NETWORK" \
    -m conntrack \
    --ctstate RELATED,ESTABLISHED \
    -j ACCEPT 2>/dev/null || \
iptables -I FORWARD 1 \
    -i "$HOST_IFACE" \
    -o "$LXD_NETWORK" \
    -m conntrack \
    --ctstate RELATED,ESTABLISHED \
    -j ACCEPT

ok "IPv4 forwarding rules repaired."

# ============================================================
# IPTABLES NAT
# ============================================================

step "REPAIRING NAT"

if ! iptables -t nat -C POSTROUTING \
    -s "${LXD_SUBNET}/24" \
    -o "$HOST_IFACE" \
    -j MASQUERADE 2>/dev/null; then

    iptables -t nat -I POSTROUTING 1 \
        -s "${LXD_SUBNET}/24" \
        -o "$HOST_IFACE" \
        -j MASQUERADE

    ok "Added MASQUERADE rule."
else
    ok "MASQUERADE rule already exists."
fi

# ============================================================
# DNS
# ============================================================

step "REPAIRING CONTAINER DNS"

lxc exec "$CT" -- bash -c '
cat > /etc/resolv.conf <<DNS
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 9.9.9.9
DNS
' || warn "Could not modify /etc/resolv.conf"

ok "DNS configuration applied."

# ============================================================
# APT CONFIG
# ============================================================

step "REPAIRING APT"

lxc exec "$CT" -- bash -c '
mkdir -p /etc/apt/apt.conf.d

cat > /etc/apt/apt.conf.d/99-aethercloud-network <<APT
Acquire::ForceIPv4 "true";
Acquire::Retries "2";
Acquire::http::Timeout "10";
Acquire::https::Timeout "10";
APT
' || warn "Could not configure APT."

ok "APT configured with IPv4 + timeout protection."

# ============================================================
# REPAIR DEBIAN SOURCES
# ============================================================

step "CHECKING DEBIAN SOURCES"

lxc exec "$CT" -- bash -c '
if grep -q "bookworm" /etc/apt/sources.list 2>/dev/null; then
    echo "Debian bookworm sources detected."
else
    echo "deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware" > /etc/apt/sources.list
    echo "deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware" >> /etc/apt/sources.list
    echo "deb http://deb.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware" >> /etc/apt/sources.list
fi
' || warn "Could not check Debian sources."

ok "Debian sources checked."

# ============================================================
# NETWORK TEST
# ============================================================

step "TESTING CONTAINER NETWORK"

echo
echo -e "${CYAN}Container IP:${NC}"

lxc exec "$CT" -- bash -c '
ip -4 addr show eth0 || true
'

echo
echo -e "${CYAN}Container route:${NC}"

lxc exec "$CT" -- bash -c '
ip -4 route || true
'

echo
echo -e "${CYAN}Testing LXD gateway...${NC}"

if lxc exec "$CT" -- bash -c \
    'timeout 5 ping -4 -c 2 10.63.232.1 >/dev/null 2>&1'; then
    ok "LXD gateway reachable."
else
    warn "LXD gateway test failed."
fi

echo
echo -e "${CYAN}Testing HTTPS connectivity...${NC}"

HTTPS_TEST=1

lxc exec "$CT" -- bash -c '
if command -v curl >/dev/null 2>&1; then
    timeout 12 curl -4 -fsSI https://deb.debian.org >/dev/null
elif command -v wget >/dev/null 2>&1; then
    timeout 12 wget -4 --spider -q https://deb.debian.org
else
    exit 127
fi
' || HTTPS_TEST=0

if [[ "$HTTPS_TEST" == "1" ]]; then
    ok "Container has working HTTPS internet."
else
    warn "Container HTTPS test failed."
fi

# ============================================================
# APT UPDATE
# ============================================================

step "TESTING APT"

APT_OK=0

if lxc exec "$CT" -- bash -c '
timeout 45 apt-get \
    -o Acquire::ForceIPv4=true \
    -o Acquire::Retries=2 \
    -o Acquire::http::Timeout=10 \
    -o Acquire::https::Timeout=10 \
    update
'; then
    APT_OK=1
    ok "APT update successful."
else
    warn "APT update failed."
fi

# ============================================================
# TMATE
# ============================================================

step "INSTALLING TMATE"

if [[ "$APT_OK" == "1" ]]; then

    if lxc exec "$CT" -- bash -c 'command -v tmate >/dev/null 2>&1'; then
        ok "tmate is already installed."
    else
        if lxc exec "$CT" -- bash -c '
            timeout 60 apt-get \
                -o Acquire::ForceIPv4=true \
                -o Acquire::Retries=2 \
                -o Acquire::http::Timeout=10 \
                -o Acquire::https::Timeout=10 \
                install -y tmate
        '; then
            ok "tmate installed successfully."
        else
            warn "tmate installation failed."
        fi
    fi

else
    warn "Skipping tmate installation because APT update failed."
fi

# ============================================================
# FINAL REPORT
# ============================================================

step "FINAL REPORT"

echo

echo -e "${CYAN}Container:${NC} $CT"
echo -e "${CYAN}Network:${NC}   $LXD_NETWORK"
echo -e "${CYAN}Interface:${NC} $HOST_IFACE"
echo -e "${CYAN}Subnet:${NC}    ${LXD_SUBNET}/24"

echo

echo -e "${CYAN}Container status:${NC}"
lxc list "$CT"

echo
echo -e "${CYAN}tmate status:${NC}"

if lxc exec "$CT" -- bash -c 'command -v tmate >/dev/null 2>&1'; then
    ok "tmate is installed."
    lxc exec "$CT" -- tmate -V 2>/dev/null || true
else
    warn "tmate is NOT installed."
fi

echo
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo -e "${GREEN}${BOLD}              ERROR FIX FINISHED${NC}"
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo

echo "Useful commands:"
echo
echo "Enter container:"
echo "  lxc exec $CT -- bash"
echo
echo "Check container:"
echo "  lxc list $CT"
echo
echo "Check LXD network:"
echo "  lxc network show $LXD_NETWORK"
echo
echo "Check bot:"
echo "  systemctl status aethercloud"
echo

EOF

chmod +x /root/error-fix.sh
