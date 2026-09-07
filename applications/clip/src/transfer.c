/*
 * Copyright (c) 2025 Seeed Technology Co., Ltd.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/fs/fs.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

#include "transfer.h"
#include "storage.h"
#include "transport.h"
#include "clip.h"
#include "ble.h"
#include "audio.h"
#include "display.h"

LOG_MODULE_REGISTER(transfer, LOG_LEVEL_WRN); /* chatty transfer-progress logs */

/* Transfer thread stack - uses Kconfig value */
K_THREAD_STACK_DEFINE(transfer_thread_stack, CONFIG_CLIP_TRANSFER_STACK_SIZE);

/* Static chunk buffer - avoids stack allocation for large buffer */
static uint8_t chunk_buffer[CONFIG_CLIP_TRANSFER_CHUNK_SIZE];

/* Transfer thread state */
static struct k_thread transfer_thread_data;
static k_tid_t transfer_thread_id;
static K_SEM_DEFINE(transfer_trigger_sem, 0, 1);
static K_SEM_DEFINE(transfer_idle_sem, 0, 1);
static K_MUTEX_DEFINE(transfer_cleanup_mutex);
static volatile bool transfer_thread_running = false;
static volatile bool transfer_thread_waiting = false;
static volatile bool transfer_thread_ready = false;

/* Helper: transfer thread signals idle then waits for trigger */
static void transfer_thread_wait_idle(void)
{
	transfer_thread_waiting = true;
	k_sem_give(&transfer_idle_sem);
	k_sem_take(&transfer_trigger_sem, K_FOREVER);
	transfer_thread_waiting = false;
}

/* Transfer state */
static struct transfer_info current_transfer = {0};
static struct fs_file_t transfer_file;
static bool transfer_file_open = false;
static struct transport *current_transport = NULL;  /* Transport for current transfer */

/* Track last successfully transferred file */
static char last_transferred_file[32] = {0};

/* Transfer rate tracking */
static int64_t file_transfer_start_ms = 0;

/* Static counters reset at start of each transfer */
static int consecutive_file_errors = 0;
static int chunk_count = 0;

/* Transfer control flags (atomic for thread safety) */
static atomic_t transfer_pause_requested = ATOMIC_INIT(0);
static atomic_t transfer_cancel_requested = ATOMIC_INIT(0);
static atomic_t transfer_complete_sent = ATOMIC_INIT(0);

/* Forward declarations */
static void transfer_thread_main(void *, void *, void *);
static int transfer_next_file(void);
static int transfer_send_chunk(void);
static void transfer_cleanup(void);
static void send_file_ready_event(const char *session_id, const char *filename, uint64_t size);
static int send_file_complete_event(const char *filename);
static void send_transfer_complete_once(const char *session_id, int file_count);
static void generate_filename(uint32_t file_num, char *filename);
static int build_transfer_path(char *buf, size_t size, const char *session_id,
                               uint32_t file_num);

static bool is_valid_session_id(const char *session_id)
{
    if (!session_id || strlen(session_id) != 14) {
        return false;
    }
    for (const char *p = session_id; *p; p++) {
        if (*p < '0' || *p > '9') {
            return false;
        }
    }
    return true;
}

static bool is_valid_chunk_filename(const char *filename)
{
    uint32_t index = 0;

    if (!filename || strlen(filename) != 9 ||
        strcmp(filename + 4, ".opus") != 0) {
        return false;
    }
    for (size_t i = 0; i < 4; i++) {
        if (filename[i] < '0' || filename[i] > '9') {
            return false;
        }
        index = index * 10U + (uint32_t)(filename[i] - '0');
    }
    return index > 0 && index <= CONFIG_CLIP_STORAGE_MAX_CHUNKS;
}

/**
 * @brief Build the physical file path while preserving logical 0001.opus names
 *        on the transfer protocol.
 */
static int build_transfer_path(char *buf, size_t size, const char *session_id,
                               uint32_t file_num)
{
	return storage_build_chunk_path(session_id, file_num, buf, size);
}

/**
 * @brief Generate filename from file number
 *
 * Files are numbered sequentially: 0001.opus, 0002.opus, etc.
 */
static void generate_filename(uint32_t file_num, char *filename)
{
    snprintf(filename, 16, "%04u.opus", file_num);
}

int transfer_init(void)
{
    memset(&current_transfer, 0, sizeof(current_transfer));
    memset(last_transferred_file, 0, sizeof(last_transferred_file));

    /* Set thread running flag BEFORE creating thread */
    transfer_thread_running = true;

    /* Create transfer thread */
    transfer_thread_id = k_thread_create(&transfer_thread_data,
                                         transfer_thread_stack,
                                         K_KERNEL_STACK_SIZEOF(transfer_thread_stack),
                                         transfer_thread_main,
                                         NULL, NULL, NULL,
                                         CONFIG_CLIP_TRANSFER_THREAD_PRIORITY,
                                         0, K_NO_WAIT);
    if (transfer_thread_id == NULL) {
        LOG_ERR("Failed to create transfer thread");
        transfer_thread_running = false;
        return -ENOMEM;
    }
    k_thread_name_set(&transfer_thread_data, "transfer");
    LOG_INF("xfer thread created");

    /* Wait for thread to reach idle state */
    if (k_sem_take(&transfer_idle_sem, K_SECONDS(1)) != 0) {
        LOG_ERR("Transfer thread not ready after 1s");
        return -ETIMEDOUT;
    }
    /* Give back so transfer_start() can take it — thread is idle on trigger_sem */
    k_sem_give(&transfer_idle_sem);

    return 0;
}

