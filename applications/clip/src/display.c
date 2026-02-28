/*
 * Simple OLED display driver test for CH1115
 * Basic screen-on functionality
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/display.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/sys/printk.h>
#include <zephyr/logging/log.h>
#include <string.h>
#include <math.h>

LOG_MODULE_REGISTER(display, LOG_LEVEL_INF);

/* Display dimensions */
#define OLED_WIDTH  88
#define OLED_HEIGHT 48

/* Display buffer size (monochrome: 8 pixels per byte) */
#define OLED_BUF_SIZE (OLED_WIDTH * OLED_HEIGHT / 8)

/* Mirror settings for display correction */
#define UI_MIRROR_X 1
#define UI_MIRROR_Y 0

/* Frame buffer */
static uint8_t display_buffer[OLED_BUF_SIZE];

/* Display device */
static const struct device *display_dev = NULL;

/* ========================================
 * Recording Animation Configuration
 * ======================================== */

/* Fast Animation Config (Enhanced Mode - first 5 seconds) */
#define FAST_ANIM_BAR_COUNT         13
#define FAST_ANIM_BAR_WIDTH         1
#define FAST_ANIM_BAR_GAP           4
#define FAST_ANIM_MAX_HEIGHT        10
#define FAST_ANIM_MIN_HEIGHT        2
#define FAST_ANIM_PERIOD            75
#define FAST_ANIM_PHASE_SHIFT       5
#define FAST_ANIM_EDGE_MARGIN       14
#define FAST_ANIM_WAVE_PEAKS        3
#define FAST_ANIM_WAVE_WIDTH        1.0f

/* Normal Animation Config (Slow mode - after 5 seconds) */
#define NORMAL_ANIM_BAR_COUNT        13
#define NORMAL_ANIM_BAR_WIDTH        2
#define NORMAL_ANIM_BAR_GAP          3
#define NORMAL_ANIM_MAX_HEIGHT       12
#define NORMAL_ANIM_MIN_HEIGHT       2
#define NORMAL_ANIM_PERIOD           120
#define NORMAL_ANIM_PHASE_SHIFT      8
#define NORMAL_ANIM_EDGE_MARGIN      14
#define NORMAL_ANIM_WAVE_PEAKS       1
#define NORMAL_ANIM_WAVE_WIDTH       1.0f

/**
 * @brief Recording animation type
 */
typedef enum {
	REC_ANIM_NORMAL,    /**< Normal/slow animation */
	REC_ANIM_FAST,      /**< Fast animation for enhanced mode */
} rec_anim_type_t;

/**
 * @brief Fast animation bar state
 */
struct fast_anim_bar {
	int8_t phase_offset;     /* Phase offset in frames (relative to start) */
	uint8_t current_height;  /* Current half-height of the bar */
};

/* Runtime animation state */
static rec_anim_type_t g_current_anim_type = REC_ANIM_NORMAL;
static struct fast_anim_bar g_fast_bars[FAST_ANIM_BAR_COUNT];
static uint32_t g_fast_anim_frame = 0;
static bool g_fast_anim_inited = false;

