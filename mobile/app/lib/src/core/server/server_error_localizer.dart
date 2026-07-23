import 'package:flutter/material.dart';

import '../auth/oauth_display_name_error.dart';
import '../l10n/app_localizations.dart';
import '../validation/text_charset.dart';
import 'sensecraft_auth/sensecraft_error_codes.dart';
import 'server_error_codes.dart';
import 'server_exception.dart';

/// Maps [ServerException] to a localized message for display.
/// Prefer bizCode mapping; fallback to statusCode for generic HTTP errors, then to [ServerException.message].
String serverErrorMessage(BuildContext context, ServerException e) {
  final l10n = AppLocalizations.of(context);
  if (l10n == null) return e.message;
  final languageCode =
      Localizations.localeOf(context).languageCode.toLowerCase();

  if (e.messageKey != null) {
    final msg = l10n.messageForKey(e.messageKey!);
    if (msg != null) return msg;
  }

  final errorKeyMsg = _messageForErrorKey(languageCode, e.errorKey);
  if (errorKeyMsg != null) return errorKeyMsg;

  if (isPromptTemplateCharsetServerError(e)) {
    return l10n.promptTemplateUnsupportedChars;
  }

  if (isOAuthDisplayNameDbCharsetError(e)) {
    return l10n.errorOAuthDisplayNameDbCharset;
  }

  if (e.bizCode != null) {
    final msg = _messageForBizCode(l10n, e.bizCode!);
    if (msg != null) return msg;
  }

  if (e.statusCode == 408) return l10n.errorNetworkTimeout;

  final trimmed = e.message.trim();
  if (trimmed.isNotEmpty) return trimmed;
  return l10n.errorRequestFailed;
}

/// Friendly text for config list / template load failures.
/// Never surfaces raw `ServerException(...)` / stack-like `toString()`.
String friendlyLoadErrorMessage(BuildContext context, Object error) {
  if (error is ServerException) {
    return serverErrorMessage(context, error);
  }
  final l10n = AppLocalizations.of(context);
  return l10n?.errorRequestFailed ?? 'Request failed.';
}

/// For dialogs, prefer backend details when available so vendor-specific ASR/LLM
/// errors are visible to users; otherwise fall back to localized generic text.
String serverErrorDialogMessage(BuildContext context, Object error) {
  if (error is! ServerException) return error.toString();
  final languageCode =
      Localizations.localeOf(context).languageCode.toLowerCase();
  final errorKeyMsg = _messageForErrorKey(languageCode, error.errorKey);
  if (errorKeyMsg != null) return errorKeyMsg;
  final details = error.details?.trim() ?? '';
  // Vendor payloads (e.g. Gemini 429 JSON) can be thousands of chars — keep
  // dialogs readable; short vendor hints are still shown verbatim.
  if (details.isNotEmpty && details.length <= 400) return details;
  return serverErrorMessage(context, error);
}

