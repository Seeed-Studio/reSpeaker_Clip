/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/net/net_mgmt.h>
#include <zephyr/net/wifi_mgmt.h>
#include <zephyr/net/net_event.h>
#include <zephyr/net/net_if.h>
#include <zephyr/net/net_ip.h>
#include <zephyr/net/dhcpv4_server.h>
#include <zephyr/drivers/hwinfo.h>
#include <stdio.h>
#include <string.h>
#include <net/wifi_ready.h>
#include "wifi.h"
#include "wifi_udp.h"
#include "transport_udp.h"
#include "config.h"
#include "config.h"
#include "clip_event.h"
#include "ble.h"
#include "transfer.h"


#ifdef CONFIG_NRF70_SR_COEX
#include <coex.h>
#endif

LOG_MODULE_REGISTER(wifi, CONFIG_CLIP_LOG_LEVEL);

#define WIFI_AP_MGMT_EVENTS (NET_EVENT_WIFI_AP_ENABLE_RESULT |  \
							 NET_EVENT_WIFI_AP_DISABLE_RESULT | \
							 NET_EVENT_WIFI_AP_STA_CONNECTED |  \
							 NET_EVENT_WIFI_AP_STA_DISCONNECTED)

static char ap_ssid[32] = "ClipAP_Test";
static bool sta_connected;
static bool ap_running;
static bool wifi_ready;

static struct net_mgmt_event_callback wifi_mgmt_cb;
static K_SEM_DEFINE(wifi_ready_sem, 0, 1);
static K_SEM_DEFINE(ap_enabled_sem, 0, 1);
static K_SEM_DEFINE(ap_disabled_sem, 0, 1);

static void wifi_timeout_handler(struct k_work *work)
{
	ARG_UNUSED(work);
	if (ap_running && !sta_connected) {
		LOG_INF("WiFi timeout, auto-off");
		clip_post_event(CLIP_EVENT_WIFI_OFF);
	}
}

static K_WORK_DELAYABLE_DEFINE(wifi_timeout_work, wifi_timeout_handler);

/* Work for transfer cancel on STA disconnect (deferred to avoid stack issues) */
static void wifi_transfer_cancel_work_handler(struct k_work *work);
static K_WORK_DEFINE(wifi_transfer_cancel_work, wifi_transfer_cancel_work_handler);

static void wifi_transfer_cancel_work_handler(struct k_work *work)
{
	ARG_UNUSED(work);
	if (transfer_is_active()) {
		transfer_cancel();
	}
}

static void schedule_wifi_timeout(void)
{
	if (CONFIG_CLIP_WIFI_TIMEOUT_MS > 0) {
		k_work_reschedule(&wifi_timeout_work, K_MSEC(CONFIG_CLIP_WIFI_TIMEOUT_MS));
	}
}

static void cancel_wifi_timeout(void)
{
	k_work_cancel_delayable(&wifi_timeout_work);
}

#ifdef CONFIG_NRF70_SR_COEX
static void wifi_coex_configure(bool is_5ghz)
{
	bool sep = IS_ENABLED(CONFIG_COEX_SEP_ANTENNAS);
	bool ble = IS_ENABLED(CONFIG_SR_PROTOCOL_BLE);
	enum nrf_wifi_pta_wlan_op_band band = is_5ghz ?
		NRF_WIFI_PTA_WLAN_OP_BAND_5_GHZ : NRF_WIFI_PTA_WLAN_OP_BAND_2_4_GHZ;
	int ret;

	ret = nrf_wifi_coex_config_non_pta(sep, ble);
	if (ret)
	{
		LOG_WRN("Coex non-PTA config failed: %d", ret);
	}
	ret = nrf_wifi_coex_config_pta(band, sep, ble);
	if (ret)
	{
		LOG_WRN("Coex PTA config failed: %d", ret);
	}
	LOG_INF("coex PTA (%s sep=%d ble=%d)", is_5ghz ? "5GHz" : "2.4GHz", sep, ble);
}
#endif

