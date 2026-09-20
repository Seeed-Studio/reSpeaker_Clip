/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/storage/disk_access.h>
#include <zephyr/fs/fs.h>
#include <zephyr/drivers/regulator.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/pm/device.h>
#include <ff.h>
#include <zephyr/logging/log.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>

#include "storage.h"

LOG_MODULE_REGISTER(storage, CONFIG_CLIP_LOG_LEVEL);

/* SD Card and File System */
static FATFS fat_fs;
static struct fs_mount_t mp = {
    .type = FS_FATFS,
    .fs_data = &fat_fs,
    .mnt_point = "/SD:",
};
static bool sd_mounted = false;
static bool sd_powered = false;
static bool sd_full = false;     /* latched on write failure; cleared when free space recovers */

/* SD power-gating handles: LDO2 rail, SPI4 bus, and CS pin parking */
static const struct device *const sd_ldo2 = DEVICE_DT_GET(DT_NODELABEL(npm1300_ldo2));
static const struct device *const sd_spi4 = DEVICE_DT_GET(DT_NODELABEL(spi4));
static const struct device *const sd_gpio0 = DEVICE_DT_GET(DT_NODELABEL(gpio0));
#define STORAGE_SD_CS_PIN 9

/* Serialize SD power lifecycle vs concurrent AT/recording access */
static K_MUTEX_DEFINE(sd_lifecycle_mutex);

/* Activity callback: re-arms the idle power-off timer (set by clip_event) */
static storage_activity_cb_t sd_activity_cb;

/* Busy callback: returns true if SD must not be powered off (checked under lock) */
static storage_busy_cb_t sd_busy_cb;

/* Base path for recordings */
#define STORAGE_BASE_PATH "/SD:/REC"

/* Write buffer for efficient SD card operations */
static uint8_t write_buffer[CONFIG_CLIP_STORAGE_CHUNK_SIZE];
static uint32_t buffer_pos = 0;
static struct fs_file_t *current_file_ptr = NULL;

/* Statistics */
static uint32_t total_chunks = 0;
static uint64_t total_bytes = 0;
static uint32_t free_space_mb = 0;
static uint32_t sd_total_mb = 0;
static uint64_t session_bytes_base = 0;  /* total_bytes at session start */

/* Current recording session */
static char current_session_id[STORAGE_SESSION_ID_LEN] = {0};

/* Track current writing file for transfer coordination */
static char writing_session[STORAGE_SESSION_ID_LEN] = {0};
static char writing_filename[STORAGE_FILENAME_MAX_LEN] = {0};

/* Semaphore to signal when a file is closed and ready for transfer */
static K_SEM_DEFINE(file_closed_sem, 0, 1);

/* Mutex to serialize session.json read-modify-write across threads */
static K_MUTEX_DEFINE(session_json_mutex);

/* Internal functions */
static int update_free_space(void);
static int create_marks_file(const char *path);
static int create_session_json(const char *path, const char *session_id,
                               uint8_t channels, uint32_t sample_rate,
                               const char *mode);
static int update_session_json(const char *session_id, uint32_t duration_sec,
                               uint32_t chunk_count, uint64_t session_bytes);
static int flush_write_buffer(void);
static void delete_dir_contents(const char *dir_path);
static int validate_session_id(const char *session_id);
static int scan_session_ids(char ids[][16], int max_ids, int *total);

static int storage_path_format(char *path, size_t path_size, const char *fmt, ...)
{
    va_list ap;
    int written;

    if (!path || path_size == 0) {
        return -EINVAL;
    }

    va_start(ap, fmt);
    written = vsnprintf(path, path_size, fmt, ap);
    va_end(ap);

    if (written < 0 || (size_t)written >= path_size) {
        path[0] = '\0';
        return -ENAMETOOLONG;
    }

    return 0;
}

static int build_bucket_dir(const char *session_id, char *path, size_t path_size)
{
    if (validate_session_id(session_id) != 0) {
        return -EINVAL;
    }

    return storage_path_format(path, path_size, "%s/%.8s/%.2s/%.2s",
                               STORAGE_BASE_PATH, session_id, session_id + 8,
                               session_id + 10);
}

static int build_bucket_session_dir(const char *session_id, char *path,
                                    size_t path_size)
{
    char bucket_dir[STORAGE_PATH_MAX];
    int rc;

    rc = build_bucket_dir(session_id, bucket_dir, sizeof(bucket_dir));
    if (rc != 0) {
        return rc;
    }
    return storage_path_format(path, path_size, "%s/%.2s", bucket_dir,
                               session_id + 12);
}

static int build_session_metadata_path(const char *session_id, char *path,
                                       size_t path_size)
{
    char dir[STORAGE_PATH_MAX];
    int rc;

    rc = build_bucket_session_dir(session_id, dir, sizeof(dir));
    if (rc != 0) {
        return rc;
    }
    return storage_path_format(path, path_size, "%s/session.json", dir);
}

static int build_marks_path(const char *session_id, char *path,
                            size_t path_size)
{
    char dir[STORAGE_PATH_MAX];
    int rc;

    rc = build_bucket_session_dir(session_id, dir, sizeof(dir));
    if (rc != 0) {
        return rc;
    }
    return storage_path_format(path, path_size, "%s/marks.bin", dir);
}

int storage_build_chunk_path(const char *session_id, uint32_t chunk_index,
                             char *path, size_t path_size)
{
    char dir[STORAGE_PATH_MAX];
    int rc;

    if (chunk_index == 0 || validate_session_id(session_id) != 0) {
        return -EINVAL;
    }

    rc = build_bucket_session_dir(session_id, dir, sizeof(dir));
    if (rc != 0) {
        return rc;
    }
    return storage_path_format(path, path_size, "%s/%u/%04u.opus", dir,
                               (chunk_index - 1) /
                               CONFIG_CLIP_STORAGE_FILES_PER_GROUP,
                               chunk_index);
}

int storage_build_session_metadata_path(const char *session_id,
                                        char *path, size_t path_size)
{
    return build_session_metadata_path(session_id, path, path_size);
}

static int ensure_directory(const char *path)
{
    struct fs_dirent entry;
    int rc = fs_stat(path, &entry);

    if (rc == 0) {
        return entry.type == FS_DIR_ENTRY_DIR ? 0 : -ENOTDIR;
    }

    rc = fs_mkdir(path);
    return (rc == 0 || rc == -EEXIST) ? 0 : rc;
}

static int ensure_bucket_directories(const char *session_id)
{
    char path[STORAGE_PATH_MAX];
    char session_dir[STORAGE_PATH_MAX];
    int rc;

    rc = storage_path_format(path, sizeof(path), "%s/%.8s", STORAGE_BASE_PATH,
                             session_id);
    if (rc != 0 || (rc = ensure_directory(path)) != 0) {
        return rc;
    }
    rc = storage_path_format(path, sizeof(path), "%s/%.8s/%.2s",
                             STORAGE_BASE_PATH, session_id, session_id + 8);
    if (rc != 0 || (rc = ensure_directory(path)) != 0) {
        return rc;
    }
    rc = build_bucket_dir(session_id, path, sizeof(path));
    if (rc != 0) {
        return rc;
    }
    rc = ensure_directory(path);
    if (rc != 0) {
        return rc;
    }
    rc = build_bucket_session_dir(session_id, session_dir, sizeof(session_dir));
    if (rc != 0) {
        return rc;
    }
    rc = ensure_directory(session_dir);
    if (rc != 0) {
        return rc;
    }
    rc = storage_path_format(path, sizeof(path), "%s/0", session_dir);
    if (rc != 0) {
        return rc;
    }
    return ensure_directory(path);
}

static int ensure_time_bucket_chunk_directory(const char *session_id,
                                              uint32_t chunk_index)
{
    char session_dir[STORAGE_PATH_MAX];
    char group_dir[STORAGE_PATH_MAX];
    int rc;

    rc = build_bucket_session_dir(session_id, session_dir, sizeof(session_dir));
    if (rc != 0) {
        return rc;
    }
    rc = storage_path_format(group_dir, sizeof(group_dir), "%s/%u", session_dir,
                             (chunk_index - 1) /
                             CONFIG_CLIP_STORAGE_FILES_PER_GROUP);
    if (rc != 0) {
        return rc;
    }
    return ensure_directory(group_dir);
}

