# STT / LLM vendor parameters and backend mapping

> How app form fields map to backend `vendor code` values; **per-vendor JSON keys are defined by the server**.

## STT (`SttProvider` in app → `vendors[].code` on backend)

| App enum label | Backend code (`asrVendorCode`) |
|----------------|--------------------------------|
| Alibaba Cloud | `aliyun` |
| Self-hosted FunASR | `funasr` |
| OpenAI Whisper | `openai_whisper` |
| Google Gemini | `google_gemini` |
| Deepgram | `deepgram` |
| Baidu | `baidu` |
| Tencent | `tencent` |
| Doubao ASR | `doubao` |
| iFlytek | `iflytek` |
| Vosk | `vosk` |
| Local Whisper | `local_whisper` |
| On-device Local STT | (no single remote code; per backend contract) |

Default base URL, default model, etc.: `lib/src/features/ai_config/domain/ai_providers.dart`.  
Required-field validation: `lib/src/features/ai_config/presentation/widgets/ai_config_validation.dart`.

**`config_json` keys and examples**: see the backend service's ASR config reference.

## LLM (`LlmProvider`)

Enum and display strings: `ai_providers.dart`. When creating/updating configs, `vendor` or type fields must match the **backend LLM adapter**; bodies follow OpenAPI (`/swagger`) and [api_reference.md](api_reference.md).

## Related docs

- Repo root `README.md`: default URLs, models, FAQ
- `enums_and_constants.md`: transcription language enums
- `api_reference.md`: `/api/v1/asr/config`, `/api/v1/llm/config`, etc.
