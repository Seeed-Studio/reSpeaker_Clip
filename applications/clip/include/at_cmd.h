/*
 * Copyright (c) 2024 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef AT_CMD_H
#define AT_CMD_H

/**
 * @brief AT command types (bitmask values for allowed_types checking)
 */
enum at_cmd_type {
    AT_CMD_EXEC = 0x01,    /* Execute without parameters: AT+XX */
    AT_CMD_SET  = 0x02,    /* Set parameter: AT+XX=<value> */
    AT_CMD_GET  = 0x04,    /* Query parameter: AT+XX? */
};

/**
 * @brief Parsed AT command
 */
struct at_command {
    enum at_cmd_type type;
    char name[32];      /* Command name (e.g., "GSTAT", "BITRATE") */
    char *value;        /* Parameter value (for SET commands) */
};

/**
 * @brief Initialize AT command parser
 *
 * @return 0 on success, negative error code on failure
 */
int at_cmd_init(void);

/**
 * @brief Parse AT command string
 *
 * @param cmd_str Command string to parse
 * @param cmd Output parsed command structure
 * @return 0 on success, negative error code on failure
 */
int at_cmd_parse(const char *cmd_str, struct at_command *cmd);

/**
 * @brief Execute AT command
 *
 * @param cmd Parsed command to execute
 * @param response Output JSON response string (must be freed by caller)
 * @return 0 on success, negative error code on failure
 */
int at_cmd_execute(const struct at_command *cmd, char **response);

/**
 * @brief Cleanup parsed command
 *
 * @param cmd Command to cleanup
 */
void at_cmd_cleanup(struct at_command *cmd);

#endif /* AT_CMD_H */
