#!/usr/bin/env bash
# =============================================================================
# vm-setup.sh — VM/VPS Automated Setup Script v1.0
# =============================================================================
#
# REQUIRED ENVIRONMENT VARIABLES
# ────────────────────────────────────────────────────────────────────────────
# VAULT
#   VAULT_ADDR          - Vault server address (e.g. https://vault.example.com:8200)
#   VAULT_TOKEN         - Authentication token for Vault CLI
#
# AZURE_CLI
#   AZURE_TENANT_ID     - Azure Active Directory tenant ID
#   AZURE_CLIENT_ID     - Service principal client/app ID
#   AZURE_CLIENT_SECRET - Service principal secret (for non-interactive auth)
#
# KUBECTL / HELM
#   KUBECONFIG          - Path to kubeconfig file (default: ~/.kube/config)
#
# DOCKER (optional, for remote daemon)
#   DOCKER_HOST         - Remote Docker daemon socket (e.g. tcp://host:2376)
#
# =============================================================================

set -uo pipefail

# ── Bash version guard ────────────────────────────────────────────────────────
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "ERROR: This script requires bash 4.0 or higher (found bash ${BASH_VERSION})." >&2
  exit 1
fi

# ── Constants ─────────────────────────────────────────────────────────────────
SCRIPT_VERSION="1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/setup-$(date +%Y%m%d-%H%M%S).log"
TOTAL_SECTIONS=16
TOTAL_ERRORS=0
declare -A INSTALL_STATUS
declare -A INSTALL_VERSION

# Runtime OS variables (populated by detect_os)
OS_TYPE=""
OS_NAME=""
PKG_MGR=""
PKG_INSTALL=""
PKG_UPDATE=""
PKG_UPGRADE=""
PKG_DIST_UPGRADE=""
ARCH=""
DISTRO_ID=""
DISTRO_CODENAME=""

# Spinner PID (0 = not running)
SPINNER_PID=0

# Temporary files created by run_cmd (cleaned up by cleanup trap)
declare -a TMP_FILES=()

# Spinner frames
SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

# ── Colors (only when stdout is a terminal) ────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  GRAY='\033[0;90m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' GRAY='' BOLD='' RESET=''
fi

# ── Symbols ───────────────────────────────────────────────────────────────────
CHECK="✓"
CROSS="✗"
WARN="⚠"
ARROW="►"

# =============================================================================
# TUI UTILITIES
# =============================================================================

# Print the initial welcome banner
tui_banner() {
  clear
  echo -e "${CYAN}"
  echo "  ╔══════════════════════════════════════════════════════════╗"
  echo "  ║          VM/VPS Automated Setup Script v${SCRIPT_VERSION}            ║"
  echo "  ║              github.com/HuyNguyen2109                   ║"
  echo "  ╚══════════════════════════════════════════════════════════╝"
  echo -e "${RESET}"
  echo -e "  ${GRAY}Started : $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
  echo -e "  ${GRAY}Log file: ${LOG_FILE}${RESET}"
  echo ""
}

# Print a numbered section header with an updated progress bar
# Usage: tui_header <title> <section_number>
tui_header() {
  local title="$1"
  local section="$2"
  echo ""
  echo -e "  ${CYAN}╔══════════════════════════════════════════════════════════╗${RESET}"
  printf "  ${CYAN}║${RESET}  ${BOLD}[%02d/%02d]${RESET} ${CYAN}${ARROW}${RESET} ${BOLD}%-46s${CYAN}║${RESET}\n" \
    "$section" "$TOTAL_SECTIONS" "$title"
  echo -e "  ${CYAN}╚══════════════════════════════════════════════════════════╝${RESET}"
  draw_progress_bar "$section" "$TOTAL_SECTIONS"
  echo ""
}

# Render a filled progress bar with percentage and step counter
# Usage: draw_progress_bar <current> <total>
draw_progress_bar() {
  local current="$1"
  local total="$2"
  local bar_width=40
  local filled=$(( current * bar_width / total ))
  local empty=$(( bar_width - filled ))
  local pct=$(( current * 100 / total ))
  local filled_str=""
  local empty_str=""
  local i
  for (( i = 0; i < filled; i++ )); do filled_str+="█"; done
  for (( i = 0; i < empty;  i++ )); do empty_str+="░"; done
  printf "  ${BLUE}%s${GRAY}%s${RESET}  ${BOLD}%3d%%${RESET}  [%d/%d sections]\n" \
    "$filled_str" "$empty_str" "$pct" "$current" "$total"
}

# =============================================================================
# EXECUTION UTILITIES
# =============================================================================

# Start a background spinner for a given message
# Usage: spinner_start <message>
spinner_start() {
  local msg="$1"
  (
    local i=0
    while true; do
      printf "\r  \033[1;33m%s\033[0m %s..." \
        "${SPINNER_FRAMES[$((i % ${#SPINNER_FRAMES[@]}))]}" "$msg"
      sleep 0.1
      (( i++ )) || true
    done
  ) &
  SPINNER_PID=$!
}

