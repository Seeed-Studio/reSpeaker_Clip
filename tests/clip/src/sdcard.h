/*
 * Copyright (c) 2023 Nordic Semiconductor ASA
 *
 * SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
 */

#ifndef SDCARD_H_
#define SDCARD_H_

/**
 * @brief Initialize SD card and register shell commands
 * Shell commands:
 *   sd mount  - Mount SD card
 *   sd umount - Unmount SD card
 *   sd status - Show SD card status
 *
 * @return 0 on success, negative error code on failure
 */
int sdcard_init(void);

#endif /* SDCARD_H_ */
