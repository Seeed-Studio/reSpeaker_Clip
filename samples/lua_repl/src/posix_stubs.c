/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <sys/times.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/types.h>

/*
 * Fake POSIX functions for picolibc compatibility
 * These are minimal stub implementations to satisfy picolibc linking requirements
 */

/* clock() - required by picolibc */
clock_t clock(void)
{
	return k_cyc_to_us_near64(k_cycle_get_64());
}

/* times() - required by picolibc */
clock_t times(struct tms *buf)
{
	if (buf) {
		buf->tms_utime = k_cyc_to_us_near64(k_cycle_get_64());
		buf->tms_stime = 0;
		buf->tms_cutime = 0;
		buf->tms_cstime = 0;
	}
	return 0;
}

/* File operations - minimal stubs for picolibc */
int open(const char *name, int mode, ...)
{
	(void)name;
	(void)mode;
	return -1;
}

int close(int fd)
{
	(void)fd;
	return -1;
}

int unlink(const char *name)
{
	(void)name;
	return -1;
}

int rename(const char *old, const char *new)
{
	(void)old;
	(void)new;
	return -1;
}

ssize_t read(int fd, void *buf, size_t count)
{
	(void)fd;
	(void)buf;
	(void)count;
	return -1;
}

ssize_t write(int fd, const void *buf, size_t count)
{
	(void)fd;
	(void)buf;
	(void)count;
	return -1;
}

off_t lseek(int fd, off_t offset, int whence)
{
	(void)fd;
	(void)offset;
	(void)whence;
	return -1;
}
