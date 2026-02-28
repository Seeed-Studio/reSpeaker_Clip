#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/i2c.h>
#include <zephyr/drivers/display.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/logging/log.h>
#include <zephyr/pm/device.h>
#include <zephyr/sys/util.h>
#include <zephyr/sys/atomic.h>

#include <errno.h>
#include <string.h>

/* Keep the driver quiet for FPS testing; only report errors. */
LOG_MODULE_REGISTER(ch1115, LOG_LEVEL_ERR);

#define DT_DRV_COMPAT solomon_ch1115

struct ch1115_data {
    enum display_pixel_format pf;
    uint8_t *clear_buf;
	bool suspended;
};

static uint32_t ch1115_fps_value;
static uint32_t ch1115_last_write_err;
static uint32_t ch1115_write_window_start_ms;
static uint32_t ch1115_write_calls_in_window;

uint32_t ch1115_get_fps(void)
{
	return ch1115_fps_value;
}

static void ch1115_trace_write_result(int ret)
{
    uint32_t now = k_uptime_get_32();

    if (ret < 0) {
        ch1115_last_write_err = (uint32_t)(-ret);
    }

    if (ch1115_write_window_start_ms == 0U) {
        ch1115_write_window_start_ms = now;
    }

    /* Count only successful flush calls. */
    if (ret >= 0) {
        ch1115_write_calls_in_window++;
    }
    if ((now - ch1115_write_window_start_ms) >= 1000U) {
        /* In this project, "FPS" is treated as successful flushes per second.
         * This is robust across LVGL partial updates where frame_incomplete may
         * stay true and never signal a "frame end".
         */
        ch1115_fps_value = ch1115_write_calls_in_window;
        ch1115_write_calls_in_window = 0U;
        ch1115_write_window_start_ms = now;
        ch1115_last_write_err = 0U;
    }
}

struct ch1115_config {
    struct i2c_dt_spec i2c;
    struct gpio_dt_spec reset;
    uint16_t width;
    uint16_t height;
    uint8_t segment_offset;
    uint8_t page_offset;
    uint8_t display_offset;
    uint8_t multiplex_ratio;
    uint8_t prechargep;
    uint8_t segment_remap;
    uint8_t com_invdir;
};

static inline int ch1115_write_cmds(const struct device *dev, const uint8_t *cmds, size_t len)
{
    const struct ch1115_config *config = dev->config;

    return i2c_burst_write_dt(&config->i2c, 0x00, cmds, len);
}

static inline int ch1115_write_data(const struct device *dev, const uint8_t *data, size_t len)
{
    const struct ch1115_config *config = dev->config;

    return i2c_burst_write_dt(&config->i2c, 0x40, data, len);
}

static int ch1115_blanking_on(const struct device *dev)
{
    uint8_t cmd = 0xAE;

    int ret = ch1115_write_cmds(dev, &cmd, 1);
    if (ret < 0) {
        LOG_ERR("blanking_on failed (%d)", ret);
    }
    return ret;
}

static int ch1115_blanking_off(const struct device *dev)
{
    uint8_t cmd = 0xAF;

    int ret = ch1115_write_cmds(dev, &cmd, 1);
    if (ret < 0) {
        LOG_ERR("blanking_off failed (%d)", ret);
    }
    return ret;
}

static int ch1115_set_contrast(const struct device *dev, const uint8_t contrast)
{
    uint8_t cmd_buf[] = { 0x81, contrast };

    int ret = ch1115_write_cmds(dev, cmd_buf, sizeof(cmd_buf));
    if (ret < 0) {
        LOG_ERR("set_contrast failed (%d)", ret);
    }
    return ret;
}

static void ch1115_get_capabilities(const struct device *dev, struct display_capabilities *caps)
{
    const struct ch1115_config *config = dev->config;
    struct ch1115_data *data = dev->data;

    caps->x_resolution = config->width;
    caps->y_resolution = config->height;
    caps->supported_pixel_formats = PIXEL_FORMAT_MONO10 | PIXEL_FORMAT_MONO01;
    caps->current_pixel_format = data->pf;
    /* CH1115 uses a page-based memory layout (8 vertical pixels per byte). */
    caps->screen_info = SCREEN_INFO_MONO_VTILED;
    caps->current_orientation = DISPLAY_ORIENTATION_NORMAL;
}

static int ch1115_set_pixel_format(const struct device *dev, const enum display_pixel_format pf)
{
    struct ch1115_data *data = dev->data;
    uint8_t cmd;
    int ret;

    if (pf == data->pf) {
        return 0;
    }

    if (pf == PIXEL_FORMAT_MONO10) {
        cmd = 0xA7; /* reverse display */
    } else if (pf == PIXEL_FORMAT_MONO01) {
        cmd = 0xA6; /* normal display */
    } else {
        return -ENOTSUP;
    }

    ret = ch1115_write_cmds(dev, &cmd, 1);
    if (ret < 0) {
		LOG_ERR("set_pixel_format failed (%d)", ret);
        return ret;
    }

    data->pf = pf;
    return 0;
}

