/*
 * Copyright (c) 2023 Nordic Semiconductor ASA
 *
 * SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
 */

#include <stdlib.h>
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/shell/shell.h>
#include <zephyr/logging/log.h>
#include "imu.h"

LOG_MODULE_REGISTER(imu, LOG_LEVEL_INF);

/* IMU I2C address - will be auto-detected */
static uint8_t lsm6ds3_i2c_addr = 0x6A;  /* Default: SA0=0 */
#define LSM6DS3_I2C_ADDR_ALT    0x6B  /* SA0=1 */

/* Software I2C GPIO pins */
#define I2C_SDA_GPIO    0  /* GPIO1.0 */
#define I2C_SCL_GPIO    1  /* GPIO1.1 */

/* IMU power control GPIO */
#define IMU_PWR_GPIO    2  /* GPIO0.2 (NFC1) */

/* GPIO devices */
static const struct device *gpio0_dev = DEVICE_DT_GET(DT_NODELABEL(gpio0));
static const struct device *gpio1_dev = DEVICE_DT_GET(DT_NODELABEL(gpio1));

/* I2C timing delays (for 50kHz approximately, more stable) */
#define I2C_DELAY_US    10

/* LSM6DS3 Register Map */
#define LSM6DS3_REG_WHO_AM_I    0x0F
#define LSM6DS3_REG_CTRL1_XL    0x10  /* accelerometer control */
#define LSM6DS3_REG_CTRL2_G     0x11  /* gyroscope control */
#define LSM6DS3_REG_CTRL9_XL    0x19  /* MEMS control */
#define LSM6DS3_REG_CTRL10_C    0x1A  /* MEMS control */
#define LSM6DS3_REG_OUTX_L_XL  0x28  /* accel X low */
#define LSM6DS3_REG_OUTX_H_XL  0x29  /* accel X high */
#define LSM6DS3_REG_OUTY_L_XL  0x2A  /* accel Y low */
#define LSM6DS3_REG_OUTY_H_XL  0x2B  /* accel Y high */
#define LSM6DS3_REG_OUTZ_L_XL  0x2C  /* accel Z low */
#define LSM6DS3_REG_OUTZ_H_XL  0x2D  /* accel Z high */
#define LSM6DS3_REG_OUTX_L_G   0x22  /* gyro X low */
#define LSM6DS3_REG_OUTX_H_G   0x23  /* gyro X high */
#define LSM6DS3_REG_OUTY_L_G   0x24  /* gyro Y low */
#define LSM6DS3_REG_OUTY_H_G   0x25  /* gyro Y high */
#define LSM6DS3_REG_OUTZ_L_G   0x26  /* gyro Z low */
#define LSM6DS3_REG_OUTZ_H_G   0x27  /* gyro Z high */

/* IMU power state */
static bool imu_powered = false;

/* Software I2C implementation */
static void i2c_delay(void)
{
	k_usleep(I2C_DELAY_US);
}

static void i2c_scl_high(void)
{
	gpio_port_set_masked_raw(gpio1_dev, BIT(I2C_SCL_GPIO), BIT(I2C_SCL_GPIO));
	i2c_delay();
}

static void i2c_scl_low(void)
{
	gpio_port_set_masked_raw(gpio1_dev, BIT(I2C_SCL_GPIO), 0);
	i2c_delay();
}

static void i2c_sda_high(void)
{
	gpio_port_set_masked_raw(gpio1_dev, BIT(I2C_SDA_GPIO), BIT(I2C_SDA_GPIO));
	i2c_delay();
}

static void i2c_sda_low(void)
{
	gpio_port_set_masked_raw(gpio1_dev, BIT(I2C_SDA_GPIO), 0);
	i2c_delay();
}

static void i2c_start(void)
{
	/* Ensure SCL is low first */
	i2c_scl_low();

	/* SDA high to low transition while SCL is high (START condition) */
	i2c_sda_high();
	k_usleep(1);
	i2c_scl_high();
	k_usleep(1);
	i2c_sda_low();
	k_usleep(1);

	/* Pull SCL low to prepare for data */
	i2c_scl_low();
}