String? _messageForErrorKey(String languageCode, String? errorKey) {
  if (errorKey == null || errorKey.trim().isEmpty) return null;
  final zh = languageCode.startsWith('zh');
  switch (errorKey) {
    case 'openai_whisper_file_too_large_non_wav':
      return zh
          ? '音频过大，且不是 WAV 格式。OpenAI Whisper 只支持对 WAV 自动分段，请先转成 WAV 或压缩后重试。'
          : 'Audio is too large and not WAV. OpenAI Whisper only supports auto-splitting for WAV files. Convert to WAV or compress and retry.';
    case 'openai_whisper_hallucination_detected':
      return zh
          ? '检测到 OpenAI Whisper 转写结果异常，可能与录音内容不符。请重试，或切换到百度、讯飞等 ASR。'
          : 'OpenAI Whisper returned an abnormal transcription that may not match the audio. Retry or switch to another ASR vendor.';
    case 'gemini_quota_exceeded':
      return zh
          ? 'Google Gemini 配额已用尽。请等待 1 到 2 分钟后重试，或更换新的 API Key / 其他 LLM。'
          : 'Google Gemini quota has been exceeded. Wait 1-2 minutes and retry, or use a new API key / another LLM vendor.';
    case 'google_gemini_quota_exceeded':
      return zh
          ? 'Google Gemini 配额已用尽。请等待 1 到 2 分钟后重试，或更换新的 API Key / 其他 ASR。'
          : 'Google Gemini quota has been exceeded. Wait 1-2 minutes and retry, or use a new API key / another ASR vendor.';
    case 'google_gemini_low_quality_transcript':
      return zh
          ? 'Gemini 返回的转写疑似乱码或重复拟声（如咕咕咕），多为长音频、网络中断或难辨音频导致。请重试转写、换 Deepgram/百度等专用语音识别，或缩短单次音频。'
          : 'Gemini returned a transcript that looks like gibberish or repeated sounds. Long audio, network issues, or unclear audio often cause this. Retry, use a dedicated ASR vendor, or shorten the clip.';
    case 'google_gemini_empty_transcript':
      return zh
          ? 'Gemini 未返回转写内容。可能是静音、文件仍在处理，或音频编码异常。请检查录音后重试，或更换其他 ASR。'
          : 'Gemini returned an empty transcript. Possible causes: silent audio, file still processing, or unsupported audio encoding. Check the recording or try another ASR vendor.';
    case 'gemini_auth_failed':
      return zh
          ? 'Google Gemini 鉴权失败。请检查 API Key 是否正确、是否有权限，或更换新的 Key 后重试。'
          : 'Google Gemini authentication failed. Check whether the API key is valid and authorized, or try a new key.';
    case 'gemini_bad_request':
      return zh
          ? 'Google Gemini 请求参数无效。请检查模型名、请求内容后重试。'
          : 'Google Gemini rejected the request as invalid. Check the model name and request payload, then retry.';
    case 'iflytek_invalid_app_info':
      return zh
          ? '讯飞应用信息无效。请检查 AppID、APISecret 是否正确，并确认该应用已开通录音转写能力。'
          : 'Invalid iFlytek app info. Check whether AppID and APISecret are correct and whether transcription is enabled for this app.';
    case 'iflytek_speaker_diarization_unavailable':
      return zh
          ? '讯飞当前账号或应用未开通说话人分离能力，或缺少对应权限。请先在讯飞控制台开通角色分离/声纹相关能力后再试。'
          : 'iFlytek speaker diarization is not available for the current account or app. Enable the required role-separation or voiceprint capability and retry.';
    case 'tencent_speaker_diarization_unavailable':
      return zh
          ? '腾讯云当前账号、引擎或计费资源暂不支持说话人分离。请确认所选引擎支持 SpeakerDiarization，并检查账号是否已开通相关能力。'
          : 'Tencent speaker diarization is unavailable for the current account, engine, or billing quota. Verify that the selected engine supports SpeakerDiarization and that the capability is enabled.';
    case 'aliyun_speaker_diarization_unavailable':
      return zh
          ? '阿里云当前未配置 Tingwu 说话人分离所需凭证。请补充 AppKey、AccessKey ID、AccessKey Secret 后再试。'
          : 'Aliyun speaker diarization requires Tingwu credentials. Configure AppKey, AccessKey ID, and AccessKey Secret, then retry.';
    case 'deepgram_empty_transcript':
      return zh
          ? 'Deepgram 已处理音频，但没有返回转写内容。请检查录音语言是否选对，或尝试其他 ASR。'
          : 'Deepgram processed the audio but returned an empty transcript. Check the selected language or try another ASR vendor.';
    default:
      return null;
  }
}

