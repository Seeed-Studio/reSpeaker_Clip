/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/sys/util.h>
#include <zephyr/logging/log.h>
#include <string.h>
#include <stdio.h>
#include "json_helper.h"

LOG_MODULE_REGISTER(json_helper, LOG_LEVEL_DBG);

/* Simple JSON builder - minimal implementation for our needs */

/* Stack buffer for JSON building - sized for paginated responses
 * No static buffer needed - all responses fit in 1KB with pagination */
#define JSON_STACK_BUFFER_SIZE 1024

int json_build_response(bool ok, const char *key, const char *value,
                       const char *error, char **output)
{
    char buffer[JSON_STACK_BUFFER_SIZE];
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
        LOG_ERR("JSON alloc failed");
        return -ENOMEM;
    }
    strcpy(*output, buffer);
    LOG_DBG("JSON: %s", *output);
    return 0;
}

int json_create_success(const char *data, char **output)
{
    int len;
    size_t data_len = strlen(data);

    /* With pagination, all data should fit in 1KB
     * If data is too large, return error instead of using separate buffer */
    if (data_len > JSON_STACK_BUFFER_SIZE - 50) {
        LOG_WRN("JSON too large: %u bytes", data_len);
        return -ENOMEM;
    }

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

/**
 * @brief Parse JSON string to extract field value
 *
 * @param json JSON string to parse
 * @param key Field name to extract
 * @param output Output buffer for value
 * @param size Size of output buffer
 * @return true if field found, false otherwise
 */
bool json_parse_helper(const char *json, const char *key, char *output, size_t size)
{
	char search[64];
	int len;

	if (!json || !key || !output || size == 0) {
		return false;
	}

	/* Search for "key":"value" pattern */
	len = snprintf(search, sizeof(search), "\"%s\":\"", key);
	if (len < 0 || len >= sizeof(search)) {
		return false;
	}

	const char *pos = strstr(json, search);
	if (!pos) {
		return false;
	}

	pos += len;  /* Skip "key":" */

	/* Find closing quote */
	const char *end = strchr(pos, '"');
	if (!end) {
		return false;
	}

	/* Copy value to output */
	size_t copy_len = end - pos;
	if (copy_len >= size) {
		copy_len = size - 1;
	}
	memcpy(output, pos, copy_len);
	output[copy_len] = '\0';

	return true;
}