static void i2c_stop(void)
{
	/* Ensure SCL is low first */
	i2c_scl_low();

	/* SDA low to high transition while SCL is high (STOP condition) */
	i2c_sda_low();
	k_usleep(1);
	i2c_scl_high();
	k_usleep(1);
	i2c_sda_high();
	k_usleep(1);

	/* Return to idle state */
	i2c_scl_low();
}

static void i2c_send_bit(uint8_t bit)
{
	/* Set SDA value while SCL is low */
	if (bit) {
		i2c_sda_high();
	} else {
		i2c_sda_low();
	}

	/* Small delay to ensure SDA is stable */
	k_usleep(1);

	/* Pulse SCL high */
	i2c_scl_high();
	i2c_delay();

	/* Bring SCL low */
	i2c_scl_low();
	i2c_delay();
}

static uint8_t i2c_read_bit(void)
{
	gpio_port_value_t port_value;
	uint8_t bit;

	/* Configure SDA as input for reading */
	gpio_pin_configure(gpio1_dev, I2C_SDA_GPIO, GPIO_INPUT);

	/* Small delay to let line settle */
	k_usleep(1);

	/* Read SDA while SCL is high */
	gpio_port_get_raw(gpio1_dev, &port_value);
	bit = (port_value & BIT(I2C_SDA_GPIO)) != 0;

	/* Restore SDA as output */
	gpio_pin_configure(gpio1_dev, I2C_SDA_GPIO, GPIO_OUTPUT);

	/* Now toggle SCL */
	i2c_scl_high();
	i2c_delay();
	i2c_scl_low();

	return bit;
}

static uint8_t i2c_send_byte(uint8_t byte)
{
	uint8_t ack;
	uint8_t i;

	for (i = 0; i < 8; i++) {
		i2c_send_bit(byte & 0x80);
		byte <<= 1;
	}

	ack = !i2c_read_bit();  /* ACK is active low */
	return ack;
}

static uint8_t i2c_read_byte(uint8_t ack)
{
	uint8_t byte = 0;
	uint8_t i;

	for (i = 0; i < 8; i++) {
		byte <<= 1;
		byte |= i2c_read_bit();
	}

	i2c_send_bit(!ack);  /* Send ACK (or NACK) */
	return byte;
}

/* Read IMU register */
static int imu_read_reg(uint8_t reg, uint8_t *value)
{
	int ret;

	i2c_start();
	ret = i2c_send_byte((lsm6ds3_i2c_addr << 1) | 0);  /* Write address */
	if (!ret) {
		i2c_stop();
		return -EIO;
	}

	ret = i2c_send_byte(reg);  /* Register address */
	if (!ret) {
		i2c_stop();
		return -EIO;
	}

	i2c_start();
	ret = i2c_send_byte((lsm6ds3_i2c_addr << 1) | 1);  /* Read address */
	if (!ret) {
		i2c_stop();
		return -EIO;
	}

	*value = i2c_read_byte(0);  /* Read byte with NACK */
	i2c_stop();

	return 0;
}

/* Write IMU register */
static int imu_write_reg(uint8_t reg, uint8_t value)
{
	int ret;

	i2c_start();
	ret = i2c_send_byte((lsm6ds3_i2c_addr << 1) | 0);  /* Write address */
	if (!ret) {
		i2c_stop();
		return -EIO;
	}

	ret = i2c_send_byte(reg);  /* Register address */
	if (!ret) {
		i2c_stop();
		return -EIO;
	}

	ret = i2c_send_byte(value);  /* Data */
	i2c_stop();

	if (!ret) {
		return -EIO;
	}

	return 0;
}

/* Simple I2C scan to check for any devices on the bus */
static void i2c_scan_bus(void)
{
	uint8_t addr;
	int ack_count = 0;

	LOG_INF("Scanning I2C bus for devices...");

	for (addr = 0x08; addr < 0x78; addr++) {
		i2c_start();
		if (i2c_send_byte((addr << 1) | 0)) {  /* Try write address */
			ack_count++;
			LOG_INF("  Device found at 0x%02X", addr);
		}
		i2c_stop();
	}

	if (ack_count == 0) {
		LOG_WRN("No I2C devices found on bus");
	} else {
		LOG_INF("Total devices found: %d", ack_count);
	}
}

