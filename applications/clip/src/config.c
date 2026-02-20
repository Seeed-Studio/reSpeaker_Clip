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

/* Factory default configuration */
static const struct clip_config factory_config = {
    .bitrate = 24000,
    .complexity = 5,
    .mode = MODE_NORMAL,
    .noise_suppress = 0,
    .chunk_size = 500,
    .auto_delete_days = -1,  /* Disabled by default */
    .agc_target = 0,
    .agc_enabled = false,
    .dereverb_enabled = false,
};

#ifdef CONFIG_SETTINGS
#include <zephyr/settings/settings.h>

/* Settings handler for configuration */
static int config_set_handler(const char *name, size_t len,
                               settings_read_cb read_cb, void *cb_arg)
{
    const char *next;
    int rc;

    if (!name) {
        return -ENOENT;
    }

    /* Parse settings subtree */
    if (!strcmp(name, "bitrate")) {
        uint16_t value;
        rc = read_cb(cb_arg, &value, sizeof(value));
        if (rc >= 0) {
            g_config.bitrate = value;
            return 0;
        }
    } else if (!strcmp(name, "complexity")) {
        uint8_t value;
        rc = read_cb(cb_arg, &value, sizeof(value));
        if (rc >= 0) {
            g_config.complexity = value;
            return 0;
        }
    } else if (!strcmp(name, "mode")) {
        uint8_t value;
        rc = read_cb(cb_arg, &value, sizeof(value));
        if (rc >= 0) {
            g_config.mode = value;
            return 0;
        }
    } else if (!strcmp(name, "noise_suppress")) {
        uint8_t value;
        rc = read_cb(cb_arg, &value, sizeof(value));
        if (rc >= 0) {
            g_config.noise_suppress = value;
            return 0;
        }
    } else if (!strcmp(name, "chunk_size")) {
        uint16_t value;
        rc = read_cb(cb_arg, &value, sizeof(value));
        if (rc >= 0) {
            g_config.chunk_size = value;
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
        LOG_WRN("Settings subsystem init failed: %d, using defaults", err);
        return 0;
    }

    /* Register settings handler */
    err = settings_register(&config_handler);
    if (err) {
        LOG_WRN("Settings register failed: %d, using defaults", err);
        return 0;
    }

    /* Load configuration from NVS */
    err = settings_load();
    if (err) {
        LOG_WRN("Settings load failed: %d, using defaults", err);
        /* Save defaults to NVS */
        config_save();
    }
#else
    LOG_INF("Config initialized with factory defaults (settings disabled)");
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

    err = settings_save_one("config/bitrate", &g_config.bitrate,
                            sizeof(g_config.bitrate));
    if (err) {
        return err;
    }

    err = settings_save_one("config/complexity", &g_config.complexity,
                            sizeof(g_config.complexity));
    if (err) {
        return err;
    }

    err = settings_save_one("config/mode", &g_config.mode,
                            sizeof(g_config.mode));
    if (err) {
        return err;
    }

    err = settings_save_one("config/noise_suppress", &g_config.noise_suppress,
                            sizeof(g_config.noise_suppress));
    if (err) {
        return err;
    }

    err = settings_save_one("config/chunk_size", &g_config.chunk_size,
                            sizeof(g_config.chunk_size));
    if (err) {
        return err;
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

int config_set(uint16_t key, const void *value, size_t len)
{
    int ret = 0;

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
    /* Save to NVS */
    switch (key) {
    case NVS_KEY_BITRATE:
        return settings_save_one("config/bitrate", value, len);
    case NVS_KEY_COMPLEXITY:
        return settings_save_one("config/complexity", value, len);
    case NVS_KEY_MODE:
        return settings_save_one("config/mode", value, len);
    case NVS_KEY_NOISE:
        return settings_save_one("config/noise_suppress", value, len);
    case NVS_KEY_CHUNK_SIZE:
        return settings_save_one("config/chunk_size", value, len);
    case NVS_KEY_AUTODEL:
        return settings_save_one("config/auto_delete_days", value, len);
    case NVS_KEY_AGC_ENABLE:
        return settings_save_one("config/agc_enabled", value, len);
    case NVS_KEY_AGC_TARGET:
        return settings_save_one("config/agc_target", value, len);
    case NVS_KEY_DEREVERB:
        return settings_save_one("config/dereverb_enabled", value, len);
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