/* Runtime config selector macros */
#define GET_ANIM_BAR_COUNT()     (g_current_anim_type == REC_ANIM_FAST ? FAST_ANIM_BAR_COUNT : NORMAL_ANIM_BAR_COUNT)
#define GET_ANIM_BAR_WIDTH()     (g_current_anim_type == REC_ANIM_FAST ? FAST_ANIM_BAR_WIDTH : NORMAL_ANIM_BAR_WIDTH)
#define GET_ANIM_BAR_GAP()       (g_current_anim_type == REC_ANIM_FAST ? FAST_ANIM_BAR_GAP : NORMAL_ANIM_BAR_GAP)
#define GET_ANIM_MAX_HEIGHT()    (g_current_anim_type == REC_ANIM_FAST ? FAST_ANIM_MAX_HEIGHT : NORMAL_ANIM_MAX_HEIGHT)
#define GET_ANIM_MIN_HEIGHT()    (g_current_anim_type == REC_ANIM_FAST ? FAST_ANIM_MIN_HEIGHT : NORMAL_ANIM_MIN_HEIGHT)
#define GET_ANIM_PERIOD()        (g_current_anim_type == REC_ANIM_FAST ? FAST_ANIM_PERIOD : NORMAL_ANIM_PERIOD)
#define GET_ANIM_PHASE_SHIFT()   (g_current_anim_type == REC_ANIM_FAST ? FAST_ANIM_PHASE_SHIFT : NORMAL_ANIM_PHASE_SHIFT)
#define GET_ANIM_EDGE_MARGIN()   (g_current_anim_type == REC_ANIM_FAST ? FAST_ANIM_EDGE_MARGIN : NORMAL_ANIM_EDGE_MARGIN)
#define GET_ANIM_WAVE_PEAKS()    (g_current_anim_type == REC_ANIM_FAST ? FAST_ANIM_WAVE_PEAKS : NORMAL_ANIM_WAVE_PEAKS)
#define GET_ANIM_WAVE_WIDTH()    (g_current_anim_type == REC_ANIM_FAST ? FAST_ANIM_WAVE_WIDTH : NORMAL_ANIM_WAVE_WIDTH)

/* ========================================
 * Pixel operations
 * ======================================== */

static inline void map_xy(int *x, int *y)
{
	if (UI_MIRROR_X) {
		*x = (OLED_WIDTH - 1) - *x;
	}
	if (UI_MIRROR_Y) {
		*y = (OLED_HEIGHT - 1) - *y;
	}
}

static inline void set_pixel(uint8_t *buf, int x, int y)
{
	map_xy(&x, &y);
	if (x < 0 || x >= OLED_WIDTH || y < 0 || y >= OLED_HEIGHT)
		return;
	buf[(y / 8) * OLED_WIDTH + x] |= (1 << (y % 8));
}

static inline void set_pixel_direct(uint8_t *buf, int x, int y)
{
	/* Set pixel WITHOUT applying mirror transformation */
	if (x < 0 || x >= OLED_WIDTH || y < 0 || y >= OLED_HEIGHT)
		return;
	buf[(y / 8) * OLED_WIDTH + x] |= (1 << (y % 8));
}

static inline void clear_pixel_direct(uint8_t *buf, int x, int y)
{
	/* Clear pixel WITHOUT applying mirror transformation */
	if (x < 0 || x >= OLED_WIDTH || y < 0 || y >= OLED_HEIGHT)
		return;
	buf[(y / 8) * OLED_WIDTH + x] &= ~(1 << (y % 8));
}

static void draw_rect_direct(uint8_t *buf, int x, int y, int w, int h, bool fill)
{
	/* Draw rectangle WITHOUT mirror transformation */
	for (int i = x; i < x + w && i < OLED_WIDTH; i++) {
		for (int j = y; j < y + h && j < OLED_HEIGHT; j++) {
			if (fill || i == x || i == x + w - 1 || j == y || j == y + h - 1) {
				set_pixel_direct(buf, i, j);
			}
		}
	}
}

static void clear_screen(uint8_t *buf)
{
	memset(buf, 0, OLED_BUF_SIZE);
}

/* ========================================
 * Recording Animation - Wave Implementation
 * ======================================== */

/**
 * @brief Sine-like wave function for smooth height animation
 * @param phase Current phase (0 to period-1)
 * @param period Full period length
 * @param min_val Minimum value
 * @param max_val Maximum value
 * @return Calculated value at given phase
 */
static int fast_anim_wave(int phase, int period, int min_val, int max_val)
{
	/* Normalize phase to 0-2PI range */
	int normalized = phase % period;
	float angle = (float)normalized * 6.28318f / (float)period;  /* 2*PI */

	/* Apply wave peaks count and width factor */
	int wave_peaks = GET_ANIM_WAVE_PEAKS();
	float wave_width = GET_ANIM_WAVE_WIDTH();
	float scaled_angle = (float)wave_peaks * angle * wave_width;

	/* Use (1 - cos(angle)) / 2 to get smooth 0 to 1 transition */
	float factor = (1.0f - (float)cos(scaled_angle)) / 2.0f;

	return min_val + (int)(factor * (max_val - min_val));
}