# Stop the background spinner and print final ✓ or ✗ status line
# Usage: spinner_stop <exit_code> <message>
spinner_stop() {
  local status="$1"
  local msg="$2"
  if [[ "${SPINNER_PID}" -ne 0 ]]; then
    kill "${SPINNER_PID}" 2>/dev/null || true
    wait "${SPINNER_PID}" 2>/dev/null || true
    SPINNER_PID=0
  fi
  # Clear spinner line, then print final status
  printf "\r\033[K"
  if [[ "$status" -eq 0 ]]; then
    printf "  ${GREEN}${CHECK}${RESET} %-45s ${GREEN}OK${RESET}\n" "$msg"
  else
    printf "  ${RED}${CROSS}${RESET} %-45s ${RED}FAILED${RESET}  → see %s\n" \
      "$msg" "$(basename "${LOG_FILE}")"
  fi
}

# Run a command with spinner; log stderr+stdout on failure (non-fatal)
# Usage: run_cmd <description> <cmd> [args...]
# Returns: the exit code of <cmd>
run_cmd() {
  local desc="$1"
  shift
  local tmp_out exit_code
  exit_code=0

  if ! tmp_out=$(mktemp); then
    spinner_start "$desc"
    spinner_stop 1 "$desc"
    log_error "$desc" "$*" 1 "mktemp failed: could not create temporary file"
    TOTAL_ERRORS=$(( TOTAL_ERRORS + 1 ))
    return 1
  fi
  TMP_FILES+=("$tmp_out")

  spinner_start "$desc"

  if "$@" > "$tmp_out" 2>&1; then
    spinner_stop 0 "$desc"
  else
    exit_code=$?
    spinner_stop 1 "$desc"
    log_error "$desc" "$*" "$exit_code" "$(cat "$tmp_out")"
    TOTAL_ERRORS=$(( TOTAL_ERRORS + 1 ))
  fi

  rm -f "$tmp_out"
  return "$exit_code"
}

# Append a structured error entry to the log file
# Usage: log_error <description> <command_string> <exit_code> <output>
log_error() {
  local desc="$1"
  local cmd="$2"
  local code="$3"
  local output="$4"
  {
    printf "\n════════════════════════════════════════════════════════\n"
    printf "[%s] ERROR: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$desc"
    printf "Command  : %s\n" "$cmd"
    printf "Exit code: %s\n" "$code"
    printf "Output   :\n%s\n" "$output"
  } >> "$LOG_FILE"
}

# Kill any background spinner on unexpected exit
cleanup() {
  if [[ "${SPINNER_PID}" -ne 0 ]]; then
    kill "${SPINNER_PID}" 2>/dev/null || true
    wait "${SPINNER_PID}" 2>/dev/null || true
    SPINNER_PID=0
  fi
  local f
  for f in "${TMP_FILES[@]+"${TMP_FILES[@]}"}"; do
    if [[ -n "$f" ]]; then rm -f "$f" 2>/dev/null; fi
  done
}
trap 'cleanup' EXIT INT TERM HUP

# Verify the script is running as root (required for package installation)
check_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}${CROSS} This script must be run as root or with sudo.${RESET}" >&2
    exit 1
  fi
}

# =============================================================================
# SECTION 1 — OS DETECTION
# =============================================================================

detect_os() {
  tui_header "OS Detection" 1

  ARCH=$(uname -m)

  if [[ ! -f /etc/os-release ]]; then
    echo -e "  ${RED}${CROSS} Cannot detect OS: /etc/os-release not found.${RESET}" >&2
    exit 1
  fi

  # shellcheck source=/dev/null
  source /etc/os-release
  OS_NAME="${PRETTY_NAME:-Unknown}"
  DISTRO_ID="${ID:-unknown}"
  DISTRO_CODENAME="${VERSION_CODENAME:-}"

  case "${DISTRO_ID}" in
    debian|ubuntu|linuxmint|pop|kali|raspbian)
      OS_TYPE="debian"
      PKG_MGR="apt"
      PKG_INSTALL="apt-get install -y"
      PKG_UPDATE="apt-get update"
      PKG_UPGRADE="apt-get upgrade -y"
      PKG_DIST_UPGRADE="apt-get dist-upgrade -y"
      ;;
    rhel|centos|almalinux|rocky|fedora|ol|amzn)
      OS_TYPE="rhel"
      if command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
        PKG_INSTALL="dnf install -y"
        PKG_UPDATE="dnf check-update; true"
        PKG_UPGRADE="dnf upgrade -y"
        PKG_DIST_UPGRADE="dnf upgrade -y"
      else
        PKG_MGR="yum"
        PKG_INSTALL="yum install -y"
        PKG_UPDATE="yum check-update; true"
        PKG_UPGRADE="yum update -y"
        PKG_DIST_UPGRADE="yum update -y"
      fi
      ;;
    arch|manjaro|endeavouros|garuda)
      OS_TYPE="arch"
      PKG_MGR="pacman"
      PKG_INSTALL="pacman -S --noconfirm --needed"
      PKG_UPDATE="pacman -Sy"
      PKG_UPGRADE="pacman -Su --noconfirm"
      PKG_DIST_UPGRADE="pacman -Syu --noconfirm"
      ;;
    opensuse*|sles|sled)
      OS_TYPE="suse"
      PKG_MGR="zypper"
      PKG_INSTALL="zypper install -y"
      PKG_UPDATE="zypper refresh"
      PKG_UPGRADE="zypper update -y"
      PKG_DIST_UPGRADE="zypper dup -y"
      ;;
    *)
      echo -e "  ${RED}${CROSS} Unsupported Linux distribution: '${DISTRO_ID}'${RESET}" >&2
      echo -e "  Supported: Debian/Ubuntu, RHEL/CentOS/Fedora, Arch, openSUSE" >&2
      exit 1
      ;;
  esac

  echo -e "  ${GREEN}${CHECK}${RESET} OS              : ${BOLD}${OS_NAME}${RESET}"
  echo -e "  ${GREEN}${CHECK}${RESET} Architecture    : ${BOLD}${ARCH}${RESET}"
  echo -e "  ${GREEN}${CHECK}${RESET} Distribution ID : ${BOLD}${DISTRO_ID}${RESET}${DISTRO_CODENAME:+ (${DISTRO_CODENAME})}"
  echo -e "  ${GREEN}${CHECK}${RESET} Package Manager : ${BOLD}${PKG_MGR}${RESET}"

  INSTALL_STATUS["os-detect"]="OK"
  INSTALL_VERSION["os-detect"]="${OS_NAME} ${ARCH}"
}