int transfer_start(const char *session_id, const char *filename, struct transport *tp)
{
    int err;

    if (!is_valid_session_id(session_id) ||
        (filename && !is_valid_chunk_filename(filename))) {
        return -EINVAL;
    }

    /* Use active transport if none specified */
    if (!tp) {
        tp = transport_get_active();
        if (!tp) {
            LOG_ERR("No transport available for transfer");
            return -ENOTCONN;
        }
    }

    /* Save the transport for this transfer session */
    current_transport = tp;
    LOG_INF("xfer tp=%d", tp->type);

    clip_cpu_boost_acquire();

    /* Check if transfer is already active with file open */
    if (transfer_is_active() && transfer_file_open) {
        clip_cpu_boost_release();
        LOG_WRN("Transfer already active");
        return -EBUSY;
    }

    /* Wait for transfer thread to be idle (replaces 3 polling loops) */
    if (k_sem_take(&transfer_idle_sem, K_SECONDS(3)) != 0) {
        clip_cpu_boost_release();
        LOG_ERR("Transfer thread not idle after 3s");
        return -ETIMEDOUT;
    }

    if (storage_ensure_mounted() != 0) {
        LOG_ERR("SD card not mounted");
        err = -ENODEV;
        goto fail;
    }

    /* Check if session exists */
    struct storage_session_info session_info;
    if (storage_get_session_info(session_id, &session_info) != 0) {
        LOG_ERR("Session not found: %s", session_id);
        err = -ENOENT;
        goto fail;
    }

    /* Skip empty sessions (0 files) */
    if (session_info.file_count == 0) {
        LOG_INF("Empty session, skipping: %s", session_id);
        err = -ENOENT;
        goto fail;
    }

    atomic_set(&transfer_complete_sent, 0);
    atomic_set(&transfer_pause_requested, 0);
    atomic_set(&transfer_cancel_requested, 0);

    /* Close any leaked file handle from interrupted transfer */
    if (transfer_file_open) {
        LOG_WRN("Closing leaked file handle");
        fs_close(&transfer_file);
        transfer_file_open = false;
    }

    /* Initialize transfer state */
    memset(&current_transfer, 0, sizeof(current_transfer));
    memset(last_transferred_file, 0, sizeof(last_transferred_file));
    consecutive_file_errors = 0;
    chunk_count = 0;
    current_transfer.state = TRANSFER_STATE_TRANSMITTING;

    /* Show transfer icon on display immediately */
    display_set_transferring(true);
    current_transfer.direction = TRANSFER_DIR_UPLOAD;

    strncpy(current_transfer.session_id, session_id, sizeof(current_transfer.session_id) - 1);

    if (filename) {
        /* Transfer single file */
        char filepath[128];
        struct fs_dirent entry;
        uint32_t file_num = (uint32_t)atoi(filename);

        err = build_transfer_path(filepath, sizeof(filepath), session_id,
                                  file_num > 0 ? file_num : 1);
        if (err != 0) {
            goto fail;
        }
        if (fs_stat(filepath, &entry) != 0) {
            LOG_ERR("File not found: %s", filepath);
            err = -ENOENT;
            goto fail;
        }

        strncpy(current_transfer.current_file, filename, sizeof(current_transfer.current_file) - 1);
        current_transfer.total_files = 1;
        current_transfer.total_bytes = entry.size;
        current_transfer.continuous = false;  /* Single file - not continuous */
        LOG_INF("xfer: %s (%u KB)", filename, (uint32_t)entry.size/1024);
    } else {
        /* Transfer entire session */
        struct storage_session_info session_info;
        err = storage_get_session_info(session_id, &session_info);
        if (err < 0) {
            LOG_ERR("Failed to get session info: %d", err);
            goto fail;
        }
        current_transfer.total_files = session_info.file_count;
        current_transfer.total_bytes = session_info.total_bytes;
        current_transfer.file_index = 0;
        current_transfer.first_file_num = 1;
        current_transfer.last_file_num = session_info.file_count;

        /* Check if this session is currently being recorded (continuous mode) */
        const char *recording_session = audio_get_session_id();
        current_transfer.continuous = (recording_session != NULL &&
                                       strcmp(recording_session, session_id) == 0);

        /* For continuous mode, total files unknown until recording stops */
        if (current_transfer.continuous) {
            current_transfer.total_files = 0;
        }

        LOG_INF("xfer: %s (%u files, %s)",
                session_id, current_transfer.total_files,
                current_transfer.continuous ? "continuous" : "normal");
    }

    /* Start transfer thread */
    transfer_thread_running = true;
    k_sem_give(&transfer_trigger_sem);

    return 0;

fail:
    clip_cpu_boost_release();
    k_sem_give(&transfer_trigger_sem);  /* Release thread from idle */
    return err;
}

