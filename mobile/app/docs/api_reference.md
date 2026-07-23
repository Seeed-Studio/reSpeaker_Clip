# Backend API quick reference (called from the app)

> Backend endpoints grouped by module for integration and debugging. For full request/response bodies, use backend Swagger or `lib/src/core/server/api/`.

---

## 1. Auth

| Method | Path | Purpose | Request body summary | Response |
|--------|------|---------|----------------------|----------|
| POST | `/api/v1/user/app/login` | OAuth (Apple/Google/GitHub) | `provider`, `access_token`, `id_token`; GitHub may add `code`, `code_verifier`, `redirect_uri` | `token`, `refresh_token`, `user` |
| POST | `/api/v1/user/email/login` | Email + password | `email`, `password` (MD5) | `token`, `refresh_token`, `user` |
| POST | `/api/v1/user/email/send_code` | Send verification code | `email`, `scene` (register/login/change_email/reset_password) | success, no result payload |
| POST | `/api/v1/user/email/verify_code` | Verify code (login/register/change email) | `email`, `code`, `scene` | for scene=login returns `token` |
| POST | `/api/v1/user/register` | Email registration | `email`, `password` (MD5), `username` | `token`, `refresh_token`, `user` |
| POST | `/api/v1/user/refresh` | Refresh token | `refresh_token` | `token`, `refresh_token` |
| POST | `/api/v1/user/logout` | Log out | — | success |
| POST | `/api/v1/user/deactivate` | Delete account | — | success |

**Headers**: `Authorization: Bearer <access_token>` (except login/register/send_code/verify_code/refresh)

---

## 2. User

| Method | Path | Purpose | Request / query | Response |
|--------|------|---------|-----------------|----------|
| GET | `/api/v1/user` | Current profile | — | `id`, `name`, `email`, `avatar_url`, `provider`, `role`, etc. |
| PUT | `/api/v1/user` | Update profile | `name`, `avatar_url`, etc. | success |
| PUT | `/api/v1/user/email` | Change email | `email`, `code` (verification) | success |
| PUT | `/api/v1/user/password` | Change password | `old_password`, `new_password` (MD5) | success |
| POST | `/api/v1/user/password/reset` | Forgot password | `email`, `code`, `new_password` | success |

---

## 3. OSS upload

| Method | Path | Purpose | Request body | Response |
|--------|------|---------|--------------|----------|
| POST | `/api/v1/oss/upload` | Small file (≤5MB) | `multipart/form-data`: `type`, `file` | `public_url`, `object_key`, `size`, `content_type` |
| POST | `/api/v1/oss/upload/init` | Multipart init | `type`, `filename` | `upload_id` |
| POST | `/api/v1/oss/upload/chunk` | Multipart chunk | `upload_id`, `chunk_index`, `chunk` | success |
| POST | `/api/v1/oss/upload/complete` | Multipart complete | `upload_id` | `public_url`, `object_key`, etc. |

**Timeouts**: upload 600s; init/complete 180s.

---

## 4. ASR (speech-to-text)

| Method | Path | Purpose | Request / query | Response |
|--------|------|---------|-----------------|----------|
| GET | `/api/v1/asr/config` | List ASR configs | — | `default_vendor`, `vendors`, `items` |
| GET | `/api/v1/asr/config/:id` | Single config | — | vendor config detail |
| POST | `/api/v1/asr/config` | Create ASR config | `code`, `config_json` | success |
| PUT | `/api/v1/asr/config/:id` | Update ASR config | `config_json` | success |
| DELETE | `/api/v1/asr/config/:id` | Delete ASR config | — | success |
| GET | `/api/v1/asr/vendors` | Configured vendor list | — | `codes`, `default_vendor` |
| GET | `/api/v1/asr/config/default` | Default vendor | — | `default_vendor` |
| PUT | `/api/v1/asr/config/default` | Set default vendor | `default_vendor` | success |
| POST | `/api/v1/asr/jobs` | URL transcription job | `url`, `id`, `language?`, `file_id?`, `mac_address?` | `job id`, `status` |
| GET | `/api/v1/asr/jobs/:id` | Job status | — | `status`, `asr_result_id?`, `error_message?` |
| GET | `/api/v1/asr/result/:id` | Transcription result | — | `result_text`, `asr_config_id`, `created_at` |
| POST | `/api/v1/asr/binary` | Binary transcription | Query: `id`, `language?`, `file_id?`, `mac_address?`, `asr_result_id?`; body: `application/octet-stream` | same pattern as above |

**Timeouts**: URL path uses job mode with client polling; `binary` uses a long client timeout.

---

## 5. LLM

| Method | Path | Purpose | Request / query | Response |
|--------|------|---------|-----------------|----------|
| GET | `/api/v1/llm/config` | List LLM configs | — | `items` (id, code, is_default, config_json) |
| POST | `/api/v1/llm/config` | Create LLM config | `code`, `config_json` | success |
| GET | `/api/v1/llm/config/:id` | Single config | — | config detail |
| PUT | `/api/v1/llm/config/:id` | Update LLM config | `config_json` | success |
| DELETE | `/api/v1/llm/config/:id` | Delete LLM config | — | success |
| GET | `/api/v1/llm/config/default` | Default config | — | default config |
| PUT | `/api/v1/llm/config/default` | Set default | `id` | success |
| POST | `/api/v1/llm/chat` | Streaming summary/chat | `config_id`, `input`, `system_prompt`, `mac_address?`, `session_id?`, `asr_result_id?` | SSE text stream |
| GET | `/api/v1/llm/prompt/public` | Public templates | — | list |
| GET | `/api/v1/llm/prompt` | User templates | — | `items` |
| GET | `/api/v1/llm/prompt/:id` | Template detail | — | `name`, `content`, `is_default`, `share_key` |
| POST | `/api/v1/llm/prompt` | Create template | `name`, `content`, `is_default?` | success |
| PUT | `/api/v1/llm/prompt/:id` | Update template | `name`, `content`, `is_default?` | success |
| DELETE | `/api/v1/llm/prompt/:id` | Delete template | — | success |
| GET | `/api/v1/llm/prompt/import/:key` | Preview shared template | — | `name`, `content` |
| POST | `/api/v1/llm/prompt/import` | Import shared | `key` | imported template |
| PUT | `/api/v1/llm/prompt/:id/share` | Enable sharing | — | `share_key` |
| DELETE | `/api/v1/llm/prompt/:id/share` | Disable sharing | — | success |
| GET | `/api/v1/llm/sessions` | Session list | `mac_address?`, `asr_result_id?`, `include_messages?`, `message_limit?` | `items` |
| GET | `/api/v1/llm/sessions/:sid` | Session detail | — | session + messages |
| DELETE | `/api/v1/llm/sessions/:sid` | Delete session | — | success |
| DELETE | `/api/v1/llm/sessions/:sid/messages/:messageId` | Delete message | — | success |

**Timeouts**: LLM chat 180s, SSE streaming.

---

## 6. General conventions

- **Response shape**: `{ code, message, details?, result? }`; `code=0` or `200` means success
- **Errors**: see `server_error_codes.dart`, `server_error_localizer`
- **Timeout constants**: [enums_and_constants.md](enums_and_constants.md)

---

## 7. Related files

| Area | Files |
|------|-------|
| Auth | `auth_api.dart`, `email_auth_api.dart` |
| User / OSS | `user_api.dart` |
| ASR | `asr_api.dart` |
| LLM | `llm_api.dart` |
| Error codes | `server_error_codes.dart` |