# =============================================================================
# SECTION 2 — SYSTEM UPDATE & UPGRADE  (FATAL on failure)
# =============================================================================

system_update() {
  tui_header "System Update & Upgrade" 2
  echo -e "  ${GRAY}Running full system update — this may take several minutes...${RESET}"
  echo ""

  if ! run_cmd "Updating package index" bash -c "${PKG_UPDATE}"; then
    echo -e "\n${RED}${CROSS} FATAL: Package index update failed. Cannot continue.${RESET}" >&2
    echo -e "  ${GRAY}See: ${LOG_FILE}${RESET}" >&2
    exit 1
  fi

  if ! run_cmd "Upgrading installed packages" bash -c "${PKG_UPGRADE}"; then
    echo -e "\n${RED}${CROSS} FATAL: Package upgrade failed. Cannot continue.${RESET}" >&2
    echo -e "  ${GRAY}See: ${LOG_FILE}${RESET}" >&2
    exit 1
  fi

  case "${OS_TYPE}" in
    debian)
      run_cmd "Running dist-upgrade"       bash -c "${PKG_DIST_UPGRADE}" || true
      run_cmd "Removing unused packages"   apt-get autoremove -y         || true
      run_cmd "Cleaning package cache"     apt-get clean                 || true
      ;;
    rhel)
      run_cmd "Cleaning ${PKG_MGR} cache"  bash -c "${PKG_MGR} clean all" || true
      ;;
    arch)
      run_cmd "Cleaning pacman cache"      pacman -Sc --noconfirm         || true
      ;;
    suse)
      run_cmd "Cleaning zypper cache"      zypper clean --all             || true
      ;;
  esac

  INSTALL_STATUS["system-update"]="OK"
  INSTALL_VERSION["system-update"]="$(date '+%Y-%m-%d')"
}

# =============================================================================
# SECTION 3 — BASE SYSTEM PACKAGES
# =============================================================================

install_base() {
  tui_header "Base System Packages" 3

  case "${OS_TYPE}" in
    debian)
      run_cmd "Installing build-essential" \
        apt-get install -y build-essential ca-certificates gnupg lsb-release curl wget || true
      ;;
    rhel)
      run_cmd "Installing Development Tools group" \
        bash -c "${PKG_MGR} groupinstall -y 'Development Tools'" || true
      run_cmd "Installing gcc make curl wget" \
        bash -c "${PKG_INSTALL} gcc make ca-certificates gnupg curl wget" || true
      ;;
    arch)
      run_cmd "Installing base-devel" \
        pacman -S --noconfirm --needed base-devel curl wget gnupg || true
      ;;
    suse)
      run_cmd "Installing devel_basis pattern" \
        zypper install -y -t pattern devel_basis || true
      run_cmd "Installing gcc make curl wget" \
        bash -c "${PKG_INSTALL} gcc make ca-certificates curl wget" || true
      ;;
  esac

  INSTALL_STATUS["base-packages"]="OK"
  INSTALL_VERSION["base-packages"]="$(gcc --version 2>/dev/null | head -1 | awk '{print $NF}' || echo 'n/a')"
}

# =============================================================================
# SECTION 4 — DOCKER  (official Docker documentation)
# =============================================================================

