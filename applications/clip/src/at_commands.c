/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/logging/log_backend.h>
#include <zephyr/logging/log_ctrl.h>
#include <zephyr/sys/reboot.h>
#include <zephyr/drivers/regulator.h>
#include <zephyr/settings/settings.h>
#include <zephyr/retention/bootmode.h>
#include <time.h>
#include <string.h>
#include <strings.h>
#include <stdio.h>
#include <stdlib.h>
#include "at_commands.h"
#include "at_server.h"
#include "clip.h"
#include "clip_event.h"
#include "config.h"
#include "battery.h"
#include "app_version.h"
#include "audio.h"
#include "storage.h"
#include "transfer.h"
#include "ble.h"
#include "wifi.h"
#include "display.h"
#include "haptic.h"
#include "usb_cdc.h"
#ifdef CONFIG_CLIP_THROUGHPUT_TEST
#include "throughput_test.h"
#endif

LOG_MODULE_REGISTER(at_commands, CONFIG_CLIP_LOG_LEVEL);

/* Delayed reboot work — allows response to be sent before rebooting */
static struct k_work_delayable reboot_work;
static bool reboot_clear_bonds;
static bool log_fs_active = IS_ENABLED(CONFIG_CLIP_LOG_FS_DEFAULT_ON);

static void reboot_work_handler(struct k_work *work)
{
    /* Stop recording if active before rebooting */
    if (audio_is_recording()) {
        audio_stop_recording();
        k_sleep(K_MSEC(100));
    }
    if (reboot_clear_bonds) {
        ble_clear_bonds();
    }
    /* Persist fuel gauge state so the SoC is continuous across this reboot. */
    battery_save_fg_state();
    sys_reboot(SYS_REBOOT_COLD);
}

static void schedule_reboot(int delay_ms, bool clear_bonds)
{
    reboot_clear_bonds = clear_bonds;
    k_work_schedule(&reboot_work, K_MSEC(delay_ms));
}

/* Helper: Extract integer from string */
static int extract_int(const char *str, int *value)
{
    if (!str || !value) {
        return -EINVAL;
    }
    char *end;
    long val = strtol(str, &end, 10);
    if (end == str || *end != '\0') {
        return -EINVAL;
    }
    *value = (int)val;
    return 0;
}

/* Helper: Create JSON response */
static int create_json_response(bool success, const char *message,
                                const char *data, char *response, size_t len)
{
    int n = 0;
    if (success) {
        n = snprintf(response, len, "{\"ok\":true");
    } else {
        n = snprintf(response, len, "{\"ok\":false");
    }
    if (n < 0 || n >= len) {
        return AT_ERR_NOMEM;
    }
    if (message) {
        int ret = snprintf(response + n, len - n, ",\"msg\":\"%s\"", message);
        if (ret < 0 || ret >= (len - n)) {
            return AT_ERR_NOMEM;
        }
        n += ret;
    }
    if (data) {
        int ret = snprintf(response + n, len - n, ",\"data\":%s", data);
        if (ret < 0 || ret >= (len - n)) {
            return AT_ERR_NOMEM;
        }
        n += ret;
    }
    if (n + 3 < len) {
        response[n] = '}';
        response[n + 1] = '\n';
        return n + 2;
    }
    return AT_ERR_NOMEM;
}

/* Validate session_id: must be exactly 14 digits (YYYYMMDDHHMMSS) */
static bool is_valid_session_id(const char *id)
{
    if (!id || strlen(id) != 14) {
        return false;
    }
    for (int i = 0; i < 14; i++) {
        if (id[i] < '0' || id[i] > '9') {
            return false;
        }
    }
    return true;
}

/* GSTAT Command Handler - Get device status */
/* BATT Command Handler - Get battery status (%, charging, voltage, temp).
 * Exposes the NPM1300 voltage + NTC temperature that battery.c refreshes every
 * poll, alongside the SoC % and charging state. Useful for field/debug thermal
 * monitoring and verifying the 45C charge cutoff. */
static int cmd_batt_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    struct clip_context *c = clip_get_context();
    int n = snprintf(response, len,
        "{\"ok\":true,\"data\":{\"battery\":%u,\"charging\":%s,\"voltage\":%u,\"temp\":%d}}",
        c->status.battery_percent,
        c->status.battery_charging ? "true" : "false",
        c->status.battery_mv,
        c->status.battery_temp);
    if (n < 0 || n >= len - 2) {
        return AT_ERR_NOMEM;
    }
    response[n] = '\n';
    return n + 1;
}

static int cmd_gstat_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    struct clip_context *c = clip_get_context();
    struct storage_stats stats;
    struct audio_stats audio_stats;
    uint32_t free_space = 0;
    uint32_t recording_duration = 0;
    const char *session_id = NULL;
    const char *mode_str = (c->config.mode == MODE_NORMAL) ? "normal" : "enhanced";
    const char *device_name = ble_get_device_name();

    /* Get storage statistics */
    if (storage_get_stats(&stats) == 0) {
        free_space = stats.free_space_mb;
    }

    /* Get recording duration and session ID if recording */
    /* Check session_id first to handle startup window where recording is
     * initializing but session_id is already set */
    session_id = audio_get_session_id();
    if (session_id != NULL && audio_get_stats(&audio_stats) == 0) {
        recording_duration = (uint32_t)(audio_stats.recording_time_ms / 1000);
    }

    /* Build response - format matches clip for compatibility
     * Clip wraps data in "data" field: {"ok":true,"data":{...}}
     */
    char data_buf[512];
    int data_len = snprintf(data_buf, sizeof(data_buf),
                     "{\"state\":\"%s\","
                     "\"recording\":%s,"
                     "\"session\":%s%s%s,"
                     "\"duration\":%u,"
                     "\"battery\":%u,"
                     "\"charging\":%s,"
                     "\"temp\":%d,"
                     "\"voltage\":%u,"
                     "\"mode\":\"%s\","
                     "\"bitrate\":%u,"
                     "\"free_space\":%u,"
                     "\"device\":\"%s\"}",
                     clip_state_to_string(clip_event_get_state()),
                     audio_is_recording() ? "true" : "false",
                     session_id ? "\"" : "", session_id ? session_id : "null", session_id ? "\"" : "",
                     recording_duration,
                     c->status.battery_percent,
                     c->status.battery_charging ? "true" : "false",
                     c->status.battery_temp,
                     c->status.battery_mv,
                     mode_str,
                     (c->config.mode == MODE_NORMAL) ? CONFIG_CLIP_NORMAL_BITRATE : CONFIG_CLIP_ENHANCED_BITRATE,
                     free_space,
                     device_name ? device_name : "Unknown");

    if (data_len < 0 || data_len >= sizeof(data_buf)) {
        return AT_ERR_NOMEM;
    }

    /* Wrap in {"ok":true,"data":...} format to match clip */
    int n = snprintf(response, len, "{\"ok\":true,\"data\":%s}", data_buf);
    if (n < 0 || n >= len - 2) {
        return AT_ERR_NOMEM;
    }
    response[n] = '\n';

    /* Log GSTAT response for debugging */
    LOG_DBG("GSTAT: %s", response);

    return n + 1;
}

/* DEVICE Command Handler - Get device name */
static int cmd_device_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    const char *device_name = ble_get_device_name();
    char name_buf[32];

    snprintf(name_buf, sizeof(name_buf), "\"%s\"", device_name ? device_name : "Unknown");
    int n = snprintf(response, len, "{\"ok\":true,\"device\":%s}", name_buf);
    if (n < 0 || n >= len - 2) {
        return AT_ERR_NOMEM;
    }
    response[n] = '\n';
    return n + 1;
}

/* VERSION Command Handler - Get firmware version */
static int cmd_version_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    char version_str[32];
    snprintf(version_str, sizeof(version_str), "\"%s\"", CLIP_VERSION);
    int n = snprintf(response, len, "{\"ok\":true,\"firmware\":%s}", version_str);
    if (n < 0 || n >= len - 2) {
        return AT_ERR_NOMEM;
    }
    response[n] = '\n';
    return n + 1;
}