static void generate_ap_ssid(void)
{
	uint8_t chip_id[16];
	ssize_t len = hwinfo_get_device_id(chip_id, sizeof(chip_id));

	if (len > 0)
	{
		uint32_t suffix = 0;
		int off = len > 4 ? len - 4 : 0;

		for (int i = 0; i < 4 && (off + i) < len; i++)
		{
			suffix = (suffix << 8) | chip_id[off + i];
		}
		snprintf(ap_ssid, sizeof(ap_ssid), "%s%04X",
				 WIFI_AP_SSID_PREFIX, (unsigned)(suffix & 0xFFFF));
	}
	LOG_INF("AP SSID: %s", ap_ssid);
}

static void wifi_mgmt_event_handler(struct net_mgmt_event_callback *cb,
									uint64_t mgmt_event, struct net_if *iface)
{
	ARG_UNUSED(cb);
	ARG_UNUSED(iface);

	switch (mgmt_event)
	{
	case NET_EVENT_WIFI_AP_ENABLE_RESULT:
	{
		const struct wifi_status *status = (const struct wifi_status *)cb->info;
		if (status->status)
		{
			LOG_ERR("AP enable failed: %d", status->status);
		}
		else
		{
			LOG_INF("WiFi AP enabled");
			ap_running = true;
		}
		k_sem_give(&ap_enabled_sem);
		break;
	}
	case NET_EVENT_WIFI_AP_DISABLE_RESULT:
		LOG_INF("WiFi AP disabled");
		ap_running = false;
		sta_connected = false;
		k_sem_give(&ap_disabled_sem);
		break;
	case NET_EVENT_WIFI_AP_STA_CONNECTED:
	{
		const struct wifi_ap_sta_info *sta_info = (const struct wifi_ap_sta_info *)cb->info;
		char mac_string_buf[sizeof("xx:xx:xx:xx:xx:xx")];
		snprintf(mac_string_buf, sizeof(mac_string_buf),
				 "%02x:%02x:%02x:%02x:%02x:%02x",
				 sta_info->mac[0], sta_info->mac[1], sta_info->mac[2],
				 sta_info->mac[3], sta_info->mac[4], sta_info->mac[5]);
		LOG_INF("Station connected: %s", mac_string_buf);
		sta_connected = true;
		cancel_wifi_timeout();
		transport_udp_update_active(false); /* Reset, waiting for new client */
		break;
	}
	case NET_EVENT_WIFI_AP_STA_DISCONNECTED:
	{
		const struct wifi_ap_sta_info *sta_info = (const struct wifi_ap_sta_info *)cb->info;
		char mac_string_buf[sizeof("xx:xx:xx:xx:xx:xx")];
		snprintf(mac_string_buf, sizeof(mac_string_buf),
				 "%02x:%02x:%02x:%02x:%02x:%02x",
				 sta_info->mac[0], sta_info->mac[1], sta_info->mac[2],
				 sta_info->mac[3], sta_info->mac[4], sta_info->mac[5]);
		LOG_INF("Station disconnected: %s", mac_string_buf);
		sta_connected = false;
		schedule_wifi_timeout();
		transport_udp_update_active(false); /* Notify transport of disconnect */
		k_work_submit(&wifi_transfer_cancel_work);
		break;
	}
	default:
		break;
	}
}

static void wifi_ready_callback(bool ready)
{
	LOG_DBG("WiFi ready: %s", ready ? "yes" : "no");
	wifi_ready = ready;
	if (ready)
	{
		k_sem_give(&wifi_ready_sem);
	}
}

int wifi_init(void)
{
	struct net_if *iface;
	wifi_ready_callback_t cb;
	int ret;

	generate_ap_ssid();

	/* Register WiFi management events */
	net_mgmt_init_event_callback(&wifi_mgmt_cb, wifi_mgmt_event_handler,
								 WIFI_AP_MGMT_EVENTS);
	net_mgmt_add_event_callback(&wifi_mgmt_cb);

	/* Register WiFi ready callback */
	iface = net_if_get_first_wifi();
	if (iface)
	{
		cb.wifi_ready_cb = wifi_ready_callback;
		ret = register_wifi_ready_callback(cb, iface);
		if (ret)
		{
			LOG_WRN("wifi_ready cb reg failed %d", ret);
		}
	}

	LOG_INF("WiFi module initialized");


	return 0;
}

