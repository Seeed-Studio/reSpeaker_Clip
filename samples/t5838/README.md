# T5838 PDM Microphone Test

## Overview

This sample demonstrates PDM (Pulse Density Modulation) microphone recording on the ReSpeaker Lav board.

## Hardware

- **Board**: ReSpeaker Lav (nRF5340)
- **Microphone**: T5838 PDM microphone or compatible PDM microphone array

## Features

- PDM/DMIC audio recording
- 16kHz sample rate, 16-bit depth, stereo
- 5 seconds recording duration
- LED status indicators:
  - Green: Recording in progress
  - Red: Error occurred
  - Blue: Success
- Audio data output to console

## Building

From project root:
```bash
./build.sh samples/t5838
```

Or manually:
```bash
source ~/ncs/v3.2.1/zephyr/zephyr-env.sh
export ZEPHYR_EXTRA_MODULES=$(pwd)
west build --build-dir build --pristine --board respeaker/nrf5340/cpuapp samples/t5838 \
  -DSB_CONFIG_BOOTLOADER_MCUBOOT=n
```

## Flashing

```bash
west flash --build-dir build
```

## Running

1. Connect via serial (115200 baud)
2. Reset the board
3. Speak or play audio near the microphone
4. View captured audio data on console

## Output

The sample will:
1. Configure PDM microphone
2. Record 5 seconds of audio
3. Print the first 100 samples to console
4. Show LED status indicators

## Requirements

- Zephyr RTOS NCS v3.2.1
- ReSpeaker Lav board with PDM microphone