int storage_init(void)
{
    int rc;
    struct fs_dirent entry;

    /* Enable SD card power via NPM1300 LDO2 */
    const struct device *ldo2 = DEVICE_DT_GET(DT_NODELABEL(npm1300_ldo2));
    if (device_is_ready(ldo2)) {
        regulator_enable(ldo2);
        k_msleep(20);
    }

    LOG_INF("SD init");

    /* Card power-up race: the LDO2 ramp plus the card's internal init
     * can exceed the settle delay on some cards / temperatures. A boot
     * mount failure here is expensive — recording must then lazily
     * remount, and the one-shot boot-time unsynced-audio check in
     * main() is skipped entirely (the UI then misses existing
     * recordings until the next reboot). Retry with a growing delay. */
    for (int attempt = 1;; attempt++) {
        /* Initialize SD card. -ENOTSUP = already initialized (same
         * tolerance as storage_resume/storage_ensure_mounted below):
         * without it, a first-attempt init success + mount failure
         * would exit every later attempt at the init step and the
         * fs_mount retry would never run — recreating the exact
         * boot degradation this loop exists to fix. */
        rc = disk_access_init("SD");
        if (rc != 0 && rc != -ENOTSUP) {
            if (attempt < 4) {
                LOG_WRN("SD init failed: %d (attempt %d)", rc, attempt);
                k_msleep(100 * attempt);
                continue;
            }
            LOG_WRN("SD init failed: %d", rc);
            return rc;
        }

        /* Mount filesystem */
        rc = fs_mount(&mp);
        if (rc == 0) {
            break;
        }
        if (attempt < 4) {
            LOG_WRN("SD mount failed: %d (attempt %d)", rc, attempt);
            k_msleep(100 * attempt);
            continue;
        }
        LOG_WRN("SD mount failed: %d", rc);
        sd_mounted = false;
        return rc;
    }

    sd_mounted = true;
    sd_powered = true;
    LOG_INF("SD card mounted at /SD:");

    /* Create base REC directory if not exists */
    rc = fs_stat(STORAGE_BASE_PATH, &entry);
    if (rc != 0 || entry.type != FS_DIR_ENTRY_DIR)
    {
        rc = fs_mkdir(STORAGE_BASE_PATH);
        if (rc != 0 && rc != -EEXIST)
        {
            LOG_ERR("Failed to create REC directory: %d", rc);
            return rc;
        }
    }

    update_free_space();

    return 0;
}

void storage_cleanup(void)
{
    if (sd_mounted)
    {
        fs_unmount(&mp);
        sd_mounted = false;
    }
}

int storage_idle_poweroff(void)
{
    char ws[STORAGE_SESSION_ID_LEN], wf[STORAGE_FILENAME_MAX_LEN];

    k_mutex_lock(&sd_lifecycle_mutex, K_FOREVER);

    if (!sd_powered) {
        k_mutex_unlock(&sd_lifecycle_mutex);
        return 0;                       /* idempotent */
    }

    /* Re-check everything UNDER the lock: a recording/transfer/AT that starts
     * between the work handler's unlocked tick and here must not have its FAT
     * FS unmounted and rail cut underneath it (closes the TOCTOU). */
    if (storage_get_writing_file(ws, wf, sizeof(ws), sizeof(wf))) {
        k_mutex_unlock(&sd_lifecycle_mutex);
        return -EBUSY;
    }
    if (sd_busy_cb && sd_busy_cb()) {
        k_mutex_unlock(&sd_lifecycle_mutex);
        return -EBUSY;
    }

    /* Park CS low and cut the rail. ORDER: SPI4 suspend (its sleep pinctrl
     * pulls SCK/MOSI/MISO low) -> park CS low -> cut LDO2, so the unpowered
     * card never sees a high level on any pin. SCK/MOSI/MISO are NOT touched
     * here — the SPI4 sleep pinctrl handles them; reconfiguring them raises
     * leakage (matches samples/suspend_to_ram spi4_suspend()). */
    if (sd_mounted) {
        /* Refresh the cached free/total right before unmount so status
         * queries while idle report post-write values (e.g. after a
         * recording), not the pre-write cache. */
        (void)update_free_space();
        (void)fs_unmount(&mp);
        sd_mounted = false;
    }
    (void)disk_access_ioctl("SD", DISK_IOCTL_CTRL_DEINIT, NULL);

    if (device_is_ready(sd_spi4)) {
        /* Usually already suspended by runtime PM (-EALREADY); explicit call
         * is a safety net guaranteeing the sleep pinctrl is applied. */
        (void)pm_device_action_run(sd_spi4, PM_DEVICE_ACTION_SUSPEND);
    }
    if (device_is_ready(sd_gpio0)) {
        (void)gpio_pin_configure(sd_gpio0, STORAGE_SD_CS_PIN,
                                 GPIO_INPUT | GPIO_PULL_DOWN);
    }
    if (device_is_ready(sd_ldo2)) {
        (void)regulator_disable(sd_ldo2);
    }

    sd_powered = false;
    LOG_DBG("SD idle power-off (LDO2 off, CS low)");
    k_mutex_unlock(&sd_lifecycle_mutex);
    return 0;
}

int storage_remount(void)
{
    int rc;

    if (sd_mounted) {
        return 0;
    }

    /* Re-initialize SD card (-ENOTSUP = already initialized, e.g. after MSC release) */
    rc = disk_access_init("SD");
    if (rc != 0 && rc != -ENOTSUP) {
        LOG_ERR("SD reinit failed: %d", rc);
        return rc;
    }

    /* Remount FATFS */
    rc = fs_mount(&mp);
    if (rc != 0) {
        LOG_ERR("SD remount failed: %d", rc);
        return rc;
    }

    sd_mounted = true;
    LOG_INF("SD remounted");

    update_free_space();
    return 0;
}

int storage_resume(void)
{
    int rc;

    k_mutex_lock(&sd_lifecycle_mutex, K_FOREVER);

    if (sd_mounted && sd_powered) {
        k_mutex_unlock(&sd_lifecycle_mutex);
        return 0;                       /* idempotent, stale-safe */
    }

    LOG_INF("SD resume start");
    if (device_is_ready(sd_ldo2)) {
        (void)regulator_enable(sd_ldo2);
        k_msleep(100);
    }
    if (device_is_ready(sd_spi4)) {
        (void)pm_device_action_run(sd_spi4, PM_DEVICE_ACTION_RESUME);
    }
    if (device_is_ready(sd_gpio0)) {
        /* CS restored deselected (physical HIGH); GPIO_ACTIVE_LOW preserved */
        (void)gpio_pin_configure(sd_gpio0, STORAGE_SD_CS_PIN,
                                 GPIO_OUTPUT_HIGH | GPIO_ACTIVE_LOW);
    }

    rc = disk_access_init("SD");
    if (rc != 0 && rc != -ENOTSUP) {
        LOG_ERR("SD disk init failed: %d", rc);
        k_mutex_unlock(&sd_lifecycle_mutex);
        return rc;
    }
    rc = fs_mount(&mp);
    if (rc != 0) {
        LOG_ERR("SD remount failed: %d", rc);
        k_mutex_unlock(&sd_lifecycle_mutex);
        return rc;
    }

    sd_mounted = true;
    sd_powered = true;
    update_free_space();
    k_mutex_unlock(&sd_lifecycle_mutex);
    LOG_INF("SD resumed (mounted)");
    return 0;
}

int storage_ensure_mounted(void)
{
    int rc = storage_resume();          /* idempotent + locked internally */

    if (rc == 0 && sd_activity_cb) {
        sd_activity_cb();               /* re-arm idle power-off timer */
    }
    return rc;
}

bool storage_is_sd_powered(void)
{
    return sd_powered;
}

void storage_set_activity_cb(storage_activity_cb_t cb)
{
    sd_activity_cb = cb;
}

void storage_set_busy_cb(storage_busy_cb_t cb)
{
    sd_busy_cb = cb;
}

bool storage_is_mounted(void)
{
    return sd_mounted;
}

