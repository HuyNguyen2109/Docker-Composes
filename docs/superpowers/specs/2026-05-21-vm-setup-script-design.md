# VM/VPS Setup Script — Design Document

**Date:** 2026-05-21  
**Author:** HuyNguyen2109  
**Status:** Approved

---

## Overview

A single self-contained Bash script (`scripts/vm-setup.sh`) that automates the full setup of a fresh VM/VPS. It detects the host OS, runs a full system update/upgrade, installs all user-installed tools (mapped from an existing machine's package scan), and provides a rich TUI with spinners, progress bars, colored headers, and ✓/✗ per-command feedback. Errors are written to a timestamped `.log` file beside the script. A summary report and optional reboot prompt conclude the run.

**Version policy:** The script never pins package versions. It always installs the **latest available version** at the time of execution. If a newer version exists than what was on the source machine, the newer version is installed. The summary report reflects the actual version installed.

---

## 1. Scope

### Packages to Install

Derived from scanning this machine's installed packages, filtered to meaningful user-installed tools:

| Group | Packages |
|---|---|
| Container | docker-ce, docker-ce-cli, docker-buildx-plugin, docker-compose-plugin, containerd.io |
| Kubernetes | kubectl, helm |
| Cloud/Secrets | azure-cli, vault (HashiCorp) |
| Language runtimes | python3, python3-pip, python3-dev, python3-venv, nodejs, npm |
| DB clients | postgresql-client (v17), redis-tools |
| Dev tools | git, vim, nano, build-essential (distro-mapped), curl, wget, unzip |
| Network | nmap, nfs-common, nfs-kernel-server, net-tools, openssh-server |
| Utilities | autofs, sshpass, bash-completion |

### Supported Linux Distributions

| Family | Package Manager | Distros |
|---|---|---|
| Debian/Ubuntu | apt | Debian, Ubuntu, Mint, Kali, Pop!_OS |
| RHEL | dnf / yum | RHEL, CentOS, AlmaLinux, Rocky, Fedora |
| Arch | pacman | Arch Linux, Manjaro, EndeavourOS |
| SUSE | zypper | openSUSE Leap/Tumbleweed, SLES |

---

## 2. Script Structure

```
vm-setup.sh
├── HEADER: Required env var comment block
├── CONSTANTS: Colors, Unicode symbols, log file path, version
├── CORE UTILS
│     tui_header()      → Colored section header with box-drawing chars
│     progress_bar()    → Filled bar + percentage + [step/total]
│     spinner_start()   → Background spinner (⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏) per command
│     spinner_stop()    → Stop background spinner, print ✓/✗
│     run_cmd()         → Wrapper: spinner → exec → log on failure
│     log_error()       → Append timestamped error to .log file
│     check_root()      → Warn if not run as root / with sudo
│
├── SECTION 1 — OS Detection
│     detect_os()       → Sets $OS_TYPE, $OS_NAME, $PKG_MGR, $ARCH, $DISTRO_CODENAME
│
├── SECTION 2 — System Update/Upgrade
│     system_update()   → Full update + upgrade per $PKG_MGR (FATAL on failure)
│
├── SECTION 3 — Base System Packages
│     install_base()    → Distro-mapped:
│                          Debian:  build-essential
│                          RHEL:    "Development Tools" group + gcc make
│                          Arch:    base-devel
│                          SUSE:    patterns-devel-base gcc make
│
├── SECTION 4 — Tool Installation Functions
│     install_docker()       → Official docs (get.docker.com + post-install)
│     install_kubectl()      → Official Kubernetes apt/yum/pacman/zypper repos
│     install_helm()         → Official helm.sh install script
│     install_azure_cli()    → Official Microsoft repo method per distro
│     install_vault()        → Official HashiCorp repo method per distro
│     install_node()         → NodeSource official setup script (LTS)
│     install_python()       → PM search: python3, pip, dev headers, venv
│     install_pg_client()    → PM search: postgresql-client (distro-mapped name)
│     install_redis_tools()  → PM search: redis-tools / redis
│     install_common_tools() → PM search: git vim nano curl wget unzip nmap
│                              nfs-common/nfs-utils net-tools openssh-server
│                              autofs sshpass bash-completion
│     install_npm_globals()  → npm install -g (after Node.js):
│                              eslint, webpack, terser, handlebars, @angular/cli
│
├── SECTION 5 — User / Group Setup
│     setup_users()     → Add $SUDO_USER (or current user) to docker group
│
├── SECTION 6 — Summary Report
│     print_summary()   → Box-drawn table with OS info, each tool status + version
│
└── SECTION 7 — Reboot Prompt
      reboot_prompt()   → Interactive y/N; y → sudo reboot
```

---

## 3. Required Environment Variables (Header Comment Block)

```bash
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
```

---

## 4. Cross-Distro Package Name Mapping

| Logical name | Debian/Ubuntu | RHEL/Fedora | Arch | SUSE |
|---|---|---|---|---|
| build-essential | build-essential | @"Development Tools" + gcc make | base-devel | patterns-devel-base gcc make |
| postgresql-client | postgresql-client | postgresql | postgresql-libs | postgresql |
| redis-tools | redis-tools | redis | redis | redis |
| nfs-client | nfs-common | nfs-utils | nfs-utils | nfs-client |
| nfs-server | nfs-kernel-server | nfs-utils | nfs-utils | nfs-kernel-server |
| openssh-server | openssh-server | openssh-server | openssh | openssh |
| python3-pip | python3-pip | python3-pip | python-pip | python3-pip |
| python3-dev | python3-dev | python3-devel | (built-in) | python3-devel |

---

## 5. Official Installation Methods

| Tool | Method | Version strategy |
|---|---|---|
| Docker | `curl -fsSL https://get.docker.com \| sh` + Docker apt/yum/pacman repos | Latest stable |
| kubectl | Kubernetes apt/yum repo + GPG key | Latest stable release |
| helm | `curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \| bash` | Latest stable |
| azure-cli | Microsoft apt/rpm repo + GPG key | Latest from Microsoft repo |
| vault | HashiCorp apt/rpm/pacman repo | Latest from HashiCorp repo |
| nodejs | NodeSource setup script (LTS channel) | Latest LTS |
| npm globals | `npm install -g <pkg>@latest` | Latest |
| All PM packages | `apt-get install -y <pkg>` (no version pin) | Latest in repo |

---

## 6. TUI Design

### Progress Display (combined)
```
╔══════════════════════════════════════════╗
║  VM/VPS Setup Script  v1.0               ║
╚══════════════════════════════════════════╝

[SECTION 4/7] ► Installing User Tools
████████████░░░░░░░░  60%  [6/10 packages]

  ⠋ Installing docker-ce...
  ✓ docker-ce            installed  (28.1.1)
  ✗ some-pkg             FAILED     → see setup-20260521-031525.log
```

### Colors
- Section headers: **Cyan**
- ✓ success: **Green**
- ✗ failure: **Red**
- Progress bar filled: **Blue**
- Progress bar empty: **Dark grey**
- Spinner: **Yellow**

---

## 7. Error Handling

- `run_cmd()` captures stdout+stderr to temp file.
- On non-zero exit: prints ✗ in red, appends entry to `<script_dir>/setup-YYYYMMDD-HHMMSS.log`.
- Individual package failures are **non-fatal** (script continues).
- System update/upgrade failure is **fatal** (exits, shows log path).
- Log format:
  ```
  [2026-05-21 03:15:25] ERROR in SECTION 4 - install_docker
  Command: apt-get install -y docker-ce
  Exit code: 1
  Output:
    E: Package 'docker-ce' has no installation candidate
  ```

---

## 8. User/Group Setup

- Detects `$SUDO_USER` (the real user who invoked sudo) or falls back to `$USER`.
- Adds that user to the `docker` group via `usermod -aG docker <user>`.
- Skips if the user is already in the docker group.
- Logs the change.

---

## 9. Summary Report

Box-drawn table printed to terminal at end of run:
- OS/arch info row
- Per-tool row: name | ✓/✗ status | installed version (from `--version` or package query)
- Total counts: N installed, M failed
- Log file path
- Elapsed time

---

## 10. Files

| Path | Purpose |
|---|---|
| `scripts/vm-setup.sh` | Main setup script (executable) |
| `setup-YYYYMMDD-HHMMSS.log` | Error log, created at script location at runtime |
