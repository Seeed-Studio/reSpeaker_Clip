/*
 * Copyright (c) 2023 Nordic Semiconductor ASA
 *
 * SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
 */

#ifndef IMU_H
#define IMU_H

#include <zephyr/kernel.h>
#include <stdbool.h>

/**
 * @brief IMU sensor data structure
 */
struct imu_data {
	int16_t accel_x;  /* Accelerometer X (raw) */
	int16_t accel_y;  /* Accelerometer Y (raw) */
	int16_t accel_z;  /* Accelerometer Z (raw) */
	int16_t gyro_x;   /* Gyroscope X (raw) */
	int16_t gyro_y;   /* Gyroscope Y (raw) */
	int16_t gyro_z;   /* Gyroscope Z (raw) */
};

/**
 * @brief Initialize IMU (LSM6DS3)
 * @return 0 on success, negative errno on failure
 *
 * Powers on the IMU and configures it for operation.
 */
int imu_init(void);

/**
 * @brief Read IMU sensor data
 * @param data Output sensor data structure
 * @return 0 on success, negative errno on failure
 */
int imu_read(struct imu_data *data);

/**
 * @brief Power off IMU
 */
void imu_deinit(void);

#endif /* IMU_H */