/* TIME Command Handler - Get/Set time */
static int cmd_time_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    struct clip_context *c = clip_get_context();

    if (ctx->type == AT_CMD_TYPE_SET || ctx->type == AT_CMD_TYPE_EXEC) {
        /* Set time: AT+TIME=<unix_timestamp> */
        if (!ctx->args || strlen(ctx->args) == 0) {
            return create_json_response(false, "Missing timestamp", NULL, response, len);
        }

        /* Parse 64-bit timestamp directly (extract_int only handles 32-bit) */
        char *end;
        int64_t timestamp = strtoll(ctx->args, &end, 10);
        if (end == ctx->args || *end != '\0') {
            return create_json_response(false, "Invalid timestamp", NULL, response, len);
        }

        /* Convert Unix timestamp to YMDHMS */
        time_t ts = (time_t)timestamp;
        struct tm *tm_info = localtime(&ts);
        if (!tm_info) {
            return create_json_response(false, "Invalid time", NULL, response, len);
        }

        uint16_t year = tm_info->tm_year + 1900;
        uint8_t month = tm_info->tm_mon + 1;
        uint8_t day = tm_info->tm_mday;
        uint8_t hour = tm_info->tm_hour;
        uint8_t min = tm_info->tm_min;
        uint8_t sec = tm_info->tm_sec;

        c->time.year = year;
        c->time.month = month;
        c->time.day = day;
        c->time.hour = hour;
        c->time.min = min;
        c->time.sec = sec;
        c->time.base_uptime_ms = k_uptime_get();
        c->time.valid = true;

        /* Save to storage */
        config_set_time_ymd(year, month, day, hour, min, sec);

        char data[64];
        /* Manual int64 to string conversion - Zephyr snprintf doesn't support %lld */
        char ts_str[32];
        int64_t ts_val = timestamp;
        int ts_idx = 0;
        bool negative = ts_val < 0;
        if (negative) ts_val = -ts_val;

        /* Convert to string (reverse order) */
        if (ts_val == 0) {
            ts_str[ts_idx++] = '0';
        } else {
            while (ts_val > 0) {
                ts_str[ts_idx++] = '0' + (ts_val % 10);
                ts_val /= 10;
            }
        }
        if (negative) ts_str[ts_idx++] = '-';

        /* Reverse to get correct order */
        for (int i = 0; i < ts_idx / 2; i++) {
            char tmp = ts_str[i];
            ts_str[i] = ts_str[ts_idx - 1 - i];
            ts_str[ts_idx - 1 - i] = tmp;
        }
        ts_str[ts_idx] = '\0';

        snprintf(data, sizeof(data), "{\"time\":%s}", ts_str);
        return create_json_response(true, NULL, data, response, len);
    } else {
        /* Get time: AT+TIME? */
        if (!c->time.valid) {
            return create_json_response(false, "Time not set (use AT+TIME=<timestamp>)", NULL, response, len);
        }

        uint16_t year;
        uint8_t month, day, hour, min, sec;
        if (!clip_get_current_time(&year, &month, &day, &hour, &min, &sec)) {
            return create_json_response(false, "Time error", NULL, response, len);
        }

        /* Return ISO 8601 format to be compatible with clip */
        char time_buf[64];
        snprintf(time_buf, sizeof(time_buf),
                 "\"%04u-%02u-%02uT%02u:%02u:%02uZ\"",
                 year, month, day, hour, min, sec);

        char data[128];
        snprintf(data, sizeof(data), "{\"time\":%s}", time_buf);
        return create_json_response(true, NULL, data, response, len);
    }
}

/* MODE Command Handler - Get/Set recording mode */
static int cmd_mode_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    struct clip_context *c = clip_get_context();

    if (ctx->type == AT_CMD_TYPE_SET) {
        /* Set mode: AT+MODE=<normal|enhanced> */
        if (!ctx->args || strlen(ctx->args) == 0) {
            return create_json_response(false, "Missing mode value", NULL, response, len);
        }

        /* Convert to lowercase for comparison */
        char mode_str[32];
        strncpy(mode_str, ctx->args, sizeof(mode_str) - 1);
        mode_str[sizeof(mode_str) - 1] = '\0';
        for (char *p = mode_str; *p; p++) {
            if (*p >= 'A' && *p <= 'Z') {
                *p = *p - 'A' + 'a';
            }
        }

        enum recording_mode mode;
        if (strcmp(mode_str, "normal") == 0) {
            mode = MODE_NORMAL;
        } else if (strcmp(mode_str, "enhanced") == 0) {
            mode = MODE_ENHANCED;
        } else {
            return create_json_response(false, "Mode must be normal or enhanced", NULL, response, len);
        }

        c->config.mode = mode;
        config_set_mode(mode);

        char data[32];
        snprintf(data, sizeof(data), "{\"mode\":\"%s\"}", mode_str);
        return create_json_response(true, NULL, data, response, len);
    } else {
        /* Get mode: AT+MODE? */
        const char *mode_str = (c->config.mode == MODE_NORMAL) ? "normal" : "enhanced";
        char data[32];
        snprintf(data, sizeof(data), "{\"mode\":\"%s\"}", mode_str);
        return create_json_response(true, NULL, data, response, len);
    }
}

/* LOG Command Handler - control the FS (SD card) log backend.
 * AT+LOG=off (default) | info | debug. Default off so the SD can idle-power-off;
 * when on, INF (or DBG) level logs persist to /SD:/LOG. */
static int cmd_log_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    if (ctx->type == AT_CMD_TYPE_SET) {
        if (!ctx->args || strlen(ctx->args) == 0) {
            return create_json_response(false, "Missing log mode", NULL, response, len);
        }

        char mode[32];
        strncpy(mode, ctx->args, sizeof(mode) - 1);
        mode[sizeof(mode) - 1] = '\0';
        for (char *p = mode; *p; p++) {
            if (*p >= 'A' && *p <= 'Z') {
                *p = *p - 'A' + 'a';
            }
        }

        if (strcmp(mode, "off") == 0) {
            log_fs_active = false;
            const struct log_backend *fs_be = log_backend_get_by_name("log_backend_fs");
            if (fs_be) {
                log_backend_deactivate(fs_be);
            }
            char data[32];
            snprintf(data, sizeof(data), "{\"log\":\"off\"}");
            return create_json_response(true, NULL, data, response, len);
        }

        if (strcmp(mode, "info") != 0 && strcmp(mode, "debug") != 0) {
            return create_json_response(false, "Log mode must be off, info or debug",
                                        NULL, response, len);
        }

        uint32_t level = (strcmp(mode, "debug") == 0) ? LOG_LEVEL_DBG : LOG_LEVEL_INF;

        /* SD may be idle-powered-off; bring it up before enabling the backend */
        if (storage_ensure_mounted() != 0) {
            return create_json_response(false, "SD card not available", NULL, response, len);
        }

        const struct log_backend *fs_be = log_backend_get_by_name("log_backend_fs");
        if (!fs_be) {
            return create_json_response(false, "FS log backend unavailable", NULL, response, len);
        }

        log_backend_activate(fs_be, NULL);
        uint32_t src_cnt = log_src_cnt_get(0);
        for (uint32_t i = 0; i < src_cnt; i++) {
            log_filter_set(fs_be, 0, (int16_t)i, level);
        }
        log_fs_active = true;
        clip_storage_activity_notify();

        char data[32];
        snprintf(data, sizeof(data), "{\"log\":\"%s\"}", mode);
        return create_json_response(true, NULL, data, response, len);
    } else {
        /* AT+LOG? */
        const char *m = log_fs_active ? "info" : "off";
        char data[32];
        snprintf(data, sizeof(data), "{\"log\":\"%s\"}", m);
        return create_json_response(true, NULL, data, response, len);
    }
}

bool clip_log_fs_active(void)
{
    return log_fs_active;
}

/* AUTODEL Command Handler - Get/Set auto-delete policy */
static int cmd_autodel_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    struct clip_context *c = clip_get_context();

    if (ctx->type == AT_CMD_TYPE_SET) {
        /* Set autodel: AT+AUTODEL=<days> or AT+AUTODEL=off */
        if (!ctx->args || strlen(ctx->args) == 0) {
            return create_json_response(false, "Missing autodel value", NULL, response, len);
        }

        char autodel_str[32];
        strncpy(autodel_str, ctx->args, sizeof(autodel_str) - 1);
        autodel_str[sizeof(autodel_str) - 1] = '\0';
        for (char *p = autodel_str; *p; p++) {
            if (*p >= 'A' && *p <= 'Z') {
                *p = *p - 'A' + 'a';
            }
        }

        if (strcmp(autodel_str, "off") == 0 || strcmp(autodel_str, "-1") == 0) {
            c->config.auto_delete_days = -1;
            config_set_auto_delete_days(-1);
            return create_json_response(true, NULL, "{\"autodel\":\"off\"}", response, len);
        } else {
            int days;
            if (extract_int(ctx->args, &days) != 0) {
                return create_json_response(false, "Invalid autodel value", NULL, response, len);
            }

            if (days < 0 || days > 30) {
                return create_json_response(false, "Auto-delete must be 0-30 days or off", NULL, response, len);
            }

            c->config.auto_delete_days = days;
            config_set_auto_delete_days(days);

            char data[32];
            snprintf(data, sizeof(data), "{\"autodel\":%d}", days);
            return create_json_response(true, NULL, data, response, len);
        }
    } else {
        /* Get autodel: AT+AUTODEL? */
        char data[32];
        if (c->config.auto_delete_days < 0) {
            snprintf(data, sizeof(data), "{\"autodel\":\"off\"}");
        } else {
            snprintf(data, sizeof(data), "{\"autodel\":%d}", c->config.auto_delete_days);
        }
        return create_json_response(true, NULL, data, response, len);
    }
}

