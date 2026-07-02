# VM/VPS Setup Script — Consolidated Design Document

**Date:** 2026-07-02
**Author:** HuyNguyen2109
**Status:** Approved

> This document consolidates and supersedes:
> - `2026-05-21-vm-setup-script-design.md` (original design)
> - `2026-06-04-vm-setup-script-additions-design.md` (tool additions)
> - `2026-07-02-vm-setup-script-menu-design.md` (interactive menu)

---

## Version History

| Date | Change |
|---|---|
| 2026-05-21 | Original design — 16 sections, core tools |
| 2026-06-04 | Added AWS CLI v2, Velero, jq, yq, shellcheck, bind9-dnsutils, netcat-openbsd, libssl-dev, libffi-dev, locales, dialog. Sections renumbered to 18. |
| 2026-07-02 | Added interactive TUI mode selection menu (full or selective installation) |

---

## Overview

A single self-contained Bash script (`scripts/vm-setup.sh`) that automates the full setup of a fresh VM/VPS. It detects the host OS, runs a full system update/upgrade, installs all user-installed tools, and provides a rich TUI with spinners, progress bars, colored headers, and ✓/✗ per-command feedback. Errors are written to a timestamped `.log` file beside the script. A summary report and optional reboot prompt conclude the run.

**Version policy:** The script never pins package versions. It always installs the **latest available version** at the time of execution.

**Mode selection:** At startup, the user chooses between:
- **Full Installation** — runs all 18 sections sequentially (original behavior)
- **Selective Installation** — multi-select checklist to pick individual sections
- **Exit** — graceful exit

---

## 1. Scope

### Packages to Install

| Group | Packages |
|---|---|
| Container | docker-ce, docker-ce-cli, docker-buildx-plugin, docker-compose-plugin, containerd.io |
| Kubernetes | kubectl, helm |
| Cloud/Secrets | azure-cli, vault (HashiCorp), aws-cli |
| Backup | velero |
| Language runtimes | python3, python3-pip, python3-dev, python3-venv, nodejs, npm |
| DB clients | postgresql-client, redis-tools |
| Dev tools | git, vim, nano, build-essential (distro-mapped), curl, wget, unzip, jq, yq, shellcheck |
| Network | nmap, nfs-common, nfs-kernel-server, net-tools, openssh-server, bind9-dnsutils/bind-utils, netcat-openbsd/nmap-ncat |
| Utilities | autofs, sshpass, bash-completion, libssl-dev, libffi-dev, locales, dialog |

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
│     tui_banner()          → Welcome banner with box-drawing chars
│     tui_header()          → Colored section header + progress bar
│     draw_progress_bar()   → Filled bar + percentage + [step/total]
│     spinner_start()       → Background spinner per command
│     spinner_stop()        → Stop spinner, print ✓/✗
│     run_cmd()             → Wrapper: spinner → exec → log on failure
│     log_error()           → Append timestamped error to .log file
│     cleanup()             → Kill spinner + remove temp files on exit
│     check_root()          → Warn if not run as root / with sudo
│
├── SECTION 1  — detect_os           → OS detection
├── SECTION 2  — system_update       → System update/upgrade (FATAL)
├── SECTION 3  — install_base        → Base system packages
├── SECTION 4  — install_docker      → Docker Engine
├── SECTION 5  — install_kubectl     → kubectl
├── SECTION 6  — install_helm        → Helm
├── SECTION 7  — install_azure_cli   → Azure CLI + Vault secrets
├── SECTION 8  — install_vault       → HashiCorp Vault
├── SECTION 9  — install_node        → Node.js LTS
├── SECTION 10 — install_npm_globals → npm global packages
├── SECTION 11 — install_python      → Python 3
├── SECTION 12 — install_pg_client   → PostgreSQL client
├── SECTION 13 — install_redis_tools → Redis tools
├── SECTION 14 — install_common_tools→ Common tools (git, jq, yq, etc.)
├── SECTION 15 — install_aws_cli     → AWS CLI v2
├── SECTION 16 — install_velero      → Velero
├── SECTION 17 — setup_users         → User/group setup (docker group)
├── SECTION 18 — print_summary       → Summary report
├── MODE MENU
│     show_mode_menu()         → Full / Selective / Exit chooser
│     run_full_install()       → All 16 sections + summary + reboot
│     run_selective_install()  → Checklist + selected sections + summary
│
└── reboot_prompt()            → Interactive y/N; y → sudo reboot
```

---

## 3. Required Environment Variables

```bash
# VAULT (must be set in ~/.bashrc on the target machine)
#   VAULT_ADDR          - Vault server address (e.g. https://vault.example.com:8200)
#   VAULT_TOKEN         - Authentication token for Vault CLI
#
# AZURE (auto-fetched from Vault, written to ~/.bashrc by Section 7)
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
| openssl-devel | libssl-dev | openssl-devel | openssl | libopenssl-devel |
| libffi-devel | libffi-dev | libffi-devel | libffi | libffi-devel |
| locales | locales | glibc-locale-source | (built-in) | glibc-locale |
| dialog | dialog | dialog | dialog | dialog |
| jq | jq | jq | jq | jq |
| shellcheck | shellcheck | epel-release → shellcheck | shellcheck | ShellCheck |
| dnsutils | bind9-dnsutils | bind-utils | bind-utils | bind-utils |
| netcat | netcat-openbsd | nmap-ncat | openbsd-netcat | netcat-openbsd |

---

## 5. Official Installation Methods