bool storage_is_full(void)
{
    if (sd_full) {
        return true;
    }
    if (sd_total_mb == 0) {
        return false;   /* size unknown — don't block recording */
    }
    /* Full when free% <= (100 - threshold), i.e. usage >= threshold */
    return (free_space_mb * 100U) <= ((100U - CONFIG_CLIP_STORAGE_FULL_PERCENT) * sd_total_mb);
}

int storage_get_stats(struct storage_stats *stats)
{
    if (!stats)
    {
        return -EINVAL;
    }

    memset(stats, 0, sizeof(*stats));
    stats->is_mounted = sd_mounted;
    stats->total_chunks = total_chunks;
    stats->total_bytes = total_bytes;

    if (sd_mounted)
    {
        update_free_space();
        /* Clear the full latch once free space recovers (usage drops below
         * the threshold, e.g. after the user deletes sessions). */
        if (sd_total_mb > 0 &&
            (free_space_mb * 100U) > ((100U - CONFIG_CLIP_STORAGE_FULL_PERCENT) * sd_total_mb)) {
            sd_full = false;
        }
    }

    /* Report last-known capacity/free even when the card is currently
     * unmounted (idle power-gate). free_space_mb / sd_total_mb survive
     * storage_idle_poweroff (not cleared), and free space does not change
     * while idle, so the cached values are accurate. is_mounted tells the
     * caller whether these are live or cached. Lets status queries
     * (GSTAT free_space, AT+STORAGE) report storage without waking the SD. */
    stats->free_space_mb = free_space_mb;
    stats->total_mb = sd_total_mb;

    return 0;
}

/* Session IDs are UTC timestamps: YYYYMMDDHHMMSS. Enforce the complete form
 * because the bucket layout slices it into date/hour/minute path components. */
static int validate_session_id(const char *session_id)
{
    if (!session_id || strlen(session_id) != 14) {
        return -EINVAL;
    }
    for (const char *p = session_id; *p; p++) {
        if (*p < '0' || *p > '9') {
            return -EINVAL;
        }
    }
    return 0;
}

int storage_create_session(const char *session_id, uint8_t channels,
                           uint32_t sample_rate, const char *mode)
{
    char metadata_path[STORAGE_PATH_MAX];
    char marks_path[STORAGE_PATH_MAX];
    int rc;

    if (!sd_mounted) {
        return -ENODEV;
    }
    if (validate_session_id(session_id) != 0) {
        return -EINVAL;
    }

    rc = ensure_bucket_directories(session_id);
    if (rc != 0) {
        LOG_ERR("Failed to create session bucket: %d", rc);
        return rc;
    }

    rc = build_session_metadata_path(session_id, metadata_path,
                                     sizeof(metadata_path));
    if (rc == 0) {
        rc = build_marks_path(session_id, marks_path, sizeof(marks_path));
    }
    if (rc != 0) {
        return rc;
    }

    LOG_INF("Creating session: %s", session_id);
    rc = create_marks_file(marks_path);
    if (rc != 0) {
        return rc;
    }
    rc = create_session_json(metadata_path, session_id, channels, sample_rate, mode);
    if (rc != 0) {
        return rc;
    }

    /* Store current session */
    strncpy(current_session_id, session_id, sizeof(current_session_id) - 1);
    current_session_id[sizeof(current_session_id) - 1] = '\0';
    session_bytes_base = total_bytes;

    return 0;
}

int storage_close_session(const char *session_id, uint32_t duration_sec,
                          uint32_t chunk_count)
{
    if (!session_id)
    {
        return -EINVAL;
    }

    uint64_t session_bytes = total_bytes - session_bytes_base;

    LOG_INF("session close: %s chunks=%u dur=%us",
            session_id, chunk_count, duration_sec);

    /* Update session.json with final values */
    update_session_json(session_id, duration_sec, chunk_count, session_bytes);

    /* Clear current session if matching */
    if (strcmp(current_session_id, session_id) == 0)
    {
        current_session_id[0] = '\0';
    }

    return 0;
}

int storage_write_chunk(const char *session_id, uint32_t chunk_index,
                        const uint8_t *data, uint32_t len)
{
    char filepath[STORAGE_PATH_MAX];
    struct fs_file_t file;
    int rc;
    ssize_t written;

    if (!sd_mounted || !data || validate_session_id(session_id) != 0 ||
        chunk_index == 0)
    {
        return -EINVAL;
    }

    if (len == 0)
    {
        return 0;
    }

    rc = ensure_time_bucket_chunk_directory(session_id, chunk_index);
    if (rc != 0) {
        return rc;
    }
    rc = storage_build_chunk_path(session_id, chunk_index, filepath,
                                  sizeof(filepath));
    if (rc != 0) {
        return rc;
    }

    /* Open file for writing */
    fs_file_t_init(&file);
    rc = fs_open(&file, filepath, FS_O_CREATE | FS_O_WRITE);
    if (rc != 0)
    {
        LOG_ERR("Failed to create chunk file %s: %d", filepath, rc);
        return rc;
    }

    /* Write data */
    written = fs_write(&file, data, len);
    fs_close(&file);

    if (written != len)
    {
        LOG_ERR("Write incomplete: %zd != %u", written, len);
        sd_full = true;
        return -EIO;
    }

    /* Update statistics */
    total_chunks++;
    total_bytes += len;

    return 0;
}

/* Flush write buffer to SD card */
static int flush_write_buffer(void)
{
    int rc;
    ssize_t written;

    if (buffer_pos == 0 || !current_file_ptr)
    {
        return 0;
    }

    written = fs_write(current_file_ptr, write_buffer, buffer_pos);
    if (written != buffer_pos)
    {
        LOG_ERR("Buffer flush incomplete: %zd != %u", written, buffer_pos);
        sd_full = true;
        return -EIO;
    }

    buffer_pos = 0;
    return 0;
}

int storage_create_file(struct storage_file *file, const char *session_id, uint32_t chunk_index)
{
    char filepath[STORAGE_PATH_MAX];
    char filename[32]; /* Just the filename, not full path */
    int rc;

    if (!sd_mounted || !file || validate_session_id(session_id) != 0 ||
        chunk_index == 0)
    {
        return -EINVAL;
    }

    /* Flush any existing buffer */
    if (current_file_ptr)
    {
        rc = flush_write_buffer();
        if (rc != 0)
        {
            return rc;
        }
        fs_close(current_file_ptr);
        current_file_ptr = NULL;
    }

    /* Initialize file structure */
    memset(file, 0, sizeof(*file));
    strncpy(file->session_id, session_id, sizeof(file->session_id) - 1);
    file->chunk_index = chunk_index;

    /* Generate filename: 0001.opus (4-digit format) */
    snprintf(filename, sizeof(filename), "%04u.opus", chunk_index);

    rc = ensure_time_bucket_chunk_directory(session_id, chunk_index);
    if (rc != 0) {
        return rc;
    }
    rc = storage_build_chunk_path(session_id, chunk_index, filepath,
                                  sizeof(filepath));
    if (rc != 0) {
        return rc;
    }
    strncpy(file->filename, filename, sizeof(file->filename) - 1);

    /* Open file */
    fs_file_t_init(&file->internal_file);
    LOG_INF("open: %s", filepath);
    rc = fs_open(&file->internal_file, filepath, FS_O_CREATE | FS_O_WRITE);
    if (rc != 0)
    {
        LOG_ERR("Failed to create file %s: %d", filepath, rc);
        return rc;
    }

    file->is_open = true;
    current_file_ptr = &file->internal_file;
    buffer_pos = 0;

    /* Mark this file as being written for transfer coordination */
    storage_set_writing_file(session_id, filename);

    LOG_INF("file: %s (chunk %u)", filepath, chunk_index);
    return 0;
}

