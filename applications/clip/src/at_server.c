/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <string.h>
#include <stdio.h>
#include <ctype.h>
#include "at_server.h"
#include "transport.h"
#include "transport_udp.h"
#include "usb_cdc.h"

LOG_MODULE_REGISTER(at_server, LOG_LEVEL_WRN); /* chatty plumbing logs */

/* Command queue item */
struct at_queue_item {
    uint8_t data[CONFIG_CLIP_AT_MAX_CMD_LEN];
    uint16_t len;
    uint8_t transport_type;
};

/* AT Server Context */
static struct {
    struct k_msgq msgq;
    char msgq_buffer[sizeof(struct at_queue_item) * CONFIG_CLIP_AT_SERVER_QUEUE_SIZE];
    struct k_thread thread;
    k_thread_stack_t stack_area[CONFIG_CLIP_AT_SERVER_STACK_SIZE];
    bool running;
    char response_buffer[CONFIG_CLIP_AT_MAX_RESPONSE_LEN];
} at_ctx = {
    .running = false,
};

/* Command registry */
static struct {
    const struct at_command *cmds[32];
    int count;
} cmd_registry = { .count = 0 };

/* Forward declarations */
static void at_server_thread_func(void *p1, void *p2, void *p3);

/* Register an AT command */
int at_server_register_cmd(const struct at_command *cmd)
{
    if (!cmd || !cmd->name || !cmd->handler) {
        return -EINVAL;
    }

    if (cmd_registry.count >= 32) {
        return -ENOMEM;
    }

    cmd_registry.cmds[cmd_registry.count++] = cmd;
    LOG_DBG("Registered command: %s", cmd->name);
    return 0;
}

/* Skip whitespace */
static const char *skip_whitespace(const char *p)
{
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') {
        p++;
    }
    return p;
}

/* Parse AT command line */
static int parse_command(const char *input, size_t len,
                        char *cmd_name, char *args, uint8_t *type)
{
    const char *p = input;
    const char *end = input + len;

    /* Skip "AT" prefix */
    if (len < 2 || p[0] != 'A' || p[1] != 'T') {
        return AT_ERR_PARSE;
    }
    p += 2;

    /* Skip whitespace after AT */
    p = skip_whitespace(p);
    if (p >= end) {
        return AT_ERR_PARSE;
    }

    /* Check for + prefix */
    if (*p == '+') {
        p++;
    }

    /* Extract command name */
    const char *name_start = p;
    while (p < end && *p != '=' && *p != '?' && *p != ' ' && *p != '\t' &&
           *p != '\r' && *p != '\n') {
        p++;
    }

    size_t name_len = p - name_start;
    if (name_len == 0 || name_len >= 32) {
        return AT_ERR_PARSE;
    }

    memcpy(cmd_name, name_start, name_len);
    cmd_name[name_len] = '\0';

    /* Skip whitespace */
    p = skip_whitespace(p);

    /* Determine command type and extract arguments */
    *type = AT_CMD_TYPE_EXEC;

    if (p < end && *p == '=') {
        p++;  /* Skip '=' */
        p = skip_whitespace(p);

        if (p < end && *p == '?') {
            *type = AT_CMD_TYPE_TEST;  /* AT+CMD=? */
        } else {
            *type = AT_CMD_TYPE_SET;   /* AT+CMD=... */
            /* Copy arguments */
            const char *arg_start = p;
            while (p < end && *p != '\r' && *p != '\n') {
                p++;
            }
            size_t arg_len = p - arg_start;
            memcpy(args, arg_start, arg_len);
            args[arg_len] = '\0';
        }
    } else if (p < end && *p == '?') {
        p++;  /* Skip '?' */
        p = skip_whitespace(p);

        /* Check if there are arguments after '?' (e.g., AT+LIST?2&10) */
        if (p < end && *p != '\r' && *p != '\n') {
            *type = AT_CMD_TYPE_SET;   /* AT+CMD?args... */
            /* Copy arguments including '?' */
            const char *arg_start = p - 1;  /* Include '?' in args */
            while (p < end && *p != '\r' && *p != '\n') {
                p++;
            }
            size_t arg_len = p - arg_start;
            memcpy(args, arg_start, arg_len);
            args[arg_len] = '\0';
        } else {
            *type = AT_CMD_TYPE_READ;   /* AT+CMD? (no args) */
        }
    }

    return AT_OK;
}

/* Create JSON response */
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

    /* Always add closing brace and newline, ensure space */
    if (n + 2 <= len) {
        response[n] = '}';
        response[n + 1] = '\n';
        return n + 2;
    }

    return AT_ERR_NOMEM;
}

