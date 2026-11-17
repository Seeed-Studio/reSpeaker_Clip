/*
 * Copyright (c) 2026 Seeed Studio
 *
 * SPDX-License-Identifier: Apache-2.0
 */

/*
 * WiFi STA + iperf Throughput Test Sample for reSpeaker Clip
 *
 * Minimal delta from samples/wifi_ap_iperf (the proven-working AP sample):
 * the AP start/stop is replaced by a WPA2-PSK station join + DHCP client.
 * Everything else — boot-time AUTO_START bring-up, scan, zperf UDP iperf,
 * shell — is kept identical.
 *
 * Shell commands:
 *   wifi connect <ssid> <psk> [band] - Join WPA2-PSK (band: 0=any, 1=2.4G, 2=5G),
 *                                      wait for DHCP, print the address
 *   wifi disconnect                  - Leave the network
 *   wifi scan [band]                 - Scan networks (0=all, 1=2.4G, 2=5G)
 *   wifi status                      - Show link state + IP
 *   iperf [ip] [dur] [rate]          - UDP throughput test (PC: iperf2 -s -u -p 5001)
 *
 * Build:
 *   west build --build-dir build-wifi-sta --board clip/nrf5340/cpuapp \
 *       --pristine=always samples/wifi_sta_iperf
 */

#include <zephyr/kernel.h>
#include <zephyr/net/net_mgmt.h>
#include <zephyr/net/wifi_mgmt.h>
#include <zephyr/net/net_event.h>
#include <zephyr/net/net_if.h>
#include <zephyr/net/net_ip.h>
#include <zephyr/net/socket.h>
#include <zephyr/net/dhcpv4.h>
#include <zephyr/net/zperf.h>
#include <zephyr/logging/log.h>
#include <zephyr/shell/shell.h>
#include <nrfx_clock.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

LOG_MODULE_REGISTER(wifi_sta_iperf, LOG_LEVEL_INF);

#define WIFI_REG_DOMAIN "US"
#define WIFI_CONNECT_RETRIES 2

#define IPERF_PORT 5001
#define IPERF_PACKET_SIZE 1400
#define IPERF_DURATION_SEC 10

static bool sta_connected;
static char sta_ssid[WIFI_SSID_MAX_LEN + 1];
static char sta_ip[INET_ADDRSTRLEN];
static char iperf_server_ip[32] = "192.168.4.2";

static struct net_mgmt_event_callback wifi_mgmt_cb;
static struct net_mgmt_event_callback ipv4_mgmt_cb;

static K_SEM_DEFINE(link_connected_sem, 0, 1);
static K_SEM_DEFINE(link_disconnected_sem, 0, 1);
static K_SEM_DEFINE(ipv4_addr_sem, 0, 1);

/* Scan state */
static K_SEM_DEFINE(scan_done_sem, 0, 1);
static struct wifi_scan_result scan_results[10];
static int scan_result_count;

static void wifi_mgmt_event_handler(struct net_mgmt_event_callback *cb,
				    uint64_t mgmt_event, struct net_if *iface)
{
	switch (mgmt_event) {
	case NET_EVENT_WIFI_CONNECT_RESULT:
	{
		const struct wifi_status *status =
			(const struct wifi_status *)cb->info;
		if (status && status->status == 0) {
			printk("[WiFi] Connected\n");
			sta_connected = true;
		} else {
			printk("[WiFi] Connect failed: %d\n",
			       status ? status->status : -999);
		}
		k_sem_give(&link_connected_sem);
		break;
	}
	case NET_EVENT_WIFI_DISCONNECT_RESULT:
		printk("[WiFi] Disconnected\n");
		sta_connected = false;
		sta_ip[0] = '\0';
		k_sem_give(&link_disconnected_sem);
		break;
	default:
		break;
	}
}

static void ipv4_mgmt_event_handler(struct net_mgmt_event_callback *cb,
				    uint64_t mgmt_event, struct net_if *iface)
{
	if (mgmt_event == NET_EVENT_IPV4_ADDR_ADD) {
		const struct in_addr *addr = (const struct in_addr *)cb->info;

		if (net_ipv4_is_ll_addr(addr)) {
			return;   /* skip 169.254.x.x link-local */
		}

		net_addr_ntop(AF_INET, addr, sta_ip, sizeof(sta_ip));
		printk("[WiFi] IPv4: %s\n", sta_ip);
		k_sem_give(&ipv4_addr_sem);
	}
}