int transfer_resume_from(const char *session_id, const char *start_file, struct transport *tp)
{
    int err;

    if (!is_valid_session_id(session_id) ||
        !is_valid_chunk_filename(start_file)) {
        return -EINVAL;
    }

    /* Use active transport if none specified */
    if (!tp) {
        tp = transport_get_active();
        if (!tp) {
            LOG_ERR("No transport available for transfer");
            return -ENOTCONN;
        }
    }

    /* Save the transport for this transfer session */
    current_transport = tp;
    LOG_INF("xfer tp=%d", tp->type);

    clip_cpu_boost_acquire();

    /* Check if transfer is already active with file open */
    if (transfer_is_active() && transfer_file_open) {
        clip_cpu_boost_release();
        LOG_WRN("Transfer already active");
        return -EBUSY;
    }

    /* Wait for transfer thread to be idle */
    if (k_sem_take(&transfer_idle_sem, K_SECONDS(3)) != 0) {
        clip_cpu_boost_release();
        LOG_ERR("Transfer thread not idle after 3s");
        return -ETIMEDOUT;
    }

    if (transfer_is_active()) {
        err = -EBUSY;
        goto fail;
    }

    if (storage_ensure_mounted() != 0) {
        LOG_ERR("SD card not mounted");
        err = -ENODEV;
        goto fail;
    }

    struct storage_session_info tmp_info;
    if (storage_get_session_info(session_id, &tmp_info) != 0) {
        LOG_ERR("Session not found: %s", session_id);
        err = -ENOENT;
        goto fail;
    }

    if (tmp_info.file_count == 0) {
        LOG_INF("Empty session, skipping: %s", session_id);
        err = -ENOENT;
        goto fail;
    }

    atomic_set(&transfer_complete_sent, 0);
    atomic_set(&transfer_pause_requested, 0);
    atomic_set(&transfer_cancel_requested, 0);

    /* Close any leaked file handle from interrupted transfer */
    if (transfer_file_open) {
        LOG_WRN("Closing leaked file handle");
        fs_close(&transfer_file);
        transfer_file_open = false;
    }

    /* Initialize transfer state */
    memset(&current_transfer, 0, sizeof(current_transfer));
    consecutive_file_errors = 0;
    chunk_count = 0;
    current_transfer.state = TRANSFER_STATE_TRANSMITTING;
    current_transfer.direction = TRANSFER_DIR_UPLOAD;
    strncpy(current_transfer.session_id, session_id, sizeof(current_transfer.session_id) - 1);

    /* Get total file count */
    struct storage_session_info session_info;
    err = storage_get_session_info(session_id, &session_info);
    if (err < 0) {
        LOG_ERR("Failed to get session info: %d", err);
        goto fail;
    }

    current_transfer.total_files = session_info.file_count;
    current_transfer.total_bytes = session_info.total_bytes;
    current_transfer.first_file_num = 1;
    current_transfer.last_file_num = session_info.file_count;

    /* Check if this session is currently being recorded (continuous mode) */
    const char *recording_session = audio_get_session_id();
    current_transfer.continuous = (recording_session != NULL &&
                                   strcmp(recording_session, session_id) == 0);

    /* Extract number from filename (e.g., "0023.opus" -> 23) */
    int start_num = atoi(start_file);
    if (start_num > 0 && start_num <= (int)current_transfer.total_files) {
        current_transfer.file_index = start_num - 1;
        LOG_DBG("Starting from file %s (index=%u)", start_file, current_transfer.file_index);
    } else if (start_num > (int)current_transfer.total_files) {
        current_transfer.file_index = current_transfer.total_files - 1;
        LOG_DBG("start file %s absent, waiting", start_file);
        if (current_transfer.total_files > 0) {
            generate_filename(current_transfer.total_files, last_transferred_file);
        }
    } else {
        LOG_WRN("bad start file %s, from begin", start_file);
        current_transfer.file_index = 0;
    }

    /* Start transfer thread */
    transfer_thread_running = true;
    k_sem_give(&transfer_trigger_sem);

    return 0;

fail:
    clip_cpu_boost_release();
    k_sem_give(&transfer_trigger_sem);  /* Release thread from idle */
    return err;
}

int transfer_cancel(void)
{
    if (!transfer_is_active()) {
        return -EINVAL;
    }

    LOG_INF("xfer canceled");
    atomic_set(&transfer_cancel_requested, 1);
    atomic_set(&transfer_pause_requested, 0);
    /* Mark inactive immediately so a subsequent AT+DOWNLOAD right after a BLE
     * drop isn't rejected as "already in progress" while the thread winds down. */
    current_transfer.state = TRANSFER_STATE_ERROR;

    return 0;
}

int transfer_get_progress(struct transfer_info *info)
{
    if (!info) {
        return -EINVAL;
    }

    memcpy(info, &current_transfer, sizeof(*info));

    return 0;
}

bool transfer_is_active(void)
{
    return (current_transfer.state == TRANSFER_STATE_TRANSMITTING ||
            current_transfer.state == TRANSFER_STATE_PAUSED);
}

enum transfer_state transfer_get_state(void)
{
    return current_transfer.state;
}

int transfer_get_current_session(char *session_id, size_t len, char *filename, size_t filename_len)
{
    if (!transfer_is_active()) {
        return -EINVAL;
    }

    if (session_id && len > 0) {
        strncpy(session_id, current_transfer.session_id, len - 1);
        session_id[len - 1] = '\0';
    }

    if (filename && filename_len > 0) {
        if (current_transfer.current_file[0] != '\0') {
            strncpy(filename, current_transfer.current_file, filename_len - 1);
            filename[filename_len - 1] = '\0';
        } else {
            filename[0] = '\0';
        }
    }

    return 0;
}

uint32_t transfer_get_total_files(void)
{
    if (!transfer_is_active()) {
        return 0;
    }

    return current_transfer.total_files;
}

