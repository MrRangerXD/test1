#!/usr/bin/env bash
#
# install.sh - AetherCloud VMB-V1 Installer
# Bot repo: https://github.com/MrRangerXD/VMB-V1
# Developer: ZenseiBabe
#
# Usage (from repo, bot.py sitting next to this script):
#   sudo bash install.sh
# Usage (remote, no clone needed):
#   sudo bash <(curl -sSL https://raw.githubusercontent.com/MrRangerXD/VMB-V1/main/install.sh)
#
set -euo pipefail

REPO_URL="https://github.com/MrRangerXD/VMB-V1.git"
INSTALL_DIR="/root/aethercloud"
SERVICE_NAME="aethercloud"
BOT_TARGET_FILE="bot.py"
ENV_FILE="${INSTALL_DIR}/.env"
DEFAULT_BOT_NAME="AetherCloud"
DEFAULT_DEVELOPER="ZenseiBabe"
DEFAULT_BOT_VERSION="1.0 PRO"
DEFAULT_THUMBNAIL_URL="https://i.imgur.com/n2dkdyR.png"
DEFAULT_ICON_URL="https://i.imgur.com/n2dkdyR.png"
DEFAULT_HOST_MOTD="bash <(curl -fsSL https://raw.githubusercontent.com/MrRangerXD/VMB-V1/refs/heads/main/AetherCloud)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; BOLD='\033[1m'; MAGENTA='\033[0;35m'; NC='\033[0m'
info()  { echo -e "${CYAN}[*]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
  err "Please run this script as root (e.g. sudo bash install.sh)"
  exit 1
fi

# ==============================================================================
# STEP 1: Install LXC + LXD
# ==============================================================================
step_install_lxc() {
  echo
  echo -e "${BOLD}-------------------------------------------------"
  echo "  STEP 1: Install LXC + LXD"
  echo -e "-------------------------------------------------${NC}"

  if command -v lxc >/dev/null 2>&1 && command -v lxd >/dev/null 2>&1; then
    ok "LXC/LXD already installed. Skipping install, checking init status..."
  else
    info "Updating system..."
    apt update -y
    apt upgrade -y

    info "Installing LXC..."
    apt install -y lxc lxc-utils bridge-utils uidmap

    if ! command -v snap >/dev/null 2>&1; then
      info "Installing snapd..."
      apt install -y snapd
      systemctl enable --now snapd.socket || true
      if [[ ! -e /snap ]]; then
        ln -s /var/lib/snapd/snap /snap || true
      fi
      sleep 3
    fi

    info "Installing LXD via snap..."
    snap install lxd || warn "snap install lxd reported an issue, continuing anyway"

    usermod -aG lxd "${SUDO_USER:-root}" || true
    ok "LXC/LXD packages installed."
  fi

  export PATH="$PATH:/snap/bin"

  echo
  if lxc list >/dev/null 2>&1; then
    ok "LXD is already initialized."
  else
    warn "LXD needs to be initialized (storage pool + network)."
    read -rp "$(echo -e ${CYAN}Run \'lxd init\' interactively now? [Y/n]: ${NC})" RUN_INIT
    if [[ "${RUN_INIT,,}" != "n" ]]; then
      lxd init
    else
      warn "Skipped. Run 'lxd init' manually before creating any VPS containers."
    fi
  fi

  echo
  ok "STEP 1 complete: LXC + LXD ready."
}

# ==============================================================================
# STEP 2: Install AetherCloud (Full-Setup)
# ==============================================================================
step_install_bot() {
  echo
  echo -e "${BOLD}-------------------------------------------------"
  echo "  STEP 2: Install ${DEFAULT_BOT_NAME} ( Full-Setup )"
  echo -e "-------------------------------------------------${NC}"

  # ---- base packages ----
  info "Installing base packages (python3, pip, git, curl)..."
  apt update -y
  apt install -y python3 python3-pip python3-venv git curl

  mkdir -p ~/.config/pip
  echo -e "[global]\nbreak-system-packages = true" > ~/.config/pip/pip.conf

  # ---- get bot source (local repo, or self-clone if run via curl|bash) ----
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
  LOCAL_PY_FILE=""
  LOCAL_REQ_FILE=""
  if [[ -n "$SCRIPT_DIR" ]]; then
    LOCAL_PY_FILE="$(find "$SCRIPT_DIR" -maxdepth 1 -iname 'bot.py' | head -n1 || true)"
    [[ -z "$LOCAL_PY_FILE" ]] && LOCAL_PY_FILE="$(find "$SCRIPT_DIR" -maxdepth 1 -iname '*.py' | head -n1 || true)"
    LOCAL_REQ_FILE="$(find "$SCRIPT_DIR" -maxdepth 1 -iname 'requirements.txt' | head -n1 || true)"
  fi

  mkdir -p "${INSTALL_DIR}"

  if [[ -n "$LOCAL_PY_FILE" && -f "$LOCAL_PY_FILE" ]]; then
    info "Using local bot source: $(basename "$LOCAL_PY_FILE")"
    cp "$LOCAL_PY_FILE" "${INSTALL_DIR}/${BOT_TARGET_FILE}"
    if [[ -n "$LOCAL_REQ_FILE" && -f "$LOCAL_REQ_FILE" ]]; then
      cp "$LOCAL_REQ_FILE" "${INSTALL_DIR}/requirements.txt"
    fi
  else
    info "No local bot source found next to this script - cloning from repo..."
    TMP_CLONE="$(mktemp -d)"
    git clone --depth 1 "$REPO_URL" "$TMP_CLONE"
    PY_FILE="$(find "$TMP_CLONE" -maxdepth 1 -iname 'bot.py' | head -n1 || true)"
    [[ -z "$PY_FILE" ]] && PY_FILE="$(find "$TMP_CLONE" -maxdepth 1 -iname '*.py' | head -n1 || true)"
    if [[ -z "$PY_FILE" ]]; then
      err "Could not find a .py bot file in ${REPO_URL}."
      exit 1
    fi
    cp "$PY_FILE" "${INSTALL_DIR}/${BOT_TARGET_FILE}"
    if [[ -f "${TMP_CLONE}/requirements.txt" ]]; then
      cp "${TMP_CLONE}/requirements.txt" "${INSTALL_DIR}/requirements.txt"
    fi
    rm -rf "$TMP_CLONE"
  fi
  ok "Bot script placed at ${INSTALL_DIR}/${BOT_TARGET_FILE}"

  # ---- python deps ----
  info "Installing Python dependencies..."
  pip3 install --break-system-packages --upgrade pip || warn "pip self-upgrade skipped (safe to ignore on Debian/Ubuntu)"
  if [[ -f "${INSTALL_DIR}/requirements.txt" ]]; then
    pip3 install --break-system-packages -r "${INSTALL_DIR}/requirements.txt"
  else
    warn "No requirements.txt found - installing known AetherCloud dependencies directly."
    pip3 install --break-system-packages "discord.py>=2.4.0" "aiohttp>=3.10.0" "python-dotenv>=1.0.1" "PyNaCl>=1.5.0" "requests>=2.32.0" "pillow>=11.0" "psutil>=5.9.6"
  fi
  ok "Python dependencies installed."

  # ---- LXC sanity check ----
  export PATH="$PATH:/snap/bin"
  if ! command -v lxc >/dev/null 2>&1; then
    warn "LXC/LXD not found. Run STEP 1 first, or VPS commands will fail."
  elif ! lxc list >/dev/null 2>&1; then
    warn "LXD is installed but not initialized. Run 'lxd init' before creating VPS containers."
  else
    ok "LXC/LXD detected and initialized."
  fi

  # ---- configuration prompts ----
  echo
  echo "-------------------------------------------------"
  echo "  Bot Configuration"
  echo "-------------------------------------------------"
  echo

  while true; do
    read -rsp "$(echo -e ${CYAN}Enter your DISCORD_TOKEN \(input hidden\): ${NC})" DISCORD_TOKEN
    echo
    [[ -n "$DISCORD_TOKEN" ]] && break
    warn "Discord token cannot be empty."
  done

  while true; do
    read -rp "$(echo -e ${CYAN}Enter MAIN_ADMIN_ID \(your Discord user ID\): ${NC})" MAIN_ADMIN_ID
    [[ "$MAIN_ADMIN_ID" =~ ^[0-9]+$ ]] && break
    warn "MAIN_ADMIN_ID must be numeric (your Discord user ID)."
  done

  while true; do
    read -rp "$(echo -e ${CYAN}Enter VPS_USER_ROLE_ID \(Discord role ID for VPS users\): ${NC})" VPS_USER_ROLE_ID
    [[ "$VPS_USER_ROLE_ID" =~ ^[0-9]+$ ]] && break
    warn "VPS_USER_ROLE_ID must be numeric (a Discord role ID)."
  done

  read -rp "$(echo -e ${CYAN}Bot name [${DEFAULT_BOT_NAME}]: ${NC})" BOT_NAME
  BOT_NAME=${BOT_NAME:-$DEFAULT_BOT_NAME}

  read -rp "$(echo -e ${CYAN}Command prefix [a!]: ${NC})" PREFIX
  PREFIX=${PREFIX:-a!}

  DEFAULT_IP=$(curl -s -4 --max-time 5 ifconfig.me 2>/dev/null || true)
  IP_REGEX='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
  if [[ ! "$DEFAULT_IP" =~ $IP_REGEX ]]; then
    DEFAULT_IP="127.0.0.1"
  fi
  read -rp "$(echo -e ${CYAN}Server public IP [${DEFAULT_IP}]: ${NC})" YOUR_SERVER_IP
  YOUR_SERVER_IP=${YOUR_SERVER_IP:-$DEFAULT_IP}

  read -rp "$(echo -e ${CYAN}Default LXD storage pool [default]: ${NC})" DEFAULT_STORAGE_POOL
  DEFAULT_STORAGE_POOL=${DEFAULT_STORAGE_POOL:-default}

  read -rp "$(echo -e ${CYAN}Default VPS expiration in days [30]: ${NC})" DEFAULT_VPS_EXPIRATION_DAYS
  DEFAULT_VPS_EXPIRATION_DAYS=${DEFAULT_VPS_EXPIRATION_DAYS:-30}

  read -rp "$(echo -e ${CYAN}Expiration warning window in days [1]: ${NC})" EXPIRATION_WARNING_DAYS
  EXPIRATION_WARNING_DAYS=${EXPIRATION_WARNING_DAYS:-1}

  read -rp "$(echo -e ${CYAN}Bot thumbnail URL [${DEFAULT_THUMBNAIL_URL}]: ${NC})" BOT_THUMBNAIL_URL
  BOT_THUMBNAIL_URL=${BOT_THUMBNAIL_URL:-$DEFAULT_THUMBNAIL_URL}

  read -rp "$(echo -e ${CYAN}Bot icon URL [${DEFAULT_ICON_URL}]: ${NC})" BOT_ICON_URL
  BOT_ICON_URL=${BOT_ICON_URL:-$DEFAULT_ICON_URL}

  read -rp "$(echo -e ${CYAN}HOST_MOTD install command [default MOTD installer]: ${NC})" HOST_MOTD
  HOST_MOTD=${HOST_MOTD:-$DEFAULT_HOST_MOTD}

  # ---- write .env ----
  cat > "${ENV_FILE}" <<EOF
DISCORD_TOKEN=${DISCORD_TOKEN}
BOT_NAME=${BOT_NAME}
PREFIX=${PREFIX}
YOUR_SERVER_IP=${YOUR_SERVER_IP}
MAIN_ADMIN_ID=${MAIN_ADMIN_ID}
VPS_USER_ROLE_ID=${VPS_USER_ROLE_ID}
DEFAULT_STORAGE_POOL=${DEFAULT_STORAGE_POOL}
BOT_VERSION=${DEFAULT_BOT_VERSION}
BOT_DEVELOPER=${DEFAULT_DEVELOPER}
BOT_THUMBNAIL_URL=${BOT_THUMBNAIL_URL}
BOT_ICON_URL=${BOT_ICON_URL}
DEFAULT_VPS_EXPIRATION_DAYS=${DEFAULT_VPS_EXPIRATION_DAYS}
EXPIRATION_WARNING_DAYS=${EXPIRATION_WARNING_DAYS}
HOST_MOTD=${HOST_MOTD}
EOF
  chmod 600 "${ENV_FILE}"
  ok "Configuration saved to ${ENV_FILE}"

  # ---- systemd service ----
  info "Creating systemd service '${SERVICE_NAME}'..."

  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=${BOT_NAME} Discord Bot (by ${DEFAULT_DEVELOPER})
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/${BOT_TARGET_FILE}
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}"
  systemctl restart "${SERVICE_NAME}"

  sleep 2
  echo
  echo "-------------------------------------------------"
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    ok "${BOT_NAME} is running as service '${SERVICE_NAME}'."
  else
    err "Service did not start correctly. Check logs with:"
    echo "    journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
  fi
  echo "-------------------------------------------------"
  echo
  echo "Useful commands:"
  echo "  systemctl status ${SERVICE_NAME}      # check status"
  echo "  systemctl restart ${SERVICE_NAME}     # restart bot"
  echo "  journalctl -u ${SERVICE_NAME} -f      # live logs"
  echo "  nano ${ENV_FILE}                      # edit config, then restart"
  echo "  sqlite3 ${INSTALL_DIR}/vps.db         # inspect the VPS database"
}