/* BRIGHTNESS Command Handler - Get/Set OLED brightness */
static int cmd_brightness_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    struct clip_context *c = clip_get_context();

    if (ctx->type == AT_CMD_TYPE_SET) {
        /* Set brightness: AT+BRIGHTNESS=<0-255> */
        if (!ctx->args || strlen(ctx->args) == 0) {
            return create_json_response(false, "Missing brightness value", NULL, response, len);
        }

        int brightness;
        if (extract_int(ctx->args, &brightness) != 0) {
            return create_json_response(false, "Invalid brightness", NULL, response, len);
        }

        /* Validate brightness range */
        if (brightness < 0 || brightness > 255) {
            return create_json_response(false, "Brightness must be 0-255", NULL, response, len);
        }

        c->config.oled_brightness = brightness;
        config_set_oled_brightness(brightness);
        clip_display_set_brightness((uint8_t)brightness);

        /* Show status bar briefly to confirm brightness change */
        clip_post_event(CLIP_EVENT_STATUS_SHOW);

        char data[32];
        snprintf(data, sizeof(data), "{\"brightness\":%u}", brightness);
        return create_json_response(true, NULL, data, response, len);
    } else {
        /* Get brightness: AT+BRIGHTNESS? */
        char data[32];
        snprintf(data, sizeof(data), "{\"brightness\":%u}", c->config.oled_brightness);
        return create_json_response(true, NULL, data, response, len);
    }
}

/* POWEROFF Command Handler - Shutdown the device */
static int cmd_poweroff_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    /* Send success response first */
    int ret = create_json_response(true, NULL, "{\"poweroff\":\"shutting down\"}", response, len);

    k_sleep(K_MSEC(500));

    struct clip_event_result_info info;
    clip_post_event_sync(CLIP_EVENT_POWER_OFF_EXEC, &info);

    return ret;
}

/* FACTORY Command Handler - Factory reset */
static int cmd_factory_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    /* Check for confirmation parameter */
    char confirm_str[32];
    if (ctx->args && strlen(ctx->args) > 0) {
        strncpy(confirm_str, ctx->args, sizeof(confirm_str) - 1);
        confirm_str[sizeof(confirm_str) - 1] = '\0';
        for (char *p = confirm_str; *p; p++) {
            if (*p >= 'A' && *p <= 'Z') {
                *p = *p - 'A' + 'a';
            }
        }

        if (strcmp(confirm_str, "confirm") != 0 && strcmp(confirm_str, "yes") != 0) {
            return create_json_response(false, "Add 'confirm' or 'yes' to proceed", NULL, response, len);
        }
    } else {
        return create_json_response(false, "Add 'confirm' or 'yes' to proceed", NULL, response, len);
    }

    /* Perform factory reset (clear LittleFS config) */
    int err = config_factory_reset();
    if (err) {
        return create_json_response(false, "Factory reset failed", NULL, response, len);
    }

    /* Format SD card (clear FATFS recordings) */
    err = storage_format_card();
    if (err) {
        LOG_WRN("SD format failed during factory reset: %d", err);
    }

    /* Send response before clearing bonds (which may drop BLE link) */
    int ret = create_json_response(true, "Factory reset complete, rebooting...", NULL, response, len);

    /* Schedule: clear bonds then reboot */
    schedule_reboot(500, true);

    return ret;
}

/* REBOOT Command Handler - Reboot the device */
static int cmd_reboot_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    /* Send success response first */
    int ret = create_json_response(true, NULL, "{\"reboot\":\"restarting\"}", response, len);

    /* Schedule reboot after response is sent */
    schedule_reboot(500, false);

    return ret;
}

/* DFU Command Handler - Reboot into MCUboot recovery mode */
static int cmd_dfu_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    /* Set boot mode to bootloader before rebooting */
    int ret = bootmode_set(BOOT_MODE_TYPE_BOOTLOADER);
    if (ret != 0) {
        return create_json_response(false, "Failed to set boot mode", NULL, response, len);
    }

    clip_post_event(CLIP_EVENT_OTA_START);

    ret = create_json_response(true, NULL, "{\"dfu\":\"rebooting\"}", response, len);

    /* Schedule reboot after response is sent */
    schedule_reboot(500, false);

    return ret;
}

/* PAIR Command Handler - Query or reset BLE pairing */
static int cmd_pair_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    if (ctx->type == AT_CMD_TYPE_SET) {
        /* AT+PAIR=reset - Clear bonds and reboot */
        if (!ctx->args || strcmp(ctx->args, "reset") != 0) {
            return create_json_response(false, "Use AT+PAIR=reset", NULL, response, len);
        }

        /* Clear bonds and persist before reboot. ble_clear_bonds may
         * drop the BLE link, so send the response first. Rotate the BLE
         * identity first so iOS (which caches stale bonds) sees a new device
         * and re-pairs fresh after the reboot. */
        int ret = create_json_response(true, NULL, "{\"rebooting\":true}", response, len);

        /* Rotate the BLE identity (retry). If this fails, the device reboots
         * with the OLD address but cleared bonds — the phone's cached stale
         * bond (iOS) then blocks re-pairing, which only a full settings wipe
         * (recovery) fixes. Retry so the rotation actually takes. */
        for (int i = 0; i < 3; i++) {
            int rerr = ble_rotate_identity();
            if (rerr == 0) {
                break;
            }
            LOG_WRN("ble_rotate_identity failed: %d (attempt %d)", rerr, i + 1);
            if (i < 2) {
                k_sleep(K_MSEC(200));
            }
        }
        ble_clear_bonds();
        settings_save();
        storage_format_card();
        schedule_reboot(500, true);
        return ret;
    } else {
        /* AT+PAIR? - Query pairing status */
        char addr[18] = {0};
        bool bonded = (ble_get_bond_addr(addr, sizeof(addr)) == 0);

        if (bonded) {
            char data[64];
            snprintf(data, sizeof(data), "\"paired\",\"addr\":\"%s\"", addr);
            return create_json_response(true, data, NULL, response, len);
        } else {
            return create_json_response(true, "\"unpaired\"", NULL, response, len);
        }
    }
}

/* Per-request session ID buffer for LIST commands (no persistent cache) */
static char list_ids[200][16];

static int parse_pagination(const char *query, int *page, int *per_page, int max_pp)
{
    *page = 1;
    *per_page = 10;

    if (!query) return 0;

    char buf[32];
    strncpy(buf, query, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';

    char *token = strtok(buf, "&");
    if (token) {
        *page = atoi(token);
        if (*page < 1) *page = 1;
    }
    token = strtok(NULL, "&");
    if (token) {
        *per_page = atoi(token);
        if (*per_page < 1) *per_page = 10;
        if (*per_page > max_pp) *per_page = max_pp;
    }
    return 0;
}

/* FORMAT Command Handler - Format SD card (delete all sessions) */
static int cmd_format_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    if (storage_ensure_mounted() != 0) {
        return create_json_response(false, "SD card not mounted", NULL, response, len);
    }

    if (audio_is_recording()) {
        return create_json_response(false, "Cannot format while recording", NULL, response, len);
    }

    int err = storage_format_card();
    if (err) {
        return create_json_response(false, "Format failed", NULL, response, len);
    }

    return create_json_response(true, NULL, NULL, response, len);
}

/* START Command Handler - Start recording */
static int cmd_start_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    struct clip_context *c = clip_get_context();
    enum recording_mode rec_mode;

    /* Parse mode parameter if provided */
    if (ctx->args && strlen(ctx->args) > 0) {
        char mode_str[32];
        strncpy(mode_str, ctx->args, sizeof(mode_str) - 1);
        mode_str[sizeof(mode_str) - 1] = '\0';

        for (char *p = mode_str; *p; p++) {
            if (*p >= 'A' && *p <= 'Z') {
                *p = *p - 'A' + 'a';
            }
        }

        if (strcmp(mode_str, "normal") == 0 || strcmp(mode_str, "stereo") == 0) {
            rec_mode = MODE_NORMAL;
        } else if (strcmp(mode_str, "enhanced") == 0 || strcmp(mode_str, "merge") == 0) {
            rec_mode = MODE_ENHANCED;
        } else {
            return create_json_response(false, "Invalid mode (use normal/stereo or enhanced/merge)", NULL, response, len);
        }

        /* Apply mode for this session */
        c->config.mode = rec_mode;
    } else {
        rec_mode = c->config.mode;
    }

    struct clip_event_result_info info;
    int ret = clip_post_event_sync(CLIP_EVENT_START, &info);

    if (ret != 0 || info.result != CLIP_EVENT_OK) {
        if (info.result == CLIP_EVENT_INVALID) {
            if (clip_event_get_state() == CLIP_STATE_WIFI_SYNC) {
                return create_json_response(false, "WiFi active, cannot record",
                                           NULL, response, len);
            }
            if (usb_cdc_is_enabled()) {
                return create_json_response(false, "USB MSC active, disable USB first",
                                           NULL, response, len);
            }
            return create_json_response(false, "Already recording or invalid state",
                                       NULL, response, len);
        }
        if (info.result == CLIP_EVENT_BUSY) {
            return create_json_response(false, "Audio module busy",
                                       NULL, response, len);
        }
        return create_json_response(false, "Failed to start recording",
                                   NULL, response, len);
    }

    haptic_play_pattern(HAPTIC_SHORT);

    const char *session_id = audio_get_session_id();
    char data[64];
    if (session_id) {
        snprintf(data, sizeof(data), "{\"session\":\"%s\"}", session_id);
    } else {
        snprintf(data, sizeof(data), "{}");
    }

    return create_json_response(true, NULL, data, response, len);
}