static void scan_result_callback(struct net_mgmt_event_callback *cb,
				 uint64_t mgmt_event, struct net_if *iface)
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

static int wifi_set_reg_domain(struct net_if *iface)
{
	struct wifi_reg_domain regd = {0};
	int ret;

	regd.oper = WIFI_MGMT_SET;
	strncpy(regd.country_code, WIFI_REG_DOMAIN, WIFI_COUNTRY_CODE_LEN + 1);

	ret = net_mgmt(NET_REQUEST_WIFI_REG_DOMAIN, iface, &regd, sizeof(regd));
	if (ret) {
		LOG_WRN("Reg domain failed: %d", ret);
	}

	return ret;
}

static int do_wifi_sta_connect(const char *ssid, const char *psk, int band)
{
	struct net_if *iface;
	struct wifi_connect_req_params req;
	int ret;

	if (sta_connected) {
		printk("[WiFi] Already connected to \"%s\" (wifi disconnect first)\n",
		       sta_ssid);
		return 0;
	}

	iface = net_if_get_first_wifi();
	if (!iface) {
		printk("[WiFi] No WiFi interface\n");
		return -ENODEV;
	}

	memset(&req, 0, sizeof(req));
	req.ssid = (const uint8_t *)ssid;
	req.ssid_length = strlen(ssid);
	req.psk = (const uint8_t *)psk;
	req.psk_length = strlen(psk);
	req.security = WIFI_SECURITY_TYPE_PSK;
	req.mfp = WIFI_MFP_OPTIONAL;
	req.channel = WIFI_CHANNEL_ANY;
	req.band = (band == 1) ? WIFI_FREQ_BAND_2_4_GHZ :
		   (band == 2) ? WIFI_FREQ_BAND_5_GHZ : WIFI_FREQ_BAND_UNKNOWN;

	strncpy(sta_ssid, ssid, sizeof(sta_ssid) - 1);
	sta_ssid[sizeof(sta_ssid) - 1] = '\0';

	wifi_set_reg_domain(iface);

	for (int attempt = 0; attempt <= WIFI_CONNECT_RETRIES; attempt++) {
		k_sem_reset(&link_connected_sem);

		ret = net_mgmt(NET_REQUEST_WIFI_CONNECT, iface, &req, sizeof(req));
		if (ret) {
			LOG_ERR("Connect request failed: %d (attempt %d)", ret, attempt);
			continue;
		}

		printk("[WiFi] Connecting to \"%s\"...\n", sta_ssid);

		ret = k_sem_take(&link_connected_sem, K_SECONDS(20));
		if (ret) {
			LOG_WRN("Connect timeout (attempt %d)", attempt);
			continue;
		}

		if (!sta_connected) {
			continue;
		}

		/* Link is up — request an address from the router */
		k_sem_reset(&ipv4_addr_sem);
		sta_ip[0] = '\0';
		net_dhcpv4_start(iface);

		ret = k_sem_take(&ipv4_addr_sem, K_SECONDS(20));
		if (ret) {
			LOG_WRN("DHCP timeout (link is up; check router)");
			return -ETIMEDOUT;
		}

		printk("[WiFi] Connected: SSID=%s IP=%s\n", sta_ssid, sta_ip);
		return 0;
	}

	return -EIO;
}

static int do_wifi_sta_disconnect(void)
{
	struct net_if *iface = net_if_get_first_wifi();

	if (!iface || !sta_connected) {
		printk("[WiFi] Not connected\n");
		return 0;
	}

	k_sem_reset(&link_disconnected_sem);
	net_mgmt(NET_REQUEST_WIFI_DISCONNECT, iface, NULL, 0);
	k_sem_take(&link_disconnected_sem, K_SECONDS(5));
	printk("[WiFi] Disconnected\n");
	return 0;
}

/* Shell commands */

