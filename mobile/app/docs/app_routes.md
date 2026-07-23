# App routes and page entry points

> Path ↔ screen mapping for navigation and debugging. Defined in `lib/src/app/router/app_router.dart`.

---

## 1. Entry and auth

| Path | Page | Notes |
|------|------|-------|
| `/recordings` | `RecordingsPage` | **Default home**, file list |
| `/login` | `LoginLandingPage` | Login entry |
| `/login/email` | `EmailLoginPage` | Email OTP login (query: `email`; if a login code was already sent, `code_sent=1` or `true` so the primary button shows resend countdown instead of “send code”) |
| `/login/password` | `PasswordLoginPage` | Password login (query: `email`) |
| `/login/forgot-password` | `ForgotPasswordPage` | Forgot password |
| `/login/authorize` | `ThirdPartyAuthorizePage` | OAuth (query: `provider`) |
| `/register` | `RegisterEmailPage` | Sign up (query: `email`) |
| `/register/verify` | `RegisterVerifyCodePage` | Verify code (query: `email`) |
| `/link-identity` | `LinkIdentityPage` | Bind email after OAuth |
| `/set-password` | `SetPasswordPage` | Set password |

---

## 2. Inside shell (ShellRoute, bottom tabs)

### Devices

| Path | Page | Notes |
|------|------|-------|
| `/devices` | `DevicePage` | Device list |
| `/device/:id` | `DeviceDetailsPage` | Device detail |
| `/device/:id/firmware` | `FirmwareUpdatePage` | OTA firmware |
| `/device/:id/wifi-transfer` | `WifiTransferPage` | WiFi fast transfer (query: `session`, `recording`) |

### Recordings / files

| Path | Page | Notes |
|------|------|-------|
| `/recordings` | `RecordingsPage` | File list (main tab) |
| `/recordings/search` | `RecordingsSearchPage` | Search |
| `/recordings/:id` | `RecordingDetailPage` | Recording detail |
| `/recordings/:id/trim` | `RecordingTrimPage` | Trim |

### AI config

| Path | Page | Notes |
|------|------|-------|
| `/ai-config` | `AiConfigPage` | AI config home (main tab) |
| `/ai-config/guide` | `AiConfigGuideFlowPage` | Onboarding (no shell); shown once per app install after login |
| `/ai-config/stt` | `SttConfigsPage` | STT configs |
| `/ai-config/llm` | `LlmConfigsPage` | LLM configs |
| `/ai-config/templates` | `PromptTemplatesPage` | Templates list |
| `/ai-config/templates/new` | `PromptTemplateCreatePage`     | New template |
| `/ai-config/templates/:id` | `PromptTemplateDetailPage` | Template detail |

### Settings

| Path | Page | Notes |
|------|------|-------|
| `/settings` | `SettingsPage` | Settings home |
| `/settings/personal` | `PersonalInformationPage` | Profile |
| `/settings/change-email` | `ChangeEmailPage` | Change email |
| `/settings/change-password` | `ChangePasswordPage` | Change password |
| `/settings/language` | `LanguagePage` | Language |
| `/settings/help-feedback` | `HelpFeedbackPage` | Help & feedback |
| `/settings/about` | `AboutAppPage` | About |
| `/settings/policies` | `PoliciesPage` | Policies |
| `/settings/permissions` | `PermissionsPage` | Permissions |
| `/settings/delete-account` | `DeleteAccountPage` | Delete account |

---

## 3. Auth redirects

- **Not logged in**: redirect to `/login` except `/login`, `/register`, `/link-identity`, `/set-password`
- **Email binding required**: OAuth without email → `/link-identity`
- **Password setup required**: after OAuth → `/set-password`
- **Logged in hitting login**: redirect to `/recordings`

---

## 4. Code entry

**File**: `lib/src/app/router/app_router.dart`

**Provider**: `appRouterProvider`
