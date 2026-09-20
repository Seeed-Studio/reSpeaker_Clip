# WiFi Radio Test for Clip

WiFi radio test firmware for RF testing and certification on the reSpeaker Clip board.

## Overview

Based on the Nordic WiFi radio test sample, this firmware provides shell commands to configure the nRF70 radio in specific modes for RF testing:

- Modulated carrier TX/RX
- Tone transmission
- IQ sample capture at ADC output
- FICR (Factory Information Configuration Registers) programming

## Build

```sh
source ~/ncs/v3.3.0/zephyr/zephyr-env.sh
export ZEPHYR_EXTRA_MODULES=$(pwd)
west build --build-dir build-wifi-radio --pristine --board clip/nrf5340/cpuapp tests/wifi_radio
```

## Flash

```sh
west flash --build-dir build-wifi-radio && nrfutil device reset
```

> **No MCUboot**: this is factory/cert firmware. `sysbuild.conf` sets
> `SB_CONFIG_BOOTLOADER_NONE=y` (plus `SB_CONFIG_SECURE_BOOT_NETCORE=n`,
> `SB_CONFIG_NETCORE_NONE=y`, and `SB_CONFIG_PARTITION_MANAGER=n`, so the
> image links at 0x0), which means the image is flashed **directly via
> J-Link** — no bootloader, no OTA slots, no signing.

## Shell Access

Connect via UART (USB-TTL or debug probe):
- **TX**: P1.05 (Clip -> Host)
- **RX**: P1.04 (Host -> Clip)
- **Baud rate**: 115200
- **Format**: 8N1

```sh
minicom -D /dev/ttyUSB0 -b 115200
```

## Usage

The shell prompt `uart:~$` appears after boot. All commands are under `wifi_radio_test`.

### Basic TX Test

```
uart:~$ wifi_radio_test init 1              # Initialize radio on channel 1 (2412 MHz)
uart:~$ wifi_radio_test show_config          # Display current configuration
uart:~$ wifi_radio_test tx_power 10          # Set TX power to 10 dBm
uart:~$ wifi_radio_test tx_pkt_num 100       # Transmit 100 packets
uart:~$ wifi_radio_test tx 1                 # Start transmission
uart:~$ wifi_radio_test tx 0                 # Stop transmission
```

### Basic RX Test

```
uart:~$ wifi_radio_test init 6              # Initialize radio on channel 6 (2437 MHz)
uart:~$ wifi_radio_test rx 1                 # Start reception
uart:~$ wifi_radio_test get_stats            # Display RX statistics
uart:~$ wifi_radio_test rx 0                 # Stop reception
```

### Tone Test

```
uart:~$ wifi_radio_test init 1
uart:~$ wifi_radio_test tx_tone 1            # Start tone transmission
uart:~$ wifi_radio_test tx_tone 0            # Stop tone
```

### Set Defaults

```
uart:~$ wifi_radio_test set_defaults         # Reset all parameters to default values
```

## Configuration Commands

| Command         | Argument                       | Default | Description                        |
|-----------------|--------------------------------|---------|------------------------------------|
| init            | Channel number (1-13)          | 1       | Initialize radio on channel        |
| tx              | 0 or 1                         | 0       | Enable/disable TX                  |
| rx              | 0 or 1                         | 0       | Enable/disable RX                  |
| tx_power        | 0-24 (dBm)                     | 0       | TX power                           |
| tx_pkt_num      | -1=infinite, N=packets         | -1      | Number of packets to transmit      |
| tx_pkt_len      | Packet length                  | 1400    | Packet data length                 |
| tx_pkt_gap      | 0-200000 (us)                  | 0       | Gap between TX packets             |
| tx_pkt_mcs      | MCS index                      | 0       | MCS index (mutually exclusive with rate) |
| tx_pkt_rate     | 1,2,5.5,11,6,9,12,18,24,36,48,54 | 6    | Legacy rate (mutually exclusive with MCS) |
| tx_pkt_tput_mode| 0=Legacy,1=HT,2=VHT,3=HE_SU   | 0       | Throughput mode                    |
| tx_tone         | 0 or 1                         | 0       | Enable/disable tone transmission   |
| tx_tone_freq    | -10 to 10 (MHz offset)         | 0       | Tone frequency offset from channel |
| he_ltf          | 0=1x,1=2x,2=4x                 | 2       | HE LTF value                       |
| he_gi           | 0=0.8us,1=1.6us,2=3.2us        | 2       | HE guard interval                  |
| rx_lna_gain     | 0-4 (24dB to -12dB)            | 0       | LNA gain                           |
| rx_cap          | 0=ADC,1=Filtered,2=Packet      | -       | Capture IQ samples                 |
| rx_capture_length | 0-16383 samples              | 0       | Number of RX samples to capture    |
| dpd             | 0=bypass,1=enable              | 0       | Digital pre-distortion             |
| show_config     | -                              | -       | Display current config             |
| get_stats       | -                              | -       | Display statistics                 |
| get_temperature | -                              | -       | Read chip temperature              |
| get_rf_rssi     | -                              | -       | Get RF RSSI                        |
| get_voltage     | -                              | -       | Get battery voltage                |
| set_defaults    | -                              | -       | Reset to defaults                  |
| reg_domain      | Country code (US, GB, etc.)    | 00      | Set regulatory domain              |
| bypass_reg_domain | 0 or 1                       | 0       | Bypass regulatory domain           |
| set_xo_val      | 0-127                          | 42      | Set XO trim value                  |
| compute_optimal_xo_val | -                       | -       | Compute optimal XO trim            |

## FICR Programming

OTP registers for factory programming. **Warning: OTP writes are permanent.**

```
uart:~$ wifi_radio_ficr_prog read <address>        # Read OTP register
uart:~$ wifi_radio_ficr_prog write <address> <val>  # Write OTP register
```

## Troubleshooting

- **Shell not responding**: Verify baud rate 115200, check TX/RX wiring (P1.04=RX, P1.05=TX)
- **Build errors**: Ensure `ZEPHYR_EXTRA_MODULES` points to the Clip project root
- **Flash fails**: Try `nrfutil device recover` to unlock the device
- **Radio init fails ("Configuration init failed")**: Board without OTP MAC address needs `CONFIG_WIFI_RANDOM_MAC_ADDRESS=y`
- **OTP not ready**: the `wifi_radio_ficr_prog` shell commands in this firmware (see [FICR Programming](#ficr-programming) above) program the nRF70 OTP MAC address

## References

- Nordic WiFi Radio Test Sample: nrf/samples/wifi/radio_test/multi_domain
- Nordic FICR Programming: nrf/samples/wifi/radio_test/multi_domain/ficr.rst
