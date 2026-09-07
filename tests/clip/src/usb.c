/*
 * USB Mass Storage Class module
 * Exposes SD card as a USB drive for direct file access from PC.
 *
 * Usage:
 *   usb msc on   - Unmount SD from filesystem, enable USB MSC
 *   usb msc off  - Disable USB MSC, remount SD filesystem
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/usb/usbd.h>
#include <zephyr/usb/class/usbd_msc.h>
#include <zephyr/storage/disk_access.h>
#include <zephyr/fs/fs.h>
#include <zephyr/shell/shell.h>
#include <zephyr/logging/log.h>
#include "usb.h"
#include "sdcard.h"

LOG_MODULE_REGISTER(usb_msc, LOG_LEVEL_INF);

/* USB device context - using new USB stack */
USBD_DEVICE_DEFINE(sample_usbd,
		   DEVICE_DT_GET(DT_NODELABEL(usbd)),
		   0x2886, 0x0047);

USBD_DESC_LANG_DEFINE(sample_lang);
USBD_DESC_MANUFACTURER_DEFINE(sample_mfr, "Seeed");
USBD_DESC_PRODUCT_DEFINE(sample_product, "Clip Test");

USBD_DESC_CONFIG_DEFINE(fs_cfg_desc, "FS Configuration");

USBD_CONFIGURATION_DEFINE(sample_fs_config,
			  0, 100, &fs_cfg_desc);

/* SD card as MSC LUN */
USBD_DEFINE_MSC_LUN(sd, "SD", "Seeed", "Clip SD", "1.00");

static bool msc_enabled;
static bool usbd_initialized;

static int usbd_setup(void)
{
	int err;

	err = usbd_add_descriptor(&sample_usbd, &sample_lang);
	if (err) {
		LOG_ERR("Failed to add language descriptor: %d", err);
		return err;
	}

	err = usbd_add_descriptor(&sample_usbd, &sample_mfr);
	if (err) {
		LOG_ERR("Failed to add manufacturer descriptor: %d", err);
		return err;
	}

	err = usbd_add_descriptor(&sample_usbd, &sample_product);
	if (err) {
		LOG_ERR("Failed to add product descriptor: %d", err);
		return err;
	}

	err = usbd_add_configuration(&sample_usbd, USBD_SPEED_FS,
				     &sample_fs_config);
	if (err) {
		LOG_ERR("Failed to add FS configuration: %d", err);
		return err;
	}

	err = usbd_register_all_classes(&sample_usbd, USBD_SPEED_FS, 1, NULL);
	if (err) {
		LOG_ERR("Failed to register classes: %d", err);
		return err;
	}

	err = usbd_init(&sample_usbd);
	if (err) {
		LOG_ERR("Failed to init USBD: %d", err);
		return err;
	}

	usbd_initialized = true;
	return 0;
}

static int cmd_usb_msc_on(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	if (msc_enabled) {
		shell_print(sh, "USB MSC already enabled");
		return 0;
	}

	/* Unmount SD filesystem first */
	if (sdcard_is_mounted()) {
		shell_print(sh, "Unmounting SD card...");
		sdcard_unmount();
		k_sleep(K_MSEC(100));
	}

	/* Initialize USB device if needed */
	if (!usbd_initialized) {
		int ret = usbd_setup();
		if (ret != 0) {
			shell_error(sh, "USB init failed: %d", ret);
			return ret;
		}
	}

	/* Enable USB device */
	int ret = usbd_enable(&sample_usbd);
	if (ret != 0) {
		shell_error(sh, "USB enable failed: %d", ret);
		return ret;
	}

	msc_enabled = true;
	shell_print(sh, "USB MSC enabled - SD card visible as USB drive");
	shell_print(sh, "Connect USB cable to PC to access files");
	shell_print(sh, "Use 'usb msc off' to disable and remount SD");
	return 0;
}

static int cmd_usb_msc_off(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	if (!msc_enabled) {
		shell_print(sh, "USB MSC not enabled");
		return 0;
	}

	/* Disable USB device */
	int ret = usbd_disable(&sample_usbd);
	if (ret != 0) {
		LOG_WRN("USB disable failed: %d", ret);
	}

	msc_enabled = false;
	k_sleep(K_MSEC(200));

	/* Remount SD card */
	shell_print(sh, "Remounting SD card...");
	sdcard_mount();

	shell_print(sh, "USB MSC disabled, SD card remounted");
	return 0;
}

static int cmd_usb_status(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	shell_print(sh, "USB MSC: %s", msc_enabled ? "enabled" : "disabled");
	shell_print(sh, "SD card: %s", sdcard_is_mounted() ? "mounted" : "unmounted");
	return 0;
}

SHELL_STATIC_SUBCMD_SET_CREATE(sub_usb_msc,
	SHELL_CMD(on, NULL, "Enable USB MSC (expose SD card)", cmd_usb_msc_on),
	SHELL_CMD(off, NULL, "Disable USB MSC (remount SD)", cmd_usb_msc_off),
	SHELL_SUBCMD_SET_END
);

SHELL_STATIC_SUBCMD_SET_CREATE(sub_usb,
	SHELL_CMD(msc, &sub_usb_msc, "USB Mass Storage commands", NULL),
	SHELL_CMD(status, NULL, "Show USB status", cmd_usb_status),
	SHELL_SUBCMD_SET_END
);

SHELL_CMD_REGISTER(usb, &sub_usb, "USB commands", NULL);

int usb_msc_disable(void)
{
	if (!usbd_initialized) {
		return -EALREADY;
	}

	int ret = usbd_disable(&sample_usbd);
	if (ret != 0) {
		LOG_WRN("USB disable failed: %d", ret);
	}
	msc_enabled = false;
	return ret;
}

int usb_msc_init(void)
{
	LOG_INF("USB MSC module ready (use 'usb msc on' to enable)");
	return 0;
}
