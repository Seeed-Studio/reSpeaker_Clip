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
#include <zephyr/sys/util.h>
#include <string.h>
#include <math.h>
#include <stdio.h>

#include "icons.h"

LOG_MODULE_REGISTER(display, LOG_LEVEL_INF);

/* Display dimensions */
#define OLED_WIDTH  88
#define OLED_HEIGHT 48

/* Display buffer size (monochrome: 8 pixels per byte) */
#define OLED_BUF_SIZE (OLED_WIDTH * OLED_HEIGHT / 8)

/* Mirror settings for display correction */
#define UI_MIRROR_X 1
#define UI_MIRROR_Y 0

/* ========================================
 * Recording Dot Circle Animation Configuration
 * ======================================== */

#define DOT_CIRCLE_STABLE_RADIUS    4    /* Stable circle radius (pixels) */
#define DOT_CIRCLE_MAX_RADIUS       8   /* Maximum circle radius (pixels) */
#define DOT_CIRCLE_ANIM_FRAMES      8    /* Total animation frames */

/* ========================================
 * Mark Animation Configuration (for MARK display)
 * ======================================== */

/* Mark animation frame counts */
#define MARK_ANIM_FRAMES_FAST        15    /* Total frames for fast mode */
#define MARK_ANIM_FRAMES_NORMAL      30    /* Total frames for normal mode (reserved) */

/* White circle parameters */
#define MARK_WHITE_CIRCLE_MAX_RADIUS     6   /* Maximum radius of white circle */
#define MARK_WHITE_CIRCLE_STABLE_RADIUS  4   /* Stable radius of white circle */

/* Black circle parameters */
#define MARK_BLACK_CIRCLE_MAX_RADIUS     4   /* Maximum radius of black circle */
#define MARK_BLACK_CIRCLE_STABLE_RADIUS  2   /* Stable radius of black circle */

/* Vertical line parameters */
#define MARK_LINE_THICKNESS             2    /* Line thickness in pixels */
#define MARK_LINE_STABLE_LENGTH         12    /* Stable length of each line segment */
#define MARK_LINE_MAX_LENGTH            14   /* Maximum length of each line segment */
#define MARK_LINE_OFFSET_FROM_WHITE     2    /* Pixels offset from white circle stable radius */

/* Animation timing */
#define MARK_EXPAND_PHASE_RATIO         0.5f /* Ratio of frames for expansion phase (0.0-1.0) */

/* ========================================
 * Info Page Display Layout Constants
 * ======================================== */

#define BATTERY_TO_DIGITS_OFFSET 2    /* Pixels between battery icon and first digit */
#define PERCENT_OFFSET_FROM_DIGITS 1  /* Pixels between last digit and % sign */
#define DIGIT_WIDTH 6                 /* Width of each digit in pixels */
#define DIGIT_GAP 1                   /* Gap between digits in pixels */

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

/* ========================================
 * Info Page Display - Battery & Status
 * ======================================== */

/**
 * @brief 6x12 Digits in Row-Major Format (for icon_draw_bitmap)
 * Converted from Spleen 6x12 BDF
 * Format: row-major, 1 byte per row (6 pixels in high bits)
 */
