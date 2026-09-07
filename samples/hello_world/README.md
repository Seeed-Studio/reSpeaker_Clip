# Hello World

The minimal clip application: a sysbuild (MCUboot + app core + ipc-radio) that
prints one line to the UART console and exits `main()`. Use it to verify your
environment (NCS v3.3.0 + `ZEPHYR_EXTRA_MODULES`) and toolchain before trying
the bigger samples.

## Build

```sh
west build --build-dir build-hello --board clip/nrf5340/cpuapp samples/hello_world
west flash --build-dir build-hello && nrfutil device reset
```

Note: even this "hello world" boots through the custom signed MCUboot
bootloader (see `docs/custom_app_guide.md`); the board sysbuild config
provides MCUboot and the network-core radio image automatically.

## Usage

Open the serial console (`minicom -D /dev/ttyACM0 -b 921600`; if a J-Link
probe is also connected, the Clip's UART bridge is `ttyACM1`). You will see the
MCUboot boot output, then:

```
Hello World! clip/nrf5340/cpuapp
```

## What to try next

- Change the message in `src/main.c` and rebuild to confirm the
  edit-flash-test loop.
- Watch the MCUboot banner on the same serial port to see the boot flow
  (boot animation on the OLED, then the app starts).