static int wifi_set_reg_domain(struct net_if *iface)
{
	struct wifi_reg_domain regd = {0};
	int ret;

	regd.oper = WIFI_MGMT_SET;
	strncpy(regd.country_code, config_get_wifi_reg_domain(), WIFI_COUNTRY_CODE_LEN);

	ret = net_mgmt(NET_REQUEST_WIFI_REG_DOMAIN, iface, &regd, sizeof(regd));
	if (ret)
	{
		LOG_WRN("Failed to set reg domain: %d", ret);
	}

	return ret;
}

#define WIFI_AP_ENABLE_RETRIES 2

static int wifi_enable_ap(struct net_if *iface)
{
	struct wifi_connect_req_params req;
	int ret;

	memset(&req, 0, sizeof(req));
	req.ssid = (const uint8_t *)ap_ssid;
	req.ssid_length = strlen(ap_ssid);
	req.psk = (const uint8_t *)config_get_wifi_password();
	req.psk_length = strlen(config_get_wifi_password());
	uint8_t channel = config_get_wifi_channel();
	bool is_5ghz = (channel >= 36);

	req.channel = channel;
	req.security = WIFI_SECURITY_TYPE_PSK;
	req.mfp = WIFI_MFP_OPTIONAL;
	req.band = is_5ghz ? WIFI_FREQ_BAND_5_GHZ : WIFI_FREQ_BAND_2_4_GHZ;

	for (int attempt = 0; attempt <= WIFI_AP_ENABLE_RETRIES; attempt++) {
		k_sem_reset(&ap_enabled_sem);

		ret = net_mgmt(NET_REQUEST_WIFI_AP_ENABLE, iface, &req, sizeof(req));
		if (ret) {
			LOG_ERR("AP enable fail %d (try %d)", ret, attempt);
			continue;
		}

		ret = k_sem_take(&ap_enabled_sem, K_SECONDS(5));
		if (ret) {
			LOG_WRN("AP enable timeout (attempt %d)", attempt);
			continue;
		}

		if (!ap_running) {
			LOG_ERR("AP enable rejected (attempt %d)", attempt);
			continue;
		}

	return 0;
	}

	return -ETIMEDOUT;
}

static int wifi_start_dhcp_server(struct net_if *iface)
{
	struct in_addr pool_start;
	int ret;

	/* Derive pool start from server IP (192.168.4.1 -> 192.168.4.2) */
	net_addr_pton(AF_INET, CONFIG_NET_CONFIG_MY_IPV4_ADDR, &pool_start);
	pool_start.s_addr = htonl(ntohl(pool_start.s_addr) + 1);

	ret = net_dhcpv4_server_start(iface, &pool_start);
	if (ret && ret != -EALREADY)
	{
		LOG_WRN("DHCP server start failed: %d", ret);
	}
	else
	{
		LOG_INF("DHCP server started");
	}

	return ret;
}