/**
 * @brief Initialize fast animation bars
 */
static void fast_anim_init(void)
{
	/* Check if re-initialization needed (config changed) */
	static rec_anim_type_t last_anim_type = REC_ANIM_NORMAL;

	if (g_fast_anim_inited && (last_anim_type == g_current_anim_type)) {
		return;
	}

	LOG_INF("[DISPLAY] fast_anim_init: re-init detected, last_type=%d, current_type=%d",
		last_anim_type, g_current_anim_type);

	g_fast_anim_inited = true;
	g_fast_anim_frame = 0;
	last_anim_type = g_current_anim_type;

	/* Get runtime config values */
	int bar_count = GET_ANIM_BAR_COUNT();
	int phase_shift = GET_ANIM_PHASE_SHIFT();
	int min_height = GET_ANIM_MIN_HEIGHT();
	int period = GET_ANIM_PERIOD();
	int wave_peaks = GET_ANIM_WAVE_PEAKS();

	LOG_INF("[DISPLAY] Anim config: bars=%d, phase_shift=%d, period=%d, wave_peaks=%d, max_height=%d, min_height=%d",
		bar_count, phase_shift, period, wave_peaks, GET_ANIM_MAX_HEIGHT(), min_height);

	/* Initialize bars with linear phase offsets for left-to-right wave motion */
	for (int i = 0; i < bar_count; i++) {
		/* Set phase offset - each bar has a progressive offset from left to right */
		g_fast_bars[i].phase_offset = (int8_t)(i * phase_shift);
		g_fast_bars[i].current_height = (uint8_t)min_height;
	}
}

/**
 * @brief Step fast animation - update bar heights
 */
static void fast_anim_step(void)
{
	/* Increment frame counter */
	g_fast_anim_frame++;

	/* Get runtime config values */
	int bar_count = GET_ANIM_BAR_COUNT();
	int period = GET_ANIM_PERIOD();
	int min_height = GET_ANIM_MIN_HEIGHT();
	int max_height = GET_ANIM_MAX_HEIGHT();

	/* Update each bar's height based on its phase */
	for (int i = 0; i < bar_count; i++) {
		/* Calculate current phase for this bar */
		int current_phase = (int)g_fast_anim_frame + g_fast_bars[i].phase_offset;

		/* Calculate new height using wave function */
		int new_height = fast_anim_wave(current_phase, period, min_height, max_height);

		g_fast_bars[i].current_height = (uint8_t)new_height;
	}
}

/**
 * @brief Draw fast animation - symmetric bars along center
 */
static void draw_fast_animation(uint8_t *buf)
{
	const int x_mid = OLED_WIDTH / 2;
	const int y_mid = OLED_HEIGHT / 2;

	/* Get runtime config values */
	int bar_count = GET_ANIM_BAR_COUNT();
	int bar_width = GET_ANIM_BAR_WIDTH();
	int bar_gap = GET_ANIM_BAR_GAP();
	int edge_margin = GET_ANIM_EDGE_MARGIN();

	/* Calculate total width of all bars and gaps */
	int total_width = (bar_count * bar_width) + ((bar_count - 1) * bar_gap);

	/* Calculate available width (screen width minus edge margins) */
	int available_width = OLED_WIDTH - (2 * edge_margin);

	/* Calculate starting X position */
	int start_x = edge_margin + ((available_width - total_width) / 2);

	/* Draw each bar */
	for (int i = 0; i < bar_count; i++) {
		/* Calculate bar position */
		int bar_x = start_x + i * (bar_width + bar_gap);
		int bar_height = g_fast_bars[i].current_height;

		/* Draw bar symmetric from center */
		for (int dx = 0; dx < bar_width; dx++) {
			int x = bar_x + dx;
			if (x < 0 || x >= OLED_WIDTH) continue;

			for (int dy = 0; dy <= bar_height; dy++) {
				if (y_mid - dy >= 0) {
					set_pixel_direct(buf, x, y_mid - dy);
				}
				if (y_mid + dy < OLED_HEIGHT && dy > 0) {
					set_pixel_direct(buf, x, y_mid + dy);
				}
			}
		}
	}
}

