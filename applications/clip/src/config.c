/*
 * Copyright (c) 2024 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/settings/settings.h>
#include <string.h>
#include "config.h"

/* Factory default configuration */
static const struct clip_config factory_config = {
    .bitrate = 24000,
    .complexity = 5,
    .mode = MODE_NORMAL,
    .noise_suppress = 0,
    .chunk_size = 500,
};

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

int config_init(void)
{
    int err;

    /* Initialize settings subsystem */
    err = settings_subsys_init();
    if (err) {
        printk("Settings subsystem init failed: %d\n", err);
        /* Continue with defaults */
        memcpy(&g_config, &factory_config, sizeof(g_config));
        return 0;
    }

    /* Register settings handler */
    err = settings_register(&config_handler);
    if (err) {
        printk("Settings register failed: %d\n", err);
        memcpy(&g_config, &factory_config, sizeof(g_config));
        return 0;
    }

    /* Load configuration from NVS */
    err = settings_load();
    if (err) {
        printk("Settings load failed: %d, using defaults\n", err);
        memcpy(&g_config, &factory_config, sizeof(g_config));
        /* Save defaults to NVS */
        config_save();
    }

    return 0;
}

int config_load(void)
{
    return settings_load();
}

int config_save(void)
{
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
    switch (key) {
    case NVS_KEY_BITRATE:
        if (len == sizeof(uint16_t)) {
            g_config.bitrate = *(const uint16_t *)value;
            return settings_save_one("config/bitrate", value, len);
        }
        break;
    case NVS_KEY_COMPLEXITY:
        if (len == sizeof(uint8_t)) {
            g_config.complexity = *(const uint8_t *)value;
            return settings_save_one("config/complexity", value, len);
        }
        break;
    case NVS_KEY_MODE:
        if (len == sizeof(uint8_t)) {
            g_config.mode = *(const uint8_t *)value;
            return settings_save_one("config/mode", value, len);
        }
        break;
    case NVS_KEY_NOISE:
        if (len == sizeof(uint8_t)) {
            g_config.noise_suppress = *(const uint8_t *)value;
            return settings_save_one("config/noise_suppress", value, len);
        }
        break;
    case NVS_KEY_CHUNK_SIZE:
        if (len == sizeof(uint16_t)) {
            g_config.chunk_size = *(const uint16_t *)value;
            return settings_save_one("config/chunk_size", value, len);
        }
        break;
    default:
        return -EINVAL;
    }

    return -EINVAL;
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
    default:
        return -EINVAL;
    }

    return -EINVAL;
}
