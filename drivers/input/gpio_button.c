#define DT_DRV_COMPAT gpio_button

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/input/button.h>
#include <zephyr/sys/util.h>
#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(gpio_button, CONFIG_INPUT_LOG_LEVEL);

struct gpio_button_config {
	struct gpio_dt_spec gpio;
	uint32_t debounce_ms;
	uint32_t long_press_ms[LONG_PRESS_MS_MAX];
	uint32_t long_press_count; /* Actual number of long press levels configured */
	uint32_t double_click_ms;
};

struct gpio_button_data {
	const struct device *dev;
	const struct gpio_button_config *cfg;
	struct gpio_callback gpio_cb;
	bool interrupt_enabled;

	// State variables for event detection
	uint32_t press_count;
	int64_t press_time;
	int64_t release_time;
	int64_t last_release_time;
	bool waiting_for_release;
	bool long_press_triggered; /* Flag to prevent duplicate long press events */

#if defined(CONFIG_INPUT_GPIO_BUTTON_OWN_THREAD)
	K_KERNEL_STACK_MEMBER(thread_stack, CONFIG_INPUT_GPIO_BUTTON_THREAD_STACK_SIZE);
	struct k_thread thread;
	struct k_sem gpio_sem;
#elif defined(CONFIG_INPUT_GPIO_BUTTON_GLOBAL_THREAD)
	struct k_work work;
#endif

	button_event_cb_t event_cb[BUTTON_EVENT_NUM];
};

volatile bool wakeup = false;

static void gpio_button_callback(const struct device *port, struct gpio_callback *cb, uint32_t pins)
{
	struct gpio_button_data *data = CONTAINER_OF(cb, struct gpio_button_data, gpio_cb);

#if defined(CONFIG_INPUT_GPIO_BUTTON_OWN_THREAD)
	k_sem_give(&data->gpio_sem);
#elif defined(CONFIG_INPUT_GPIO_BUTTON_GLOBAL_THREAD)
	k_work_submit(&data->work);
#endif
}


int button_event_callback_register(const struct device *dev, button_event_cb_t cb,
				   enum button_action action)
{
	struct gpio_button_data *data = dev->data;
	const struct gpio_button_config *cfg = data->cfg;

	if (!data->interrupt_enabled) {
		gpio_pin_configure_dt(&cfg->gpio, GPIO_INPUT);
		gpio_pin_interrupt_configure_dt(&cfg->gpio, GPIO_INT_EDGE_BOTH);

		gpio_init_callback(&data->gpio_cb, gpio_button_callback, BIT(cfg->gpio.pin));
		gpio_add_callback(cfg->gpio.port, &data->gpio_cb);
		data->interrupt_enabled = true;
	}

	if (action < BUTTON_EVENT_NUM) {
		data->event_cb[action] = cb;
	}
	return 0;
}

int button_callback_register(const struct device *dev, button_event_cb_t cb)
{
	for (int i = 0; i < BUTTON_EVENT_NUM; i++) {
		button_event_callback_register(dev, cb, i);
	}
	return 0;
}

static void gpio_button_thread_cb(const struct device *dev)
{
	struct gpio_button_data *data = dev->data;
	const struct gpio_button_config *cfg = data->cfg;

	while (1) {
		bool pressed = gpio_pin_get_dt(&cfg->gpio);
		int64_t now = k_uptime_get();

		// 1. press detect
		if (pressed) {
			if (!data->waiting_for_release) {
				data->press_time = now;
				data->press_count++;
				data->waiting_for_release = true;
				data->long_press_triggered = false;
			} else if (!data->long_press_triggered && cfg->long_press_count > 0) {
				uint32_t press_duration = now - data->press_time;
				uint32_t max_long_press_idx = cfg->long_press_count - 1;

				// Check if reached the maximum long press threshold
				if (press_duration >= cfg->long_press_ms[max_long_press_idx]) {
					// Auto callback when reaching the longest press time
					if (data->event_cb[max_long_press_idx]) {
						data->long_press_triggered = true;
						data->press_count = 0;
						data->waiting_for_release = false;
						data->event_cb[max_long_press_idx](
							dev, max_long_press_idx);
						break;
					}
				}
			}
			k_sleep(K_MSEC(30));
		} else {
			if (data->press_count == 0) {
				/* If an auto-triggered long press was fired, emit BUTTON_RELEASE
				 * so the application knows the button is now up. */
				if (data->long_press_triggered) {
					data->long_press_triggered = false;
					if (data->event_cb[BUTTON_RELEASE]) {
						data->event_cb[BUTTON_RELEASE](dev, BUTTON_RELEASE);
					}
				}
				break; // skip must pair with a press event
			}
			// only generate a release event if we've received a press event
			data->release_time = now;

			// Debounce: ignore short press fluctuations
			if (data->release_time - data->press_time < cfg->debounce_ms) {
				break;
			}

			if (data->waiting_for_release) {
				data->waiting_for_release = false;
				data->last_release_time = data->release_time;
				uint32_t press_duration = data->release_time - data->press_time;

				// Skip processing if long press was already triggered
				if (data->long_press_triggered) {
					data->long_press_triggered = false;
					break;
				}

				bool long_press_detected = false;
				enum button_action long_press_level = BUTTON_LONG_PRESS;

				// Check from highest to lowest long press threshold
				for (uint32_t i = cfg->long_press_count; i > 0; i--) {
					if (press_duration >= cfg->long_press_ms[i - 1]) {
						long_press_detected = true;
						long_press_level = (enum button_action)(i - 1);
						break;
					}
				}

				if (long_press_detected) {
					// Long press detected on release
					if (data->event_cb[long_press_level]) {
						data->press_count = 0;
						data->event_cb[long_press_level](dev,
										 long_press_level);
						break;
					}
				} else {
					if (data->press_count == 1) {
						if (data->release_time - data->last_release_time <
						    cfg->double_click_ms) {
							// wait for the next press to be able to
							// detect double click
							k_sleep(K_MSEC(30));
							continue;
						}
					} else if (data->press_count == 2) {
						data->press_count = 0;
						// Double press
						if (data->event_cb[BUTTON_DOUBLE_CLICK]) {
							data->event_cb[BUTTON_DOUBLE_CLICK](
								dev, BUTTON_DOUBLE_CLICK);
						}
					}
				}
			} else {
				if (data->release_time - data->last_release_time >
				    cfg->double_click_ms) {
					data->press_count = 0;
					// Single press
					if (data->event_cb[BUTTON_SINGLE_CLICK]) {
						data->event_cb[BUTTON_SINGLE_CLICK](
							dev, BUTTON_SINGLE_CLICK);
					}
				}
				k_sleep(K_MSEC(30));
			}
		}
	}

}

