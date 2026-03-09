/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

/*
 * WiFi Sample for ReSpeaker Clip
 *
 * This sample demonstrates how to use the nRF7002 WiFi chip
 * to scan for networks and connect to WiFi.
 *
 * Features:
 * - Scans for available WiFi networks
 * - Displays network information (SSID, RSSI, security)
 * - Can connect to a network via shell command
 * - Shows connection status
 */

#include <zephyr/kernel.h>
#include <zephyr/net/net_mgmt.h>
#include <zephyr/net/wifi_mgmt.h>
#include <zephyr/net/net_event.h>
#include <zephyr/net/net_if.h>
#include <zephyr/net/net_ip.h>
#include <zephyr/logging/log.h>
#include <zephyr/shell/shell.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

LOG_MODULE_REGISTER(wifi_sample, LOG_LEVEL_INF);

/* Scan configuration */
#define MAX_SCAN_RESULTS 10
#define SCAN_TIMEOUT_SEC 10

/* Global scan data */
static K_SEM_DEFINE(scan_done_sem, 0, 1);
static struct wifi_scan_result scan_results[MAX_SCAN_RESULTS];
static int scan_result_count;
static bool wifi_connected = false;

/**
 * @brief WiFi scan result callback
 */
static void scan_result_callback(struct net_mgmt_event_callback *cb,
				 uint64_t mgmt_event,
				 struct net_if *iface)
{
	if (mgmt_event == NET_EVENT_WIFI_SCAN_RESULT) {
		struct wifi_scan_result *result =
			(struct wifi_scan_result *)cb->info;

		if (scan_result_count < MAX_SCAN_RESULTS && result) {
			memcpy(&scan_results[scan_result_count], result,
			       sizeof(struct wifi_scan_result));
			scan_result_count++;
			printk("[%d] %s (RSSI: %d, Ch: %d)\n",
			       scan_result_count, result->ssid, result->rssi,
			       result->channel);
		}
	} else if (mgmt_event == NET_EVENT_WIFI_SCAN_DONE) {
		printk("Scan complete: found %d networks\n", scan_result_count);
		k_sem_give(&scan_done_sem);
	}
}

/**
 * @brief WiFi management event handler
 */
static void wifi_mgmt_event_handler(struct net_mgmt_event_callback *cb,
				    uint64_t mgmt_event,
				    struct net_if *iface)
{
	switch (mgmt_event) {
	case NET_EVENT_L4_CONNECTED:
		printk("WiFi connected\n");
		wifi_connected = true;
		break;
	case NET_EVENT_L4_DISCONNECTED:
		printk("WiFi disconnected\n");
		wifi_connected = false;
		break;
	case NET_EVENT_WIFI_CONNECT_RESULT:
	{
		const struct wifi_status *status =
			(const struct wifi_status *)cb->info;
		if (status && status->status) {
			printk("Connection failed: %d\n", status->status);
		}
		break;
	}
	default:
		break;
	}
}

/**
 * @brief Scan for WiFi networks
 */
static int wifi_scan(void)
{
	struct net_if *iface = net_if_get_default();
	int ret;

	if (!iface) {
		printk("No network interface found\n");
		return -ENODEV;
	}

	/* Reset scan results */
	scan_result_count = 0;
	memset(scan_results, 0, sizeof(scan_results));

	/* Set up scan callback */
	static struct net_mgmt_event_callback scan_cb;
	net_mgmt_init_event_callback(&scan_cb, scan_result_callback,
				     NET_EVENT_WIFI_SCAN_RESULT |
				     NET_EVENT_WIFI_SCAN_DONE);
	net_mgmt_add_event_callback(&scan_cb);

	/* Start scan */
	printk("Scanning for networks...\n");
	ret = net_mgmt(NET_REQUEST_WIFI_SCAN, iface, NULL, 0);
	if (ret) {
		printk("Scan failed: %d\n", ret);
		return ret;
	}

	/* Wait for scan to complete */
	ret = k_sem_take(&scan_done_sem, K_SECONDS(SCAN_TIMEOUT_SEC));
	if (ret) {
		printk("Scan timeout\n");
		return -ETIMEDOUT;
	}

	return 0;
}