int transfer_set_synced_files(const char *session_id, uint32_t count)
{
    /* This updates the synced field in session.json */
    char filepath[STORAGE_PATH_MAX];
    struct fs_file_t file;
    char json_buf[512];
    int ret;

    if (!session_id) {
        return -EINVAL;
    }

    ret = storage_build_session_metadata_path(session_id, filepath,
                                              sizeof(filepath));
    if (ret != 0) {
        return ret;
    }

    storage_session_json_lock();

    /* Read existing session.json */
    fs_file_t_init(&file);
    ret = fs_open(&file, filepath, FS_O_READ);
    if (ret != 0) {
        if (ret == -ENOENT) {
            /* Session was deleted (e.g. host deleted right after download) —
             * nothing to persist. */
            storage_session_json_unlock();
            return 0;
        }
        LOG_ERR("Failed to open session.json: %d", ret);
        storage_session_json_unlock();
        return ret;
    }

    ssize_t bytes_read = fs_read(&file, json_buf, sizeof(json_buf) - 1);
    fs_close(&file);

    if (bytes_read < 0) {
        LOG_ERR("Failed to read session.json: %zd", bytes_read);
        storage_session_json_unlock();
        return bytes_read;
    }
    if (bytes_read >= (ssize_t)(sizeof(json_buf) - 64)) {
        LOG_ERR("session.json too large (%zd bytes)", bytes_read);
        storage_session_json_unlock();
        return -ENOMEM;
    }
    json_buf[bytes_read] = '\0';

    /* Update synced field */
    char *p = strstr(json_buf, "\"synced\"");
    if (!p) {
        /* Add synced field after "files" field */
        p = strstr(json_buf, "\"files\"");
        if (p) {
            p = strstr(p, ",");
            if (p) {
                char new_synced[32];
                snprintf(new_synced, sizeof(new_synced), ",\n  \"synced\": %u", count);
                size_t insert_len = strlen(new_synced);
                /* Check if there's room for the insertion */
                size_t tail_len = strlen(p + 1);
                if ((size_t)(p - json_buf) + 1 + insert_len + tail_len + 1 > sizeof(json_buf)) {
                    LOG_ERR("session.json: no room for synced field");
                    storage_session_json_unlock();
                    return -ENOMEM;
                }
                /* Insert after comma */
                memmove(p + insert_len + 1, p + 1, tail_len + 1);
                memcpy(p + 1, new_synced, insert_len);
            }
        }
    } else {
        /* Update existing synced field */
        p = strstr(p, ":");
        if (p) {
            p++; /* Skip ':' */
            while (*p == ' ') p++; /* Skip whitespace */
            char new_count[16];
            snprintf(new_count, sizeof(new_count), "%u", count);
            /* Find end of number */
            char *end = p;
            while (*end >= '0' && *end <= '9') end++;
            /* Replace number */
            size_t old_len = end - p;
            size_t new_len = strlen(new_count);
            if (new_len <= old_len) {
                memcpy(p, new_count, new_len);
                /* Pad with spaces if needed */
                for (size_t i = new_len; i < old_len; i++) {
                    p[i] = ' ';
                }
            } else {
                /* New value is longer — shift remaining content */
                size_t tail_len = strlen(end);
                memmove(p + new_len, end, tail_len + 1);
                memcpy(p, new_count, new_len);
            }
        }
    }

    /* Write back to file */
    fs_file_t_init(&file);
    ret = fs_open(&file, filepath, FS_O_WRITE);
    if (ret != 0) {
        if (ret == -ENOENT) {
            /* Session deleted between our read and write — it's gone. */
            storage_session_json_unlock();
            return 0;
        }
        LOG_ERR("session.json open(write) %d", ret);
        storage_session_json_unlock();
        return ret;
    }

    ssize_t bytes_written = fs_write(&file, json_buf, strlen(json_buf));
    fs_close(&file);

    if (bytes_written < 0) {
        LOG_ERR("Failed to write session.json: %zd", bytes_written);
        storage_session_json_unlock();
        return bytes_written;
    }

    LOG_DBG("synced=%u (%s)", count, session_id);
    storage_session_json_unlock();
    return 0;
}

