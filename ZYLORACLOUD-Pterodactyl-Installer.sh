#!/usr/bin/env bash
# ZYLORACLOUD menu installer
# Ubuntu 22.04 / 24.04 LTS | Panel / Wings / Blueprint themes / Blueprint extensions
set -Eeuo pipefail
IFS=$'\n\t'

OWNER="ramanchoudhary0214-netizen"
REPO="zyloracloud-installer"
BRANCH="main"
PACKAGE="ZYLORACLOUD-Blueprint-Packages-v2.zip"
PANEL_DIR="/var/www/pterodactyl"
RAW_BASE="https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH}"
PACKAGE_URL="${RAW_BASE}/${PACKAGE}"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'
info(){ echo -e "${GREEN}[ZYLORACLOUD]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[WARNING]${RESET} $*"; }
fail(){ echo -e "${RED}[ERROR]${RESET} $*" >&2; }
pause(){ read -r -p "Press Enter to continue..."; }

[[ $EUID -eq 0 ]] || { fail "Run as root: sudo bash $0"; exit 1; }
[[ -r /etc/os-release ]] || { fail "Cannot detect operating system."; exit 1; }
. /etc/os-release
[[ "${ID:-}" == ubuntu && ( "${VERSION_ID:-}" == "22.04" || "${VERSION_ID:-}" == "24.04" ) ]] || {
  fail "Supported operating systems: Ubuntu 22.04 LTS and 24.04 LTS. Detected: ${PRETTY_NAME:-unknown}"
  exit 1
}
command -v curl >/dev/null 2>&1 || { apt-get update && apt-get install -y curl; }

show_banner() {
  clear 2>/dev/null || true
  echo -e "${CYAN}"
  cat <<'BANNER'
 __   __ __   __ _      ____  ____   ____  _   _  ____  _   _ ____
 \ \ / / \ \ / /| |    / ___||  _ \ / ___|| | | |/ ___|| | | |  _ \
  \ V /   \ V / | |    \___ \| | | | |    | | | | |    | | | | |_) |
   | |     | |  | |___  ___) | |_| | |___ | |_| | |___ | |_| |  __/
   |_|     |_|  |_____||____/|____/ \____| \___/ \____| \___/|_|
BANNER
  echo -e "${RESET}"
  echo "             PTERODACTYL AUTOMATION MENU"
  echo "------------------------------------------------------"
  echo "  1) Install Pterodactyl Panel"
  echo "  2) Install Wings"
  echo "  3) Install Themes"
  echo "  4) Install Extensions"
  echo "  5) Exit"
  echo "------------------------------------------------------"
}

run_official_installer() {
  local choice="$1"
  local tmp="/tmp/zyloracloud-pterodactyl-installer.sh"
  warn "This option launches the Pterodactyl community installer, which has its own interactive menu."
  warn "Review its prompts carefully. Take a VPS snapshot before making changes."
  read -r -p "Continue? Type YES: " ok
  [[ "$ok" == YES ]] || return 0
  curl -fL --retry 3 https://pterodactyl-installer.se -o "$tmp"
  chmod 700 "$tmp"
  if [[ "$choice" == panel ]]; then
    info "Choose the Panel installation option in the next installer menu."
  else
    info "Choose the Wings installation option in the next installer menu."
  fi
  bash "$tmp"
  rm -f "$tmp"
}

check_panel_and_blueprint() {
  [[ -d "$PANEL_DIR" && -f "$PANEL_DIR/artisan" ]] || {
    fail "Pterodactyl Panel not found at $PANEL_DIR. Install Panel first."
    return 1
  }
  command -v blueprint >/dev/null 2>&1 || {
    fail "Blueprint CLI is not installed. Install Blueprint on this Panel first."
    echo "Official guide: https://blueprint.zip/guides/admin/install"
    return 1
  }
  return 0
}

get_blueprint_version() {
  local output
  output="$(blueprint -version 2>&1 || true)"
  echo "$output"
}

prepare_packages() {
  local work="/tmp/zyloracloud-blueprint-packages"
  local zipfile="/tmp/${PACKAGE}"
  rm -rf "$work"
  mkdir -p "$work"
  info "Downloading Blueprint package archive from GitHub..."
  curl -fL --retry 3 "$PACKAGE_URL" -o "$zipfile"
  command -v unzip >/dev/null 2>&1 || apt-get install -y unzip
  unzip -q "$zipfile" -d "$work"
  [[ -d "$work/themes" && -d "$work/extensions" ]] || {
    fail "Package ZIP does not contain expected themes/ and extensions/ folders."
    return 1
  }
  echo "$work"
}

