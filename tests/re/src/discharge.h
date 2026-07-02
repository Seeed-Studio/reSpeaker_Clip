/*
 * Copyright (c) 2026 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
 *
 * Battery discharge/charge cycle test. Discharges the cell via the WiFi TX
 * load down to 3.35 V, then charges to 4.12 V, then repeats. The OLED always
 * shows the current %, voltage, and charge/discharge state.
 */

#ifndef DISCHARGE_H
#define DISCHARGE_H

/**
 * @brief Run the battery discharge/charge cycle test (blocking, never returns).
 *
 * Requires WiFi AP + discharge TX load already started.
 */
void discharge_run(void);

#endif /* DISCHARGE_H */