/* STOP Command Handler - Stop recording */
static int cmd_stop_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    const char *session_id = audio_get_session_id();
    if (!session_id) {
        return create_json_response(false, "No active session", NULL, response, len);
    }

    struct clip_event_result_info info;
    int ret = clip_post_event_sync(CLIP_EVENT_STOP, &info);

    if (ret != 0 || info.result != CLIP_EVENT_OK) {
        /* Fallback: if audio is actually recording but state machine is
         * out of sync, stop audio directly */
        if (audio_is_recording() && info.result == CLIP_EVENT_INVALID) {
            LOG_WRN("State/audio mismatch, forcing audio stop");
            audio_stop_recording();
        } else {
            return create_json_response(false, "Not recording", NULL, response, len);
        }
    }

    struct audio_stats audio_stats;
    if (audio_get_stats(&audio_stats) != 0) {
        char data[128];
        snprintf(data, sizeof(data), "{\"session\":\"%s\"}", session_id);
        haptic_play_pattern(HAPTIC_SHORT);
        return create_json_response(true, NULL, data, response, len);
    }

    char data[256];
    snprintf(data, sizeof(data),
            "{\"session\":\"%s\","
            "\"duration\":%u,"
            "\"frames\":%u,"
            "\"file_count\":1,"
            "\"total_size\":%u}",
            session_id,
            (uint32_t)(audio_stats.recording_time_ms / 1000),
            audio_stats.frames_encoded,
            audio_stats.total_bytes);

    haptic_play_pattern(HAPTIC_SHORT);

    return create_json_response(true, NULL, data, response, len);
}

/* PAUSE Command Handler - Pause recording */
static int cmd_pause_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    struct clip_event_result_info info;
    int ret = clip_post_event_sync(CLIP_EVENT_PAUSE, &info);

    if (ret != 0 || info.result != CLIP_EVENT_OK) {
        if (info.result == CLIP_EVENT_INVALID) {
            return create_json_response(false, "Not recording", NULL, response, len);
        }
        return create_json_response(false, "Failed to pause recording",
                                   NULL, response, len);
    }

    return create_json_response(true, NULL, "{\"paused\":true}", response, len);
}

/* RESUME Command Handler - Resume recording */
static int cmd_resume_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    struct clip_event_result_info info;
    int ret = clip_post_event_sync(CLIP_EVENT_RESUME, &info);

    if (ret != 0 || info.result != CLIP_EVENT_OK) {
        if (info.result == CLIP_EVENT_INVALID) {
            return create_json_response(false, "Not paused", NULL, response, len);
        }
        return create_json_response(false, "Failed to resume recording",
                                   NULL, response, len);
    }

    return create_json_response(true, NULL, "{\"resumed\":true}", response, len);
}

/* MARK Command Handler - Add bookmark */
static int cmd_mark_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    const char *session_id = audio_get_session_id();
    if (!session_id) {
        return create_json_response(false, "No active session", NULL, response, len);
    }

    struct audio_stats audio_stats;
    if (audio_get_stats(&audio_stats) != 0) {
        return create_json_response(false, "Failed to get recording stats",
                                   NULL, response, len);
    }

    uint32_t recording_sec = audio_stats.recording_time_ms / 1000;

    /* Post the MARK event — the event handler adds the bookmark (via
     * audio_add_bookmark) AND vibrates + updates the display. Doing the add
     * only in the event handler (not here too) avoids a double bookmark on
     * AT+MARK (this handler used to call storage_add_bookmark directly, which
     * conflicted with the event handler's own add). */
    clip_post_event(CLIP_EVENT_MARK);

    char data[64];
    snprintf(data, sizeof(data), "{\"offset\":%u}", recording_sec);

    return create_json_response(true, NULL, data, response, len);
}

/* LIST Command Handler - List sessions or chunks (matches clip protocol) */