static int ch1115_set_pos(const struct device *dev, uint8_t x, uint8_t page)
{
    uint8_t cmd_buf[] = {
        (uint8_t)(0xB0 | (page & 0x0F)),
        (uint8_t)(0x00 | (x & 0x0F)),
        (uint8_t)(0x10 | ((x >> 4) & 0x0F)),
    };

    return ch1115_write_cmds(dev, cmd_buf, sizeof(cmd_buf));
}

static int ch1115_write(const struct device *dev, const uint16_t x, const uint16_t y,
             const struct display_buffer_descriptor *desc, const void *buf)
{
    const struct ch1115_config *config = dev->config;
    struct ch1115_data *data = dev->data;
    size_t buf_len;

    if (data->suspended) {
        return -EACCES;
    }

    uint8_t page_start;
    uint8_t page_count;
    uint8_t col_start;
    const uint8_t *buf_ptr;
    int ret;

    if (desc->pitch < desc->width) {
        return -EINVAL;
    }

    if (desc->pitch != desc->width) {
        return -ENOTSUP;
    }

    if ((y & 0x7U) != 0U) {
        return -ENOTSUP;
    }

    buf_len = MIN(desc->buf_size, (size_t)(desc->height * desc->width / 8U));
    if (buf == NULL || buf_len == 0U) {
        return -EINVAL;
    }

    page_start = (uint8_t)(y / 8U) + config->page_offset;
    page_count = (uint8_t)(desc->height / 8U);
    col_start = (uint8_t)x + config->segment_offset;
    buf_ptr = buf;

    for (uint8_t page = 0; page < page_count; page++) {
        ret = ch1115_set_pos(dev, col_start, (uint8_t)(page_start + page));
        if (ret < 0) {
            ch1115_trace_write_result(ret);
            return ret;
        }

        ret = ch1115_write_data(dev, buf_ptr, desc->width);
        if (ret < 0) {
            ch1115_trace_write_result(ret);
            return ret;
        }

        buf_ptr += desc->width;
        if ((size_t)(buf_ptr - (const uint8_t *)buf) > buf_len) {
            return -EOVERFLOW;
        }
    }

	ch1115_trace_write_result(0);

    return 0;
}

static int ch1115_clear(const struct device *dev)
{
    struct ch1115_data *data = dev->data;
    const struct ch1115_config *config = dev->config;

    if (data->suspended) {
        return -EACCES;
    }

    struct display_buffer_descriptor desc = {
        .buf_size = (size_t)(config->width * config->height / 8U),
        .width = config->width,
        .height = config->height,
        .pitch = config->width,
    };

    if (data->clear_buf == NULL) {
        return -ENOMEM;
    }

    memset(data->clear_buf, 0x00, desc.buf_size);
    return ch1115_write(dev, 0, 0, &desc, data->clear_buf);
}

static int ch1115_init(const struct device *dev)
{
    const struct ch1115_config *config = dev->config;
    struct ch1115_data *data = dev->data;
    int ret;

    uint8_t init_cmds[] = {
        0xAE,
        0x00,
        0x10,
        0x40,
        0xB0,
        0x81,
        0x80,
        0x82,
        0x00,
        0x23,
        0x01,
        (uint8_t)(config->segment_remap ? 0xA1 : 0xA0),
        0xA2,
        (uint8_t)(config->com_invdir ? 0xC8 : 0xC0),
        0xA8,
        config->multiplex_ratio,
        0xD3,
        config->display_offset,
        0xD5,
        0x80,
        0xD9,
        config->prechargep,
        0xDA,
        0x12,
        0xDB,
        0x40,
        0xAD,
		/* Vendor init sequence for CH1115-based 0.50\" 88x48 modules */
		0x8B,
		0x33,
        0xA4,
        0xA6,
        0xAF,
    };

    if (!i2c_is_ready_dt(&config->i2c)) {
        LOG_ERR("I2C bus not ready");
        return -ENODEV;
    }

    /* Intentionally no INFO logs here (keep FPS test quiet). */

    if (config->reset.port) {
        if (!gpio_is_ready_dt(&config->reset)) {
            LOG_ERR("Reset GPIO not ready");
            return -ENODEV;
        }

        ret = gpio_pin_configure_dt(&config->reset, GPIO_OUTPUT_INACTIVE);
        if (ret < 0) {
            return ret;
        }

        gpio_pin_set_dt(&config->reset, 1);
        k_sleep(K_MSEC(10));
        gpio_pin_set_dt(&config->reset, 0);
        k_sleep(K_MSEC(10));
    }

    data->pf = PIXEL_FORMAT_MONO01;
	data->suspended = false;

    ret = ch1115_write_cmds(dev, init_cmds, sizeof(init_cmds));
    if (ret < 0) {
        LOG_ERR("Failed to init CH1115 (%d)", ret);
        return ret;
    }

    /*
     * Allocate clear buffer for application use.
     * Size based on logical resolution (88x48 = 528 bytes).
     */
    data->clear_buf = k_malloc(config->width * config->height / 8U);
    if (data->clear_buf == NULL) {
        return -ENOMEM;
    }

    /*
     * Clear ALL activated COM lines to prevent random RAM display on startup.
     *
     * Hardware context:
     * - multiplex_ratio=63 activates all 64 COM lines (COM0-COM63)
     * - OLED panel has only 48 physical rows
     * - Unclear rows show random RAM content (garbage)
     *
     * Solution: Clear all 64 rows at init, then use 48 rows for display.
     */
    const int total_com_lines = config->multiplex_ratio + 1;  /* 64 rows */
    const size_t full_clear_size = config->width * total_com_lines / 8U;
    uint8_t *full_clear_buf = k_malloc(full_clear_size);

    if (full_clear_buf) {
        /* Clear and write all 64 rows */
        memset(full_clear_buf, 0x00, full_clear_size);
        struct display_buffer_descriptor full_desc = {
            .buf_size = full_clear_size,
            .width = config->width,
            .height = total_com_lines,
            .pitch = config->width,
        };
        ch1115_write(dev, 0, 0, &full_desc, full_clear_buf);
        k_free(full_clear_buf);
    } else {
        /* Fallback: clear at least the logical height */
        ch1115_clear(dev);
    }

    return 0;
}