static const uint8_t digit_6x12_row_major[10][12] = {
	/* '0' */
	{0x00, 0x70, 0x88, 0x98, 0xA8, 0xC8, 0x88, 0x88, 0x70, 0x00, 0x00, 0x00},
	/* '1' */
	{0x00, 0x20, 0x60, 0x20, 0x20, 0x20, 0x20, 0x20, 0x70, 0x00, 0x00, 0x00},
	/* '2' */
	{0x00, 0x70, 0x88, 0x08, 0x08, 0x70, 0x80, 0x80, 0xF8, 0x00, 0x00, 0x00},
	/* '3' */
	{0x00, 0x70, 0x88, 0x08, 0x30, 0x08, 0x08, 0x88, 0x70, 0x00, 0x00, 0x00},
	/* '4' */
	{0x00, 0x80, 0x80, 0x90, 0x90, 0x90, 0xF8, 0x10, 0x10, 0x00, 0x00, 0x00},
	/* '5' */
	{0x00, 0xF8, 0x80, 0x80, 0xF0, 0x08, 0x08, 0x08, 0xF0, 0x00, 0x00, 0x00},
	/* '6' */
	{0x00, 0x70, 0x80, 0x80, 0xF0, 0x88, 0x88, 0x88, 0x70, 0x00, 0x00, 0x00},
	/* '7' */
	{0x00, 0xF8, 0x88, 0x08, 0x10, 0x20, 0x20, 0x20, 0x20, 0x00, 0x00, 0x00},
	/* '8' */
	{0x00, 0x70, 0x88, 0x88, 0x70, 0x88, 0x88, 0x88, 0x70, 0x00, 0x00, 0x00},
	/* '9' */
	{0x00, 0x70, 0x88, 0x88, 0x88, 0x78, 0x08, 0x08, 0x70, 0x00, 0x00, 0x00},
};

/**
 * @brief 8x8 Percent Sign (Public Domain)
 * Source: https://github.com/dhepper/font8x8
 */
static const uint8_t percent_8x8[8] = {0x00, 0x63, 0x33, 0x18, 0x0C, 0x66, 0x63, 0x00};

/**
 * @brief Draw digit using row-major format (6x12 pixels)
 */
static void draw_digit_large(uint8_t *buf, char c, int x, int y)
{
	if (c >= '0' && c <= '9') {
		int digit = c - '0';
		const uint8_t *bitmap = digit_6x12_row_major[digit];
		icon_draw_bitmap(buf, x, y, bitmap, 6, 12);
	}
}

/**
 * @brief Draw percent sign (8x8 pixels)
 */
static void draw_large_percent(uint8_t *buf, int x, int y)
{
	for (int row = 0; row < 8; row++) {
		uint8_t row_data = percent_8x8[row];
		for (int col = 0; col < 8; col++) {
			if (row_data & (1 << (7 - col))) {
				set_pixel_direct(buf, x + col, y + row);
			}
		}
	}
}

/**
 * @brief Draw battery icon based on charging status and level
 */
static void draw_battery_by_level(uint8_t *buf, int x, int y, uint8_t percent, bool charging)
{
	icon_id_t icon_id;

	if (charging) {
		icon_id = ICON_BATTERY_CHARGING;
	} else if (percent >= 50) {
		icon_id = ICON_BATTERY_FULL;
	} else {
		icon_id = ICON_BATTERY_LOW;
	}

	const uint8_t *bitmap = icon_get_bitmap(icon_id, NULL, NULL);
	if (bitmap) {
		icon_draw_bitmap(buf, x, y, bitmap, ICON_WIDTH, ICON_HEIGHT);
	}
}

/**
 * @brief Draw BLE connection icon
 */
static void draw_ble_icon(uint8_t *buf, int x, int y, bool connected)
{
	if (connected) {
		const uint8_t *bitmap = icon_get_bitmap(ICON_BLE_CONNECTED, NULL, NULL);
		if (bitmap) {
			icon_draw_bitmap(buf, x, y, bitmap, ICON_WIDTH, ICON_HEIGHT);
		}
	}
}

/**
 * @brief Draw transfer icon
 */
static void draw_transfer_icon(uint8_t *buf, int x, int y)
{
	const uint8_t *bitmap = icon_get_bitmap(ICON_WIFI_TRANSFER, NULL, NULL);
	if (bitmap) {
		icon_draw_bitmap(buf, x, y, bitmap, ICON_WIDTH, ICON_HEIGHT);
	}
}

/* ========================================
 * Info Page Rendering
 * ======================================== */

/**
 * @brief Display info data structure
 */
typedef struct {
	uint8_t battery_percent;
	bool charging;
	bool ble_connected;
	bool transferring;
} display_info_t;

