/*
 * Copyright (c) 2023 Nordic Semiconductor ASA
 *
 * SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
 */

#include <stdio.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/reboot.h>
#include <zephyr/sys/poweroff.h>
#include <zephyr/shell/shell.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/regulator.h>
#include <zephyr/pm/device.h>
#include <zephyr/storage/disk_access.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/dt-bindings/regulator/npm13xx.h>
#include <nrfx_clock.h>
#include <hal/nrf_oscillators.h>
#include "wifi.h"
#include "ble.h"
#include "button.h"
#include "sdcard.h"
#include "mic.h"
#include "oled.h"
#include "pmic.h"
#include "motor.h"
#include "usb.h"

LOG_MODULE_REGISTER(main, LOG_LEVEL_INF);

/* This image has no MCUboot (SB_CONFIG_BOOTLOADER_NONE), unlike applications/
 * clip where MCUboot accesses the external SPI flash first and so has already
 * driven flash_vdd high + woken the chip before the app probes it. Here
 * spi_nor (POST_KERNEL prio 80) is the first access, and with
 * CONFIG_PM_DEVICE_RUNTIME_ASYNC the boot-on regulator enable is deferred, so
 * the GPIO hasn't been driven yet -> JEDEC read returns 00 00 00. Force the
 * regulator on and block long enough (tPUW ~10 ms) for the chip to settle,
 * BEFORE spi_nor runs. */
static int flash_vdd_preinit(const struct device *dev)
{
	ARG_UNUSED(dev);

	const struct device *fv = DEVICE_DT_GET(DT_NODELABEL(flash_vdd));
	if (device_is_ready(fv)) {
		(void)regulator_enable(fv);
	}
	k_msleep(50);
	return 0;
}
SYS_INIT(flash_vdd_preinit, POST_KERNEL, 78);

static int cmd_reboot(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	shell_print(sh, "Rebooting...");
	(void)pmic_battery_state_save();
	k_sleep(K_MSEC(100));
	sys_reboot(SYS_REBOOT_WARM);
	return 0;
}

SHELL_CMD_REGISTER(reboot, NULL, "Reboot device", cmd_reboot);

struct sd_shutdown_result {
	int unmount_rc;
	int deinit_rc;
	int suspend_rc;
	int cs_rc;
	int ldo_rc;
	bool ldo_before;
	bool ldo_after;
};

static struct sd_shutdown_result sys_sd_shutdown(void);
static void sys_wifi_power_off(void);

/* The fuel gauge is software state. Save it before any SYSTEM OFF path so a
 * relaxed cell voltage after wake cannot make the always-on OLED jump. */
static void sys_poweroff_with_battery_state(void)
{
	int ret = pmic_battery_state_save();

	if (ret != 0 && ret != -EAGAIN) {
		LOG_WRN("Fuel-gauge state save before power-off failed: %d", ret);
	}
	sys_poweroff();
}

/* cmd_sys_stop is defined after the device pointers below (it touches all of
 * them for a full shutdown). */

/* Isolate the UART contribution before SYSTEM OFF. The production Clip build
 * saves about 570 uA by disabling UART console/logging. */
static const struct device *const uart0 = DEVICE_DT_GET(DT_NODELABEL(uart0));

static int cmd_sys_uart_stop(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	shell_print(sh, "Suspending UARTE, then entering nRF5340 SYSTEM OFF");
	k_sleep(K_MSEC(100));
	(void)pm_device_action_run(uart0, PM_DEVICE_ACTION_SUSPEND);
	sys_poweroff_with_battery_state();
}

/* nRF7002 is powered by two board GPIOs; leave all data/coexistence pins
 * untouched here so this command isolates only the radio supply domains. */