static int cmd_list_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    /*
     * AT+LIST command formats:
     * 1. AT+LIST or AT+LIST?page&per_page - List sessions with pagination
     * 2. AT+LIST=session_id - Session details
     * 3. AT+LIST=session_id?page&per_page - Paginated file list
     */

    LOG_DBG("AT+LIST: args='%s'", ctx->args ? ctx->args : "(null)");

    if (storage_ensure_mounted() != 0) {
        LOG_WRN("SD card not mounted for AT+LIST");
        return create_json_response(false, "SD card not mounted", NULL, response, len);
    }

    /* Parse arguments */
    if (ctx->args && strlen(ctx->args) > 0) {
        /* AT+LIST?page&per_page - session list with pagination */
        if (ctx->args[0] == '?') {
            int page, per_page;
            parse_pagination(ctx->args + 1, &page, &per_page, 50);

            int total_count = storage_list_session_ids(list_ids, 200);
            if (total_count < 0) {
                return create_json_response(false, "Failed to list sessions", NULL, response, len);
            }

            int offset = (page - 1) * per_page;

            if (offset >= total_count) {
                int n = snprintf(response, len,
                    "{\"ok\":true,\"data\":{\"total\":%d,\"page\":%d,\"per_page\":%d,\"sessions\":[]}}\n",
                    total_count, page, per_page);
                return (n < 0 || n >= len) ? AT_ERR_NOMEM : n;
            }

            int end = offset + per_page;
            if (end > total_count) end = total_count;

            char *p = response;
            size_t rem = len;
            int written = 0;

            int n = snprintf(p, rem,
                "{\"ok\":true,\"data\":{\"total\":%d,\"page\":%d,\"per_page\":%d,\"sessions\":[",
                total_count, page, per_page);
            if (n < 0 || n >= rem) return AT_ERR_NOMEM;
            p += n; rem -= n; written += n;

            for (int i = offset; i < end && rem > 100; i++) {
                struct storage_session_info info;
                if (storage_get_session_info(list_ids[i], &info) != 0) continue;

                /* Auto-delete empty sessions */
                if (info.file_count == 0 && info.total_bytes == 0) {
                    storage_delete_session(list_ids[i]);
                    continue;
                }

                int bm = storage_count_bookmarks(list_ids[i]);
                if (bm < 0) bm = 0;

                if (i > offset) {
                    n = snprintf(p, rem, ",");
                    if (n < 0 || n >= rem) return AT_ERR_NOMEM;
                    p += n; rem -= n; written += n;
                }

                n = snprintf(p, rem,
                    "{\"id\":\"%s\",\"files\":%u,\"size\":%u,\"bookmarks\":%d}",
                    list_ids[i], info.file_count,
                    (unsigned int)info.total_bytes, bm);
                if (n < 0 || n >= rem) return AT_ERR_NOMEM;
                p += n; rem -= n; written += n;
            }

            n = snprintf(p, rem, "]}}\n");
            if (n < 0 || n >= rem) return AT_ERR_NOMEM;
            written += n;
            return written;
        }

        /* Parse session_id and optional pagination */
        char args_copy[64];
        strncpy(args_copy, ctx->args, sizeof(args_copy) - 1);
        args_copy[sizeof(args_copy) - 1] = '\0';

        char *query = strchr(args_copy, '?');
        char *session_id = args_copy;

        size_t sid_len = query ? (size_t)(query - session_id) : strlen(session_id);
        if (sid_len != 14) {
            return create_json_response(false, "Invalid session ID", NULL, response, len);
        }

        /* Null-terminate session_id before validation */
        if (query) {
            *query = '\0';
        }

        if (!is_valid_session_id(session_id)) {
            return create_json_response(false, "Invalid session ID", NULL, response, len);
        }

        if (query) {
            /* AT+LIST=id?page&per_page - file list with pagination */
            query++;

            int page, per_page;
            parse_pagination(query, &page, &per_page, 20);

            struct storage_session_info info;
            int err = storage_get_session_info(session_id, &info);
            if (err != 0) {
                return create_json_response(false, "Session not found", NULL, response, len);
            }

            if (info.file_count == 0) {
                return create_json_response(true, NULL,
                    "{\"files\":0,\"size\":0,\"synced\":0,\"bookmarks\":0,"
                    "\"channels\":0,\"sample_rate\":0,\"mode\":\"\"}",
                    response, len);
            }

            uint32_t chunks[20];
            int skip = (page - 1) * per_page;
            int file_count = storage_list_chunks(session_id, chunks, per_page, skip);
            if (file_count < 0) {
                return create_json_response(false, "Session not found", NULL, response, len);
            }

            char *p = response;
            size_t rem = len;
            int written = 0;

            int n = snprintf(p, rem,
                "{\"ok\":true,\"data\":{\"total\":%d,\"page\":%d,\"per_page\":%d,\"files\":[",
                info.file_count, page, per_page);
            if (n < 0 || n >= rem) return AT_ERR_NOMEM;
            p += n; rem -= n; written += n;

            for (int i = 0; i < file_count && rem > 50; i++) {
                if (i > 0) {
                    n = snprintf(p, rem, ",");
                    if (n < 0 || n >= rem) return AT_ERR_NOMEM;
                    p += n; rem -= n; written += n;
                }
                n = snprintf(p, rem, "\"%04u.opus\"", (unsigned int)chunks[i]);
                if (n < 0 || n >= rem) return AT_ERR_NOMEM;
                p += n; rem -= n; written += n;
            }

            n = snprintf(p, rem, "]}}\n");
            if (n < 0 || n >= rem) return AT_ERR_NOMEM;
            written += n;
            return written;
        }

        /* AT+LIST=id - session details */
        struct storage_session_info info;
        int err = storage_get_session_info(session_id, &info);
        if (err != 0) {
            return create_json_response(false, "Session not found", NULL, response, len);
        }

        int bm = storage_count_bookmarks(session_id);
        if (bm < 0) bm = 0;

        char data[256];
        int n = snprintf(data, sizeof(data),
            "{\"files\":%u,\"size\":%u,\"synced\":%u,\"bookmarks\":%d,\"channels\":%u,\"sample_rate\":%u,\"mode\":\"%s\"}",
            info.file_count,
            (unsigned int)info.total_bytes,
            info.synced_files,
            bm,
            info.channels,
            info.sample_rate_khz * 1000,
            info.mode);
        if (n < 0 || n >= (int)sizeof(data)) {
            return create_json_response(false, "Response too large", NULL, response, len);
        }

        return create_json_response(true, NULL, data, response, len);
    }

    /* No arguments - list first page (default: page=1, per_page=10) */
    int total_count = storage_list_session_ids(list_ids, 200);
    if (total_count < 0) {
        return create_json_response(false, "Failed to list sessions", NULL, response, len);
    }

    int per_page = 10;
    int result_count = total_count < per_page ? total_count : per_page;

    char *p = response;
    size_t rem = len;
    int written = 0;

    int n = snprintf(p, rem,
        "{\"ok\":true,\"data\":{\"total\":%d,\"page\":1,\"per_page\":%d,\"sessions\":[",
        total_count, per_page);
    if (n < 0 || n >= rem) return AT_ERR_NOMEM;
    p += n; rem -= n; written += n;

    bool first = true;
    for (int i = 0; i < result_count && rem > 100; i++) {
        struct storage_session_info info;
        if (storage_get_session_info(list_ids[i], &info) != 0) continue;

        /* Skip empty sessions (deleted or no files) */
        if (info.file_count == 0 && info.total_bytes == 0) {
            continue;
        }

        int bm = storage_count_bookmarks(list_ids[i]);
        if (bm < 0) bm = 0;

        if (!first) {
            n = snprintf(p, rem, ",");
            if (n < 0 || n >= rem) return AT_ERR_NOMEM;
            p += n; rem -= n; written += n;
        }
        first = false;

        n = snprintf(p, rem,
            "{\"id\":\"%s\",\"files\":%u,\"size\":%u,\"bookmarks\":%d}",
            list_ids[i], info.file_count,
            (unsigned int)info.total_bytes, bm);
        if (n < 0 || n >= rem) return AT_ERR_NOMEM;
        p += n; rem -= n; written += n;
    }

    n = snprintf(p, rem, "]}}\n");
    if (n < 0 || n >= rem) return AT_ERR_NOMEM;
    written += n;
    return written;
}

/* MARKS Command Handler - List bookmarks */
static int cmd_marks_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    /* Format: AT+MARKS=<session_id>?page&per_page */
    /* Without query: return summary (total count) */
    /* With query: return paginated bookmark list */

    if (!ctx->args || strlen(ctx->args) == 0) {
        return create_json_response(false, "Missing session_id", NULL, response, len);
    }

    /* Check if SD card is mounted */
    if (storage_ensure_mounted() != 0) {
        return create_json_response(false, "SD card not mounted", NULL, response, len);
    }

    char args_copy[128];
    strncpy(args_copy, ctx->args, sizeof(args_copy) - 1);
    args_copy[sizeof(args_copy) - 1] = '\0';

    /* Split by '?' to get session_id and query */
    char *question_mark = strchr(args_copy, '?');
    char *session_id = args_copy;
    char *query = NULL;
    int page = 1;
    int per_page = 20;

    if (question_mark) {
        *question_mark = '\0';
        query = question_mark + 1;

        /* Validate session_id */
        if (!is_valid_session_id(session_id)) {
            return create_json_response(false, "Invalid session ID", NULL, response, len);
        }

        /* Parse pagination: page&per_page */
        char *token = strtok(query, "&");
        if (token) {
            page = atoi(token);
            if (page < 1) page = 1;
        }
        token = strtok(NULL, "&");
        if (token) {
            per_page = atoi(token);
            if (per_page < 1) per_page = 20;
            if (per_page > 100) per_page = 100;
        }
    }

    /* Validate session_id (covers both query and no-query paths) */
    if (!is_valid_session_id(session_id)) {
        return create_json_response(false, "Invalid session ID", NULL, response, len);
    }

    /* If no query, return summary */
    if (!query) {
        int count = storage_count_bookmarks(session_id);
        if (count < 0) {
            return create_json_response(false, "Failed to get bookmark count", NULL, response, len);
        }

        char data[64];
        snprintf(data, sizeof(data), "{\"session\":\"%s\",\"total\":%d}", session_id, count);
        return create_json_response(true, NULL, data, response, len);
    }

    /* Get bookmarks with pagination */
    struct storage_bookmark bookmarks[per_page];
    int count = storage_get_bookmarks(session_id, page, per_page, bookmarks, per_page);
    if (count < 0) {
        return create_json_response(false, "Failed to get bookmarks", NULL, response, len);
    }

    /* Get total count */
    int total = storage_count_bookmarks(session_id);
    if (total < 0) {
        total = count;  /* Fallback */
    }

    /* Build JSON response - wrap in data field to match clip format */
    char *json_data = response;
    size_t remaining = len;
    int total_written = 0;

    int n = snprintf(json_data, remaining,
        "{\"ok\":true,\"data\":{\"total\":%d,\"page\":%d,\"per_page\":%d,\"bookmarks\":[",
        total, page, per_page);
    if (n < 0 || n >= (int)remaining) {
        return AT_ERR_NOMEM;
    }
    json_data += n;
    remaining -= n;
    total_written += n;

    for (int i = 0; i < count; i++) {
        if (i > 0) {
            n = snprintf(json_data, remaining, ",");
            if (n < 0 || n >= (int)remaining) {
                return AT_ERR_NOMEM;
            }
            json_data += n;
            remaining -= n;
            total_written += n;
        }

        n = snprintf(json_data, remaining, "{\"offset\":%u}", bookmarks[i].offset_sec);
        if (n < 0 || n >= (int)remaining) {
            return AT_ERR_NOMEM;
        }
        json_data += n;
        remaining -= n;
        total_written += n;
    }

    n = snprintf(json_data, remaining, "]}}\n");
    if (n < 0 || n >= (int)remaining) {
        return AT_ERR_NOMEM;
    }
    total_written += n;

    return total_written;
}