install_docker() {
  tui_header "Docker Engine (Official)" 4

  if command -v docker &>/dev/null; then
    local current_ver
    current_ver=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
    echo -e "  ${YELLOW}${WARN}${RESET}  Docker already installed (${current_ver}). Skipping."
    INSTALL_STATUS["docker"]="already-installed"
    INSTALL_VERSION["docker"]="${current_ver}"
    return 0
  fi

  case "${OS_TYPE}" in
    debian)
      # Remove old conflicting packages
      run_cmd "Removing conflicting packages" bash -c "
        for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
          apt-get remove -y \"\${pkg}\" 2>/dev/null || true
        done
      " || true
      run_cmd "Installing Docker prerequisites" \
        apt-get install -y ca-certificates curl gnupg lsb-release || true
      run_cmd "Adding Docker GPG key" bash -c "
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/${DISTRO_ID}/gpg \
          | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
      " || true
      run_cmd "Adding Docker apt repository" bash -c "
        echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \\
          https://download.docker.com/linux/${DISTRO_ID} \\
          \$(. /etc/os-release && echo \"\${VERSION_CODENAME}\") stable\" \\
          | tee /etc/apt/sources.list.d/docker.list > /dev/null
      " || true
      run_cmd "Updating package index (docker)" apt-get update || true
      run_cmd "Installing Docker Engine" \
        apt-get install -y docker-ce docker-ce-cli containerd.io \
          docker-buildx-plugin docker-compose-plugin || true
      run_cmd "Enabling Docker service" systemctl enable --now docker || true
      ;;
    rhel)
      run_cmd "Removing conflicting packages" bash -c "
        ${PKG_MGR} remove -y docker docker-client docker-client-latest \
          docker-common docker-latest docker-latest-logrotate \
          docker-logrotate docker-engine podman runc 2>/dev/null || true
      " || true
      run_cmd "Installing yum-utils" bash -c "${PKG_INSTALL} yum-utils" || true
      run_cmd "Adding Docker yum repository" bash -c "
        yum-config-manager --add-repo \
          https://download.docker.com/linux/centos/docker-ce.repo
      " || true
      run_cmd "Installing Docker Engine" bash -c "
        ${PKG_INSTALL} docker-ce docker-ce-cli containerd.io \
          docker-buildx-plugin docker-compose-plugin
      " || true
      run_cmd "Enabling Docker service" systemctl enable --now docker || true
      ;;
    arch)
      run_cmd "Installing Docker (pacman)" \
        pacman -S --noconfirm --needed docker docker-compose || true
      run_cmd "Enabling Docker service" systemctl enable --now docker || true
      ;;
    suse)
      run_cmd "Installing Docker (zypper)" \
        zypper install -y docker docker-compose || true
      run_cmd "Enabling Docker service" systemctl enable --now docker || true
      ;;
  esac

  local installed_ver
  installed_ver=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo "unknown")
  INSTALL_STATUS["docker"]="installed"
  INSTALL_VERSION["docker"]="${installed_ver}"
}

# =============================================================================
# SECTION 5 — KUBECTL  (official Kubernetes repositories)
# =============================================================================

install_kubectl() {
  tui_header "kubectl (Official Kubernetes)" 5

  if command -v kubectl &>/dev/null; then
    local current_ver
    current_ver=$(kubectl version --client -o json 2>/dev/null \
      | grep -o '"gitVersion": "[^"]*"' | head -1 | cut -d'"' -f4 \
      || kubectl version --client 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 \
      || echo "unknown")
    echo -e "  ${YELLOW}${WARN}${RESET}  kubectl already installed (${current_ver}). Skipping."
    INSTALL_STATUS["kubectl"]="already-installed"
    INSTALL_VERSION["kubectl"]="${current_ver}"
    return 0
  fi

  case "${OS_TYPE}" in
    debian)
      run_cmd "Adding Kubernetes APT key" bash -c "
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key \
          | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
      " || true
      run_cmd "Adding Kubernetes APT repo" bash -c "
        echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
          https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' \
          | tee /etc/apt/sources.list.d/kubernetes.list
      " || true
      run_cmd "Updating package index (k8s)" apt-get update || true
      run_cmd "Installing kubectl" apt-get install -y kubectl || true
      ;;
    rhel)
      run_cmd "Adding Kubernetes yum repo" bash -c "
        cat > /etc/yum.repos.d/kubernetes.repo <<'REPO'
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.32/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.32/rpm/repodata/repomd.xml.key
REPO
      " || true
      run_cmd "Installing kubectl" bash -c "${PKG_INSTALL} kubectl" || true
      ;;
    arch)
      run_cmd "Installing kubectl (pacman)" \
        pacman -S --noconfirm --needed kubectl || true
      ;;
    suse)
      run_cmd "Installing kubectl (zypper)" zypper install -y kubectl || true
      ;;
  esac

  local installed_ver
  installed_ver=$(kubectl version --client -o json 2>/dev/null \
    | grep -o '"gitVersion": "[^"]*"' | head -1 | cut -d'"' -f4 \
    || kubectl version --client 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 \
    || echo "unknown")
  INSTALL_STATUS["kubectl"]="installed"
  INSTALL_VERSION["kubectl"]="${installed_ver}"
}

# =============================================================================
# SECTION 6 — HELM  (official get-helm-3 script)
# =============================================================================

install_helm() {
  tui_header "Helm (Official Script)" 6

  if command -v helm &>/dev/null; then
    local current_ver
    current_ver=$(helm version --short 2>/dev/null | cut -d'+' -f1 || echo "unknown")
    echo -e "  ${YELLOW}${WARN}${RESET}  Helm already installed (${current_ver}). Skipping."
    INSTALL_STATUS["helm"]="already-installed"
    INSTALL_VERSION["helm"]="${current_ver}"
    return 0
  fi

  local tmp_script
  tmp_script=$(mktemp /tmp/installer.XXXXXX.sh)
  chmod 700 "${tmp_script}"
  run_cmd "Downloading Helm install script" \
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
      -o "${tmp_script}" || true
  run_cmd "Installing Helm" bash "${tmp_script}" || true
  rm -f "${tmp_script}"

  local installed_ver
  installed_ver=$(helm version --short 2>/dev/null | cut -d'+' -f1 || echo "unknown")
  INSTALL_STATUS["helm"]="installed"
  INSTALL_VERSION["helm"]="${installed_ver}"
}

# =============================================================================
# SECTION 7 — AZURE CLI  (official Microsoft repository)
# =============================================================================