int storage_write_frame(struct storage_file *file, const uint8_t *data, uint32_t len)
{
    int rc;
    uint8_t frame_len[2];

    if (!sd_mounted || !file || !file->is_open)
    {
        return -EINVAL;
    }

    if (len > 65535)
    {
        LOG_ERR("Frame too large: %u", len);
        return -EINVAL;
    }

    /* Write frame length as 2-byte little-endian */
    frame_len[0] = len & 0xFF;
    frame_len[1] = (len >> 8) & 0xFF;

    /* Write length to buffer */
    if (buffer_pos + 2 > CONFIG_CLIP_STORAGE_CHUNK_SIZE)
    {
        rc = flush_write_buffer();
        if (rc != 0)
        {
            return rc;
        }
    }

    write_buffer[buffer_pos++] = frame_len[0];
    write_buffer[buffer_pos++] = frame_len[1];

    /* Write frame data */
    uint32_t remaining = len;
    uint32_t offset = 0;

    while (remaining > 0)
    {
        uint32_t space = CONFIG_CLIP_STORAGE_CHUNK_SIZE - buffer_pos;
        uint32_t to_copy = (remaining < space) ? remaining : space;

        memcpy(&write_buffer[buffer_pos], &data[offset], to_copy);
        buffer_pos += to_copy;
        offset += to_copy;
        remaining -= to_copy;

        /* Flush buffer when full */
        if (buffer_pos >= CONFIG_CLIP_STORAGE_CHUNK_SIZE)
        {
            rc = flush_write_buffer();
            if (rc != 0)
            {
                return rc;
            }
        }
    }

    file->bytes_written += len + 2; /* +2 for length header */
    file->frames_written++;
    total_bytes += len + 2;

    return 0;
}

int storage_close_file(struct storage_file *file)
{
    int rc;

    if (!file || !file->is_open)
    {
        return -EINVAL;
    }

    /* Flush any remaining data in buffer */
    if (buffer_pos > 0)
    {
        rc = flush_write_buffer();
        if (rc != 0)
        {
            LOG_ERR("Failed to flush buffer: %d", rc);
        }
    }

    /* Sync file to ensure data is written to disk
     * Important for transfer-while-recording: files must be available immediately */
    if (current_file_ptr)
    {
        rc = fs_sync(current_file_ptr);
        if (rc != 0)
        {
            LOG_WRN("File sync failed: %d", rc);
        }

        fs_close(current_file_ptr);
        current_file_ptr = NULL;
    }

    /* Small delay to ensure file system has flushed data */
    k_sleep(K_MSEC(50));

    /* Clear writing file status - file is now ready for transfer */
    storage_set_writing_file(NULL, NULL);

    /* Signal that a file has been closed and is ready for transfer */
    k_sem_give(&file_closed_sem);

    LOG_DBG("File closed: %s (%u bytes, %u frames)",
            file->filename, file->bytes_written, file->frames_written);

    file->is_open = false;
    return 0;
}

int storage_read_chunk(const char *session_id, uint32_t chunk_index,
                       uint8_t *data, uint32_t len)
{
    char filepath[STORAGE_PATH_MAX];
    struct fs_file_t file;
    int rc;
    ssize_t bytes_read;

    if (!sd_mounted || !data || chunk_index == 0)
    {
        return -EINVAL;
    }

    rc = storage_build_chunk_path(session_id, chunk_index, filepath,
                                  sizeof(filepath));
    if (rc != 0) {
        return rc;
    }

    /* Open file for reading */
    fs_file_t_init(&file);
    rc = fs_open(&file, filepath, FS_O_READ);
    if (rc != 0)
    {
        LOG_ERR("Failed to open chunk file %s: %d", filepath, rc);
        return rc;
    }

    /* Read data */
    bytes_read = fs_read(&file, data, len);
    fs_close(&file);

    if (bytes_read < 0)
    {
        LOG_ERR("Read error: %zd", bytes_read);
        return (int)bytes_read;
    }

    return (int)bytes_read;
}

int storage_delete_chunk(const char *session_id, uint32_t chunk_index)
{
    char filepath[STORAGE_PATH_MAX];
    int rc;

    if (!sd_mounted || chunk_index == 0)
    {
        return -EINVAL;
    }

    rc = storage_build_chunk_path(session_id, chunk_index, filepath,
                                  sizeof(filepath));
    if (rc != 0) {
        return rc;
    }

    rc = fs_unlink(filepath);
    if (rc != 0)
    {
        LOG_WRN("Failed to delete chunk %s: %d", filepath, rc);
    }

    return rc;
}

int storage_list_sessions(struct storage_session_info *sessions, int max_sessions)
{
    char ids[200][16];
    int limit = MIN(max_sessions, (int)ARRAY_SIZE(ids));
    int id_count;
    int result = 0;

    if (!sd_mounted || !sessions || max_sessions <= 0) {
        return -EINVAL;
    }

    id_count = storage_list_session_ids(ids, limit);
    if (id_count < 0) {
        return id_count;
    }
    for (int i = 0; i < id_count; i++) {
        if (storage_get_session_info(ids[i], &sessions[result]) == 0) {
            result++;
        }
    }
    return result;
}

int storage_count_sessions(void)
{
    int total = 0;
    int scan_rc;

    if (!sd_mounted) {
        return -EINVAL;
    }
    scan_rc = scan_session_ids(NULL, 0, &total);
    return scan_rc < 0 ? scan_rc : total;
}

static bool is_decimal_name(const char *name, size_t length)
{
    if (!name || strlen(name) != length) {
        return false;
    }
    for (size_t i = 0; i < length; i++) {
        if (name[i] < '0' || name[i] > '9') {
            return false;
        }
    }
    return true;
}

static void add_session_id(char ids[][16], int max_ids, int *stored,
                           int *total, const char *session_id)
{
    if (total) {
        (*total)++;
    }
    if (!ids || max_ids <= 0 || !stored) {
        return;
    }

    for (int i = 0; i < *stored; i++) {
        if (strcmp(ids[i], session_id) == 0) {
            if (total) {
                (*total)--;
            }
            return;
        }
    }

    if (*stored < max_ids) {
        int pos = *stored;
        for (int i = 0; i < *stored; i++) {
            if (strcmp(session_id, ids[i]) > 0) {
                pos = i;
                break;
            }
        }
        for (int i = *stored; i > pos; i--) {
            memcpy(ids[i], ids[i - 1], 16);
        }
        strncpy(ids[pos], session_id, 15);
        ids[pos][15] = '\0';
        (*stored)++;
        return;
    }

    if (strcmp(session_id, ids[max_ids - 1]) > 0) {
        int pos = max_ids - 1;
        for (int i = 0; i < max_ids - 1; i++) {
            if (strcmp(session_id, ids[i]) > 0) {
                pos = i;
                break;
            }
        }
        for (int i = max_ids - 1; i > pos; i--) {
            memcpy(ids[i], ids[i - 1], 16);
        }
        strncpy(ids[pos], session_id, 15);
        ids[pos][15] = '\0';
    }
}