static const struct device *const gpio0 = DEVICE_DT_GET(DT_NODELABEL(gpio0));
static const struct device *const gpio1 = DEVICE_DT_GET(DT_NODELABEL(gpio1));
static const struct device *const i2c2 = DEVICE_DT_GET(DT_NODELABEL(i2c2));
static const struct device *const spi4 = DEVICE_DT_GET(DT_NODELABEL(spi4));
static const struct device *const npm1300 = DEVICE_DT_GET(DT_NODELABEL(npm1300));
static const struct device *const npm1300_regulators =
	DEVICE_DT_GET(DT_NODELABEL(npm1300_regulators));
static const struct device *const ldo1 = DEVICE_DT_GET(DT_NODELABEL(npm1300_ldo1));
static const struct device *const ldo2 = DEVICE_DT_GET(DT_NODELABEL(npm1300_ldo2));

/* nRF7002 supply domains: this is the same proven isolation sequence used by
 * `sys wifi_stop`, which removes about 70 uA before SYSTEM OFF. */
static void sys_wifi_power_off(void)
{
	(void)gpio_pin_configure(gpio0, 11, GPIO_OUTPUT_INACTIVE); /* BUCKEN */
	(void)gpio_pin_configure(gpio0, 26, GPIO_OUTPUT_INACTIVE); /* IOVDD_EN */
	(void)gpio_pin_configure(gpio0, 29, GPIO_OUTPUT_INACTIVE); /* RF switch */
}

/* Keep every SD signal benign before cutting VDD_SD. SPI4's sleep pinctrl
 * parks SCK/MOSI/MISO low, and CS is then explicitly pulled low. */
static struct sd_shutdown_result sys_sd_shutdown(void)
{
	struct sd_shutdown_result result;

	result.ldo_before = regulator_is_enabled(ldo2);
	result.unmount_rc = sdcard_unmount();
	result.deinit_rc = disk_access_ioctl("SD", DISK_IOCTL_CTRL_DEINIT, NULL);
	result.suspend_rc = pm_device_action_run(spi4, PM_DEVICE_ACTION_SUSPEND);
	result.cs_rc = gpio_pin_configure(gpio0, 9, GPIO_INPUT | GPIO_PULL_DOWN);
	result.ldo_rc = regulator_disable(ldo2);
	result.ldo_after = regulator_is_enabled(ldo2);

	return result;
}

static void print_device_state(const struct shell *sh, const char *name,
			       const struct device *dev)
{
	shell_print(sh, "%s: ready=%d init=%d init_res=-%u", name,
		    device_is_ready(dev), dev->state->initialized, dev->state->init_res);
}

static int cmd_sys_sd_status(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	print_device_state(sh, "nPM1300", npm1300);
	print_device_state(sh, "nPM1300 regulators", npm1300_regulators);
	print_device_state(sh, "LDO1", ldo1);
	print_device_state(sh, "LDO2", ldo2);
	print_device_state(sh, "SPI4", spi4);
	return 0;
}

static int cmd_sys_sd_stop(const struct shell *sh, size_t argc, char **argv)
{
	struct sd_shutdown_result result;

	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	result = sys_sd_shutdown();

	shell_print(sh, "SD shutdown: ldo %d -> %d", result.ldo_before, result.ldo_after);
	shell_print(sh, "  unmount=%d deinit=%d spi4_suspend=%d cs=%d ldo2_disable=%d",
		    result.unmount_rc, result.deinit_rc, result.suspend_rc,
		    result.cs_rc, result.ldo_rc);
	shell_print(sh, "Entering nRF5340 SYSTEM OFF");
	k_sleep(K_MSEC(200));
	sys_poweroff_with_battery_state();
}

static int cmd_sys_wifi_stop(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	shell_print(sh, "Cutting nRF7002 power, then entering nRF5340 SYSTEM OFF");
	k_sleep(K_MSEC(100));
	sys_wifi_power_off();
	sys_poweroff_with_battery_state();
}

