/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/sys/util.h>
#include <zephyr/sys/printk.h>
#include <zephyr/logging/log.h>
#include <app_version.h>
#include <time.h>
#include <string.h>
#include <strings.h>
#include <stdlib.h>
#include <ctype.h>
#include "at_cmd.h"
#include "clip.h"
#include "state_machine.h"
#include "json_helper.h"
#include "audio.h"
#include "storage.h"
#include "transfer.h"
#include "bookmarks.h"
#include "battery.h"
#include "config.h"
#include "ble_svc.h"
#include "display_ctrl.h"
#include "display.h"

LOG_MODULE_REGISTER(at_cmd, LOG_LEVEL_DBG);

/* Shared JSON response buffer to reduce stack usage
 * Size configured via CLIP_JSON_BUFFER_SIZE (default 1KB)
 */
static char json_buffer[CLIP_JSON_BUFFER_SIZE];

/* Static session buffer for AT+LIST pagination
 * Size configured via CLIP_AT_CMD_MAX_PER_PAGE (default 10)
 * Using static allocation to avoid heap fragmentation
 */
static struct storage_session_info session_buffer[CLIP_AT_CMD_MAX_PER_PAGE];

/* Helper function to trim whitespace */
static void trim_whitespace(char *str)
{
    char *start = str;
    char *end;

    while (isspace((unsigned char)*start)) {
        start++;
    }

    if (*start == 0) {
        *str = 0;
        return;
    }

    end = start + strlen(start) - 1;
    while (end > start && isspace((unsigned char)*end)) {
        end--;
    }

    memmove(str, start, end - start + 1);
    str[end - start + 1] = '\0';
}

/* Helper to extract integer from string */
static int extract_int(const char *str, int *value)
{
    char *end;
    long val = strtol(str, &end, 10);

    if (end == str || *end != '\0') {
        return -EINVAL;
    }

    *value = (int)val;
    return 0;
}

#ifdef CONFIG_SETTINGS
#include <zephyr/settings/settings.h>

/* Helper to save a single setting to NVS immediately */
static int save_setting_now(const char *name, const void *value, size_t size)
{
    int err = settings_save_one(name, value, size);
    if (err != 0) {
        LOG_WRN("Failed to save %s: %d", name, err);
    } else {
        LOG_DBG("Saved to NVS: %s", name);
    }
    return err;
}
#endif

int at_cmd_parse(const char *cmd_str, struct at_command *cmd)
{
    char buffer[256];
    char *token;
    char *value_start;

    if (!cmd_str || !cmd) {
        return -EINVAL;
    }

    /* Copy command to buffer */
    strncpy(buffer, cmd_str, sizeof(buffer) - 1);
    buffer[sizeof(buffer) - 1] = '\0';

    /* Trim whitespace */
    trim_whitespace(buffer);

    /* Check for AT prefix */
    if (strncmp(buffer, "AT", 2) != 0) {
        return -EINVAL;
    }

    /* Skip AT */
    token = buffer + 2;

    /* Skip whitespace after AT */
    while (*token == ' ') {
        token++;
    }

    /* Find + separator */
    if (*token != '+') {
        return -EINVAL;
    }

    token++; /* Skip + */

    /* Find command name (uppercase) */
    char name_start[32] = {0};
    int i = 0;
    while (*token && *token != '=' && *token != '?' && *token != ' ' &&
           i < (sizeof(name_start) - 1)) {
        name_start[i++] = toupper((unsigned char)*token++);
    }
    name_start[i] = '\0';

    strncpy(cmd->name, name_start, sizeof(cmd->name) - 1);
    cmd->name[sizeof(cmd->name) - 1] = '\0';

    /* Determine command type and extract value */
    value_start = token;

    if (*value_start == '?') {
        /* GET command */
        cmd->type = AT_CMD_GET;
        cmd->value = NULL;
    } else if (*value_start == '=') {
        value_start++; /* Skip = */

        if (*value_start == '?') {
            /* Some commands use =? which is still a GET */
            cmd->type = AT_CMD_GET;
            cmd->value = NULL;
        } else {
            /* SET command */
            cmd->type = AT_CMD_SET;
            trim_whitespace(value_start);

            if (strlen(value_start) > 0) {
                size_t val_len = strlen(value_start) + 1;
                cmd->value = k_malloc(val_len);
                if (!cmd->value) {
                    return -ENOMEM;
                }
                strcpy(cmd->value, value_start);
            } else {
                cmd->value = NULL;
            }
        }
    } else {
        /* EXEC command */
        cmd->type = AT_CMD_EXEC;
        cmd->value = NULL;
    }

    return 0;
}

void at_cmd_cleanup(struct at_command *cmd)
{
    if (cmd->value) {
        k_free(cmd->value);
        cmd->value = NULL;
    }
}

/* Command handlers */
static int cmd_gstat(const struct at_command *cmd, char **response)
{
    char buffer[512];
    struct storage_stats stats;
    struct audio_stats audio_stats;
    uint32_t free_space = 0;
    uint32_t recording_duration = 0;
    const char *session_id = NULL;

    /* Refresh battery reading before reporting */
    battery_request_update();

    /* Get storage statistics */
    if (storage_get_stats(&stats) == 0) {
        free_space = stats.free_space_mb;
    }

    /* Get recording duration and session ID if recording */
    if (audio_is_recording() && audio_get_stats(&audio_stats) == 0) {
        recording_duration = (uint32_t)(audio_stats.recording_time_ms / 1000);
        session_id = audio_get_session_id();
    }

    snprintf(buffer, sizeof(buffer),
             "{\"state\":\"%s\","
             "\"recording\":%s,"
             "\"session_id\":%s%s%s,"
             "\"duration\":%u,"
             "\"battery\":%u,"
             "\"charging\":%s,"
             "\"mode\":\"%s\","
             "\"bitrate\":%u,"
             "\"free_space\":%u}",
             state_to_string(state_get_current()),
             audio_is_recording() ? "true" : "false",
             session_id ? "\"" : "", session_id ? session_id : "", session_id ? "\"" : "\"\"",
             recording_duration,
             battery_get_level(),
             battery_is_charging() ? "true" : "false",
             g_config.mode == MODE_NORMAL ? "normal" : "enhanced",
             g_config.bitrate,
             free_space);

    return json_create_success(buffer, response);
}

static int cmd_version(const struct at_command *cmd, char **response)
{
    char version_str[32];

    snprintf(version_str, sizeof(version_str), "\"%s\"", APP_VERSION_STRING);
    return json_create_kv("firmware", version_str, response);
}