/* DOWNLOAD Command Handler - Start file transfer */
static int cmd_download_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    /*
     * AT+DOWNLOAD command formats:
     * 1. AT+DOWNLOAD=<session_id> - Transfer entire session
     * 2. AT+DOWNLOAD=<session_id>:<filename> - Transfer single file
     *
     * Response: {"ok":true,"data":{"state":"transmitting","session":"...","file":"...","total":X}}
     */

    struct transport *tp = NULL;

    if (!ctx->args || strlen(ctx->args) == 0) {
        return create_json_response(false, "Missing session_id", NULL, response, len);
    }

    /* Check if SD card is mounted */
    if (storage_ensure_mounted() != 0) {
        return create_json_response(false, "SD card not mounted", NULL, response, len);
    }

    /* Check if file data notify is enabled (required for BLE transfer only) */
    if (ctx->transport_type == TRANSPORT_TYPE_BLE && !ble_is_file_data_notify_enabled()) {
        return create_json_response(false, "File data notification not enabled", NULL, response, len);
    }

    /* Get transport based on where the command came from */
    tp = transport_get(ctx->transport_type);
    if (!tp) {
        return create_json_response(false, "Transport not available", NULL, response, len);
    }

    /* Parse args: session_id or session_id:filename */
    char args_copy[128];
    strncpy(args_copy, ctx->args, sizeof(args_copy) - 1);
    args_copy[sizeof(args_copy) - 1] = '\0';

    char *colon = strchr(args_copy, ':');
    char *session_id = args_copy;
    char *filename = NULL;

    if (colon) {
        *colon = '\0';
        filename = colon + 1;
    }

    /* Validate session_id: must be exactly 14 digits */
    if (!is_valid_session_id(session_id)) {
        return create_json_response(false, "Invalid session ID", NULL, response, len);
    }

    /* Start transfer using the transport that received the command */
    int err;
    if (filename) {
        /* Resume from specific file — transfer all remaining files */
        err = transfer_resume_from(session_id, filename, tp);
    } else {
        /* Transfer entire session */
        err = transfer_start(session_id, NULL, tp);
    }
    if (err) {
        const char *msg = "Failed to start transfer";
        if (err == -ENOENT) msg = "Session or file not found";
        if (err == -EBUSY) msg = "Transfer already in progress";
        if (err == -ENOTCONN) msg = "No transport available";
        return create_json_response(false, msg, NULL, response, len);
    }

    /* Get transfer info for response */
    struct transfer_info info;
    transfer_get_progress(&info);

    char data[256];
    if (filename) {
        snprintf(data, sizeof(data),
                 "{\"state\":\"transmitting\",\"session\":\"%s\",\"file\":\"%s\",\"total\":%u,\"bytes\":%u}",
                 info.session_id, info.current_file, (unsigned int)info.total_files,
                 (unsigned int)info.total_bytes);
    } else {
        snprintf(data, sizeof(data),
                 "{\"state\":\"transmitting\",\"session\":\"%s\",\"total\":%u,\"bytes\":%u}",
                 info.session_id, (unsigned int)info.total_files,
                 (unsigned int)info.total_bytes);
    }

    return create_json_response(true, NULL, data, response, len);
}


/* CANCEL Command Handler - Cancel transfer */
static int cmd_cancel_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    /*
     * AT+CANCEL - Cancel ongoing transfer
     *
     * Response: {"ok":true,"data":{"canceled":true}}
     */

    if (!transfer_is_active()) {
        return create_json_response(false, "No active transfer", NULL, response, len);
    }

    int err = transfer_cancel();
    if (err) {
        return create_json_response(false, "Failed to cancel transfer", NULL, response, len);
    }

    return create_json_response(true, NULL, "{\"canceled\":true}", response, len);
}

/* DELETE Command Handler - Delete a session */
static int cmd_delete_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    /*
     * AT+DELETE=<session_id> - Delete a recording session
     *
     * Response: {"ok":true,"data":{"deleted":true}}
     * Error: {"ok":false,"error":"..."}
     */

    if (!ctx->args || strlen(ctx->args) == 0) {
        return create_json_response(false, "Missing session_id", NULL, response, len);
    }

    /* Check if SD card is mounted */
    if (storage_ensure_mounted() != 0) {
        return create_json_response(false, "SD card not mounted", NULL, response, len);
    }

    /* Parse session_id */
    char session_id[32];
    strncpy(session_id, ctx->args, sizeof(session_id) - 1);
    session_id[sizeof(session_id) - 1] = '\0';

    /* Trim whitespace */
    char *end = session_id + strlen(session_id) - 1;
    while (end > session_id && (*end == ' ' || *end == '\t' || *end == '\r' || *end == '\n')) {
        *end-- = '\0';
    }

    /* Validate session_id: must be exactly 14 digits */
    if (!is_valid_session_id(session_id)) {
        return create_json_response(false, "Invalid session ID", NULL, response, len);
    }

    int err = storage_delete_session(session_id);
    if (err == -EBUSY) {
        return create_json_response(false, "Cannot delete current recording session", NULL, response, len);
    } else if (err == -ENOENT) {
        return create_json_response(false, "Session not found", NULL, response, len);
    } else if (err != 0) {
        return create_json_response(false, "Failed to delete session", NULL, response, len);
    }

    return create_json_response(true, NULL, "{\"deleted\":true}", response, len);
}

/* NAME Command Handler - Set/Get device name */
static int cmd_name_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    if (ctx->type == AT_CMD_TYPE_SET || ctx->type == AT_CMD_TYPE_EXEC) {
        if (!ctx->args || strlen(ctx->args) == 0) {
            return create_json_response(false, "Missing name", NULL, response, len);
        }

        if (strncasecmp(ctx->args, "CLEAR", 5) == 0) {
            config_set_device_name("");
            return create_json_response(true, "Name cleared", NULL, response, len);
        }

        /* Strip surrounding quotes if present (AT+NAME="value" → value) */
        char name_buf[257];
        const char *src = ctx->args;
        size_t src_len = strlen(src);
        if (src_len >= 2 && src[0] == '"' && src[src_len - 1] == '"') {
            src++;
            src_len -= 2;
        }

        if (src_len > 256) {
            return create_json_response(false, "Name too long (max 256 bytes)", NULL, response, len);
        }

        memcpy(name_buf, src, src_len);
        name_buf[src_len] = '\0';

        bool has_printable = false;
        for (size_t i = 0; i < src_len; i++) {
            if ((unsigned char)name_buf[i] < 0x20) {
                return create_json_response(false, "Invalid characters", NULL, response, len);
            }
            if ((unsigned char)name_buf[i] >= 0x20) {
                has_printable = true;
            }
        }

        if (!has_printable) {
            return create_json_response(false, "Name cannot be empty", NULL, response, len);
        }

        int err = config_set_device_name(name_buf);
        if (err) {
            return create_json_response(false, "Save failed", NULL, response, len);
        }

        char data[300];
        snprintf(data, sizeof(data), "{\"name\":\"%s\"}", name_buf);
        return create_json_response(true, NULL, data, response, len);
    }

    const char *name = config_get_device_name();
    char data[300];
    snprintf(data, sizeof(data), "{\"name\":\"%s\"}", name);
    return create_json_response(true, NULL, data, response, len);
}

static int cmd_wifi_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    /*
     * AT+WIFI=on  - Start WiFi AP
     * AT+WIFI=off - Stop WiFi AP
     * AT+WIFI?    - Query WiFi AP status
     *
     * Response (on success):
     * {"ok":true,"data":{"ssid":"ClipAP_xxxx","password":"12345678","ip":"192.168.4.1","port":8080}}
     */

    if (ctx->type == AT_CMD_TYPE_SET || ctx->type == AT_CMD_TYPE_EXEC) {
        if (!ctx->args || strlen(ctx->args) == 0) {
            return create_json_response(false, "Missing argument (on/off)", NULL, response, len);
        }

        char arg[16];
        strncpy(arg, ctx->args, sizeof(arg) - 1);
        arg[sizeof(arg) - 1] = '\0';
        for (char *p = arg; *p; p++) {
            if (*p >= 'A' && *p <= 'Z') {
                *p = *p - 'A' + 'a';
            }
        }

        if (strcmp(arg, "on") == 0 || strcmp(arg, "1") == 0) {
            struct clip_event_result_info info;
            int ret = clip_post_event_sync(CLIP_EVENT_WIFI_ON, &info);

            if (ret != 0 || info.result != CLIP_EVENT_OK) {
                if (info.result == CLIP_EVENT_INVALID) {
                    return create_json_response(false, "Cannot start WiFi in current state",
                                               NULL, response, len);
                }
                return create_json_response(false, "Failed to start WiFi AP",
                                           NULL, response, len);
            }

            char data[256];
            snprintf(data, sizeof(data),
                     "{\"ssid\":\"%s\",\"password\":\"%s\",\"ip\":\"%s\",\"port\":%d}",
                     wifi_get_ssid(), wifi_get_password(), wifi_get_ip_address(), WIFI_AP_UDP_PORT);
            return create_json_response(true, NULL, data, response, len);

        } else if (strcmp(arg, "off") == 0 || strcmp(arg, "0") == 0) {
            struct clip_event_result_info info;
            int ret = clip_post_event_sync(CLIP_EVENT_WIFI_OFF, &info);

            if (ret != 0 || info.result != CLIP_EVENT_OK) {
                return create_json_response(false, "Failed to stop WiFi AP",
                                           NULL, response, len);
            }

            return create_json_response(true, NULL, "{\"wifi\":\"off\"}", response, len);

        } else {
            return create_json_response(false, "Invalid argument (use on/off)", NULL, response, len);
        }
    } else {
        /* Query status */
        char data[256];
        if (wifi_ap_is_running()) {
            snprintf(data, sizeof(data),
                     "{\"running\":true,\"ssid\":\"%s\",\"password\":\"%s\",\"ip\":\"%s\",\"port\":%d,\"connected\":%s}",
                     wifi_get_ssid(), wifi_get_password(), wifi_get_ip_address(), WIFI_AP_UDP_PORT,
                     wifi_is_sta_connected() ? "true" : "false");
        } else {
            snprintf(data, sizeof(data), "{\"running\":false}");
        }
        return create_json_response(true, NULL, data, response, len);
    }
}