# ==============================================================================
# MENU
# ==============================================================================
print_banner() {
  clear 2>/dev/null || true
  echo -e "${MAGENTA}${BOLD}-------------------------------------------------"
  echo "   INSTALLATION CMD BY ${DEFAULT_DEVELOPER}"
  echo -e "-------------------------------------------------${NC}"
  echo "   ${DEFAULT_BOT_NAME} Installer (VMB-V1)"
  echo "-------------------------------------------------"
  echo "   1) Install LXC + LXD"
  echo "   2) Install ${DEFAULT_BOT_NAME} ( Full-Setup )"
  echo "   3) Do Both (1 then 2)"
  echo "   0) Exit"
  echo "-------------------------------------------------"
}

while true; do
  print_banner
  read -rp "$(echo -e ${CYAN}Select an option [1-3, 0 to exit]: ${NC})" CHOICE
  case "$CHOICE" in
    1)
      step_install_lxc
      read -rp "$(echo -e ${CYAN}Press Enter to return to menu...${NC})" _
      ;;
    2)
      step_install_bot
      read -rp "$(echo -e ${CYAN}Press Enter to return to menu...${NC})" _
      ;;
    3)
      step_install_lxc
      step_install_bot
      read -rp "$(echo -e ${CYAN}Press Enter to return to menu...${NC})" _
      ;;
    4)
      bash <(curl -fsSL https://raw.githubusercontent.com/MrRangerXD/VMB-V1/refs/heads/main/error-fix.sh)
      read -rp "$(echo -e ${CYAN}Press Enter to return to menu...${NC})" _
      ;;
    0)
      echo "Bye."
      exit 0
      ;;
    *)
      warn "Invalid option, choose 1, 2, 3 or 0."
      sleep 1
      ;;
  esac
done