/* Combined TIME command handler for GET and SET */
static int cmd_time(const struct at_command *cmd, char **response)
{
    if (cmd->type == AT_CMD_SET) {
        /* Set time from Unix timestamp */
        char data[128];
        time_t unix_time;
        struct tm tm;

        if (!cmd->value) {
            return json_create_error("Missing time value", response);
        }

        /* Parse Unix timestamp */
        unix_time = (time_t)atoi(cmd->value);
        if (unix_time < 0) {
            return json_create_error("Invalid timestamp", response);
        }

        /* Convert Unix timestamp to broken-down time */
        gmtime_r(&unix_time, &tm);

        /* Validate year range */
        if (tm.tm_year + 1900 < 2020 || tm.tm_year + 1900 > 2099) {
            return json_create_error("Year out of range (2020-2099)", response);
        }

        /* Store synchronized time */
        g_synced_time.year = tm.tm_year + 1900;
        g_synced_time.month = tm.tm_mon + 1;
        g_synced_time.day = tm.tm_mday;
        g_synced_time.hour = tm.tm_hour;
        g_synced_time.min = tm.tm_min;
        g_synced_time.sec = tm.tm_sec;
        g_synced_time.base_uptime_ms = k_uptime_get();
        g_synced_time.valid = true;

        LOG_DBG("Time synced: %lld (base uptime: %lld ms)",
                (int64_t)unix_time, g_synced_time.base_uptime_ms);

        /* Save to NVS for persistence across reboots */
        int64_t unix_time_64 = (int64_t)unix_time;
        config_set_time(&unix_time_64);

        snprintf(data, sizeof(data), "\"%lld\"", (int64_t)unix_time);
        return json_create_kv("time", data, response);
    } else {
        /* Get time - return current synced time or error */
        if (g_synced_time.valid) {
            char time_buf[64];
            snprintf(time_buf, sizeof(time_buf),
                "\"%04d-%02d-%02dT%02d:%02d:%02dZ\"",
                g_synced_time.year, g_synced_time.month, g_synced_time.day,
                g_synced_time.hour, g_synced_time.min, g_synced_time.sec);
            return json_create_kv("time", time_buf, response);
        } else {
            return json_create_error("Time not set (use AT+TIME=<timestamp>)", response);
        }
    }
}

static int cmd_battery_set(const struct at_command *cmd, char **response)
{
    uint32_t level;
    char data[128];

    if (!cmd->value) {
        /* GET: trigger a fresh hardware read, then return current values */
        battery_request_update();
        snprintf(data, sizeof(data),
                 "{\"level\":%u,\"charging\":%s,\"voltage\":%u}",
                 battery_get_level(),
                 battery_is_charging() ? "true" : "false",
                 battery_get_voltage());
        return json_create_success(data, response);
    }

    level = atoi(cmd->value);

    if (level > 100) {
        return json_create_error("Invalid battery level (0-100)", response);
    }

    battery_set_level((uint8_t)level);

    snprintf(data, sizeof(data), "{\"level\":%u}", level);
    return json_create_success(data, response);
}

static int cmd_charging_set(const struct at_command *cmd, char **response)
{
    bool charging;
    char data[128];

    if (!cmd->value) {
        /* Get current charging status */
        snprintf(data, sizeof(data), "{\"charging\":%s}",
                battery_is_charging() ? "true" : "false");
        return json_create_success(data, response);
    }

    /* Parse value */
    if (strcasecmp(cmd->value, "on") == 0 || strcasecmp(cmd->value, "1") == 0) {
        charging = true;
    } else if (strcasecmp(cmd->value, "off") == 0 || strcasecmp(cmd->value, "0") == 0) {
        charging = false;
    } else {
        return json_create_error("Invalid value (use on/off or 0/1)", response);
    }

    battery_set_charging(charging);

    snprintf(data, sizeof(data), "{\"charging\":%s}", charging ? "true" : "false");
    return json_create_success(data, response);
}

static int cmd_autodel_set(const struct at_command *cmd, char **response)
{
    char data[128];

    if (!cmd->value) {
        /* Get current auto-delete policy */
        if (g_config.auto_delete_days < 0) {
            return json_create_kv("value", "\"off\"", response);
        } else {
            snprintf(data, sizeof(data), "{\"value\":%d}", g_config.auto_delete_days);
            return json_create_success(data, response);
        }
    }

    /* Parse value */
    if (strcasecmp(cmd->value, "off") == 0) {
        g_config.auto_delete_days = -1;
    } else {
        int days = atoi(cmd->value);
        if (days < 0 || days > 30) {
            return json_create_error("Invalid value (use off or 0-30)", response);
        }
        g_config.auto_delete_days = (int8_t)days;
    }

#ifdef CONFIG_SETTINGS
    save_setting_now("config/auto_delete_days", &g_config.auto_delete_days, sizeof(g_config.auto_delete_days));
#endif

    if (g_config.auto_delete_days < 0) {
        return json_create_kv("value", "\"off\"", response);
    } else {
        snprintf(data, sizeof(data), "{\"value\":%d}", g_config.auto_delete_days);
        return json_create_success(data, response);
    }
}

static int cmd_noise_set(const struct at_command *cmd, char **response)
{
    uint8_t level;
    char data[128];

    if (!cmd->value) {
        snprintf(data, sizeof(data), "{\"value\":%u}", g_config.noise_suppress);
        return json_create_success(data, response);
    }

    level = (uint8_t)atoi(cmd->value);

    if (level > 60) {
        return json_create_error("Invalid level (0-60 dB)", response);
    }

    g_config.noise_suppress = level;
#ifdef CONFIG_SETTINGS
    uint8_t noise_val = level;
    save_setting_now("config/noise_suppress", &noise_val, sizeof(noise_val));
#endif

    snprintf(data, sizeof(data), "{\"value\":%u}", level);
    return json_create_success(data, response);
}

static int cmd_agc_set(const struct at_command *cmd, char **response)
{
    char data[256];
    bool enable;
    uint8_t target = 0;

    if (!cmd->value) {
        snprintf(data, sizeof(data),
                "{\"enabled\":%s,\"target\":%u}",
                g_config.agc_enabled ? "true" : "false",
                g_config.agc_target);
        return json_create_success(data, response);
    }

    /* Parse format: on/off,target or just on/off */
    char *comma = strchr(cmd->value, ',');

    if (comma) {
        *comma = '\0';
        char *enable_str = cmd->value;
        char *target_str = comma + 1;

        /* Parse enable */
        if (strcasecmp(enable_str, "on") == 0 || strcasecmp(enable_str, "1") == 0) {
            enable = true;
        } else if (strcasecmp(enable_str, "off") == 0 || strcasecmp(enable_str, "0") == 0) {
            enable = false;
        } else {
            return json_create_error("Invalid enable value", response);
        }

        /* Parse target */
        target = (uint8_t)atoi(target_str);
        if (target > 30) {
            return json_create_error("Invalid target (0-30 dB)", response);
        }
    } else {
        /* Just enable/disable */
        if (strcasecmp(cmd->value, "on") == 0 || strcasecmp(cmd->value, "1") == 0) {
            enable = true;
            target = g_config.agc_target;
        } else if (strcasecmp(cmd->value, "off") == 0 || strcasecmp(cmd->value, "0") == 0) {
            enable = false;
        } else {
            return json_create_error("Invalid value (use on/off or 0/1)", response);
        }
    }

    g_config.agc_enabled = enable;
    g_config.agc_target = target;

#ifdef CONFIG_SETTINGS
    save_setting_now("config/agc_enabled", &enable, sizeof(enable));
    save_setting_now("config/agc_target", &target, sizeof(target));
#endif

    snprintf(data, sizeof(data),
            "{\"enabled\":%s,\"target\":%u}",
            enable ? "true" : "false",
            target);
    return json_create_success(data, response);
}