| Tool | Method | Version strategy |
|---|---|---|
| Docker | Docker apt/yum/pacman repo + GPG key | Latest stable |
| kubectl | Kubernetes apt/yum repo + GPG key | Latest stable |
| helm | Official get-helm-3 script | Latest stable |
| azure-cli | Microsoft apt/rpm repo + GPG key (Debian: one-liner installer) | Latest from Microsoft repo |
| vault | HashiCorp apt/rpm/pacman repo; Arch/SUSE: binary download from releases | Latest |
| aws-cli | Official standalone installer zip + SHA256 verification | Latest |
| velero | GitHub releases binary tarball + SHA256 verification | Latest |
| yq | GitHub releases binary | Latest |
| nodejs | NodeSource setup script (LTS channel) | Latest LTS |
| npm globals | `npm install -g <pkg>@latest` | Latest |
| All PM packages | `apt-get install -y <pkg>` (no version pin) | Latest in repo |

---

## 6. TUI Design

### Welcome Banner

```
  ╔══════════════════════════════════════════════════════════╗
  ║          VM/VPS Automated Setup Script v1.2               ║
  ║              github.com/HuyNguyen2109                   ║
  ╚══════════════════════════════════════════════════════════╝

  Started : 2026-07-02 12:00:00
  Log file: setup-20260702-120000.log
```

### Mode Selection Menu

```
  ╔══════════════════════════════════════════════════════════╗
  ║              Installation Mode Selection                  ║
  ╚══════════════════════════════════════════════════════════╝

  1) Full Installation (all 18 sections)
  2) Selective Installation (choose individual sections)

  0) Exit

  Enter your choice [0-2]:
```

### Selective Checklist

```
  ╔══════════════════════════════════════════════════════════╗
  ║              Select Sections to Install                  ║
  ╚══════════════════════════════════════════════════════════╝

  [n] 1) System Update & Upgrade
  [n] 2) Base System Packages
  ...
  [n] 16) User & Group Setup

  Enter choice (e.g. 1-16) or 'a' for all, 'd' when done:
```

- Entering a number toggles that section on/off (`[y]` / `[n]`)
- `a` enables all sections at once
- `d` confirms selection and begins installation

### Section Progress Display

```
  ╔══════════════════════════════════════════════════════════╗
  ║  [05/18] ► Docker Engine (Official)                      ║
  ╚══════════════════════════════════════════════════════════╝
  ████████░░░░░░░░░░░░░░░░░░░░░░░░░░  20%  [5/18 sections]

  ✓ Installing ca-certificates ... OK
  ⠋ Installing Docker Engine...
  ✓ Installing Docker Engine      OK
  ✓ Enabling Docker service       OK
```

### Colors

- Section headers: **Cyan**
- ✓ success: **Green**
- ✗ failure: **Red**
- Progress bar filled: **Blue**
- Progress bar empty: **Dark grey**
- Spinner: **Yellow**
- General info: **Dark grey**

---

## 7. Error Handling

- `run_cmd()` captures stdout+stderr to a temp file.
- On non-zero exit: prints ✗ in red, appends entry to `<script_dir>/setup-YYYYMMDD-HHMMSS.log`.
- Individual package failures are **non-fatal** (script continues, `TOTAL_ERRORS` incremented).
- System update/upgrade failure is **fatal** (exits, shows log path).
- Log format:
  ```
  ════════════════════════════════════════════════════════
  [2026-07-02 12:00:00] ERROR: Installing Docker Engine
  Command  : apt-get install -y docker-ce docker-ce-cli containerd.io
  Exit code: 1
  Output   :
    E: Package 'docker-ce' has no installation candidate
  ```

---

## 8. User/Group Setup

- Detects `$SUDO_USER` (the real user who invoked sudo) or falls back to `$USER`.
- Adds that user to the `docker` group via `usermod -aG docker <user>`.
- Skips if the user is already in the docker group.
- Skips if running as root directly (no non-root user detected).

---

## 9. Summary Report

Box-drawn table printed to terminal at end of run:
- OS/arch info row
- Per-tool row: name | ✓/✗ status | installed version (from `--version` or package query)
- In selective mode: only shows rows for selected sections
- In full mode: shows all 15 tool rows
- Log file path + total error count
- Elapsed time

---

## 10. Global Variables

| Variable | Type | Purpose |
|---|---|---|
| `INSTALL_STATUS` | Associative array | Per-tool status (installed/skipped/not-run) |
| `INSTALL_VERSION` | Associative array | Per-tool version string |
| `TOTAL_ERRORS` | Integer | Accumulated failure count |
| `TOTAL_SECTIONS` | Integer | Total sections (18 full, dynamic in selective mode) |
| `SUMMARY_FILTER` | Array | Populated in selective mode; limits summary rows |
| `TMP_FILES` | Array | Temp file paths cleaned by `cleanup()` trap |

---

## 11. Files

| Path | Purpose |
|---|---|
| `scripts/vm-setup.sh` | Main setup script (executable, ~1424 lines) |
| `setup-YYYYMMDD-HHMMSS.log` | Error log, created at script location at runtime |
| `docs/superpowers/specs/2026-07-02-vm-setup-script-comprehensive-design.md` | This consolidated design document |
| `docs/superpowers/plans/2026-05-21-vm-setup-script.md` | Implementation plan (updated with post-implementation additions) |

---

## Related Documents

- `docs/superpowers/specs/2026-05-21-vm-setup-script-design.md` — Original design (superseded)
- `docs/superpowers/specs/2026-06-04-vm-setup-script-additions-design.md` — Tool additions (superseded)
- `docs/superpowers/specs/2026-07-02-vm-setup-script-menu-design.md` — Interactive menu (superseded)
- `docs/superpowers/plans/2026-05-21-vm-setup-script.md` — Implementation plan