static int scan_bucket_sessions(const char *day_name, char ids[][16],
                                int max_ids, int *stored, int *total)
{
    char day_path[STORAGE_PATH_MAX];
    char hour_path[STORAGE_PATH_MAX];
    char minute_path[STORAGE_PATH_MAX];
    struct fs_dir_t day_dir;
    struct fs_dirent hour_entry;
    int rc;

    rc = storage_path_format(day_path, sizeof(day_path), "%s/%s",
                             STORAGE_BASE_PATH, day_name);
    if (rc != 0) {
        return rc;
    }
    fs_dir_t_init(&day_dir);
    rc = fs_opendir(&day_dir, day_path);
    if (rc != 0) {
        return rc;
    }

    while (fs_readdir(&day_dir, &hour_entry) == 0 && hour_entry.name[0] != '\0') {
        if (hour_entry.type != FS_DIR_ENTRY_DIR ||
            !is_decimal_name(hour_entry.name, 2)) {
            continue;
        }
        rc = storage_path_format(hour_path, sizeof(hour_path), "%s/%s",
                                 day_path, hour_entry.name);
        if (rc != 0) {
            fs_closedir(&day_dir);
            return rc;
        }

        struct fs_dir_t hour_dir;
        struct fs_dirent minute_entry;
        fs_dir_t_init(&hour_dir);
        if (fs_opendir(&hour_dir, hour_path) != 0) {
            continue;
        }
        while (fs_readdir(&hour_dir, &minute_entry) == 0 &&
               minute_entry.name[0] != '\0') {
            if (minute_entry.type != FS_DIR_ENTRY_DIR ||
                !is_decimal_name(minute_entry.name, 2)) {
                continue;
            }

            rc = storage_path_format(minute_path, sizeof(minute_path), "%s/%s",
                                     hour_path, minute_entry.name);
            if (rc != 0) {
                fs_closedir(&hour_dir);
                fs_closedir(&day_dir);
                return rc;
            }

            struct fs_dir_t minute_dir;
            struct fs_dirent session_entry;
            fs_dir_t_init(&minute_dir);
            if (fs_opendir(&minute_dir, minute_path) != 0) {
                continue;
            }
            while (fs_readdir(&minute_dir, &session_entry) == 0 &&
                   session_entry.name[0] != '\0') {
                char metadata_path[STORAGE_PATH_MAX];
                struct fs_dirent metadata_entry;

                if (session_entry.type != FS_DIR_ENTRY_DIR ||
                    !is_decimal_name(session_entry.name, 2)) {
                    continue;
                }
                rc = storage_path_format(metadata_path, sizeof(metadata_path),
                                         "%s/%s/session.json", minute_path,
                                         session_entry.name);
                if (rc != 0) {
                    fs_closedir(&minute_dir);
                    fs_closedir(&hour_dir);
                    fs_closedir(&day_dir);
                    return rc;
                }
                if (fs_stat(metadata_path, &metadata_entry) == 0 &&
                    metadata_entry.type == FS_DIR_ENTRY_FILE) {
                    char session_id[16];

                    rc = storage_path_format(session_id, sizeof(session_id),
                                             "%s%s%s%s", day_name,
                                             hour_entry.name,
                                             minute_entry.name,
                                             session_entry.name);
                    if (rc != 0) {
                        fs_closedir(&minute_dir);
                        fs_closedir(&hour_dir);
                        fs_closedir(&day_dir);
                        return rc;
                    }
                    add_session_id(ids, max_ids, stored, total, session_id);
                    /* Stop walking once enough IDs are collected — the tree
                     * can hold thousands of sessions but we only need max_ids
                     * (64 for the untransferred check, 200 for a LIST page).
                     * max_ids==0 means count-only, so keep walking. */
                    if (max_ids > 0 && *stored >= max_ids) {
                        fs_closedir(&minute_dir);
                        fs_closedir(&hour_dir);
                        fs_closedir(&day_dir);
                        return 0;
                    }
                }
            }
            fs_closedir(&minute_dir);
        }
        fs_closedir(&hour_dir);
    }
    fs_closedir(&day_dir);
    return 0;
}

static int scan_session_ids(char ids[][16], int max_ids, int *total)
{
    struct fs_dir_t root_dir;
    struct fs_dirent entry;
    int stored = 0;
    int count = 0;
    int rc;

    fs_dir_t_init(&root_dir);
    rc = fs_opendir(&root_dir, STORAGE_BASE_PATH);
    if (rc != 0) {
        return rc;
    }

    while (fs_readdir(&root_dir, &entry) == 0 && entry.name[0] != '\0') {
        if (entry.type != FS_DIR_ENTRY_DIR) {
            continue;
        }
        if (is_decimal_name(entry.name, 8)) {
            rc = scan_bucket_sessions(entry.name, ids, max_ids, &stored, &count);
            if (rc != 0) {
                fs_closedir(&root_dir);
                return rc;
            }
            if (max_ids > 0 && stored >= max_ids) {
                break;
            }
        }
    }
    fs_closedir(&root_dir);
    if (total) {
        *total = count;
    }
    return stored;
}

int storage_list_session_ids(char ids[][16], int max_ids)
{
    if (!sd_mounted || !ids || max_ids <= 0) {
        return -EINVAL;
    }
    return scan_session_ids(ids, max_ids, NULL);
}

int storage_list_sessions_paginated(struct storage_session_info *sessions,
                                    int offset, int limit)
{
    char ids[200][16];
    int wanted = MIN(offset + limit, (int)ARRAY_SIZE(ids));
    int id_count;
    int result = 0;

    if (!sd_mounted || !sessions || offset < 0 || limit <= 0) {
        return -EINVAL;
    }
    id_count = storage_list_session_ids(ids, wanted);
    if (id_count < 0) {
        return id_count;
    }
    for (int i = offset; i < id_count && result < limit; i++) {
        if (storage_get_session_info(ids[i], &sessions[result]) == 0) {
            result++;
        }
    }
    return result;

}

int storage_get_session_info(const char *session_id, struct storage_session_info *info)
{
    char filepath[STORAGE_PATH_MAX];
    struct fs_file_t file;
    char json_buf[512];
    int rc;
    ssize_t bytes_read;

    if (!info || validate_session_id(session_id) != 0) {
        return -EINVAL;
    }

    memset(info, 0, sizeof(*info));
    strncpy(info->session_id, session_id, sizeof(info->session_id) - 1);
    info->session_id[sizeof(info->session_id) - 1] = '\0';

    rc = build_session_metadata_path(session_id, filepath, sizeof(filepath));
    if (rc != 0) {
        return rc;
    }

    fs_file_t_init(&file);
    rc = fs_open(&file, filepath, FS_O_READ);
    if (rc == 0)
    {
        bytes_read = fs_read(&file, json_buf, sizeof(json_buf) - 1);
        fs_close(&file);

        if (bytes_read > 0)
        {
            json_buf[bytes_read] = '\0';

            /* Simple JSON parsing */
            char *p;

            /* Parse duration */
            p = strstr(json_buf, "\"duration\":");
            if (p)
            {
                info->duration_sec = atoi(p + 11);
            }

            /* Parse files (chunk_count) */
            p = strstr(json_buf, "\"files\":");
            if (p)
            {
                info->file_count = atoi(p + 8);
            }

            /* Parse synced files */
            p = strstr(json_buf, "\"synced\":");
            if (p)
            {
                info->synced_files = atoi(p + 9);
            }
            else
            {
                /* For backward compatibility, if no synced field, check recording flag */
                p = strstr(json_buf, "\"recording\":");
                if (p && strncmp(p + 12, "true", 4) == 0)
                {
                    info->synced_files = 0; /* Still recording, nothing synced yet */
                }
                else
                {
                    /* Recording completed, all files are synced */
                    info->synced_files = info->file_count;
                }
            }

            /* Parse size (total bytes) */
            p = strstr(json_buf, "\"size\":");
            if (p)
            {
                info->total_bytes = (uint64_t)strtoull(p + 7, NULL, 10);
            }

            /* Parse channels */
            p = strstr(json_buf, "\"channels\":");
            if (p)
            {
                info->channels = atoi(p + 11);
            }

            /* Parse sample_rate and convert to kHz */
            p = strstr(json_buf, "\"sample_rate\":");
            if (p)
            {
                uint32_t sample_rate_hz = atoi(p + 14);
                info->sample_rate_khz = (uint8_t)(sample_rate_hz / 1000);
            }

            /* Parse mode */
            p = strstr(json_buf, "\"mode\": \"");
            if (p)
            {
                char mode_start[16];
                strncpy(mode_start, p + 9, sizeof(mode_start) - 1);
                mode_start[sizeof(mode_start) - 1] = '\0';
                char *end = strchr(mode_start, '"');
                if (end)
                {
                    *end = '\0';
                    strncpy(info->mode, mode_start, sizeof(info->mode) - 1);
                }
            }

            /* Parse recording flag - if still recording, reset synced */
            p = strstr(json_buf, "\"recording\":");
            if (p && strncmp(p + 12, "true", 4) == 0)
            {
                info->synced_files = 0; /* Still recording, nothing synced yet */
            }
            /* Note: do NOT override synced_files when recording is done.
             * The synced field in session.json is the authoritative value. */
        }
    }

    /* If session.json had valid file data, trust it and skip the scan.
     * Directory scan is only needed when session.json is missing or stale
     * (e.g., power loss during recording).
     */
    if (info->file_count > 0) {
        return 0;
    }

    /* Fall back: scan directory for actual file count and total size. */
    {
        char dir_path[STORAGE_PATH_MAX];
        struct fs_dir_t dirp;
        struct fs_dirent entry;

        rc = build_bucket_session_dir(session_id, dir_path, sizeof(dir_path));
        if (rc != 0) {
            return rc;
        }
        fs_dir_t_init(&dirp);
        if (fs_opendir(&dirp, dir_path) != 0) {
            return -ENOENT;
        }

        uint32_t file_count = 0;
        uint64_t actual_bytes = 0;

        while (fs_readdir(&dirp, &entry) == 0 && entry.name[0] != '\0')
        {
            if (entry.type == FS_DIR_ENTRY_DIR && entry.name[0] != '.')
            {
                /* Group subdirectory — scan for .opus files */
                char subdir[STORAGE_PATH_MAX];
                struct fs_dir_t sub_dirp;
                struct fs_dirent sub_entry;

                if (storage_path_format(subdir, sizeof(subdir), "%s/%s",
                                        dir_path, entry.name) != 0) {
                    continue;
                }
                fs_dir_t_init(&sub_dirp);
                if (fs_opendir(&sub_dirp, subdir) == 0) {
                    while (fs_readdir(&sub_dirp, &sub_entry) == 0 &&
                           sub_entry.name[0] != '\0') {
                        size_t slen = strlen(sub_entry.name);
                        if (slen == 9 && strcmp(sub_entry.name + 4, ".opus") == 0) {
                            file_count++;
                            actual_bytes += (uint64_t)sub_entry.size;
                        }
                    }
                    fs_closedir(&sub_dirp);
                }
            }
        }
        fs_closedir(&dirp);

        if (file_count > 0) {
            info->file_count = file_count;
            info->total_bytes = actual_bytes;
        }
    }

    return 0;
}