static int cmd_dereverb_set(const struct at_command *cmd, char **response)
{
    char data[256];
    bool enable;
    uint8_t level = 5;
    uint8_t decay = 0;

    if (!cmd->value) {
        snprintf(data, sizeof(data),
                "{\"enabled\":%s,\"level\":%u,\"decay\":%u}",
                g_config.dereverb_enabled ? "true" : "false",
                (uint8_t)5, (uint8_t)0);
        return json_create_success(data, response);
    }

    /* Parse format: on/off,level,decay or just on/off */
    char *comma1 = strchr(cmd->value, ',');
    char *comma2 = NULL;

    if (comma1) {
        *comma1 = '\0';
        comma2 = strchr(comma1 + 1, ',');
        if (comma2) {
            *comma2 = '\0';
        }

        char *enable_str = cmd->value;
        char *level_str = comma1 + 1;
        char *decay_str = comma2 ? comma2 + 1 : NULL;

        /* Parse enable */
        if (strcasecmp(enable_str, "on") == 0 || strcasecmp(enable_str, "1") == 0) {
            enable = true;
        } else if (strcasecmp(enable_str, "off") == 0 || strcasecmp(enable_str, "0") == 0) {
            enable = false;
        } else {
            return json_create_error("Invalid enable value", response);
        }

        /* Parse level (SpeexDSP uses 0-100 range) */
        if (level_str) {
            int level_val = atoi(level_str);
            if (level_val < 0 || level_val > 100) {
                return json_create_error("Invalid level (0-100)", response);
            }
            level = (uint8_t)level_val;
        }

        /* Parse decay (SpeexDSP uses 0-100 range) */
        if (decay_str) {
            int decay_val = atoi(decay_str);
            if (decay_val < 0 || decay_val > 100) {
                return json_create_error("Invalid decay (0-100)", response);
            }
            decay = (uint8_t)decay_val;
        }
    } else {
        /* Just enable/disable */
        if (strcasecmp(cmd->value, "on") == 0 || strcasecmp(cmd->value, "1") == 0) {
            enable = true;
        } else if (strcasecmp(cmd->value, "off") == 0 || strcasecmp(cmd->value, "0") == 0) {
            enable = false;
        } else {
            return json_create_error("Invalid value (use on/off or 0/1)", response);
        }
    }

    g_config.dereverb_enabled = enable;

#ifdef CONFIG_SETTINGS
    save_setting_now("config/dereverb_enabled", &enable, sizeof(enable));
#endif

    snprintf(data, sizeof(data),
            "{\"enabled\":%s,\"level\":%u,\"decay\":%u}",
            enable ? "true" : "false",
            level,
            decay);
    return json_create_success(data, response);
}

/* AT+BRIGHTNESS - OLED brightness (contrast) control */
static int cmd_brightness(const struct at_command *cmd, char **response)
{
    char data[64];

    if (!cmd->value) {
        /* GET: return current contrast value */
        snprintf(data, sizeof(data), "{\"value\":%u}", g_config.oled_contrast);
        return json_create_success(data, response);
    }

    /* SET */
    int val;
    if (extract_int(cmd->value, &val) != 0) {
        return json_create_error("Invalid brightness value", response);
    }
    if (val < 0 || val > 255) {
        return json_create_error("Brightness must be 0-255", response);
    }

    g_config.oled_contrast = (uint8_t)val;
    oled_set_contrast(g_config.oled_contrast);
    save_setting_now("config/oled_contrast", &g_config.oled_contrast,
                     sizeof(g_config.oled_contrast));

    snprintf(data, sizeof(data), "{\"value\":%u}", g_config.oled_contrast);
    return json_create_success(data, response);
}

/* Bond info collection callback for AT+PAIR? */
struct at_pair_status {
    int count;
    char addr[BT_ADDR_LE_STR_LEN];
};

static void collect_bond_cb(const struct bt_bond_info *info, void *user_data)
{
    struct at_pair_status *st = (struct at_pair_status *)user_data;

    st->count++;
    /* Capture address of first (and only expected) bond */
    if (st->count == 1) {
        bt_addr_le_to_str(&info->addr, st->addr, sizeof(st->addr));
    }
}

static int cmd_pair(const struct at_command *cmd, char **response)
{
    char data[256];

    if (!cmd->value) {
        /* Report actual bond status from flash */
        struct at_pair_status st = {0};

        bt_foreach_bond(BT_ID_DEFAULT, collect_bond_cb, &st);
        if (st.count > 0) {
            snprintf(data, sizeof(data),
                    "{\"paired\":true,\"addr\":\"%s\"}", st.addr);
        } else {
            snprintf(data, sizeof(data), "{\"paired\":false}");
        }
        return json_create_success(data, response);
    }

    if (strcasecmp(cmd->value, "reset") == 0 || strcasecmp(cmd->value, "clear") == 0) {
        /* Erase all bond records from flash */
        int err = bt_unpair(BT_ID_DEFAULT, NULL);

        if (err) {
            LOG_ERR("bt_unpair failed: %d", err);
            return json_create_error("Failed to clear pairing", response);
        }

        LOG_INF("Pairing info cleared, rebooting in 500ms");
        /* Schedule reboot so the response is sent first */
        ble_svc_schedule_reboot(500);
        return json_create_success("{\"action\":\"cleared\",\"rebooting\":true}", response);
    }

    return json_create_error("Invalid value (use reset/clear)", response);
}

/* Combined BITRATE command handler */
static int cmd_bitrate(const struct at_command *cmd, char **response)
{
    if (cmd->type == AT_CMD_SET) {
        /* Set bitrate (mono bitrate, stereo will be x2) */
        int bitrate;

        if (!cmd->value) {
            return json_create_error("Missing bitrate value", response);
        }

        if (extract_int(cmd->value, &bitrate) != 0) {
            return json_create_error("Invalid bitrate format", response);
        }

        /* Validate bitrate (mono bitrate range: 16000-32000) */
        if (bitrate < 16000 || bitrate > 32000) {
            return json_create_error("Bitrate out of range (16000-32000 for mono)", response);
        }

        /* Store to config */
        g_config.bitrate = bitrate;
#ifdef CONFIG_SETTINGS
        save_setting_now("config/bitrate", &bitrate, sizeof(bitrate));
#endif

        /* Update audio subsystem */
        audio_set_bitrate(bitrate);

        return json_create_kv("value", cmd->value, response);
    } else {
        /* GET bitrate - return actual bitrate being used (depends on mode) */
        char buffer[16];
        uint32_t actual_bitrate = audio_get_bitrate();
        snprintf(buffer, sizeof(buffer), "%u", actual_bitrate);
        return json_create_kv("value", buffer, response);
    }
}

