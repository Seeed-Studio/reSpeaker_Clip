# Button Demo

Demonstrates the custom GPIO button input driver (`drivers/input`,
`CONFIG_GPIO_BUTTON`): single click, double click, long press (1 s), and
level-1 long press (3 s). Each event is logged with a timestamp; event count
statistics are printed every 30 seconds.

## Build

```sh
west build --build-dir build-button-demo --board clip/nrf5340/cpuapp samples/button_demo
west flash --build-dir build-button-demo && nrfutil device reset
```

## Usage

Watch the serial console (`minicom -D /dev/ttyACM0 -b 921600`) and press the
user button (GPIO1.15). Expected log lines:

```
[1234 ms] Single Click
[2345 ms] Double Click
[3456 ms] Long Press (1 second)
[4567 ms] Long Press Level 1 (3 seconds)
```

Event count statistics are printed every 30 seconds.
