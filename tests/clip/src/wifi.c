/*
 * Copyright (c) 2023 Nordic Semiconductor ASA
 *
 * SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/net/net_mgmt.h>
#include <zephyr/net/wifi_mgmt.h>
#include <zephyr/net/net_event.h>
#include <zephyr/net/socket.h>
#include <zephyr/net/zperf.h>
#include <zephyr/shell/shell.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "wifi.h"

LOG_MODULE_REGISTER(wifi, LOG_LEVEL_INF);

#define WIFI_SSID_MAX_LEN 32
#define WIFI_PASSPHRASE_MAX_LEN 64
#define IPERF_PORT 5001
#define IPERF_PACKET_SIZE 1400
#define IPERF_DURATION_SEC 10

static struct net_mgmt_event_callback wifi_mgmt_cb;
static bool wifi_connected = false;
static char iperf_server_ip[32] = "192.168.1.100";
static int iperf_server_port = IPERF_PORT;
static int iperf_duration = IPERF_DURATION_SEC;

/* Helper function to check actual WiFi connection status */
static bool is_wifi_connected(void)
{
	struct net_if *iface = net_if_get_default();
	struct wifi_iface_status status;
	int ret;

	ret = net_mgmt(NET_REQUEST_WIFI_IFACE_STATUS, iface,
		       &status, sizeof(status));
	if (ret == 0 && status.state == WIFI_STATE_COMPLETED) {
		return true;
	}
	return false;
}

/* Global scan callback data */
static K_SEM_DEFINE(scan_done_sem, 0, 1);
static struct wifi_scan_result scan_results[10];
static int scan_result_count;

static void scan_result_callback(struct net_mgmt_event_callback *cb,
				 uint64_t mgmt_event,
				 struct net_if *iface)
{
	if (mgmt_event == NET_EVENT_WIFI_SCAN_RESULT) {
		struct wifi_scan_result *result =
			(struct wifi_scan_result *)cb->info;

		if (scan_result_count < 10 && result) {
			memcpy(&scan_results[scan_result_count], result,
			       sizeof(struct wifi_scan_result));
			scan_result_count++;
			printk("Found: %s, RSSI: %d\n", result->ssid, result->rssi);
		}
	} else if (mgmt_event == NET_EVENT_WIFI_SCAN_DONE) {
		printk("Scan done, found %d networks\n", scan_result_count);
		k_sem_give(&scan_done_sem);
	}
}

static void wifi_mgmt_event_handler(struct net_mgmt_event_callback *cb,
				    uint64_t mgmt_event,
				    struct net_if *iface)
{
	/* Use printk for immediate output */
	printk("WiFi event: 0x%llx\n", mgmt_event);

	switch (mgmt_event) {
	case NET_EVENT_L4_CONNECTED:
		printk("Network connected (L4)\n");
		wifi_connected = true;
		break;
	case NET_EVENT_L4_DISCONNECTED:
		printk("Network disconnected (L4)\n");
		wifi_connected = false;
		break;
	case NET_EVENT_WIFI_CONNECT_RESULT:
	{
		const struct wifi_status *status =
			(const struct wifi_status *)cb->info;
		printk("Connect result - status: %d\n",
			status ? status->status : -999);
		if (status) {
			if (status->status) {
				printk("Connection failed: %d\n", status->status);
				wifi_connected = false;
			} else {
				printk("WiFi link connected!\n");
			}
		} else {
			printk("Connection status is NULL\n");
			wifi_connected = false;
		}
		break;
	}
	case NET_EVENT_WIFI_DISCONNECT_RESULT:
		printk("WiFi disconnected\n");
		wifi_connected = false;
		break;
	case NET_EVENT_IPV4_DHCP_BOUND:
		printk("DHCP address acquired\n");
		break;
	default:
		break;
	}
}