/* Combined COMPLEXITY command handler */
static int cmd_complexity(const struct at_command *cmd, char **response)
{
    if (cmd->type == AT_CMD_SET) {
        /* Set complexity */
        int complexity;

        if (!cmd->value) {
            return json_create_error("Missing complexity value", response);
        }

        if (extract_int(cmd->value, &complexity) != 0) {
            return json_create_error("Invalid complexity format", response);
        }

        if (complexity < 0 || complexity > 10) {
            return json_create_error("Complexity out of range (0-10)", response);
        }

        g_config.complexity = complexity;
#ifdef CONFIG_SETTINGS
        uint8_t complexity_val = complexity;
        save_setting_now("config/complexity", &complexity_val, sizeof(complexity_val));
#endif

        return json_create_kv("value", cmd->value, response);
    } else {
        /* GET complexity */
        char buffer[16];
        snprintf(buffer, sizeof(buffer), "%u", g_config.complexity);
        return json_create_kv("value", buffer, response);
    }
}

/* Combined MODE command handler */
static int cmd_mode(const struct at_command *cmd, char **response)
{
    if (cmd->type == AT_CMD_SET) {
        /* Set mode */
        char mode_str[32];
        char quoted[36];

        if (!cmd->value) {
            return json_create_error("Missing mode value", response);
        }

        /* Copy and trim */
        strncpy(mode_str, cmd->value, sizeof(mode_str) - 1);
        mode_str[sizeof(mode_str) - 1] = '\0';
        trim_whitespace(mode_str);

        /* Convert to lowercase */
        for (char *p = mode_str; *p; p++) {
            *p = tolower((unsigned char)*p);
        }

        if (strcmp(mode_str, "normal") == 0) {
            g_config.mode = MODE_NORMAL;
        } else if (strcmp(mode_str, "enhanced") == 0) {
            g_config.mode = MODE_ENHANCED;
        } else {
            return json_create_error("Invalid mode (use normal or enhanced)", response);
        }

#ifdef CONFIG_SETTINGS
        uint8_t mode_val = g_config.mode;
        save_setting_now("config/mode", &mode_val, sizeof(mode_val));
#endif

        /* Return as quoted string */
        char quoted_mode[64];
        snprintf(quoted_mode, sizeof(quoted_mode), "\"%s\"", mode_str);
        return json_create_kv("value", quoted_mode, response);
    } else {
        /* GET mode - return as quoted string */
        const char *mode = (g_config.mode == MODE_NORMAL) ? "normal" : "enhanced";
        char quoted_mode[64];
        snprintf(quoted_mode, sizeof(quoted_mode), "\"%s\"", mode);
        return json_create_kv("value", quoted_mode, response);
    }
}

/* Combined CHUNKSIZE command handler */
static int cmd_chunksize(const struct at_command *cmd, char **response)
{
    char buffer[16];

    if (cmd->type == AT_CMD_SET) {
        /* Set chunk size */
        uint32_t value;

        if (!cmd->value) {
            return json_create_error("Missing chunk size value", response);
        }

        value = atoi(cmd->value);

        if (value < 100 || value > 4096) {
            return json_create_error("Invalid chunk size (100-4096)", response);
        }

        g_config.chunk_size = value;
#ifdef CONFIG_SETTINGS
        uint16_t chunk_val = value;
        save_setting_now("config/chunk_size", &chunk_val, sizeof(chunk_val));
#endif

        snprintf(buffer, sizeof(buffer), "%u", value);
    } else {
        /* GET chunk size */
        snprintf(buffer, sizeof(buffer), "%u", g_config.chunk_size);
    }

    return json_create_kv("value", buffer, response);
}

static int cmd_start(const struct at_command *cmd, char **response)
{
    int err;
    enum audio_mode audio_mode = AUDIO_MODE_MONO; /* Default to mono */
    enum recording_mode rec_mode = g_config.mode;

    /* Parse mode parameter if provided */
    if (cmd->value) {
        char mode_str[32];
        strncpy(mode_str, cmd->value, sizeof(mode_str) - 1);
        mode_str[sizeof(mode_str) - 1] = '\0';
        trim_whitespace(mode_str);

        for (char *p = mode_str; *p; p++) {
            *p = tolower((unsigned char)*p);
        }

        if (strcmp(mode_str, "normal") == 0 || strcmp(mode_str, "stereo") == 0) {
            rec_mode = MODE_NORMAL;
            audio_mode = AUDIO_MODE_STEREO; /* Stereo: 2 channels */
        } else if (strcmp(mode_str, "enhanced") == 0 || strcmp(mode_str, "mono") == 0) {
            rec_mode = MODE_ENHANCED;
            audio_mode = AUDIO_MODE_MERGE; /* Processed mono: L+R → mono + DSP */
        } else {
            return json_create_error("Invalid mode (use normal/stereo or enhanced/mono)", response);
        }
    } else {
        /* Use config default */
        if (rec_mode == MODE_NORMAL) {
            audio_mode = AUDIO_MODE_STEREO;  /* Stereo: 2 channels */
        } else {
            audio_mode = AUDIO_MODE_MERGE;  /* Processed mono: L+R → mono + DSP */
        }
    }

    /* Check current state */
    if (state_get_current() == CLIP_STATE_RECORDING) {
        return json_create_error("Already recording", response);
    }

    /* Start audio recording */
    err = audio_start_recording(audio_mode);
    if (err) {
        return json_create_error("Failed to start audio", response);
    }

    /* Transition to recording state */
    err = state_transition(CLIP_STATE_RECORDING);
    if (err) {
        audio_stop_recording();
        return json_create_error("Cannot start recording", response);
    }

    /* Get session ID from audio module (uses time-based format) */
    const char *session_id = audio_get_session_id();
    if (!session_id) {
        return json_create_error("No active session", response);
    }

    /* Return session ID as quoted string for valid JSON */
    char quoted_session[64];
    snprintf(quoted_session, sizeof(quoted_session), "\"%s\"", session_id);
    return json_create_kv("session", quoted_session, response);
}

static int cmd_stop(const struct at_command *cmd, char **response)
{
    int err;
    struct audio_stats audio_stats;
    enum clip_state current_state = state_get_current();

    /* Check current state - allow stop from RECORDING or PAUSED state */
    if (current_state != CLIP_STATE_RECORDING && current_state != CLIP_STATE_PAUSED) {
        return json_create_error("Not recording", response);
    }

    /* Get session ID before stopping (same format as AT+START) */
    const char *session_id = audio_get_session_id();
    if (!session_id) {
        return json_create_error("No active session", response);
    }

    /* Stop audio recording - state transition will be handled by audio thread */
    err = audio_stop_recording();
    if (err) {
        LOG_WRN("Failed to stop audio: %d", err);
        return json_create_error("Failed to stop recording", response);
    }

    /* Note: State transition to IDLE is handled by audio thread after
     * it has actually stopped recording. This prevents race condition. */

    /* Get audio statistics */
    audio_get_stats(&audio_stats);

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

    return json_create_success(data, response);
}

static int cmd_mark(const struct at_command *cmd, char **response)
{
    int err;

    /* Check if recording */
    if (state_get_current() != CLIP_STATE_RECORDING) {
        return json_create_error("Not recording", response);
    }

    /* Add bookmark via audio module */
    err = audio_add_bookmark();
    if (err != 0) {
        return json_create_error("Failed to add bookmark", response);
    }

    /* Trigger mark animation on UI */
    ui_post_event(UI_EVT_MARK);

    LOG_INF("Bookmark added at %u seconds", g_recording_time);

    /* Return simplified response with just the offset */
    char data[64];
    snprintf(data, sizeof(data), "{\"offset\":%u}", g_recording_time);

    return json_create_success(data, response);
}

