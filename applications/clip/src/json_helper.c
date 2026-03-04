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

/* Shared buffer for large JSON responses (e.g., bookmarks with many entries) */
#define JSON_LARGE_BUFFER_SIZE 4096
static char json_large_buffer[JSON_LARGE_BUFFER_SIZE];

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
    int len;
    size_t data_len = strlen(data);

    /* Use large buffer if data exceeds small buffer capacity */
    /* Small buffer: 512 - overhead (~30) = ~480 bytes for data */
    if (data_len > 480) {
        len = snprintf(json_large_buffer, JSON_LARGE_BUFFER_SIZE,
                      "{\"ok\":true,\"data\":%s}", data);
        if (len < 0 || len >= JSON_LARGE_BUFFER_SIZE) {
            return -ENOMEM;
        }

        *output = k_malloc(len + 1);
        if (!*output) {
            return -ENOMEM;
        }
        strcpy(*output, json_large_buffer);
        return 0;
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