/**
 * @brief Render info page with battery and status
 * @param buf Frame buffer
 * @param info Display info data (NULL for defaults)
 */
static void render_info_page(uint8_t *buf, const display_info_t *info)
{
	clear_screen(buf);

	/* Default values if info is NULL */
	uint8_t battery = info ? info->battery_percent : 100;
	bool charging = info ? info->charging : false;
	bool ble_connected = info ? info->ble_connected : false;
	bool transferring = info ? info->transferring : false;

	/*
	 * UI Layout (88px x 48px):
	 *
	 * Position breakdown:
	 * - Battery icon:     (4, 16) - 16x16, vertically centered
	 * - "100" text:       (19, 16) - aligned with battery top
	 * - "%" symbol:        (45, 15) - large percent
	 * - BLE icon:         (52, 17) - 16x16
	 * - Transfer icon:     (68, 17) - 16x16
	 */

	/* 1. Battery icon at (4, 16) */
	draw_battery_by_level(buf, 4, 16, battery, charging);

	/* 2. Battery percentage "100" text - scaled font (6x12 pixels) */
	char pct_str[8];
	snprintk(pct_str, sizeof(pct_str), "%u", battery);
	int digit_x = 16 + BATTERY_TO_DIGITS_OFFSET;
	int digit_y = 20;  /* Vertically centered with battery icon */
	const char *p = pct_str;
	while (*p && digit_x < OLED_WIDTH - 6) {
		draw_digit_large(buf, *p, digit_x, digit_y);
		digit_x += DIGIT_WIDTH + DIGIT_GAP;
		p++;
	}

	/* 3. Percent symbol "%" (8x8 pixels) */
	int percent_x = digit_x + PERCENT_OFFSET_FROM_DIGITS;
	int percent_y = 20;
	draw_large_percent(buf, percent_x, percent_y);

	/* 4. Connection/Transfer icons at (52, 17) and (68, 17) */
	/* Priority: Transferring > BLE > Nothing */
	if (transferring) {
		draw_transfer_icon(buf, 68, 17);
	} else if (ble_connected) {
		draw_ble_icon(buf, 68, 17, true);
	}
}

/* ========================================
 * Public API - Info Display
 * ======================================== */

/**
 * @brief Show info page with battery and status
 * @param battery_percent Battery percentage (0-100)
 * @param charging Charging status
 * @param ble_connected BLE connection status
 * @param transferring File transfer status
 */
void display_show_info(uint8_t battery_percent, bool charging, bool ble_connected, bool transferring)
{
	display_info_t info = {
		.battery_percent = battery_percent,
		.charging = charging,
		.ble_connected = ble_connected,
		.transferring = transferring,
	};

	render_info_page(display_buffer, &info);
	flush_display();
}

/**
 * @brief Draw a circle mark (●) at the center
 * @param buf Frame buffer
 * @param radius Circle radius
 * @param scale Current scale factor for animation (0.0 to 1.0)
 */
static void draw_circle_mark(uint8_t *buf, int radius, float scale)
{
	const int x_mid = OLED_WIDTH / 2;
	const int y_mid = OLED_HEIGHT / 2;

	/* Calculate scaled radius */
	int scaled_radius = (int)(radius * scale);
	if (scaled_radius < 1) scaled_radius = 1;

	/* Draw filled circle using distance check */
	for (int dy = -scaled_radius; dy <= scaled_radius; dy++) {
		for (int dx = -scaled_radius; dx <= scaled_radius; dx++) {
			int x = x_mid + dx;
			int y = y_mid + dy;

			/* Check bounds */
			if (x < 0 || x >= OLED_WIDTH || y < 0 || y >= OLED_HEIGHT) {
				continue;
			}

			/* Check if point is inside circle (using squared distance to avoid sqrt) */
			int dist_sq = dx * dx + dy * dy;
			int radius_sq = scaled_radius * scaled_radius;

			if (dist_sq <= radius_sq) {
				set_pixel_direct(buf, x, y);
			}
		}
	}
}