static int cmd_list(const struct at_command *cmd, char **response)
{
    /*
     * AT+LIST command has three modes:
     * 1. AT+LIST - List sessions with pagination (default page 1)
     * 2. AT+LIST?page&per_page - Paginated session list
     * 3. AT+LIST=session_id - Session details
     * 4. AT+LIST=session_id?page&per_page - Paginated file list
     */
    if (cmd->value) {
        /* Check if this is pagination for session list (starts with ?)
         * Session IDs are 15+ characters, so ? at position 0 means pagination */
        if (cmd->value[0] == '?') {
            /* Session list pagination: AT+LIST?1&10 */
            const char *query = cmd->value;
            int page = 1;
            int per_page = 10;

            /* Parse pagination: page&per_page */
            char query_buf[32];
            strncpy(query_buf, query + 1, sizeof(query_buf) - 1);
            query_buf[sizeof(query_buf) - 1] = '\0';

            char *token = strtok(query_buf, "&");
            if (token) {
                page = atoi(token);
                if (page < 1) page = 1;
            }
            token = strtok(NULL, "&");
            if (token) {
                per_page = atoi(token);
                if (per_page < 1) per_page = 10;
                if (per_page > CLIP_AT_CMD_MAX_PER_PAGE) per_page = CLIP_AT_CMD_MAX_PER_PAGE;
            }

            /* Variables for session list pagination (using static buffer) */
            int total_count;
            int offset;
            int result_count;

            /* Get total count first (fast, doesn't read session details) */
            total_count = storage_count_sessions();
            if (total_count < 0) {
                return json_create_error("Failed to count sessions", response);
            }

            /* Calculate offset for pagination */
            offset = (page - 1) * per_page;
            if (offset >= total_count) {
                /* Page beyond available data */
                int len = snprintf(json_buffer, sizeof(json_buffer),
                        "{\"ok\":true,\"data\":{\"total\":%d,\"page\":%d,\"per_page\":%d,\"sessions\":[]}}",
                        total_count, page, per_page);
                if (len < 0 || len >= sizeof(json_buffer)) {
                    return json_create_error("Response too large", response);
                }
                *response = json_buffer;
                return 0;
            }

            /* Use static buffer for sessions (avoid heap allocation) */
            if (per_page > CLIP_AT_CMD_MAX_PER_PAGE) {
                per_page = CLIP_AT_CMD_MAX_PER_PAGE;
            }

            /* Get only the requested page */
            result_count = storage_list_sessions_paginated(session_buffer, offset, per_page);
            if (result_count < 0) {
                    return json_create_error("Failed to list sessions", response);
            }

            /* Build paginated response */
            char *ptr = json_buffer;
            int remaining = sizeof(json_buffer);
            int len;

            len = snprintf(ptr, remaining,
                         "{\"ok\":true,\"data\":{\"total\":%d,\"page\":%d,\"per_page\":%d,\"sessions\":[",
                         total_count, page, per_page);
            if (len < 0 || len >= remaining) {
                    return json_create_error("Response too large", response);
            }
            ptr += len;
            remaining -= len;

            /* Add sessions for this page */
            for (int i = 0; i < result_count && remaining > 200; i++) {
                int bookmark_count = bookmarks_count(session_buffer[i].session_id);
                if (bookmark_count < 0) {
                    bookmark_count = 0;
                }

                len = snprintf(ptr, remaining,
                              "%s{\"id\":\"%s\",\"files\":%u,\"size\":%llu,\"bookmarks\":%d}",
                              (i > 0) ? "," : "",
                              session_buffer[i].session_id,
                              session_buffer[i].file_count,
                              session_buffer[i].total_bytes,
                              bookmark_count);
                if (len < 0 || len >= remaining) {
                    break;
                }
                ptr += len;
                remaining -= len;
            }


            /* Close JSON */
            if (remaining < 4) {
                return json_create_error("Response too large", response);
            }
            snprintf(ptr, remaining, "]}}");

            *response = json_buffer;
            return 0;
        }

        /* Otherwise, this is session_id or session_id?pagination */
        struct storage_session_info session;
        int ret;
        char session_id[32] = {0};
        const char *query = strchr(cmd->value, '?');
        int page = 1;
        int per_page = 10;  /* Default 10 items per page */
        int start_index, end_index;

        /* Initialize session structure to ensure clean state */
        memset(&session, 0, sizeof(session));

        /* Extract session_id (part before ? if present) */
        if (query) {
            size_t len = query - cmd->value;
            if (len >= sizeof(session_id)) {
                len = sizeof(session_id) - 1;
            }
            strncpy(session_id, cmd->value, len);
            session_id[len] = '\0';

            /* Parse pagination: page&per_page */
            /* Use local buffer for parsing */
            char query_buf[32];
            strncpy(query_buf, query + 1, sizeof(query_buf) - 1);
            query_buf[sizeof(query_buf) - 1] = '\0';

            char *token = strtok(query_buf, "&");
            if (token) {
                page = atoi(token);
                if (page < 1) page = 1;
            }
            token = strtok(NULL, "&");
            if (token) {
                per_page = atoi(token);
                if (per_page < 1) per_page = 10;
                if (per_page > CLIP_AT_CMD_MAX_PER_PAGE) per_page = CLIP_AT_CMD_MAX_PER_PAGE; /* Cap at 50 for safety */
            }
        } else {
            strncpy(session_id, cmd->value, sizeof(session_id) - 1);
            session_id[sizeof(session_id) - 1] = '\0';
        }

        /* Get session info */
        ret = storage_get_session_info(session_id, &session);
        if (ret != 0) {
            return json_create_error("Session not found", response);
        }

        /* If no pagination requested, return summary only */
        if (!query) {
            /* Get bookmark count for this session */
            int bookmark_count = bookmarks_count(session_id);
            if (bookmark_count < 0) {
                bookmark_count = 0;
            }

            /* Ensure mode string is null-terminated for safety */
            session.mode[sizeof(session.mode) - 1] = '\0';

            /* Validate session fields */
            if (session.sample_rate_khz > 255 || session.sample_rate_khz == 0) {
                session.sample_rate_khz = 16;
            }
            if (session.channels < 1 || session.channels > 2) {
                session.channels = 1;
            }

            /* Build JSON response with validated values */
            int len = snprintf(json_buffer, sizeof(json_buffer),
                    "{\"ok\":true,\"data\":{\"files\":%u,\"size\":%u,\"synced\":%u,"
                    "\"bookmarks\":%d,\"channels\":%u,\"sample_rate\":%u,\"mode\":\"%s\"}}",
                    session.file_count, (uint32_t)session.total_bytes, session.synced_files,
                    bookmark_count, session.channels, session.sample_rate_khz * 1000, session.mode);

            /* Check for buffer overflow */
            if (len < 0 || len >= sizeof(json_buffer)) {
                return json_create_error("Response too large", response);
            }

            /* Return response (using static buffer) */
            *response = json_buffer;
            return 0;
        }

        /* Paginated file list - generate file names since they're sequential */
        start_index = (page - 1) * per_page;
        if (start_index >= session.file_count) {
            /* Page beyond available data */
            int len = snprintf(json_buffer, sizeof(json_buffer),
                    "{\"ok\":true,\"data\":{\"total\":%u,\"page\":%d,\"per_page\":%d,\"files\":[]}}",
                    session.file_count, page, per_page);
            if (len < 0 || len >= sizeof(json_buffer)) {
                return json_create_error("Response too large", response);
            }
        } else {
            end_index = start_index + per_page;
            if (end_index > session.file_count) {
                end_index = session.file_count;
            }

            /* Build paginated response with file names */
            char *ptr = json_buffer;
            int remaining = sizeof(json_buffer);
            int len;

            len = snprintf(ptr, remaining,
                         "{\"ok\":true,\"data\":{\"total\":%u,\"page\":%d,\"per_page\":%d,\"files\":[",
                         session.file_count, page, per_page);
            if (len < 0 || len >= remaining) {
                return json_create_error("Response too large", response);
            }
            ptr += len;
            remaining -= len;

            /* Add file names (0001.opus, 0002.opus, etc.) */
            for (int i = start_index; i < end_index && remaining > 50; i++) {
                len = snprintf(ptr, remaining,
                              "%s\"%04u.opus\"",
                              (i > start_index) ? "," : "",
                              i + 1);
                if (len < 0 || len >= remaining) {
                    break;
                }
                ptr += len;
                remaining -= len;
            }

            /* Close JSON array - check remaining space */
            if (remaining < 4) {
                return json_create_error("Response too large", response);
            }
            snprintf(ptr, remaining, "]}}");
        }

        /* Allocate and copy response */
        *response = json_buffer;
            return 0;
    }

    /* Otherwise, list sessions (default first page with pagination info) */
    int total_count;
    int page = 1;
    int per_page = 10;  /* Default 10 items per page */
    int offset;
    int result_count;

    /* Get total count first (fast, doesn't read session details) */
    total_count = storage_count_sessions();
    if (total_count < 0) {
        return json_create_error("Failed to count sessions", response);
    }

    /* Calculate offset for pagination (default: first page) */
    offset = (page - 1) * per_page;
    if (offset >= total_count) {
        offset = 0;
    }

    /* Use static buffer for sessions (avoid heap allocation) */
    if (per_page > CLIP_AT_CMD_MAX_PER_PAGE) {
        per_page = CLIP_AT_CMD_MAX_PER_PAGE;
    }

    /* Get only the requested page */
    result_count = storage_list_sessions_paginated(session_buffer, offset, per_page);
    if (result_count < 0) {
            return json_create_error("Failed to list sessions", response);
    }

    /* Build response with pagination info */
    char *ptr = json_buffer;
    int remaining = sizeof(json_buffer);
    int len;

    /* Start with {"ok":true,"data":{"total":N,"page":1,"per_page":10,"sessions":[ */
    len = snprintf(ptr, remaining,
                  "{\"ok\":true,\"data\":{\"total\":%d,\"page\":%d,\"per_page\":%d,\"sessions\":[",
                  total_count, page, per_page);
    if (len < 0 || len >= remaining) {
            return json_create_error("Response too large", response);
    }
    ptr += len;
    remaining -= len;

    /* Add sessions for this page */
    for (int i = 0; i < result_count && remaining > 200; i++) {
        /* Get bookmark count for this session */
        int bookmark_count = bookmarks_count(session_buffer[i].session_id);
        if (bookmark_count < 0) {
            bookmark_count = 0;
        }

        len = snprintf(ptr, remaining,
                      "%s{\"id\":\"%s\",\"files\":%u,\"size\":%llu,\"bookmarks\":%d}",
                      (i > 0) ? "," : "",
                      session_buffer[i].session_id,
                      session_buffer[i].file_count,
                              session_buffer[i].total_bytes,
                      bookmark_count);

        /* Check if snprintf was truncated */
        if (len < 0 || len >= remaining) {
            /* Not enough space, don't add this session and stop */
            break;
        }
        ptr += len;
        remaining -= len;
    }


    /* Close with ]}} - check space first */
    if (remaining < 4) {
        return json_create_error("Response too large", response);
    }
    snprintf(ptr, remaining, "]}}");

    /* Allocate and copy response */
    *response = json_buffer;
            return 0;
}

