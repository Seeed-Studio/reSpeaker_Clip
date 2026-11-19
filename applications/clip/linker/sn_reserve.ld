/*
 * Copyright (c) 2026 Seeed Studio
 *
 * SPDX-License-Identifier: Apache-2.0
 */

/* Factory SN dual backup — a fixed 4KB region at the app-slot tail
 * (0xFE000), NOT part of the linked image:
 *  - nothing is placed there: the ASSERT below makes the link fail if
 *    the image ever grows past 0xFE000 (no silent overwrite), and the
 *    binary/hex carry no content at this address, so J-Link flashing
 *    and the MCUboot OTA copy never write over what the factory put
 *    there
 *  - the MCUboot slot trailer lives in the last sectors of the slot
 *    (0xFF000+), clear of this region
 *  - both 48-byte records share the one reserved sector; a (re)write
 *    erases the sector and programs both records together
 * Contents are managed at runtime via the internal flash driver (see
 * config.c sn_*); the linker only fixes the address and the bound.
 */

PROVIDE(__sn_backup_start = 0xFE000);
PROVIDE(__sn_backup_end = 0xFE000 + 0x1000);

ASSERT(__sn_backup_start >= __rom_region_end,
       "app image overruns the SN backup region at 0xFE000")