/* Internal functions */
static void transfer_thread_main(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1);
    ARG_UNUSED(p2);
    ARG_UNUSED(p3);

    /* Wait for initial transfer start signal */
    transfer_thread_ready = true;
    transfer_thread_wait_idle();

    LOG_INF("xfer: initial wake, state=%d", current_transfer.state);

    while (transfer_thread_running) {
        /* Check if paused */
        if (current_transfer.state == TRANSFER_STATE_PAUSED) {
            transfer_thread_wait_idle();
            continue;
        }

        /* Process transfer */
        int ret;

process_next_file:
        /* Handle cancel: send TRANSFER_DONE then cleanup */
        if (atomic_get(&transfer_cancel_requested)) {
            LOG_INF("Transfer thread handling cancel");
            if (transfer_file_open) {
                fs_close(&transfer_file);
                transfer_file_open = false;
            }
            if (current_transfer.session_id[0] != '\0') {
                send_transfer_complete_once(current_transfer.session_id,
                                             (int)current_transfer.synced_files);
            }
            atomic_set(&transfer_cancel_requested, 0);
            transfer_cleanup();
            transfer_thread_wait_idle();
            goto process_next_file;
        }

        /* Check if we should be processing transfers */
        if (current_transfer.state != TRANSFER_STATE_TRANSMITTING) {
            /* Not in transmitting state, wait for next transfer */
            if (current_transfer.state == TRANSFER_STATE_IDLE) {
                transfer_thread_wait_idle();
                goto process_next_file;
            }
            /* COMPLETED or ERROR state - wait and recheck */
            k_sleep(K_MSEC(100));
            continue;
        }

        /* Check transport connection */
        if (!transport_is_connected()) {
            LOG_INF("tp disconnected, stopping xfer");
            transfer_cleanup();
            transfer_thread_wait_idle();
            LOG_INF("xfer: re-woke, state=%d tp=%d",
                current_transfer.state, current_transport != NULL);
            goto process_next_file;
        }

        LOG_INF("xfer loop: state=%d file_open=%d tp=%d",
            current_transfer.state, transfer_file_open,
            current_transport != NULL);

        /* Open first file if not already open */
        if (!transfer_file_open) {
            LOG_INF("xfer: next file (idx=%u/%u)",
                current_transfer.file_index, current_transfer.total_files);
            ret = transfer_next_file();
            LOG_INF("xfer: next_file ret=%d", ret);
            if (ret == 0) {
                consecutive_file_errors = 0;
            }
            if (ret != 0) {
                if (ret == -ENOENT) {
                    /* No more files */
                    LOG_INF("xfer done: %u files", current_transfer.synced_files);
                    current_transfer.state = TRANSFER_STATE_COMPLETED;
                    send_transfer_complete_once(current_transfer.session_id,
                                                 (int)current_transfer.synced_files);
                    transfer_cleanup();
                    transfer_thread_wait_idle();
                    goto process_next_file;
                } else if (ret == -EAGAIN) {
                    /* Missing file skipped — try next immediately */
                    consecutive_file_errors = 0;
                    goto process_next_file;
                } else {
                    /* Non-ENOENT error */
                    consecutive_file_errors++;
                    LOG_ERR("xfer err: %d (consec: %d)", ret, consecutive_file_errors);

                    if (consecutive_file_errors > 10) {
                        LOG_ERR("too many file errors, abort");
                        current_transfer.state = TRANSFER_STATE_ERROR;
                        send_transfer_complete_once(current_transfer.session_id,
                                                     (int)current_transfer.synced_files);
                        transfer_cleanup();
                        transfer_thread_wait_idle();
                        consecutive_file_errors = 0;
                        goto process_next_file;
                    }

                    k_sleep(K_MSEC(100));
                    goto process_next_file;
                }
            }
        }

        /* Send data chunks */
        while (transfer_thread_running &&
               current_transfer.state == TRANSFER_STATE_TRANSMITTING &&
               !atomic_get(&transfer_cancel_requested)) {

            /* Check if transport is connected before sending */
            if (!transport_is_connected()) {
                LOG_WRN("Transport disconnected during send");
                if (transfer_file_open) {
                    fs_close(&transfer_file);
                    transfer_file_open = false;
                }
                break;
            }

            ret = transfer_send_chunk();
            if (ret != 0) {
                if (ret == -EOF) {
                    /* File complete — send FILE_END and wait for FILE_ACK */
                    int64_t elapsed_ms = k_uptime_get() - file_transfer_start_ms;
                    uint32_t rate_kbps = 0;
                    if (elapsed_ms > 0) {
                        rate_kbps = (uint32_t)((current_transfer.bytes_transferred * 8) / elapsed_ms);
                    }
                    LOG_INF("sent: %s (%u KB, %u kbps)",
                            current_transfer.current_file,
                            (uint32_t)(current_transfer.bytes_transferred/1024),
                            rate_kbps);

                    strncpy(last_transferred_file, current_transfer.current_file,
                           sizeof(last_transferred_file) - 1);
                    last_transferred_file[sizeof(last_transferred_file) - 1] = '\0';

                    /* Send file_end and wait for FILE_ACK */
                    int file_ret = send_file_complete_event(last_transferred_file);
                    if (file_ret == -EAGAIN) {
                        /* CRC mismatch — retransmit entire file */
                        int file_retry = 0;
                        bool file_ok = false;

                        while (!file_ok && file_retry < TRANSFER_MAX_FILE_RETRIES &&
                               transfer_thread_running &&
                               current_transfer.state == TRANSFER_STATE_TRANSMITTING) {
                            file_retry++;

                            /* Repair pace (递减): halves each round toward 0
                             * (full speed) as the file converges; the next
                             * file's initial send is always full speed. */
                            uint32_t repair_pace = CONFIG_CLIP_UDP_REPAIR_PACE_US;
                            for (int i = 1; i < file_retry && repair_pace > 0; i++) {
                                repair_pace >>= 1;
                            }

                            LOG_WRN("file NACK, retry (%d/%d)", file_retry,
                                    TRANSFER_MAX_FILE_RETRIES);

                            /* Backoff: let WiFi channel settle before retransmit */
                            k_msleep(CONFIG_CLIP_UDP_NACK_BACKOFF_MS * file_retry);

                            /* Selective-repeat: retransmit only the frames the
                             * client reported missing in the NACK bitmap. Falls
                             * back to whole-file retransmit if the transport
                             * can't (or the client sent no bitmap). */
                            bool did_selective = false;
                            if (current_transport && current_transport->ops &&
                                current_transport->ops->repair_missing) {
                                int sr = current_transport->ops->repair_missing(
                                    &transfer_file,
                                    current_transfer.total_bytes, repair_pace);
                                if (sr < 0) {
                                    break;  /* fatal send error */
                                }
                                did_selective = (sr > 0);
                            }

                            if (!did_selective) {
                                /* Whole-file retransmit (legacy / no bitmap). */
                                fs_seek(&transfer_file, 0, FS_SEEK_SET);
                                current_transfer.bytes_transferred = 0;

                                /* Resend FILE_START (will reset transport file state) */
                                send_file_ready_event(current_transfer.session_id,
                                                       last_transferred_file,
                                                       current_transfer.total_bytes);

                                /* Resend all chunks */
                                bool chunk_error = false;
                                while (transfer_thread_running &&
                                       current_transfer.state == TRANSFER_STATE_TRANSMITTING) {
                                    ret = transfer_send_chunk();
                                    if (ret == -EOF) {
                                        break;
                                    } else if (ret < 0) {
                                        chunk_error = true;
                                        break;
                                    }
                                    /* Pace the retransmit: the link just
                                     * dropped frames, so don't re-blast at
                                     * full speed — give the phone time to
                                     * drain each burst. */
                                    if (CONFIG_CLIP_UDP_REPAIR_PACE_US > 0) {
                                        k_usleep(CONFIG_CLIP_UDP_REPAIR_PACE_US);
                                    }
                                }

                                if (chunk_error) {
                                    break;
                                }
                            }

                            /* Resend FILE_END and wait for FILE_ACK */
                            file_ret = send_file_complete_event(last_transferred_file);
                            if (file_ret == 0) {
                                file_ok = true;
                            } else if (file_ret != -EAGAIN) {
                                /* -ETIMEDOUT or other fatal error */
                                break;
                            }
                        }

                        if (!file_ok) {
                            LOG_ERR("retransmit fail after %d retries", file_retry);
                            fs_close(&transfer_file);
                            transfer_file_open = false;
                            current_transfer.state = TRANSFER_STATE_ERROR;
                            send_transfer_complete_once(current_transfer.session_id,
                                                         (int)current_transfer.synced_files);
                            transfer_cleanup();
                            break;
                        }

                        LOG_INF("retransmit OK attempt %d", file_retry + 1);
                    } else if (file_ret < 0) {
                        /* -ETIMEDOUT or other error */
                        LOG_ERR("FILE_END failed: %d", file_ret);
                        fs_close(&transfer_file);
                        transfer_file_open = false;
                        current_transfer.state = TRANSFER_STATE_ERROR;
                        send_transfer_complete_once(current_transfer.session_id,
                                                     (int)current_transfer.synced_files);
                        transfer_cleanup();
                        break;
                    }

                    /* File ACKed OK — file_index is already 1-based */
                    current_transfer.synced_files = current_transfer.file_index;

                    /* Close file */
                    fs_close(&transfer_file);
                    transfer_file_open = false;
                    memset(&current_transfer.current_file, 0, sizeof(current_transfer.current_file));
                    break;
                } else if (ret == -ENOTCONN || ret == -EIO) {
                    /* Connection error, cancel transfer */
                    LOG_INF("conn err in send: %d", ret);
                    /* Close file if open */
                    if (transfer_file_open) {
                        fs_close(&transfer_file);
                        transfer_file_open = false;
                    }
                    /* Do NOT increment synced_files - file was not completed */
                    current_transfer.state = TRANSFER_STATE_ERROR;
                    send_transfer_complete_once(current_transfer.session_id,
                                                 (int)current_transfer.synced_files);
                    transfer_cleanup();
                    break;
                } else {
                    /* Any other error (e.g. -ETIMEDOUT): close file and exit transfer */
                    LOG_ERR("send err: %d, abort", ret);
                    if (transfer_file_open) {
                        fs_close(&transfer_file);
                        transfer_file_open = false;
                    }
                    current_transfer.state = TRANSFER_STATE_ERROR;
                    send_transfer_complete_once(current_transfer.session_id,
                                                 (int)current_transfer.synced_files);
                    transfer_cleanup();
                    break;
                }
            }

            /* Update progress */
            if (current_transfer.total_bytes > 0) {
                current_transfer.progress_percent =
                    (uint8_t)((current_transfer.bytes_transferred * 100) / current_transfer.total_bytes);
            }
        }
    }

    LOG_DBG("Transfer thread exiting");
}