static int cmd_delete(const struct at_command *cmd, char **response)
{
    int err;

    if (!cmd->value) {
        return json_create_error("Missing session ID", response);
    }

    /* Check if session exists */
    if (!storage_session_exists(cmd->value)) {
        return json_create_error("Session not found", response);
    }

    /* Delete the session */
    err = storage_delete_session(cmd->value);
    if (err != 0) {
        return json_create_error("Failed to delete session", response);
    }

    char data[128];
    snprintf(data, sizeof(data), "{\"deleted\":\"%s\"}", cmd->value);

    return json_create_success(data, response);
}

static int cmd_format(const struct at_command *cmd, char **response)
{
    int err;

    LOG_DBG("FORMAT command");

    /* Only allow EXEC type (no arguments) */
    if (cmd->value) {
        LOG_WRN("FORMAT: unexpected argument");
        return json_create_error("FORMAT takes no arguments", response);
    }

    /* Check state machine - only allow IDLE state */
    enum clip_state state = state_get_current();
    if (state != CLIP_STATE_IDLE) {
        char err_buf[64];
        snprintf(err_buf, sizeof(err_buf), "Cannot format while busy (state=%d)", (int)state);
        LOG_WRN("FORMAT: %s", err_buf);
        return json_create_error(err_buf, response);
    }

    /* Check if recording is active */
    if (audio_is_recording()) {
        LOG_WRN("FORMAT: recording is active");
        return json_create_error("Cannot format while recording", response);
    }

    /* Check if transfer is active */
    if (transfer_is_active()) {
        LOG_WRN("FORMAT: transfer is active");
        return json_create_error("Cannot format while transferring", response);
    }

    /* Format SD card */
    err = storage_format_card();
    if (err != 0) {
        LOG_ERR("FORMAT: storage_format_card returned %d", err);
        return json_create_error("Failed to format SD card", response);
    }

    LOG_INF("SD card formatted");
    return json_create_success("{\"formatted\":true}", response);
}

