/*
 * Per-device identity for production-test (产测).
 *
 * The reSpeaker Clip test firmware runs on many boards that may sit on the
 * same jig simultaneously. The BLE advertising name and WiFi AP SSID must
 * therefore carry a per-board token so a test host can lock RSSI/identity to
 * the device under test instead of seeing a sea of identical names.
 *
 * The token is the trailing hex of the nRF5340 FICR DEVICEID (read via
 * hwinfo). FICR is factory-programmed, so the token is stable across reboots
 * and re-flashes (it follows the silicon, not the firmware). Both the BLE
 * name and the AP SSID use the SAME token so a host reading either one can
 * correlate the board.
 */
#ifndef IDENTITY_H
#define IDENTITY_H

#include <stddef.h>

/* Compute and cache the per-device suffix from the chip id. Idempotent.
 * Safe to call multiple times; also called lazily by the getters. */
int identity_init(void);

/* Hex token derived from the chip id, e.g. "A1B2C3".
 * Length is IDENTITY_SUFFIX_HEX_LEN (6 by default; bump for larger fleets). */
const char *identity_suffix_get(void);

/* "Clip_Test_<suffix>" — set as the BLE advertising/connection name. */
const char *identity_ble_name_get(void);

/* "ClipTest_<suffix>" — used as the WiFi AP SSID. */
const char *identity_ap_ssid_get(void);

#endif /* IDENTITY_H */