static int transfer_next_file(void)
{
    char filepath[128];
    struct fs_dirent entry;
    int ret;

    /* If specific filename is set, use it directly */
    if (current_transfer.current_file[0] != '\0') {
        uint32_t file_num = (uint32_t)atoi(current_transfer.current_file);
        ret = build_transfer_path(filepath, sizeof(filepath),
                                  current_transfer.session_id,
                                  file_num > 0 ? file_num : 1);
        if (ret != 0) {
            return ret;
        }
        goto open_file;
    }

    /* Generate next filename from file number */
    uint32_t file_num = current_transfer.file_index + 1;

    if (current_transfer.continuous) {
        /* ========================================
         * CONTINUOUS MODE: Session is being recorded
         * ========================================
         * - Wait for files to be written
         * - Wait for new files to appear
         * - Detect recording stop to end transfer
         */
        generate_filename(file_num, current_transfer.current_file);
        ret = build_transfer_path(filepath, sizeof(filepath),
                                  current_transfer.session_id, file_num);
        if (ret != 0) {
            return ret;
        }

        /* Check if file exists */
        if (fs_stat(filepath, &entry) != 0) {
            /* File doesn't exist yet - wait for it (recording in progress) */
            int wait_count = 0;
            while (wait_count < 600) {  /* Wait up to 5 minutes (600 * 500ms) */
                /* Check if file appeared */
                if (fs_stat(filepath, &entry) == 0) {
                    LOG_INF("Found new file: %s", current_transfer.current_file);
                    goto wait_for_write;
                }

                /* Check if recording stopped - if so, no more files coming */
                if (!audio_is_recording() && wait_count > 4) {
                    /* Check if next file exists (skip missing files) */
                    uint32_t next_num = file_num + 1;
                    char next_name[16];
                    char next_filepath[128];
                    generate_filename(next_num, next_name);
                    ret = build_transfer_path(next_filepath, sizeof(next_filepath),
                                              current_transfer.session_id, next_num);
                    if (ret != 0) {
                        return ret;
                    }
                    if (fs_stat(next_filepath, &entry) == 0) {
                        LOG_WRN("File missing: %s, skipping", current_transfer.current_file);
                        current_transfer.file_index = file_num;
                        current_transfer.current_file[0] = '\0';
                        return -EAGAIN;
                    }
                    LOG_INF("rec stopped, ending xfer");
                    return -ENOENT;
                }

                /* Check if still connected */
                if (!transport_is_connected()) {
                    LOG_INF("tp disconnected");
                    return -ENOTCONN;
                }

                /* Check if transfer was canceled */
                if (current_transfer.state != TRANSFER_STATE_TRANSMITTING) {
                    LOG_INF("xfer canceled");
                    return -ECANCELED;
                }

                /* Wait for file closed signal with timeout */
                struct k_sem *file_closed_sem = storage_get_file_closed_sem();
                if (file_closed_sem &&
                    k_sem_take(file_closed_sem, K_MSEC(500)) == 0) {
                    /* File closed signal received, check if it's our file */
                    if (fs_stat(filepath, &entry) == 0) {
                        LOG_INF("File ready: %s", current_transfer.current_file);
                        goto wait_for_write;
                    }
                }
                wait_count++;
            }

            LOG_WRN("Timeout waiting for file");
            return -ENOENT;
        }

wait_for_write:
        /* Wait for file to finish writing using semaphore */
        while (storage_file_is_writing(current_transfer.session_id,
                                        current_transfer.current_file)) {
            if (!transport_is_connected()) {
                LOG_INF("transport gone during write");
                current_transfer.current_file[0] = '\0';
                return -ENOTCONN;
            }
            if (atomic_get(&transfer_cancel_requested)) {
                LOG_INF("xfer canceled while waiting for write");
                return -ECANCELED;
            }
            /* Use semaphore with timeout instead of busy polling */
            struct k_sem *file_closed_sem = storage_get_file_closed_sem();
            if (file_closed_sem) {
                k_sem_take(file_closed_sem, K_MSEC(100));
            } else {
                k_sleep(K_MSEC(100));
            }
        }

    } else {
        /* ========================================
         * NORMAL MODE: Session is complete
         * ========================================
         * - Just read files in sequence
         * - No waiting for writes
         */
        generate_filename(file_num, current_transfer.current_file);
        ret = build_transfer_path(filepath, sizeof(filepath),
                                  current_transfer.session_id, file_num);
        if (ret != 0) {
            return ret;
        }

        /* Check if file exists */
        if (fs_stat(filepath, &entry) != 0) {
            /* Check if we've passed the expected file count */
            if (current_transfer.total_files > 0 &&
                file_num > current_transfer.total_files) {
                LOG_INF("all files sent");
                return -ENOENT;
            }

            /* File missing in sequence — skip and try next */
            LOG_WRN("File missing: %s, skipping", current_transfer.current_file);
            current_transfer.file_index = file_num;  /* Advance past missing file */
            current_transfer.current_file[0] = '\0';  /* Clear so next call generates new filename */
            /* Safety: stop at total_files + 10 missing files */
            if (file_num > current_transfer.total_files + 10) {
                LOG_INF("too many missing files, stopping at %u", file_num);
                return -ENOENT;
            }
            return -EAGAIN;
        }

        /* Check if we've transferred all files */
        if (current_transfer.total_files > 0 &&
            file_num > current_transfer.total_files) {
            LOG_INF("All files transferred");
            return -ENOENT;
        }
    }

open_file:
    /* Verify file exists and get size */
    if (fs_stat(filepath, &entry) != 0) {
        LOG_WRN("File not found: %s", filepath);
        current_transfer.current_file[0] = '\0';
        return -ENOENT;
    }

    /* Skip very small files (might still be flushing) */
    int retry_count = 0;
    while (entry.size <= 100 && retry_count < 10) {
        k_sleep(K_MSEC(100));
        if (fs_stat(filepath, &entry) != 0) {
            return -ENOENT;
        }
        retry_count++;
    }

    /* Open file */
    fs_file_t_init(&transfer_file);
    ret = fs_open(&transfer_file, filepath, FS_O_READ);
    if (ret != 0) {
        LOG_ERR("File open failed: %s (%d)", filepath, ret);
        current_transfer.current_file[0] = '\0';
        return ret;
    }

    /* Skip empty files */
    if (entry.size == 0) {
        LOG_WRN("Empty file: %s", current_transfer.current_file);
        fs_close(&transfer_file);
        fs_unlink(filepath);
        current_transfer.current_file[0] = '\0';
        return -ENOENT;
    }

    current_transfer.file_index++;
    transfer_file_open = true;
    current_transfer.total_bytes = entry.size;
    current_transfer.bytes_transferred = 0;  /* Reset for accurate rate calculation */
    file_transfer_start_ms = k_uptime_get();

    LOG_INF("sending: %s (%u KB)", current_transfer.current_file, (uint32_t)entry.size/1024);
    send_file_ready_event(current_transfer.session_id, current_transfer.current_file, entry.size);

    return 0;
}