static int cmd_marks(const struct at_command *cmd, char **response)
{
    struct bookmark *bookmarks = NULL;
    int total_count;
    int page = 1;           /* Default page 1 */
    int per_page = 10;      /* Default 10 items per page */
    int start_index = 0;
    int end_index;
    int return_count;
    char *ptr = json_buffer;
    int remaining = sizeof(json_buffer);
    char session_id[32];

    if (!cmd->value) {
        return json_create_error("Missing session ID", response);
    }

    /* Parse session_id and optional pagination (format: "session_id?page&per_page" or "session_id") */
    const char *query = strchr(cmd->value, '?');

    if (query) {
        /* Extract session_id (part before ?) */
        size_t len = query - cmd->value;
        if (len >= sizeof(session_id)) {
            len = sizeof(session_id) - 1;
        }
        strncpy(session_id, cmd->value, len);
        session_id[len] = '\0';

        /* Parse pagination: page&per_page */
        /* Use local buffer for parsing */
        char query_buf[32];
        strncpy(query_buf, query + 1, sizeof(query_buf) - 1);
        query_buf[sizeof(query_buf) - 1] = '\0';

        char *token = strtok(query_buf, "&");
        if (token) {
            page = atoi(token);
            if (page < 1) page = 1;
        }
        token = strtok(NULL, "&");
        if (token) {
            per_page = atoi(token);
            if (per_page < 1) per_page = 10;
            if (per_page > CLIP_AT_CMD_MAX_PER_PAGE) per_page = CLIP_AT_CMD_MAX_PER_PAGE; /* Cap at 50 for safety */
        }
    } else {
        strncpy(session_id, cmd->value, sizeof(session_id) - 1);
        session_id[sizeof(session_id) - 1] = '\0';
    }

    /* Check if session exists */
    if (!storage_session_exists(session_id)) {
        return json_create_error("Session not found", response);
    }

    /* Get total bookmark count */
    total_count = bookmarks_count(session_id);
    if (total_count < 0) {
        total_count = 0;
    }

    /* If no query string, return summary only */
    if (!query) {
        int len = snprintf(json_buffer, sizeof(json_buffer),
                 "{\"total\":%d,\"marks_file\":\"marks.bin\"}",
                 total_count);
        if (len < 0 || len >= sizeof(json_buffer)) {
            return json_create_error("Response too large", response);
        }
        return json_create_success(json_buffer, response);
    }

    /* Calculate pagination bounds */
    start_index = (page - 1) * per_page;
    if (start_index >= total_count && total_count > 0) {
        /* Page beyond available data */
        int len = snprintf(json_buffer, sizeof(json_buffer),
                 "{\"total\":%d,\"page\":%d,\"per_page\":%d,\"bookmarks\":[]}",
                 total_count, page, per_page);
        if (len < 0 || len >= sizeof(json_buffer)) {
            return json_create_error("Response too large", response);
        }
        return json_create_success(json_buffer, response);
    }

    end_index = start_index + per_page;
    if (end_index > total_count) {
        end_index = total_count;
    }

    /* Only allocate what we need for this page */
    int alloc_count = end_index - start_index;
    if (alloc_count > per_page) {
        alloc_count = per_page;
    }

    bookmarks = k_malloc(alloc_count * sizeof(struct bookmark));
    if (!bookmarks) {
        return json_create_error("Out of memory", response);
    }

    /* Get bookmarks for this page using new API */
    return_count = bookmarks_get_page(session_id, page, per_page, bookmarks, alloc_count);
    if (return_count < 0) {
        k_free(bookmarks);
        return json_create_error("Failed to get bookmarks", response);
    }

    /* Build paginated JSON response - simplified to only show offset */
    int len = snprintf(json_buffer, sizeof(json_buffer),
                     "{\"total\":%d,\"page\":%d,\"per_page\":%d,\"bookmarks\":[",
                     total_count, page, per_page);
    if (len < 0 || len >= sizeof(json_buffer)) {
        k_free(bookmarks);
        return json_create_error("Response too large", response);
    }
    ptr = json_buffer + len;
    remaining = sizeof(json_buffer) - len;

    /* Add bookmarks for this page - only offset (no note, no timestamp) */
    int items_added = 0;
    for (int i = 0; i < return_count && remaining > 50; i++) {
        len = snprintf(ptr, remaining,
                      "%s{\"offset\":%u}",
                      (items_added > 0) ? "," : "",
                      bookmarks[i].offset_sec);

        if (len < 0 || len >= remaining) {
            break; /* Buffer full */
        }
        ptr += len;
        remaining -= len;
        items_added++;
    }

    /* Close JSON array - check remaining space */
    if (remaining < 4) {
        k_free(bookmarks);
        return json_create_error("Response too large", response);
    }
    snprintf(ptr, remaining, "]}");

    k_free(bookmarks);
    return json_create_success(json_buffer, response);
}

static int cmd_download(const struct at_command *cmd, char **response)
{
    char session_id[32] = {0};
    char filename[64] = {0};
    char start_file[32] = {0};  /* For resume: start from this file */
    char *slash;
    char *colon;
    int err;

    if (!cmd->value) {
        return json_create_error("Missing session ID", response);
    }

    /* Parse session/filename or session:start_file or just session */
    slash = strchr(cmd->value, '/');
    colon = strchr(cmd->value, ':');

    if (slash) {
        /* Session/filename format - download single file */
        *slash = '\0';
        strncpy(session_id, cmd->value, sizeof(session_id) - 1);
        strncpy(filename, slash + 1, sizeof(filename) - 1);
    } else if (colon) {
        /* Session:start_file format - resume from this file */
        *colon = '\0';
        strncpy(session_id, cmd->value, sizeof(session_id) - 1);
        strncpy(start_file, colon + 1, sizeof(start_file) - 1);
    } else {
        /* Just session ID - download all files */
        strncpy(session_id, cmd->value, sizeof(session_id) - 1);
    }

    /* Check if session exists */
    if (!storage_session_exists(session_id)) {
        return json_create_error("Session not found", response);
    }

    /* Start transfer */
    if (filename[0]) {
        /* Download single file */
        err = transfer_start(session_id, filename);
    } else if (start_file[0]) {
        /* Resume transfer from start_file */
        err = transfer_resume_from(session_id, start_file);
    } else {
        /* Download all files from session */
        err = transfer_start(session_id, NULL);
    }

    if (err != 0) {
        return json_create_error("Failed to start transfer", response);
    }

    /* Return current file info in response */
    char data[256];
    char cur_session_id[32] = {0};
    char cur_filename[64] = {0};
    uint32_t total_files = 0;
    int len;

    err = transfer_get_current_session(cur_session_id, sizeof(cur_session_id), cur_filename, sizeof(cur_filename));
    if (err == 0) {
        total_files = transfer_get_total_files();
        if (cur_filename[0] != '\0') {
            len = snprintf(data, sizeof(data),
                         "{\"session\":\"%s\",\"filename\":\"%s\",\"files\":%u}",
                         cur_session_id, cur_filename, total_files);
        } else {
            len = snprintf(data, sizeof(data),
                         "{\"session\":\"%s\",\"files\":%u}",
                         cur_session_id, total_files);
        }
    } else {
        /* Not actively transferring, return basic success */
        return json_create_success(NULL, response);
    }

    return json_create_success(data, response);
}

static int cmd_progress(const struct at_command *cmd, char **response)
{
    char data[256];
    uint8_t progress_percent;
    uint64_t bytes_transferred;
    uint64_t total_bytes;
    enum transfer_state state;
    int err;

    err = transfer_get_progress_lite(&progress_percent, &bytes_transferred,
                                     &total_bytes, &state);
    if (err != 0) {
        return json_create_error("Failed to get progress", response);
    }

    snprintf(data, sizeof(data),
             "{\"progress\":%u,"
             "\"transferred\":%llu,"
             "\"total\":%llu,"
             "\"state\":%u}",
             progress_percent,
             bytes_transferred,
             total_bytes,
             state);

    return json_create_success(data, response);
}