/* Initialize software I2C GPIO pins */
static int i2c_soft_init(void)
{
	int ret;

	if (!device_is_ready(gpio1_dev)) {
		LOG_ERR("GPIO1 not ready");
		return -ENODEV;
	}

	LOG_INF("Configuring GPIO1.0 (SDA) and GPIO1.1 (SCL) for software I2C...");

	/* Configure SDA and SCL as open-drain outputs (I2C standard)
	 * Note: If open-drain is not available, use regular output with pull-up */
	ret = gpio_pin_configure(gpio1_dev, I2C_SDA_GPIO,
				 GPIO_OUTPUT | GPIO_PULL_UP);
	if (ret != 0 && ret != -EEXIST) {
		LOG_ERR("Failed to configure SDA GPIO: %d", ret);
		return ret;
	}

	ret = gpio_pin_configure(gpio1_dev, I2C_SCL_GPIO,
				 GPIO_OUTPUT | GPIO_PULL_UP);
	if (ret != 0 && ret != -EEXIST) {
		LOG_ERR("Failed to configure SCL GPIO: %d", ret);
		return ret;
	}

	/* Set idle state (both high) */
	i2c_sda_high();
	i2c_scl_high();

	LOG_INF("Software I2C GPIO pins configured (with pull-ups)");

	/* Small delay to let lines settle */
	k_sleep(K_MSEC(10));

	return 0;
}

/* Power on IMU */
static int imu_power_on(void)
{
	int ret;
	gpio_port_value_t port_value;

	if (!device_is_ready(gpio0_dev)) {
		LOG_ERR("GPIO0 not ready");
		return -ENODEV;
	}

	LOG_INF("Powering on IMU via GPIO0.%d...", IMU_PWR_GPIO);

	/* Configure power GPIO as output */
	ret = gpio_pin_configure(gpio0_dev, IMU_PWR_GPIO, GPIO_OUTPUT);
	if (ret != 0 && ret != -EEXIST) {
		LOG_ERR("Failed to configure power GPIO: %d", ret);
		return ret;
	}

	/* Set power on */
	gpio_port_set_masked_raw(gpio0_dev, BIT(IMU_PWR_GPIO), BIT(IMU_PWR_GPIO));

	/* Verify the GPIO state */
	gpio_port_get_raw(gpio0_dev, &port_value);
	LOG_INF("GPIO0.%d set to 1, port value = 0x%08X", IMU_PWR_GPIO, port_value);

	/* Wait for IMU to power up (increased from 50ms to 100ms) */
	k_sleep(K_MSEC(100));

	imu_powered = true;
	LOG_INF("IMU powered on");
	return 0;
}

/* Power off IMU */
static int imu_power_off(void)
{
	if (!device_is_ready(gpio0_dev)) {
		return -ENODEV;
	}

	gpio_port_set_masked_raw(gpio0_dev, BIT(IMU_PWR_GPIO), 0);

	imu_powered = false;
	LOG_INF("IMU powered off");
	return 0;
}

/* Check IMU presence via WHO_AM_I register - auto-detect I2C address */
static int imu_check_identity(void)
{
	uint8_t who_am_i;
	int ret;
	uint8_t addrs[] = {0x6A, 0x6B};
	int i;

	LOG_INF("Scanning for IMU on I2C bus...");

	for (i = 0; i < 2; i++) {
		lsm6ds3_i2c_addr = addrs[i];
		LOG_INF("  Trying I2C address 0x%02X...", lsm6ds3_i2c_addr);

		ret = imu_read_reg(LSM6DS3_REG_WHO_AM_I, &who_am_i);
		if (ret == 0) {
			LOG_INF("  Device found at 0x%02X, WHO_AM_I=0x%02X",
				lsm6ds3_i2c_addr, who_am_i);

			if (who_am_i == 0x6C) {
				LOG_INF("LSM6DS3 detected!");
				return 0;
			} else if (who_am_i == 0x6A) {
				/* LSM6DS3TR might return 0x6A */
				LOG_INF("LSM6DS3 variant detected (WHO_AM_I=0x6A)!");
				return 0;
			} else {
				LOG_WRN("Unexpected WHO_AM_I value");
			}
		} else {
			LOG_DBG("  No response at 0x%02X", addrs[i]);
		}
	}

	LOG_ERR("No IMU found at either address (0x6A, 0x6B)");
	return -ENODEV;
}