static int cmd_sys_oled_stop(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	shell_print(sh, "Isolating OLED bus, cutting VDD, then entering SYSTEM OFF");
	k_sleep(K_MSEC(100));
	/* Do not leave any OLED input high when VDD is removed: it back-powers
	 * the display through its ESD diodes. */
	(void)pm_device_action_run(i2c2, PM_DEVICE_ACTION_SUSPEND);
	(void)gpio_pin_configure(gpio1, 9, GPIO_OUTPUT_INACTIVE); /* RESET asserted */
	(void)gpio_pin_configure(gpio1, 8, GPIO_OUTPUT_INACTIVE); /* OLED VDD */
	sys_poweroff_with_battery_state();
}

static int cmd_sys_mic_stop(const struct shell *sh, size_t argc, char **argv)
{
	int ret;

	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	if (!device_is_ready(ldo1)) {
		shell_error(sh, "nPM1300 LDO1 is not ready");
		return -ENODEV;
	}

	shell_print(sh, "Cutting microphone LDO1, then entering SYSTEM OFF");
	ret = regulator_disable(ldo1);
	if (ret != 0) {
		shell_error(sh, "LDO1 disable failed: %d", ret);
		return ret;
	}

	k_sleep(K_MSEC(100));
	sys_poweroff_with_battery_state();
}

static int cmd_sys_ble_stop(const struct shell *sh, size_t argc, char **argv)
{
	int ret;

	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	shell_print(sh, "Stopping BLE, then entering nRF5340 SYSTEM OFF");
	ret = bt_le_adv_stop();
	if (ret != 0 && ret != -EALREADY) {
		shell_warn(sh, "BLE advertising stop failed: %d", ret);
	}

	ret = bt_disable();
	if (ret != 0) {
		/* The IPC controller may already be unavailable. Do not let a failed
		 * HCI reset prevent the following SYSTEM OFF current measurement. */
		shell_warn(sh, "BLE disable failed: %d; continuing to SYSTEM OFF", ret);
	}

	k_sleep(K_MSEC(100));
	sys_poweroff_with_battery_state();
}

static const struct device *const buck2 = DEVICE_DT_GET(DT_NODELABEL(npm1300_buck2));

static int cmd_sys_buck_pfm_stop(const struct shell *sh, size_t argc, char **argv)
{
	int ret;

	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	if (!device_is_ready(buck2)) {
		shell_error(sh, "nPM1300 BUCK2 is not ready");
		return -ENODEV;
	}

	shell_print(sh, "Setting BUCK2 PFM, then entering SYSTEM OFF");
	ret = regulator_set_mode(buck2, NPM13XX_BUCK_MODE_PFM);
	if (ret != 0) {
		shell_error(sh, "BUCK2 PFM failed: %d", ret);
		return ret;
	}

	k_sleep(K_MSEC(100));
	sys_poweroff_with_battery_state();
}

/* Full shutdown: stop every peripheral known to leak or hold a wake source,
 * THEN suspend the UART (~570 uA console leak) and enter SYSTEM OFF. Use this
 * (not the single-peripheral `sys *_stop` isolation commands) to measure sleep
 * current. NOTE: with SWD/J-Link attached, nRF5340 cannot enter true SYSTEM
 * OFF — detach the probe and power-cycle to read uA-level current. */
