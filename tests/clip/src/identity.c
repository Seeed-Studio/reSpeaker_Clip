/*
 * Per-device identity for production-test (产测).
 * See identity.h for rationale.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/drivers/hwinfo.h>
#include <zephyr/shell/shell.h>
#include <zephyr/sys/printk.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/addr.h>
#include <stdio.h>
#include <string.h>

#include "identity.h"

/* Suffix length in hex digits.
 * 6 hex = 24-bit (~16M values; birthday-50% at ~4800 boards) — ample for a
 * 产测 line. For very large fleets change to 8 (32-bit) or 12; nRF5340 FICR
 * DEVICEID is 8 bytes (16 hex) so the source has plenty of entropy. */
#define IDENTITY_SUFFIX_HEX_LEN 6
#define IDENTITY_SUFFIX_BYTES   ((IDENTITY_SUFFIX_HEX_LEN + 1) / 2)

#define BLE_NAME_PREFIX "Clip_"
#define AP_SSID_PREFIX  "Clip_"

static char suffix[IDENTITY_SUFFIX_HEX_LEN + 1];
static char ble_name[sizeof(BLE_NAME_PREFIX) + IDENTITY_SUFFIX_HEX_LEN];
static char ap_ssid[sizeof(AP_SSID_PREFIX) + IDENTITY_SUFFIX_HEX_LEN];
static bool inited;

int identity_init(void)
{
	if (inited) {
		return 0;
	}

	uint8_t cid[16];
	ssize_t len = hwinfo_get_device_id(cid, sizeof(cid));

	/* Default-fill so the buffers are always valid even if hwinfo fails. */
	for (int i = 0; i < IDENTITY_SUFFIX_HEX_LEN; i++) {
		suffix[i] = '0';
	}
	suffix[IDENTITY_SUFFIX_HEX_LEN] = '\0';

	if (len > 0) {
		int off = (int)len > IDENTITY_SUFFIX_BYTES
				? (int)len - IDENTITY_SUFFIX_BYTES : 0;
		int sl = 0;
		for (int i = 0; i < IDENTITY_SUFFIX_BYTES && (off + i) < (int)len; i++) {
			sl += snprintk(suffix + sl, sizeof(suffix) - sl,
				       "%02X", cid[off + i]);
		}
		suffix[IDENTITY_SUFFIX_HEX_LEN] = '\0';
	}

	snprintk(ble_name, sizeof(ble_name), "%s%s", BLE_NAME_PREFIX, suffix);
	snprintk(ap_ssid, sizeof(ap_ssid), "%s%s", AP_SSID_PREFIX, suffix);

	inited = true;
	printk("[identity] suffix=%s ble=\"%s\" ap=\"%s\"\n",
	       suffix, ble_name, ap_ssid);
	return 0;
}

static void ensure(void)
{
	if (!inited) {
		(void)identity_init();
	}
}

const char *identity_suffix_get(void)
{
	ensure();
	return suffix;
}

const char *identity_ble_name_get(void)
{
	ensure();
	return ble_name;
}

const char *identity_ap_ssid_get(void)
{
	ensure();
	return ap_ssid;
}

/* `ident` — print the board's BLE name, BLE MAC, AP SSID and chip suffix.
 * Lets a产测 host read one serial line and know which board this is. */
static int cmd_ident(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);
	ensure();

	char addr_str[BT_ADDR_LE_STR_LEN] = "(n/a)";
	struct bt_le_oob oob;
	if (bt_le_oob_get_local(BT_ID_DEFAULT, &oob) == 0) {
		bt_addr_le_to_str(&oob.addr, addr_str, sizeof(addr_str));
	}

	shell_print(sh, "BLE name : %s", bt_get_name());
	shell_print(sh, "BLE MAC  : %s", addr_str);
	shell_print(sh, "AP SSID  : %s", ap_ssid);
	shell_print(sh, "suffix   : %s (chip_id last %d hex)",
		    suffix, IDENTITY_SUFFIX_HEX_LEN);
	return 0;
}

SHELL_CMD_REGISTER(ident, NULL,
		   "Show BLE name / MAC / AP SSID / chip suffix",
		   cmd_ident);