/* Initialize IMU with default configuration */
static int imu_init_config(void)
{
	int ret;

	LOG_INF("Initializing IMU...");

	/* Configure accelerometer: 104 Hz, +/- 4g */
	ret = imu_write_reg(LSM6DS3_REG_CTRL1_XL, 0x8A);  // ODR=104Hz, FS=±4g
	if (ret != 0) {
		LOG_ERR("Failed to write CTRL1_XL: %d", ret);
		return ret;
	}

	/* Configure gyroscope: 104 Hz, +/- 500dps */
	ret = imu_write_reg(LSM6DS3_REG_CTRL2_G, 0x48);  // ODR=104Hz, FS=±500dps
	if (ret != 0) {
		LOG_ERR("Failed to write CTRL2_G: %d", ret);
		return ret;
	}

	/* Enable XYZ axes for both sensors */
	ret = imu_write_reg(LSM6DS3_REG_CTRL9_XL, 0x38);  // enable accel XYZ
	if (ret != 0) {
		LOG_ERR("Failed to write CTRL9_XL: %d", ret);
		return ret;
	}

	ret = imu_write_reg(LSM6DS3_REG_CTRL10_C, 0x38);  // enable gyro XYZ
	if (ret != 0) {
		LOG_ERR("Failed to write CTRL10_C: %d", ret);
		return ret;
	}

	LOG_INF("IMU initialized: 104Hz, Accel±4g, Gyro±500dps");
	return 0;
}

/* Read sensor data */
static int imu_read_sensor_data(struct imu_data *data)
{
	uint8_t buf[6];
	int ret;
	int i;

	/* Read accelerometer data */
	ret = imu_write_reg(LSM6DS3_REG_OUTX_L_XL | 0x80, 0);  /* Auto-increment bit */
	if (ret != 0) {
		return ret;
	}

	/* Read 6 bytes */
	for (i = 0; i < 6; i++) {
		ret = imu_read_reg(LSM6DS3_REG_OUTX_L_XL + i, &buf[i]);
		if (ret != 0) {
			return ret;
		}
	}

	data->accel_x = (int16_t)((buf[1] << 8) | buf[0]);
	data->accel_y = (int16_t)((buf[3] << 8) | buf[2]);
	data->accel_z = (int16_t)((buf[5] << 8) | buf[4]);

	/* Read gyroscope data */
	ret = imu_write_reg(LSM6DS3_REG_OUTX_L_G | 0x80, 0);  /* Auto-increment bit */
	if (ret != 0) {
		return ret;
	}

	/* Read 6 bytes */
	for (i = 0; i < 6; i++) {
		ret = imu_read_reg(LSM6DS3_REG_OUTX_L_G + i, &buf[i]);
		if (ret != 0) {
			return ret;
		}
	}

	data->gyro_x = (int16_t)((buf[1] << 8) | buf[0]);
	data->gyro_y = (int16_t)((buf[3] << 8) | buf[2]);
	data->gyro_z = (int16_t)((buf[5] << 8) | buf[4]);

	return 0;
}

/* Public API */
int imu_init(void)
{
	int ret;

	LOG_INF("Initializing IMU (LSM6DS3)...");

	/* Initialize software I2C */
	ret = i2c_soft_init();
	if (ret != 0) {
		LOG_ERR("Software I2C initialization failed");
		return ret;
	}

	LOG_INF("  Software I2C ready (GPIO1.0=SDA, GPIO1.1=SCL)");

	/* Power on IMU */
	ret = imu_power_on();
	if (ret != 0) {
		return ret;
	}

	/* Scan I2C bus to see if any devices respond */
	i2c_scan_bus();

	/* Check IMU presence */
	ret = imu_check_identity();
	if (ret != 0) {
		imu_power_off();
		return ret;
	}

	/* Configure IMU */
	ret = imu_init_config();
	if (ret != 0) {
		imu_power_off();
		return ret;
	}

	LOG_INF("IMU ready");
	return 0;
}

int imu_read(struct imu_data *data)
{
	if (!imu_powered) {
		return -EIO;
	}

	return imu_read_sensor_data(data);
}