install_azure_cli() {
  tui_header "Azure CLI (Official Microsoft Repo)" 7

  if command -v az &>/dev/null; then
    local current_ver
    current_ver=$(az version 2>/dev/null \
      | grep '"azure-cli"' | awk '{print $2}' | tr -d '",' \
      || echo "unknown")
    echo -e "  ${YELLOW}${WARN}${RESET}  Azure CLI already installed (${current_ver}). Skipping."
    INSTALL_STATUS["azure-cli"]="already-installed"
    INSTALL_VERSION["azure-cli"]="${current_ver}"
    return 0
  fi

  case "${OS_TYPE}" in
    debian)
      # Microsoft's official one-liner installer (handles any Debian/Ubuntu version)
      local tmp_script
      tmp_script=$(mktemp /tmp/installer.XXXXXX.sh)
      chmod 700 "${tmp_script}"
      run_cmd "Downloading Microsoft install script" \
        curl -fsSL https://aka.ms/InstallAzureCLIDeb -o "${tmp_script}" || true
      run_cmd "Running Azure CLI installer" bash "${tmp_script}" || true
      rm -f "${tmp_script}"
      ;;
    rhel)
      run_cmd "Importing Microsoft GPG key" \
        rpm --import https://packages.microsoft.com/keys/microsoft.asc || true
      run_cmd "Adding Azure CLI RPM repo" bash -c "
        cat > /etc/yum.repos.d/azure-cli.repo <<'REPO'
[azure-cli]
name=Azure CLI
baseurl=https://packages.microsoft.com/yumrepos/azure-cli
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
REPO
      " || true
      run_cmd "Installing azure-cli" bash -c "${PKG_INSTALL} azure-cli" || true
      ;;
    arch)
      # azure-cli is not in official Arch repos; install via pip
      run_cmd "Installing azure-cli via pip3" bash -c "
        pip3 install --break-system-packages azure-cli 2>/dev/null \
          || pip3 install azure-cli || true
      " || true
      ;;
    suse)
      run_cmd "Importing Microsoft GPG key" \
        rpm --import https://packages.microsoft.com/keys/microsoft.asc || true
      run_cmd "Adding Azure CLI zypper repo" bash -c "
        zypper addrepo --gpgcheck \
          https://packages.microsoft.com/yumrepos/azure-cli azure-cli || true
      " || true
      run_cmd "Installing azure-cli" \
        zypper install -y --from azure-cli azure-cli || true
      ;;
  esac

  local installed_ver
  installed_ver=$(az version 2>/dev/null \
    | grep '"azure-cli"' | awk '{print $2}' | tr -d '",' \
    || echo "unknown")
  INSTALL_STATUS["azure-cli"]="installed"
  INSTALL_VERSION["azure-cli"]="${installed_ver}"
}

# =============================================================================
# SECTION 8 — HASHICORP VAULT  (official HashiCorp repositories)
# =============================================================================

install_vault() {
  tui_header "HashiCorp Vault (Official Repo)" 8

  if command -v vault &>/dev/null; then
    local current_ver
    current_ver=$(vault version 2>/dev/null | awk '{print $2}' || echo "unknown")
    echo -e "  ${YELLOW}${WARN}${RESET}  Vault already installed (${current_ver}). Skipping."
    INSTALL_STATUS["vault"]="already-installed"
    INSTALL_VERSION["vault"]="${current_ver}"
    return 0
  fi

  case "${OS_TYPE}" in
    debian)
      run_cmd "Adding HashiCorp GPG key" bash -c "
        curl -fsSL https://apt.releases.hashicorp.com/gpg \
          | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
      " || true
      run_cmd "Adding HashiCorp APT repo" bash -c "
        echo \"deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \\
          https://apt.releases.hashicorp.com \\
          \$(lsb_release -cs) main\" \\
          | tee /etc/apt/sources.list.d/hashicorp.list
      " || true
      run_cmd "Updating package index (vault)" apt-get update || true
      run_cmd "Installing vault" apt-get install -y vault || true
      ;;
    rhel)
      run_cmd "Installing yum-utils" bash -c "${PKG_INSTALL} yum-utils" || true
      run_cmd "Adding HashiCorp yum repo" bash -c "
        yum-config-manager --add-repo \
          https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
      " || true
      run_cmd "Installing vault" bash -c "${PKG_INSTALL} vault" || true
      ;;
    arch|suse)
      # Ensure unzip is available before extraction
      case "${OS_TYPE}" in
        arch) run_cmd "Installing unzip" pacman -S --noconfirm --needed unzip || true ;;
        suse) run_cmd "Installing unzip" zypper install -y unzip || true ;;
      esac
      run_cmd "Downloading and verifying Vault binary" bash -c "
        VAULT_VER=\$(curl -fsSL https://api.releases.hashicorp.com/v1/releases/vault/latest \
          | grep -o '\"version\":\"[^\"]*\"' | head -1 | cut -d'\"' -f4)
        ARCH_NAME=\"amd64\"
        case \"\$(uname -m)\" in
          aarch64|arm64) ARCH_NAME=\"arm64\" ;;
          arm*)          ARCH_NAME=\"arm\"   ;;
        esac
        VAULT_ZIP=\"vault_\${VAULT_VER}_linux_\${ARCH_NAME}.zip\"
        curl -fsSL \"https://releases.hashicorp.com/vault/\${VAULT_VER}/\${VAULT_ZIP}\" \
          -o \"/tmp/\${VAULT_ZIP}\"
        curl -fsSL \"https://releases.hashicorp.com/vault/\${VAULT_VER}/vault_\${VAULT_VER}_SHA256SUMS\" \
          -o /tmp/vault_SHA256SUMS
        cd /tmp
        grep \"\${VAULT_ZIP}\" vault_SHA256SUMS | sha256sum --check --status
        unzip -o \"/tmp/\${VAULT_ZIP}\" vault -d /usr/local/bin/
        chmod +x /usr/local/bin/vault
        rm -f \"/tmp/\${VAULT_ZIP}\" /tmp/vault_SHA256SUMS
      " || true
      ;;
  esac

  local installed_ver
  installed_ver=$(vault version 2>/dev/null | awk '{print $2}' || echo "unknown")
  INSTALL_STATUS["vault"]="installed"
  INSTALL_VERSION["vault"]="${installed_ver}"
}

