/*
 * Copyright (c) 2024 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <string.h>
#include <zephyr/logging/log.h>
#include "config.h"

LOG_MODULE_REGISTER(config, LOG_LEVEL_INF);

/* Settings name macros */
#define SETTING_BITRATE         "config/bitrate"
#define SETTING_COMPLEXITY      "config/complexity"
#define SETTING_MODE            "config/mode"
#define SETTING_NOISE_SUPPRESS  "config/noise_suppress"
#define SETTING_CHUNK_SIZE      "config/chunk_size"
#define SETTING_AUTODEL         "config/auto_delete_days"
#define SETTING_AGC_ENABLED     "config/agc_enabled"
#define SETTING_AGC_TARGET      "config/agc_target"
#define SETTING_DEREVERB        "config/dereverb_enabled"

/* Factory default configuration */
static const struct clip_config factory_config = {
    .bitrate = 48000,
    .complexity = 1,
    .mode = MODE_ENHANCED,
    .noise_suppress = 0,
    .chunk_size = 500,
    .auto_delete_days = -1,
    .agc_target = 0,
    .agc_enabled = false,
    .dereverb_enabled = false,
};

#ifdef CONFIG_SETTINGS
#include <zephyr/settings/settings.h>

/* Config entry: maps setting name to struct member offset and size */
struct config_entry {
    const char *name;
    size_t offset;
    size_t size;
};

/* Table of all config entries */
static const struct config_entry config_table[] = {
    { SETTING_BITRATE,        offsetof(struct clip_config, bitrate),        sizeof(uint16_t) },
    { SETTING_COMPLEXITY,     offsetof(struct clip_config, complexity),     sizeof(uint8_t) },
    { SETTING_MODE,           offsetof(struct clip_config, mode),           sizeof(uint8_t) },
    { SETTING_NOISE_SUPPRESS, offsetof(struct clip_config, noise_suppress), sizeof(uint8_t) },
    { SETTING_CHUNK_SIZE,     offsetof(struct clip_config, chunk_size),     sizeof(uint16_t) },
    { SETTING_AUTODEL,        offsetof(struct clip_config, auto_delete_days), sizeof(int8_t) },
    { SETTING_AGC_ENABLED,    offsetof(struct clip_config, agc_enabled),    sizeof(bool) },
    { SETTING_AGC_TARGET,     offsetof(struct clip_config, agc_target),     sizeof(uint8_t) },
    { SETTING_DEREVERB,       offsetof(struct clip_config, dereverb_enabled), sizeof(bool) },
};

#define CONFIG_TABLE_SIZE (sizeof(config_table) / sizeof(config_table[0]))

/* Settings handler for configuration */
static int config_set_handler(const char *name, size_t len,
                               settings_read_cb read_cb, void *cb_arg)
{
    if (!name) {
        return -ENOENT;
    }

    /* Find matching entry in table */
    for (size_t i = 0; i < CONFIG_TABLE_SIZE; i++) {
        const struct config_entry *entry = &config_table[i];

        /* Check if name matches (skip "config/" prefix) */
        const char *entry_name = entry->name + 7;  /* Skip "config/" */
        if (!strcmp(name, entry_name)) {
            /* Read value from NVS */
            uint8_t buffer[16];
            int rc = read_cb(cb_arg, buffer, entry->size);
            if (rc < 0) {
                return rc;
            }

            /* Copy to g_config at offset */
            memcpy((uint8_t *)&g_config + entry->offset, buffer, entry->size);
            return 0;
        }
    }

    return -ENOENT;
}

static struct settings_handler config_handler = {
    .name = "config",
    .h_set = config_set_handler,
};
#endif /* CONFIG_SETTINGS */

int config_init(void)
{
    /* Load factory defaults */
    memcpy(&g_config, &factory_config, sizeof(g_config));

#ifdef CONFIG_SETTINGS
    int err;

    /* Initialize settings subsystem */
    err = settings_subsys_init();
    if (err) {
        LOG_WRN("Settings init failed: %d", err);
        return 0;
    }

    /* Register settings handler */
    err = settings_register(&config_handler);
    if (err) {
        LOG_WRN("Settings register failed: %d", err);
        return 0;
    }

    /* Load configuration from NVS */
    err = settings_load();
    if (err) {
        LOG_WRN("Settings load failed: %d, using defaults", err);
        /* Save defaults to NVS */
        config_save();
    } else {
        LOG_INF("Config loaded: mode=%s, bitrate=%u, complexity=%u",
                (g_config.mode == MODE_NORMAL) ? "normal" : "enhanced",
                g_config.bitrate, g_config.complexity);
    }
#else
    LOG_INF("Config: factory defaults (NVS disabled)");
#endif /* CONFIG_SETTINGS */

    return 0;
}

int config_load(void)
{
#ifdef CONFIG_SETTINGS
    return settings_load();
#else
    return 0;
#endif
}

int config_save(void)
{
#ifdef CONFIG_SETTINGS
    int err;

    /* Save all entries from table */
    for (size_t i = 0; i < CONFIG_TABLE_SIZE; i++) {
        const struct config_entry *entry = &config_table[i];

        err = settings_save_one(entry->name,
                               (const uint8_t *)&g_config + entry->offset,
                               entry->size);
        if (err) {
            LOG_ERR("Failed to save %s: %d", entry->name, err);
            return err;
        }
    }

    return 0;
#else
    LOG_WRN("Config save not implemented (settings disabled)");
    return -ENOTSUP;
#endif
}