static int cmd_sys_stop(const struct shell *sh, size_t argc, char **argv)
{
	struct sd_shutdown_result sd;
	int ret;

	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	shell_print(sh, "Full peripheral shutdown, then nRF5340 SYSTEM OFF");

	/* 1. BLE / network-core radio (wake source) */
	shell_print(sh, "  [1/8] BLE: adv stop + disable");
	ret = bt_le_adv_stop();
	if (ret != 0 && ret != -EALREADY) {
		shell_warn(sh, "    adv stop: %d", ret);
	}
	(void)bt_disable();

	/* 2. nRF7002 WiFi supply (~70 uA) */
	shell_print(sh, "  [2/8] WiFi: nRF7002 power off");
	sys_wifi_power_off();

	/* 3. USB device (wake source when VBUS present) */
	shell_print(sh, "  [3/8] USB: disable");
	(void)usb_msc_disable();

	/* 4. SD card + LDO2 */
	shell_print(sh, "  [4/8] SD: unmount + SPI4 suspend + LDO2 off");
	sd = sys_sd_shutdown();
	if (sd.ldo_after) {
		shell_warn(sh, "    LDO2 still on (unmount=%d deinit=%d spi4=%d cs=%d ldo=%d)",
			   sd.unmount_rc, sd.deinit_rc, sd.suspend_rc, sd.cs_rc, sd.ldo_rc);
	}

	/* 5. Mic LDO1 */
	shell_print(sh, "  [5/8] Mic: LDO1 off");
	if (device_is_ready(ldo1)) {
		(void)regulator_disable(ldo1);
	}

	/* 6. OLED (bus suspend + VDD/RESET low to avoid ESD back-power) */
	shell_print(sh, "  [6/8] OLED: bus suspend + VDD off");
	(void)pm_device_action_run(i2c2, PM_DEVICE_ACTION_SUSPEND);
	(void)gpio_pin_configure(gpio1, 9, GPIO_OUTPUT_INACTIVE);  /* RESET */
	(void)gpio_pin_configure(gpio1, 8, GPIO_OUTPUT_INACTIVE);  /* OLED VDD */

	/* 7. BUCK2 PFM (low-power regulator mode) */
	shell_print(sh, "  [7/8] BUCK2: PFM");
	if (device_is_ready(buck2)) {
		(void)regulator_set_mode(buck2, NPM13XX_BUCK_MODE_PFM);
	}

	/* 8. UART console (~570 uA) — suspended LAST so the shell stays up until
	 * the final message is flushed. */
	shell_print(sh, "  [8/8] UART: suspend (console goes dark) -> SYSTEM OFF");
	k_sleep(K_MSEC(300));  /* let the last line flush before UARTE dies */
	(void)pm_device_action_run(uart0, PM_DEVICE_ACTION_SUSPEND);

	sys_poweroff_with_battery_state();
	return 0;
}

SHELL_STATIC_SUBCMD_SET_CREATE(sub_sys_cmds,
	SHELL_CMD(stop, NULL, "Full shutdown (all peripherals) then SYSTEM OFF", cmd_sys_stop),
	SHELL_CMD(uart_stop, NULL, "Suspend UARTE then system power off", cmd_sys_uart_stop),
	SHELL_CMD(wifi_stop, NULL, "Cut nRF7002 power then system power off", cmd_sys_wifi_stop),
	SHELL_CMD(oled_stop, NULL, "Cut OLED VDD then system power off", cmd_sys_oled_stop),
	SHELL_CMD(mic_stop, NULL, "Cut microphone LDO1 then system power off", cmd_sys_mic_stop),
	SHELL_CMD(ble_stop, NULL, "Stop BLE then system power off", cmd_sys_ble_stop),
	SHELL_CMD(buck_pfm_stop, NULL, "Set BUCK2 PFM then system power off", cmd_sys_buck_pfm_stop),
	SHELL_CMD(sd_status, NULL, "Show SD/PMIC device initialization state", cmd_sys_sd_status),
	SHELL_CMD(sd_stop, NULL, "Log SD shutdown steps then system power off", cmd_sys_sd_stop),
);

SHELL_CMD_REGISTER(sys, &sub_sys_cmds, "System power control", NULL);

/* LFXO capacitance commands */
static const char *lfxo_cap_name(uint32_t val)
{
	switch (val) {
	case 0: return "External";
	case 1: return "6 pF";
	case 2: return "7 pF";
	case 3: return "9 pF";
	default: return "Unknown";
	}
}