static int cmd_wifi_connect(const struct shell *sh, size_t argc, char **argv)
{
	int band = 0;

	if (argc < 3) {
		shell_print(sh, "Usage: wifi connect <ssid> <psk> [band 0|1|2]");
		shell_print(sh, "  band: 0=any (default), 1=2.4G, 2=5G");
		return -EINVAL;
	}
	if (argc >= 4) {
		band = atoi(argv[3]);
		if (band < 0 || band > 2) {
			shell_print(sh, "Invalid band (0=any, 1=2.4G, 2=5G)");
			return -EINVAL;
		}
	}

	return do_wifi_sta_connect(argv[1], argv[2], band);
}

static int cmd_wifi_disconnect(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);
	return do_wifi_sta_disconnect();
}

static int cmd_wifi_status(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	shell_print(sh, "WiFi STA Status:");

	if (sta_connected) {
		shell_print(sh, "  SSID: %s", sta_ssid);
		shell_print(sh, "  IP: %s", sta_ip[0] ? sta_ip : "<no address>");
	} else {
		shell_print(sh, "  State: Disconnected");
		shell_print(sh, "  Use 'wifi connect <ssid> <psk> [band]'");
	}

	return 0;
}

static int cmd_wifi_scan(const struct shell *sh, size_t argc, char **argv)
{
	struct net_if *iface = net_if_get_first_wifi();
	static struct net_mgmt_event_callback scan_cb;
	int ret, band = 0;

	if (!iface) {
		shell_error(sh, "No WiFi interface");
		return -ENODEV;
	}

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

/* zperf UDP throughput test */
static K_SEM_DEFINE(zperf_done_sem, 0, 1);
static atomic_t zperf_sessions = ATOMIC_INIT(0);
static volatile bool zperf_error;

static void zperf_cb(enum zperf_status status,
		     struct zperf_results *result,
		     void *user_data)
{
	const struct shell *sh = (const struct shell *)user_data;

	switch (status) {
	case ZPERF_SESSION_STARTED:
		atomic_inc(&zperf_sessions);
		break;
	case ZPERF_SESSION_FINISHED:
		if (result && !zperf_error) {
			uint64_t bytes = (uint64_t)result->nb_packets_sent *
					 result->packet_size;
			uint64_t time_ms = result->client_time_in_us / 1000;
			uint32_t kbps = 0;

			if (result->client_time_in_us > 0) {
				kbps = (uint32_t)(
					((uint64_t)result->nb_packets_sent *
					 result->packet_size * 8ULL * 1000000ULL) /
					(result->client_time_in_us * 1024ULL));
			}
			shell_print(sh, "[iperf] pkts=%u lost=%u bytes=%llu time=%llums",
				    result->nb_packets_sent, result->nb_packets_lost,
				    bytes, time_ms);
			shell_print(sh, "[iperf] Throughput: %u kbps (%u.%03u Mbps)",
				    kbps, kbps / 1000, kbps % 1000);
		}
		if (atomic_dec(&zperf_sessions) <= 1) {
			k_sem_give(&zperf_done_sem);
		}
		break;
	case ZPERF_SESSION_ERROR:
		zperf_error = true;
		if (atomic_dec(&zperf_sessions) <= 1) {
			shell_print(sh, "[iperf] Test failed");
			k_sem_give(&zperf_done_sem);
		}
		break;
	default:
		break;
	}
}

static int cmd_udp_test(const struct shell *sh, size_t argc, char **argv)
{
	struct sockaddr_in addr;
	struct zperf_upload_params params;
	int ret;
	int duration_sec = IPERF_DURATION_SEC;
	uint32_t rate_kbps = 100000;

	if (!sta_connected) {
		shell_print(sh, "WiFi not connected. Use 'wifi connect <ssid> <psk>'.");
		return -ENETDOWN;
	}

	if (argc >= 2) {
		strncpy(iperf_server_ip, argv[1], sizeof(iperf_server_ip) - 1);
	}
	if (argc >= 3) {
		duration_sec = atoi(argv[2]);
		if (duration_sec <= 0 || duration_sec > 86400) {
			shell_print(sh, "Invalid duration (1-86400 seconds)");
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
	addr.sin_port = htons(IPERF_PORT);
	ret = inet_pton(AF_INET, iperf_server_ip, &addr.sin_addr);
	if (ret != 1) {
		shell_print(sh, "Invalid IP address");
		return -EINVAL;
	}

	memset(&params, 0, sizeof(params));
	params.duration_ms = duration_sec * 1000;
	params.packet_size = IPERF_PACKET_SIZE;
	params.rate_kbps = rate_kbps;
	memcpy(&params.peer_addr, &addr, sizeof(addr));

	shell_print(sh, "UDP throughput test (iperf v2 compatible)");
	shell_print(sh, "Target: %s:%d", iperf_server_ip, IPERF_PORT);
	shell_print(sh, "Duration: %d seconds, Rate: %u kbps", duration_sec, rate_kbps);
	shell_print(sh, "Run on PC: iperf -s -u -p 5001 -i 1");

	zperf_error = false;
	ret = zperf_udp_upload_async(&params, zperf_cb, (void *)sh);
	if (ret) {
		shell_print(sh, "Failed to start test: %d", ret);
		return ret;
	}

	/* Periodic progress: zperf only reports at session END, so poll the
	 * interface TX byte counter every 5 s. If this counter is flat while
	 * the test "runs", nothing is actually being sent. */
	{
		struct net_if *iface = net_if_get_first_wifi();
		uint64_t last_bytes = iface ? iface->stats.bytes.sent : 0;
		int64_t t0 = k_uptime_get();
		int64_t t_last = t0;
		uint32_t total_ms = (duration_sec + 30) * 1000;

		while (k_uptime_get() - t0 < total_ms) {
			ret = k_sem_take(&zperf_done_sem, K_SECONDS(5));
			if (ret == 0) {
				break;   /* session finished */
			}

			if (iface) {
				uint64_t now_bytes = iface->stats.bytes.sent;
				int64_t dt_ms = k_uptime_get() - t_last;
				uint64_t d_bytes = now_bytes - last_bytes;

				if (dt_ms >= 1000) {
					uint32_t kbps = (uint32_t)(
						(d_bytes * 8ULL) / (uint64_t)(dt_ms / 1000) / 1024ULL);

					shell_print(sh, "[iperf] t=%llums tx=%lluKB rate=%u kbps",
						    (k_uptime_get() - t0),
						    now_bytes / 1024, kbps);
				}
				last_bytes = now_bytes;
				t_last = k_uptime_get();
			}
		}

		if (ret != 0) {
			shell_print(sh, "Test timeout");
			return -ETIMEDOUT;
		}
	}

	return 0;
}

SHELL_STATIC_SUBCMD_SET_CREATE(sub_wifi,
	SHELL_CMD(connect, NULL, "Connect <ssid> <psk> [band 0|1|2]", cmd_wifi_connect),
	SHELL_CMD(disconnect, NULL, "Disconnect", cmd_wifi_disconnect),
	SHELL_CMD(scan, NULL, "Scan networks [band: 0=all, 1=2.4G, 2=5G]", cmd_wifi_scan),
	SHELL_CMD(status, NULL, "Show WiFi STA status", cmd_wifi_status),
	SHELL_SUBCMD_SET_END
);

SHELL_CMD_REGISTER(wifi, &sub_wifi, "WiFi STA commands", NULL);

SHELL_CMD_REGISTER(iperf, NULL, "UDP iperf test [server_ip] [duration_sec] [rate_kbps]",
		   cmd_udp_test);

int main(void)
{
#ifdef CLOCK_FEATURE_HFCLK_DIVIDE_PRESENT
	nrfx_clock_divider_set(NRF_CLOCK_DOMAIN_HFCLK, NRF_CLOCK_HFCLK_DIV_1);
#endif

	LOG_INF("WiFi STA + iperf Sample");

	net_mgmt_init_event_callback(&wifi_mgmt_cb, wifi_mgmt_event_handler,
				     NET_EVENT_WIFI_CONNECT_RESULT |
				     NET_EVENT_WIFI_DISCONNECT_RESULT);
	net_mgmt_add_event_callback(&wifi_mgmt_cb);

	net_mgmt_init_event_callback(&ipv4_mgmt_cb, ipv4_mgmt_event_handler,
				     NET_EVENT_IPV4_ADDR_ADD);
	net_mgmt_add_event_callback(&ipv4_mgmt_cb);

	printk("\nWiFi STA + iperf Sample (built " __DATE__ " " __TIME__ ")\n");
	printk("Commands: wifi connect <ssid> <psk> [band] | wifi disconnect | "
	       "wifi scan | wifi status | iperf <ip>\n\n");

	return 0;
}