String? _messageForBizCode(AppLocalizations l10n, int code) {
  switch (code) {
    // ---- General (self-hosted 1xxx + SenseCraft 10xxx) ----------------
    case ServerErrorCodes.timeout:
      return l10n.errorTimeout;
    case ServerErrorCodes.notImplemented:
      return l10n.errorNotImplemented;
    case ServerErrorCodes.internalError:
    case SenseCraftErrorCodes.serviceError:
      return l10n.errorInternalError;
    case ServerErrorCodes.busySystem:
      return l10n.errorBusySystem;
    case SenseCraftErrorCodes.remoteCalledError:
      return l10n.errorRemoteCalled;
    case SenseCraftErrorCodes.pathNotFound:
      return l10n.errorPathNotFound;
    case SenseCraftErrorCodes.missingParams:
      return l10n.errorMissingParams;
    case ServerErrorCodes.badRequest:
    case ServerErrorCodes.invalidParams:
    case ServerErrorCodes.notAcceptable:
    case SenseCraftErrorCodes.paramInvalid:
      return l10n.errorInvalidParams;

    // ---- User / auth (self-hosted 2xxx) -------------------------------
    case ServerErrorCodes.userNotFound:
      return l10n.errorUserNotFound;
    case ServerErrorCodes.unauthorized:
      return l10n.errorUnauthorized;
    case ServerErrorCodes.rbacNoUserId:
      return l10n.errorUnauthorized;
    case ServerErrorCodes.forbidden:
    case ServerErrorCodes.rbacNoPermission:
    case SenseCraftErrorCodes.noPermission:
      return l10n.errorForbidden;
    case ServerErrorCodes.passwordIncorrect:
    case SenseCraftErrorCodes.passwordIncorrect:
      return l10n.errorPasswordIncorrect;
    case ServerErrorCodes.userAlreadyExists:
      return l10n.errorUserAlreadyExists;
    case ServerErrorCodes.duplicatedPassword:
      return l10n.errorPasswordIncorrect;
    case SenseCraftErrorCodes.newPasswordSameAsOld:
      return l10n.errorNewPasswordSameAsOld;
    case ServerErrorCodes.tokenExpired:
    case SenseCraftErrorCodes.refreshTokenExpired:
      return l10n.errorTokenExpired;
    case ServerErrorCodes.tokenInvalid:
    case SenseCraftErrorCodes.refreshTokenInvalid:
    case SenseCraftErrorCodes.tokenInvalid:
      return l10n.errorTokenInvalid;
    case ServerErrorCodes.emailAlreadyRegistered:
    case SenseCraftErrorCodes.emailAlreadyUsed:
      return l10n.errorEmailAlreadyRegistered;
    case SenseCraftErrorCodes.mobileAlreadyUsed:
      return l10n.errorMobileAlreadyRegistered;
    case ServerErrorCodes.emailNotVerified:
      return l10n.errorEmailNotVerified;
    case ServerErrorCodes.verifyCodeInvalid:
    case SenseCraftErrorCodes.verifyCodeInvalid:
    case SenseCraftErrorCodes.smsCodeInvalid:
      return l10n.errorVerifyCodeInvalid;
    case SenseCraftErrorCodes.verifyCodeExpired:
    case SenseCraftErrorCodes.smsCodeExpired:
      return l10n.errorVerifyCodeExpired;
    case SenseCraftErrorCodes.smsCodeAlreadySent:
      return l10n.errorSmsCodeAlreadySent;
    case SenseCraftErrorCodes.mobileRequired:
      return l10n.errorMobileRequired;
    case SenseCraftErrorCodes.mobileFormatInvalid:
      return l10n.errorMobileFormatInvalid;

    // ---- SenseCraft account (110xx) -----------------------------------
    case SenseCraftErrorCodes.accountNotFound:
      return l10n.errorAccountNotFound;
    case SenseCraftErrorCodes.accountFrozen:
      return l10n.errorAccountFrozen;
    case SenseCraftErrorCodes.tooManyLoginAttempts:
      return l10n.errorTooManyLoginAttempts;
    case SenseCraftErrorCodes.ossUploadNotConfigured:
      return l10n.errorOssUploadNotConfigured;
    case SenseCraftErrorCodes.ossPresignFailed:
      return l10n.errorOssPresignFailed;

    // ---- SenseCraft OAuth / terms (17xxx) -----------------------------
    case SenseCraftErrorCodes.authorizeCodeInvalid:
      return l10n.errorAuthorizeCodeInvalid;
    case SenseCraftErrorCodes.oauthUserInfoFailed:
      return l10n.errorOauthFailed;
    case SenseCraftErrorCodes.unsupportedOAuthProvider:
      return l10n.errorUnsupportedOAuthProvider;
    case SenseCraftErrorCodes.userInfoError:
      return l10n.errorUserInfoError;
    case SenseCraftErrorCodes.verifyCodeNotExpired:
      return l10n.errorVerifyCodeNotExpired;
    case SenseCraftErrorCodes.oauthStateMismatch:
      return l10n.errorOauthStateMismatch;
    case SenseCraftErrorCodes.oauthCodeMissing:
      return l10n.errorOauthCodeMissing;
    case SenseCraftErrorCodes.oauthStateMissing:
      return l10n.errorOauthStateMissing;
    case SenseCraftErrorCodes.oauthAccountNeedBind:
      return l10n.errorOauthAccountNeedBind;
    case SenseCraftErrorCodes.childAccountCannotDelete:
      return l10n.errorChildAccountCannotDelete;
    case SenseCraftErrorCodes.termsAcceptanceRequired:
      return l10n.errorTermsAcceptanceRequired;
    case SenseCraftErrorCodes.oauthForeignIdTaken:
      return l10n.errorOauthForeignIdTaken;
    case SenseCraftErrorCodes.oauthOrgAlreadyBound:
      return l10n.errorOauthOrgAlreadyBound;
    case SenseCraftErrorCodes.oauthWechatNoUnionid:
      return l10n.errorOauthWechatNoUnionid;

    // ---- Database (6xxx) ----------------------------------------------
    case ServerErrorCodes.recordNotFound:
    case ServerErrorCodes.dataNotFound:
      return l10n.errorRecordNotFound;
    case ServerErrorCodes.recordNotUpdate:
      return l10n.errorRecordNotUpdate;
    case ServerErrorCodes.duplicateRecord:
      return l10n.errorDuplicateRecord;

    // ---- External / account (business 11xxx) --------------------------
    case ServerErrorCodes.clusterNotFound:
      return l10n.errorClusterNotFound;
    case ServerErrorCodes.tenantNotFound:
      return l10n.errorTenantNotFound;
    // 11002: see ServerErrorCodes.tenantExist — same code as SenseCraft accountNotFound.

    // ---- Audit (12xxx) ----------------------------------------------
    case ServerErrorCodes.auditNotFound:
      return l10n.errorAuditNotFound;
    case ServerErrorCodes.auditExists:
      return l10n.errorAuditExists;

    // ---- RBAC (13xxx) -----------------------------------------------
    case ServerErrorCodes.rbacPolicyExists:
      return l10n.errorRbacPolicyExists;
    case ServerErrorCodes.rbacPolicyNotFound:
      return l10n.errorRbacPolicyNotFound;
    case ServerErrorCodes.rbacRoleExists:
      return l10n.errorRbacRoleExists;
    case ServerErrorCodes.rbacRoleNotFound:
      return l10n.errorRbacRoleNotFound;

    // ---- ASR / LLM (14xxx, 15xxx) -------------------------------------
    case ServerErrorCodes.asrVendorNotConfigured:
      return l10n.errorAsrVendorNotConfigured;
    case ServerErrorCodes.asrUnsupportedFormat:
      return l10n.errorAsrUnsupportedFormat;
    case ServerErrorCodes.asrConfigAlreadyExists:
      return l10n.errorAsrConfigAlreadyExists;
    case ServerErrorCodes.asrConfigNotFound:
      return l10n.errorAsrConfigNotFound;
    case ServerErrorCodes.asrVendorNotFound:
      return l10n.errorAsrVendorNotFound;
    case ServerErrorCodes.asrResultNotFound:
      return l10n.errorAsrResultNotFound;
    case ServerErrorCodes.asrJobNotFound:
      return l10n.errorAsrJobNotFound;
    case ServerErrorCodes.llmVendorNotConfigured:
      return l10n.errorLlmVendorNotConfigured;
    case ServerErrorCodes.promptTemplateNotFound:
      return l10n.errorPromptTemplateNotFound;
    case ServerErrorCodes.llmConfigAlreadyExists:
      return l10n.errorLlmConfigAlreadyExists;
    case ServerErrorCodes.llmConfigNotFound:
      return l10n.errorLlmConfigNotFound;
    case ServerErrorCodes.promptAlreadyImported:
      return l10n.errorPromptAlreadyImported;
    case ServerErrorCodes.promptTemplateUnsupportedChars:
      return l10n.promptTemplateUnsupportedChars;

    default:
      return null;
  }
}