static int cmd_lfxo_cap_get(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	uint32_t cap = NRF_OSCILLATORS->XOSC32KI.INTCAP;
	shell_print(sh, "LFXO capacitance: %u (%s)", cap, lfxo_cap_name(cap));
	return 0;
}

static int cmd_lfxo_cap_set(const struct shell *sh, size_t argc, char **argv)
{
	if (argc < 2) {
		shell_print(sh, "Usage: lfxo cap <0-3>");
		shell_print(sh, "  0 = External capacitors");
		shell_print(sh, "  1 = 6 pF internal");
		shell_print(sh, "  2 = 7 pF internal");
		shell_print(sh, "  3 = 9 pF internal");
		return -EINVAL;
	}

	int val = atoi(argv[1]);
	if (val < 0 || val > 3) {
		shell_print(sh, "Error: value must be 0-3");
		return -EINVAL;
	}

	NRF_OSCILLATORS->XOSC32KI.INTCAP = (uint32_t)val;
	shell_print(sh, "LFXO capacitance set to: %u (%s)", val, lfxo_cap_name(val));
	return 0;
}

SHELL_STATIC_SUBCMD_SET_CREATE(sub_lfxo,
	SHELL_CMD(cap, NULL, "Get/set LFXO capacitance (0=ext, 1=6pF, 2=7pF, 3=9pF)",
		  NULL),
	SHELL_SUBCMD_SET_END
);

SHELL_STATIC_SUBCMD_SET_CREATE(sub_lfxo_cap,
	SHELL_CMD(get, NULL, "Get LFXO capacitance", cmd_lfxo_cap_get),
	SHELL_CMD_ARG(set, NULL, "Set LFXO capacitance (0-3)", cmd_lfxo_cap_set, 2, 0),
	SHELL_SUBCMD_SET_END
);

SHELL_CMD_REGISTER(lfxo, &sub_lfxo_cap, "LFXO 32.768kHz crystal capacitance", NULL);

/* HFXO capacitance commands */
static int cmd_hfxo_cap_get(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	uint32_t reg = NRF_OSCILLATORS->XOSC32MCAPS;
	bool enabled = (reg & OSCILLATORS_XOSC32MCAPS_ENABLE_Msk) != 0;
	uint32_t capvalue = (reg & OSCILLATORS_XOSC32MCAPS_CAPVALUE_Msk)
		>> OSCILLATORS_XOSC32MCAPS_CAPVALUE_Pos;

	if (enabled) {
		shell_print(sh, "HFXO capacitance: internal (CAPVALUE=%u)", capvalue);
	} else {
		shell_print(sh, "HFXO capacitance: external");
	}
	return 0;
}

static int cmd_hfxo_cap_set(const struct shell *sh, size_t argc, char **argv)
{
	if (argc < 2) {
		shell_print(sh, "Usage: hfxo set <picofarad>");
		shell_print(sh, "  Range: 7.0 - 20.0 pF, step 0.5 pF");
		shell_print(sh, "  Example: hfxo set 9.5");
		shell_print(sh, "  Use 0 to disable (external capacitors)");
		return -EINVAL;
	}

	float pf = strtof(argv[1], NULL);
	if (pf == 0.0f) {
		NRF_OSCILLATORS->XOSC32MCAPS =
			OSCILLATORS_XOSC32MCAPS_ENABLE_Disabled <<
			OSCILLATORS_XOSC32MCAPS_ENABLE_Pos;
		shell_print(sh, "HFXO capacitance: external");
		return 0;
	}

	if (pf < 7.0f || pf > 20.0f) {
		shell_print(sh, "Error: value must be 7.0-20.0 pF or 0 for external");
		return -EINVAL;
	}

	uint32_t capvalue = NRF_OSCILLATORS_HFXO_CAP_CALCULATE(NRF_FICR, pf);
	NRF_OSCILLATORS->XOSC32MCAPS =
		(OSCILLATORS_XOSC32MCAPS_ENABLE_Enabled <<
		 OSCILLATORS_XOSC32MCAPS_ENABLE_Pos) |
		(capvalue << OSCILLATORS_XOSC32MCAPS_CAPVALUE_Pos);
	shell_print(sh, "HFXO capacitance set to: %.1f pF (CAPVALUE=%u)", pf, capvalue);
	return 0;
}