#ifdef CONFIG_INPUT_GPIO_BUTTON_OWN_THREAD
static void gpio_button_thread(void *p1, void *p2, void *p3)
{
	ARG_UNUSED(p2);
	ARG_UNUSED(p3);

	struct gpio_button_data *data = p1;

	while (1) {
		k_sem_take(&data->gpio_sem, K_FOREVER);
		gpio_button_thread_cb(data->dev);
	}
}
#endif

#ifdef CONFIG_INPUT_GPIO_BUTTON_GLOBAL_THREAD
static void gpio_button_work_cb(struct k_work *work)
{
	struct gpio_button_data *data = CONTAINER_OF(work, struct gpio_button_data, work);

	gpio_button_thread_cb(data->dev);
}
#endif

static int gpio_button_init(const struct device *dev)
{
	struct gpio_button_data *data = dev->data;
	const struct gpio_button_config *cfg = dev->config;

	if (!gpio_is_ready_dt(&cfg->gpio)) {
		LOG_ERR("GPIO device not ready");
		return -ENODEV;
	}

	data->dev = dev;
	data->cfg = cfg;
	data->long_press_triggered = false;

	/* Log button configuration */
	LOG_DBG("Button initialized: debounce=%dms, double_click=%dms, long_press_levels=%d",
		cfg->debounce_ms, cfg->double_click_ms, cfg->long_press_count);
	for (uint32_t i = 0; i < cfg->long_press_count; i++) {
		LOG_DBG("  Long press level %d: %dms", i, cfg->long_press_ms[i]);
	}

#if defined(CONFIG_INPUT_GPIO_BUTTON_OWN_THREAD)
	k_sem_init(&data->gpio_sem, 0, K_SEM_MAX_LIMIT);

	k_thread_create(&data->thread, data->thread_stack,
			CONFIG_INPUT_GPIO_BUTTON_THREAD_STACK_SIZE, gpio_button_thread, data, NULL,
			NULL, K_PRIO_COOP(CONFIG_INPUT_GPIO_BUTTON_THREAD_PRIORITY), 0, K_NO_WAIT);
#elif defined(CONFIG_INPUT_GPIO_BUTTON_GLOBAL_THREAD)
	data->work.handler = gpio_button_work_cb;
#endif

	return 0;
}

/* Helper macro to get long press array length safely */
#define GET_LONG_PRESS_COUNT(inst) MIN(DT_INST_PROP_LEN(inst, long_press_ms), LONG_PRESS_MS_MAX)

/* Helper macros to get long press values with bounds checking */
#define GET_LONG_PRESS_MS(inst, idx)                                                               \
	COND_CODE_1(DT_INST_PROP_HAS_IDX(inst, long_press_ms, idx),                                \
		    (DT_INST_PROP_BY_IDX(inst, long_press_ms, idx)), (0))

#define DEFINE_GPIO_BUTTON(inst)                                                                   \
	static struct gpio_button_data gpio_button_data_##inst;                                    \
	static const struct gpio_button_config gpio_button_config_##inst = {                       \
		.gpio = GPIO_DT_SPEC_INST_GET(inst, gpios),                                        \
		.debounce_ms = DT_INST_PROP_OR(inst, debounce_ms, 30),                             \
		.long_press_ms = {GET_LONG_PRESS_MS(inst, 0), GET_LONG_PRESS_MS(inst, 1),          \
				  GET_LONG_PRESS_MS(inst, 2), GET_LONG_PRESS_MS(inst, 3)},         \
		.long_press_count = GET_LONG_PRESS_COUNT(inst),                                    \
		.double_click_ms = DT_INST_PROP_OR(inst, double_click_ms, 400)};                   \
	DEVICE_DT_INST_DEFINE(inst, gpio_button_init, NULL, &gpio_button_data_##inst,              \
			      &gpio_button_config_##inst, POST_KERNEL,                             \
			      CONFIG_KERNEL_INIT_PRIORITY_DEFAULT, NULL);

DT_INST_FOREACH_STATUS_OKAY(DEFINE_GPIO_BUTTON)