static int transfer_send_chunk(void)
{
    ssize_t bytes_read;
    int ret;
    int64_t t0, t_read, t_send;

    if (!transfer_file_open) {
        LOG_ERR("File not open!");
        return -EIO;
    }

    if (!current_transport || !current_transport->ops || !current_transport->ops->send_file_data) {
        LOG_ERR("No transport available for sending");
        return -ENOTCONN;
    }

    /* Read chunk from file into static buffer */
    t0 = k_uptime_get();
    bytes_read = fs_read(&transfer_file, chunk_buffer, CONFIG_CLIP_TRANSFER_CHUNK_SIZE);
    t_read = k_uptime_get() - t0;

    if (bytes_read < 0) {
        LOG_ERR("File read error: %zd", bytes_read);
        return bytes_read;
    }

    if (bytes_read == 0) {
        /* End of file */
        LOG_DBG("End of file: %u bytes", (unsigned int)current_transfer.bytes_transferred);
        return -EOF;
    }

    /* Send via the transport that initiated this transfer */
    t0 = k_uptime_get();
    ret = current_transport->ops->send_file_data(chunk_buffer, bytes_read);
    t_send = k_uptime_get() - t0;

    if (ret < 0) {
        LOG_ERR("Transport send error: %d", ret);
        return ret;
    }

    /* Log timing for first few chunks and every 64th chunk */
    if (chunk_count < 3 || chunk_count % 64 == 0) {
        LOG_INF("chunk %d: read=%dms, send=%dms, size=%d",
                chunk_count, (int)t_read, (int)t_send, (int)bytes_read);
    }
    chunk_count++;

    /* Only increment bytes_transferred if send actually succeeded */
    current_transfer.bytes_transferred += bytes_read;

    return 0;
}