SHELL_STATIC_SUBCMD_SET_CREATE(sub_hfxo,
	SHELL_CMD(get, NULL, "Get HFXO capacitance", cmd_hfxo_cap_get),
	SHELL_CMD_ARG(set, NULL, "Set HFXO capacitance in pF (7.0-20.0, 0=external)",
		      cmd_hfxo_cap_set, 2, 0),
	SHELL_SUBCMD_SET_END
);

SHELL_CMD_REGISTER(hfxo, &sub_hfxo, "HFXO 32MHz crystal capacitance", NULL);

int main(void)
{
	int ret;

	printk("Starting %s with CPU frequency: %d MHz\n", CONFIG_BOARD, SystemCoreClock / 1000000);

	/* Initialize Button */
	ret = button_init();
	if (ret != 0) {
		LOG_ERR("Button initialization failed: %d", ret);
	}

	/* Initialize SD Card (auto-mounts if present) */
	ret = sdcard_init();
	if (ret != 0) {
		LOG_ERR("SD card initialization failed: %d", ret);
		/* Continue anyway, SD card is optional */
	}

	/* Initialize Microphone */
	ret = mic_init();
	if (ret != 0) {
		LOG_ERR("Microphone initialization failed: %d", ret);
		/* Continue anyway, MIC is optional */
	}

	/* Initialize OLED display */
	ret = oled_init();
	if (ret != 0) {
		LOG_ERR("OLED display initialization failed: %d", ret);
		/* Continue anyway, OLED is optional */
	} else {
		/* Make the battery screen visible immediately. PMIC initialization and
		 * its periodic refresh replace this placeholder with live readings. */
		oled_show_battery_unavailable();
	}

	/* Initialize PMIC (NPM1300) */
	ret = pmic_init();
	if (ret != 0) {
		LOG_ERR("PMIC initialization failed: %d", ret);
		/* Continue anyway, PMIC is optional for testing */
	}

	/* Initialize Motor */
	ret = motor_init();
	if (ret != 0) {
		LOG_ERR("Motor initialization failed: %d", ret);
		/* Continue anyway, Motor is optional for testing */
	}

	/* Initialize USB MSC */
	ret = usb_msc_init();
	if (ret != 0) {
		LOG_WRN("USB MSC initialization failed: %d", ret);
	}

	/* Initialize BLE - starts advertising automatically */
	ret = ble_init();
	if (ret != 0) {
		LOG_ERR("Bluetooth initialization failed: %d", ret);
		/* Continue anyway, BLE is optional */
	}

	/* Initialize WiFi */
	ret = wifi_run_test();
	if (ret != 0) {
		LOG_ERR("WiFi initialization failed: %d", ret);
		/* Continue anyway, WiFi can be configured via shell */
	}

	printk("System ready\n");
	printk("WiFi: Use 'wifi on' to start AP, 'wifi status' to check\n");
	printk("BLE: Advertising as '%s'\n", CONFIG_BT_DEVICE_NAME);
	printk("SD card: Use 'sd mount' to mount, 'fs ls /SD:' to list files\n");
	printk("Flash: Use 'flash' commands for SPI flash operations\n");
	printk("MIC: Use 'mic capture [time_sec]' to capture audio\n");
	printk("OLED: Use 'oled test' to run display tests, 'oled help' for more\n");
	printk("PMIC: Use 'pmic status' to check battery, 'pmic ship' to power off\n");
	printk("Motor: Use 'motor pulse' or 'motor pattern' to test vibration\n");
	printk("USB: Use 'usb msc on' to expose SD card, 'mic record' to record WAV\n");

	return 0;
}
