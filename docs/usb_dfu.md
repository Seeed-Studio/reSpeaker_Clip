# Firmware Upgrade Guide

Host-side procedures for upgrading reSpeaker Clip firmware — no debug probe needed for
the USB and BLE paths. All host tools talk the **mcumgr Simple Management Protocol
(SMP)** over the bootloader's USB CDC-ACM serial port or over BLE.

> The bootloader's USB serial recovery and the application's UART console are
> independent. **Production builds (console off) still support USB serial DFU.**

## At a glance

| Method | Probe? | Tool | Artifact |
|--------|--------|------|----------|
| **USB serial DFU** (recommended) | No | `nrfutil mcu-manager` / `mcumgr` / nRF Connect | `*-signed.bin` or `*-ota.zip` |
| BLE OTA | No | nRF Connect app / `mcumgr` | `*-ota.zip` |
| Programmer | Yes (J-Link) | `west flash` / `nrfutil device program` | `*-merged.hex` |

Native USB-DFU (`dfu-util`) is **not** used — see [Why not dfu-util / native USB-DFU?](#why-not-dfu-util--native-usb-dfu).

## Getting the firmware

Official binaries are published on **GitHub Releases** — one release per version
tag, each containing the 8 artifacts listed below:
<https://github.com/Seeed-Studio/reSpeaker_Clip/releases>

- **Field users** normally want the **production** build: upload
  `clip-<v>-production-signed.bin` (app-only upgrade) or
  `clip-<v>-production-ota.zip` (app + network core) — this is the low-power
  image with the serial console disabled.
- **Debug** builds (console on, higher idle current) are for development and
  post-mortem log inspection.
- Developers can also **build locally** — see the [repo README](../README.md)
  and [docs/custom_app_guide.md](custom_app_guide.md). A local build produces
  the same files in the build directory (`zephyr.signed.bin`,
  `dfu_application.zip`, `merged.hex`, ...); Releases just package them with
  version-tagged names.

## Artifacts (the 8 files per release)

Every GitHub Release (and every local build) produces these — on Releases they
are named `clip-<version>-{debug,production}-*`:

| File | What it is | Use with |
|------|-----------|----------|
| `clip-<v>-*-merged.hex` | Full image (MCUboot + app + net core) | Programmer |
| `clip-<v>-*-merged_CPUNET.hex` | Network core only | Programmer |
| `clip-<v>-*-signed.bin` | Signed **app** image | USB serial DFU, BLE (mcumgr) |
| `clip-<v>-*-ota.zip` | Multi-image package (app + net core) | USB serial DFU, BLE (mcumgr/nRF Connect) |

(`debug` and `production` variants of each = the 8 files; a local build's
`output/<version>/` export is the same set.)

For an app-only field upgrade, upload the `-signed.bin`. For a full app + net-core
upgrade, upload the `-ota.zip`.

## Entering USB serial recovery mode

MCUboot (`CONFIG_MCUBOOT_SERIAL=y`, `CONFIG_BOOT_SERIAL_CDC_ACM=y`) exposes an SMP
console over USB. Enter it one of three ways (USB/VBUS must be present):

- **1200 baud** (recommended — every app has it, no button): open the device's USB
  CDC-ACM port at **1200 baud**. The app detects the line-coding change, writes the
  boot-mode retention register, and reboots into serial recovery. See
  [1200-baud auto-trigger](#1200-baud-auto-trigger-app-update) below.
- **Button** (field): hold the **user button** (GPIO1.15) while connecting USB
  (or while powering on). The device enumerates as a serial port, e.g. `/dev/ttyACM0`
  (Linux), `COMx` (Windows), `/dev/cu.usbmodem*` (macOS).
- **Software** (app-initiated): the app writes the boot-mode retention register
  (`boot_mode0`, the `zephyr,boot-mode` node) and reboots; MCUboot then enters
  serial recovery on the next boot (e.g. the clip app's `AT+DFU` over BLE).

VBUS gating (MCUboot patch `0001-require-vbus-for-gpio-serial-recovery`) requires a
USB connection for the **button** path, so the device is never left listening for DFU
on battery. The 1200-baud and software paths are not VBUS-gated (VBUS is present
anyway — the trigger arrives over USB).

### 1200-baud auto-trigger (app update)

The standard "open the CDC port at 1200 baud → reboot into the bootloader" pattern
(Arduino/Adafruit/UF2 style) is built into the board, so **every clip app gets it
with no code**. When the host sets the CDC-ACM line coding to 1200, the app sets the
mcuboot boot-mode and reboots; MCUboot enters serial recovery on the next boot.
mcuboot itself does not detect 1200 baud — the app-side trigger drives the existing
`bootmode_set` + recovery flow.

**USB IDs** (Seeed VID `0x2886`):

| State | PID | Meaning |
|-------|-----|---------|
| Application running | `0x0069` | The app's CDC-ACM port — trigger 1200 baud on this one. |
| MCUboot serial recovery | `0x8069` | The `0x8000` bit marks bootloader mode — upload to this port. |

**Trigger from the host** (open at 1200, then close — pyserial is the reliable way;
any tool that sends `SET_LINE_CODING` at 1200 works):

```sh
python3 -c "import serial; s=serial.Serial('/dev/ttyACMx',1200); s.close()"
```

The device reboots; a new CDC-ACM port (PID `0x8069`) appears. Upload the app:

```sh
nrfutil mcu-manager serial image-upload --firmware clip-<v>-signed.bin --serial-port /dev/ttyACMx
nrfutil mcu-manager serial reset     --serial-port /dev/ttyACMx
```

**clip app caveat — USB is BLE-gated.** The clip app does not enable USB by default;
first send `AT+USB=on` over BLE, then the CDC-ACM port (PID `0x0069`) appears and the
1200-baud trigger works. Samples and custom apps that use the default CDC
(`CONFIG_CLIP_USB_DFU_DEFAULT_CDC=y`, the board default) auto-enable USB at boot, so
no BLE step is needed there.

#### How it's wired (board level)

The trigger lives in the `lib/clip_usb_dfu/` module, compiled into every clip app.
Two Kconfig symbols control it (board defaults in
`boards/seeed/clip/Kconfig.defconfig`):

| Kconfig | Default | What it does |
|---------|---------|--------------|
| `CONFIG_CLIP_USB_DFU` | `y` (app images; `!MCUBOOT` excludes the bootloader) | The shared `clip_usb_dfu_check()` hook — on 1200 baud it calls `bootmode_set(BOOT_MODE_TYPE_BOOTLOADER)` and schedules a deferred reboot. Any app's USB message callback can call it. |
| `CONFIG_CLIP_USB_DFU_DEFAULT_CDC` | `y` | A minimal CDC-ACM interface, auto-initialized and enabled via `SYS_INIT` (Arduino-style), so apps without their own USB stack (e.g. samples) get the trigger with zero code. Apps with their own CDC (the clip app) set this to `n` and call `clip_usb_dfu_check()` from their own USB message callback. |

The hook pulls in `REBOOT`, `UART_LINE_CTRL` (required to read the host-requested
baud — without it `uart_line_ctrl_get()` returns `-ENOTSUP` and the trigger silently
no-ops), and the retention chain (`RETAINED_MEM` / `RETENTION` /
`RETENTION_BOOT_MODE`).

> **Stack note.** The board also bumps `CONFIG_UDC_NRF_THREAD_STACK_SIZE` to 1024
> when the default CDC is on. The UDC driver thread handles host enumeration and is
> only 512 bytes by default; apps that combine the default CDC with
> `LOG_MODE_IMMEDIATE` overflow it during enumeration (manifests as a stack-overflow
> fault at boot). 1024 fixes this; the clip app is unaffected (it uses its own CDC +
> deferred LOG and keeps the 512 default).

## USB serial DFU procedures

Pick any one tool — they all speak SMP over the same CDC-ACM port. Adjust the
serial port and firmware path to your system.

### Option A — `nrfutil mcu-manager` (recommended)

nrfutil (Nordic's tool; ≥ 8.x with the `mcu-manager` plugin) speaks mcumgr SMP
over serial or BLE.

```sh
# List serial ports
nrfutil device list

# Upload the app image (single-core field upgrade)
nrfutil mcu-manager serial image-upload \
    --firmware clip-0.0.5-production-signed.bin \
    --serial-port /dev/ttyACM0

# ...or the full package (app + net core)
nrfutil mcu-manager serial image-upload \
    --firmware clip-0.0.5-production-ota.zip \
    --serial-port /dev/ttyACM0

# Reset to apply (MCUboot verifies signature and swaps on next boot)
nrfutil mcu-manager serial reset --serial-port /dev/ttyACM0
```

`--firmware` accepts BIN, HEX, or ZIP (ZIP = multi-image package).

### Option B — `mcumgr`

The upstream mcumgr CLI (`go install github.com/apache/mynewt-mcumgr/cli/mcumgr@latest`).

```sh
mcumgr --conntype serial --connstring dev=/dev/ttyACM0,mtu=512 \
    image upload clip-0.0.5-production-signed.bin

# Inspect / confirm / reset
mcumgr --conntype serial --connstring dev=/dev/ttyACM0,mtu=512 image list
mcumgr --conntype serial --connstring dev=/dev/ttyACM0,mtu=512 reset
```

### Option C — nRF Connect

- **Desktop**: Programmer app → select the serial port → add the `-signed.bin` or
  `-ota.zip` → "Update".
- **Mobile**: Device Manager app → connect over BLE → "Add file" → the `-ota.zip` →
  "Update". (This is the BLE path; see below.)

## BLE OTA

Same SMP protocol over Bluetooth LE. Use the `-ota.zip`.

- **nRF Connect mobile** (Device Manager): connect to the device → "Add file" →
  `clip-<v>-*-ota.zip` → "Update".
- **nrfutil**:
  ```sh
  nrfutil mcu-manager ble image-upload \
      --firmware clip-0.0.5-production-ota.zip \
      --address <DEVICE-BLE-MAC>
  ```
- **mcumgr**:
  ```sh
  mcumgr --conntype ble --connstring peer_name=Clip \
      image upload clip-0.0.5-production-ota.zip
  ```
  (`peer_name` does a prefix match against the device's BLE advertised name,
  which is `Clip XXXX` — the 4 hex suffix of the FICR device id. Note that
  `ClipAP_XXXX` is the **WiFi AP SSID**, not the BLE name.)

## Programmer (when a probe is available)

Full image, no signature-slot dance:

```sh
west flash --build-dir build-clip && nrfutil device reset
# or
nrfutil device program --firmware clip-0.0.5-production-merged.hex --serial-number <JLINK-SN>
```

> `west flash --reset` does **not** work on this board — reset separately with
> `nrfutil device reset`.

## Why not dfu-util / native USB-DFU?

`dfu-util` speaks the standard USB DFU device class (`USB_DFU_CLASS`), which is a
**different transport** from mcumgr-over-CDC-ACM. MCUboot supports it
(`BOOT_USB_DFU_WAIT`/`BOOT_USB_DFU_GPIO` choice), but it is **disabled** here
(`BOOT_USB_DFU_NO`), and intentionally so:

- The bootloader partition is ~99% full (USB CDC-ACM serial recovery + OLED already
  occupy the slot). Enabling the DFU class on top would overflow it; you would have
  to drop the OLED display patch or the CDC-ACM recovery, or grow the mcuboot
  partition (repartitioning the app slots).
- NCS/mcuboot's primary, well-supported upgrade path is mcumgr SMP — over serial
  CDC-ACM **and** BLE — which already covers USB and wireless field upgrades.

So the mcumgr path (above) is the supported route. `dfu-util` would only be worth
revisiting if a host without mcumgr/nrfutil must be supported and the bootloader
partition is enlarged.

## Post-upgrade verification

After the swap and reboot:

```sh
nrfutil mcu-manager serial image-list --serial-port /dev/ttyACM0   # running image + hash
# or on the device: AT+VERSION  →  confirms the new version string
```

## Troubleshooting

### No `0x8069` recovery port appears

- **Cable**: try another USB cable — charge-only cables have no data lines.
- **VBUS**: the **button** path is VBUS-gated (MCUboot patch `0001`); without a
  real USB connection the device will never enter serial recovery that way.
- **Button timing**: hold the user button **before/while** plugging USB, and keep
  holding until the device enumerates. The OLED shows "Recovery Mode".
- **1200-baud path on the clip app**: USB is BLE-gated — send `AT+USB=on` over
  BLE first so the app's CDC port (PID `0x0069`) appears, then trigger 1200
  baud. If BLE is unavailable, the **button path is the fallback** — it needs no
  BLE, only a USB connection.

### Upload fails / interrupted mid-upload

Serial recovery is idempotent — nothing is written to the active (primary) slot
until the full image has been received into the secondary slot and its
signature verified. Just re-run the upload from scratch; a partial image in the
secondary slot is harmless.

### Device rejects the image (signature verification failed)

The image was signed with a different key than the one baked into the device's
MCUboot. Re-obtain the official artifacts from
[Releases](https://github.com/Seeed-Studio/reSpeaker_Clip/releases). Note that
this repository's default key (`root-rsa-2048.pem`) is MCUboot's
publicly-available **sample** key — fine for development, but any image you
build yourself with it will only run on development devices expecting that key.

### Bad image boots / device misbehaves after upgrade

This board's MCUboot runs in **overwrite-only** mode
(`MCUBOOT_MODE_OVERWRITE_ONLY` in `boards/seeed/clip/Kconfig.sysbuild`) — the
new image is copied over the primary slot with **no automatic revert** and no
`image-confirm`/revert semantics. If the upgraded image is bad, recovery means
re-entering serial recovery (1200 baud, or button + USB) and uploading a known
good image (e.g. the last working version from Releases).

### Boot loop after repeated pair/unpair

A corrupted settings partition (`/lfs/settings/run` on the external flash)
can stall `settings_load` and boot-loop the app. Recover without opening the
device: enter serial recovery (above) and use the MCUboot custom **erase
settings** mcumgr command (group 64 / peruser, command 1 —
`patches/mcuboot/README.md` patch `0004`), which erases the LittleFS
superblock so the filesystem reformats cleanly on next boot (BLE bonds and app
settings are lost). The **erase SD card** command (command 0) is the sibling
factory-reset.

### Still bricked

The last resort is SWD/J-Link reflashing of the full image (`*-merged.hex`) —
a **development** operation that needs an opened device and a probe. Enclosed
field devices should go through RMA instead.