static int cmd_wifi_connect(const struct shell *sh, size_t argc, char **argv)
{
	struct wifi_connect_req_params req;
	int ret;
	int band = WIFI_FREQ_BAND_2_4_GHZ;

	if (argc < 2) {
		shell_print(sh, "Usage: wifi connect <SSID> [password] [band]");
		shell_print(sh, "  band: 0=2.4GHz (default), 1=5GHz");
		return -EINVAL;
	}

	if (strlen(argv[1]) > WIFI_SSID_MAX_LEN) {
		shell_print(sh, "SSID too long (max %d)", WIFI_SSID_MAX_LEN);
		return -EINVAL;
	}

	memset(&req, 0, sizeof(req));

	req.ssid = argv[1];
	req.ssid_length = strlen(req.ssid);

	if (argc >= 3) {
		if (strlen(argv[2]) > WIFI_PASSPHRASE_MAX_LEN) {
			shell_print(sh, "Password too long (max %d)",
				   WIFI_PASSPHRASE_MAX_LEN);
			return -EINVAL;
		}
		req.psk = argv[2];
		req.psk_length = strlen(req.psk);
		req.security = WIFI_SECURITY_TYPE_PSK;
	} else {
		req.security = WIFI_SECURITY_TYPE_NONE;
	}

	if (argc >= 4) {
		band = atoi(argv[3]);
		if (band != 0 && band != 1) {
			shell_print(sh, "Invalid band (0=2.4GHz, 1=5GHz)");
			return -EINVAL;
		}
	}

	req.channel = WIFI_CHANNEL_ANY;
	req.band = band;
	req.mfp = WIFI_MFP_OPTIONAL;

	shell_print(sh, "Connecting to %s on %sGHz...",
		   req.ssid, band == 0 ? "2.4" : "5");

	wifi_connected = false;

	ret = net_mgmt(NET_REQUEST_WIFI_CONNECT, net_if_get_default(),
		       &req, sizeof(req));
	if (ret) {
		shell_print(sh, "Connection request failed: %d", ret);
		return ret;
	}

	shell_print(sh, "Connection initiated...");
	return 0;
}

static int cmd_wifi_disconnect(const struct shell *sh, size_t argc, char **argv)
{
	int ret;

	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	ret = net_mgmt(NET_REQUEST_WIFI_DISCONNECT, net_if_get_default(),
		       NULL, 0);
	if (ret) {
		shell_print(sh, "Disconnect failed: %d", ret);
		return ret;
	}

	wifi_connected = false;
	shell_print(sh, "Disconnecting...");
	return 0;
}

static int cmd_wifi_off(const struct shell *sh, size_t argc, char **argv)
{
	struct net_if *iface = net_if_get_default();
	int ret;

	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	if (is_wifi_connected()) {
		net_mgmt(NET_REQUEST_WIFI_DISCONNECT, iface, NULL, 0);
		k_sleep(K_MSEC(500));
	}

	ret = net_if_down(iface);
	if (ret) {
		shell_print(sh, "WiFi off failed: %d", ret);
		return ret;
	}

	wifi_connected = false;
	shell_print(sh, "WiFi turned off (radio powered down)");
	return 0;
}

static int cmd_wifi_on(const struct shell *sh, size_t argc, char **argv)
{
	struct net_if *iface = net_if_get_default();
	int ret;

	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	ret = net_if_up(iface);
	if (ret) {
		shell_print(sh, "WiFi on failed: %d", ret);
		return ret;
	}

	shell_print(sh, "WiFi turned on (radio powered up)");
	shell_print(sh, "Use 'wifi connect <SSID> [password] [band]' to connect");
	return 0;
}

static int cmd_wifi_scan(const struct shell *sh, size_t argc, char **argv)
{
	struct net_if *iface = net_if_get_default();
	static struct net_mgmt_event_callback scan_cb;
	int ret, band = 0;

	if (argc >= 2) {
		band = atoi(argv[1]);
		if (band < 0 || band > 2) {
			shell_print(sh, "Invalid band (0=all, 1=2.4G, 2=5G)");
			return -EINVAL;
		}
	}

	scan_result_count = 0;
	memset(scan_results, 0, sizeof(scan_results));
	k_sem_reset(&scan_done_sem);

	net_mgmt_init_event_callback(&scan_cb, scan_result_callback,
				     NET_EVENT_WIFI_SCAN_RESULT |
				     NET_EVENT_WIFI_SCAN_DONE);
	net_mgmt_add_event_callback(&scan_cb);

	struct wifi_scan_params params = {
		.scan_type = WIFI_SCAN_TYPE_ACTIVE,
		.bands = (band == 0) ? ((1 << WIFI_FREQ_BAND_2_4_GHZ) | (1 << WIFI_FREQ_BAND_5_GHZ)) :
			(band == 1) ? (1 << WIFI_FREQ_BAND_2_4_GHZ) : (1 << WIFI_FREQ_BAND_5_GHZ),
		.max_bss_cnt = 10,
	};

	shell_print(sh, "Scanning for networks...");

	ret = net_mgmt(NET_REQUEST_WIFI_SCAN, iface, &params, sizeof(params));
	if (ret) {
		shell_print(sh, "Scan failed: %d", ret);
		net_mgmt_del_event_callback(&scan_cb);
		return ret;
	}

	ret = k_sem_take(&scan_done_sem, K_SECONDS(15));
	if (ret != 0) {
		shell_print(sh, "Scan timeout");
		net_mgmt_del_event_callback(&scan_cb);
		return -ETIMEDOUT;
	}

	net_mgmt_del_event_callback(&scan_cb);

	shell_print(sh, "Found %d networks:", scan_result_count);
	shell_print(sh, "%-4s %-20s %-6s %-4s", "CH", "SSID", "RSSI", "BAND");

	for (int i = 0; i < scan_result_count; i++) {
		struct wifi_scan_result *r = &scan_results[i];
		const char *band_str = (r->band == WIFI_FREQ_BAND_2_4_GHZ) ? "2.4G" : "5G";

		char ssid[21];
		snprintf(ssid, sizeof(ssid), "%.20s", r->ssid);

		shell_print(sh, "%-4d %-20s %-6d %-4s",
			   r->channel, ssid, r->rssi, band_str);
	}

	return 0;
}