static int cmd_wificfg_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    if (ctx->type == AT_CMD_TYPE_SET || ctx->type == AT_CMD_TYPE_EXEC) {
        if (!ctx->args || strlen(ctx->args) == 0) {
            return create_json_response(false, "Missing argument (format: channel:CC)", NULL, response, len);
        }

        /* Parse channel:CC (e.g., "36:US" or "149:CN") */
        char args[32];
        strncpy(args, ctx->args, sizeof(args) - 1);
        args[sizeof(args) - 1] = '\0';

        char *colon = strchr(args, ':');
        if (!colon || colon == args || strlen(colon + 1) != 2) {
            return create_json_response(false, "Invalid format (use: channel:CC, e.g. 36:US)",
                                       NULL, response, len);
        }

        *colon = '\0';
        int channel = atoi(args);
        char *reg_domain = colon + 1;

        /* Validate channel: 1-13 (2.4GHz) or 36-165 (5GHz) */
        if (!((channel >= 1 && channel <= 13) || (channel >= 36 && channel <= 165))) {
            return create_json_response(false, "Channel must be 1-13 (2.4GHz) or 36-165 (5GHz)",
                                       NULL, response, len);
        }

        /* Validate reg_domain (2 uppercase letters) */
        for (int i = 0; i < 2; i++) {
            if (reg_domain[i] < 'A' || reg_domain[i] > 'Z') {
                if (reg_domain[i] >= 'a' && reg_domain[i] <= 'z') {
                    reg_domain[i] = reg_domain[i] - 'a' + 'A';
                } else {
                    return create_json_response(false, "Reg domain must be 2-letter country code",
                                               NULL, response, len);
                }
            }
        }

        config_set_wifi_channel((uint8_t)channel);
        config_set_wifi_reg_domain(reg_domain);

        char data[64];
        snprintf(data, sizeof(data), "{\"channel\":%d,\"reg_domain\":\"%s\"}", channel, reg_domain);
        return create_json_response(true, "Saved (apply on next WiFi start)", data, response, len);
    } else {
        /* Query */
        char data[64];
        snprintf(data, sizeof(data), "{\"channel\":%u,\"reg_domain\":\"%s\"}",
                 config_get_wifi_channel(), config_get_wifi_reg_domain());
        return create_json_response(true, NULL, data, response, len);
    }
}

static int cmd_usb_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    if (ctx->type == AT_CMD_TYPE_SET || ctx->type == AT_CMD_TYPE_EXEC) {
	if (!ctx->args || strlen(ctx->args) == 0) {
	    return create_json_response(false, "Missing argument (on/off)", NULL, response, len);
	}

	char arg[16];
	strncpy(arg, ctx->args, sizeof(arg) - 1);
	arg[sizeof(arg) - 1] = '\0';
	for (char *p = arg; *p; p++) {
	    if (*p >= 'A' && *p <= 'Z') {
		*p = *p - 'A' + 'a';
	    }
	}

	if (strcmp(arg, "on") == 0 || strcmp(arg, "1") == 0) {
	    int err = usb_cdc_enable();
	    if (err == -EBUSY) {
		const char *reason = "Busy";
		if (audio_is_recording()) {
		    reason = "Recording in progress, stop recording first";
		} else if (transfer_is_active()) {
		    reason = "Transfer in progress, cancel transfer first";
		}
		return create_json_response(false, reason, NULL, response, len);
	    } else if (err) {
		return create_json_response(false, "Failed to enable USB", NULL, response, len);
	    }
	    return create_json_response(true, NULL, "{\"status\":\"on\"}", response, len);
	} else if (strcmp(arg, "off") == 0 || strcmp(arg, "0") == 0) {
	    int err = usb_cdc_disable();
	    if (err) {
		return create_json_response(false, "Failed to disable USB", NULL, response, len);
	    }
	    return create_json_response(true, NULL, "{\"status\":\"off\"}", response, len);
	} else {
	    return create_json_response(false, "Invalid argument (use on/off)", NULL, response, len);
	}
    } else {
	return create_json_response(true, NULL,
				   usb_cdc_is_enabled() ? "{\"status\":\"on\"}" : "{\"status\":\"off\"}",
				   response, len);
    }
}

#ifdef CONFIG_CLIP_THROUGHPUT_TEST
/* BLETHRU - BLE notify throughput test (AT+BLETHRU=<dur_sec>) */
static int cmd_blethru_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    if (ctx->type != AT_CMD_TYPE_SET && ctx->type != AT_CMD_TYPE_EXEC) {
        return create_json_response(false, "Use AT+BLETHRU=<dur_sec>", NULL, response, len);
    }
    if (!ble_is_connected() || !ble_is_throughput_subscribed()) {
        return create_json_response(false,
            "Subscribe to the throughput characteristic first", NULL, response, len);
    }
    uint32_t dur = 0;
    if (ctx->args && strlen(ctx->args) > 0) {
        dur = (uint32_t)strtoul(ctx->args, NULL, 10);
    }
    int ret = throughput_ble_start(dur);
    if (ret) {
        return create_json_response(false, "Test busy", NULL, response, len);
    }
    return create_json_response(true, "BLE throughput started (result via event)", NULL, response, len);
}

/* WIFITHRU - WiFi UDP TX throughput (AT+WIFITHRU=<ip>[,<port>][,<dur_sec>]) */
static int cmd_wifithru_handler(struct at_cmd_ctx *ctx, char *response, size_t len)
{
    if (ctx->type != AT_CMD_TYPE_SET && ctx->type != AT_CMD_TYPE_EXEC) {
        return create_json_response(false,
            "Use AT+WIFITHRU=<ip>[,<port>][,<dur_sec>]", NULL, response, len);
    }
    if (!ctx->args || strlen(ctx->args) == 0) {
        return create_json_response(false, "Missing argument (ip)", NULL, response, len);
    }

    char args[64];
    char ip[32] = {0};
    uint32_t port = 0, dur = 0;

    strncpy(args, ctx->args, sizeof(args) - 1);
    args[sizeof(args) - 1] = '\0';

    char *tok = strtok(args, ",");
    if (tok) { strncpy(ip, tok, sizeof(ip) - 1); }
    tok = strtok(NULL, ",");
    if (tok) { port = (uint32_t)strtoul(tok, NULL, 10); }
    tok = strtok(NULL, ",");
    if (tok) { dur = (uint32_t)strtoul(tok, NULL, 10); }

    if (strlen(ip) == 0) {
        return create_json_response(false, "Invalid ip", NULL, response, len);
    }
    int ret = throughput_wifi_start(ip, (uint16_t)port, dur);
    if (ret) {
        return create_json_response(false, "Test busy or WiFi not ready", NULL, response, len);
    }
    return create_json_response(true, "WiFi throughput started (result via event)", NULL, response, len);
}
#endif