# =============================================================================
# SECTION 9 — NODE.JS LTS  (NodeSource official setup script)
# =============================================================================

install_node() {
  tui_header "Node.js LTS (NodeSource)" 9

  if command -v node &>/dev/null; then
    local current_ver
    current_ver=$(node --version 2>/dev/null || echo "unknown")
    echo -e "  ${YELLOW}${WARN}${RESET}  Node.js already installed (${current_ver}). Skipping."
    INSTALL_STATUS["nodejs"]="already-installed"
    INSTALL_VERSION["nodejs"]="${current_ver}"
    return 0
  fi

  case "${OS_TYPE}" in
    debian)
      local tmp_script
      tmp_script=$(mktemp /tmp/installer.XXXXXX.sh)
      chmod 700 "${tmp_script}"
      run_cmd "Downloading NodeSource LTS setup" \
        curl -fsSL https://deb.nodesource.com/setup_lts.x -o "${tmp_script}" || true
      run_cmd "Running NodeSource setup" bash "${tmp_script}" || true
      run_cmd "Installing nodejs" apt-get install -y nodejs || true
      rm -f "${tmp_script}"
      ;;
    rhel)
      local tmp_script
      tmp_script=$(mktemp /tmp/installer.XXXXXX.sh)
      chmod 700 "${tmp_script}"
      run_cmd "Downloading NodeSource LTS setup" \
        curl -fsSL https://rpm.nodesource.com/setup_lts.x -o "${tmp_script}" || true
      run_cmd "Running NodeSource setup" bash "${tmp_script}" || true
      run_cmd "Installing nodejs" bash -c "${PKG_INSTALL} nodejs" || true
      rm -f "${tmp_script}"
      ;;
    arch)
      run_cmd "Installing nodejs npm (pacman)" \
        pacman -S --noconfirm --needed nodejs npm || true
      ;;
    suse)
      local tmp_script
      tmp_script=$(mktemp /tmp/installer.XXXXXX.sh)
      chmod 700 "${tmp_script}"
      run_cmd "Downloading NodeSource LTS setup" \
        curl -fsSL https://rpm.nodesource.com/setup_lts.x -o "${tmp_script}" || true
      run_cmd "Running NodeSource setup" bash "${tmp_script}" || true
      run_cmd "Installing nodejs" bash -c "${PKG_INSTALL} nodejs npm" || true
      rm -f "${tmp_script}"
      ;;
  esac

  local installed_ver
  installed_ver=$(node --version 2>/dev/null || echo "unknown")
  INSTALL_STATUS["nodejs"]="installed"
  INSTALL_VERSION["nodejs"]="${installed_ver}"
}

# =============================================================================
# SECTION 10 — NPM GLOBAL PACKAGES
# =============================================================================

install_npm_globals() {
  tui_header "npm Global Packages" 10

  if ! command -v npm &>/dev/null; then
    echo -e "  ${YELLOW}${WARN}${RESET}  npm not available — skipping npm global packages."
    INSTALL_STATUS["npm-globals"]="skipped (npm not found)"
    return 0
  fi

  local npm_packages=("eslint" "webpack" "terser" "handlebars" "@angular/cli")
  local pkg
  for pkg in "${npm_packages[@]}"; do
    run_cmd "Installing ${pkg}@latest" npm install -g "${pkg}@latest" || true
  done

  INSTALL_STATUS["npm-globals"]="installed"
  INSTALL_VERSION["npm-globals"]=$(npm --version 2>/dev/null || echo "unknown")
}

# =============================================================================
# SECTION 11 — PYTHON 3
# =============================================================================

install_python() {
  tui_header "Python 3" 11

  case "${OS_TYPE}" in
    debian)
      run_cmd "Installing python3"       apt-get install -y python3       || true
      run_cmd "Installing python3-pip"   apt-get install -y python3-pip   || true
      run_cmd "Installing python3-dev"   apt-get install -y python3-dev   || true
      run_cmd "Installing python3-venv"  apt-get install -y python3-venv  || true
      ;;
    rhel)
      run_cmd "Installing python3"       bash -c "${PKG_INSTALL} python3"         || true
      run_cmd "Installing python3-pip"   bash -c "${PKG_INSTALL} python3-pip"     || true
      run_cmd "Installing python3-devel" bash -c "${PKG_INSTALL} python3-devel"   || true
      ;;
    arch)
      run_cmd "Installing python python-pip" \
        pacman -S --noconfirm --needed python python-pip || true
      ;;
    suse)
      run_cmd "Installing python3"        bash -c "${PKG_INSTALL} python3"        || true
      run_cmd "Installing python3-pip"    bash -c "${PKG_INSTALL} python3-pip"    || true
      run_cmd "Installing python3-devel"  bash -c "${PKG_INSTALL} python3-devel"  || true
      ;;
  esac

  local installed_ver
  installed_ver=$(python3 --version 2>/dev/null | awk '{print $2}' || echo "unknown")
  INSTALL_STATUS["python3"]="installed"
  INSTALL_VERSION["python3"]="${installed_ver}"
}