static int cmd_wifi_status(const struct shell *sh, size_t argc, char **argv)
{
	struct net_if *iface = net_if_get_default();
	struct wifi_iface_status status;
	int ret;

	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	ret = net_mgmt(NET_REQUEST_WIFI_IFACE_STATUS, iface,
		       &status, sizeof(status));
	if (ret) {
		shell_print(sh, "Status request failed: %d", ret);
		return ret;
	}

	shell_print(sh, "WiFi Status:");

	if (status.state == WIFI_STATE_COMPLETED) {
		shell_print(sh, "  State: Connected");
		shell_print(sh, "  SSID: %.32s", status.ssid);
		shell_print(sh, "  RSSI: %d dBm", status.rssi);
		shell_print(sh, "  Channel: %d", status.channel);
		shell_print(sh, "  Band: %s", status.band == WIFI_FREQ_BAND_2_4_GHZ ?
			   "2.4 GHz" : "5 GHz");

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
	} else {
		shell_print(sh, "  State: Disconnected");
	}

	return 0;
}

/* zperf UDP throughput test - iperf compatible */
static K_SEM_DEFINE(zperf_done_sem, 0, 1);

static void udp_upload_results_cb(enum zperf_status status,
				   struct zperf_results *result,
				   void *user_data)
{
	const struct shell *sh = (const struct shell *)user_data;

	switch (status) {
	case ZPERF_SESSION_STARTED:
		printk("zperf: Session started\n");
		break;
	case ZPERF_SESSION_FINISHED:
		printk("zperf: Session finished\n");
		if (result) {
			uint32_t throughput_kbps = 0;
			uint64_t bytes_sent = result->nb_packets_sent * result->packet_size;
			uint64_t time_ms = result->client_time_in_us / 1000;

			/* Calculate throughput using client_time_in_us (Nordic reference way) */
			if (result->client_time_in_us != 0) {
				throughput_kbps = (uint32_t)(
					((uint64_t)result->nb_packets_sent *
					 (uint64_t)result->packet_size * 8 *
					 1000000) /
					(result->client_time_in_us * 1024)
				);
			}

			shell_print(sh, "");
			shell_print(sh, "Test completed!");
			shell_print(sh, "  Packets sent: %u", result->nb_packets_sent);
			shell_print(sh, "  Packets lost: %u", result->nb_packets_lost);
			shell_print(sh, "  Packets received: %u", result->nb_packets_rcvd);
			shell_print(sh, "  Bytes sent: %llu", bytes_sent);
			shell_print(sh, "  Time: %llu ms", time_ms);
			shell_print(sh, "  Throughput: %u kbps (%u.%03u Mbps)",
				   throughput_kbps,
				   throughput_kbps / 1000,
				   throughput_kbps % 1000);
		}
		k_sem_give(&zperf_done_sem);
		break;
	case ZPERF_SESSION_ERROR:
		printk("zperf: Session error\n");
		if (result) {
			printk("  Packet errors: %u\n", result->nb_packets_errors);
		}
		shell_print(sh, "Test failed");
		k_sem_give(&zperf_done_sem);
		break;
	case ZPERF_SESSION_PERIODIC_RESULT:
		break;
	default:
		printk("zperf: Unknown status: %d\n", status);
		break;
	}
}

