#!/usr/bin/env python3
"""
WOL VM Listener — Listens for Wake-on-LAN magic packets on a bridge
interface and starts the corresponding Proxmox VM.

Magic packet format:
  6 bytes of 0xFF followed by 16 repetitions of the target MAC address.
  Total payload: 102 bytes.

Companion systemd service: /etc/systemd/system/wol-vm-listener.service
"""

import socket
import struct
import subprocess
import logging
import sys
import os

# ── Configuration ────────────────────────────────────────────────────────────
BRIDGE = "vmbr0"

# MAC → VMID mapping (lowercase MAC, colon-separated)
VM_MAP = {
    "bc:24:11:1e:39:9b": "100",   # talos-00
}

LOG_FILE = "/var/log/wol-vm-listener.log"

# ── Setup ────────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(sys.stdout),
    ],
)
logger = logging.getLogger("wol-vm-listener")

# Precompute magic patterns for each registered MAC
MAGIC_PATTERNS = {}
for mac_str, vmid in VM_MAP.items():
    mac_bytes = bytes.fromhex(mac_str.replace(":", ""))
    magic = b"\xff" * 6 + mac_bytes * 16
    MAGIC_PATTERNS[mac_str] = (vmid, magic)
    logger.info("Registered VM %s (MAC %s)", vmid, mac_str)


def start_vm(vmid: str, mac: str) -> None:
    """Start a Proxmox VM via qm."""
    logger.info("WOL detected for MAC %s → starting VM %s", mac, vmid)
    try:
        result = subprocess.run(
            ["/usr/sbin/qm", "start", vmid],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode == 0:
            logger.info("VM %s start command issued successfully", vmid)
        else:
            logger.error(
                "VM %s start failed (rc=%d): %s",
                vmid,
                result.returncode,
                result.stderr.strip(),
            )
    except subprocess.TimeoutExpired:
        logger.error("VM %s start command timed out", vmid)
    except Exception as exc:
        logger.error("VM %s start exception: %s", vmid, exc)


def main() -> None:
    # Create raw AF_PACKET socket to capture all Ethernet frames on the bridge
    # ETH_P_ALL = 0x0003 (capture all protocols)
    try:
        sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.ntohs(0x0003))
        sock.bind((BRIDGE, 0))
    except PermissionError:
        logger.fatal("Must run as root to open raw socket on %s", BRIDGE)
        sys.exit(1)
    except OSError as exc:
        logger.fatal("Failed to bind to %s: %s", BRIDGE, exc)
        sys.exit(1)

    logger.info("Listening on %s for WOL magic packets...", BRIDGE)

    # Track last start time per VM to prevent rapid re-triggers
    import time
    last_start: dict[str, float] = {}

    while True:
        try:
            packet = sock.recv(65535)
        except KeyboardInterrupt:
            logger.info("Shutting down.")
            break
        except Exception as exc:
            logger.error("recv error: %s", exc)
            continue

        # Skip packets that are too short to contain a magic pattern (< 102 bytes)
        if len(packet) < 102:
            continue

        now = time.time()
        for mac_str, (vmid, magic) in MAGIC_PATTERNS.items():
            if magic in packet:
                # Debounce: don't re-start the same VM within 60 seconds
                if mac_str in last_start and (now - last_start[mac_str]) < 60:
                    logger.debug("Debounced WOL for MAC %s (last start %.0fs ago)", mac_str, now - last_start[mac_str])
                    continue
                last_start[mac_str] = now
                start_vm(vmid, mac_str)
                break  # one match per packet is enough

    sock.close()


if __name__ == "__main__":
    main()