# =============================================================================
# SECTION 12 — POSTGRESQL CLIENT  (official PostgreSQL APT repo for latest)
# =============================================================================

install_pg_client() {
  tui_header "PostgreSQL Client" 12

  case "${OS_TYPE}" in
    debian)
      # Use official PostgreSQL Global Development Group repo for latest version
      run_cmd "Adding PGDG APT key" bash -c "
        curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
          | gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg
      " || true
      run_cmd "Adding PGDG APT repo" bash -c "
        echo \"deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] \\
          https://apt.postgresql.org/pub/repos/apt \\
          \$(lsb_release -cs)-pgdg main\" \\
          | tee /etc/apt/sources.list.d/pgdg.list
      " || true
      run_cmd "Updating package index (pgdg)" apt-get update || true
      run_cmd "Installing postgresql-client" apt-get install -y postgresql-client || true
      ;;
    rhel)
      run_cmd "Installing postgresql" bash -c "${PKG_INSTALL} postgresql" || true
      ;;
    arch)
      run_cmd "Installing postgresql-libs" \
        pacman -S --noconfirm --needed postgresql-libs || true
      ;;
    suse)
      run_cmd "Installing postgresql" bash -c "${PKG_INSTALL} postgresql" || true
      ;;
  esac

  local installed_ver
  installed_ver=$(psql --version 2>/dev/null | awk '{print $3}' || echo "unknown")
  INSTALL_STATUS["postgresql-client"]="installed"
  INSTALL_VERSION["postgresql-client"]="${installed_ver}"
}

# =============================================================================
# SECTION 13 — REDIS TOOLS
# =============================================================================

install_redis_tools() {
  tui_header "Redis Tools" 13

  case "${OS_TYPE}" in
    debian) run_cmd "Installing redis-tools" apt-get install -y redis-tools            || true ;;
    rhel)   run_cmd "Installing redis"       bash -c "${PKG_INSTALL} redis"            || true ;;
    arch)   run_cmd "Installing redis"       pacman -S --noconfirm --needed redis      || true ;;
    suse)   run_cmd "Installing redis"       bash -c "${PKG_INSTALL} redis"            || true ;;
  esac

  local installed_ver
  installed_ver=$(redis-cli --version 2>/dev/null | awk '{print $2}' || echo "unknown")
  INSTALL_STATUS["redis-tools"]="installed"
  INSTALL_VERSION["redis-tools"]="${installed_ver}"
}

# =============================================================================
# SECTION 14 — COMMON TOOLS
# =============================================================================

install_common_tools() {
  tui_header "Common Tools" 14

  local tools_debian=(
    git vim nano nmap unzip
    nfs-common nfs-kernel-server net-tools
    openssh-server autofs sshpass bash-completion
  )
  local tools_rhel=(
    git vim nano nmap unzip
    nfs-utils net-tools
    openssh-server autofs sshpass bash-completion
  )
  local tools_arch=(
    git vim nano nmap unzip
    nfs-utils net-tools
    openssh autofs sshpass bash-completion
  )
  local tools_suse=(
    git vim nano nmap unzip
    nfs-client nfs-kernel-server net-tools
    openssh autofs sshpass bash-completion
  )

  local pkg
  case "${OS_TYPE}" in
    debian)
      for pkg in "${tools_debian[@]}"; do
        run_cmd "Installing ${pkg}" apt-get install -y "${pkg}" || true
      done
      ;;
    rhel)
      for pkg in "${tools_rhel[@]}"; do
        run_cmd "Installing ${pkg}" bash -c "${PKG_INSTALL} ${pkg}" || true
      done
      ;;
    arch)
      for pkg in "${tools_arch[@]}"; do
        run_cmd "Installing ${pkg}" pacman -S --noconfirm --needed "${pkg}" || true
      done
      ;;
    suse)
      for pkg in "${tools_suse[@]}"; do
        run_cmd "Installing ${pkg}" bash -c "${PKG_INSTALL} ${pkg}" || true
      done
      ;;
  esac

  INSTALL_STATUS["common-tools"]="installed"
  INSTALL_VERSION["common-tools"]=$(git --version 2>/dev/null | awk '{print $3}' || echo "n/a")
}

# =============================================================================
# SECTION 15 — USER & GROUP SETUP
# =============================================================================

setup_users() {
  tui_header "User & Group Setup" 15

  local target_user="${SUDO_USER:-}"
  if [[ -z "${target_user}" ]]; then
    target_user="${USER:-}"
  fi

  if [[ -z "${target_user}" ]] || [[ "${target_user}" == "root" ]]; then
    echo -e "  ${YELLOW}${WARN}${RESET}  No non-root user detected. Skipping docker group assignment."
    echo -e "  ${GRAY}Run: usermod -aG docker <your-username>  after creating a user.${RESET}"
    INSTALL_STATUS["user-setup"]="skipped (root-only session)"
    return 0
  fi

  if id -nG "${target_user}" 2>/dev/null | grep -qw docker; then
    echo -e "  ${GREEN}${CHECK}${RESET} User '${target_user}' is already in the docker group."
    INSTALL_STATUS["user-setup"]="already-configured"
  else
    run_cmd "Adding '${target_user}' to docker group" \
      usermod -aG docker "${target_user}" || true
    echo -e "  ${GRAY}Note: '${target_user}' must log out and back in for the group change to take effect.${RESET}"
    INSTALL_STATUS["user-setup"]="configured"
  fi

  INSTALL_VERSION["user-setup"]="${target_user} → docker group"
}