/**
 * @brief Shell command to scan for networks
 */
static int cmd_scan(const struct shell *sh, size_t argc, char **argv)
{
	int ret;

	ret = wifi_scan();
	if (ret) {
		shell_print(sh, "Scan failed: %d", ret);
		return ret;
	}

	shell_print(sh, "Found %d networks:", scan_result_count);
	for (int i = 0; i < scan_result_count; i++) {
		struct wifi_scan_result *r = &scan_results[i];
		shell_print(sh, "  [%d] %s (RSSI: %d dBm, Ch: %d)",
			   i + 1, r->ssid, r->rssi, r->channel);
	}

	return 0;
}

/**
 * @brief Shell command to get WiFi status
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

	shell_print(sh, "WiFi Status:");
	shell_print(sh, "  State: %s",
		   status.state == WIFI_STATE_COMPLETED ? "Connected" :
		   status.state == WIFI_STATE_SCANNING ? "Scanning" :
		   "Disconnected");
	shell_print(sh, "  SSID: %s", status.ssid);
	shell_print(sh, "  RSSI: %d dBm", status.rssi);
	shell_print(sh, "  Channel: %d", status.channel);
	shell_print(sh, "  Security: %d", status.security);

	/* Show IP address if connected */
	if (status.state == WIFI_STATE_COMPLETED) {
		char addr_str[NET_IPV4_ADDR_LEN];

		if (iface->config.ip.ipv4) {
			struct net_if_addr_ipv4 *ifaddr =
				&iface->config.ip.ipv4->unicast[0];
			if (ifaddr->ipv4.addr_state == NET_ADDR_PREFERRED) {
				shell_print(sh, "  IP: %s",
					net_addr_ntop(AF_INET, &ifaddr->ipv4.address.in_addr,
						     addr_str, sizeof(addr_str)));
			}
		}
	}

	return 0;
}

/* Shell commands */
SHELL_STATIC_SUBCMD_SET_CREATE(wifi_cmds,
	SHELL_CMD(scan, NULL, "Scan for WiFi networks", cmd_scan),
	SHELL_CMD(status, NULL, "Show WiFi status", cmd_status),
	SHELL_SUBCMD_SET_END
);

SHELL_CMD_REGISTER(wifi, &wifi_cmds, "WiFi commands", NULL);

/**
 * @brief Main application
 */
int main(void)
{
	int ret;

	LOG_INF("ReSpeaker Clip WiFi Sample");
	LOG_INF("============================");

	printk("\n");
	printk("ReSpeaker Clip WiFi Sample\n");
	printk("============================\n\n");

	/* Set up management event callback */
	static struct net_mgmt_event_callback mgmt_cb;
	net_mgmt_init_event_callback(&mgmt_cb, wifi_mgmt_event_handler,
				     NET_EVENT_L4_CONNECTED |
				     NET_EVENT_L4_DISCONNECTED |
				     NET_EVENT_WIFI_CONNECT_RESULT);
	net_mgmt_add_event_callback(&mgmt_cb);

	/* Initial scan */
	printk("Running initial WiFi scan...\n");
	ret = wifi_scan();
	if (ret) {
		printk("Scan failed: %d\n", ret);
	} else {
		printk("\nFound %d networks\n", scan_result_count);
	}

	printk("\nWiFi shell commands available:\n");
	printk("  wifi scan    - Scan for networks\n");
	printk("  wifi status  - Show connection status\n\n");

	printk("Use 'wifi connect <SSID> <password>' via shell to connect\n");
	printk("(Note: Full shell WiFi commands require additional configuration)\n\n");

	return 0;
}