#ifdef CONFIG_PM_DEVICE
static int ch1115_pm_action(const struct device *dev, enum pm_device_action action)
{
    struct ch1115_data *data = dev->data;
    int ret;

    switch (action) {
    case PM_DEVICE_ACTION_SUSPEND:
        /* Lowest-risk "sleep": turn display off. RAM is typically retained. */
        ret = ch1115_blanking_on(dev);
        if (ret == 0) {
            data->suspended = true;
        }
        return ret;
    case PM_DEVICE_ACTION_RESUME:
        /* Wake: turn display on. App can optionally clear/redraw. */
        ret = ch1115_blanking_off(dev);
        if (ret == 0) {
            data->suspended = false;
        }
        return ret;
    case PM_DEVICE_ACTION_TURN_OFF:
        /* Treat TURN_OFF as suspend for now (no external power gating). */
        ret = ch1115_blanking_on(dev);
        if (ret == 0) {
            data->suspended = true;
        }
        return ret;
    default:
        return -ENOTSUP;
    }
}
#endif /* CONFIG_PM_DEVICE */

static const struct display_driver_api ch1115_driver_api = {
    .write = ch1115_write,
    .clear = ch1115_clear,
    .blanking_on = ch1115_blanking_on,
    .blanking_off = ch1115_blanking_off,
    .get_capabilities = ch1115_get_capabilities,
    .set_pixel_format = ch1115_set_pixel_format,
    .set_contrast = ch1115_set_contrast,
};

#define CH1115_DEVICE(inst)                                                                      \
    static struct ch1115_data ch1115_data_##inst;                                              \
    static const struct ch1115_config ch1115_config_##inst = {                                 \
        .i2c = I2C_DT_SPEC_INST_GET(inst),                                                    \
        .reset = GPIO_DT_SPEC_INST_GET_OR(inst, reset_gpios, {0}),                           \
        .width = DT_INST_PROP(inst, width),                                                  \
        .height = DT_INST_PROP(inst, height),                                                \
        .segment_offset = DT_INST_PROP_OR(inst, segment_offset, 0),                          \
        .page_offset = DT_INST_PROP_OR(inst, page_offset, 0),                                \
        .display_offset = DT_INST_PROP_OR(inst, display_offset, 0),                          \
        .multiplex_ratio = DT_INST_PROP_OR(inst, multiplex_ratio, 47),                       \
        .prechargep = DT_INST_PROP_OR(inst, prechargep, 0x22),                               \
        .segment_remap = DT_INST_PROP_OR(inst, segment_remap, 0),                            \
        .com_invdir = DT_INST_PROP_OR(inst, com_invdir, 0),                                  \
    };                                                                                         \
	PM_DEVICE_DT_INST_DEFINE(inst, ch1115_pm_action);                                          \
    DEVICE_DT_INST_DEFINE(inst, ch1115_init, PM_DEVICE_DT_INST_GET(inst),                    \
			  &ch1115_data_##inst, &ch1115_config_##inst,                                  \
            POST_KERNEL, CONFIG_DISPLAY_INIT_PRIORITY, &ch1115_driver_api);

DT_INST_FOREACH_STATUS_OKAY(CH1115_DEVICE)
