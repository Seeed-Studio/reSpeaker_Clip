import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  static const _dbName = 'respeaker_app.db';
  static const _dbVersion = 26; // v26: drop prompt_templates (API-only like STT/LLM)

  /// Best-effort schema fix for cases where user_version is already bumped
  /// but the table was created without the expected column (e.g. hot reload /
  /// older build mistakenly created v17 schema).
  static Future<void> _ensureColumnExists(
    Database db, {
    required String table,
    required String column,
    required String columnDefSql,
  }) async {
    try {
      final rows = await db.rawQuery('PRAGMA table_info($table);');
      final exists = rows.any((r) => r['name'] == column);
      if (!exists) {
        await db.execute('ALTER TABLE $table ADD COLUMN $column $columnDefSql;');
      }
    } catch (_) {
      // ignore - best effort only
    }
  }

  static Future<void> _createRecordingSummaries(Database db) async {
    await db.execute('''
CREATE TABLE recording_summaries(
  id TEXT PRIMARY KEY,
  recording_id TEXT NOT NULL,
  version INTEGER NOT NULL,
  title TEXT NOT NULL,
  content TEXT NOT NULL,
  remote_session_id TEXT,
  remote_message_id INTEGER,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
''');
    await db.execute('CREATE INDEX idx_recording_summaries_recording_id ON recording_summaries(recording_id);');
    await db.execute('CREATE INDEX idx_recording_summaries_recording_id_version ON recording_summaries(recording_id, version);');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_recording_summaries_remote_map ON recording_summaries(remote_session_id, remote_message_id);');
  }

  static Future<void> _createRecordings(Database db) async {
    await db.execute('''
CREATE TABLE recordings(
  id TEXT PRIMARY KEY,
  device_id TEXT,
  device_path TEXT NOT NULL,
  session_id TEXT,
  asr_result_id INTEGER,
  recording_state TEXT NOT NULL DEFAULT 'idle',
  started_at TEXT,
  ended_at TEXT,
  tmp_path TEXT,
  mtu INTEGER,
  last_packet_at TEXT,
  transfer_started_at TEXT,
  transfer_finished_at TEXT,
  remote_id TEXT,
  remote_url TEXT,
  transport TEXT,
  connection_id TEXT,
  last_stt_job_id TEXT,
  last_summary_job_id TEXT,
  name TEXT,
  size_bytes INTEGER,
  duration_seconds INTEGER,
  created_at TEXT,
  local_path TEXT,
  format TEXT,
  container TEXT,
  sample_rate INTEGER,
  channels INTEGER,
  bit_depth INTEGER,
  received_bytes INTEGER,
  expected_bytes INTEGER,
  last_seq INTEGER,
  crc32 INTEGER,
  folder_id TEXT,
  source TEXT NOT NULL DEFAULT 'device',
  is_deleted INTEGER NOT NULL DEFAULT 0,
  deleted_at TEXT,
  device_present INTEGER NOT NULL DEFAULT 1,
  transfer_state TEXT NOT NULL DEFAULT 'not_started',
  transfer_progress REAL,
  transfer_error TEXT,
  transfer_error_code TEXT,
  upload_state TEXT NOT NULL DEFAULT 'not_uploaded',
  job_state TEXT NOT NULL DEFAULT 'none',
  transcript TEXT,
  summary TEXT,
  current_summary_id TEXT,
  transcript_path TEXT,
  summary_path TEXT,
  last_stt_config_id TEXT,
  last_llm_config_id TEXT,
  last_template_id TEXT,
  last_language TEXT,
  last_auto_speaker INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL
);
''');

    await db.execute('CREATE INDEX idx_recordings_device_id ON recordings(device_id);');
    await db.execute('CREATE INDEX idx_recordings_created_at ON recordings(created_at);');
    await db.execute('CREATE INDEX idx_recordings_updated_at ON recordings(updated_at);');
    await db.execute('CREATE INDEX idx_recordings_folder_id ON recordings(folder_id);');
    await db.execute('CREATE INDEX idx_recordings_is_deleted ON recordings(is_deleted);');
    await db.execute('CREATE INDEX idx_recordings_source ON recordings(source);');
    await db.execute('CREATE INDEX idx_recordings_remote_id ON recordings(remote_id);');
    await db.execute('CREATE UNIQUE INDEX idx_recordings_asr_result_id ON recordings(asr_result_id);');
  }

  static Future<void> _createJobs(Database db) async {
    await db.execute('''
CREATE TABLE jobs(
  id TEXT PRIMARY KEY,
  recording_id TEXT NOT NULL,
  type TEXT NOT NULL,
  state TEXT NOT NULL,
  progress REAL,
  payload_json TEXT,
  result_json TEXT,
  error TEXT,
  attempt INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
''');
    await db.execute('CREATE INDEX idx_jobs_recording_id ON jobs(recording_id);');
    await db.execute('CREATE INDEX idx_jobs_type_state_updated ON jobs(type, state, updated_at);');
  }

  static Future<void> _createLlmSessions(Database db) async {
    await db.execute('''
CREATE TABLE llm_sessions(
  session_id TEXT PRIMARY KEY,
  title TEXT,
  created_at TEXT,
  updated_at TEXT
);
''');
    await db.execute('CREATE INDEX idx_llm_sessions_updated_at ON llm_sessions(updated_at);');
  }

  static Future<void> _createLlmSessionMessages(Database db) async {
    await db.execute('''
CREATE TABLE llm_session_messages(
  id INTEGER,
  session_id TEXT NOT NULL,
  role TEXT,
  content TEXT,
  created_at TEXT,
  PRIMARY KEY (session_id, id)
);
''');
    await db.execute('CREATE INDEX idx_llm_session_messages_session_id ON llm_session_messages(session_id);');
    await db.execute('CREATE INDEX idx_llm_session_messages_created_at ON llm_session_messages(created_at);');
  }

  static Future<String> dbPathForUserKey(String? userKey) async {
    final dir = await getApplicationDocumentsDirectory();
    final safeKey =
        (userKey ?? '').trim().replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '');
    final dbFile = safeKey.isEmpty ? _dbName : 'respeaker_app_$safeKey.db';
    return p.join(dir.path, dbFile);
  }

  /// Opens the SQLite file for [userKey] (`respeaker_app_{userKey}.db`).
  static Future<Database> openForUserKey(String userKey) async {
    final safe = userKey.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '');
    if (safe.isEmpty) {
      throw ArgumentError('openForUserKey requires a non-empty account key');
    }
    final dbPath = await dbPathForUserKey(safe);

    final db = await openDatabase(
      dbPath,
      version: _dbVersion,
      onCreate: (db, version) async {
        await _createRecordings(db);
        await _createRecordingSummaries(db);

        await db.execute('''
CREATE TABLE folders(
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  color INTEGER NOT NULL DEFAULT 0,
  icon INTEGER NOT NULL DEFAULT 0,
  sort_index INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
''');
        await db.execute('''
CREATE INDEX idx_folders_sort_index ON folders(sort_index);
''');

        await _createJobs(db);

        await db.execute('''
CREATE TABLE devices(
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  sn TEXT,
  model TEXT NOT NULL,
  battery_percent INTEGER,
  recording_mode INTEGER NOT NULL DEFAULT 0,
  firmware_version TEXT,
  has_firmware_update INTEGER NOT NULL DEFAULT 0,
  is_online INTEGER NOT NULL DEFAULT 0,
  last_seen TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
''');

        await db.execute('''
CREATE INDEX idx_devices_is_online ON devices(is_online);
''');

        // -------------------------- AI Config (STT/LLM/templates are API-only) -------------------------- //

        // -------------------------- LLM Sessions -------------------------- //
        await _createLlmSessions(db);
        await _createLlmSessionMessages(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // v25: recording_summaries remote map columns (local Summary row <-> server message)
        if (oldVersion < 25) {
          await _ensureColumnExists(
            db,
            table: 'recording_summaries',
            column: 'remote_session_id',
            columnDefSql: 'TEXT',
          );
          await _ensureColumnExists(
            db,
            table: 'recording_summaries',
            column: 'remote_message_id',
            columnDefSql: 'INTEGER',
          );
          try {
            await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_recording_summaries_remote_map ON recording_summaries(remote_session_id, remote_message_id);',
            );
          } catch (_) {
            // ignore
          }
        }
        // NOTE: Pre-prod DB; v13 rebuilds recordings/jobs to align fields (cloud/job payload, etc.).
        final rebuiltRecordings = oldVersion < 13;
        final rebuiltJobs = oldVersion < 13;
        final rebuiltAiConfigs = oldVersion < 14;
        if (rebuiltRecordings) {
          await db.execute('DROP TABLE IF EXISTS recordings;');
          await db.execute('DROP INDEX IF EXISTS idx_recordings_device_id;');
          await db.execute('DROP INDEX IF EXISTS idx_recordings_created_at;');
          await db.execute('DROP INDEX IF EXISTS idx_recordings_updated_at;');
          await db.execute('DROP INDEX IF EXISTS idx_recordings_folder_id;');
          await db.execute('DROP INDEX IF EXISTS idx_recordings_is_deleted;');
          await db.execute('DROP INDEX IF EXISTS idx_recordings_source;');
          await db.execute('DROP INDEX IF EXISTS idx_recordings_remote_id;');
          await db.execute('DROP INDEX IF EXISTS idx_recordings_asr_result_id;');
          await _createRecordings(db);
        }
        if (rebuiltJobs) {
          await db.execute('DROP TABLE IF EXISTS jobs;');
          await db.execute('DROP INDEX IF EXISTS idx_jobs_recording_id;');
          await db.execute('DROP INDEX IF EXISTS idx_jobs_type_state_updated;');
          await _createJobs(db);
        }
        if (rebuiltAiConfigs) {
          await db.execute('DROP TABLE IF EXISTS stt_configs;');
          await db.execute('DROP INDEX IF EXISTS idx_stt_configs_sort_index;');
          await db.execute('DROP TABLE IF EXISTS llm_configs;');
          await db.execute('DROP INDEX IF EXISTS idx_llm_configs_sort_index;');
        }

        if (oldVersion < 19) {
          try {
            await db.execute('ALTER TABLE prompt_templates ADD COLUMN remote_id INTEGER;');
          } catch (_) {
            // ignore if already exists
          }
        }

        if (oldVersion < 20) {
          await db.execute('DROP TABLE IF EXISTS llm_sessions;');
          await db.execute('DROP TABLE IF EXISTS llm_session_messages;');
          await _createLlmSessions(db);
          await _createLlmSessionMessages(db);
        }

        // v23: drop stt_configs, llm_configs (STT/LLM are API-only)
        if (oldVersion < 23) {
          await db.execute('DROP TABLE IF EXISTS stt_configs;');
          await db.execute('DROP INDEX IF EXISTS idx_stt_configs_sort_index;');
          await db.execute('DROP TABLE IF EXISTS llm_configs;');
          await db.execute('DROP INDEX IF EXISTS idx_llm_configs_sort_index;');
        }

        // v24: prompt_templates.is_imported (imported templates hide share)
        if (oldVersion < 24) {
          try {
            await db.execute('ALTER TABLE prompt_templates ADD COLUMN is_imported INTEGER NOT NULL DEFAULT 0;');
          } catch (_) {
            // ignore if already exists
          }
        }

        // v21: recordings.asr_result_id + unique index
        if (oldVersion < 21) {
          try {
            await db.execute('ALTER TABLE recordings ADD COLUMN asr_result_id INTEGER;');
          } catch (_) {
            // ignore if already exists
          }
          try {
            await db.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_recordings_asr_result_id ON recordings(asr_result_id);');
          } catch (_) {
            // ignore
          }
        }

        // v22: recordings.transfer_error_code for i18n
        if (oldVersion < 22) {
          try {
            await db.execute('ALTER TABLE recordings ADD COLUMN transfer_error_code TEXT;');
          } catch (_) {
            // ignore if already exists
          }
        }

        // v15: versioned summaries.
        if (oldVersion < 15) {
          // 1) Create new summaries table (if not exists).
          await db.execute('DROP TABLE IF EXISTS recording_summaries;');
          await db.execute('DROP INDEX IF EXISTS idx_recording_summaries_recording_id;');
          await db.execute('DROP INDEX IF EXISTS idx_recording_summaries_recording_id_version;');
          await _createRecordingSummaries(db);

          // 2) Add current_summary_id column to recordings (best-effort).
          try {
            await db.execute('ALTER TABLE recordings ADD COLUMN current_summary_id TEXT;');
          } catch (_) {
            // ignore if already exists
          }

          // 3) Migrate existing recordings.summary into V1 summary rows.
          final rows = await db.query('recordings', columns: ['id', 'summary', 'updated_at', 'created_at', 'current_summary_id']);
          for (final r in rows) {
            final recordingId = r['id'] as String?;
            if (recordingId == null) continue;
            final existing = (r['summary'] as String?)?.trim();
            if (existing == null || existing.isEmpty) continue;

            // If current_summary_id already set, skip migration for this row.
            final cur = r['current_summary_id'] as String?;
            if (cur != null && cur.isNotEmpty) continue;

            final id = '${recordingId}__sum_v1';
            final createdAt = (r['created_at'] as String?) ?? DateTime.now().toIso8601String();
            final updatedAt = (r['updated_at'] as String?) ?? DateTime.now().toIso8601String();
            await db.insert(
              'recording_summaries',
              {
                'id': id,
                'recording_id': recordingId,
                'version': 1,
                'title': '总结 V1',
                'content': existing,
                'created_at': createdAt,
                'updated_at': updatedAt,
              },
              conflictAlgorithm: ConflictAlgorithm.ignore,
            );
            await db.update(
              'recordings',
              {
                'current_summary_id': id,
                'updated_at': DateTime.now().toIso8601String(),
              },
              where: 'id = ?',
              whereArgs: [recordingId],
            );
          }
        }

        // v17: some installs created recordings without current_summary_id (onCreate path).
        if (oldVersion < 17) {
          try {
            await db.execute('ALTER TABLE recordings ADD COLUMN current_summary_id TEXT;');
          } catch (_) {
            // ignore if already exists
          }
        }

        // v18: force-migrate installs that are "v17 but missing current_summary_id".
        if (oldVersion < 18) {
          try {
            await db.execute('ALTER TABLE recordings ADD COLUMN current_summary_id TEXT;');
          } catch (_) {
            // ignore if already exists
          }
        }

        // v16: ensure created_at is not null/empty so Create Time sort works.
        if (oldVersion < 16) {
          try {
            await db.execute("UPDATE recordings SET created_at = updated_at WHERE created_at IS NULL OR TRIM(created_at) = '';");
          } catch (_) {
            // ignore
          }
        }

        if (oldVersion < 2) {
          await db.execute('''
CREATE TABLE devices(
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  sn TEXT,
  model TEXT NOT NULL,
  battery_percent INTEGER,
  recording_mode INTEGER NOT NULL DEFAULT 0,
  firmware_version TEXT,
  has_firmware_update INTEGER NOT NULL DEFAULT 0,
  is_online INTEGER NOT NULL DEFAULT 0,
  last_seen TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
''');

          await db.execute('''
CREATE INDEX idx_devices_is_online ON devices(is_online);
''');
        }

        if (oldVersion < 3) {
          // Add device details fields for the new Device Details page.
          // Use ALTER TABLE to keep existing data.
          await db.execute("ALTER TABLE devices ADD COLUMN sn TEXT;");
          await db.execute("ALTER TABLE devices ADD COLUMN recording_mode INTEGER NOT NULL DEFAULT 0;");
          await db.execute("ALTER TABLE devices ADD COLUMN firmware_version TEXT;");
          await db.execute("ALTER TABLE devices ADD COLUMN has_firmware_update INTEGER NOT NULL DEFAULT 0;");
        }

        if (oldVersion < 4) {
          await db.execute('''
CREATE TABLE prompt_templates(
  id TEXT PRIMARY KEY,
  remote_id INTEGER,
  name TEXT NOT NULL,
  prompt TEXT NOT NULL,
  is_default INTEGER NOT NULL DEFAULT 0,
  share_key TEXT,
  icon_code INTEGER NOT NULL DEFAULT 0,
  sort_index INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
''');
          await db.execute('''
CREATE INDEX idx_prompt_templates_sort_index ON prompt_templates(sort_index);
''');
        }

        if (!rebuiltRecordings && oldVersion < 5) {
          // Track which STT/LLM/template was used for this recording.
          await db.execute('ALTER TABLE recordings ADD COLUMN last_stt_config_id TEXT;');
          await db.execute('ALTER TABLE recordings ADD COLUMN last_llm_config_id TEXT;');
          await db.execute('ALTER TABLE recordings ADD COLUMN last_template_id TEXT;');
          await db.execute('ALTER TABLE recordings ADD COLUMN last_language TEXT;');
          await db.execute('ALTER TABLE recordings ADD COLUMN last_auto_speaker INTEGER NOT NULL DEFAULT 1;');
        }

        if (!rebuiltRecordings && oldVersion < 6) {
          // File transfer progress (device -> app) for better UX in Files list.
          await db.execute("ALTER TABLE recordings ADD COLUMN transfer_state TEXT NOT NULL DEFAULT 'not_started';");
          await db.execute('ALTER TABLE recordings ADD COLUMN transfer_progress REAL;');
          await db.execute('ALTER TABLE recordings ADD COLUMN transfer_error TEXT;');
        }

        if (!rebuiltRecordings && oldVersion < 7) {
          // Whether the file still exists on device SD card.
          await db.execute('ALTER TABLE recordings ADD COLUMN device_present INTEGER NOT NULL DEFAULT 1;');
          // Local-only files (trimmed/imported) should be marked not present on device.
          await db.execute('UPDATE recordings SET device_present = 0 WHERE device_id IS NULL;');
        }

        if (!rebuiltRecordings && oldVersion < 8) {
          // Folder + recycle bin + source (for Files filter & sort UX)
          await db.execute('ALTER TABLE recordings ADD COLUMN folder_id TEXT;');
          await db.execute("ALTER TABLE recordings ADD COLUMN source TEXT NOT NULL DEFAULT 'device';");
          await db.execute('ALTER TABLE recordings ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0;');
          await db.execute('ALTER TABLE recordings ADD COLUMN deleted_at TEXT;');

          await db.execute('''
CREATE TABLE folders(
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  sort_index INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
''');
          await db.execute('''
CREATE INDEX idx_folders_sort_index ON folders(sort_index);
''');

          // Existing local-only recordings should be treated as local source.
          await db.execute("UPDATE recordings SET source = 'local' WHERE device_id IS NULL;");
        }

        if (oldVersion < 9) {
          // Folder style: color + icon.
          await db.execute('ALTER TABLE folders ADD COLUMN color INTEGER NOT NULL DEFAULT 0;');
          await db.execute('ALTER TABLE folders ADD COLUMN icon INTEGER NOT NULL DEFAULT 0;');
        }

        if (oldVersion < 10) {
          // Prompt template icon (for Templates list/detail UI)
          try {
            await db.execute('ALTER TABLE prompt_templates ADD COLUMN icon_code INTEGER NOT NULL DEFAULT 0;');
          } catch (_) {
            // ignore if table already dropped / column exists
          }
        }

        // v26 last: drop prompt_templates after any legacy create/alter above.
        if (oldVersion < 26) {
          await db.execute('DROP TABLE IF EXISTS prompt_templates;');
          await db.execute('DROP INDEX IF EXISTS idx_prompt_templates_sort_index;');
        }
      },
      onOpen: (db) async {
        // Defensive schema fix: even if user_version didn't change, ensure column exists.
        await _ensureColumnExists(
          db,
          table: 'recordings',
          column: 'current_summary_id',
          columnDefSql: 'TEXT',
        );
        await _ensureColumnExists(
          db,
          table: 'recording_summaries',
          column: 'remote_session_id',
          columnDefSql: 'TEXT',
        );
        await _ensureColumnExists(
          db,
          table: 'recording_summaries',
          column: 'remote_message_id',
          columnDefSql: 'INTEGER',
        );
      },
    );
    return db;
  }
}