# =============================================================================
# SECTION 16 — SUMMARY REPORT + REBOOT PROMPT
# =============================================================================

print_summary() {
  tui_header "Setup Complete — Summary" 16

  local elapsed_min=$(( SECONDS / 60 ))
  local elapsed_sec=$(( SECONDS % 60 ))

  local box="══════════════════════════════════════════════════════════════════"
  echo ""
  echo -e "${CYAN}╔${box}╗${RESET}"
  echo -e "${CYAN}║${RESET}  ${BOLD}$(printf '%-66s' 'SETUP SUMMARY')${CYAN}║${RESET}"
  echo -e "${CYAN}╠${box}╣${RESET}"
  printf "${CYAN}║${RESET}  ${BOLD}%-20s${RESET}  %-44s${CYAN}║${RESET}\n" "OS"              "${OS_NAME:-unknown}"
  printf "${CYAN}║${RESET}  ${BOLD}%-20s${RESET}  %-44s${CYAN}║${RESET}\n" "Architecture"    "${ARCH:-unknown}"
  printf "${CYAN}║${RESET}  ${BOLD}%-20s${RESET}  %-44s${CYAN}║${RESET}\n" "Package Manager" "${PKG_MGR:-unknown}"
  printf "${CYAN}║${RESET}  ${BOLD}%-20s${RESET}  %-44s${CYAN}║${RESET}\n" "Elapsed Time"    "${elapsed_min}m ${elapsed_sec}s"
  echo -e "${CYAN}╠${box}╣${RESET}"
  printf "${CYAN}║${RESET}  ${BOLD}%-22s  %-18s  %-22s${RESET}${CYAN}║${RESET}\n" \
    "TOOL" "STATUS" "VERSION"
  echo -e "${CYAN}╠${box}╣${RESET}"

  local tools=(
    "docker" "kubectl" "helm" "azure-cli" "vault"
    "nodejs" "npm-globals" "python3"
    "postgresql-client" "redis-tools" "common-tools"
    "base-packages" "user-setup"
  )

  local tool status_val version_val status_display color
  for tool in "${tools[@]}"; do
    status_val="${INSTALL_STATUS[${tool}]:-not-run}"
    version_val="${INSTALL_VERSION[${tool}]:-—}"

    case "${status_val}" in
      installed|already-installed|already-configured|configured|OK)
        color="${GREEN}"; status_display="${CHECK} ${status_val}" ;;
      skipped*)
        color="${YELLOW}"; status_display="${WARN} skipped" ;;
      *)
        color="${RED}";   status_display="${CROSS} ${status_val}" ;;
    esac

    printf "${CYAN}║${RESET}  %-22s  ${color}%-18s${RESET}  %-22s${CYAN}║${RESET}\n" \
      "${tool}" "${status_display}" "${version_val:0:22}"
  done

  echo -e "${CYAN}╠${box}╣${RESET}"
  local log_display
  if [[ -s "${LOG_FILE}" ]]; then
    log_display="$(basename "${LOG_FILE}") (${TOTAL_ERRORS} error(s))"
  else
    log_display="no errors"
  fi
  printf "${CYAN}║${RESET}  ${BOLD}%-20s${RESET}  %-44s${CYAN}║${RESET}\n" \
    "Log file" "${log_display}"
  echo -e "${CYAN}╚${box}╝${RESET}"
  echo ""
}

reboot_prompt() {
  echo -e "${BOLD}A system reboot is recommended to apply all changes.${RESET}"
  echo -e "${GRAY}(docker group membership, kernel updates, etc.)${RESET}"
  echo ""
  local answer
  read -rp "  Reboot now? [y/N]: " answer
  case "${answer,,}" in
    y|yes)
      echo -e "\n${YELLOW}Rebooting in 5 seconds... Press Ctrl+C to cancel.${RESET}"
      sleep 5
      reboot
      ;;
    *)
      echo -e "\n${GRAY}Skipping reboot. Remember to reboot later to apply all changes.${RESET}"
      ;;
  esac
}

# =============================================================================
# MAIN ORCHESTRATOR
# =============================================================================

main() {
  # Pre-create log file so it always exists for reference
  touch "${LOG_FILE}"

  check_root
  tui_banner

  detect_os          # Section  1
  system_update      # Section  2  (FATAL on failure)
  install_base       # Section  3
  install_docker     # Section  4
  install_kubectl    # Section  5
  install_helm       # Section  6
  install_azure_cli  # Section  7
  install_vault      # Section  8
  install_node       # Section  9
  install_npm_globals # Section 10
  install_python     # Section 11
  install_pg_client  # Section 12
  install_redis_tools # Section 13
  install_common_tools # Section 14
  setup_users        # Section 15

  print_summary      # Section 16
  reboot_prompt
}

main "$@"
