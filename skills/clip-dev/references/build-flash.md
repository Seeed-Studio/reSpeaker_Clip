# Build, flash, and release

Use NCS v3.3.0 on `main`:

```sh
source ~/ncs/v3.3.0/zephyr/zephyr-env.sh
export ZEPHYR_EXTRA_MODULES="$PWD"
west build --build-dir build-clip --board clip/nrf5340/cpuapp applications/clip
```

Use `--pristine` after Kconfig, devicetree, sysbuild, partition, or board-level
changes. The board supplies MCUboot, IPC radio, Wi-Fi, signing keys, and static
partition defaults through `boards/seeed/clip/Kconfig.sysbuild`; applications do
not normally need their own sysbuild configuration.

## Images

```sh
# Debug image
west build --build-dir build-clip --pristine --board clip/nrf5340/cpuapp applications/clip

# Production image, console/log backend disabled
west build --build-dir build-clip-prod --pristine --board clip/nrf5340/cpuapp \
  applications/clip -- -DSNIPPET=production
```

Flash with `west flash --build-dir <dir> && nrfutil device reset`. Use
`west flash --build-dir <dir> --recover` only when necessary: it erases the
device, including both cores. Build and flash the network core as part of the
sysbuild image when validating BLE.

Use `scripts/build_release.sh` for release artifacts. It builds debug and
production variants and exports the merged app/netcore HEX, OTA ZIP, and signed
binary into `output/$VERSION/`.