/**
 * @brief Render mark page with circle animation
 * @param buf Frame buffer
 * @param frame Animation frame (0-7 for 8-frame loop)
 */
static void render_mark_page(uint8_t *buf, int frame)
{
	clear_screen(buf);

	/* Animation parameters */
	const int total_frames = DOT_CIRCLE_ANIM_FRAMES;

	/* Calculate current radius: stable → max → stable */
	/* Using sine wave for smooth animation (0 → 1 → 0) */
	float phase = (float)frame / (float)total_frames;  /* 0.0 to 1.0 */
	float sine_val = (1.0f - (float)cosf(phase * 6.28318f)) / 2.0f;  /* 0 to 1 to 0 */

	/* Map sine value to radius range */
	int current_radius = DOT_CIRCLE_STABLE_RADIUS +
		(int)((DOT_CIRCLE_MAX_RADIUS - DOT_CIRCLE_STABLE_RADIUS) * sine_val);

	/* Draw the animated circle with current radius (no scale) */
	draw_circle_mark(buf, current_radius, 1.0f);
}

/**
 * @brief Show a single frame of the circle mark animation
 * @param frame Animation frame number (0-7 for 8-frame loop)
 *
 * Renders an animated circle (●) that pulses in size.
 * Call repeatedly with incrementing frame numbers for smooth animation.
 */
void display_show_mark_cross_frame(int frame)
{
	render_mark_page(display_buffer, frame);
	flush_display();
}

/* ========================================
 * Mark Animation Implementation
 * (Macro definitions at top of file)
 * ======================================== */

/**
 * @brief Draw a black circle (clears pixels) at the center
 * @param buf Frame buffer
 * @param radius Circle radius
 * @param scale Current scale factor for animation (0.0 to 1.0)
 */
static void draw_black_circle(uint8_t *buf, int radius, float scale)
{
	const int x_mid = OLED_WIDTH / 2;
	const int y_mid = OLED_HEIGHT / 2;

	/* Calculate scaled radius */
	int scaled_radius = (int)(radius * scale);
	if (scaled_radius < 0) scaled_radius = 0;

	/* Clear pixels for filled circle using distance check */
	for (int dy = -scaled_radius; dy <= scaled_radius; dy++) {
		for (int dx = -scaled_radius; dx <= scaled_radius; dx++) {
			int x = x_mid + dx;
			int y = y_mid + dy;

			/* Check bounds */
			if (x < 0 || x >= OLED_WIDTH || y < 0 || y >= OLED_HEIGHT) {
				continue;
			}

			/* Check if point is inside circle */
			int dist_sq = dx * dx + dy * dy;
			int radius_sq = scaled_radius * scaled_radius;

			if (dist_sq <= radius_sq) {
				clear_pixel_direct(buf, x, y);
			}
		}
	}
}

/**
 * @brief Draw vertical lines (top and bottom) on the center axis
 * @param buf Frame buffer
 * @param white_circle_radius Current white circle radius
 * @param line_length Length of each line segment
 * @param thickness Line thickness
 * @param offset_pixels Offset from white circle stable radius
 */
static void draw_vertical_lines(uint8_t *buf, int white_circle_radius, int line_length,
				 int thickness, int offset_pixels)
{
	const int x_mid = OLED_WIDTH / 2;
	const int y_mid = OLED_HEIGHT / 2;

	/* Calculate starting positions */
	/* Top line: starts at (white_radius + offset) above center */
	int top_start_y = y_mid - white_circle_radius - offset_pixels;
	/* Bottom line: starts at (white_radius + offset) below center */
	int bottom_start_y = y_mid + white_circle_radius + offset_pixels;

	/* Draw top line (going up) */
	for (int i = 0; i < line_length; i++) {
		for (int t = 0; t < thickness; t++) {
			int x = x_mid - (thickness / 2) + t;
			int y = top_start_y - i;
			if (x >= 0 && x < OLED_WIDTH && y >= 0 && y < OLED_HEIGHT) {
				set_pixel_direct(buf, x, y);
			}
		}
	}

	/* Draw bottom line (going down) */
	for (int i = 0; i < line_length; i++) {
		for (int t = 0; t < thickness; t++) {
			int x = x_mid - (thickness / 2) + t;
			int y = bottom_start_y + i;
			if (x >= 0 && x < OLED_WIDTH && y >= 0 && y < OLED_HEIGHT) {
				set_pixel_direct(buf, x, y);
			}
		}
	}
}

