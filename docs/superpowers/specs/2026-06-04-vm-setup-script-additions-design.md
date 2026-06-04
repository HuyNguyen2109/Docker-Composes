# vm-setup.sh Additions Design
**Date:** 2026-06-04
**Scope:** Update `scripts/vm-setup.sh` to include tools discovered on the current homelab machine that are not yet covered.

---

## Context

The existing script (`vm-setup.sh` v1.0) provisions new VMs with 16 sections covering: OS detection, system update, base packages, Docker, kubectl, Helm, Azure CLI, HashiCorp Vault, Node.js LTS, npm globals, Python 3, PostgreSQL client, Redis tools, common tools, user setup, and summary.

A machine scan (2026-06-04) revealed the following tools installed on the homelab that are missing from the script:

| Tool | Version Found | Install Method |
|---|---|---|
| AWS CLI v2 | 2.34.26 | Official standalone installer |
| Velero | v1.18.0 | GitHub releases binary |
| jq | — (not installed, common) | apt / distro package |
| yq | — (not installed, common) | GitHub releases binary |
| shellcheck | apt | apt / distro package |
| bind9-dnsutils | apt | apt / distro package |
| netcat-openbsd | apt | apt / distro package |
| libssl-dev, libffi-dev | apt | apt / distro package |
| locales, dialog | apt | apt / distro package |

---

## Design

### Approach: One new section per major standalone tool (Option B)

Each new standalone binary tool gets its own numbered section, consistent with the script's existing one-tool-per-section convention. Utility packages are folded into the nearest logical existing section. `TOTAL_SECTIONS` is updated from 16 to 18.

### Section map (new/modified)

| Section | Function | Status |
|---|---|---|
| 1 | `detect_os` | Unchanged |
| 2 | `system_update` | Unchanged |
| 3 | `install_base` | **Modified** — add `libssl-dev libffi-dev locales dialog` |
| 4 | `install_docker` | Unchanged |
| 5 | `install_kubectl` | Unchanged |
| 6 | `install_helm` | Unchanged |
| 7 | `install_azure_cli` | Unchanged |
| 8 | `install_vault` | Unchanged |
| 9 | `install_node` | Unchanged |
| 10 | `install_npm_globals` | Unchanged |
| 11 | `install_python` | Unchanged |
| 12 | `install_pg_client` | Unchanged |
| 13 | `install_redis_tools` | Unchanged |
| 14 | `install_common_tools` | **Modified** — add `jq yq shellcheck bind9-dnsutils netcat-openbsd` |
| 15 | `install_aws_cli` | **New** |
| 16 | `install_velero` | **New** |
| 17 | `setup_users` | Renumbered (was 15) |
| 18 | `print_summary` | Renumbered (was 16), gains two rows |

### Section 3 — Base packages (modification)

Add to the Debian branch:
- `libssl-dev` — OpenSSL development headers (needed by Python packages, pip, etc.)
- `libffi-dev` — FFI headers (needed by cffi/cryptography Python packages)
- `locales` — locale data (avoids Perl/Python locale warnings on minimal images)
- `dialog` — TUI dialog boxes (used by some installers)

Add equivalent packages to RHEL (`openssl-devel libffi-devel glibc-locale-source`), Arch (`openssl libffi`), and SUSE (`libopenssl-devel libffi-devel glibc-locale`).

### Section 14 — Common tools (modification)

Add to all distros:
- `jq` — JSON processor (universal apt/dnf/pacman/zypper name)
- `shellcheck` — Shell script linter (apt: `shellcheck`; rhel: install `epel-release` then `shellcheck`; arch: `shellcheck`; suse: `ShellCheck`)
- `bind9-dnsutils` (Debian) / `bind-utils` (RHEL/SUSE/Arch) — provides `dig` and `nslookup`
- `netcat-openbsd` (Debian) / `nmap-ncat` (RHEL) / `openbsd-netcat` (Arch) / `netcat-openbsd` (SUSE) — `nc` command

For `yq`: installed as a binary from GitHub releases (no universal distro package), using the same verify-then-install pattern as Velero/Vault — download latest release, verify SHA256, install to `/usr/local/bin/yq`.

### Section 15 — AWS CLI v2 (new)

**Why standalone section:** AWS CLI uses its own official installer script (not a distro package). The installation method is the same across all distributions.

**Install flow:**
1. Skip if `aws --version` succeeds (idempotent).
2. Download the official installer zip: `https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip` (arm64 variant for aarch64).
3. Verify SHA256: download `https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip.sha256` and run `sha256sum --check`.
4. Unzip to a temp directory.
5. Run `./aws/install` (or `./aws/install --update` if already present).
6. Clean up temp directory.
7. Record version: `aws --version`.

**Architecture detection:** `uname -m` → `aarch64` maps to `awscli-exe-linux-aarch64.zip`.

**Error handling:** Non-fatal (consistent with other sections).

### Section 16 — Velero (new)

**Why standalone section:** Velero is a Kubernetes backup/restore tool, installed as a standalone binary from GitHub releases — same pattern as Vault on Arch/SUSE.

**Install flow:**
1. Skip if `velero version --client-only` succeeds (idempotent).
2. Query latest release from GitHub API: `https://api.github.com/repos/vmware-tanzu/velero/releases/latest`.
3. Download binary tarball: `velero-vX.Y.Z-linux-amd64.tar.gz` (arm64 variant for aarch64).
4. Download SHA256 checksums file.
5. Verify SHA256.
6. Extract `velero` binary, install to `/usr/local/bin/velero`, set executable.
7. Clean up temp files.
8. Record version: `velero version --client-only`.

### Summary table (Section 18)

Add `aws-cli` and `velero` rows to the `tools` array in `print_summary`. The box header already adapts to content so no box-width changes needed.

---

## Shellcheck compliance

All new code must be shellcheck-clean (SC2034, SC2086, SC2046, etc.). Patterns follow existing conventions:
- Temp files registered in `TMP_FILES[]` array.
- All commands wrapped with `run_cmd`.
- Version strings captured after install for the `INSTALL_VERSION[]` map.
- `|| true` on all non-fatal commands.

---

## Testing

- Run `shellcheck scripts/vm-setup.sh` — must produce zero warnings.
- Idempotency: run on a machine with all tools already installed; all sections should print "already installed — skipping".
