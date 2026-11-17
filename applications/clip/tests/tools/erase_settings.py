#!/usr/bin/env python3
"""Erase the Clip's LittleFS settings partition via MCUboot serial recovery.

Sends the board's custom mcumgr command (per-user group 64, command 1 —
patches/mcuboot/0004-add-custom-mcumgr-commands.patch), which erases the
LittleFS superblock pair on the external flash. On the next boot LittleFS
reformats cleanly: BLE bonds and app settings (incl. SN!) are lost, and a
bloated/corrupt settings file is gone — the "slow settings save / slow
shutdown" condition this tool exists to test.

Usage:
    python3 erase_settings.py                 # auto-find the device
    python3 erase_settings.py --port /dev/ttyACM1
    python3 erase_settings.py --keep-sn       # (informational only — see WARNING)

Steps performed:
    1. Open the app's USB CDC port at 1200 baud and close it — the DFU
       trigger that reboots the device into MCUboot serial recovery
       (USB PID changes 2886:0069 -> 2886:8069).
    2. Wait for the recovery CDC port to appear.
    3. Send the custom erase-settings SMP command and print the response.
    4. Tell you to power-cycle (unplug/replug USB) — recovery mode stays
       in recovery until reset.

WARNING: the SN (AT+SN) lives in the same settings file and is erased too.
Re-write it after this (AT+SN=<sn>).
"""

import argparse
import struct
import sys
import time

import serial
from serial.tools import list_ports

VID_SEEED = 0x2886
PID_APP_CDC = 0x0069
PID_RECOVERY_CDC = 0x8069

# Custom SMP: per-user group, WRITE op. Command 1 = erase LFS settings.
GRP_CLIP_PERUSER = 64
CMD_ERASE_LFS = 1
NMGR_OP_WRITE = 2

CBOR_EMPTY_MAP = b"\xa0"


def find_port(pid, wait_s=0.0):
    deadline = time.time() + wait_s
    while True:
        for p in list_ports.comports():
            if p.vid == VID_SEEED and p.pid == pid:
                return p.device
        if time.time() >= deadline:
            return None
        time.sleep(0.5)


def trigger_recovery(port):
    """1200-baud open/close: the app's DFU trigger into MCUboot recovery."""
    ser = serial.Serial(port, 1200, timeout=1)
    ser.close()
    print(f"[1/3] 1200-baud trigger sent on {port}")


def smp_frame(op, flags, group, seq, cmd_id, payload):
    hdr = struct.pack(">BBHHBB", op, flags, len(payload), group, seq, cmd_id)
    return hdr + payload


def erase_settings_cmd(port):
    """Send the custom erase-settings command, return (ok, reply bytes)."""
    frame = smp_frame(NMGR_OP_WRITE, 0, GRP_CLIP_PERUSER, 1,
                      CMD_ERASE_LFS, CBOR_EMPTY_MAP)
    with serial.Serial(port, 115200, timeout=10) as ser:
        ser.reset_input_buffer()
        ser.write(frame)
        ser.flush()
        # Response: same 8-byte header then CBOR payload.
        hdr = ser.read(8)
        if len(hdr) < 8:
            return False, b"<no response>"
        op, flags, plen, group, seq, rid = struct.unpack(">BBHHBB", hdr)
        payload = ser.read(plen) if plen else b""
        # MCUboot's custom handler returns MGMT_ERR_* directly; on error
        # boot_serial answers with a CBOR map carrying a non-zero "rc"
        # (key 0x02... "rc" encoded) or an error op. Empty/small payload
        # with op echo means accepted.
        ok = not payload or b"rc" not in payload or payload.endswith(b"\x00")
        return ok, hdr + payload


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", help="app CDC port (default: auto 2886:0069)")
    args = ap.parse_args()

    app_port = args.port or find_port(PID_APP_CDC, wait_s=3)
    if not app_port:
        print("error: no Clip app CDC found (USB PID 2886:0069); "
              "plug the device in (it must be running the app firmware)")
        return 1

    print(f"      app CDC port: {app_port}")
    print("      WARNING: this erases BLE bonds + settings + SN. "
          "Re-pair and re-write the SN afterwards.")
    try:
        trigger_recovery(app_port)
    except serial.SerialException as e:
        print(f"error: 1200-baud trigger failed: {e}")
        return 1

    rec_port = find_port(PID_RECOVERY_CDC, wait_s=15)
    if not rec_port:
        print("error: MCUboot recovery CDC (2886:8069) did not appear; "
              "the app firmware may predate the DFU trigger — use the "
              "button+USB recovery entry instead")
        return 1
    print(f"[2/3] recovery CDC port: {rec_port}")

    ok, reply = erase_settings_cmd(rec_port)
    print(f"[3/3] erase-settings reply: {reply!r}")
    if not ok:
        print("error: command may have failed — check the reply above")
        return 1

    print("\nDone. Now UNPLUG and REPLUG USB (recovery mode stays in "
          "recovery until reset). On next boot LittleFS reformats fresh:\n"
          "  - re-pair the phone\n"
          "  - AT+TIME=<ts> to sync the clock\n"
          "  - AT+SN=<sn> to re-write the serial number\n"
          "Then time AT+TIME again — if it now answers instantly, the slow "
          "settings file was the root cause.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
