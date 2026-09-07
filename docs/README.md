# Documentation Map

Entry point for all reSpeaker Clip documentation. English docs are canonical;
the only maintained translation is `tests/clip/README_zh.md`.

## Where do I start?

| I want to... | Go to |
|--------------|-------|
| Upgrade a device in the field | [usb_dfu.md](usb_dfu.md) |
| Build a phone/desktop client | [protocol.md](protocol.md) (BLE AT) + [udp_protocol.md](udp_protocol.md) + [../mobile/README.md](../mobile/README.md) |
| Start firmware development | [../README.md](../README.md) (Getting Started) + [../applications/clip/README.md](../applications/clip/README.md) + [architecture.md](architecture.md) |
| Build my own app on the Clip board | [custom_app_guide.md](custom_app_guide.md) |
| Understand the hardware/board | [architecture.md](architecture.md) §10 Hardware Interfaces + [../tests/clip/README.md](../tests/clip/README.md) (pin/regulator tables) |
| Publish a release | [release_process.md](release_process.md) |
| Debug power draw | [power.md](power.md) |
| Fix a stuck device / common errors | [troubleshooting.md](troubleshooting.md) |
| Run hardware test firmware | [../tests/clip/README.md](../tests/clip/README.md) ([中文版](../tests/clip/README_zh.md)), [../tests/dtm/README.md](../tests/dtm/README.md), [../tests/wifi_radio/README.md](../tests/wifi_radio/README.md), [../tests/battery_cycle/README.md](../tests/battery_cycle/README.md), [../tests/re/README.md](../tests/re/README.md) |
| Run the Python test suite | [../applications/clip/tests/docs/testing.md](../applications/clip/tests/docs/testing.md) |

## Index

**Getting started**

- [../README.md](../README.md) — repo overview, toolchain install, build/flash
- [../applications/clip/README.md](../applications/clip/README.md) — main application guide

**Guides**

- [architecture.md](architecture.md) — system architecture and design
- [custom_app_guide.md](custom_app_guide.md) — custom apps, signing, OTA, DFU recovery
- [usb_dfu.md](usb_dfu.md) — firmware upgrade (USB / BLE / programmer)
- [release_process.md](release_process.md) — tagging and publishing a release
- [power.md](power.md) — power measurements and idle budget
- [troubleshooting.md](troubleshooting.md) — common errors and recovery

**Protocol specs**

- [protocol.md](protocol.md) — BLE AT command protocol (WiFi AP credentials, AT command list in Appendix A)
- [udp_protocol.md](udp_protocol.md) — WiFi UDP file transfer protocol

**Reference**

- [requirements.md](requirements.md) — product requirements
- [audio_quality_standard.md](audio_quality_standard.md) — audio quality test standard
- [development.md](development.md) — development log

**Release notes**

- [release_notes/](release_notes/) — one `vX.Y.Z.md` per release

**Mobile**

- [../mobile/README.md](../mobile/README.md) — companion app and SDK monorepo
- [../mobile/app/docs/](../mobile/app/docs/) — app design/API docs

**AI-assisted development**

- `skills/clip-dev` — firmware development skill (Zephyr/board specifics)
- `skills/clip-sdk` — SDK/client integration skill

## Single source of truth

| Fact class | Owner |
|------------|-------|
| WiFi AP credentials & BLE name | [protocol.md](protocol.md) §2 |
| Power figures (idle current, budgets) | [power.md](power.md) |
| AT command list / count | [protocol.md](protocol.md) Appendix A |
| Build commands | [../README.md](../README.md) |
| MCUboot patch details | [../patches/mcuboot/README.md](../patches/mcuboot/README.md) |

Other files summarize; when they disagree, the owner above wins.
