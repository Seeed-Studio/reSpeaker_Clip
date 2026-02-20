/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/sys/util.h>
#include <string.h>
#include <stdio.h>
#include "json_helper.h"

/* Simple JSON builder - minimal implementation for our needs */

int json_build_response(bool ok, const char *key, const char *value,
                       const char *error, char **output)
{
    char buffer[512];
    int len = 0;

    if (ok) {
        if (key && value) {
            len = snprintf(buffer, sizeof(buffer),
                          "{\"ok\":true,\"%s\":%s}",
                          key, value);
        } else if (key && !value) {
            len = snprintf(buffer, sizeof(buffer),
                          "{\"ok\":true,\"%s\":null}",
                          key);
        } else {
            len = snprintf(buffer, sizeof(buffer),
                          "{\"ok\":true}");
        }
    } else {
        if (error) {
            len = snprintf(buffer, sizeof(buffer),
                          "{\"ok\":false,\"error\":\"%s\"}",
                          error);
        } else {
            len = snprintf(buffer, sizeof(buffer),
                          "{\"ok\":false}");
        }
    }

    if (len < 0 || len >= sizeof(buffer)) {
        return -ENOMEM;
    }

    *output = k_malloc(len + 1);
    if (!*output) {
        return -ENOMEM;
    }
    strcpy(*output, buffer);

    return 0;
}

int json_create_success(const char *data, char **output)
{
    return json_build_response(true, "data", data, NULL, output);
}

int json_create_error(const char *error, char **output)
{
    return json_build_response(false, NULL, NULL, error, output);
}

int json_create_kv(const char *key, const char *value, char **output)
{
    return json_build_response(true, key, value, NULL, output);
}

void json_free(char *json)
{
    if (json) {
        k_free(json);
    }
}