/**
 * @brief Calculate animation progress (0.0 to 1.0 and back to 0.0) using sine wave
 * @param frame Current frame number
 * @param total_frames Total frames in animation
 * @return Synchronized value (0.0 = start/end, 1.0 = peak at middle)
 */
static float get_animation_progress(int frame, int total_frames)
{
	/* Use sine wave for smooth 0 → 1 → 0 transition */
	float phase = (float)frame / (float)total_frames;  /* 0.0 to 1.0 */
	float sine_val = (1.0f - (float)cosf(phase * 6.28318f)) / 2.0f;  /* 0 to 1 to 0 */
	return sine_val;
}

/**
 * @brief Render mark animation frame
 * @param buf Frame buffer
 * @param frame Animation frame number
 * @param total_frames Total frames in animation
 */
static void render_mark_animation_frame(uint8_t *buf, int frame, int total_frames)
{
	clear_screen(buf);

	/* Get synchronized animation value (0.0 → 1.0 → 0.0) */
	float anim_value = get_animation_progress(frame, total_frames);

	/* 1. Draw white circle first (base layer) */
	/* White circle: stable → max → stable */
	int white_radius = MARK_WHITE_CIRCLE_STABLE_RADIUS +
		(int)((MARK_WHITE_CIRCLE_MAX_RADIUS - MARK_WHITE_CIRCLE_STABLE_RADIUS) * anim_value);
	draw_circle_mark(buf, white_radius, 1.0f);

	/* 2. Draw black circle on top */
	/* Black circle: 0 → max → stable (smaller than white stable) */
	int black_radius;
	if (anim_value <= 0.5f) {
		/* First half: 0 → max (scale 0→1, anim_value is 0→0.5, so multiply by 2) */
		black_radius = (int)(MARK_BLACK_CIRCLE_MAX_RADIUS * (anim_value * 2.0f));
	} else {
		/* Second half: max → stable (anim_value is 0.5→1, map to 1→0) */
		float contract = 1.0f - ((anim_value - 0.5f) * 2.0f);  /* 1.0 → 0.0 */
		black_radius = MARK_BLACK_CIRCLE_STABLE_RADIUS +
			(int)((MARK_BLACK_CIRCLE_MAX_RADIUS - MARK_BLACK_CIRCLE_STABLE_RADIUS) * contract);
	}
	draw_black_circle(buf, black_radius, 1.0f);

	/* 3. Draw vertical lines */
	/* Lines: stable → max → stable */
	int line_length = MARK_LINE_STABLE_LENGTH +
		(int)((MARK_LINE_MAX_LENGTH - MARK_LINE_STABLE_LENGTH) * anim_value);
	draw_vertical_lines(buf, white_radius, line_length, MARK_LINE_THICKNESS,
			    MARK_LINE_OFFSET_FROM_WHITE);
}

/**
 * @brief Show a single frame of the mark animation
 * @param frame Animation frame number
 * @param fast_mode true for fast mode (30 frames), false for normal mode (60 frames)
 *
 * Renders the mark animation with white circle, black circle, and vertical lines.
 * Call repeatedly with incrementing frame numbers for smooth animation.
 */
void display_show_mark_animation_frame(int frame, bool fast_mode)
{
	int total_frames = fast_mode ? MARK_ANIM_FRAMES_FAST : MARK_ANIM_FRAMES_NORMAL;
	render_mark_animation_frame(display_buffer, frame, total_frames);
	flush_display();
}

