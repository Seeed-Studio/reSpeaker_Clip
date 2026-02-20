/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef JSON_HELPER_H
#define JSON_HELPER_H

#include <stdint.h>
#include <stdbool.h>

/**
 * @brief Create success JSON response
 *
 * @param data   Data object (can be NULL for no data)
 * @param output Output JSON string (must be freed by caller)
 * @return 0 on success, negative error code on failure
 */
int json_create_success(const char *data, char **output);

/**
 * @brief Create error JSON response
 *
 * @param error  Error message
 * @param output Output JSON string (must be freed by caller)
 * @return 0 on success, negative error code on failure
 */
int json_create_error(const char *error, char **output);

/**
 * @brief Create JSON string with key-value pairs
 *
 * @param key    Key name
 * @param value  Value (as string)
 * @param output Output JSON string (must be freed by caller)
 * @return 0 on success, negative error code on failure
 */
int json_create_kv(const char *key, const char *value, char **output);

/**
 * @brief Free JSON string allocated by json helpers
 *
 * @param json String to free
 */
void json_free(char *json);

/**
 * @brief Build simple JSON object from key-value pairs
 *
 * @param ok     Success flag
 * @param key    Key name (can be NULL)
 * @param value  Value (can be NULL)
 * @param error  Error message (can be NULL)
 * @param output Output JSON string (must be freed by caller)
 * @return 0 on success, negative error code on failure
 */
int json_build_response(bool ok, const char *key, const char *value,
                       const char *error, char **output);

#endif /* JSON_HELPER_H */