static void send_file_ready_event(const char *session_id, const char *filename, uint64_t size)
{
    if (!session_id || session_id[0] == '\0') {
        LOG_WRN("file_ready: empty sid");
        return;
    }

    if (!filename || filename[0] == '\0') {
        LOG_WRN("Cannot send file_ready: empty filename");
        return;
    }

    if (!current_transport || !current_transport->ops) {
        LOG_WRN("No transport for file_ready event");
        return;
    }

    if (current_transport->ops->send_file_start) {
        current_transport->ops->send_file_start(session_id, filename, (uint32_t)size);
    }
}

static int send_file_complete_event(const char *filename)
{
    if (!filename || filename[0] == '\0') {
        LOG_WRN("file_complete: empty filename");
        return -EINVAL;
    }

    if (!current_transport || !current_transport->ops) {
        LOG_WRN("No transport for file_complete event");
        return -ENOTCONN;
    }

    if (current_transport->ops->send_file_end) {
        return current_transport->ops->send_file_end(filename);
    }

    return 0;
}


static void send_transfer_complete_once(const char *session_id, int file_count)
{
	if (atomic_get(&transfer_complete_sent)) {
		LOG_DBG("transfer_complete dup, skip");
		return;
	}

	if (!session_id || session_id[0] == '\0') {
		LOG_WRN("transfer_complete: empty sid");
		return;
	}

	/* Save synced count to session.json */
	if (current_transfer.synced_files > 0) {
		transfer_set_synced_files(session_id, current_transfer.synced_files);
	}

	if (current_transport && current_transport->ops && current_transport->ops->send_transfer_done) {
		current_transport->ops->send_transfer_done(session_id, file_count);
	}

	LOG_INF("xfer done: %s files=%d", session_id, file_count);
	atomic_set(&transfer_complete_sent, 1);
}

static void transfer_cleanup(void)
{
	k_mutex_lock(&transfer_cleanup_mutex, K_FOREVER);

	/* Restore display icon from transfer to arrow */
	display_set_transferring(false);

	clip_cpu_boost_release();

	/* Refresh BLE inactivity timer so it doesn't expire immediately
	 * after a long transfer (or paused transfer that was canceled)
	 */
	ble_activity_refresh();

	if (transfer_file_open) {
		fs_close(&transfer_file);
		transfer_file_open = false;
	}

	/* synced count already saved in send_transfer_complete_once() */

	/* Reset state */
	current_transfer.state = TRANSFER_STATE_IDLE;
	memset(&current_transfer.current_file, 0, sizeof(current_transfer.current_file));
	memset(current_transfer.session_id, 0, sizeof(current_transfer.session_id));
	current_transfer.file_index = 0;
	current_transfer.total_files = 0;
	current_transfer.synced_files = 0;
	current_transfer.bytes_transferred = 0;
	current_transfer.total_bytes = 0;
	current_transfer.progress_percent = 0;
	atomic_set(&transfer_pause_requested, 0);
	atomic_set(&transfer_cancel_requested, 0);
	atomic_set(&transfer_complete_sent, 0);

	k_mutex_unlock(&transfer_cleanup_mutex);
}