int wifi_on(void)
{
	struct net_if *iface;
	int ret;

	/* Check if already running */
	if (ap_running)
	{
		LOG_DBG("AP already running");
		return 0;
	}

	iface = net_if_get_first_wifi();
	if (!iface)
	{
		LOG_ERR("No WiFi interface");
		return -ENODEV;
	}

	/* Bring up interface if not already up */
	if (!net_if_is_admin_up(iface))
	{
		LOG_INF("Interface is down, bringing up");
		ret = net_if_up(iface);
		if (ret)
		{
			LOG_ERR("net_if_up failed: %d", ret);
			return ret;
		}

		/* Wait for WiFi driver ready */
		if (!wifi_ready) {
			ret = k_sem_take(&wifi_ready_sem, K_SECONDS(3));
			if (ret) {
				LOG_ERR("WiFi ready timeout");
				net_if_down(iface);
				return -ETIMEDOUT;
			}
		}
	}

	/* Set regulatory domain */
	wifi_set_reg_domain(iface);

	/* Enable AP mode */
	ret = wifi_enable_ap(iface);
	if (ret)
	{
		LOG_WRN("wifi_on: AP failed, cleaning up");
		net_if_down(iface);
		ap_running = false;
		return ret;
	}

#ifdef CONFIG_NRF70_SR_COEX
	/* Configure coexistence AFTER AP is enabled. Do NOT configure before
	 * AP enable — if nRF70 is in a bad state, coex config hangs forever.
	 * The band follows the channel (>=36 is 5GHz), same as wifi_enable_ap(). */
	wifi_coex_configure(config_get_wifi_channel() >= 36);
#endif

	/* Configure static IP from Kconfig macros */
	{
		struct in_addr addr, netmask, gw;
		struct net_if_addr *ifaddr;
		net_addr_pton(AF_INET, CONFIG_NET_CONFIG_MY_IPV4_ADDR, &addr);
		net_addr_pton(AF_INET, CONFIG_NET_CONFIG_MY_IPV4_NETMASK, &netmask);
		net_addr_pton(AF_INET, CONFIG_NET_CONFIG_MY_IPV4_GW, &gw);
		ifaddr = net_if_ipv4_addr_add(iface, &addr, NET_ADDR_MANUAL, 0);
		if (!ifaddr && !net_if_ipv4_addr_lookup(&addr, &iface))
		{
			LOG_WRN("Failed to set IP address");
		}
		net_if_ipv4_set_netmask_by_addr(iface, &addr, &netmask);
		net_if_ipv4_set_gw(iface, &gw);
	}

	/* Start DHCP server */
	ret = wifi_start_dhcp_server(iface);
	if (ret) {
		LOG_WRN("DHCP server start failed: %d", ret);
	}

	/* Start UDP server */
	ret = wifi_udp_start();
	if (ret)
	{
		LOG_WRN("UDP server start failed: %d", ret);
		/* Continue anyway - UDP is optional */
	}

	/* Start auto-off timeout */
	schedule_wifi_timeout();

	LOG_INF("AP up: %s ch=%d %s:%d",
			ap_ssid, WIFI_AP_CHANNEL, CONFIG_NET_CONFIG_MY_IPV4_ADDR, WIFI_AP_UDP_PORT);

	ble_notify_event("wifi", "on");

	return 0;
}

int wifi_off(void)
{
	struct net_if *iface = net_if_get_first_wifi();
	int ret;

	cancel_wifi_timeout();

	if (!ap_running) {
		return 0;
	}

	if (!iface)
	{
		return -ENODEV;
	}

	/* Stop UDP server */
	wifi_udp_stop();

	/* Stop DHCP server */
	net_dhcpv4_server_stop(iface);

	/* Disable AP mode — wait for the result before powering down,
	 * otherwise a fast re-enable (wifi_on) can race the still-pending
	 * disable and fail. */
	k_sem_reset(&ap_disabled_sem);
	net_mgmt(NET_REQUEST_WIFI_AP_DISABLE, iface, NULL, 0);
	ret = k_sem_take(&ap_disabled_sem, K_SECONDS(3));
	if (ret) {
		LOG_WRN("WiFi AP disable timeout: %d", ret);
	}
	ap_running = false;
	sta_connected = false;

	/* Reset WiFi ready state so next wifi_on() waits properly */
	wifi_ready = false;
	k_sem_reset(&wifi_ready_sem);

#ifdef CONFIG_NRF70_SR_COEX
	/* Reset coexistence hardware */
	nrf_wifi_coex_hw_reset();
#endif

	/* Power down interface to save power (required when CONFIG_NRF_WIFI_IF_AUTO_START=n) */
	if (net_if_is_admin_up(iface))
	{
		LOG_INF("wifi_off: calling net_if_down");
		ret = net_if_down(iface);
		if (ret)
		{
			LOG_WRN("net_if_down failed: %d", ret);
		}
		else
		{
			LOG_INF("wifi_off: net_if_down done");
		}
	}

	ble_notify_event("wifi", "off");

	return 0;
}

bool wifi_is_interface_up(void)
{
	struct net_if *iface = net_if_get_first_wifi();

	if (!iface)
	{
		return false;
	}
	return net_if_is_up(iface);
}

bool wifi_ap_is_running(void)
{
	return ap_running;
}

const char *wifi_get_ssid(void)
{
	return ap_ssid;
}

const char *wifi_get_password(void)
{
	return config_get_wifi_password();
}

const char *wifi_get_ip_address(void)
{
	return CONFIG_NET_CONFIG_MY_IPV4_ADDR;
}

bool wifi_is_sta_connected(void)
{
	return sta_connected;
}