bool storage_has_unsynced_sessions(void)
{
	char id[16];

	/* "Untransferred" indicator: any session present counts, instead of
	 * reading each session.json to compare synced_files vs file_count.
	 * scan_session_ids stops at the first session found (max_ids=1), so this
	 * is O(1) even with thousands of sessions — no per-session reads. */
	return storage_list_session_ids(&id, 1) > 0;
}

int storage_list_chunks(const char *session_id, uint32_t *chunks, int max_chunks, int skip)
{
    char dir_path[STORAGE_PATH_MAX];
    struct fs_dir_t dirp;
    struct fs_dirent entry;
    int count = 0;
    int rc;
    int skipped = 0;

    if (!sd_mounted || !chunks || max_chunks <= 0 || skip < 0 ||
        validate_session_id(session_id) != 0)
    {
        return -EINVAL;
    }

    /* Open session directory */
    rc = build_bucket_session_dir(session_id, dir_path, sizeof(dir_path));
    if (rc != 0) {
        return rc;
    }
    LOG_DBG("Listing chunks in: %s (max=%d, skip=%d)", dir_path, max_chunks,
            skip);

    fs_dir_t_init(&dirp);
    rc = fs_opendir(&dirp, dir_path);
    if (rc != 0)
    {
        LOG_ERR("session dir open %s: %d", dir_path, rc);
        return rc;
    }

    /* Read directory entries */
    while (count < max_chunks)
    {
        rc = fs_readdir(&dirp, &entry);
        if (rc != 0 || entry.name[0] == '\0')
        {
            break;
        }

        if (entry.type == FS_DIR_ENTRY_DIR &&
            entry.name[0] != '.')
        {
            /* Scan group subdirectory for .opus files */
            char subdir[STORAGE_PATH_MAX];
            struct fs_dir_t sub_dirp;
            struct fs_dirent sub_entry;

            if (storage_path_format(subdir, sizeof(subdir), "%s/%s", dir_path,
                                    entry.name) != 0) {
                continue;
            }
            fs_dir_t_init(&sub_dirp);
            if (fs_opendir(&sub_dirp, subdir) == 0) {
                while (count < max_chunks &&
                       fs_readdir(&sub_dirp, &sub_entry) == 0 &&
                       sub_entry.name[0] != '\0') {
                    size_t slen = strlen(sub_entry.name);
                    if (slen == 9 && strcmp(sub_entry.name + 4, ".opus") == 0) {
                        if (skipped < skip) {
                            skipped++;
                            continue;
                        }
                        chunks[count] = (uint32_t)atoi(sub_entry.name);
                        count++;
                    }
                }
                fs_closedir(&sub_dirp);
            }
            continue;
        }

    }

    fs_closedir(&dirp);

    LOG_DBG("Listed %d chunks for session %s", count, session_id);
    return count;
}

int storage_delete_session(const char *session_id)
{
    char dir_path[STORAGE_PATH_MAX];
    int rc;

    if (!sd_mounted || validate_session_id(session_id) != 0)
    {
        return -EINVAL;
    }

    /* Don't delete current recording session */
    if (strcmp(current_session_id, session_id) == 0)
    {
        return -EBUSY;
    }

    /* Open session directory */
    rc = build_bucket_session_dir(session_id, dir_path, sizeof(dir_path));
    if (rc != 0) {
        return rc;
    }

    /* Recursively delete all contents (files and group subdirectories) */
    delete_dir_contents(dir_path);

    /* Remove session directory */
    rc = fs_unlink(dir_path);
    if (rc != 0)
    {
        LOG_WRN("Failed to remove session directory: %d", rc);
    }

    return 0;
}

int storage_format_card(void)
{
    int rc;

    /* The idle power-gate unmounts the SD after 45 s of inactivity — a
     * format request arriving over BLE while idle must lazily remount
     * first, or it fails -ENODEV and (previously) the AT response still
     * claimed success while every recording survived the "factory reset". */
    rc = storage_ensure_mounted();
    if (rc != 0)
    {
        return rc;
    }

    /* 1. Unmount */
    fs_unmount(&mp);
    sd_mounted = false;

    /* 2. Format */
    static uint8_t workbuf[4096];

    MKFS_PARM opt = {
        .fmt = FM_FAT32,
        .n_fat = 1,
        .align = 0,
        .n_root = 0,
        .au_size = 0};

    rc = f_mkfs("SD:", &opt, workbuf, sizeof(workbuf));

    if (rc != FR_OK)
    {
        LOG_ERR("f_mkfs failed: %d", rc);
        return -EIO;
    }

    /* 3. Remount */
    rc = fs_mount(&mp);
    if (rc != 0)
    {
        LOG_ERR("Remount failed after format: %d", rc);
        return rc;
    }

    sd_mounted = true;

    /* 4. Recreate REC directory */
    fs_mkdir(STORAGE_BASE_PATH);

    return 0;
}

/* Internal functions */

static void delete_dir_contents(const char *dir_path)
{
    struct fs_dir_t dirp;
    struct fs_dirent entry;

    fs_dir_t_init(&dirp);
    if (fs_opendir(&dirp, dir_path) != 0) {
        return;
    }

    while (fs_readdir(&dirp, &entry) == 0 && entry.name[0] != '\0') {
        char filepath[STORAGE_PATH_MAX];

        if (storage_path_format(filepath, sizeof(filepath), "%s/%s", dir_path,
                                entry.name) != 0) {
            LOG_WRN("Skipping overlong path while deleting %s", entry.name);
            continue;
        }

        if (entry.type == FS_DIR_ENTRY_DIR && entry.name[0] != '.') {
            delete_dir_contents(filepath);
            fs_unlink(filepath);
        } else {
            fs_unlink(filepath);
        }
    }

    fs_closedir(&dirp);
}

static int update_free_space(void)
{
    struct fs_statvfs stat;

    if (!sd_mounted)
    {
        return -ENODEV;
    }

    /* Use the Zephyr FS API so we get both free and total capacity. */
    if (fs_statvfs("/SD:", &stat) != 0)
    {
        /* Keep the last known values rather than zeroing — a transient
         * statvfs failure (e.g. at idle-unmount) must not wipe the cached
         * capacity/free that status queries rely on while unmounted. */
        LOG_WRN("Failed to get free space");
        return -EIO;
    }

    /* f_bfree / f_blocks are in cluster (f_frsize) units, NOT sector (f_bsize)
     * units — the FATFS driver sets f_bfree = free clusters and f_frsize =
     * cluster size. Multiplying by f_bsize (sector) would under-report by the
     * cluster-size/sector-size factor (e.g. 64x too small for 32KB clusters). */
    free_space_mb = (uint32_t)((uint64_t)stat.f_bfree * stat.f_frsize / (1024 * 1024));
    sd_total_mb = (uint32_t)((uint64_t)stat.f_blocks * stat.f_frsize / (1024 * 1024));

    return 0;
}