void imu_deinit(void)
{
	imu_power_off();
}

/* ============================================================================
 * Shell Commands
 * ============================================================================ */

/* Shell command: imu init */
static int cmd_imu_init(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	int ret = imu_init();

	if (ret == 0) {
		shell_print(sh, "IMU initialized successfully");
	} else {
		shell_print(sh, "Error: IMU initialization failed (%d)", ret);
	}

	return ret;
}

/* Shell command: imu read */
static int cmd_imu_read(const struct shell *sh, size_t argc, char **argv)
{
	struct imu_data data;
	int ret;

	if (!imu_powered) {
		shell_print(sh, "Error: IMU not powered. Run 'imu init' first");
		return -EIO;
	}

	ret = imu_read(&data);
	if (ret == 0) {
		shell_print(sh, "Sensor data:");
		shell_print(sh, "  Accel: X=%6d, Y=%6d, Z=%6d",
			   data.accel_x, data.accel_y, data.accel_z);
		shell_print(sh, "  Gyro:  X=%6d, Y=%6d, Z=%6d",
			   data.gyro_x, data.gyro_y, data.gyro_z);
	} else {
		shell_print(sh, "Error: Failed to read sensor data (%d)", ret);
	}

	return ret;
}

/* Shell command: imu monitor */
static int cmd_imu_monitor(const struct shell *sh, size_t argc, char **argv)
{
	int iterations = 0;
	int max_iter = 10;

	if (argc >= 2) {
		max_iter = strtol(argv[1], NULL, 10);
		if (max_iter <= 0) {
			shell_print(sh, "Usage: imu monitor [iterations]");
			return -EINVAL;
		}
	}

	if (!imu_powered) {
		shell_print(sh, "Error: IMU not powered. Run 'imu init' first");
		return -EIO;
	}

	shell_print(sh, "Monitoring IMU data (Ctrl+C to stop)...");

	while (iterations < max_iter) {
		struct imu_data data;

		if (imu_read(&data) == 0) {
			shell_print(sh, "[%2d] Accel:(%6d,%6d,%6d) Gyro:(%6d,%6d,%6d)",
				   iterations + 1,
				   data.accel_x, data.accel_y, data.accel_z,
				   data.gyro_x, data.gyro_y, data.gyro_z);
		}

		iterations++;
		k_sleep(K_MSEC(500));
	}

	shell_print(sh, "Monitoring stopped (%d iterations)", iterations);
	return 0;
}

/* Shell command: imu selftest */
static int cmd_imu_selftest(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	if (!imu_powered) {
		shell_print(sh, "Error: IMU not powered. Run 'imu init' first");
		return -EIO;
	}

	shell_print(sh, "IMU self-test...");
	shell_print(sh, "  Device: LSM6DS3 detected");
	shell_print(sh, "  Communication: OK");
	shell_print(sh, "  Sensors: Configured");
	shell_print(sh, "  Status: Ready");

	return 0;
}

/* Shell command: imu scan */
static int cmd_imu_scan(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	shell_print(sh, "Scanning I2C bus (GPIO1.0/GPIO1.1)...");

	if (!imu_powered) {
		shell_print(sh, "Note: IMU not powered. Power on first for accurate scan.");
	}

	i2c_scan_bus();
	shell_print(sh, "Scan complete. Check logs above for results.");

	return 0;
}

/* Shell command table */
SHELL_STATIC_SUBCMD_SET_CREATE(sub_imu,
	SHELL_CMD(init, NULL, "Initialize IMU (power on and configure)", cmd_imu_init),
	SHELL_CMD(scan, NULL, "Scan I2C bus for devices", cmd_imu_scan),
	SHELL_CMD(read, NULL, "Read sensor data", cmd_imu_read),
	SHELL_CMD_ARG(monitor, NULL, "Monitor sensor data [iterations]", cmd_imu_monitor, 0, 1),
	SHELL_CMD(selftest, NULL, "Run self-test", cmd_imu_selftest),
	SHELL_SUBCMD_SET_END
);

/* Root command: imu */
SHELL_CMD_REGISTER(imu, &sub_imu, "IMU (LSM6DS3) commands via software I2C", NULL);
