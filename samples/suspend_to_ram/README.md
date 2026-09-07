# suspend_to_ram

Minimal Zephyr sample for measuring the **System ON suspend-to-RAM
(`PM_STATE_SUSPEND_TO_RAM`) current** of the reSpeaker Clip (nRF5340).

The application does nothing in the main thread. Once it yields, the
Zephyr idle thread enters the deepest available PM state, which on
nRF5340 is `PM_STATE_SUSPEND_TO_RAM`. A `pm_notifier` drives GPIO0.27
high while suspended, so a scope or logic analyzer can confirm the
state transitions.

## Build

```sh
source ~/ncs/v3.3.0/zephyr/zephyr-env.sh
export ZEPHYR_EXTRA_MODULES=$(pwd)
west build --build-dir build-suspend --pristine \
    --board clip/nrf5340/cpuapp samples/suspend_to_ram
```

## Flash (manual)

```sh
west flash --build-dir build-suspend && nrfutil device reset
```

## Measure

1. Probe **GPIO0.27** with a scope or logic analyzer. It is LOW
   while the CPU is running and goes HIGH only while in
   `PM_STATE_SUSPEND_TO_RAM`.
2. Power the board through a Power Profiler Kit (or any µA-capable
   ammeter) on the 3V3 rail.
3. Expected: ~1-3 µA on the nRF5340 VDD supply with the DCDC
   regulators active and full RAM retention.

If the current is much higher, common causes are:

- **BUCK2 not in PFM mode** on the NPM1300 PMIC — leaks tens of µA.
- **External LDOs (mic, SD, OLED) still up** — leaks hundreds of µA.
- **Flash not in Deep Power-Down** — leaks a few µA.

This sample intentionally does **not** control those — it only
measures the SoC-side suspend current. For whole-board suspend
current, see `tests/sysoff` (System OFF) or add a follow-up sample
that drives NPM1300 regulators and the SPI flash into DPD before
yielding to idle.