static int create_marks_file(const char *marks_path)
{
    struct fs_file_t file;
    int rc;
    ssize_t written;

    fs_file_t_init(&file);
    rc = fs_open(&file, marks_path, FS_O_CREATE | FS_O_WRITE);
    if (rc != 0)
    {
        LOG_ERR("Failed to create marks.bin: %d", rc);
        return rc;
    }

    /* Write empty bookmark header */
    uint8_t header[6] = {'B', 'M', 'R', 'K', 0, 0};
    written = fs_write(&file, header, 6);
    if (written != 6)
    {
        LOG_ERR("Failed to write marks.bin header: %zd", written);
        fs_close(&file);
        return -EIO;
    }

    fs_close(&file);
    LOG_DBG("Created marks.bin");

    return 0;
}

static int create_session_json(const char *json_path, const char *session_id,
                               uint8_t channels, uint32_t sample_rate,
                               const char *mode)
{
    struct fs_file_t file;
    char json_buf[512];
    int len;
    int rc;
    ssize_t written;

    fs_file_t_init(&file);
    rc = fs_open(&file, json_path, FS_O_CREATE | FS_O_WRITE);
    if (rc != 0)
    {
        LOG_ERR("Failed to create session.json: %d", rc);
        return rc;
    }

    len = snprintf(json_buf, sizeof(json_buf),
                   "{\n"
                   "  \"id\": \"%s\",\n"
                   "  \"duration\": 0,\n"
                   "  \"files\": 0,\n"
                   "  \"synced\": 0,\n"
                   "  \"channels\": %u,\n"
                   "  \"sample_rate\": %u,\n"
                   "  \"mode\": \"%s\",\n"
                   "  \"recording\": true\n"
                   "}\n",
                   session_id, channels, sample_rate, mode ? mode : "normal");

    if (len < 0 || len >= (int)sizeof(json_buf))
    {
        LOG_ERR("Failed to format session.json");
        fs_close(&file);
        return -ENOMEM;
    }

    written = fs_write(&file, json_buf, len);
    if (written != len)
    {
        LOG_ERR("session.json write %zd!=%d", written, len);
        fs_close(&file);
        return -EIO;
    }

    fs_close(&file);
    LOG_DBG("Created session.json");

    return 0;
}

static int update_session_json(const char *session_id, uint32_t duration_sec,
                               uint32_t chunk_count, uint64_t session_bytes)
{
    char json_path[STORAGE_PATH_MAX];
    struct fs_file_t file;
    char json_buf[512];
    char channels_str[16] = "2";
    char sample_rate_str[16] = "16000";
    char mode_str[16] = "normal";
    int len;
    int rc;
    ssize_t bytes_read, written;

    rc = build_session_metadata_path(session_id, json_path, sizeof(json_path));
    if (rc != 0) {
        return rc;
    }

    k_mutex_lock(&session_json_mutex, K_FOREVER);

    /* Read existing JSON to preserve other fields including synced */
    fs_file_t_init(&file);
    char synced_str[16] = "0"; /* Default: no files synced */
    rc = fs_open(&file, json_path, FS_O_READ);
    if (rc == 0)
    {
        bytes_read = fs_read(&file, json_buf, sizeof(json_buf) - 1);
        fs_close(&file);

        if (bytes_read > 0)
        {
            json_buf[bytes_read] = '\0';

            /* Parse and preserve channels, sample_rate, mode, synced */
            char *p;
            p = strstr(json_buf, "\"channels\":");
            if (p)
            {
                unsigned int val = atoi(p + 11);
                snprintf(channels_str, sizeof(channels_str), "%u", val);
            }
            p = strstr(json_buf, "\"sample_rate\":");
            if (p)
            {
                unsigned int val = atoi(p + 14);
                snprintf(sample_rate_str, sizeof(sample_rate_str), "%u", val);
            }
            p = strstr(json_buf, "\"mode\": \"");
            if (p)
            {
                char temp[16];
                strncpy(temp, p + 9, sizeof(temp) - 1);
                temp[sizeof(temp) - 1] = '\0';
                char *end = strchr(temp, '"');
                if (end)
                {
                    *end = '\0';
                    strncpy(mode_str, temp, sizeof(mode_str) - 1);
                }
            }
            /* Preserve synced count - don't assume all files are synced */
            p = strstr(json_buf, "\"synced\":");
            if (p)
            {
                unsigned int val = atoi(p + 9);
                snprintf(synced_str, sizeof(synced_str), "%u", val);
            }
        }
    }

    /* Write updated JSON with all fields, set recording to false */
    fs_file_t_init(&file);
    rc = fs_open(&file, json_path, FS_O_CREATE | FS_O_WRITE);
    if (rc != 0)
    {
        LOG_ERR("session.json open(update) %d", rc);
        k_mutex_unlock(&session_json_mutex);
        return rc;
    }

    len = snprintf(json_buf, sizeof(json_buf),
                   "{\n"
                   "  \"id\": \"%s\",\n"
                   "  \"duration\": %u,\n"
                   "  \"files\": %u,\n"
                   "  \"size\": %u,\n"
                   "  \"synced\": %s,\n"
                   "  \"channels\": %s,\n"
                   "  \"sample_rate\": %s,\n"
                   "  \"mode\": \"%s\",\n"
                   "  \"recording\": false\n"
                   "}\n",
                   session_id, duration_sec, chunk_count,
                   (unsigned int)session_bytes,
                   synced_str, channels_str, sample_rate_str, mode_str);

    if (len < 0 || len >= (int)sizeof(json_buf))
    {
        LOG_ERR("Failed to format session.json");
        fs_close(&file);
        k_mutex_unlock(&session_json_mutex);
        return -ENOMEM;
    }

    written = fs_write(&file, json_buf, len);
    if (written != len)
    {
        LOG_ERR("session.json write %zd!=%d", written, len);
        fs_close(&file);
        k_mutex_unlock(&session_json_mutex);
        return -EIO;
    }

    fs_close(&file);
    k_mutex_unlock(&session_json_mutex);
    LOG_DBG("Updated session.json");

    return 0;
}

/* Bookmark support */

#define BOOKMARK_MAGIC "BMRK"
#define BOOKMARK_FILE_NAME "marks.bin"

static int get_bookmark_filepath(const char *session_id, char *filepath, size_t size)
{
    if (!filepath)
    {
        return -EINVAL;
    }

    return build_marks_path(session_id, filepath, size);
}