/* Register all AT commands */
int at_commands_register(void)
{
    int err;

    k_work_init_delayable(&reboot_work, reboot_work_handler);

    /* GSTAT - Get device status */
    static const struct at_command gstat_cmd = {
        .name = "GSTAT",
        .flags = AT_CMD_EXEC,
        .handler = cmd_gstat_handler,
    };
    err = at_server_register_cmd(&gstat_cmd);
    if (err) return err;

    /* BATT - Get battery status (%, charging, voltage mV, temp C) */
    static const struct at_command batt_cmd = {
        .name = "BATT",
        .flags = AT_CMD_QUERY | AT_CMD_EXEC,
        .handler = cmd_batt_handler,
    };
    err = at_server_register_cmd(&batt_cmd);
    if (err) return err;

    /* DEVICE - Get device name */
    static const struct at_command device_cmd = {
        .name = "DEVICE",
        .flags = AT_CMD_QUERY | AT_CMD_EXEC,
        .handler = cmd_device_handler,
    };
    err = at_server_register_cmd(&device_cmd);
    if (err) return err;

    /* VERSION - Get firmware version */
    static const struct at_command version_cmd = {
        .name = "VERSION",
        .flags = AT_CMD_EXEC,
        .handler = cmd_version_handler,
    };
    err = at_server_register_cmd(&version_cmd);
    if (err) return err;

    /* TIME - Get/Set time */
    static const struct at_command time_cmd = {
        .name = "TIME",
        .flags = AT_CMD_SET | AT_CMD_QUERY | AT_CMD_EXEC,
        .handler = cmd_time_handler,
    };
    err = at_server_register_cmd(&time_cmd);
    if (err) return err;

    /* MODE - Get/Set recording mode */
    static const struct at_command mode_cmd = {
        .name = "MODE",
        .flags = AT_CMD_SET | AT_CMD_QUERY | AT_CMD_EXEC,
        .handler = cmd_mode_handler,
    };
    err = at_server_register_cmd(&mode_cmd);
    if (err) return err;


    /* AUTODEL - Get/Set auto-delete policy */
    static const struct at_command autodel_cmd = {
        .name = "AUTODEL",
        .flags = AT_CMD_SET | AT_CMD_QUERY | AT_CMD_EXEC,
        .handler = cmd_autodel_handler,
    };
    err = at_server_register_cmd(&autodel_cmd);
    if (err) return err;

    /* BRIGHTNESS - Get/Set OLED brightness */
    static const struct at_command brightness_cmd = {
        .name = "BRIGHTNESS",
        .flags = AT_CMD_SET | AT_CMD_QUERY | AT_CMD_EXEC,
        .handler = cmd_brightness_handler,
    };
    err = at_server_register_cmd(&brightness_cmd);
    if (err) return err;

    /* POWEROFF - Shutdown the device */
    static const struct at_command poweroff_cmd = {
        .name = "POWEROFF",
        .flags = AT_CMD_EXEC,
        .handler = cmd_poweroff_handler,
    };
    err = at_server_register_cmd(&poweroff_cmd);
    if (err) return err;

    /* FACTORY - Factory reset (requires confirmation) */
    static const struct at_command factory_cmd = {
        .name = "FACTORY",
        .flags = AT_CMD_SET | AT_CMD_EXEC,
        .handler = cmd_factory_handler,
    };
    err = at_server_register_cmd(&factory_cmd);
    if (err) return err;

    /* PAIR - BLE pairing query/reset */
    static const struct at_command pair_cmd = {
        .name = "PAIR",
        .flags = AT_CMD_SET | AT_CMD_QUERY,
        .handler = cmd_pair_handler,
    };
    err = at_server_register_cmd(&pair_cmd);
    if (err) return err;

    /* REBOOT - Reboot the device */
    static const struct at_command reboot_cmd = {
        .name = "REBOOT",
        .flags = AT_CMD_EXEC,
        .handler = cmd_reboot_handler,
    };
    err = at_server_register_cmd(&reboot_cmd);
    if (err) return err;

    /* DFU - Reboot into MCUboot recovery mode */
    static const struct at_command dfu_cmd = {
        .name = "DFU",
        .flags = AT_CMD_EXEC,
        .handler = cmd_dfu_handler,
    };
    err = at_server_register_cmd(&dfu_cmd);
    if (err) return err;

    /* START - Start recording */
    static const struct at_command start_cmd = {
        .name = "START",
        .flags = AT_CMD_EXEC | AT_CMD_SET,
        .handler = cmd_start_handler,
    };
    err = at_server_register_cmd(&start_cmd);
    if (err) return err;

    /* STOP - Stop recording */
    static const struct at_command stop_cmd = {
        .name = "STOP",
        .flags = AT_CMD_EXEC,
        .handler = cmd_stop_handler,
    };
    err = at_server_register_cmd(&stop_cmd);
    if (err) return err;

    /* PAUSE - Pause recording */
    static const struct at_command pause_cmd = {
        .name = "PAUSE",
        .flags = AT_CMD_EXEC,
        .handler = cmd_pause_handler,
    };
    err = at_server_register_cmd(&pause_cmd);
    if (err) return err;

    /* RESUME - Resume recording */
    static const struct at_command resume_cmd = {
        .name = "RESUME",
        .flags = AT_CMD_EXEC,
        .handler = cmd_resume_handler,
    };
    err = at_server_register_cmd(&resume_cmd);
    if (err) return err;

    /* MARK - Add bookmark */
    static const struct at_command mark_cmd = {
        .name = "MARK",
        .flags = AT_CMD_EXEC,
        .handler = cmd_mark_handler,
    };
    err = at_server_register_cmd(&mark_cmd);
    if (err) return err;

    /* LIST - List sessions or chunks */
    static const struct at_command list_cmd = {
        .name = "LIST",
        .flags = AT_CMD_SET | AT_CMD_QUERY | AT_CMD_EXEC,
        .handler = cmd_list_handler,
    };
    err = at_server_register_cmd(&list_cmd);
    if (err) return err;

    /* MARKS - List bookmarks */
    static const struct at_command marks_cmd = {
        .name = "MARKS",
        .flags = AT_CMD_SET | AT_CMD_QUERY | AT_CMD_EXEC,
        .handler = cmd_marks_handler,
    };
    err = at_server_register_cmd(&marks_cmd);
    if (err) return err;

    /* DOWNLOAD - Start file transfer */
    static const struct at_command download_cmd = {
        .name = "DOWNLOAD",
        .flags = AT_CMD_SET | AT_CMD_EXEC,
        .handler = cmd_download_handler,
    };
    err = at_server_register_cmd(&download_cmd);
    if (err) return err;

    /* CANCEL - Cancel transfer */
    static const struct at_command cancel_cmd = {
        .name = "CANCEL",
        .flags = AT_CMD_EXEC,
        .handler = cmd_cancel_handler,
    };
    err = at_server_register_cmd(&cancel_cmd);
    if (err) return err;

    /* DELETE - Delete a session */
    static const struct at_command delete_cmd = {
        .name = "DELETE",
        .flags = AT_CMD_SET,
        .handler = cmd_delete_handler,
    };
    err = at_server_register_cmd(&delete_cmd);
    if (err) return err;
    /* FORMAT - Format SD card */
    static const struct at_command format_cmd = {
        .name = "FORMAT",
        .flags = AT_CMD_EXEC,
        .handler = cmd_format_handler,
    };
    err = at_server_register_cmd(&format_cmd);
    if (err) return err;

    /* WIFI - Control WiFi AP */
    static const struct at_command wifi_cmd = {
        .name = "WIFI",
        .flags = AT_CMD_SET | AT_CMD_QUERY | AT_CMD_EXEC,
        .handler = cmd_wifi_handler,
    };
    err = at_server_register_cmd(&wifi_cmd);
    if (err) return err;

    /* WIFICFG - WiFi AP channel/regulatory domain */
    static const struct at_command wificfg_cmd = {
        .name = "WIFICFG",
        .flags = AT_CMD_SET | AT_CMD_QUERY,
        .handler = cmd_wificfg_handler,
    };
    err = at_server_register_cmd(&wificfg_cmd);
    if (err) return err;

    /* NAME - Set/Get device name */
    static const struct at_command name_cmd = {
        .name = "NAME",
        .flags = AT_CMD_SET | AT_CMD_QUERY,
        .handler = cmd_name_handler,
    };
    err = at_server_register_cmd(&name_cmd);
    if (err) return err;

    /* USB - Control USB CDC+MSC */
    static const struct at_command usb_cmd = {
        .name = "USB",
        .flags = AT_CMD_SET | AT_CMD_QUERY | AT_CMD_EXEC,
        .handler = cmd_usb_handler,
    };
    err = at_server_register_cmd(&usb_cmd);
    if (err) return err;

    /* LOG - control FS (SD) log backend (AT+LOG=off|info|debug) */
    static const struct at_command log_cmd = {
        .name = "LOG",
        .flags = AT_CMD_SET | AT_CMD_QUERY | AT_CMD_EXEC,
        .handler = cmd_log_handler,
    };
    err = at_server_register_cmd(&log_cmd);
    if (err) return err;

#ifdef CONFIG_CLIP_THROUGHPUT_TEST
    /* BLETHRU - BLE notify throughput test */
    static const struct at_command blethru_cmd = {
        .name = "BLETHRU",
        .flags = AT_CMD_SET | AT_CMD_EXEC,
        .handler = cmd_blethru_handler,
    };
    err = at_server_register_cmd(&blethru_cmd);
    if (err) return err;

    /* WIFITHRU - WiFi UDP TX throughput test */
    static const struct at_command wifithru_cmd = {
        .name = "WIFITHRU",
        .flags = AT_CMD_SET | AT_CMD_EXEC,
        .handler = cmd_wifithru_handler,
    };
    err = at_server_register_cmd(&wifithru_cmd);
    if (err) return err;
#endif

    LOG_INF("AT commands registered");
    return 0;
}