/**
 * @brief Render recording page with animation
 * @param buf Frame buffer
 * @param enhanced_mode Recording mode display (NORMAL or ENHANCED)
 */
static void render_recording_page(uint8_t *buf, bool enhanced_mode)
{
	clear_screen(buf);

	/* Draw wave animation */
	/* Note: fast_anim_init() is already called by display_show_recording() */
	draw_fast_animation(buf);
}

/* ========================================
 * Display Flush
 * ======================================== */

static void flush_display(void)
{
	if (!display_dev) {
		return;
	}

	struct display_buffer_descriptor desc = {
		.buf_size = OLED_BUF_SIZE,
		.width = OLED_WIDTH,
		.height = OLED_HEIGHT,
		.pitch = OLED_WIDTH,
	};

	display_write(display_dev, 0, 0, &desc, display_buffer);
}

/* ========================================
 * Public API - Recording Display
 * ======================================== */

/**
 * @brief Show recording page with animation
 * @param enhanced_mode true for enhanced mode (fast animation), false for normal mode
 */
void display_show_recording(bool enhanced_mode)
{
	/* Set animation type first (needed by fast_anim_init) */
	rec_anim_type_t new_type = enhanced_mode ? REC_ANIM_FAST : REC_ANIM_NORMAL;
	rec_anim_type_t old_type = g_current_anim_type;

	g_current_anim_type = new_type;

	/* Log when animation type changes (only on actual change) */
	if (old_type != new_type) {
		LOG_INF("[DISPLAY] Animation switch: %d -> %d (mode=%s)",
			old_type, new_type,
			(new_type == REC_ANIM_FAST) ? "FAST" : "NORMAL");
	}

	/* Initialize animation bars (checks if re-init needed) */
	fast_anim_init();

	/* Update animation step (advance frame counter) */
	fast_anim_step();

	/* Render and flush */
	render_recording_page(display_buffer, enhanced_mode);
	flush_display();
}

/* ========================================
 * Original Basic Functions
 * ======================================== */

/* Initialize display hardware */
int display_init_hw(void)
{
	/* Get display device */
	display_dev = DEVICE_DT_GET(DT_CHOSEN(zephyr_display));
	if (!display_dev || !device_is_ready(display_dev)) {
		LOG_WRN("[DISPLAY] OLED device not ready, using log output");
		display_dev = NULL;
	} else {
		LOG_INF("[DISPLAY] Initialized (OLED: %dx%d)", OLED_WIDTH, OLED_HEIGHT);

		/* Initialize with white screen (all pixels set to 1 for MONO01) */
		memset(display_buffer, 0xFF, OLED_BUF_SIZE);

		struct display_buffer_descriptor desc = {
			.buf_size = OLED_BUF_SIZE,
			.width = OLED_WIDTH,
			.height = OLED_HEIGHT,
			.pitch = OLED_WIDTH,
		};

		display_write(display_dev, 0, 0, &desc, display_buffer);
	}

	return 0;
}

/* Clear display */
void oled_clear(void)
{
	struct display_buffer_descriptor desc;

	if (!display_dev) {
		return;
	}

	desc.buf_size = sizeof(display_buffer);
	desc.width = OLED_WIDTH;
	desc.height = OLED_HEIGHT;
	desc.pitch = OLED_WIDTH;

	memset(display_buffer, 0x00, sizeof(display_buffer));
	display_write(display_dev, 0, 0, &desc, display_buffer);
}

/* Fill display (all on) */
void display_fill(void)
{
	struct display_buffer_descriptor desc;

	if (!display_dev) {
		return;
	}

	desc.buf_size = sizeof(display_buffer);
	desc.width = OLED_WIDTH;
	desc.height = OLED_HEIGHT;
	desc.pitch = OLED_WIDTH;

	memset(display_buffer, 0xFF, sizeof(display_buffer));
	display_write(display_dev, 0, 0, &desc, display_buffer);
}
