/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/logging/log.h>
#include <stdio.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

LOG_MODULE_REGISTER(lua_repl, LOG_LEVEL_INF);

#define INPUT_BUFFER_SIZE 256
#define REPL_STACK_SIZE 8192

/* Forward declarations */
static void lua_repl_thread(void *, void *, void *);

/* Thread stack */
static K_THREAD_DEFINE(lua_thread, REPL_STACK_SIZE,
		       lua_repl_thread, NULL, NULL, NULL,
		       5, 0, 0);

/* UART device */
static const struct device *uart_dev;

/* Lua state */
static lua_State *g_L;

/* Simple line input - returns length (excluding null terminator) */
static int read_line(char *buf, int max_len)
{
	uint8_t c;
	int pos = 0;

	printk("> ");

	while (pos < max_len - 1) {
		int ret = uart_poll_in(uart_dev, &c);

		if (ret == 0) {
			/* Enter key */
			if (c == '\r' || c == '\n') {
				printk("\n");
				buf[pos] = '\0';

				/* Consume LF if we got CR */
				if (c == '\r') {
					uart_poll_in(uart_dev, &c);
				}
				return pos;
			}
			/* Backspace */
			else if (c == '\b' || c == 0x7F) {
				if (pos > 0) {
					pos--;
					printk("\b \b");
				}
			}
			/* Printable character */
			else if (c >= 32 && c < 127) {
				buf[pos++] = c;
				printk("%c", c);
			}
		}

		k_yield();
	}

	buf[pos] = '\0';
	return pos;
}

/* Execute the buffer content */
static void execute_buffer(const char *buf, size_t len)
{
	int result = luaL_loadbuffer(g_L, buf, len, "stdin");

	if (result != LUA_OK) {
		const char *err = lua_tostring(g_L, -1);
		printk("Error: %s\n", err);
		lua_pop(g_L, 1);
		return;
	}

	result = lua_pcall(g_L, 0, LUA_MULTRET, 0);

	if (result != LUA_OK) {
		const char *err = lua_tostring(g_L, -1);
		printk("Error: %s\n", err);
		lua_pop(g_L, 1);
		return;
	}

	/* Print results */
	int n = lua_gettop(g_L);
	for (int i = 1; i <= n; i++) {
		if (lua_isstring(g_L, i)) {
			printk("%s\n", lua_tostring(g_L, i));
		} else if (lua_isnumber(g_L, i)) {
			printk("%g\n", lua_tonumber(g_L, i));
		} else if (lua_isboolean(g_L, i)) {
			printk("%s\n", lua_toboolean(g_L, i) ? "true" : "false");
		} else if (lua_isnil(g_L, i)) {
			printk("nil\n");
		} else {
			printk("<%s>\n", lua_typename(g_L, lua_type(g_L, i)));
		}
	}
	lua_settop(g_L, 0);
}

/* REPL main function */
static void lua_repl_thread(void *p1, void *p2, void *p3)
{
	char line[INPUT_BUFFER_SIZE];
	char buffer[INPUT_BUFFER_SIZE * 2];
	size_t pos = 0;

	ARG_UNUSED(p1);
	ARG_UNUSED(p2);
	ARG_UNUSED(p3);

	k_sleep(K_MSEC(500));

	printk("\n========================================\n");
	printk("Lua 5.5.0 REPL\n");
	printk("========================================\n");
	printk("Enter Lua code, empty line to execute.\n");
	printk("========================================\n\n");

	while (1) {
		/* Read line */
		int len = read_line(line, sizeof(line));

		/* Handle empty line - execute buffer */
		if (len == 0) {
			if (pos > 0) {
				buffer[pos] = '\0';
				execute_buffer(buffer, pos);
				pos = 0;
			}
			continue;
		}

		/* Add to buffer */
		size_t line_len = strlen(line);
		if (pos + line_len + 2 < sizeof(buffer)) {
			strcpy(buffer + pos, line);
			pos += line_len;
			buffer[pos++] = '\n';

			/* Try to load and see if it's complete */
			int result = luaL_loadbuffer(g_L, buffer, pos, "stdin");

			if (result == LUA_OK) {
				lua_pop(g_L, 1);  /* Remove loaded function from stack */
				/* Complete statement, execute it */
				execute_buffer(buffer, pos);
				pos = 0;
			} else if (result == LUA_ERRSYNTAX) {
				const char *err = lua_tostring(g_L, -1);
				/* Check for incomplete input (ends with <eof>) */
				if (err != NULL && strstr(err, "<eof>") != NULL) {
					/* Incomplete, show continuation prompt */
					printk(">> ");
				} else {
					/* Real syntax error */
					printk("Error: %s\n", err);
					pos = 0;
				}
				lua_pop(g_L, 1);  /* Remove error message from stack */
			} else {
				printk("Error: %d\n", result);
				lua_pop(g_L, 1);  /* Remove error from stack */
				pos = 0;
			}
		} else {
			printk("Input too long\n");
			pos = 0;
		}
	}
}

/* Print function for Lua */
static int lua_print(lua_State *L)
{
	int n = lua_gettop(L);
	int i;

	for (i = 1; i <= n; i++) {
		if (lua_isstring(L, i)) {
			printk("%s", lua_tostring(L, i));
		} else if (lua_isnumber(L, i)) {
			printk("%g", lua_tonumber(L, i));
		} else if (lua_isboolean(L, i)) {
			printk("%s", lua_toboolean(L, i) ? "true" : "false");
		} else if (lua_isnil(L, i)) {
			printk("nil");
		}

		if (i < n) {
			printk("\t");
		}
	}
	printk("\n");
	return 0;
}

int main(void)
{
	LOG_INF("Lua REPL Sample");

	uart_dev = DEVICE_DT_GET(DT_CHOSEN(zephyr_console));

	if (!device_is_ready(uart_dev)) {
		LOG_ERR("UART device not ready");
		return -ENODEV;
	}

	/* Create Lua state */
	g_L = luaL_newstate();
	if (!g_L) {
		LOG_ERR("Failed to create Lua state");
		return -1;
	}

	luaL_openlibs(g_L);
	lua_register(g_L, "print", lua_print);

	LOG_INF("Lua 5.5.0 initialized");
	printk("Lua REPL starting...\n\n");

	/* Thread starts automatically */
	return 0;
}