/* Process single AT command */
static void process_command(struct at_queue_item *item)
{
    char cmd_name[32] = {0};
    char args[256] = {0};
    uint8_t cmd_type = AT_CMD_TYPE_EXEC;
    int ret;

    /* Helper to send response via appropriate transport */
    #define SEND_RESPONSE() do { \
        at_ctx.response_buffer[sizeof(at_ctx.response_buffer) - 1] = '\0'; \
        size_t resp_len = strnlen(at_ctx.response_buffer, sizeof(at_ctx.response_buffer)); \
        if (item->transport_type == TRANSPORT_TYPE_USB) { \
            usb_cdc_send_response((uint8_t *)at_ctx.response_buffer, resp_len); \
        } else if (item->transport_type == TRANSPORT_TYPE_UDP) { \
            transport_udp_send_response((uint8_t *)at_ctx.response_buffer, resp_len); \
        } else { \
            transport_send_to(item->transport_type, (uint8_t *)at_ctx.response_buffer, resp_len); \
        } \
    } while(0)

    /* Clear response buffer */
    memset(at_ctx.response_buffer, 0, sizeof(at_ctx.response_buffer));

    /* Parse command */
    ret = parse_command((const char *)item->data, item->len, cmd_name, args, &cmd_type);
    if (ret != AT_OK) {
        create_json_response(false, at_server_err_msg(ret), NULL, at_ctx.response_buffer, sizeof(at_ctx.response_buffer));
        SEND_RESPONSE();
        return;
    }

    LOG_INF("AT command: %s type=%d args=%s", cmd_name, cmd_type, args);

    /* Find command handler */
    struct at_cmd_ctx ctx = {
        .name = cmd_name,
        .type = cmd_type,
        .args = args,
        .transport_type = item->transport_type,
    };

    for (int i = 0; i < cmd_registry.count; i++) {
        const struct at_command *cmd = cmd_registry.cmds[i];

        if (strcmp(cmd->name, cmd_name) == 0) {
                    /* Check if operation is supported */
            switch (cmd_type) {
            case AT_CMD_TYPE_SET:
                if (!(cmd->flags & AT_CMD_SET)) {
                    create_json_response(false, "SET not supported", NULL, at_ctx.response_buffer, sizeof(at_ctx.response_buffer));
                    SEND_RESPONSE();
                    return;
                }
                break;
            case AT_CMD_TYPE_TEST:
            case AT_CMD_TYPE_READ:
                if (!(cmd->flags & AT_CMD_QUERY)) {
                    create_json_response(false, "QUERY not supported", NULL, at_ctx.response_buffer, sizeof(at_ctx.response_buffer));
                    SEND_RESPONSE();
                    return;
                }
                break;
            case AT_CMD_TYPE_EXEC:
                if (!(cmd->flags & AT_CMD_EXEC)) {
                    create_json_response(false, "EXEC not supported", NULL, at_ctx.response_buffer, sizeof(at_ctx.response_buffer));
                    SEND_RESPONSE();
                    return;
                }
                break;
            }

            /* Call handler */
            ret = cmd->handler(&ctx, at_ctx.response_buffer, sizeof(at_ctx.response_buffer));

            if (ret < 0) {
                /* Handler returned error, create error response */
                create_json_response(false, at_server_err_msg(-ret), NULL, at_ctx.response_buffer, sizeof(at_ctx.response_buffer));
            }

            /* Ensure null-termination and send response */
            LOG_INF("AT Response [%s]: %s", cmd_name, at_ctx.response_buffer);
            SEND_RESPONSE();
            return;
        }
    }

    /* Command not found */
    create_json_response(false, "Unknown command", NULL, at_ctx.response_buffer, sizeof(at_ctx.response_buffer));
    SEND_RESPONSE();
}

/* AT Server Thread */
static void at_server_thread_func(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1);
    ARG_UNUSED(p2);
    ARG_UNUSED(p3);

    LOG_INF("AT Server thread started");

    struct at_queue_item item;
    while (at_ctx.running) {
        /* Wait for command (message is copied into item) */
        k_msgq_get(&at_ctx.msgq, &item, K_FOREVER);
        process_command(&item);
    }

    LOG_INF("AT Server thread stopped");
}

/* Initialize AT server */
int at_server_init(void)
{
    /* Initialize message queue */
    k_msgq_init(&at_ctx.msgq,
                at_ctx.msgq_buffer,
                sizeof(struct at_queue_item),
                CONFIG_CLIP_AT_SERVER_QUEUE_SIZE);

    /* Start thread */
    at_ctx.running = true;
    k_thread_create(&at_ctx.thread, at_ctx.stack_area, K_KERNEL_STACK_SIZEOF(at_ctx.stack_area),
                   at_server_thread_func, NULL, NULL, NULL,
                   CONFIG_CLIP_AT_SERVER_PRIORITY, 0, K_NO_WAIT);
    k_thread_name_set(&at_ctx.thread, "at_server");

    LOG_INF("AT Server initialized");
    return 0;
}

/* Submit AT command to server queue */
int at_server_submit_cmd(const uint8_t *data, uint16_t len, uint8_t transport_type)
{
    if (!data || len == 0 || len >= CONFIG_CLIP_AT_MAX_CMD_LEN) {
        return -EINVAL;
    }

    struct at_queue_item item = {
        .len = len,
        .transport_type = transport_type,
    };
    memcpy(item.data, data, len);

    /* Submit to queue (message is copied) */
    return k_msgq_put(&at_ctx.msgq, &item, K_NO_WAIT);
}

/* Get error message */
const char *at_server_err_msg(uint8_t err_code)
{
    switch (err_code) {
    case AT_OK:              return "OK";
    case AT_ERR_PARSE:       return "Parse error";
    case AT_ERR_PARAM:       return "Invalid parameter";
    case AT_ERR_STATE:       return "Invalid state";
    case AT_ERR_NOMEM:       return "Out of memory";
    case AT_ERR_STORAGE:     return "Storage error";
    case AT_ERR_NETWORK:     return "Network error";
    case AT_ERR_TIMEOUT:     return "Timeout";
    case AT_ERR_NOT_FOUND:   return "Not found";
    case AT_ERR_NOT_ALLOWED: return "Not allowed";
    default:                 return "Unknown error";
    }
}
