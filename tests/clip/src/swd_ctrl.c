/*
 * Copyright (c) 2026 Seeed Studio
 *
 * SPDX-License-Identifier: Apache-2.0
 */

/*
 * SWD power-domain control for the production fixture (tests/clip).
 *
 * Problem: on the fixture the J-Link stays wired to the board's SWD
 * pads. In sleep the DAP keeps SWDIO pulled high, back-feeding current
 * into the probe and making sleep-current measurements unstable.
 *
 * The nRF5340 firmware branch of APPROTECT can be re-locked at runtime:
 * writing CTRLAP->APPROTECT.DISABLE = 0 (disabled) cuts the debug port
 * (and the SWDIO drive) from firmware. The lock survives until the next
 * reset — so on the fixture:
 *
 *   swd off    - lock the debug port now (SWDIO goes quiet), then let
 *                the fixture run the sleep measurement
 *   swd on     - re-open the port for further flashing/debug (or just
 *                reset the board; boot re-opens it from UICR, which is
 *                the unlocked default on these units)
 *
 * Both cores need the lock for a full cut; this commands the app core
 * only — the network core's SWD is on separate pads the fixture does
 * not wire (verify with hardware).
 */

#include <zephyr/kernel.h>
#include <zephyr/shell/shell.h>
#include <errno.h>
#include <nrfx.h>

static int cmd_swd_off(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	/* Re-lock the firmware branch: DISABLE=0 means "not disabled",
	 * i.e. APPROTECT active, debug port cut. */
	NRF_CTRLAP_S->APPROTECT.DISABLE = 0;
	shell_print(sh, "debug port locked (SWDIO quiet) until reset");
	return 0;
}

static int cmd_swd_on(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	/* Software-branch unlock value (same one the MDK boot code writes
	 * from UICR on unlocked units). */
	NRF_CTRLAP_S->APPROTECT.DISABLE = 0x5a;
	shell_print(sh, "debug port open");
	return 0;
}

SHELL_STATIC_SUBCMD_SET_CREATE(sub_swd,
	SHELL_CMD_ARG(off, NULL, "Lock debug port (SWDIO quiet) until reset",
		      cmd_swd_off, 1, 0),
	SHELL_CMD_ARG(on, NULL, "Re-open debug port", cmd_swd_on, 1, 0),
	SHELL_SUBCMD_SET_END
);

SHELL_CMD_REGISTER(swd, &sub_swd, "SWD debug port control", NULL);