read_conf_value() {
  local file="$1" key="$2"
  awk -F: -v key="$key" '
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      sub(/^[^:]*:[[:space:]]*/, "", $0)
      gsub(/^[\"\047]|[\"\047]$/, "", $0)
      sub(/[[:space:]]+#.*/, "", $0)
      print $0
      exit
    }' "$file"
}

install_blueprint_package() {
  local category="$1" filename="$2" work="$3"
  local source="${work}/${category}/${filename}"
  [[ -f "$source" ]] || { fail "Package missing: $filename"; return 1; }

  local conf target identifier name current
  conf="$(unzip -p "$source" conf.yml 2>/dev/null || true)"
  [[ -n "$conf" ]] || { fail "$filename has no conf.yml; refusing to install."; return 1; }

  local temp_conf
  temp_conf="$(mktemp)"
  printf '%s\n' "$conf" > "$temp_conf"
  target="$(read_conf_value "$temp_conf" target)"
  identifier="$(read_conf_value "$temp_conf" identifier)"
  name="$(read_conf_value "$temp_conf" name)"
  rm -f "$temp_conf"

  [[ -n "$target" && -n "$identifier" ]] || {
    fail "Cannot read target/identifier from $filename; refusing to install."
    return 1
  }

  current="$(get_blueprint_version)"
  echo
  echo "Package: ${name:-$identifier}"
  echo "Identifier: $identifier"
  echo "Package target: $target"
  echo "Installed Blueprint version:"
  echo "$current"
  echo

  # Conservative compatibility gate: require the CLI output to contain the exact target.
  if ! grep -Fq "$target" <<< "$current"; then
    warn "Exact target match could not be confirmed. This package will NOT be installed."
    warn "Do not bypass this check unless you have independently verified compatibility."
    return 1
  fi

  # Back up panel files before running third-party package install scripts.
  local backup="/root/zyloracloud-backups"
  mkdir -p "$backup"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  warn "Blueprint packages can modify Panel files and run package install scripts."
  read -r -p "Confirm you have a database backup and want to install ${identifier}? Type INSTALL: " ok
  [[ "$ok" == INSTALL ]] || { info "Skipped $identifier."; return 0; }

  tar -czf "${backup}/panel-files-${stamp}.tar.gz" -C /var/www pterodactyl
  install -m 0644 "$source" "${PANEL_DIR}/${identifier}.blueprint"
  chown www-data:www-data "${PANEL_DIR}/${identifier}.blueprint"
  (
    cd "$PANEL_DIR"
    blueprint -install "$identifier"
  )
  info "Finished processing $identifier."
}

theme_menu() {
  check_panel_and_blueprint || return 1
  local work
  work="$(prepare_packages)" || return 1
  while true; do
    echo
    echo "========== ZYLORACLOUD THEMES =========="
    echo "1) Nebula"
    echo "2) Snowflakes"
    echo "3) Back"
    read -r -p "Select theme [1-3]: " choice
    case "$choice" in
      1) install_blueprint_package themes nebula.blueprint "$work" || true ;;
      2) install_blueprint_package themes snowflakes.blueprint "$work" || true ;;
      3) break ;;
      *) warn "Invalid selection." ;;
    esac
  done
}

extension_menu() {
  check_panel_and_blueprint || return 1
  local work
  work="$(prepare_packages)" || return 1
  while true; do
    echo
    echo "========== ZYLORACLOUD EXTENSIONS =========="
    echo "1) Saga Auto Suspension"
    echo "2) Player Listing"
    echo "3) Hux Register"
    echo "4) Minecraft Plugin Manager"
    echo "5) MC Plugins"
    echo "6) Minecraft Player Manager"
    echo "7) MC Logs"
    echo "8) Back"
    read -r -p "Select extension [1-8]: " choice
    case "$choice" in
      1) install_blueprint_package extensions sagaautosuspension.blueprint "$work" || true ;;
      2) install_blueprint_package extensions playerlisting.blueprint "$work" || true ;;
      3) install_blueprint_package extensions huxregister.blueprint "$work" || true ;;
      4) install_blueprint_package extensions minecraftpluginmanager.blueprint "$work" || true ;;
      5) install_blueprint_package extensions mcplugins.blueprint "$work" || true ;;
      6) install_blueprint_package extensions minecraftplayermanager.blueprint "$work" || true ;;
      7) install_blueprint_package extensions mclogs.blueprint "$work" || true ;;
      8) break ;;
      *) warn "Invalid selection." ;;
    esac
  done
}

while true; do
  show_banner
  read -r -p "Select option [1-5]: " option
  case "$option" in
    1) run_official_installer panel; pause ;;
    2) run_official_installer wings; pause ;;
    3) theme_menu; pause ;;
    4) extension_menu; pause ;;
    5) info "Goodbye!"; exit 0 ;;
    *) warn "Invalid option."; sleep 1 ;;
  esac
done
