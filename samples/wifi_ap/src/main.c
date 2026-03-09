/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

/*
 * WiFi AP Sample for ReSpeaker Clip
 *
 * This sample demonstrates how to use the nRF7002 WiFi chip
 * in AP (Access Point) mode.
 *
 * Features:
 * - Device acts as a WiFi AP (hotspot)
 * - SSID: "ClipAP_XXXX" (last 4 hex of chip ID)
 * - Password: "12345678"
 * - DHCP server assigns IP addresses to connected devices
 * - Shows connected clients and status
 */

#include <zephyr/kernel.h>
#include <zephyr/net/net_mgmt.h>
#include <zephyr/net/wifi_mgmt.h>
#include <zephyr/net/net_event.h>
#include <zephyr/net/net_if.h>
#include <zephyr/net/net_ip.h>
#include <zephyr/net/dhcpv4_server.h>
#include <zephyr/logging/log.h>
#include <zephyr/shell/shell.h>
#include <zephyr/device.h>
#include <zephyr/drivers/hwinfo.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

LOG_MODULE_REGISTER(wifi_ap, LOG_LEVEL_INF);

/* AP Configuration */
#define WIFI_AP_SSID_PREFIX "ClipAP_"
#define WIFI_AP_PASSWORD "12345678"
#define WIFI_AP_CHANNEL 6
#define WIFI_AP_MAX_CLIENTS 4

/* Global state */
static bool ap_started = false;
static char ap_ssid[32];

/* Fallback SSID if chip ID read fails */
#define DEFAULT_AP_SSID "ClipAP_Test"

/**
 * @brief Generate AP SSID from chip ID
 */
static void generate_ap_ssid(void)
{
	uint8_t chip_id[16];
	ssize_t length;

	length = hwinfo_get_device_id(chip_id, sizeof(chip_id));

	if (length > 0) {
		/* Use last 4 bytes of chip ID for SSID suffix */
		uint32_t id_suffix = 0;
		int offset = length > 4 ? length - 4 : 0;

		for (int i = 0; i < 4 && (offset + i) < length; i++) {
			id_suffix = (id_suffix << 8) | chip_id[offset + i];
		}

		snprintf(ap_ssid, sizeof(ap_ssid), "%s%04X",
			 WIFI_AP_SSID_PREFIX, (unsigned int)(id_suffix & 0xFFFF));
	} else {
		strncpy(ap_ssid, DEFAULT_AP_SSID, sizeof(ap_ssid) - 1);
		ap_ssid[sizeof(ap_ssid) - 1] = '\0';
	}

	LOG_INF("AP SSID: %s", ap_ssid);
	LOG_INF("AP Password: " WIFI_AP_PASSWORD);
}

/**
 * @brief WiFi management event handler
 */
static void wifi_mgmt_event_handler(struct net_mgmt_event_callback *cb,
				    uint64_t mgmt_event,
				    struct net_if *iface)
{
	switch (mgmt_event) {
	case NET_EVENT_WIFI_AP_ENABLE_RESULT:
		LOG_INF("AP enabled result");
		break;
	case NET_EVENT_WIFI_AP_STA_CONNECTED:
	{
		struct wifi_ap_sta_info *sta =
			(struct wifi_ap_sta_info *)cb->info;
		if (sta) {
			LOG_INF("Station connected");
			printk("Station connected: %02X:%02X:%02X:%02X:%02X:%02X\n",
			       sta->mac[0], sta->mac[1], sta->mac[2],
			       sta->mac[3], sta->mac[4], sta->mac[5]);
		}
		break;
	}
	case NET_EVENT_WIFI_AP_STA_DISCONNECTED:
	{
		struct wifi_ap_sta_info *sta =
			(struct wifi_ap_sta_info *)cb->info;
		if (sta) {
			LOG_INF("Station disconnected");
			printk("Station disconnected: %02X:%02X:%02X:%02X:%02X:%02X\n",
			       sta->mac[0], sta->mac[1], sta->mac[2],
			       sta->mac[3], sta->mac[4], sta->mac[5]);
		}
		break;
	}
	case NET_EVENT_L4_CONNECTED:
		LOG_INF("Layer 4 connected");
		break;
	case NET_EVENT_L4_DISCONNECTED:
		LOG_INF("Layer 4 disconnected");
		break;
	default:
		break;
	}
}