int config_factory_reset(void)
{
    /* Restore factory defaults */
    memcpy(&g_config, &factory_config, sizeof(g_config));

    /* Save defaults to NVS */
    return config_save();
}

/* Map NVS keys to setting names */
static const char *nvs_key_to_setting(uint16_t key)
{
    switch (key) {
    case NVS_KEY_BITRATE:     return SETTING_BITRATE;
    case NVS_KEY_COMPLEXITY:  return SETTING_COMPLEXITY;
    case NVS_KEY_MODE:        return SETTING_MODE;
    case NVS_KEY_NOISE:       return SETTING_NOISE_SUPPRESS;
    case NVS_KEY_CHUNK_SIZE:  return SETTING_CHUNK_SIZE;
    case NVS_KEY_AUTODEL:     return SETTING_AUTODEL;
    case NVS_KEY_AGC_ENABLE:  return SETTING_AGC_ENABLED;
    case NVS_KEY_AGC_TARGET:  return SETTING_AGC_TARGET;
    case NVS_KEY_DEREVERB:    return SETTING_DEREVERB;
    default:                  return NULL;
    }
}

int config_set(uint16_t key, const void *value, size_t len)
{
    int ret = 0;

    /* Update in-memory config */
    switch (key) {
    case NVS_KEY_BITRATE:
        if (len == sizeof(uint16_t)) {
            g_config.bitrate = *(const uint16_t *)value;
        } else {
            ret = -EINVAL;
        }
        break;
    case NVS_KEY_COMPLEXITY:
        if (len == sizeof(uint8_t)) {
            g_config.complexity = *(const uint8_t *)value;
        } else {
            ret = -EINVAL;
        }
        break;
    case NVS_KEY_MODE:
        if (len == sizeof(uint8_t)) {
            g_config.mode = *(const uint8_t *)value;
        } else {
            ret = -EINVAL;
        }
        break;
    case NVS_KEY_NOISE:
        if (len == sizeof(uint8_t)) {
            g_config.noise_suppress = *(const uint8_t *)value;
        } else {
            ret = -EINVAL;
        }
        break;
    case NVS_KEY_CHUNK_SIZE:
        if (len == sizeof(uint16_t)) {
            g_config.chunk_size = *(const uint16_t *)value;
        } else {
            ret = -EINVAL;
        }
        break;
    case NVS_KEY_AUTODEL:
        if (len == sizeof(int8_t)) {
            g_config.auto_delete_days = *(const int8_t *)value;
        } else {
            ret = -EINVAL;
        }
        break;
    case NVS_KEY_AGC_ENABLE:
        if (len == sizeof(bool)) {
            g_config.agc_enabled = *(const bool *)value;
        } else {
            ret = -EINVAL;
        }
        break;
    case NVS_KEY_AGC_TARGET:
        if (len == sizeof(uint8_t)) {
            g_config.agc_target = *(const uint8_t *)value;
        } else {
            ret = -EINVAL;
        }
        break;
    case NVS_KEY_DEREVERB:
        if (len == sizeof(bool)) {
            g_config.dereverb_enabled = *(const bool *)value;
        } else {
            ret = -EINVAL;
        }
        break;
    default:
        return -EINVAL;
    }

    if (ret) {
        return ret;
    }

#ifdef CONFIG_SETTINGS
    const char *setting = nvs_key_to_setting(key);
    if (setting) {
        return settings_save_one(setting, value, len);
    }
#endif

    return 0;
}

int config_get(uint16_t key, void *value, size_t len)
{
    switch (key) {
    case NVS_KEY_BITRATE:
        if (len == sizeof(uint16_t)) {
            *(uint16_t *)value = g_config.bitrate;
            return 0;
        }
        break;
    case NVS_KEY_COMPLEXITY:
        if (len == sizeof(uint8_t)) {
            *(uint8_t *)value = g_config.complexity;
            return 0;
        }
        break;
    case NVS_KEY_MODE:
        if (len == sizeof(uint8_t)) {
            *(uint8_t *)value = g_config.mode;
            return 0;
        }
        break;
    case NVS_KEY_NOISE:
        if (len == sizeof(uint8_t)) {
            *(uint8_t *)value = g_config.noise_suppress;
            return 0;
        }
        break;
    case NVS_KEY_CHUNK_SIZE:
        if (len == sizeof(uint16_t)) {
            *(uint16_t *)value = g_config.chunk_size;
            return 0;
        }
        break;
    case NVS_KEY_AUTODEL:
        if (len == sizeof(int8_t)) {
            *(int8_t *)value = g_config.auto_delete_days;
            return 0;
        }
        break;
    case NVS_KEY_AGC_ENABLE:
        if (len == sizeof(bool)) {
            *(bool *)value = g_config.agc_enabled;
            return 0;
        }
        break;
    case NVS_KEY_AGC_TARGET:
        if (len == sizeof(uint8_t)) {
            *(uint8_t *)value = g_config.agc_target;
            return 0;
        }
        break;
    case NVS_KEY_DEREVERB:
        if (len == sizeof(bool)) {
            *(bool *)value = g_config.dereverb_enabled;
            return 0;
        }
        break;
    default:
        return -EINVAL;
    }

    return -EINVAL;
}