int storage_add_bookmark(const char *session_id, uint32_t offset_sec)
{
    char filepath[128];
    struct fs_file_t file;
    int rc;
    ssize_t ret;

    if (!sd_mounted || !session_id)
    {
        return -EINVAL;
    }

    /* Get file path */
    rc = get_bookmark_filepath(session_id, filepath, sizeof(filepath));
    if (rc != 0)
    {
        return rc;
    }

    /* Check if file exists */
    struct fs_dirent entry;
    bool file_exists = (fs_stat(filepath, &entry) == 0);

    if (file_exists)
    {
        /* Read current header and count */
        fs_file_t_init(&file);
        rc = fs_open(&file, filepath, FS_O_READ | FS_O_WRITE);
        if (rc != 0)
        {
            LOG_ERR("Failed to open bookmarks file: %d", rc);
            return rc;
        }

        /* Read header */
        uint8_t header[6];
        ret = fs_read(&file, header, sizeof(header));
        if (ret != sizeof(header))
        {
            LOG_ERR("Failed to read bookmark header: %zd", ret);
            fs_close(&file);
            return -EIO;
        }

        /* Verify magic */
        if (memcmp(header, BOOKMARK_MAGIC, 4) != 0)
        {
            LOG_ERR("Invalid bookmark magic");
            fs_close(&file);
            return -EIO;
        }

        /* Get and increment count */
        uint16_t count;
        memcpy(&count, &header[4], 2);
        count++;

        /* Seek back to count position */
        rc = fs_seek(&file, 4, FS_SEEK_SET);
        if (rc != 0)
        {
            LOG_ERR("Failed to seek to count position: %d", rc);
            fs_close(&file);
            return rc;
        }

        /* Write updated count */
        ret = fs_write(&file, &count, 2);
        if (ret != 2)
        {
            LOG_ERR("Failed to write bookmark count: %zd", ret);
            fs_close(&file);
            return -EIO;
        }

        /* Seek to end to append bookmark */
        rc = fs_seek(&file, 0, FS_SEEK_END);
        if (rc != 0)
        {
            LOG_ERR("Failed to seek to end: %d", rc);
            fs_close(&file);
            return rc;
        }

        /* Write bookmark */
        ret = fs_write(&file, &offset_sec, sizeof(uint32_t));
        if (ret != sizeof(uint32_t))
        {
            LOG_ERR("Failed to write bookmark: %zd", ret);
            fs_close(&file);
            return -EIO;
        }

        fs_close(&file);

        LOG_DBG("Added bookmark %u at %u seconds", count, offset_sec);
    }
    else
    {
        /* Create new file with header */
        fs_file_t_init(&file);
        rc = fs_open(&file, filepath, FS_O_CREATE | FS_O_WRITE);
        if (rc != 0)
        {
            LOG_ERR("Failed to create bookmarks file: %d", rc);
            return rc;
        }

        /* Write header */
        uint8_t header[6];
        memcpy(header, BOOKMARK_MAGIC, 4);
        uint16_t count = 1;
        memcpy(&header[4], &count, 2);
        ret = fs_write(&file, header, sizeof(header));
        if (ret != sizeof(header))
        {
            LOG_ERR("Failed to write bookmark header: %zd", ret);
            fs_close(&file);
            return -EIO;
        }

        /* Write first bookmark */
        ret = fs_write(&file, &offset_sec, sizeof(uint32_t));
        if (ret != sizeof(uint32_t))
        {
            LOG_ERR("Failed to write first bookmark: %zd", ret);
            fs_close(&file);
            return -EIO;
        }

        fs_close(&file);

        LOG_DBG("bookmarks: first mark at %us", offset_sec);
    }

    return 0;
}

int storage_get_bookmarks(const char *session_id, int page, int per_page,
                          struct storage_bookmark *bookmarks, int max_count)
{
    char filepath[128];
    struct fs_file_t file;
    uint8_t header[6];
    ssize_t ret;
    uint16_t count;
    int start_index, end_index;
    int rc;

    if (!sd_mounted || !session_id || !bookmarks || max_count <= 0)
    {
        return -EINVAL;
    }

    if (page < 1 || per_page < 1)
    {
        return -EINVAL;
    }

    /* Get file path */
    rc = get_bookmark_filepath(session_id, filepath, sizeof(filepath));
    if (rc != 0)
    {
        return rc;
    }

    /* Open file */
    fs_file_t_init(&file);
    rc = fs_open(&file, filepath, FS_O_READ);
    if (rc != 0)
    {
        /* File doesn't exist yet - no bookmarks */
        return 0;
    }

    /* Read header */
    ret = fs_read(&file, header, sizeof(header));
    if (ret != sizeof(header))
    {
        LOG_ERR("Invalid bookmark file");
        fs_close(&file);
        return -EIO;
    }

    /* Verify magic */
    if (memcmp(header, BOOKMARK_MAGIC, 4) != 0)
    {
        LOG_ERR("Invalid bookmark magic");
        fs_close(&file);
        return -EIO;
    }

    /* Get count */
    memcpy(&count, &header[4], 2);
    if (count > 10000)
    { /* Sanity check */
        LOG_WRN("Bookmark count too large: %u", count);
        count = 0;
    }

    /* Calculate pagination bounds */
    start_index = (page - 1) * per_page;
    if (start_index >= count)
    {
        /* Page beyond available data */
        fs_close(&file);
        return 0;
    }

    end_index = start_index + per_page;
    if (end_index > (int)count)
    {
        end_index = count;
    }

    /* Adjust max_count */
    if (max_count < (end_index - start_index))
    {
        end_index = start_index + max_count;
    }

    /* Seek to first bookmark in page */
    off_t seek_pos = sizeof(header) + (start_index * sizeof(uint32_t));
    ret = fs_seek(&file, seek_pos, FS_SEEK_SET);
    if (ret < 0)
    {
        LOG_ERR("Failed to seek to bookmark position");
        fs_close(&file);
        return ret;
    }

    /* Read bookmarks */
    int read_count = 0;
    for (int i = start_index; i < end_index; i++)
    {
        uint32_t offset_sec;
        ret = fs_read(&file, (uint8_t *)&offset_sec, sizeof(uint32_t));
        if (ret != sizeof(uint32_t))
        {
            break;
        }
        bookmarks[read_count].offset_sec = offset_sec;
        read_count++;
    }

    fs_close(&file);

    return read_count;
}

int storage_count_bookmarks(const char *session_id)
{
    char filepath[128];
    struct fs_file_t file;
    uint8_t header[6];
    ssize_t ret;
    uint16_t count = 0;
    int rc;

    if (!sd_mounted || !session_id)
    {
        return -EINVAL;
    }

    /* Get file path */
    rc = get_bookmark_filepath(session_id, filepath, sizeof(filepath));
    if (rc != 0)
    {
        return rc;
    }

    /* Open file */
    fs_file_t_init(&file);
    rc = fs_open(&file, filepath, FS_O_READ);
    if (rc != 0)
    {
        /* File doesn't exist yet - no bookmarks */
        return 0;
    }

    /* Read header */
    ret = fs_read(&file, header, sizeof(header));
    if (ret == sizeof(header))
    {
        /* Verify magic */
        if (memcmp(header, BOOKMARK_MAGIC, 4) == 0)
        {
            /* Get count */
            memcpy(&count, &header[4], 2);
        }
    }

    fs_close(&file);

    return count;
}

/* File writing state tracking for transfer coordination */

/**
 * @brief Set the current writing file
 *
 * Called by storage_create_file() to mark a file as being written.
 * Transfer thread waits for files to finish writing before transferring.
 *
 * @param session_id Session ID (NULL to clear)
 * @param filename Filename (NULL to clear)
 */
void storage_set_writing_file(const char *session_id, const char *filename)
{
    if (session_id && filename)
    {
        strncpy(writing_session, session_id, sizeof(writing_session) - 1);
        writing_session[sizeof(writing_session) - 1] = '\0';
        strncpy(writing_filename, filename, sizeof(writing_filename) - 1);
        writing_filename[sizeof(writing_filename) - 1] = '\0';
        LOG_DBG("Writing: %s/%s", writing_session, writing_filename);
    }
    else
    {
        /* Clear writing file info */
        writing_session[0] = '\0';
        writing_filename[0] = '\0';
        LOG_DBG("Writing cleared");
    }
}

/**
 * @brief Check if a file is currently being written
 *
 * @param session_id Session ID
 * @param filename Filename
 * @return true if file is being written, false otherwise
 */
bool storage_file_is_writing(const char *session_id, const char *filename)
{
    if (!session_id || !filename)
    {
        return false;
    }

    /* Check if session and filename match current writing file */
    return (strcmp(writing_session, session_id) == 0 &&
            strcmp(writing_filename, filename) == 0);
}

struct k_sem *storage_get_file_closed_sem(void)
{
    return &file_closed_sem;
}

/**
 * @brief Get the current writing file info
 *
 * @param out_session Output buffer for session ID (can be NULL)
 * @param out_filename Output buffer for filename (can be NULL)
 * @param session_size Size of session buffer
 * @param filename_size Size of filename buffer
 * @return true if a file is being written, false otherwise
 */
bool storage_get_writing_file(char *out_session, char *out_filename,
                              size_t session_size, size_t filename_size)
{
    bool is_writing = (writing_session[0] != '\0');

    if (is_writing)
    {
        if (out_session && session_size > 0)
        {
            strncpy(out_session, writing_session, session_size - 1);
            out_session[session_size - 1] = '\0';
        }
        if (out_filename && filename_size > 0)
        {
            strncpy(out_filename, writing_filename, filename_size - 1);
            out_filename[filename_size - 1] = '\0';
        }
    }

    return is_writing;
}

void storage_session_json_lock(void)
{
    k_mutex_lock(&session_json_mutex, K_FOREVER);
}

void storage_session_json_unlock(void)
{
    k_mutex_unlock(&session_json_mutex);
}