static int cmd_pause(const struct at_command *cmd, char **response)
{
    int ret;

    /* Only support recording pause */
    if (!audio_is_recording()) {
        return json_create_error("Not recording", response);
    }

    if (audio_is_paused()) {
        return json_create_error("Already paused", response);
    }

    ret = audio_pause_recording();
    if (ret != 0) {
        return json_create_error("Failed to pause", response);
    }

    state_transition(CLIP_STATE_PAUSED);

    return json_create_success(NULL, response);
}

static int cmd_resume(const struct at_command *cmd, char **response)
{
    int ret;

    if (!audio_is_paused()) {
        return json_create_error("Not paused", response);
    }

    ret = audio_resume_recording();
    if (ret != 0) {
        return json_create_error("Failed to resume", response);
    }

    state_transition(CLIP_STATE_RECORDING);

    return json_create_success(NULL, response);
}

static int cmd_cancel(const struct at_command *cmd, char **response)
{
     int err;

     err = transfer_cancel();
     if (err != 0) {
         return json_create_error("No transfer to cancel", response);
     }

     /* Only transition to idle if we were in TRANSMITTING state
      * If recording is in progress, don't change the state */
     enum clip_state current_state = state_get_current();
     if (current_state == CLIP_STATE_TRANSMITTING) {
         state_transition(CLIP_STATE_IDLE);
     }

     return json_create_success(NULL, response);
}

static int cmd_reboot(const struct at_command *cmd, char **response)
{
    /* Confirm reboot is about to happen */
    return json_create_success("{\"rebooting\":true}", response);
}

static int cmd_purge(const struct at_command *cmd, char **response)
{
    struct storage_session_info sessions[32];
    char deleted_list[512];
    int count;
    int deleted_count = 0;
    uint64_t total_freed = 0;

    /* List all sessions */
    count = storage_list_sessions(sessions, 32);
    if (count < 0) {
        return json_create_error("Failed to list sessions", response);
    }

    if (count == 0) {
        return json_create_success("{\"deleted\":[],\"freed\":0}", response);
    }

    /* Build deleted list JSON */
    char *ptr = deleted_list;
    int remaining = sizeof(deleted_list);
    int len;

    len = snprintf(ptr, remaining, "{\"deleted\":[");
    if (len < 0 || len >= remaining) {
        return json_create_error("Response too large", response);
    }
    ptr += len;
    remaining -= len;

    /* Delete all sessions */
    for (int i = 0; i < count && remaining > 50; i++) {
        int err = storage_delete_session(sessions[i].session_id);
        if (err == 0) {
            len = snprintf(ptr, remaining,
                              "%s\"%s\"",
                              deleted_count > 0 ? "," : "",
                              sessions[i].session_id);
            if (len < 0 || len >= remaining) {
                break; /* Buffer full, stop adding */
            }
            ptr += len;
            remaining -= len;
            total_freed += sessions[i].total_bytes;
            deleted_count++;
        }
    }

    /* Check remaining space before closing */
    if (remaining < 30) {
        return json_create_error("Response too large", response);
    }
    snprintf(ptr, remaining, "],\"freed\":%llu}", total_freed);

    return json_create_success(deleted_list, response);
}

/* Command table */
struct cmd_entry {
    const char *name;
    int (*handler)(const struct at_command *cmd, char **response);
    enum at_cmd_type allowed_types;
};

static const struct cmd_entry commands[] = {
    /* Status commands */
    {"GSTAT",    cmd_gstat,        AT_CMD_EXEC},

    /* System commands */
    {"VERSION",  cmd_version,      AT_CMD_EXEC},
    {"TIME",     cmd_time,         AT_CMD_GET | AT_CMD_SET},
    {"REBOOT",   cmd_reboot,       AT_CMD_EXEC},
    {"PURGE",    cmd_purge,        AT_CMD_EXEC},
    {"BATTERY",  cmd_battery_set,  AT_CMD_SET | AT_CMD_GET},
    {"CHARGING", cmd_charging_set, AT_CMD_SET | AT_CMD_GET},
    {"PAIR",     cmd_pair,         AT_CMD_SET | AT_CMD_GET},

    /* Configuration commands */
    {"BITRATE",  cmd_bitrate,      AT_CMD_SET | AT_CMD_GET},
    {"COMPLEXITY", cmd_complexity, AT_CMD_SET | AT_CMD_GET},
    {"MODE",     cmd_mode,         AT_CMD_SET | AT_CMD_GET},
    {"CHUNKSIZE", cmd_chunksize,   AT_CMD_SET | AT_CMD_GET},

    /* Audio processing commands */
    {"NOISE",    cmd_noise_set,     AT_CMD_SET | AT_CMD_GET},
    {"AGC",      cmd_agc_set,       AT_CMD_SET | AT_CMD_GET},
    {"DEREVERB", cmd_dereverb_set,  AT_CMD_SET | AT_CMD_GET},
    {"BRIGHTNESS", cmd_brightness,  AT_CMD_SET | AT_CMD_GET},

    /* Storage management commands */
    {"AUTODEL",  cmd_autodel_set,   AT_CMD_SET | AT_CMD_GET},

    /* Recording commands */
    {"START",    cmd_start,        AT_CMD_EXEC | AT_CMD_SET},
    {"STOP",     cmd_stop,         AT_CMD_EXEC},
    {"MARK",     cmd_mark,         AT_CMD_EXEC | AT_CMD_SET},

    /* Session management commands */
    {"LIST",     cmd_list,         AT_CMD_EXEC | AT_CMD_SET},
    {"DELETE",   cmd_delete,       AT_CMD_SET},
    {"FORMAT",   cmd_format,       AT_CMD_EXEC},
    {"MARKS",    cmd_marks,        AT_CMD_SET},

    /* Transfer commands */
    {"DOWNLOAD", cmd_download,     AT_CMD_SET},
    {"PROGRESS", cmd_progress,     AT_CMD_EXEC},
    {"PAUSE",    cmd_pause,        AT_CMD_EXEC},
    {"RESUME",   cmd_resume,       AT_CMD_EXEC},
    {"CANCEL",   cmd_cancel,       AT_CMD_EXEC},

    /* Sentinel */
    {NULL, NULL, 0}
};

int at_cmd_execute(const struct at_command *cmd, char **response)
{
    const struct cmd_entry *entry;

    /* Find command handler */
    for (entry = commands; entry->name; entry++) {
        if (strcmp(cmd->name, entry->name) == 0) {
            /* Check if command type is allowed */
            if (!(entry->allowed_types & cmd->type)) {
                return json_create_error("Command type not supported", response);
            }

            /* Execute handler */
            return entry->handler(cmd, response);
        }
    }

    /* Command not found */
    return json_create_error("Unknown command", response);
}

int at_cmd_init(void)
{
    /* Initialize global status */
    memset(&g_status, 0, sizeof(g_status));
    g_status.battery.percent = 100;
    g_status.battery.charging = false;
    g_status.free_space = 1024000000;
    g_status.session_count = 0;

    /* Note: g_config is already initialized by config_init() */

    return 0;
}