/**
 * @brief Start WiFi AP
 */
static int wifi_ap_start(void)
{
	struct net_if *iface = net_if_get_default();
	struct wifi_connect_req_params req;
	int ret;

	if (!iface) {
		LOG_ERR("No network interface found");
		return -ENODEV;
	}

	/* Check if AP is already started */
	if (ap_started) {
		LOG_INF("AP already started");
		return 0;
	}

	/* Fill AP configuration */
	memset(&req, 0, sizeof(req));

	req.ssid = (const uint8_t *)ap_ssid;
	req.ssid_length = strlen(ap_ssid);
	req.psk = (const uint8_t *)WIFI_AP_PASSWORD;
	req.psk_length = strlen(WIFI_AP_PASSWORD);
	req.channel = WIFI_AP_CHANNEL;
	req.security = WIFI_SECURITY_TYPE_PSK;
	req.mfp = WIFI_MFP_OPTIONAL;
	req.band = WIFI_FREQ_BAND_2_4_GHZ;

	/* Enable AP mode */
	printk("\n");
	printk("==========================================\n");
	printk("Starting WiFi AP\n");
	printk("==========================================\n");
	printk("SSID: %s\n", ap_ssid);
	printk("Password: %s\n", WIFI_AP_PASSWORD);
	printk("Channel: %d\n", WIFI_AP_CHANNEL);
	printk("==========================================\n\n");

	ret = net_mgmt(NET_REQUEST_WIFI_AP_ENABLE, iface, &req, sizeof(req));
	if (ret) {
		LOG_ERR("AP enable failed: %d", ret);
		printk("Failed to start AP: %d\n", ret);
		return ret;
	}

	/* Wait a bit for AP to start */
	k_sleep(K_SECONDS(2));

	/* Get and show AP IP address */
	if (iface->config.ip.ipv4) {
		struct net_if_addr_ipv4 *ifaddr =
			&iface->config.ip.ipv4->unicast[0];
		char addr_str[NET_IPV4_ADDR_LEN];

		if (ifaddr->ipv4.addr_state == NET_ADDR_PREFERRED ||
		    ifaddr->ipv4.addr_state == NET_ADDR_TENTATIVE) {
			printk("AP IP Address: %s\n",
				net_addr_ntop(AF_INET, &ifaddr->ipv4.address.in_addr,
					     addr_str, sizeof(addr_str)));
			printk("Connect your phone to: %s\n", ap_ssid);
		}
	}

	ap_started = true;
	LOG_INF("AP started successfully");
	printk("\nAP started! Waiting for connections...\n\n");

	return 0;
}

/**
 * @brief Stop WiFi AP
 */
static int wifi_ap_stop(void)
{
	struct net_if *iface = net_if_get_default();
	int ret;

	if (!iface) {
		return -ENODEV;
	}

	if (!ap_started) {
		printk("AP not started\n");
		return 0;
	}

	ret = net_mgmt(NET_REQUEST_WIFI_AP_DISABLE, iface, NULL, 0);
	if (ret) {
		printk("Failed to stop AP: %d\n", ret);
		return ret;
	}

	ap_started = false;
	printk("AP stopped\n");
	LOG_INF("AP stopped");

	return 0;
}

/**
 * @brief Shell command to start AP
 */
static int cmd_start(const struct shell *sh, size_t argc, char **argv)
{
	int ret;

	ret = wifi_ap_start();
	if (ret) {
		shell_print(sh, "Failed to start AP: %d", ret);
		return ret;
	}

	shell_print(sh, "AP started successfully");
	shell_print(sh, "SSID: %s", ap_ssid);
	shell_print(sh, "Password: %s", WIFI_AP_PASSWORD);

	return 0;
}

/**
 * @brief Shell command to stop AP
 */
static int cmd_stop(const struct shell *sh, size_t argc, char **argv)
{
	int ret;

	ret = wifi_ap_stop();
	if (ret) {
		shell_print(sh, "Failed to stop AP: %d", ret);
		return ret;
	}

	shell_print(sh, "AP stopped");
	return 0;
}

/**
 * @brief Shell command to get AP status
 */