static int cmd_udp_test(const struct shell *sh, size_t argc, char **argv)
{
	struct sockaddr_in addr;
	struct zperf_upload_params params;
	int ret;
	int duration_sec = iperf_duration;
	uint32_t packet_size = IPERF_PACKET_SIZE;
	uint32_t rate_kbps = 100000; /* Default 100 Mbps */

	if (!is_wifi_connected()) {
		shell_print(sh, "WiFi not connected");
		return -ENETDOWN;
	}

	if (argc >= 2) {
		strncpy(iperf_server_ip, argv[1], sizeof(iperf_server_ip) - 1);
	}
	if (argc >= 3) {
		duration_sec = atoi(argv[2]);
		if (duration_sec <= 0 || duration_sec > 3600) {
			shell_print(sh, "Invalid duration (1-3600 seconds)");
			return -EINVAL;
		}
	}
	if (argc >= 4) {
		rate_kbps = atoi(argv[3]);
		if (rate_kbps < 100 || rate_kbps > 1000000) {
			shell_print(sh, "Invalid rate (100-1000000 kbps)");
			return -EINVAL;
		}
	}

	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons(iperf_server_port);
	ret = inet_pton(AF_INET, iperf_server_ip, &addr.sin_addr);
	if (ret != 1) {
		shell_print(sh, "Invalid IP address");
		return -EINVAL;
	}

	memset(&params, 0, sizeof(params));
	params.duration_ms = duration_sec * 1000;
	params.packet_size = packet_size;
	params.rate_kbps = rate_kbps;
	memcpy(&params.peer_addr, &addr, sizeof(addr));

	shell_print(sh, "");
	shell_print(sh, "UDP throughput test (iperf compatible)");
	shell_print(sh, "Target: %s:%d", iperf_server_ip, iperf_server_port);
	shell_print(sh, "Packet size: %u bytes", packet_size);
	shell_print(sh, "Duration: %d seconds", duration_sec);
	shell_print(sh, "Rate limit: %u kbps (%.1f Mbps)", rate_kbps, rate_kbps / 1000.0);
	shell_print(sh, "");
	shell_print(sh, "Run iperf server on your PC:");
	shell_print(sh, "  iperf -s -i 1 -u");
	shell_print(sh, "");

	ret = zperf_udp_upload_async(&params, udp_upload_results_cb, (void *)sh);
	if (ret) {
		shell_print(sh, "Failed to start test: %d", ret);
		return ret;
	}

	ret = k_sem_take(&zperf_done_sem, K_SECONDS(duration_sec + 30));
	if (ret != 0) {
		shell_print(sh, "Test timeout");
		return -ETIMEDOUT;
	}

	return 0;
}

SHELL_STATIC_SUBCMD_SET_CREATE(sub_wifi,
	SHELL_CMD(on, NULL, "Turn on WiFi radio", cmd_wifi_on),
	SHELL_CMD(off, NULL, "Turn off WiFi radio", cmd_wifi_off),
	SHELL_CMD(scan, NULL, "Scan for networks [band: 0=all, 1=2.4G, 2=5G]", cmd_wifi_scan),
	SHELL_CMD(connect, NULL, "Connect to AP", cmd_wifi_connect),
	SHELL_CMD(disconnect, NULL, "Disconnect from AP", cmd_wifi_disconnect),
	SHELL_CMD(status, NULL, "Show WiFi status", cmd_wifi_status),
	SHELL_SUBCMD_SET_END
);

SHELL_CMD_REGISTER(wifi, &sub_wifi, "WiFi commands", NULL);

SHELL_CMD_REGISTER(iperf, NULL, "UDP iperf throughput test [server_ip] [duration_sec] [rate_kbps]", cmd_udp_test);

int wifi_init_and_connect(void)
{
	net_mgmt_init_event_callback(&wifi_mgmt_cb, wifi_mgmt_event_handler,
				     NET_EVENT_L4_CONNECTED |
				     NET_EVENT_L4_DISCONNECTED |
				     NET_EVENT_WIFI_CONNECT_RESULT |
				     NET_EVENT_WIFI_DISCONNECT_RESULT |
				     NET_EVENT_IPV4_DHCP_BOUND);
	net_mgmt_add_event_callback(&wifi_mgmt_cb);

	printk("WiFi initialized\n");
	printk("Commands:\n");
	printk("  wifi on                                - Turn on WiFi radio\n");
	printk("  wifi off                               - Turn off WiFi radio (power save)\n");
	printk("  wifi scan [band]                       - Scan for networks (0=all, 1=2.4G, 2=5G)\n");
	printk("  wifi connect <SSID> [password] [band] - Connect (band: 0=2.4G, 1=5G)\n");
	printk("  wifi disconnect                         - Disconnect\n");
	printk("  wifi status                            - Show status\n");
	printk("  iperf [server_ip] [duration] [rate]  - UDP iperf throughput test\n");

	return 0;
}

int wifi_start_throughput_test(void)
{
	return 0;
}

int wifi_run_test(void)
{
	return wifi_init_and_connect();
}