static int cmd_status(const struct shell *sh, size_t argc, char **argv)
{
	struct net_if *iface = net_if_get_default();
	struct wifi_iface_status status;
	int ret;

	ret = net_mgmt(NET_REQUEST_WIFI_IFACE_STATUS, iface,
		       &status, sizeof(status));
	if (ret) {
		shell_print(sh, "Failed to get status: %d", ret);
		return ret;
	}

	shell_print(sh, "WiFi AP Status:");
	shell_print(sh, "  Mode: %s",
		   status.iface_mode == WIFI_MODE_AP ? "Access Point" :
		   status.iface_mode == WIFI_MODE_INFRA ? "Station" :
		   status.iface_mode == WIFI_MODE_IBSS ? "Ad-hoc" :
		   "Unknown");
	shell_print(sh, "  State: %s",
		   status.state == WIFI_STATE_COMPLETED ? "Running" :
		   status.state == WIFI_STATE_SCANNING ? "Scanning" :
		   "Idle");
	shell_print(sh, "  SSID: %s", status.ssid);
	shell_print(sh, "  Channel: %d", status.channel);
	shell_print(sh, "  Security: %s",
		   status.security == WIFI_SECURITY_TYPE_PSK ? "WPA2-PSK" :
		   status.security == WIFI_SECURITY_TYPE_NONE ? "Open" :
		   "Other");

	/* Show AP IP address */
	if (iface->config.ip.ipv4) {
		struct net_if_addr_ipv4 *ifaddr =
			&iface->config.ip.ipv4->unicast[0];
		char addr_str[NET_IPV4_ADDR_LEN];

		if (ifaddr->ipv4.addr_state == NET_ADDR_PREFERRED ||
		    ifaddr->ipv4.addr_state == NET_ADDR_TENTATIVE) {
			shell_print(sh, "  IP: %s",
				net_addr_ntop(AF_INET, &ifaddr->ipv4.address.in_addr,
					     addr_str, sizeof(addr_str)));
		}
	}

	if (!ap_started) {
		shell_print(sh, "\nAP not started. Use 'wifi_ap start' to start.");
	}

	return 0;
}

/* Shell commands */
SHELL_STATIC_SUBCMD_SET_CREATE(wifi_ap_cmds,
	SHELL_CMD(start, NULL, "Start WiFi AP", cmd_start),
	SHELL_CMD(stop, NULL, "Stop WiFi AP", cmd_stop),
	SHELL_CMD(status, NULL, "Show AP status", cmd_status),
	SHELL_SUBCMD_SET_END
);

SHELL_CMD_REGISTER(wifi_ap, &wifi_ap_cmds, "WiFi AP commands", NULL);

/**
 * @brief Main application
 */
int main(void)
{
	int ret;

	LOG_INF("ReSpeaker Clip WiFi AP Sample");
	LOG_INF("===============================");

	printk("\n");
	printk("==============================================\n");
	printk("   ReSpeaker Clip WiFi AP Sample\n");
	printk("==============================================\n\n");

	/* Generate AP SSID */
	generate_ap_ssid();

	/* Set up management event callback */
	static struct net_mgmt_event_callback mgmt_cb;
	net_mgmt_init_event_callback(&mgmt_cb, wifi_mgmt_event_handler,
				     NET_EVENT_WIFI_AP_ENABLE_RESULT |
				     NET_EVENT_WIFI_AP_STA_CONNECTED |
				     NET_EVENT_WIFI_AP_STA_DISCONNECTED |
				     NET_EVENT_L4_CONNECTED |
				     NET_EVENT_L4_DISCONNECTED);
	net_mgmt_add_event_callback(&mgmt_cb);

	/* Wait for network interface to be ready */
	k_sleep(K_SECONDS(2));

	/* Auto-start AP */
	ret = wifi_ap_start();
	if (ret) {
		printk("Failed to start AP: %d\n", ret);
		printk("You can start AP manually using: wifi_ap start\n");
	} else {
		printk("\nWiFi AP is running!\n");
		printk("Connect your phone or laptop to SSID: %s\n", ap_ssid);
		printk("Password: %s\n\n", WIFI_AP_PASSWORD);
	}

	printk("Shell commands:\n");
	printk("  wifi_ap start  - Start WiFi AP\n");
	printk("  wifi_ap stop   - Stop WiFi AP\n");
	printk("  wifi_ap status - Show AP status\n\n");

	return 0;
}
