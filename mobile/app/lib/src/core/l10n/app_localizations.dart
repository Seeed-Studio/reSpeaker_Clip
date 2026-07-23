import 'package:flutter/material.dart';

class AppLocalizations {
  final Locale locale;

  AppLocalizations(this.locale);

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  // Auth - Login Landing
  String get loginLandingTitle =>
      _localizedValues[locale.languageCode]?['loginLandingTitle'] ?? 'Login';
  String get externalIdentity =>
      _localizedValues[locale.languageCode]?['externalIdentity'] ??
      'EXTERNAL IDENTITY';
  String get continueWithApple =>
      _localizedValues[locale.languageCode]?['continueWithApple'] ??
      'Continue with Apple';
  String get continueWithGoogle =>
      _localizedValues[locale.languageCode]?['continueWithGoogle'] ??
      'Continue with Google';
  String get continueWithGithub =>
      _localizedValues[locale.languageCode]?['continueWithGithub'] ??
      'Continue with Github';
  String get emailLogin =>
      _localizedValues[locale.languageCode]?['emailLogin'] ?? 'Email Login';
  String get passwordLogin =>
      _localizedValues[locale.languageCode]?['passwordLogin'] ??
      'Password Login';
  String get loginWithPassword =>
      _localizedValues[locale.languageCode]?['loginWithPassword'] ??
      'Login with Password';
  String get loginWithEmailCode =>
      _localizedValues[locale.languageCode]?['loginWithEmailCode'] ??
      'Login with Email Code';
  String get terminalSessionProtected =>
      _localizedValues[locale.languageCode]?['terminalSessionProtected'] ??
      'This terminal session is protected by';
  String get technicalStandards =>
      _localizedValues[locale.languageCode]?['technicalStandards'] ??
      'Technical Standards';
  String get safetyProtocols =>
      _localizedValues[locale.languageCode]?['safetyProtocols'] ??
      'Safety Protocols';

  // Auth - Email Login
  String get identityVerification =>
      _localizedValues[locale.languageCode]?['identityVerification'] ??
      'IDENTITY VERIFICATION';
  String get emailLoginTitle =>
      _localizedValues[locale.languageCode]?['emailLoginTitle'] ??
      'Email Login';
  String get emailLoginDescription =>
      _localizedValues[locale.languageCode]?['emailLoginDescription'] ??
      '输入邮箱获取验证码登录。若邮箱未注册，将自动注册并关联。';
  String get email =>
      _localizedValues[locale.languageCode]?['email'] ?? 'EMAIL';
  String get emailHint =>
      _localizedValues[locale.languageCode]?['emailHint'] ?? 'you@example.com';
  String get emailExample =>
      _localizedValues[locale.languageCode]?['emailExample'] ??
      'name@example.com';
  String get verificationCode =>
      _localizedValues[locale.languageCode]?['verificationCode'] ??
      'Verification Code';
  String get verificationCodeHint =>
      _localizedValues[locale.languageCode]?['verificationCodeHint'] ??
      'Enter code';
  String get getCode =>
      _localizedValues[locale.languageCode]?['getCode'] ?? 'Get Code';
  String get resendIn =>
      _localizedValues[locale.languageCode]?['resendIn'] ?? 'Resend in';
  String get seconds =>
      _localizedValues[locale.languageCode]?['seconds'] ?? 's';
  String get emailNotRegisteredHint =>
      _localizedValues[locale.languageCode]?['emailNotRegisteredHint'] ??
      'If this email is not registered, an account will be automatically created.';
  String get agreeToTerms =>
      _localizedValues[locale.languageCode]?['agreeToTerms'] ??
      'I have read and agree to the';
  String get agreeToTermsRequired =>
      _localizedValues[locale.languageCode]?['agreeToTermsRequired'] ??
      'Please read and agree to the User Agreement and Privacy Policy first.';
  String get privacyConsentTitle =>
      _localizedValues[locale.languageCode]?['privacyConsentTitle'] ??
      'Privacy Policy';
  String get privacyConsentBodyPrefix =>
      _localizedValues[locale.languageCode]?['privacyConsentBodyPrefix'] ??
      'Welcome to SenseCraft Voice. Please carefully read the ';
  String get privacyConsentBodySuffix =>
      _localizedValues[locale.languageCode]?['privacyConsentBodySuffix'] ??
      '. Tap Agree to continue. If you do not agree, tap Refuse to exit the app.';
  String get privacyConsentAgree =>
      _localizedValues[locale.languageCode]?['privacyConsentAgree'] ?? 'Agree';
  String get privacyConsentRefuse =>
      _localizedValues[locale.languageCode]?['privacyConsentRefuse'] ??
      'Refuse';
  String get loginOptions =>
      _localizedValues[locale.languageCode]?['loginOptions'] ?? 'Login';
  String get thirdPartyLogin =>
      _localizedValues[locale.languageCode]?['thirdPartyLogin'] ??
      'Third-party login';
  String get errorOAuthDisplayNameDbCharset =>
      _localizedValues[locale.languageCode]
          ?['errorOAuthDisplayNameDbCharset'] ??
      'Your account display name contains unsupported characters (such as emoji). '
          'Change the name in your Apple/Google account settings, or sign in with email.';
  String get userAgreement =>
      _localizedValues[locale.languageCode]?['userAgreement'] ??
      'User Agreement';
  String get and => _localizedValues[locale.languageCode]?['and'] ?? 'and';
  String get privacyPolicy =>
      _localizedValues[locale.languageCode]?['privacyPolicy'] ??
      'Privacy Policy';
  String get orWithEmail =>
      _localizedValues[locale.languageCode]?['orWithEmail'] ?? 'Or with email';
  String get agreePrefixLanding =>
      _localizedValues[locale.languageCode]?['agreePrefixLanding'] ??
      'By clicking on the "Continue" buttons below, you agree to the';
  String get serverEnvLabel =>
      _localizedValues[locale.languageCode]?['serverEnvLabel'] ?? 'Server';
  String get serverEnvRelease =>
      _localizedValues[locale.languageCode]?['serverEnvRelease'] ?? 'Release';
  String get serverEnvTest =>
      _localizedValues[locale.languageCode]?['serverEnvTest'] ?? 'Test';
  String get serverEnvDev =>
      _localizedValues[locale.languageCode]?['serverEnvDev'] ?? 'Dev';
  String get signIn =>
      _localizedValues[locale.languageCode]?['signIn'] ?? 'Sign In';
  String get signingIn =>
      _localizedValues[locale.languageCode]?['signingIn'] ?? 'Signing In...';
  String get fillEmailCodeAndAgree =>
      _localizedValues[locale.languageCode]?['fillEmailCodeAndAgree'] ??
      '请填写邮箱/验证码并同意协议';
  String get continueAction =>
      _localizedValues[locale.languageCode]?['continueAction'] ?? 'Continue';
  String get continueLoading =>
      _localizedValues[locale.languageCode]?['continueLoading'] ??
      'Continue...';
  String get invalidCode6 =>
      _localizedValues[locale.languageCode]?['invalidCode6'] ?? '请输入 6 位验证码';

  // Auth - Password Login
  String get passwordLoginTitle =>
      _localizedValues[locale.languageCode]?['passwordLoginTitle'] ??
      'Password Login';
  String get passwordLoginDescription =>
      _localizedValues[locale.languageCode]?['passwordLoginDescription'] ??
      '使用邮箱和密码登录您的账户。';
  String get password =>
      _localizedValues[locale.languageCode]?['password'] ?? 'PASSWORD';
  String get passwordHint =>
      _localizedValues[locale.languageCode]?['passwordHint'] ??
      'Enter password';
  String get emailOrPasswordEmpty =>
      _localizedValues[locale.languageCode]?['emailOrPasswordEmpty'] ??
      '请输入邮箱和密码';
  String get invalidEmail =>
      _localizedValues[locale.languageCode]?['invalidEmail'] ?? '请输入正确的邮箱地址';
  String get forgotPasswordLink =>
      _localizedValues[locale.languageCode]?['forgotPasswordLink'] ??
      'Forgot Password?';

  // Auth - Link Identity
  String get authenticatedVia =>
      _localizedValues[locale.languageCode]?['authenticatedVia'] ??
      'AUTHENTICATED VIA';
  String get linkYourIdentity =>
      _localizedValues[locale.languageCode]?['linkYourIdentity'] ??
      'Link Your Identity';
  String get linkIdentityDescription =>
      _localizedValues[locale.languageCode]?['linkIdentityDescription'] ??
      'To sync your data, please provide an email address.';
  String get verifyAndContinue =>
      _localizedValues[locale.languageCode]?['verifyAndContinue'] ??
      'Verify & Continue';
  String get dataPrivacy =>
      _localizedValues[locale.languageCode]?['dataPrivacy'] ?? 'DATA PRIVACY';
  String get dataPrivacyDescription =>
      _localizedValues[locale.languageCode]?['dataPrivacyDescription'] ??
      'Your email will be used to synchronize engineering configurations across your reTerminal devices via an encrypted secure tunnel.';
  String get enterValidEmail =>
      _localizedValues[locale.languageCode]?['enterValidEmail'] ?? '请输入正确邮箱';

  // Auth - Set Password
  String get setPassword =>
      _localizedValues[locale.languageCode]?['setPassword'] ?? 'Set Password';
  String get setPasswordDescription =>
      _localizedValues[locale.languageCode]?['setPasswordDescription'] ??
      '登录成功后建议设置密码，便于后续使用"密码登录"。此步骤可跳过。';
  String get confirm =>
      _localizedValues[locale.languageCode]?['confirm'] ?? 'Confirm';
  String get passwordHintSet =>
      _localizedValues[locale.languageCode]?['passwordHintSet'] ??
      '8-16位，必须包含字母和数字';
  String get confirmPasswordHint =>
      _localizedValues[locale.languageCode]?['confirmPasswordHint'] ?? '再次输入密码';
  String get passwordRule =>
      _localizedValues[locale.languageCode]?['passwordRule'] ??
      '规则：8-16 位，必须同时包含字母和数字。';
  String get passwordInvalid =>
      _localizedValues[locale.languageCode]?['passwordInvalid'] ?? '密码不符合规则';
  String get passwordMismatch =>
      _localizedValues[locale.languageCode]?['passwordMismatch'] ??
      '两次输入的密码不一致';
  String get saving =>
      _localizedValues[locale.languageCode]?['saving'] ?? 'Saving...';
  String get skip => _localizedValues[locale.languageCode]?['skip'] ?? 'Skip';
  String get secureYourAccount =>
      _localizedValues[locale.languageCode]?['secureYourAccount'] ??
      'Secure Your Account';
  String get setPasswordForFuture =>
      _localizedValues[locale.languageCode]?['setPasswordForFuture'] ??
      'Set a password for future logins';
  String get skipForNow =>
      _localizedValues[locale.languageCode]?['skipForNow'] ?? 'Skip for Now';
  String get resetPasswordMissingCode =>
      _localizedValues[locale.languageCode]?['resetPasswordMissingCode'] ??
      '重置密码失败：缺少验证码';
  String get registerMissingVerificationCode =>
      _localizedValues[locale.languageCode]
          ?['registerMissingVerificationCode'] ??
      'Registration failed: missing email verification code. Go back and enter the code from your inbox.';
  String get resetPasswordSuccess =>
      _localizedValues[locale.languageCode]?['resetPasswordSuccess'] ??
      '密码已重置，请重新登录';
  String get registerCompleteSignInWithEmailCode =>
      _localizedValues[locale.languageCode]
          ?['registerCompleteSignInWithEmailCode'] ??
      'Account created. Go back to sign in and tap Continue to send a login verification code to your email.';
  String get forgotPasswordTitle =>
      _localizedValues[locale.languageCode]?['forgotPasswordTitle'] ??
      'Forgot Password';
  String get forgotPasswordDesc =>
      _localizedValues[locale.languageCode]?['forgotPasswordDesc'] ??
      'Enter your email to receive a verification code';
  String get enterVerificationCodeTitle =>
      _localizedValues[locale.languageCode]?['enterVerificationCodeTitle'] ??
      'Enter verification code';
  String get enterVerificationCodeDesc =>
      _localizedValues[locale.languageCode]?['enterVerificationCodeDesc'] ??
      'Enter the 6-digit code sent to your email';

  // Common
  String get universalAccess =>
      _localizedValues[locale.languageCode]?['universalAccess'] ??
      'UNIVERSAL ACCESS';
  String get passwordLoginSubtitle =>
      _localizedValues[locale.languageCode]?['passwordLoginSubtitle'] ??
      'PASSWORD LOGIN';
  String get passwordLoginNotImplemented =>
      _localizedValues[locale.languageCode]?['passwordLoginNotImplemented'] ??
      '密码登录功能待实现';

  // Settings - Common
  String get save => _localizedValues[locale.languageCode]?['save'] ?? 'Save';
  String get saving2 =>
      _localizedValues[locale.languageCode]?['saving2'] ?? 'Saving...';
  String get cancel =>
      _localizedValues[locale.languageCode]?['cancel'] ?? 'Cancel';
  String get delete =>
      _localizedValues[locale.languageCode]?['delete'] ?? 'Delete';
  String get clear =>
      _localizedValues[locale.languageCode]?['clear'] ?? 'Clear';
  String get enabled =>
      _localizedValues[locale.languageCode]?['enabled'] ?? 'Enabled';
  String get notEnabled =>
      _localizedValues[locale.languageCode]?['notEnabled'] ?? 'Not enabled';
  String get latest =>
      _localizedValues[locale.languageCode]?['latest'] ?? 'LATEST';
  String get languageEnglish =>
      _localizedValues[locale.languageCode]?['languageEnglish'] ?? 'English';
  String get languageChinese =>
      _localizedValues[locale.languageCode]?['languageChinese'] ?? '简体中文';

  // Settings - SettingsPage
  String get settings =>
      _localizedValues[locale.languageCode]?['settings'] ?? 'Settings';
  String get security =>
      _localizedValues[locale.languageCode]?['security'] ?? 'Security';
  String get community =>
      _localizedValues[locale.languageCode]?['community'] ?? 'Community';
  String get about =>
      _localizedValues[locale.languageCode]?['about'] ?? 'About';
  String get permissions =>
      _localizedValues[locale.languageCode]?['permissions'] ?? 'Permissions';
  String get language =>
      _localizedValues[locale.languageCode]?['language'] ?? 'Language';
  String get passwordItem =>
      _localizedValues[locale.languageCode]?['passwordItem'] ?? 'Password';
  String get deleteAccount =>
      _localizedValues[locale.languageCode]?['deleteAccount'] ??
      'Delete Account';
  String get followUs =>
      _localizedValues[locale.languageCode]?['followUs'] ?? 'Follow Us';
  String get followUsTwitter =>
      _localizedValues[locale.languageCode]?['followUsTwitter'] ??
      'X (Twitter)';
  String get followUsLinkedIn =>
      _localizedValues[locale.languageCode]?['followUsLinkedIn'] ?? 'LinkedIn';
  String get followUsDiscord =>
      _localizedValues[locale.languageCode]?['followUsDiscord'] ?? 'Discord';
  String get followUsFacebook =>
      _localizedValues[locale.languageCode]?['followUsFacebook'] ?? 'Facebook';
  String get helpFeedback =>
      _localizedValues[locale.languageCode]?['helpFeedback'] ??
      'Help & Feedback';
  String get appVersion =>
      _localizedValues[locale.languageCode]?['appVersion'] ?? 'App Version';
  String get clearCache =>
      _localizedValues[locale.languageCode]?['clearCache'] ?? 'Clear Cache';
  String get cacheCleared =>
      _localizedValues[locale.languageCode]?['cacheCleared'] ??
      'Cache cleared. Synced recordings in the app are not deleted.';
  String get clearCacheFailed =>
      _localizedValues[locale.languageCode]?['clearCacheFailed'] ??
      'Failed to clear cache';
  String get policies =>
      _localizedValues[locale.languageCode]?['policies'] ?? 'Policies';
  String get logOut =>
      _localizedValues[locale.languageCode]?['logOut'] ?? 'Log Out';
  String get pushNotifications =>
      _localizedValues[locale.languageCode]?['pushNotifications'] ??
      'Push Notifications';

  // Settings - Personal Information
  String get personalInformation =>
      _localizedValues[locale.languageCode]?['personalInformation'] ??
      'Personal Information';
  String get profileUpdated =>
      _localizedValues[locale.languageCode]?['profileUpdated'] ?? '资料已更新';
  String get tapToChangeProfilePhoto =>
      _localizedValues[locale.languageCode]?['tapToChangeProfilePhoto'] ??
      'Tap to change profile photo';
  String get nickname =>
      _localizedValues[locale.languageCode]?['nickname'] ?? 'Nickname';
  String get boundEmail =>
      _localizedValues[locale.languageCode]?['boundEmail'] ?? 'Bound Email';
  String get connectedAccounts =>
      _localizedValues[locale.languageCode]?['connectedAccounts'] ??
      'Connected Accounts';
  String get senseCraftAccount =>
      _localizedValues[locale.languageCode]?['senseCraftAccount'] ??
      'SenseCraft account';
  String get connected =>
      _localizedValues[locale.languageCode]?['connected'] ?? 'Connected';
  String get notConnected =>
      _localizedValues[locale.languageCode]?['notConnected'] ?? 'Not Connected';

  // Settings - Change Email
  String get changeEmail =>
      _localizedValues[locale.languageCode]?['changeEmail'] ?? 'Change Email';
  String get emailAddress =>
      _localizedValues[locale.languageCode]?['emailAddress'] ?? 'Email address';
  String get emailAddressDesc =>
      _localizedValues[locale.languageCode]?['emailAddressDesc'] ??
      'We will use this email for account login and notifications.';
  String get sendCode =>
      _localizedValues[locale.languageCode]?['sendCode'] ?? 'Send Code';
  String get sendCodeLoading =>
      _localizedValues[locale.languageCode]?['sendCodeLoading'] ??
      'Send Code...';
  String resendInSeconds(int seconds) =>
      (_localizedValues[locale.languageCode]?['resendInSeconds'] ??
              'Resend in {s}s')
          .replaceAll('{s}', seconds.toString());
  String get emailChangedSuccess =>
      _localizedValues[locale.languageCode]?['emailChangedSuccess'] ?? '邮箱已修改';

  // Settings - Change Password
  String get changePassword =>
      _localizedValues[locale.languageCode]?['changePassword'] ??
      'Change Password';
  String get oldPassword =>
      _localizedValues[locale.languageCode]?['oldPassword'] ?? 'OLD PASSWORD';
  String get oldPasswordHint =>
      _localizedValues[locale.languageCode]?['oldPasswordHint'] ??
      'Old password';
  String get newPassword =>
      _localizedValues[locale.languageCode]?['newPassword'] ?? 'NEW PASSWORD';
  String get confirmNewPassword =>
      _localizedValues[locale.languageCode]?['confirmNewPassword'] ??
      'CONFIRM NEW PASSWORD';
  String get repeatNewPasswordHint =>
      _localizedValues[locale.languageCode]?['repeatNewPasswordHint'] ??
      'Repeat new password';
  String get updatePassword =>
      _localizedValues[locale.languageCode]?['updatePassword'] ??
      'Update Password';
  String get confirmPasswordLabel =>
      _localizedValues[locale.languageCode]?['confirmPasswordLabel'] ??
      'CONFIRM PASSWORD';
  String get repeatPasswordHint =>
      _localizedValues[locale.languageCode]?['repeatPasswordHint'] ??
      'Repeat password';
  String get passwordSetSuccess =>
      _localizedValues[locale.languageCode]?['passwordSetSuccess'] ??
      'Password set successfully';
  String get updating =>
      _localizedValues[locale.languageCode]?['updating'] ?? 'Updating...';
  String get passwordChangedSuccess =>
      _localizedValues[locale.languageCode]?['passwordChangedSuccess'] ??
      '密码修改成功';
  String get fillAllFields =>
      _localizedValues[locale.languageCode]?['fillAllFields'] ??
      'Please fill in all fields.';
  String get newPasswordSameAsOld =>
      _localizedValues[locale.languageCode]?['newPasswordSameAsOld'] ??
      'New password cannot be the same as the old password.';

  // Settings - Delete Account
  String get accountDeletion =>
      _localizedValues[locale.languageCode]?['accountDeletion'] ??
      'Account Deletion';
  String get accountDeletionDesc =>
      _localizedValues[locale.languageCode]?['accountDeletionDesc'] ??
      'This action is irreversible. All device data\nand web templates will be permanently\ndeleted.';
  String get confirmDeletion =>
      _localizedValues[locale.languageCode]?['confirmDeletion'] ??
      'Confirm Deletion';
  String get deleteAccountConfirmTitle =>
      _localizedValues[locale.languageCode]?['deleteAccountConfirmTitle'] ??
      'Delete Account';
  String get deleteAccountConfirmMessage =>
      _localizedValues[locale.languageCode]?['deleteAccountConfirmMessage'] ??
      'This action is irreversible. Continue?';

  // Settings - Help & Feedback
  String get helpCenter =>
      _localizedValues[locale.languageCode]?['helpCenter'] ?? 'Help Center';
  String get productWiki =>
      _localizedValues[locale.languageCode]?['productWiki'] ?? 'Product Wiki';
  String get contactUs =>
      _localizedValues[locale.languageCode]?['contactUs'] ?? 'Contact Us';
  String get feedback =>
      _localizedValues[locale.languageCode]?['feedback'] ?? 'Feedback';
  String get feedbackPrompt =>
      _localizedValues[locale.languageCode]?['feedbackPrompt'] ??
      'Have a feature request or found a bug? Let us know!';
  String get feedbackHint =>
      _localizedValues[locale.languageCode]?['feedbackHint'] ??
      'Share your suggestions...';
  String get submitSuggestion =>
      _localizedValues[locale.languageCode]?['submitSuggestion'] ??
      'Submit Suggestion';
  String get feedbackTypeLabel =>
      _localizedValues[locale.languageCode]?['feedbackTypeLabel'] ??
      'Feedback type';
  String get feedbackTypeBug =>
      _localizedValues[locale.languageCode]?['feedbackTypeBug'] ?? 'Bug';
  String get feedbackTypeEnhancement =>
      _localizedValues[locale.languageCode]?['feedbackTypeEnhancement'] ??
      'Enhancement';
  String get feedbackTypeFeature =>
      _localizedValues[locale.languageCode]?['feedbackTypeFeature'] ??
      'New feature';
  String get feedbackAddPhotos =>
      _localizedValues[locale.languageCode]?['feedbackAddPhotos'] ??
      'Add screenshots (optional)';
  String get feedbackPhotosLimit =>
      _localizedValues[locale.languageCode]?['feedbackPhotosLimit'] ??
      'Up to 3 images';
  String get feedbackDescriptionRequired =>
      _localizedValues[locale.languageCode]?['feedbackDescriptionRequired'] ??
      'Please describe your feedback';
  String get feedbackSubmitSuccess =>
      _localizedValues[locale.languageCode]?['feedbackSubmitSuccess'] ??
      'Thank you — your feedback was submitted.';
  String get feedbackSubmitFailed =>
      _localizedValues[locale.languageCode]?['feedbackSubmitFailed'] ??
      'Failed to submit feedback';
  String feedbackTypeLabelFor(String apiValue) => switch (apiValue) {
        '缺陷/Bug' => feedbackTypeBug,
        '功能优化  ' => feedbackTypeEnhancement,
        '新需求' => feedbackTypeFeature,
        _ => apiValue,
      };

  // Settings - Policies/About/Permissions
  String get privacyPolicy2 =>
      _localizedValues[locale.languageCode]?['privacyPolicy2'] ??
      'Privacy Policy';
  String get userAgreement2 =>
      _localizedValues[locale.languageCode]?['userAgreement2'] ??
      'User Agreement';
  String get openSourceLicenses =>
      _localizedValues[locale.languageCode]?['openSourceLicenses'] ??
      'Open Source Licenses';
  String get linkOpenFailed =>
      _localizedValues[locale.languageCode]?['linkOpenFailed'] ??
      'Could not open the link.';
  String get bluetooth =>
      _localizedValues[locale.languageCode]?['bluetooth'] ?? 'Bluetooth';
  String get microphone =>
      _localizedValues[locale.languageCode]?['microphone'] ?? 'Microphone';
  String get notifications =>
      _localizedValues[locale.languageCode]?['notifications'] ??
      'Notifications';
  String get checkForUpdates =>
      _localizedValues[locale.languageCode]?['checkForUpdates'] ??
      'Check for Updates';
  String get checkingForUpdates =>
      _localizedValues[locale.languageCode]?['checkingForUpdates'] ??
      'Checking for updates...';
  String get updateAvailableTitle =>
      _localizedValues[locale.languageCode]?['updateAvailableTitle'] ??
      'Update Available';
  String get updateNow =>
      _localizedValues[locale.languageCode]?['updateNow'] ?? 'Update Now';
  String get updateLater =>
      _localizedValues[locale.languageCode]?['updateLater'] ?? 'Later';
  String get noUpdateAvailable =>
      _localizedValues[locale.languageCode]?['noUpdateAvailable'] ??
      'You are already on the latest version.';
  String get updateCheckFailed =>
      _localizedValues[locale.languageCode]?['updateCheckFailed'] ??
      'Failed to check for updates.';
  String get updateServiceNotConfigured =>
      _localizedValues[locale.languageCode]?['updateServiceNotConfigured'] ??
      'Update service is not configured.';
  String versionLabel(String v) =>
      (_localizedValues[locale.languageCode]?['versionLabel'] ?? 'Version {v}')
          .replaceAll('{v}', v);
  String cacheUsedLabel(String v) =>
      (_localizedValues[locale.languageCode]?['cacheUsedLabel'] ?? '{v} used')
          .replaceAll('{v}', v);
  String get aboutCopyright =>
      _localizedValues[locale.languageCode]?['aboutCopyright'] ??
      '© 2026 Seeed Technology Inc. ALL RIGHTS RESERVED.';
  String get helpCopyright =>
      _localizedValues[locale.languageCode]?['helpCopyright'] ??
      '© 2026 Seeed Technology Inc. All rights reserved.';

  // Recordings / Home
  String get recordingsLoadFailed =>
      _localizedValues[locale.languageCode]?['recordingsLoadFailed'] ?? '加载失败';
  String get recordingsListEndHint =>
      _localizedValues[locale.languageCode]?['recordingsListEndHint'] ??
      'No more files';
  String get recordingsLoadingMoreFooter =>
      _localizedValues[locale.languageCode]?['recordingsLoadingMoreFooter'] ??
      'Loading more…';
  String selectedCount(int n) =>
      (_localizedValues[locale.languageCode]?['selectedCount'] ??
              'Selected ({n})')
          .replaceAll('{n}', '$n');
  String get done => _localizedValues[locale.languageCode]?['done'] ?? 'Done';
  String get searchRecordings =>
      _localizedValues[locale.languageCode]?['searchRecordings'] ??
      'Search recordings';
  String get noRecordingsYet =>
      _localizedValues[locale.languageCode]?['noRecordingsYet'] ??
      'No recordings yet';
  String get noResults =>
      _localizedValues[locale.languageCode]?['noResults'] ?? 'No Results';
  String get importDemoData =>
      _localizedValues[locale.languageCode]?['importDemoData'] ?? '导入演示数据';
  String get filterSort =>
      _localizedValues[locale.languageCode]?['filterSort'] ?? 'Filter & Sort';
  String get allFiles =>
      _localizedValues[locale.languageCode]?['allFiles'] ?? 'All Files';
  String get all => _localizedValues[locale.languageCode]?['all'] ?? 'All';
  String get downloaded =>
      _localizedValues[locale.languageCode]?['downloaded'] ?? 'Downloaded';
  String get unclassified =>
      _localizedValues[locale.languageCode]?['unclassified'] ?? 'Unclassified';
  String get folder =>
      _localizedValues[locale.languageCode]?['folder'] ?? 'Folder';
  String get recycleBin =>
      _localizedValues[locale.languageCode]?['recycleBin'] ?? 'Recycle Bin';
  String get folders =>
      _localizedValues[locale.languageCode]?['folders'] ?? 'Folders';
  String get deviceSourcePlaceholder =>
      _localizedValues[locale.languageCode]?['deviceSourcePlaceholder'] ??
      'Note Pro  (2)';
  String get from => _localizedValues[locale.languageCode]?['from'] ?? 'From';
  String get createTime =>
      _localizedValues[locale.languageCode]?['createTime'] ?? 'Created Time';
  String get operationTime =>
      _localizedValues[locale.languageCode]?['operationTime'] ??
      'Operation Time';
  String get moveToRecycleBin =>
      _localizedValues[locale.languageCode]?['moveToRecycleBin'] ??
      'Move to Recycle Bin';
  String get restoreFromRecycleBin =>
      _localizedValues[locale.languageCode]?['restoreFromRecycleBin'] ??
      'Restore';
  String moveToRecycleBinConfirm(int n) =>
      (_localizedValues[locale.languageCode]?['moveToRecycleBinConfirm'] ??
              'Move {n} files to Recycle Bin?')
          .replaceAll('{n}', '$n');
  String get move => _localizedValues[locale.languageCode]?['move'] ?? 'Move';
  String get moveTo =>
      _localizedValues[locale.languageCode]?['moveTo'] ?? 'Move to';
  String get rename =>
      _localizedValues[locale.languageCode]?['rename'] ?? 'Rename';
  String get generate =>
      _localizedValues[locale.languageCode]?['generate'] ?? 'Generate';
  String get deleteFolder =>
      _localizedValues[locale.languageCode]?['deleteFolder'] ?? 'Delete folder';
  String get renameFolder =>
      _localizedValues[locale.languageCode]?['renameFolder'] ?? 'Rename folder';
  String get deleteFolderMessage =>
      _localizedValues[locale.languageCode]?['deleteFolderMessage'] ??
      'This folder will be deleted and all files inside will be moved to "All Files". Continue?';
  String get generateAiSummary =>
      _localizedValues[locale.languageCode]?['generateAiSummary'] ??
      'Generate AI Summary';
  String get moveToFolder =>
      _localizedValues[locale.languageCode]?['moveToFolder'] ??
      'Move to Folder';
  String get syncing =>
      _localizedValues[locale.languageCode]?['syncing'] ?? 'Syncing';
  String syncingPercent(int percent) =>
      (_localizedValues[locale.languageCode]?['syncingPercent'] ??
              'Syncing {p}%')
          .replaceAll('{p}', '$percent');
  String get resync =>
      _localizedValues[locale.languageCode]?['resync'] ?? 'Resync';
  String get resyncStarted =>
      _localizedValues[locale.languageCode]?['resyncStarted'] ??
      'Resync started';
  String get connectDeviceToResync =>
      _localizedValues[locale.languageCode]?['connectDeviceToResync'] ??
      'Please connect device to resync';
  String get resyncBlockedWhileRecordingOtherSession =>
      _localizedValues[locale.languageCode]
          ?['resyncBlockedWhileRecordingOtherSession'] ??
      'The device is recording another session. Stop or finish that recording before resyncing this one.';
  String get resyncCouldNotStart =>
      _localizedValues[locale.languageCode]?['resyncCouldNotStart'] ??
      'Could not start sync right now. If you just started recording or Wi‑Fi fast sync is running, wait a moment and try again.';
  String get transferring =>
      _localizedValues[locale.languageCode]?['transferring'] ?? 'Transferring';
  String get transferBannerMinimizeTip =>
      _localizedValues[locale.languageCode]?['transferBannerMinimizeTip'] ??
      'Hide to edge';
  String get transferBannerRestoreTip =>
      _localizedValues[locale.languageCode]?['transferBannerRestoreTip'] ??
      'Tap to show transfer progress';
  String get fastSync =>
      _localizedValues[locale.languageCode]?['fastSync'] ?? 'Fast Sync';
  String transferSpeedLabel(String speed) =>
      (_localizedValues[locale.languageCode]?['transferSpeedLabel'] ??
              'Speed: {s}')
          .replaceAll('{s}', speed);
  String get fastSyncSheetTitle =>
      _localizedValues[locale.languageCode]?['fastSyncSheetTitle'] ??
      'Wi‑Fi fast sync';
  String get fastSyncCloseTurnOffWifi =>
      _localizedValues[locale.languageCode]?['fastSyncCloseTurnOffWifi'] ??
      'Close';
  String get fastSyncDismissHint =>
      _localizedValues[locale.languageCode]?['fastSyncDismissHint'] ??
      'This sheet closes on its own when transfer starts; progress shows on the home list. '
          'If you close manually (button, outside tap, or swipe down), the recorder hotspot turns off.';
  String get fastSyncStoppingBle =>
      _localizedValues[locale.languageCode]?['fastSyncStoppingBle'] ??
      'Stopping Bluetooth transfer…';
  String get fastSyncSwitchedNetworkTitle =>
      _localizedValues[locale.languageCode]?['fastSyncSwitchedNetworkTitle'] ??
      'Connected to a different Wi‑Fi';
  String get fastSyncSwitchedNetworkMessage =>
      _localizedValues[locale.languageCode]
          ?['fastSyncSwitchedNetworkMessage'] ??
      'Your phone keeps switching back to a saved Wi‑Fi instead of the recorder\u2019s '
          'network, so fast sync can\u2019t run. Open Wi‑Fi settings, tap your other '
          'saved networks and choose "Forget" (or turn off their auto‑join), then join '
          'the recorder\u2019s hotspot (the "ClipAP_" network). Once the saved networks '
          'are forgotten the phone stops switching away. Continuing over Bluetooth for now.';
  String get fastSyncOpenWifiSettings =>
      _localizedValues[locale.languageCode]?['fastSyncOpenWifiSettings'] ??
      'Open Settings';
  String get fastSyncWifiFallbackTitle =>
      _localizedValues[locale.languageCode]?['fastSyncWifiFallbackTitle'] ??
      'Wi‑Fi fast sync didn\u2019t complete';
  String get fastSyncWifiFallbackMessage =>
      _localizedValues[locale.languageCode]?['fastSyncWifiFallbackMessage'] ??
      'Fast sync over Wi‑Fi couldn\u2019t finish — your phone may be on a different '
          'Wi‑Fi, didn\u2019t join the recorder\u2019s hotspot, or the signal was '
          'too weak. Switched to Bluetooth to keep syncing. For faster transfers, '
          'open Wi‑Fi settings and join the device hotspot below, and turn off '
          'auto‑join (or forget) your usual Wi‑Fi so the phone stops switching away.';
  String get fastSyncWifiDisconnectedTitle =>
      _localizedValues[locale.languageCode]?['fastSyncWifiDisconnectedTitle'] ??
      'Wi‑Fi disconnected';
  String get fastSyncWifiDisconnectedMessage =>
      _localizedValues[locale.languageCode]
          ?['fastSyncWifiDisconnectedMessage'] ??
      'Your phone is not connected to the recorder\u2019s Wi‑Fi (Wi‑Fi may be off '
          'or you switched to another network). Continuing over Bluetooth to keep '
          'syncing — turn Wi‑Fi back on only if you want to try fast sync again later.';
  String get fastSyncWifiVerifyTimeoutTitle =>
      _localizedValues[locale.languageCode]
          ?['fastSyncWifiVerifyTimeoutTitle'] ??
      'Could not join device Wi‑Fi';
  String get fastSyncWifiVerifyTimeoutMessage =>
      _localizedValues[locale.languageCode]
          ?['fastSyncWifiVerifyTimeoutMessage'] ??
      'The recorder\u2019s hotspot is on, but the phone did not connect in time. '
          'Continuing over Bluetooth. To use fast sync next time, open Wi‑Fi settings, '
          'join the device hotspot below, and turn off auto‑join (or forget) your usual '
          'Wi‑Fi so the phone stops switching away.';
  String get fastSyncDeviceWifiNetworkLabel =>
      _localizedValues[locale.languageCode]
          ?['fastSyncDeviceWifiNetworkLabel'] ??
      'Device Wi‑Fi';
  String get fastSyncDeviceWifiPasswordLabel =>
      _localizedValues[locale.languageCode]
          ?['fastSyncDeviceWifiPasswordLabel'] ??
      'Password';
  String get fastSyncCopied =>
      _localizedValues[locale.languageCode]?['fastSyncCopied'] ?? 'Copied';
  String get fastSyncWifiFailedTitle =>
      _localizedValues[locale.languageCode]?['fastSyncWifiFailedTitle'] ??
      'Wi‑Fi sync didn\u2019t go through';
  String get fastSyncWifiFailedMessage =>
      _localizedValues[locale.languageCode]?['fastSyncWifiFailedMessage'] ??
      'Your phone joined the recorder\u2019s Wi‑Fi but the connection was too weak '
          'to transfer data. Continuing over Bluetooth. If this keeps happening, '
          'move closer to the device or reconnect to its Wi‑Fi and try again.';
  String get fastSyncCancelBleFailed =>
      _localizedValues[locale.languageCode]?['fastSyncCancelBleFailed'] ??
      'Could not stop Bluetooth transfer';
  String get fastSyncUnavailableWhileRecording =>
      _localizedValues[locale.languageCode]
          ?['fastSyncUnavailableWhileRecording'] ??
      'Fast Sync is not available while the device is recording. Stop recording first.';
  String get fastSyncStillRunningCannotRecord =>
      _localizedValues[locale.languageCode]
          ?['fastSyncStillRunningCannotRecord'] ??
      'Wi‑Fi sync is still stopping. Wait a moment, then try recording again.';
  String get fastSyncNoSession =>
      _localizedValues[locale.languageCode]?['fastSyncNoSession'] ??
      'Missing session id for this recording';
  String get fastSyncPreparing =>
      _localizedValues[locale.languageCode]?['fastSyncPreparing'] ??
      'Preparing…';
  String get fastSyncLaunchingWifi =>
      _localizedValues[locale.languageCode]?['fastSyncLaunchingWifi'] ??
      'Starting hotspot and Wi‑Fi sync…';
  String get fastSyncEnablingHotspot =>
      _localizedValues[locale.languageCode]?['fastSyncEnablingHotspot'] ??
      'Starting device hotspot…';
  String get fastSyncJoiningWifi =>
      _localizedValues[locale.languageCode]?['fastSyncJoiningWifi'] ??
      'Joining device Wi‑Fi…';
  String get fastSyncIosLocalNetworkTitle =>
      _localizedValues[locale.languageCode]?['fastSyncIosLocalNetworkTitle'] ??
      'Local network access';
  String get fastSyncIosLocalNetworkMessage =>
      _localizedValues[locale.languageCode]
          ?['fastSyncIosLocalNetworkMessage'] ??
      'Wi‑Fi fast sync reaches your recorder on the local network. When iOS asks, tap Allow for local network access. If you chose Don’t Allow before, turn it on under Settings → Privacy & Security → Local Network for this app.';
  String get fastSyncOpenAppSettings =>
      _localizedValues[locale.languageCode]?['fastSyncOpenAppSettings'] ??
      'Open Settings';
  String get fastSyncVerifyingUdp =>
      _localizedValues[locale.languageCode]?['fastSyncVerifyingUdp'] ??
      'Verifying connection…';
  String get fastSyncTransferring =>
      _localizedValues[locale.languageCode]?['fastSyncTransferring'] ??
      'Transferring over Wi‑Fi…';
  String get fastSyncMerging =>
      _localizedValues[locale.languageCode]?['fastSyncMerging'] ??
      'Merging files…';
  String get fastSyncRestoringWifi =>
      _localizedValues[locale.languageCode]?['fastSyncRestoringWifi'] ??
      'Restoring phone Wi‑Fi…';
  String get fastSyncDone =>
      _localizedValues[locale.languageCode]?['fastSyncDone'] ?? 'Done';
  String get fastSyncFailed =>
      _localizedValues[locale.languageCode]?['fastSyncFailed'] ??
      'Transfer failed';
  String get errWifiHandoff =>
      _localizedValues[locale.languageCode]?['errWifiHandoff'] ??
      'Switching to Wi‑Fi…';
  String get errWifiFastSyncUnreachable =>
      _localizedValues[locale.languageCode]?['errWifiFastSyncUnreachable'] ??
      'Wi‑Fi fast sync could not connect; use Bluetooth sync or try Fast Sync again after joining the device network in Settings.';
  String get errWifiFastSyncDisconnected =>
      _localizedValues[locale.languageCode]?['errWifiFastSyncDisconnected'] ??
      'Wi‑Fi is off or not on the device network. Continuing over Bluetooth.';
  String get errInvalidSessionId =>
      _localizedValues[locale.languageCode]?['errInvalidSessionId'] ??
      'Invalid session id for this recording (device list response). Pull to refresh the file list or reconnect.';

  String fastSyncBytesProgress(int received, int total) {
    String fmt(int bytes) {
      const k = 1024.0;
      if (bytes < k) return '${bytes}B';
      final kb = bytes / k;
      if (kb < k) return '${kb.toStringAsFixed(1)}KB';
      final mb = kb / k;
      if (mb < k) return '${mb.toStringAsFixed(1)}MB';
      final gb = mb / k;
      return '${gb.toStringAsFixed(1)}GB';
    }

    return (_localizedValues[locale.languageCode]?['fastSyncBytesProgress'] ??
            '{r} / {t}')
        .replaceAll('{r}', fmt(received))
        .replaceAll('{t}', fmt(total));
  }

  String get syncAll =>
      _localizedValues[locale.languageCode]?['syncAll'] ?? 'Sync All';
  String syncAllResult(int count) =>
      (_localizedValues[locale.languageCode]?['syncAllResult'] ??
              'Synced {n} session(s)')
          .replaceAll('{n}', '$count');
  String get syncComplete =>
      _localizedValues[locale.languageCode]?['syncComplete'] ?? 'Sync complete';
  String get syncFailed =>
      _localizedValues[locale.languageCode]?['syncFailed'] ?? 'Sync failed';
  // Transfer/connection error codes (device_controller i18n)
  String get errDeviceDisconnectedResume =>
      _localizedValues[locale.languageCode]?['errDeviceDisconnectedResume'] ??
      'Device disconnected. Will resume after reconnecting.';
  String get errCreateLocalDirFailed =>
      _localizedValues[locale.languageCode]?['errCreateLocalDirFailed'] ??
      'Failed to create local directory.';
  String get errTransferIncompleteSize =>
      _localizedValues[locale.languageCode]?['errTransferIncompleteSize'] ??
      'Transfer incomplete (size too small). Will re-download.';
  String get errLocalFileDeleted =>
      _localizedValues[locale.languageCode]?['errLocalFileDeleted'] ??
      'Local file deleted. Will re-download.';
  String get errLocalFileIncomplete =>
      _localizedValues[locale.languageCode]?['errLocalFileIncomplete'] ??
      'Local file incomplete. Will re-download.';
  String get errDeviceSessionMissing =>
      _localizedValues[locale.languageCode]?['errDeviceSessionMissing'] ??
      'Recording no longer on device.';
  String get errDeviceSessionMissingCannotResume =>
      _localizedValues[locale.languageCode]
          ?['errDeviceSessionMissingCannotResume'] ??
      'Recording no longer on device. Cannot resume.';
  String get errTransferIncompleteResume =>
      _localizedValues[locale.languageCode]?['errTransferIncompleteResume'] ??
      'Transfer incomplete. Will resume after reconnecting.';
  String get errNoValidAudio =>
      _localizedValues[locale.languageCode]?['errNoValidAudio'] ??
      'No valid audio data received.';
  String get errUserCancelled =>
      _localizedValues[locale.languageCode]?['errUserCancelled'] ??
      'Cancelled.';
  String get errDeviceRecordingResumeLater =>
      _localizedValues[locale.languageCode]?['errDeviceRecordingResumeLater'] ??
      'Device is recording. Transfer will resume when recording ends.';
  String get errDeviceDisconnectedResumeAfterReconnect =>
      _localizedValues[locale.languageCode]
          ?['errDeviceDisconnectedResumeAfterReconnect'] ??
      'Device disconnected. Will resume after reconnecting.';
  String get errStalledNoData3Min =>
      _localizedValues[locale.languageCode]?['errStalledNoData3Min'] ??
      'No data for 3 minutes. Transfer paused — tap resync to continue.';
  String get errMergedFileIncomplete =>
      _localizedValues[locale.languageCode]?['errMergedFileIncomplete'] ??
      'Merge failed: the merged file is incomplete (some slices were missing). Try syncing again.';
  String get errMergeFailed =>
      _localizedValues[locale.languageCode]?['errMergeFailed'] ??
      'Merge failed. Tap sync to retry.';
  String get errIosPeerRemovedPairingInfo =>
      _localizedValues[locale.languageCode]?['errIosPeerRemovedPairingInfo'] ??
      errIosStaleBluetoothPairing;
  String get errIosStaleBluetoothPairing =>
      _localizedValues[locale.languageCode]?['errIosStaleBluetoothPairing'] ??
      'Connection failed: the Bluetooth pairing keys on this phone and the device no longer match (common after unbinding).\n\n'
          'Open Settings > Bluetooth, find this device, choose Forget / Unpair, then return to the app and add it again.';

  /// True when the user should Forget / unpair the device in system Bluetooth
  /// settings (pairing keys no longer match).
  bool isIosBluetoothForgetDeviceError(String? errorCode) =>
      errorCode == 'ios_peer_removed_pairing_info' ||
      errorCode == 'ios_stale_bluetooth_pairing';

  /// Returns localized message for transfer/connection error code, or [fallback] if code is null/unknown.
  String transferOrConnectionError(String? errorCode, [String? fallback]) {
    if (errorCode == null || errorCode.isEmpty) return fallback ?? syncFailed;
    switch (errorCode) {
      case 'device_disconnected_resume':
      case 'device_disconnected_resume_after_reconnect':
        return errDeviceDisconnectedResumeAfterReconnect;
      case 'create_local_dir_failed':
        return errCreateLocalDirFailed;
      case 'transfer_incomplete_size':
        return errTransferIncompleteSize;
      case 'local_file_deleted':
        return errLocalFileDeleted;
      case 'local_file_incomplete':
        return errLocalFileIncomplete;
      case 'device_session_missing':
        return errDeviceSessionMissing;
      case 'device_session_missing_cannot_resume':
        return errDeviceSessionMissingCannotResume;
      case 'transfer_incomplete_resume':
        return errTransferIncompleteResume;
      case 'no_valid_audio':
        return errNoValidAudio;
      case 'user_cancelled':
        return errUserCancelled;
      case 'wifi_handoff':
        return errWifiHandoff;
      case 'wifi_fast_sync_unreachable':
        return errWifiFastSyncUnreachable;
      case 'wifi_fast_sync_disconnected':
        return errWifiFastSyncDisconnected;
      case 'wifi_fast_sync_fallback':
        return errWifiFastSyncUnreachable;
      case 'invalid_session_id':
        return errInvalidSessionId;
      case 'device_recording_resume_later':
        return errDeviceRecordingResumeLater;
      case 'stalled_no_data_3min':
        return errStalledNoData3Min;
      case 'transfer_merged_missing_slice':
      case 'possibly_incomplete_transfer':
        return errMergedFileIncomplete;
      case 'merge_failed':
        return errMergeFailed;
      case 'ios_peer_removed_pairing_info':
        return errIosPeerRemovedPairingInfo;
      case 'ios_stale_bluetooth_pairing':
        return errIosStaleBluetoothPairing;
      default:
        return fallback ?? syncFailed;
    }
  }

  String get transferCancelled =>
      _localizedValues[locale.languageCode]?['transferCancelled'] ??
      'Transfer cancelled';
  String get cancelTransferOnlyActive =>
      _localizedValues[locale.languageCode]?['cancelTransferOnlyActive'] ??
      'Only the currently transferring recording can be cancelled';
  String get transferringWhileRecording =>
      _localizedValues[locale.languageCode]?['transferringWhileRecording'] ??
      'Unavailable while recording';
  String get waitCurrentTransferToRetry =>
      _localizedValues[locale.languageCode]?['waitCurrentTransferToRetry'] ??
      'Please wait for the current transfer to complete before retrying';
  String get today =>
      _localizedValues[locale.languageCode]?['today'] ?? 'TODAY';
  String get yesterday =>
      _localizedValues[locale.languageCode]?['yesterday'] ?? 'YESTERDAY';
  String get earlier =>
      _localizedValues[locale.languageCode]?['earlier'] ?? 'EARLIER';
  String get createFolder =>
      _localizedValues[locale.languageCode]?['createFolder'] ?? 'Create Folder';
  String get folderName =>
      _localizedValues[locale.languageCode]?['folderName'] ?? 'FOLDER NAME';
  String get folderNameExample =>
      _localizedValues[locale.languageCode]?['folderNameExample'] ??
      'e.g., University Lectures';
  String get chooseColor =>
      _localizedValues[locale.languageCode]?['chooseColor'] ?? 'CHOOSE COLOR';
  String get chooseIcon =>
      _localizedValues[locale.languageCode]?['chooseIcon'] ?? 'CHOOSE ICON';
  String get newName =>
      _localizedValues[locale.languageCode]?['newName'] ?? 'New name';
  String get folderNameHint =>
      _localizedValues[locale.languageCode]?['folderNameHint'] ?? 'Folder name';

  // Recording Detail / AI actions
  String get source =>
      _localizedValues[locale.languageCode]?['source'] ?? 'Source';
  String get note => _localizedValues[locale.languageCode]?['note'] ?? 'Note';
  String get localAudioMissing =>
      _localizedValues[locale.languageCode]?['localAudioMissing'] ??
      '本地音频文件不存在，请先同步到手机';
  String get localAudioUnplayable =>
      _localizedValues[locale.languageCode]?['localAudioUnplayable'] ??
      '本地音频无法播放，可尝试重新同步或联系支持';

  String get needTranscriptFirst =>
      _localizedValues[locale.languageCode]?['needTranscriptFirst'] ??
      '请先生成 Transcript，再进行总结';
  String get llmTemplateNotSelected =>
      _localizedValues[locale.languageCode]?['llmTemplateNotSelected'] ??
      'LLM/Template 未选择';
  String get noTranscriptYet =>
      _localizedValues[locale.languageCode]?['noTranscriptYet'] ??
      'No Transcript Yet';
  String get configureApiAndTranscribe =>
      _localizedValues[locale.languageCode]?['configureApiAndTranscribe'] ??
      'Configure your API and click below to transcribe\nand summarize';
  String get transcribeAndSummarize =>
      _localizedValues[locale.languageCode]?['transcribeAndSummarize'] ??
      'Transcribe & Summarize';
  String get transcription =>
      _localizedValues[locale.languageCode]?['transcription'] ??
      'Transcription';
  String get generateSummary =>
      _localizedValues[locale.languageCode]?['generateSummary'] ??
      'Generate Summary';
  String get chooseSummaryVersion =>
      _localizedValues[locale.languageCode]?['chooseSummaryVersion'] ??
      '选择总结版本';
  String get summary =>
      _localizedValues[locale.languageCode]?['summary'] ?? '总结';
  String get summaryVersionPrefix =>
      _localizedValues[locale.languageCode]?['summaryVersionPrefix'] ??
      'Summary';
  String get deleteCurrentSummary =>
      _localizedValues[locale.languageCode]?['deleteCurrentSummary'] ??
      '删除当前总结';
  String get aiGenerating =>
      _localizedValues[locale.languageCode]?['aiGenerating'] ??
      'AI is generating…';
  String get summaryComplete =>
      _localizedValues[locale.languageCode]?['summaryComplete'] ??
      'Summary complete';
  String get backgroundingEnabled =>
      _localizedValues[locale.languageCode]?['backgroundingEnabled'] ??
      'BACKGROUNDING ENABLED';
  String get aiDisclaimer =>
      _localizedValues[locale.languageCode]?['aiDisclaimer'] ??
      'Content generated by AI for reference only';
  String get noSummaryYet =>
      _localizedValues[locale.languageCode]?['noSummaryYet'] ??
      'No Summary Yet';
  String get configureApiAndClickPlus =>
      _localizedValues[locale.languageCode]?['configureApiAndClickPlus'] ??
      'Configure your API and click + to summarize';
  String get template =>
      _localizedValues[locale.languageCode]?['template'] ?? 'Template';
  String get autoSpeakerLabeling =>
      _localizedValues[locale.languageCode]?['autoSpeakerLabeling'] ??
      'Auto Speaker Labeling';
  String get autoSpeakerHint =>
      _localizedValues[locale.languageCode]?['autoSpeakerHint'] ??
      'Speaker labeling prefers Deepgram when available for more stable diarization.';
  String get audioLanguage =>
      _localizedValues[locale.languageCode]?['audioLanguage'] ??
      'Audio Language';
  String get sttModel =>
      _localizedValues[locale.languageCode]?['sttModel'] ?? 'STT Model';
  String get sttConfiguration =>
      _localizedValues[locale.languageCode]?['sttConfiguration'] ??
      'STT Configuration';
  String get llmModel =>
      _localizedValues[locale.languageCode]?['llmModel'] ?? 'LLM Model';
  String get llmConfiguration =>
      _localizedValues[locale.languageCode]?['llmConfiguration'] ??
      'LLM Configuration';
  String get generateNow =>
      _localizedValues[locale.languageCode]?['generateNow'] ?? 'Generate Now';
  String get summarize =>
      _localizedValues[locale.languageCode]?['summarize'] ?? 'Summarize';
  String get summarizeAgain =>
      _localizedValues[locale.languageCode]?['summarizeAgain'] ??
      'Summarize Again';
  String get transcribeAgain =>
      _localizedValues[locale.languageCode]?['transcribeAgain'] ??
      'Transcribe Again';
  String get batchTranscribe =>
      _localizedValues[locale.languageCode]?['batchTranscribe'] ??
      'Batch transcribe';

  String batchTranscribeSummary(int succeeded, int failed) => (_localizedValues[
              locale.languageCode]?['batchTranscribeSummary'] ??
          'Batch transcribe done: {ok} succeeded, {fail} skipped or failed.')
      .replaceAll('{ok}', succeeded.toString())
      .replaceAll('{fail}', failed.toString());

  String batchTranscribingFilesProgress(int current, int total) {
    final t = total < 1 ? 1 : total;
    final c = current < 1 ? 1 : (current > t ? t : current);
    return (_localizedValues[locale.languageCode]
                ?['batchTranscribingFilesProgress'] ??
            'Transcribing file {c} of {t}…')
        .replaceAll('{c}', c.toString())
        .replaceAll('{t}', t.toString());
  }

  String get batchTranscribingFloatingHint =>
      _localizedValues[locale.languageCode]?['batchTranscribingFloatingHint'] ??
      'You can leave this page; progress continues in the background.';

  String get batchTranscribeSwipeToHide =>
      _localizedValues[locale.languageCode]?['batchTranscribeSwipeToHide'] ??
      'Swipe sideways to hide';

  String get batchTranscribeShowProgress =>
      _localizedValues[locale.languageCode]?['batchTranscribeShowProgress'] ??
      'Show transcribe progress';

  String get batchTranscribeAlreadyRunning =>
      _localizedValues[locale.languageCode]?['batchTranscribeAlreadyRunning'] ??
      'Batch transcribe is already in progress';

  String get processing =>
      _localizedValues[locale.languageCode]?['processing'] ?? 'Processing...';
  String preparingAudioForTranscription(int percent) =>
      (_localizedValues[locale.languageCode]
                  ?['preparingAudioForTranscription'] ??
              'Preparing audio on device… {p}%')
          .replaceAll('{p}', percent.clamp(0, 100).toString());

  /// Global status right after ASR starts, before we know local vs upload (avoids "uploading" during long raw Opus decode).
  String get transcriptionWorkInProgress =>
      _localizedValues[locale.languageCode]?['transcriptionWorkInProgress'] ??
      'Working on transcription…';

  String transcribingChunkProgress(int current, int total) {
    final t = total < 1 ? 1 : total;
    final c = current < 1 ? 1 : (current > t ? t : current);
    return (_localizedValues[locale.languageCode]
                ?['transcribingChunkProgress'] ??
            'Transcribing… {c}/{t} segments done')
        .replaceAll('{c}', c.toString())
        .replaceAll('{t}', t.toString());
  }

  String get statusQueued =>
      _localizedValues[locale.languageCode]?['statusQueued'] ??
      'File uploading...';
  String get statusCompleted =>
      _localizedValues[locale.languageCode]?['statusCompleted'] ?? 'Completed';
  String get statusFailed =>
      _localizedValues[locale.languageCode]?['statusFailed'] ?? 'Failed';
  String get transcribing =>
      _localizedValues[locale.languageCode]?['transcribing'] ??
      'Transcribing...';
  String get waveformBuilding =>
      _localizedValues[locale.languageCode]?['waveformBuilding'] ??
      'Building waveform…';
  String get playbackPreparing =>
      _localizedValues[locale.languageCode]?['playbackPreparing'] ??
      'Preparing playback…';
  String get summarizing =>
      _localizedValues[locale.languageCode]?['summarizing'] ?? 'Summarizing...';
  String get errorTitle =>
      _localizedValues[locale.languageCode]?['errorTitle'] ?? 'Error';
  String get saveAs =>
      _localizedValues[locale.languageCode]?['saveAs'] ?? 'Save As';
  String speakerModeSwitchedProvider(String provider) =>
      (_localizedValues[locale.languageCode]?['speakerModeSwitchedProvider'] ??
              'Speaker labeling switched transcription provider to {provider}.')
          .replaceAll('{provider}', provider);
  String speakerModeFallbackNormal(String provider) => (_localizedValues[
              locale.languageCode]?['speakerModeFallbackNormal'] ??
          '{provider} does not support speaker labeling. Continued with normal transcription.')
      .replaceAll('{provider}', provider);
  String get newFileNameHint =>
      _localizedValues[locale.languageCode]?['newFileNameHint'] ??
      'New file name';
  String get trimmedAudio =>
      _localizedValues[locale.languageCode]?['trimmedAudio'] ?? 'Trimmed audio';
  String get trimSuffix =>
      _localizedValues[locale.languageCode]?['trimSuffix'] ?? '(trim)';
  String get trimOnlyWavSupported =>
      _localizedValues[locale.languageCode]?['trimOnlyWavSupported'] ??
      'Only WAV(PCM16) audio is supported for trimming.';
  String get trim => _localizedValues[locale.languageCode]?['trim'] ?? 'Trim';
  String get smartEdit =>
      _localizedValues[locale.languageCode]?['smartEdit'] ?? 'Smart Edit';
  String get smartEditTodo =>
      _localizedValues[locale.languageCode]?['smartEditTodo'] ??
      'Smart Edit (TODO)';
  String get deleteTodo =>
      _localizedValues[locale.languageCode]?['deleteTodo'] ?? 'Delete (TODO)';
  String get asrVendorIdNotConfigured =>
      _localizedValues[locale.languageCode]?['asrVendorIdNotConfigured'] ??
      'ASR vendor ID not configured. Please sync configs first.';
  String transcriptionFailed(String error) =>
      (_localizedValues[locale.languageCode]?['transcriptionFailed'] ??
              'Transcription failed: {error}')
          .replaceAll('{error}', error);
  String uploadFileTooLarge(int limitMb) =>
      (_localizedValues[locale.languageCode]?['uploadFileTooLarge'] ??
              'File too large (over {n}MB). Please trim first.')
          .replaceAll('{n}', '$limitMb');
  String get uploadFileTooLarge413 =>
      _localizedValues[locale.languageCode]?['uploadFileTooLarge413'] ??
      'Upload failed: file too large. Please trim the recording first.';
  String uploadingProgress(int percent) =>
      (_localizedValues[locale.languageCode]?['uploadingProgress'] ??
              'Uploading... {n}%')
          .replaceAll('{n}', '$percent');

  /// 504/502 gateway timeout when the server works on a large file.
  String get transcriptionGatewayTimeout =>
      _localizedValues[locale.languageCode]?['transcriptionGatewayTimeout'] ??
      'Transcription timed out. The server is still processing. Please try again.';
  String get transcriptionGatewayTimeoutRetry =>
      _localizedValues[locale.languageCode]
          ?['transcriptionGatewayTimeoutRetry'] ??
      'Retry';
  String get aiDataSharingConsentTitle =>
      _localizedValues[locale.languageCode]?['aiDataSharingConsentTitle'] ??
      'AI data sharing';
  String get aiDataSharingConsentIntro =>
      _localizedValues[locale.languageCode]?['aiDataSharingConsentIntro'] ??
      'To use transcription or summary generation, this app needs to send selected recording data to cloud AI services.';
  String aiDataSharingConsentShortMessage(String recipients) => (_localizedValues[
              locale.languageCode]?['aiDataSharingConsentShortMessage'] ??
          'To use transcription or summary, the app will send the selected recording audio, transcript text, and necessary device/recording information to {recipients} for AI processing. Please confirm whether you agree.')
      .replaceAll('{recipients}', recipients);
  String get aiDataSharingConsentAudio =>
      _localizedValues[locale.languageCode]?['aiDataSharingConsentAudio'] ??
      'Audio data: the selected recording audio may be uploaded for speech-to-text processing.';
  String get aiDataSharingConsentTranscript =>
      _localizedValues[locale.languageCode]
          ?['aiDataSharingConsentTranscript'] ??
      'Transcript data: transcript text may be sent for summary generation.';
  String get aiDataSharingConsentMetadata =>
      _localizedValues[locale.languageCode]?['aiDataSharingConsentMetadata'] ??
      'Related metadata: recording ID, device ID, language, speaker-labeling option, and selected AI configuration may be sent to process the request.';
  String aiDataSharingConsentRecipients(String recipients) =>
      (_localizedValues[locale.languageCode]
                  ?['aiDataSharingConsentRecipients'] ??
              'Recipients: {recipients}.')
          .replaceAll('{recipients}', recipients);
  String get aiDataSharingConsentProtection =>
      _localizedValues[locale.languageCode]
          ?['aiDataSharingConsentProtection'] ??
      'The data is used only to provide the requested AI result and is handled under the privacy policy and the selected provider protections.';
  String get aiDataSharingConsentCheckbox =>
      _localizedValues[locale.languageCode]?['aiDataSharingConsentCheckbox'] ??
      'I understand and agree to send this data to the listed services for AI processing.';
  String get aiDataSharingConsentAllow =>
      _localizedValues[locale.languageCode]?['aiDataSharingConsentAllow'] ??
      'Allow and continue';
  String get aiDataSharingConsentDecline =>
      _localizedValues[locale.languageCode]?['aiDataSharingConsentDecline'] ??
      'Do not allow';
  String get aiDataSharingConsentSenseCraftCloud =>
      _localizedValues[locale.languageCode]
          ?['aiDataSharingConsentSenseCraftCloud'] ??
      'SenseCraft Voice cloud service';
  String get aiDataSharingConsentSelectedAiProviders =>
      _localizedValues[locale.languageCode]
          ?['aiDataSharingConsentSelectedAiProviders'] ??
      'the selected or configured third-party AI service providers';
  String summaryFailed(String error) =>
      (_localizedValues[locale.languageCode]?['summaryFailed'] ??
              'Summary failed: {error}')
          .replaceAll('{error}', error);
  String moveToRecycleBinConfirmName(String name) =>
      (_localizedValues[locale.languageCode]?['moveToRecycleBinConfirmName'] ??
              'Move "{name}" to Recycle Bin?')
          .replaceAll('{name}', name);
  String get viewAll =>
      _localizedValues[locale.languageCode]?['viewAll'] ?? 'View All';
  String get select =>
      _localizedValues[locale.languageCode]?['select'] ?? 'Select';
  String get auto => _localizedValues[locale.languageCode]?['auto'] ?? 'Auto';
  String get share =>
      _localizedValues[locale.languageCode]?['share'] ?? 'Share';
  String get shareLink =>
      _localizedValues[locale.languageCode]?['shareLink'] ?? 'Share Link';
  String get copyToClipboard =>
      _localizedValues[locale.languageCode]?['copyToClipboard'] ??
      'Copy to Clipboard';

  /// Shown after any copy-to-clipboard in share sheet (e.g. "Copied").
  String get copySuccess =>
      _localizedValues[locale.languageCode]?['copySuccess'] ?? 'Copied';
  String get transcriptCopied =>
      _localizedValues[locale.languageCode]?['transcriptCopied'] ??
      'Transcript copied';
  String get noteCopied =>
      _localizedValues[locale.languageCode]?['noteCopied'] ?? 'Note copied';
  String get exportFile =>
      _localizedValues[locale.languageCode]?['exportFile'] ?? 'Export File';
  String get audio =>
      _localizedValues[locale.languageCode]?['audio'] ?? 'Audio';
  String get shareContent =>
      _localizedValues[locale.languageCode]?['shareContent'] ?? 'Share Content';
  String get shareLinkExpiry =>
      _localizedValues[locale.languageCode]?['shareLinkExpiry'] ??
      'Anyone with the link can access. Expires in 7 days.';
  String get linkCopied =>
      _localizedValues[locale.languageCode]?['linkCopied'] ?? 'Link copied';
  String get copyLink =>
      _localizedValues[locale.languageCode]?['copyLink'] ?? 'Copy Link';
  String get exportAudio =>
      _localizedValues[locale.languageCode]?['exportAudio'] ?? 'Export Audio';
  String get exportTranscript =>
      _localizedValues[locale.languageCode]?['exportTranscript'] ??
      'Export Transcript';
  String get exportNote =>
      _localizedValues[locale.languageCode]?['exportNote'] ?? 'Export Note';
  String get exportFormat =>
      _localizedValues[locale.languageCode]?['exportFormat'] ?? 'Export Format';
  String get export =>
      _localizedValues[locale.languageCode]?['export'] ?? 'Export';
  String get exportRecording =>
      _localizedValues[locale.languageCode]?['exportRecording'] ??
      'Export Recording';
  String get exporting =>
      _localizedValues[locale.languageCode]?['exporting'] ?? 'Exporting...';
  String exportingPercent(int p) =>
      (_localizedValues[locale.languageCode]?['exportingPercent'] ??
              'Exporting ({p}%)')
          .replaceAll('{p}', '$p');
  String get noAudioToExport =>
      _localizedValues[locale.languageCode]?['noAudioToExport'] ??
      'No audio file to export.';
  String get audioFileNotFound =>
      _localizedValues[locale.languageCode]?['audioFileNotFound'] ??
      'Audio file not found.';
  String shareFailed(String error) =>
      (_localizedValues[locale.languageCode]?['shareFailed'] ??
              'Share failed: {error}')
          .replaceAll('{error}', error);
  String transcodeFailed(String error) =>
      (_localizedValues[locale.languageCode]?['transcodeFailed'] ??
              'Transcode failed: {error}')
          .replaceAll('{error}', error);
  String get wavExportNeedsConversion =>
      _localizedValues[locale.languageCode]?['wavExportNeedsConversion'] ??
      'WAV export requires conversion (server endpoint reserved).';
  String get mp3ExportNeedsConversion =>
      _localizedValues[locale.languageCode]?['mp3ExportNeedsConversion'] ??
      'MP3 export requires conversion (server endpoint reserved).';
  String get unsupportedAudioFormat =>
      _localizedValues[locale.languageCode]?['unsupportedAudioFormat'] ??
      'Unsupported audio export format.';
  String get noTranscriptToExport =>
      _localizedValues[locale.languageCode]?['noTranscriptToExport'] ??
      'No transcript to export.';
  String formatExportNeedsServer(String format) =>
      (_localizedValues[locale.languageCode]?['formatExportNeedsServer'] ??
              '{format} export requires server generation (endpoint reserved).')
          .replaceAll('{format}', format);
  String get noNoteToExport =>
      _localizedValues[locale.languageCode]?['noNoteToExport'] ??
      'No note to export.';
  String get searchRecordingsOrQa =>
      _localizedValues[locale.languageCode]?['searchRecordingsOrQa'] ??
      'Search recordings or Q&A';
  String loadFailed(String error) =>
      (_localizedValues[locale.languageCode]?['loadFailed'] ??
              'Load failed: {error}')
          .replaceAll('{error}', error);
  String totalResults(int count) =>
      (_localizedValues[locale.languageCode]?['totalResults'] ??
              'Total {count} Results')
          .replaceAll('{count}', count.toString());
  String get recentSearches =>
      _localizedValues[locale.languageCode]?['recentSearches'] ??
      'RECENT SEARCHES';
  String get searchEmptyHint =>
      _localizedValues[locale.languageCode]?['searchEmptyHint'] ??
      'Enter keywords to search recordings or\nQ&A';
  String get creationTime =>
      _localizedValues[locale.languageCode]?['creationTime'] ?? 'Creation Time';
  String get last7Days =>
      _localizedValues[locale.languageCode]?['last7Days'] ?? 'Last 7 Days';
  String get last30Days =>
      _localizedValues[locale.languageCode]?['last30Days'] ?? 'Last 30 Days';
  String get last3Months =>
      _localizedValues[locale.languageCode]?['last3Months'] ?? 'Last 3 Months';
  String get last6Months =>
      _localizedValues[locale.languageCode]?['last6Months'] ?? 'Last 6 Months';
  String get lastYear =>
      _localizedValues[locale.languageCode]?['lastYear'] ?? 'Last Year';
  String get sinceRegistration =>
      _localizedValues[locale.languageCode]?['sinceRegistration'] ??
      'Since Registration';
  String get fromDevice =>
      _localizedValues[locale.languageCode]?['fromDevice'] ?? 'From Device';
  String get sourceLocal =>
      _localizedValues[locale.languageCode]?['sourceLocal'] ?? 'Local';
  String get transcriptStatus =>
      _localizedValues[locale.languageCode]?['transcriptStatus'] ??
      'Transcript Status';
  String get transcribed =>
      _localizedValues[locale.languageCode]?['transcribed'] ?? 'Transcribed';
  String get notTranscribed =>
      _localizedValues[locale.languageCode]?['notTranscribed'] ??
      'Not Transcribed';
  String get transcriptionFailedShort =>
      _localizedValues[locale.languageCode]?['transcriptionFailedShort'] ??
      'Transcription failed';
  String deviceN(int n) =>
      (_localizedValues[locale.languageCode]?['deviceN'] ?? 'Device {n}')
          .replaceAll('{n}', n.toString());
  String get startsAt =>
      _localizedValues[locale.languageCode]?['startsAt'] ?? 'STARTS AT';
  String get endsAt =>
      _localizedValues[locale.languageCode]?['endsAt'] ?? 'ENDS AT';
  String get selectDate =>
      _localizedValues[locale.languageCode]?['selectDate'] ?? 'Select Date';
  String get apply =>
      _localizedValues[locale.languageCode]?['apply'] ?? 'Apply';
  String get deleteSegment =>
      _localizedValues[locale.languageCode]?['deleteSegment'] ??
      'Delete segment';
  String get keepSegment =>
      _localizedValues[locale.languageCode]?['keepSegment'] ?? 'Keep segment';
  String get recordingStartFailed =>
      _localizedValues[locale.languageCode]?['recordingStartFailed'] ??
      'Failed to start recording';
  String get markFailedNotRecording =>
      _localizedValues[locale.languageCode]?['markFailedNotRecording'] ??
      'Mark failed: not recording';
  String markAdded(String time) =>
      (_localizedValues[locale.languageCode]?['markAdded'] ??
              'Marked at {time}')
          .replaceAll('{time}', time);
  String get markFailedDeviceNotReady =>
      _localizedValues[locale.languageCode]?['markFailedDeviceNotReady'] ??
      'Mark failed: not recording or device not ready';
  String markByDeviceButton(String time) =>
      (_localizedValues[locale.languageCode]?['markByDeviceButton'] ??
              'Bookmark added from device at {time}')
          .replaceAll('{time}', time);
  String get deviceButtonStartedRecording =>
      _localizedValues[locale.languageCode]?['deviceButtonStartedRecording'] ??
      'Device started recording';
  String get deviceButtonStoppedRecording =>
      _localizedValues[locale.languageCode]?['deviceButtonStoppedRecording'] ??
      'Device stopped recording';
  String get endRecording =>
      _localizedValues[locale.languageCode]?['endRecording'] ??
      'End recording?';
  String get endRecordingMessage =>
      _localizedValues[locale.languageCode]?['endRecordingMessage'] ??
      'Stop and save this recording, or continue recording?';
  String get stopAndSave =>
      _localizedValues[locale.languageCode]?['stopAndSave'] ?? 'Stop & Save';
  String get continueRecording =>
      _localizedValues[locale.languageCode]?['continueRecording'] ??
      'Continue Recording';
  String get continueRecordingSnack =>
      _localizedValues[locale.languageCode]?['continueRecordingSnack'] ??
      'Continuing recording';
  String get recordingStopFailed =>
      _localizedValues[locale.languageCode]?['recordingStopFailed'] ??
      'Failed to stop recording';
  String get pauseFailed =>
      _localizedValues[locale.languageCode]?['pauseFailed'] ??
      'Failed to pause recording';
  String get resumeFailed =>
      _localizedValues[locale.languageCode]?['resumeFailed'] ??
      'Failed to resume recording';
  String get recordingFinishedSyncing =>
      _localizedValues[locale.languageCode]?['recordingFinishedSyncing'] ??
      'Recording ended and syncing started';
  String get microphonePermissionDenied =>
      _localizedValues[locale.languageCode]?['microphonePermissionDenied'] ??
      'Microphone permission denied. Unable to record.';
  String get photoPermissionRequiredTitle =>
      _localizedValues[locale.languageCode]?['photoPermissionRequiredTitle'] ??
      'Photo access required';
  String get photoPermissionRequiredForAvatarMessage =>
      _localizedValues[locale.languageCode]
          ?['photoPermissionRequiredForAvatarMessage'] ??
      'Allow photo library access for this app in Settings to change your profile photo.';
  String get notificationPermissionDenied =>
      _localizedValues[locale.languageCode]?['notificationPermissionDenied'] ??
      'Notification permission denied. Push will be off.';
  String get bluetoothPermissionDenied =>
      _localizedValues[locale.languageCode]?['bluetoothPermissionDenied'] ??
      'Bluetooth permission denied. Unable to scan devices.';
  String get bluetoothDisabledTitle =>
      _localizedValues[locale.languageCode]?['bluetoothDisabledTitle'] ??
      'Bluetooth is off';
  String get bluetoothDisabledHint =>
      _localizedValues[locale.languageCode]?['bluetoothDisabledHint'] ??
      'Turn on Bluetooth to search for nearby devices.';
  String get turnOnBluetooth =>
      _localizedValues[locale.languageCode]?['turnOnBluetooth'] ??
      'Turn on Bluetooth';
  String get bluetoothRequiredTitle =>
      _localizedValues[locale.languageCode]?['bluetoothRequiredTitle'] ??
      'Bluetooth required';
  String get bluetoothOffForConnectMessage =>
      _localizedValues[locale.languageCode]?['bluetoothOffForConnectMessage'] ??
      'Turn on Bluetooth in Settings to connect or add a device.';
  String get bluetoothPermissionRequiredForConnectMessage =>
      _localizedValues[locale.languageCode]
          ?['bluetoothPermissionRequiredForConnectMessage'] ??
      'Allow Bluetooth access for this app in Settings to connect or add a device.';
  String get openSettingsAction =>
      _localizedValues[locale.languageCode]?['openSettingsAction'] ??
      'Open Settings';
  String get scanLocationRequiredTitle =>
      _localizedValues[locale.languageCode]?['scanLocationRequiredTitle'] ??
      'Location needed to find devices';
  String get scanLocationServiceOffMessage =>
      _localizedValues[locale.languageCode]?['scanLocationServiceOffMessage'] ??
      "Your phone's location switch is off. Android needs location turned on "
          'to discover Bluetooth devices. Turn it on, then scan again.';
  String get scanLocationPermissionMessage =>
      _localizedValues[locale.languageCode]?['scanLocationPermissionMessage'] ??
      'This app needs location permission to discover Bluetooth devices on your '
          'Android version. Grant it, then scan again.';
  String get opusNotSupported =>
      _localizedValues[locale.languageCode]?['opusNotSupported'] ??
      'Current device does not support Opus encoding';
  String get recordingSavedLocally =>
      _localizedValues[locale.languageCode]?['recordingSavedLocally'] ??
      'Recording saved locally (for server API testing)';
  String get noDeviceConnected =>
      _localizedValues[locale.languageCode]?['noDeviceConnected'] ??
      'No Device Connected';
  String get connectDeviceToRecord =>
      _localizedValues[locale.languageCode]?['connectDeviceToRecord'] ??
      'Please connect your SenseCraft Voice via\nBluetooth to start recording.';
  String get deviceDisconnectedReconnecting =>
      _localizedValues[locale.languageCode]
          ?['deviceDisconnectedReconnecting'] ??
      'Device disconnected. Attempting to reconnect...';
  String get reconnectFailed =>
      _localizedValues[locale.languageCode]?['reconnectFailed'] ??
      'Reconnect failed. Please connect manually.';
  String get connectNow =>
      _localizedValues[locale.languageCode]?['connectNow'] ?? 'Connect Now';
  String get recordingFinished =>
      _localizedValues[locale.languageCode]?['recordingFinished'] ??
      'Recording Finished';
  String get recordingFinishedLocal =>
      _localizedValues[locale.languageCode]?['recordingFinishedLocal'] ??
      'Recording finished and saved locally.';
  String get recordingFinishedDevice =>
      _localizedValues[locale.languageCode]?['recordingFinishedDevice'] ??
      'Recording finished and saved to device.';
  String get backToFiles =>
      _localizedValues[locale.languageCode]?['backToFiles'] ?? 'Back to Files';
  String get ready =>
      _localizedValues[locale.languageCode]?['ready'] ?? 'Ready';
  String get paused =>
      _localizedValues[locale.languageCode]?['paused'] ?? 'Paused';
  String get deviceRecording =>
      _localizedValues[locale.languageCode]?['deviceRecording'] ??
      'Device Recording';
  String get preparingRecording =>
      _localizedValues[locale.languageCode]?['preparingRecording'] ??
      'Preparing to record…';
  String get localRecording =>
      _localizedValues[locale.languageCode]?['localRecording'] ??
      'Local Recording';
  String get mark => _localizedValues[locale.languageCode]?['mark'] ?? 'MARK';
  String get pause =>
      _localizedValues[locale.languageCode]?['pause'] ?? 'PAUSE';
  String get resume =>
      _localizedValues[locale.languageCode]?['resume'] ?? 'RESUME';
  String get record =>
      _localizedValues[locale.languageCode]?['record'] ?? 'RECORD';
  String get recording =>
      _localizedValues[locale.languageCode]?['recording'] ?? 'Recording';
  String get finish =>
      _localizedValues[locale.languageCode]?['finish'] ?? 'FINISH';
  String keyAt(String time) =>
      (_localizedValues[locale.languageCode]?['keyAt'] ?? 'Key {time}')
          .replaceAll('{time}', time);
  String localRecordingName(String ts) =>
      (_localizedValues[locale.languageCode]?['localRecordingName'] ??
              'Local Recording {ts}')
          .replaceAll('{ts}', ts);
  String recordingName(String ts) =>
      (_localizedValues[locale.languageCode]?['recordingName'] ??
              'Recording {ts}')
          .replaceAll('{ts}', ts);
  String get seekBack5s =>
      _localizedValues[locale.languageCode]?['seekBack5s'] ?? 'Seek back 5s';
  String get seekForward5s =>
      _localizedValues[locale.languageCode]?['seekForward5s'] ??
      'Seek forward 5s';
  String get content =>
      _localizedValues[locale.languageCode]?['content'] ?? 'Content';
  String shareLinkText(String content, String link) =>
      (_localizedValues[locale.languageCode]?['shareLinkText'] ??
              'SenseCraft Voice share link ({content})\n{link}')
          .replaceAll('{content}', content)
          .replaceAll('{link}', link);
  String get shareAudioExportText =>
      _localizedValues[locale.languageCode]?['shareAudioExportText'] ??
      'SenseCraft Voice audio export';
  String get shareAudioExportOpusText =>
      _localizedValues[locale.languageCode]?['shareAudioExportOpusText'] ??
      'SenseCraft Voice audio export (Opus)';
  String get shareTranscriptExportText =>
      _localizedValues[locale.languageCode]?['shareTranscriptExportText'] ??
      'SenseCraft Voice transcript export';
  String get shareNoteExportText =>
      _localizedValues[locale.languageCode]?['shareNoteExportText'] ??
      'SenseCraft Voice note export';
  String get ffmpegError =>
      _localizedValues[locale.languageCode]?['ffmpegError'] ?? 'FFmpeg error';

  // AI Config
  String get aiConfiguration =>
      _localizedValues[locale.languageCode]?['aiConfiguration'] ??
      'AI Configuration';
  String get guide =>
      _localizedValues[locale.languageCode]?['guide'] ?? 'Guide';
  String get serviceConfiguration =>
      _localizedValues[locale.languageCode]?['serviceConfiguration'] ??
      'SERVICE CONFIGURATION';
  String get sttService =>
      _localizedValues[locale.languageCode]?['sttService'] ?? 'STT Service';
  String get llmService =>
      _localizedValues[locale.languageCode]?['llmService'] ?? 'LLM Service';
  String get notConfigured =>
      _localizedValues[locale.languageCode]?['notConfigured'] ??
      'Not configured';
  String get configured =>
      _localizedValues[locale.languageCode]?['configured'] ?? 'CONFIGURED';
  String get configure =>
      _localizedValues[locale.languageCode]?['configure'] ?? 'CONFIGURE';
  String get loading =>
      _localizedValues[locale.languageCode]?['loading'] ?? 'Loading...';
  String get promptTemplates =>
      _localizedValues[locale.languageCode]?['promptTemplates'] ??
      'PROMPT TEMPLATES';
  String get viewMoreTemplates =>
      _localizedValues[locale.languageCode]?['viewMoreTemplates'] ??
      'view more templates';
  String get sessionHistory =>
      _localizedValues[locale.languageCode]?['sessionHistory'] ??
      'SESSION HISTORY';
  String get sessionMessages =>
      _localizedValues[locale.languageCode]?['sessionMessages'] ??
      'Session Messages';
  String get noSessions =>
      _localizedValues[locale.languageCode]?['noSessions'] ?? 'No sessions yet';
  String get noMessages =>
      _localizedValues[locale.languageCode]?['noMessages'] ?? 'No messages yet';
  String get deleteSession =>
      _localizedValues[locale.languageCode]?['deleteSession'] ??
      'Delete session';
  String get deleteSessionMessage =>
      _localizedValues[locale.languageCode]?['deleteSessionMessage'] ??
      'Delete this session and its messages?';
  String get deleteMessage =>
      _localizedValues[locale.languageCode]?['deleteMessage'] ??
      'Delete message';
  String get deleteMessageConfirm =>
      _localizedValues[locale.languageCode]?['deleteMessageConfirm'] ??
      'Delete the latest message in this session?';
  String get custom =>
      _localizedValues[locale.languageCode]?['custom'] ?? 'Custom';
  String get sttProviderAliyun =>
      _localizedValues[locale.languageCode]?['sttProviderAliyun'] ??
      'Aliyun FunASR';
  String get sttProviderFunasr =>
      _localizedValues[locale.languageCode]?['sttProviderFunasr'] ??
      'Self-hosted FunASR';
  String get sttProviderOpenAiWhisper =>
      _localizedValues[locale.languageCode]?['sttProviderOpenAiWhisper'] ??
      'OpenAI Whisper';
  String get sttProviderGoogleGemini =>
      _localizedValues[locale.languageCode]?['sttProviderGoogleGemini'] ??
      'Google Gemini';
  String get sttProviderDeepgram =>
      _localizedValues[locale.languageCode]?['sttProviderDeepgram'] ??
      'Deepgram';
  String get sttProviderLocalWhisper =>
      _localizedValues[locale.languageCode]?['sttProviderLocalWhisper'] ??
      'Local Whisper';
  String get sttProviderVosk =>
      _localizedValues[locale.languageCode]?['sttProviderVosk'] ?? 'Vosk';
  String get sttProviderIflytek =>
      _localizedValues[locale.languageCode]?['sttProviderIflytek'] ?? 'iFlytek';
  String get sttProviderTencent =>
      _localizedValues[locale.languageCode]?['sttProviderTencent'] ?? 'Tencent';
  String get sttProviderBaidu =>
      _localizedValues[locale.languageCode]?['sttProviderBaidu'] ?? 'Baidu';
  String get sttProviderDoubao =>
      _localizedValues[locale.languageCode]?['sttProviderDoubao'] ??
      'Doubao ASR';
  String get sttProviderOnDevice =>
      _localizedValues[locale.languageCode]?['sttProviderOnDevice'] ??
      'On-device Local STT';
  String get llmProviderOpenAi =>
      _localizedValues[locale.languageCode]?['llmProviderOpenAi'] ??
      'OpenAI GPT';
  String get llmProviderAnthropic =>
      _localizedValues[locale.languageCode]?['llmProviderAnthropic'] ??
      'Anthropic Claude';
  String get llmProviderGoogleGemini =>
      _localizedValues[locale.languageCode]?['llmProviderGoogleGemini'] ??
      'Google Gemini';
  String get llmProviderLlama =>
      _localizedValues[locale.languageCode]?['llmProviderLlama'] ?? 'Llama';
  String get llmProviderDoubao =>
      _localizedValues[locale.languageCode]?['llmProviderDoubao'] ?? 'Doubao';
  String get llmProviderQwen =>
      _localizedValues[locale.languageCode]?['llmProviderQwen'] ?? 'Qwen';
  String get llmProviderDeepseek =>
      _localizedValues[locale.languageCode]?['llmProviderDeepseek'] ??
      'DeepSeek';
  String get llmProviderOpenRouter =>
      _localizedValues[locale.languageCode]?['llmProviderOpenRouter'] ??
      'OpenRouter';

  // Home bottom tabs
  String get filesTab =>
      _localizedValues[locale.languageCode]?['filesTab'] ?? 'FILES';
  String get aiConfigTab =>
      _localizedValues[locale.languageCode]?['aiConfigTab'] ?? 'AI CONFIG';

  // Device
  String get device =>
      _localizedValues[locale.languageCode]?['device'] ?? 'Device';
  String get disconnect =>
      _localizedValues[locale.languageCode]?['disconnect'] ?? 'Disconnect';
  String get atDebug =>
      _localizedValues[locale.languageCode]?['atDebug'] ?? 'AT Debug';
  String get connect =>
      _localizedValues[locale.languageCode]?['connect'] ?? 'Connect';
  String get noValue =>
      _localizedValues[locale.languageCode]?['noValue'] ?? '—';
  String lastResponseLabel(String value) =>
      (_localizedValues[locale.languageCode]?['lastResponseLabel'] ??
              'Last response: {value}')
          .replaceAll('{value}', value);
  String scanResultsCount(int n) =>
      (_localizedValues[locale.languageCode]?['scanResultsCount'] ??
              'Scan results ({n})')
          .replaceAll('{n}', '$n');
  String get scanning =>
      _localizedValues[locale.languageCode]?['scanning'] ?? 'Scanning...';
  String get startScan =>
      _localizedValues[locale.languageCode]?['startScan'] ?? 'Start Scan';
  String get noName =>
      _localizedValues[locale.languageCode]?['noName'] ?? '(no name)';
  String get deviceDetailsInfo =>
      _localizedValues[locale.languageCode]?['deviceDetailsInfo'] ??
      'Device Details & Info';
  String get deviceNotFound =>
      _localizedValues[locale.languageCode]?['deviceNotFound'] ??
      'Device not found';
  String get online =>
      _localizedValues[locale.languageCode]?['online'] ?? 'Online';
  String get offline =>
      _localizedValues[locale.languageCode]?['offline'] ?? 'Offline';
  String get deviceNameLabel =>
      _localizedValues[locale.languageCode]?['deviceNameLabel'] ??
      'Device Name';
  String get statusLabel =>
      _localizedValues[locale.languageCode]?['statusLabel'] ?? 'Status';
  String get modelLabel =>
      _localizedValues[locale.languageCode]?['modelLabel'] ?? 'Model';
  String get batteryLabel =>
      _localizedValues[locale.languageCode]?['batteryLabel'] ?? 'Battery';
  String get recordingModeLabel =>
      _localizedValues[locale.languageCode]?['recordingModeLabel'] ??
      'Recording Mode';
  String get firmwareVersionLabel =>
      _localizedValues[locale.languageCode]?['firmwareVersionLabel'] ??
      'Firmware Version';
  String get disconnectAction =>
      _localizedValues[locale.languageCode]?['disconnectAction'] ??
      'Disconnect';
  String get resetDeviceAction =>
      _localizedValues[locale.languageCode]?['resetDeviceAction'] ??
      'Reset Device';
  String get unbindDeviceAction =>
      _localizedValues[locale.languageCode]?['unbindDeviceAction'] ??
      'Unbind Device';
  String get unpairDeviceAction =>
      _localizedValues[locale.languageCode]?['unpairDeviceAction'] ?? 'Unpair';
  String get unpairDeviceTitle =>
      _localizedValues[locale.languageCode]?['unpairDeviceTitle'] ??
      'Unpair Device';
  String get unpairDeviceMessage =>
      _localizedValues[locale.languageCode]?['unpairDeviceMessage'] ??
      'Required before this device can pair with another phone.\n\n'
          'Clears pairing info on the device and disconnects. '
          'Recordings on the device are not deleted.';
  String get unpairConfirm =>
      _localizedValues[locale.languageCode]?['unpairConfirm'] ?? 'Unpair';
  String get unpairDoneSnack =>
      _localizedValues[locale.languageCode]?['unpairDoneSnack'] ??
      'Pairing cleared';
  String get unpairFailedSnack =>
      _localizedValues[locale.languageCode]?['unpairFailedSnack'] ??
      'Unpair failed, please try again later';
  String get unpairConnectFirst =>
      _localizedValues[locale.languageCode]?['unpairConnectFirst'] ??
      'Please connect the device first to unpair';
  String get unpairSentSnack =>
      _localizedValues[locale.languageCode]?['unpairSentSnack'] ??
      'Pairing cleared and disconnected. Re-pair on next connect.';
  String get renameDeviceTitle =>
      _localizedValues[locale.languageCode]?['renameDeviceTitle'] ??
      'Rename Device';
  String get deviceNameHint =>
      _localizedValues[locale.languageCode]?['deviceNameHint'] ?? 'Device Name';
  String get renameOfflineHint =>
      _localizedValues[locale.languageCode]?['renameOfflineHint'] ??
      'Device is not connected. The new name will be saved locally now and '
          'pushed to the device on next connection.';
  String get renameInvalid =>
      _localizedValues[locale.languageCode]?['renameInvalid'] ??
      'Invalid name. Use 1-32 characters, no control characters.';
  String get folderNameInvalid =>
      _localizedValues[locale.languageCode]?['folderNameInvalid'] ??
      'Invalid folder name. Use 1-24 characters, no control characters.';
  String get renameSavedOnDevice =>
      _localizedValues[locale.languageCode]?['renameSavedOnDevice'] ??
      'Name updated and saved on device';
  String get renameSavedLocallyWillSync =>
      _localizedValues[locale.languageCode]?['renameSavedLocallyWillSync'] ??
      'Name saved locally; will sync to device on next connection';
  String get renameFailed =>
      _localizedValues[locale.languageCode]?['renameFailed'] ??
      'Rename failed, please try again';
  String renameDeviceRejected(String detail) =>
      (_localizedValues[locale.languageCode]?['renameDeviceRejected'] ??
              'Device rejected the name: {detail}')
          .replaceAll('{detail}', detail);
  String renameAtFailed(String detail) =>
      (_localizedValues[locale.languageCode]?['renameAtFailed'] ??
              'Could not save to device: {detail}')
          .replaceAll('{detail}', detail);
  String get deviceModificationSuccess =>
      _localizedValues[locale.languageCode]?['deviceModificationSuccess'] ??
      'Modification successful';
  String get disconnectDeviceTitle =>
      _localizedValues[locale.languageCode]?['disconnectDeviceTitle'] ??
      'Disconnect Device';
  String get disconnectDeviceMessage =>
      _localizedValues[locale.languageCode]?['disconnectDeviceMessage'] ??
      'This will only break the Bluetooth connection between your phone and SenseCraft Voice. The device remains bound to your account.';
  String get disconnectedSnack =>
      _localizedValues[locale.languageCode]?['disconnectedSnack'] ??
      'Disconnected';
  String get disconnectSentSnack =>
      _localizedValues[locale.languageCode]?['disconnectSentSnack'] ??
      'Disconnected. Device keeps running. You can reconnect anytime.';
  String get resetDeviceTitle =>
      _localizedValues[locale.languageCode]?['resetDeviceTitle'] ??
      'Reset Device';
  String get resetDeviceMessage =>
      _localizedValues[locale.languageCode]?['resetDeviceMessage'] ??
      'This will reset all device parameters to factory defaults.';
  String get resetDoneSnack =>
      _localizedValues[locale.languageCode]?['resetDoneSnack'] ??
      'Reset initiated (Demo)';
  String get resetSentSnack =>
      _localizedValues[locale.languageCode]?['resetSentSnack'] ??
      'Command sent. Device will factory reset and reboot. Connection closed.';
  String get resetConfirm =>
      _localizedValues[locale.languageCode]?['resetConfirm'] ?? 'Reset';
  String get purgeDeviceSessions =>
      _localizedValues[locale.languageCode]?['purgeDeviceSessions'] ??
      'Purge Device Sessions';
  String get purgeDeviceSessionsConfirm =>
      _localizedValues[locale.languageCode]?['purgeDeviceSessionsConfirm'] ??
      'This will permanently delete all recordings on the device. This cannot be undone.';
  String get purging =>
      _localizedValues[locale.languageCode]?['purging'] ?? 'Purging...';
  String get purgeDeviceSessionsDone =>
      _localizedValues[locale.languageCode]?['purgeDeviceSessionsDone'] ??
      'All device sessions deleted';
  String get purgeDeviceSessionsFailed =>
      _localizedValues[locale.languageCode]?['purgeDeviceSessionsFailed'] ??
      'Purge failed, please try again';
  String get purgeDeviceSessionsConnectFirst =>
      _localizedValues[locale.languageCode]
          ?['purgeDeviceSessionsConnectFirst'] ??
      'Please connect this device first to delete recordings on it.';
  String get unbindDeviceTitle =>
      _localizedValues[locale.languageCode]?['unbindDeviceTitle'] ??
      'Unbind Device';
  String get unbindConfirm =>
      _localizedValues[locale.languageCode]?['unbindConfirm'] ?? 'Unbind';
  String get unbindDeviceMessage =>
      _localizedValues[locale.languageCode]?['unbindDeviceMessage'] ??
      'Disconnects if connected, clears pairing on the device when connected, '
          'then removes this device from the app list. '
          'Does not delete recordings on the device.';
  String get unbindIosForgetReminderTitle =>
      _localizedValues[locale.languageCode]?['unbindIosForgetReminderTitle'] ??
      'Device unbound';
  String get unbindIosForgetReminderMessage =>
      _localizedValues[locale.languageCode]
          ?['unbindIosForgetReminderMessage'] ??
      'Pairing on the device has been cleared, but the phone usually still keeps the old Bluetooth record.\n\n'
          'Before you reconnect, open Settings > Bluetooth, find this device, choose Forget / Unpair, then return to the app and add it again.';
  String get unbinding =>
      _localizedValues[locale.languageCode]?['unbinding'] ?? 'Unbinding...';
  String get unbindDoneSnack =>
      _localizedValues[locale.languageCode]?['unbindDoneSnack'] ??
      'Device unbound and removed from app';
  String get recordingModeNormal =>
      _localizedValues[locale.languageCode]?['recordingModeNormal'] ?? 'Normal';
  String get recordingModeEnhanced =>
      _localizedValues[locale.languageCode]?['recordingModeEnhanced'] ??
      'Enhanced';
  // Device details page - refresh & runtime (AT) section
  String get deviceDetailsRefresh =>
      _localizedValues[locale.languageCode]?['deviceDetailsRefresh'] ??
      'Refresh';
  String get deviceDetailsConnectFirstToRefresh =>
      _localizedValues[locale.languageCode]
          ?['deviceDetailsConnectFirstToRefresh'] ??
      'Please connect the device first to refresh.';
  String get deviceDetailsRefreshed =>
      _localizedValues[locale.languageCode]?['deviceDetailsRefreshed'] ??
      'Device info refreshed.';
  String get deviceDetailsRuntimeSectionTitle =>
      _localizedValues[locale.languageCode]
          ?['deviceDetailsRuntimeSectionTitle'] ??
      'Device runtime status (AT)';
  String get deviceDetailsReadingAtInfo =>
      _localizedValues[locale.languageCode]?['deviceDetailsReadingAtInfo'] ??
      'Reading AT info from device…';
  String get deviceDetailsDeviceTime =>
      _localizedValues[locale.languageCode]?['deviceDetailsDeviceTime'] ??
      'Device time';
  String get deviceDetailsWorkState =>
      _localizedValues[locale.languageCode]?['deviceDetailsWorkState'] ??
      'Work state';
  String get deviceDetailsBatteryAt =>
      _localizedValues[locale.languageCode]?['deviceDetailsBatteryAt'] ??
      'Battery (AT)';
  String get deviceDetailsModeAt =>
      _localizedValues[locale.languageCode]?['deviceDetailsModeAt'] ??
      'Mode (AT)';
  String get deviceDetailsPairStatus =>
      _localizedValues[locale.languageCode]?['deviceDetailsPairStatus'] ??
      'Pair status';
  String get deviceDetailsPairAddress =>
      _localizedValues[locale.languageCode]?['deviceDetailsPairAddress'] ??
      'Pair address';
  String get deviceDetailsAtInfoUnavailable =>
      _localizedValues[locale.languageCode]
          ?['deviceDetailsAtInfoUnavailable'] ??
      'Unable to get AT info (device not connected or response timed out).';
  String get deviceDetailsSettingFailedRetry =>
      _localizedValues[locale.languageCode]
          ?['deviceDetailsSettingFailedRetry'] ??
      'Setting failed, please try again later.';
  String get deviceDetailsConnectFirstToReset =>
      _localizedValues[locale.languageCode]
          ?['deviceDetailsConnectFirstToReset'] ??
      'Please connect the device first to reset.';
  String connectingTo(String name) =>
      (_localizedValues[locale.languageCode]?['connectingTo'] ??
              'Connecting to {name}...')
          .replaceAll('{name}', name);
  String connectedTo(String name) =>
      (_localizedValues[locale.languageCode]?['connectedTo'] ??
              'Connected to {name}')
          .replaceAll('{name}', name);
  String get connectionFailedCheck =>
      _localizedValues[locale.languageCode]?['connectionFailedCheck'] ??
      'Connection failed. Please check device status.';
  String get connectionFailedScanAndAdd =>
      _localizedValues[locale.languageCode]?['connectionFailedScanAndAdd'] ??
      'Connection failed. Please scan and add the device manually.';
  String get connectionFailedUnpairHint =>
      _localizedValues[locale.languageCode]?['connectionFailedUnpairHint'] ??
      'If it still fails, open the phone\'s Bluetooth settings, Forget this device, then add it again.';
  String get connectionFailedIosForgetTitle =>
      _localizedValues[locale.languageCode]
          ?['connectionFailedIosForgetTitle'] ??
      'Forget device in Bluetooth settings';
  String get forgetDeviceInSettingsAction =>
      _localizedValues[locale.languageCode]?['forgetDeviceInSettingsAction'] ??
      'Open Settings to Forget';
  String get addDevice =>
      _localizedValues[locale.languageCode]?['addDevice'] ?? 'Add Device';
  String get lastSeenJustNow =>
      _localizedValues[locale.languageCode]?['lastSeenJustNow'] ?? 'just now';
  String lastSeenMinutesAgo(int m) =>
      (_localizedValues[locale.languageCode]?['lastSeenMinutesAgo'] ??
              '{m}m ago')
          .replaceAll('{m}', '$m');
  String lastSeenHoursAgo(int h) =>
      (_localizedValues[locale.languageCode]?['lastSeenHoursAgo'] ?? '{h}h ago')
          .replaceAll('{h}', '$h');
  String lastSeenDaysAgo(int d) =>
      (_localizedValues[locale.languageCode]?['lastSeenDaysAgo'] ?? '{d}d ago')
          .replaceAll('{d}', '$d');
  String get currentLabel =>
      _localizedValues[locale.languageCode]?['currentLabel'] ?? 'CURRENT';
  String get searchingForDevices =>
      _localizedValues[locale.languageCode]?['searchingForDevices'] ??
      'Searching for devices...';
  String get ensureDeviceOn =>
      _localizedValues[locale.languageCode]?['ensureDeviceOn'] ??
      'Please ensure that the device is powered on\nand not bound to other accounts.';
  String get devicesFound =>
      _localizedValues[locale.languageCode]?['devicesFound'] ?? 'DEVICES FOUND';
  String get rescan =>
      _localizedValues[locale.languageCode]?['rescan'] ?? 'RESCAN';
  String get setupHelp =>
      _localizedValues[locale.languageCode]?['setupHelp'] ?? 'Setup Help';
  String get step1 =>
      _localizedValues[locale.languageCode]?['step1'] ?? 'STEP 1';
  String get step2 =>
      _localizedValues[locale.languageCode]?['step2'] ?? 'STEP 2';
  String get longPressRecording =>
      _localizedValues[locale.languageCode]?['longPressRecording'] ??
      'Long press the Recording Button\nuntil the screen lights up.';
  String get bringDeviceClose =>
      _localizedValues[locale.languageCode]?['bringDeviceClose'] ??
      'Bring the device close to your phone.';
  String get keepWithinMeters =>
      _localizedValues[locale.languageCode]?['keepWithinMeters'] ??
      'KEEP WITHIN 0.5 METERS';
  String get needMoreHelp =>
      _localizedValues[locale.languageCode]?['needMoreHelp'] ??
      'Need more help?';
  String get gotItTryAgain =>
      _localizedValues[locale.languageCode]?['gotItTryAgain'] ??
      'Got it, try again';
  String get startUsing =>
      _localizedValues[locale.languageCode]?['startUsing'] ?? 'Start Using';
  String get retry =>
      _localizedValues[locale.languageCode]?['retry'] ?? 'Retry';
  String get connecting =>
      _localizedValues[locale.languageCode]?['connecting'] ?? 'Connecting...';

  /// Android-only hint while the system BLE pairing dialog may be showing.
  String get androidPairingConfirmHint =>
      _localizedValues[locale.languageCode]?['androidPairingConfirmHint'] ??
      'If a system pairing dialog appears, confirm the pairing code to continue.';
  String get connectedSuccessfully =>
      _localizedValues[locale.languageCode]?['connectedSuccessfully'] ??
      'Connected Successfully';
  String get connectionFailed =>
      _localizedValues[locale.languageCode]?['connectionFailed'] ??
      'Connection failed';
  String get firmwareUpdate =>
      _localizedValues[locale.languageCode]?['firmwareUpdate'] ??
      'Firmware Update';
  String get downloadingNewVersion =>
      _localizedValues[locale.languageCode]?['downloadingNewVersion'] ??
      'Downloading New Version...';
  String get installing =>
      _localizedValues[locale.languageCode]?['installing'] ?? 'Installing...';
  String get keepDeviceClose =>
      _localizedValues[locale.languageCode]?['keepDeviceClose'] ??
      'Keep the device close and Bluetooth\nconnected.';
  String get doNotTurnOffDuringInstall =>
      _localizedValues[locale.languageCode]?['doNotTurnOffDuringInstall'] ??
      'Do not turn off your device or close the app during\nthe installation process to ensure firmware\nintegrity.';
  String get remaining =>
      _localizedValues[locale.languageCode]?['remaining'] ?? '~4 min remaining';
  String lastSeenLabel(String timePart) =>
      (_localizedValues[locale.languageCode]?['lastSeenLabel'] ??
              'Last seen {time}')
          .replaceAll('{time}', timePart);
  String get snLabel =>
      _localizedValues[locale.languageCode]?['snLabel'] ?? 'SN';
  String get deviceProtocolSummary =>
      _localizedValues[locale.languageCode]?['deviceProtocolSummary'] ??
      'Protocol: Clip AT over BLE(GATT)\n- Service=6E400001...\n- Command(Write)=6E400002...\n- Response/Progress(Notify)=6E400003...\n- FileData(Notify)=6E400004...';
  String deviceMtuLabel(int mtu, int payload) =>
      (_localizedValues[locale.languageCode]?['deviceMtuLabel'] ??
              'Current MTU: {mtu} (payload ≈ {payload} bytes)')
          .replaceAll('{mtu}', '$mtu')
          .replaceAll('{payload}', '$payload');
  String get canNotFindDevice =>
      _localizedValues[locale.languageCode]?['canNotFindDevice'] ??
      "Can't find your device?";
  String get notLightingUpHint =>
      _localizedValues[locale.languageCode]?['notLightingUpHint'] ??
      "Not lighting up? Charge for 10 mins and try again.";
  String get defaultDeviceName =>
      _localizedValues[locale.languageCode]?['defaultDeviceName'] ??
      'SenseCraft Voice Lav';
  String get connectionFailedTryAgain =>
      _localizedValues[locale.languageCode]?['connectionFailedTryAgain'] ??
      'Please check device status. Make sure the device is powered on and within range.';
  String get scanningChip =>
      _localizedValues[locale.languageCode]?['scanningChip'] ?? 'SCANNING';
  String get firmwareUpToDate =>
      _localizedValues[locale.languageCode]?['firmwareUpToDate'] ??
      'Firmware is up to date';
  String versionColon(String v) =>
      (_localizedValues[locale.languageCode]?['versionColon'] ?? 'version: {v}')
          .replaceAll('{v}', v);
  String get newFirmwareTitle =>
      _localizedValues[locale.languageCode]?['newFirmwareTitle'] ??
      'New Firmware';
  String get newFeaturesTitle =>
      _localizedValues[locale.languageCode]?['newFeaturesTitle'] ??
      'New Features';
  String get systemCheckTitle =>
      _localizedValues[locale.languageCode]?['systemCheckTitle'] ??
      'SYSTEM CHECK';
  String get downloadUpdateNow =>
      _localizedValues[locale.languageCode]?['downloadUpdateNow'] ??
      'Download Update Now';
  String get laterButton =>
      _localizedValues[locale.languageCode]?['laterButton'] ?? 'Later';
  String newFirmwareVersion(String v) =>
      (_localizedValues[locale.languageCode]?['newFirmwareVersion'] ??
              'New Firmware: {v}')
          .replaceAll('{v}', v);
  String get updateSuccessfulTitle =>
      _localizedValues[locale.languageCode]?['updateSuccessfulTitle'] ??
      'Update Successful';
  String updateSuccessfulMessage(String version) => (_localizedValues[
              locale.languageCode]?['updateSuccessfulMessage'] ??
          'Your SenseCraft Voice has been updated to the latest version {version}.')
      .replaceAll('{version}', version);
  String get updateSuccessfulMessageWait =>
      _localizedValues[locale.languageCode]?['updateSuccessfulMessageWait'] ??
      'Your device has been upgraded to the latest. Please wait for the device to complete the upgrade.';
  String get updateFailedTitle =>
      _localizedValues[locale.languageCode]?['updateFailedTitle'] ??
      'Update Failed';
  String get updateFailedMessage =>
      _localizedValues[locale.languageCode]?['updateFailedMessage'] ??
      'Upgrade failed. Please keep Bluetooth connected and try again later.';
  String get backToDevice =>
      _localizedValues[locale.languageCode]?['backToDevice'] ??
      'Back to Device';
  String get batteryCheckLabel =>
      _localizedValues[locale.languageCode]?['batteryCheckLabel'] ??
      'Charging or battery ≥ 50%';
  String get notRecordingLabel =>
      _localizedValues[locale.languageCode]?['notRecordingLabel'] ??
      'Not Recording';
  String get deviceConnectedLabel =>
      _localizedValues[locale.languageCode]?['deviceConnectedLabel'] ??
      'Device Connected';
  String get firmwareLabel =>
      _localizedValues[locale.languageCode]?['firmwareLabel'] ?? 'Firmware';
  String get selectFirmwareFile =>
      _localizedValues[locale.languageCode]?['selectFirmwareFile'] ??
      'Select Firmware File (ZIP/BIN)';
  String get startFirmwareUpdate =>
      _localizedValues[locale.languageCode]?['startFirmwareUpdate'] ??
      'Start Firmware Update';
  String get uploadingFirmware =>
      _localizedValues[locale.languageCode]?['uploadingFirmware'] ??
      'Uploading firmware...';
  String get otaCompleting =>
      _localizedValues[locale.languageCode]?['otaCompleting'] ??
      'Completing, please wait...';
  String get otaDeviceNotConnected =>
      _localizedValues[locale.languageCode]?['otaDeviceNotConnected'] ??
      'Please connect the device first to perform firmware update.';
  String get cloudFirmwareTitle =>
      _localizedValues[locale.languageCode]?['cloudFirmwareTitle'] ??
      'CLOUD UPDATE';
  String get cloudFirmwareChecking =>
      _localizedValues[locale.languageCode]?['cloudFirmwareChecking'] ??
      'Checking for updates...';
  String get cloudFirmwareCheckAgain =>
      _localizedValues[locale.languageCode]?['cloudFirmwareCheckAgain'] ??
      'Check again';
  String get cloudFirmwareCheckFailed =>
      _localizedValues[locale.languageCode]?['cloudFirmwareCheckFailed'] ??
      'Failed to check for updates';
  String get cloudFirmwareDownloading =>
      _localizedValues[locale.languageCode]?['cloudFirmwareDownloading'] ??
      'Downloading firmware...';
  String get downloadFirmwareButton =>
      _localizedValues[locale.languageCode]?['downloadFirmwareButton'] ??
      'Download Firmware';
  String get firmwareDownloadedReady =>
      _localizedValues[locale.languageCode]?['firmwareDownloadedReady'] ??
      'Firmware downloaded, ready to install.';
  String get firmwareMustUpdate =>
      _localizedValues[locale.languageCode]?['firmwareMustUpdate'] ??
      'REQUIRED UPDATE';
  String get localFirmwareTitle =>
      _localizedValues[locale.languageCode]?['localFirmwareTitle'] ??
      'LOCAL FILE';
  String get selectFirmwareFileAgain =>
      _localizedValues[locale.languageCode]?['selectFirmwareFileAgain'] ??
      'Choose another file';
  String get fromCloudLabel =>
      _localizedValues[locale.languageCode]?['fromCloudLabel'] ?? 'From cloud';
  String get fromLocalLabel =>
      _localizedValues[locale.languageCode]?['fromLocalLabel'] ?? 'Local file';
  String get cancelButton =>
      _localizedValues[locale.languageCode]?['cancelButton'] ?? 'Cancel';
  String get cloudFirmwareNoPermission =>
      _localizedValues[locale.languageCode]?['cloudFirmwareNoPermission'] ??
      'Your account does not have permission to check cloud firmware updates. You can still install a local firmware file.';
  String get cloudFirmwareInvalidToken =>
      _localizedValues[locale.languageCode]?['cloudFirmwareInvalidToken'] ??
      'Cloud firmware check failed (invalid login session). Try signing out and back in, or use a local firmware file.';

  // Recording - extra
  String get deviceRecordingNoPauseResume =>
      _localizedValues[locale.languageCode]?['deviceRecordingNoPauseResume'] ??
      'Device recording does not support pause/resume yet.';
  String playbackSpeedTimes(String s) =>
      (_localizedValues[locale.languageCode]?['playbackSpeedTimes'] ?? '{s}x')
          .replaceAll('{s}', s);
  String get trimTimeZero =>
      _localizedValues[locale.languageCode]?['trimTimeZero'] ?? '0:00';

  // AI Config - extra
  String get providerLabel =>
      _localizedValues[locale.languageCode]?['providerLabel'] ?? 'Provider';
  String get hintModelExample =>
      _localizedValues[locale.languageCode]?['hintModelExample'] ??
      'e.g., gpt-4o';
  String get hintJsonExample =>
      _localizedValues[locale.languageCode]?['hintJsonExample'] ??
      '{"foo":"bar"}';
  String savedLocalSyncFailed(String error) =>
      (_localizedValues[locale.languageCode]?['savedLocalSyncFailed'] ??
              'Saved locally, server sync failed: {error}')
          .replaceAll('{error}', error);
  String get deleteConfigurationTitle =>
      _localizedValues[locale.languageCode]?['deleteConfigurationTitle'] ??
      'Delete Configuration';
  String deleteConfigurationConfirm(String name) =>
      (_localizedValues[locale.languageCode]?['deleteConfigurationConfirm'] ??
              'Are you sure you want to delete "{name}"?')
          .replaceAll('{name}', name);
  String deletedLocalDeleteFailed(String error) =>
      (_localizedValues[locale.languageCode]?['deletedLocalDeleteFailed'] ??
              'Deleted locally, server delete failed: {error}')
          .replaceAll('{error}', error);
  String get llmProviders =>
      _localizedValues[locale.languageCode]?['llmProviders'] ?? 'LLM Providers';
  String get sttProviders =>
      _localizedValues[locale.languageCode]?['sttProviders'] ?? 'STT Providers';
  String get noProvidersYet =>
      _localizedValues[locale.languageCode]?['noProvidersYet'] ??
      'No providers configured yet';
  String get addLlmConfigSubtitle =>
      _localizedValues[locale.languageCode]?['addLlmConfigSubtitle'] ??
      'Add an LLM configuration to enable summary generation.';
  String get addSttConfigSubtitle =>
      _localizedValues[locale.languageCode]?['addSttConfigSubtitle'] ??
      'Add an STT configuration to enable transcription.';
  String get addNewConfiguration =>
      _localizedValues[locale.languageCode]?['addNewConfiguration'] ??
      'Add New Configuration';
  String get saveConfiguration =>
      _localizedValues[locale.languageCode]?['saveConfiguration'] ??
      'Save Configuration';
  String get pleaseAddLlm =>
      _localizedValues[locale.languageCode]?['pleaseAddLlm'] ??
      'Please add your LLM configuration.';
  String get pleaseAddStt =>
      _localizedValues[locale.languageCode]?['pleaseAddStt'] ??
      'Please add your STT configuration.';
  String get getStarted =>
      _localizedValues[locale.languageCode]?['getStarted'] ?? 'Get Started';
  String get llmConfigurationTitle =>
      _localizedValues[locale.languageCode]?['llmConfigurationTitle'] ??
      'LLM Configuration';
  String get llmConfigurationSubtitle =>
      _localizedValues[locale.languageCode]?['llmConfigurationSubtitle'] ??
      'Large Language Model settings';
  String get llmProviderTitle =>
      _localizedValues[locale.languageCode]?['llmProviderTitle'] ??
      'LLM Provider';
  String get sttConfigurationTitle =>
      _localizedValues[locale.languageCode]?['sttConfigurationTitle'] ??
      'STT Configuration';
  String get sttConfigurationSubtitle =>
      _localizedValues[locale.languageCode]?['sttConfigurationSubtitle'] ??
      'Speech-to-Text service settings';
  String get sttProviderTitle =>
      _localizedValues[locale.languageCode]?['sttProviderTitle'] ??
      'STT Provider';
  String get addConfiguration =>
      _localizedValues[locale.languageCode]?['addConfiguration'] ??
      'Add Configuration';
  String get finishSetup =>
      _localizedValues[locale.languageCode]?['finishSetup'] ?? 'Finish Setup';
  String get sttProviderChip =>
      _localizedValues[locale.languageCode]?['sttProviderChip'] ??
      'STT PROVIDER';
  String get llmProviderChip =>
      _localizedValues[locale.languageCode]?['llmProviderChip'] ??
      'LLM PROVIDER';
  String get templatesTitle =>
      _localizedValues[locale.languageCode]?['templatesTitle'] ?? 'Templates';
  String get addNewTemplate =>
      _localizedValues[locale.languageCode]?['addNewTemplate'] ??
      'Add New Template';
  String get createTemplate =>
      _localizedValues[locale.languageCode]?['createTemplate'] ??
      'Create Template';
  String get hintMeetingMinutes =>
      _localizedValues[locale.languageCode]?['hintMeetingMinutes'] ??
      'e.g., Meeting Minutes';
  String get hintEnterPrompt =>
      _localizedValues[locale.languageCode]?['hintEnterPrompt'] ??
      'Enter prompt...';
  String get importTemplate =>
      _localizedValues[locale.languageCode]?['importTemplate'] ??
      'Import Template';
  String get hintShareKey =>
      _localizedValues[locale.languageCode]?['hintShareKey'] ??
      'e.g. xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx';
  String get importAction =>
      _localizedValues[locale.languageCode]?['importAction'] ?? 'Import';
  String get invalidKeyOrSharingStopped =>
      _localizedValues[locale.languageCode]?['invalidKeyOrSharingStopped'] ??
      'Invalid key or sharing stopped.';
  String importFailed(String error) =>
      (_localizedValues[locale.languageCode]?['importFailed'] ??
              'Import failed: {error}')
          .replaceAll('{error}', error);
  String get templateDetails =>
      _localizedValues[locale.languageCode]?['templateDetails'] ??
      'Template Details';
  String get notFound =>
      _localizedValues[locale.languageCode]?['notFound'] ?? 'Not found';
  String get templateNameHint =>
      _localizedValues[locale.languageCode]?['templateNameHint'] ??
      'Template name';
  String get promptHint =>
      _localizedValues[locale.languageCode]?['promptHint'] ?? 'Prompt...';
  String stopSharingFailed(String error) =>
      (_localizedValues[locale.languageCode]?['stopSharingFailed'] ??
              'Stop sharing failed: {error}')
          .replaceAll('{error}', error);
  String get generateShareKey =>
      _localizedValues[locale.languageCode]?['generateShareKey'] ??
      'Generate Share Key';
  String get copied =>
      _localizedValues[locale.languageCode]?['copied'] ?? 'Copied';
  String get saveChanges =>
      _localizedValues[locale.languageCode]?['saveChanges'] ?? 'Save Changes';
  String get deleteTemplateTitle =>
      _localizedValues[locale.languageCode]?['deleteTemplateTitle'] ??
      'Delete Template';
  String deleteTemplateConfirm(String name) =>
      (_localizedValues[locale.languageCode]?['deleteTemplateConfirm'] ??
              'Are you sure you want to delete "{name}"?')
          .replaceAll('{name}', name);
  String get importWithKey =>
      _localizedValues[locale.languageCode]?['importWithKey'] ??
      'Import with Key';
  String get templateKey =>
      _localizedValues[locale.languageCode]?['templateKey'] ?? 'TEMPLATE KEY';
  String get hintWhisperExample =>
      _localizedValues[locale.languageCode]?['hintWhisperExample'] ??
      'e.g., whisper-1';
  String get hintWssUrl =>
      _localizedValues[locale.languageCode]?['hintWssUrl'] ?? 'wss://';
  String get hintBaseUrlExample =>
      _localizedValues[locale.languageCode]?['hintBaseUrlExample'] ??
      'e.g., http://localhost:10095';
  String get hintBaseUrlExampleHttps =>
      _localizedValues[locale.languageCode]?['hintBaseUrlExampleHttps'] ??
      'e.g., https://api.openai.com';
  String get hintRegionExample =>
      _localizedValues[locale.languageCode]?['hintRegionExample'] ??
      'e.g., cn-hangzhou';
  String get hintModelPathExample =>
      _localizedValues[locale.languageCode]?['hintModelPathExample'] ??
      'e.g., /path/to/model.bin';
  String get hintIflytekApiSecret =>
      _localizedValues[locale.languageCode]?['hintIflytekApiSecret'] ??
      'APISecret from xfyun.cn (接口密钥)';
  String get hintAliyunTingwuAppKey =>
      _localizedValues[locale.languageCode]?['hintAliyunTingwuAppKey'] ??
      'Tingwu AppKey';
  String get hintAliyunAccessKeyId =>
      _localizedValues[locale.languageCode]?['hintAliyunAccessKeyId'] ??
      'AccessKey ID';
  String get hintAliyunAccessKeySecret =>
      _localizedValues[locale.languageCode]?['hintAliyunAccessKeySecret'] ??
      'AccessKey Secret';
  String get hintLocalhostVosk =>
      _localizedValues[locale.languageCode]?['hintLocalhostVosk'] ??
      'http://localhost:2700';
  String get hintLocalhostLocalWhisper =>
      _localizedValues[locale.languageCode]?['hintLocalhostLocalWhisper'] ??
      'http://localhost:8080';
  String get hintIflytekAppId =>
      _localizedValues[locale.languageCode]?['hintIflytekAppId'] ?? 'APPID';
  String get hintLlmDoubaoModelName =>
      _localizedValues[locale.languageCode]?['hintLlmDoubaoModelName'] ??
      'Optional. Leave empty for the default; enter an endpoint ID (ep-xxx) or a model ID (e.g. doubao-seed-2-0-pro-260215)';
  String get hintLlmOpenRouterModelName =>
      _localizedValues[locale.languageCode]?['hintLlmOpenRouterModelName'] ??
      'e.g. anthropic/claude-sonnet-4, google/gemini-2.5-flash, openai/gpt-4o. See openrouter.ai/models';
  String get hintLlmOpenAiModelName =>
      _localizedValues[locale.languageCode]?['hintLlmOpenAiModelName'] ??
      'e.g. gpt-4o, gpt-4o-mini';
  String get hintLlmAnthropicModelName =>
      _localizedValues[locale.languageCode]?['hintLlmAnthropicModelName'] ??
      'e.g. claude-sonnet-4-0, claude-3-5-haiku-latest';
  String get hintLlmGoogleGeminiModelName =>
      _localizedValues[locale.languageCode]?['hintLlmGoogleGeminiModelName'] ??
      'e.g. gemini-2.5-flash, gemini-2.0-flash';
  String get hintLlmQwenModelName =>
      _localizedValues[locale.languageCode]?['hintLlmQwenModelName'] ??
      'e.g. qwen-turbo, qwen-plus';
  String get hintLlmDeepseekModelName =>
      _localizedValues[locale.languageCode]?['hintLlmDeepseekModelName'] ??
      'e.g. deepseek-chat, deepseek-reasoner';
  String get hintLlmLlamaModelName =>
      _localizedValues[locale.languageCode]?['hintLlmLlamaModelName'] ??
      'Model name on your Ollama / local server';
  String get hintLlmCustomBaseUrl =>
      _localizedValues[locale.languageCode]?['hintLlmCustomBaseUrl'] ??
      'e.g. http://localhost:11434/v1';
  String get hintLlmQwenApiKey =>
      _localizedValues[locale.languageCode]?['hintLlmQwenApiKey'] ??
      'DashScope API Key (dashscope.console.aliyun.com)';
  String get hintLlmDeepseekApiKey =>
      _localizedValues[locale.languageCode]?['hintLlmDeepseekApiKey'] ??
      'sk-... from platform.deepseek.com';
  String get hintLlmOpenAiApiKey =>
      _localizedValues[locale.languageCode]?['hintLlmOpenAiApiKey'] ??
      'sk-... from platform.openai.com';
  String get hintLlmAnthropicApiKey =>
      _localizedValues[locale.languageCode]?['hintLlmAnthropicApiKey'] ??
      'sk-ant-... from console.anthropic.com';
  String get hintLlmGoogleGeminiApiKey =>
      _localizedValues[locale.languageCode]?['hintLlmGoogleGeminiApiKey'] ??
      'API key from aistudio.google.com';
  String get hintLlmDoubaoApiKey =>
      _localizedValues[locale.languageCode]?['hintLlmDoubaoApiKey'] ??
      'API key from Volcengine Ark console';
  String get hintLlmOpenRouterApiKey =>
      _localizedValues[locale.languageCode]?['hintLlmOpenRouterApiKey'] ??
      'API key from openrouter.ai/keys';
  String get hintLlmLlamaApiKey =>
      _localizedValues[locale.languageCode]?['hintLlmLlamaApiKey'] ??
      'Optional for local Ollama';
  String get hintLlmModelCaption =>
      _localizedValues[locale.languageCode]?['hintLlmModelCaption'] ??
      'LLM model for summary generation. Not the same as STT / transcription models.';
  String get hintLlmQwenModelCaption =>
      _localizedValues[locale.languageCode]?['hintLlmQwenModelCaption'] ??
      'Use qwen-turbo or qwen-plus for summaries. Do not use fun-asr-realtime (that is STT only).';
  String get hintLlmDeepseekModelCaption =>
      _localizedValues[locale.languageCode]?['hintLlmDeepseekModelCaption'] ??
      'Use deepseek-chat for summaries. Base URL must be api.deepseek.com/v1, not the platform web page.';
  String get hintSttModelCaption =>
      _localizedValues[locale.languageCode]?['hintSttModelCaption'] ??
      'Speech-to-text model. For AI summaries configure a separate LLM service.';
  String get hintSttAliyunModelCaption =>
      _localizedValues[locale.languageCode]?['hintSttAliyunModelCaption'] ??
      'Transcription only: fun-asr-realtime. Summaries use LLM config with qwen-turbo.';
  String get hintSttBaiduModelName =>
      _localizedValues[locale.languageCode]?['hintSttBaiduModelName'] ??
      'Leave empty for default or see Baidu ASR docs';
  String get hintSttTencentModelName =>
      _localizedValues[locale.languageCode]?['hintSttTencentModelName'] ??
      'Leave empty for default or see Tencent ASR docs';
  String get hintSttDoubaoModelName =>
      _localizedValues[locale.languageCode]?['hintSttDoubaoModelName'] ??
      'See Volcengine ASR docs';

  // Guide flow
  String get guideWelcomeTitle =>
      _localizedValues[locale.languageCode]?['guideWelcomeTitle'] ?? 'Welcome!';
  String get guideWelcomeSubtitle =>
      _localizedValues[locale.languageCode]?['guideWelcomeSubtitle'] ??
      "Let's configure your AI services to\nenable voice transcription and\nsmart summaries.";
  String get guideSttServiceTitle =>
      _localizedValues[locale.languageCode]?['guideSttServiceTitle'] ??
      'STT Service';
  String get guideSttServiceSubtitle =>
      _localizedValues[locale.languageCode]?['guideSttServiceSubtitle'] ??
      'Convert voice to text in real-time';
  String get guideLlmServiceTitle =>
      _localizedValues[locale.languageCode]?['guideLlmServiceTitle'] ??
      'LLM Service';
  String get guideLlmServiceSubtitle =>
      _localizedValues[locale.languageCode]?['guideLlmServiceSubtitle'] ??
      'Extract key points and summaries';
  String get guideBackLabel =>
      _localizedValues[locale.languageCode]?['guideBackLabel'] ?? 'Back';
  String get guideNextStepLabel =>
      _localizedValues[locale.languageCode]?['guideNextStepLabel'] ??
      'Next Step';
  String get guideAddEditLaterHint =>
      _localizedValues[locale.languageCode]?['guideAddEditLaterHint'] ??
      'You can add/edit configurations later in AI Configuration.';
  String get guideAllSetTitle =>
      _localizedValues[locale.languageCode]?['guideAllSetTitle'] ?? 'All Set!';
  String get guideAllSetSubtitle =>
      _localizedValues[locale.languageCode]?['guideAllSetSubtitle'] ??
      'Your AI services are ready to go.';
  String get guideSttProviderLabel =>
      _localizedValues[locale.languageCode]?['guideSttProviderLabel'] ??
      'STT PROVIDER';
  String get guideLlmProviderLabel =>
      _localizedValues[locale.languageCode]?['guideLlmProviderLabel'] ??
      'LLM PROVIDER';
  String get guideUpdateLaterHint =>
      _localizedValues[locale.languageCode]?['guideUpdateLaterHint'] ??
      "You can always update these settings later from the\napp's settings menu.";

  // Template labels (field headers)
  String get templateNameLabel =>
      _localizedValues[locale.languageCode]?['templateNameLabel'] ??
      'TEMPLATE NAME';
  String get promptContentLabel =>
      _localizedValues[locale.languageCode]?['promptContentLabel'] ??
      'PROMPT CONTENT';
  String get tapTemplateToEdit =>
      _localizedValues[locale.languageCode]?['tapTemplateToEdit'] ??
      'Tap any template to edit name and prompt details.';
  String get enterKeyToImport =>
      _localizedValues[locale.languageCode]?['enterKeyToImport'] ??
      'Enter the key shared by others to import';
  String get shareTemplateLabel =>
      _localizedValues[locale.languageCode]?['shareTemplateLabel'] ??
      'SHARE TEMPLATE';
  String get stopSharingLabel =>
      _localizedValues[locale.languageCode]?['stopSharingLabel'] ??
      'Stop Sharing';
  String get shareKeyDescription =>
      _localizedValues[locale.languageCode]?['shareKeyDescription'] ??
      'Share this key with others to let them import your custom prompt configuration.';

  // AI Config editor labels
  String get configuredFilesLabel =>
      _localizedValues[locale.languageCode]?['configuredFilesLabel'] ??
      'CONFIGURED FILES';
  String get addTooltip =>
      _localizedValues[locale.languageCode]?['addTooltip'] ?? 'Add';
  String get apiKeyConfigDetails =>
      _localizedValues[locale.languageCode]?['apiKeyConfigDetails'] ??
      'API Key Configuration Details';
  String get requiredLabel =>
      _localizedValues[locale.languageCode]?['requiredLabel'] ?? 'REQUIRED';
  String get optionalLabel =>
      _localizedValues[locale.languageCode]?['optionalLabel'] ?? 'OPTIONAL';
  String get advancedLabel =>
      _localizedValues[locale.languageCode]?['advancedLabel'] ?? 'Advanced';
  String get testConnection =>
      _localizedValues[locale.languageCode]?['testConnection'] ??
      'Test Connection';
  String get testConnectionSuccess =>
      _localizedValues[locale.languageCode]?['testConnectionSuccess'] ??
      'Test Connection ✓';
  String testFailed(String error) =>
      (_localizedValues[locale.languageCode]?['testFailed'] ??
              'Test failed: {error}')
          .replaceAll('{error}', error);

  // AI Config editor field labels (LLM/STT dialogs)
  String get fieldLabelProvider =>
      _localizedValues[locale.languageCode]?['fieldLabelProvider'] ??
      'PROVIDER';
  String get fieldLabelName =>
      _localizedValues[locale.languageCode]?['fieldLabelName'] ?? 'NAME';
  String get fieldLabelApiKey =>
      _localizedValues[locale.languageCode]?['fieldLabelApiKey'] ?? 'API KEY';
  String get fieldLabelApiKeyOptional =>
      _localizedValues[locale.languageCode]?['fieldLabelApiKeyOptional'] ??
      'API KEY (OPTIONAL)';
  String get fieldLabelApiKeyRequired =>
      _localizedValues[locale.languageCode]?['fieldLabelApiKeyRequired'] ??
      'API KEY (REQUIRED)';
  String get fieldLabelBaseUrl =>
      _localizedValues[locale.languageCode]?['fieldLabelBaseUrl'] ?? 'BASE URL';
  String get fieldLabelBaseUrlRequired =>
      _localizedValues[locale.languageCode]?['fieldLabelBaseUrlRequired'] ??
      'BASE URL (REQUIRED)';
  String get fieldLabelBaseUrlOptional =>
      _localizedValues[locale.languageCode]?['fieldLabelBaseUrlOptional'] ??
      'BASE URL (OPTIONAL)';
  String get fieldLabelModelName =>
      _localizedValues[locale.languageCode]?['fieldLabelModelName'] ??
      'MODEL NAME';
  String get fieldLabelModelNameOptional =>
      _localizedValues[locale.languageCode]?['fieldLabelModelNameOptional'] ??
      'MODEL NAME (OPTIONAL)';
  String get fieldLabelModelNameRequired =>
      _localizedValues[locale.languageCode]?['fieldLabelModelNameRequired'] ??
      'MODEL NAME (REQUIRED)';
  String get fieldLabelModelNameAdvanced =>
      _localizedValues[locale.languageCode]?['fieldLabelModelNameAdvanced'] ??
      'MODEL NAME (ADVANCED)';
  String get fieldLabelModuleNameOptional =>
      _localizedValues[locale.languageCode]?['fieldLabelModuleNameOptional'] ??
      'MODULE NAME (OPTIONAL)';
  String get fieldLabelApiSecret =>
      _localizedValues[locale.languageCode]?['fieldLabelApiSecret'] ??
      'API SECRET';
  String get fieldLabelApiSecretOptional =>
      _localizedValues[locale.languageCode]?['fieldLabelApiSecretOptional'] ??
      'API SECRET (OPTIONAL)';
  String get fieldLabelAppId =>
      _localizedValues[locale.languageCode]?['fieldLabelAppId'] ?? 'APP ID';
  String get fieldLabelAppIdOptional =>
      _localizedValues[locale.languageCode]?['fieldLabelAppIdOptional'] ??
      'APP ID (OPTIONAL)';
  String get fieldLabelAppIdRequired =>
      _localizedValues[locale.languageCode]?['fieldLabelAppIdRequired'] ??
      'APP ID (REQUIRED)';
  String get fieldLabelAccessKeyId =>
      _localizedValues[locale.languageCode]?['fieldLabelAccessKeyId'] ??
      'ACCESS KEY ID';
  String get fieldLabelAccessKeyIdOptional =>
      _localizedValues[locale.languageCode]?['fieldLabelAccessKeyIdOptional'] ??
      'ACCESS KEY ID (OPTIONAL)';
  String get fieldLabelAccessKeySecret =>
      _localizedValues[locale.languageCode]?['fieldLabelAccessKeySecret'] ??
      'ACCESS KEY SECRET';
  String get fieldLabelAccessKeySecretOptional =>
      _localizedValues[locale.languageCode]
          ?['fieldLabelAccessKeySecretOptional'] ??
      'ACCESS KEY SECRET (OPTIONAL)';
  String get fieldLabelRegion =>
      _localizedValues[locale.languageCode]?['fieldLabelRegion'] ?? 'REGION';
  String get fieldLabelRegionOptional =>
      _localizedValues[locale.languageCode]?['fieldLabelRegionOptional'] ??
      'REGION (OPTIONAL)';
  String get fieldLabelExtraJsonAdvanced =>
      _localizedValues[locale.languageCode]?['fieldLabelExtraJsonAdvanced'] ??
      'EXTRA JSON (ADVANCED)';
  String get fieldLabelWsUrlOptional =>
      _localizedValues[locale.languageCode]?['fieldLabelWsUrlOptional'] ??
      'WS URL (OPTIONAL)';
  String get fieldLabelSecretKey =>
      _localizedValues[locale.languageCode]?['fieldLabelSecretKey'] ??
      'SECRET KEY';
  String get fieldLabelSecretKeyOptional =>
      _localizedValues[locale.languageCode]?['fieldLabelSecretKeyOptional'] ??
      'SECRET KEY (OPTIONAL)';
  String get fieldLabelSecretKeyRequired =>
      _localizedValues[locale.languageCode]?['fieldLabelSecretKeyRequired'] ??
      'SECRET KEY (REQUIRED)';
  String get fieldLabelSecretId =>
      _localizedValues[locale.languageCode]?['fieldLabelSecretId'] ??
      'SECRET ID';
  String get fieldLabelSecretIdOptional =>
      _localizedValues[locale.languageCode]?['fieldLabelSecretIdOptional'] ??
      'SECRET ID (OPTIONAL)';
  String get fieldLabelSecretIdRequired =>
      _localizedValues[locale.languageCode]?['fieldLabelSecretIdRequired'] ??
      'SECRET ID (REQUIRED)';
  String get aliyunCredentialChoiceHint =>
      _localizedValues[locale.languageCode]?['aliyunCredentialChoiceHint'] ??
      'Fill in either API KEY (DashScope) OR App Key + Secret ID + Secret Key (Tingwu). Either set is enough.';
  String get fieldLabelAliyunApiKeyChoice =>
      _localizedValues[locale.languageCode]?['fieldLabelAliyunApiKeyChoice'] ??
      'API KEY (DASHSCOPE, OR USE TINGWU BELOW)';
  String get fieldLabelAliyunAppKeyChoice =>
      _localizedValues[locale.languageCode]?['fieldLabelAliyunAppKeyChoice'] ??
      'APP KEY (TINGWU, REQUIRED WITH ACCESS KEY)';
  String get fieldLabelAliyunAccessKeyIdChoice =>
      _localizedValues[locale.languageCode]
          ?['fieldLabelAliyunAccessKeyIdChoice'] ??
      'ACCESS KEY ID (TINGWU, REQUIRED WITH APP KEY)';
  String get fieldLabelAliyunAccessKeySecretChoice =>
      _localizedValues[locale.languageCode]
          ?['fieldLabelAliyunAccessKeySecretChoice'] ??
      'ACCESS KEY SECRET (TINGWU, REQUIRED WITH APP KEY)';
  String get fieldLabelCluster =>
      _localizedValues[locale.languageCode]?['fieldLabelCluster'] ?? 'CLUSTER';
  String get fieldLabelClusterRequired =>
      _localizedValues[locale.languageCode]?['fieldLabelClusterRequired'] ??
      'CLUSTER (REQUIRED)';
  String get fieldLabelAccessToken =>
      _localizedValues[locale.languageCode]?['fieldLabelAccessToken'] ??
      'ACCESS TOKEN';
  String get fieldLabelAccessTokenRequired =>
      _localizedValues[locale.languageCode]?['fieldLabelAccessTokenRequired'] ??
      'ACCESS TOKEN (REQUIRED)';
  String get fieldLabelModelPath =>
      _localizedValues[locale.languageCode]?['fieldLabelModelPath'] ??
      'MODEL PATH';
  String get fieldLabelLanguage =>
      _localizedValues[locale.languageCode]?['fieldLabelLanguage'] ??
      'LANGUAGE';

  // iFlytek transcription mode
  String get fieldLabelTranscriptionMode =>
      _localizedValues[locale.languageCode]?['fieldLabelTranscriptionMode'] ??
      'TRANSCRIPTION MODE';
  String get iflytekModeFile =>
      _localizedValues[locale.languageCode]?['iflytekModeFile'] ??
      'File transcription (recommended, record first)';
  String get iflytekModeRealtime =>
      _localizedValues[locale.languageCode]?['iflytekModeRealtime'] ??
      'Realtime transcription';
  String get iflytekFileHint =>
      _localizedValues[locale.languageCode]?['iflytekFileHint'] ??
      'Console → 录音文件转写标准版';
  String get iflytekRealtimeHint =>
      _localizedValues[locale.languageCode]?['iflytekRealtimeHint'] ??
      'Console → 实时语音转写标准版';
  String get validationIflytekSecretKeyForFile =>
      _localizedValues[locale.languageCode]
          ?['validationIflytekSecretKeyForFile'] ??
      'SecretKey required for file transcription';

  // AI Config validation messages
  String get validationNameRequired =>
      _localizedValues[locale.languageCode]?['validationNameRequired'] ??
      'name required';
  String get validationApiKeyRequired =>
      _localizedValues[locale.languageCode]?['validationApiKeyRequired'] ??
      'API KEY required';
  String get validationAliyunCredentialRequired =>
      _localizedValues[locale.languageCode]
          ?['validationAliyunCredentialRequired'] ??
      'Fill in DashScope API KEY, or complete Tingwu credentials.';
  String get validationApiKeyRequiredLlc =>
      _localizedValues[locale.languageCode]?['validationApiKeyRequiredLlc'] ??
      'API key required';
  String get validationInvalidWsUrl =>
      _localizedValues[locale.languageCode]?['validationInvalidWsUrl'] ??
      'invalid WS URL';
  String get validationBaseUrlRequired =>
      _localizedValues[locale.languageCode]?['validationBaseUrlRequired'] ??
      'BASE URL required';
  String get validationAppIdRequired =>
      _localizedValues[locale.languageCode]?['validationAppIdRequired'] ??
      'APP ID required';
  String get validationSecretKeyRequired =>
      _localizedValues[locale.languageCode]?['validationSecretKeyRequired'] ??
      'SECRET KEY required';
  String get validationSecretIdRequired =>
      _localizedValues[locale.languageCode]?['validationSecretIdRequired'] ??
      'SECRET ID required';
  String get validationClusterAccessTokenRequired =>
      _localizedValues[locale.languageCode]
          ?['validationClusterAccessTokenRequired'] ??
      'CLUSTER and ACCESS TOKEN required';
  String get validationExtraJsonMustBeObject =>
      _localizedValues[locale.languageCode]
          ?['validationExtraJsonMustBeObject'] ??
      'EXTRA JSON must be an object';
  String get validationExtraJsonMustBeValid =>
      _localizedValues[locale.languageCode]
          ?['validationExtraJsonMustBeValid'] ??
      'EXTRA JSON must be valid JSON';
  String get validationAccessKeyIdRequired =>
      _localizedValues[locale.languageCode]?['validationAccessKeyIdRequired'] ??
      'ACCESS KEY ID required';
  String get validationAccessKeySecretRequired =>
      _localizedValues[locale.languageCode]
          ?['validationAccessKeySecretRequired'] ??
      'ACCESS KEY SECRET required';
  String get validationRegionRequired =>
      _localizedValues[locale.languageCode]?['validationRegionRequired'] ??
      'REGION required';
  String get validationModelPathRequired =>
      _localizedValues[locale.languageCode]?['validationModelPathRequired'] ??
      'MODEL PATH required';
  String get validationApiSecretRequired =>
      _localizedValues[locale.languageCode]?['validationApiSecretRequired'] ??
      'API SECRET required';
  String get validationBaseUrlRequiredLlc =>
      _localizedValues[locale.languageCode]?['validationBaseUrlRequiredLlc'] ??
      'Base URL required';
  String get validationInvalidBaseUrl =>
      _localizedValues[locale.languageCode]?['validationInvalidBaseUrl'] ??
      'invalid Base URL';
  String get validationModelNameRequired =>
      _localizedValues[locale.languageCode]?['validationModelNameRequired'] ??
      'MODEL NAME required';
  String get validationGeminiModelNameInvalid =>
      _localizedValues[locale.languageCode]
          ?['validationGeminiModelNameInvalid'] ??
      'Gemini model name must look like gemini-2.5-flash';
  String validationModelNameFormatInvalid(String provider, String example) =>
      (_localizedValues[locale.languageCode]
                  ?['validationModelNameFormatInvalid'] ??
              '{provider} model name format is invalid. Example: {example}')
          .replaceAll('{provider}', provider)
          .replaceAll('{example}', example);
  String get validationDoubaoModelEndpointRequired =>
      _localizedValues[locale.languageCode]
          ?['validationDoubaoModelEndpointRequired'] ??
      'Create an endpoint in Volcano Ark console first, then fill the endpoint ID (e.g. ep-xxx)';
  String get updateConfigurationLabel =>
      _localizedValues[locale.languageCode]?['updateConfigurationLabel'] ??
      'Update Configuration';

  // Auth - extra
  String get appleSignInNotSupported =>
      _localizedValues[locale.languageCode]?['appleSignInNotSupported'] ??
      'Apple Sign-In is not supported on this device (please test on a real iOS device with Apple ID signed in).';
  String get appleSignInNoToken =>
      _localizedValues[locale.languageCode]?['appleSignInNoToken'] ??
      'Apple Sign-In did not return a token (check Sign in with Apple capability and signing).';
  String appleSignInError(String error) =>
      (_localizedValues[locale.languageCode]?['appleSignInError'] ??
              'Apple Sign-In error: {error}')
          .replaceAll('{error}', error);
  String get appleSignInCanceled =>
      _localizedValues[locale.languageCode]?['appleSignInCanceled'] ??
      'Apple Sign-In canceled';
  String get appleSignInNotHandled =>
      _localizedValues[locale.languageCode]?['appleSignInNotHandled'] ??
      'Apple Sign-In not handled (system did not complete authorization).';
  String get appleSignInNotInteractive =>
      _localizedValues[locale.languageCode]?['appleSignInNotInteractive'] ??
      'Apple Sign-In not interactive (unlock device / disable screen recording limit).';
  String get appleSignInCredentialExport =>
      _localizedValues[locale.languageCode]?['appleSignInCredentialExport'] ??
      'Apple Sign-In failed: credential export failed.';
  String get appleSignInCredentialImport =>
      _localizedValues[locale.languageCode]?['appleSignInCredentialImport'] ??
      'Apple Sign-In failed: credential import failed.';
  String get appleSignInMatchedExcluded =>
      _localizedValues[locale.languageCode]?['appleSignInMatchedExcluded'] ??
      'Apple Sign-In failed: matched excluded credential.';
  String get appleSignInFailed =>
      _localizedValues[locale.languageCode]?['appleSignInFailed'] ??
      'Apple Sign-In failed. Please try again.';
  String get appleSignInInvalidResponse =>
      _localizedValues[locale.languageCode]?['appleSignInInvalidResponse'] ??
      'Apple Sign-In failed: invalid response (check network and system).';
  String get appleSignInUnknown =>
      _localizedValues[locale.languageCode]?['appleSignInUnknown'] ??
      'Apple Sign-In failed: unknown error. Common causes: Sign in with Apple not enabled for App ID / certificates not updated / BundleId mismatch.';
  String get passwordHintDots =>
      _localizedValues[locale.languageCode]?['passwordHintDots'] ?? '••••••••';
  String googleSignInFailedCode(String code) =>
      (_localizedValues[locale.languageCode]?['googleSignInFailedCode'] ??
              'Google Sign-In failed: {code}')
          .replaceAll('{code}', code);
  String googleSignInFailed(String error) =>
      (_localizedValues[locale.languageCode]?['googleSignInFailed'] ??
              'Google Sign-In failed: {error}')
          .replaceAll('{error}', error);
  String get googleSignInNoTokenAndroid =>
      _localizedValues[locale.languageCode]?['googleSignInNoTokenAndroid'] ??
      'Google Sign-In did not return a token. On Android, set Web OAuth client via --dart-define=GOOGLE_SERVER_CLIENT_ID=... or app env, and register package cc.seeed.voice + SHA-1 in Google Cloud.';
  String get googleSignInNoTokenGeneric =>
      _localizedValues[locale.languageCode]?['googleSignInNoTokenGeneric'] ??
      'Google Sign-In did not return a token. Check your platform configuration.';
  String get googleSignInCanceledOrMisconfigured =>
      _localizedValues[locale.languageCode]
          ?['googleSignInCanceledOrMisconfigured'] ??
      'Google sign-in stopped (canceled). If you already chose an account, check Google Cloud: package cc.seeed.voice, your build SHA-1, and Web client ID as serverClientId.';
  String get githubSignInNotConfigured =>
      _localizedValues[locale.languageCode]?['githubSignInNotConfigured'] ??
      'GitHub sign-in is not configured (missing client_id).';
  String get githubSignInFailedShort =>
      _localizedValues[locale.languageCode]?['githubSignInFailedShort'] ??
      'GitHub sign-in failed';
  String get oauthGitHubStateMismatch =>
      _localizedValues[locale.languageCode]?['oauthGitHubStateMismatch'] ??
      'GitHub sign-in failed: state mismatch';
  String get oauthGitHubMissingCode =>
      _localizedValues[locale.languageCode]?['oauthGitHubMissingCode'] ??
      'GitHub sign-in failed: callback missing code';
  String get oauthUnsupportedProvider =>
      _localizedValues[locale.languageCode]?['oauthUnsupportedProvider'] ??
      'This sign-in method is not supported';
  String get oauthAllowAccess =>
      _localizedValues[locale.languageCode]?['oauthAllowAccess'] ??
      'Allow Access';
  String get appleOauthPageTitle =>
      _localizedValues[locale.languageCode]?['appleOauthPageTitle'] ??
      'Sign in with Apple';
  String get appleOauthPageSubtitle =>
      _localizedValues[locale.languageCode]?['appleOauthPageSubtitle'] ??
      'A system sign-in dialog will open. We do not fake Apple account or email pickers in the app.';

  /// Product name in OAuth card title (brand; usually not translated)
  String get oauthPartnerProductName =>
      _localizedValues[locale.languageCode]?['oauthPartnerProductName'] ??
      'SenseCraft Voice';

  /// "Wishes to access your account" phrasing after [oauthPartnerProductName]
  String get oauthWantsAccessAfterBrand =>
      _localizedValues[locale.languageCode]?['oauthWantsAccessAfterBrand'] ??
      ' wants to\naccess your Account';
  String get oauthReTerminalSyncDescription =>
      _localizedValues[locale.languageCode]
          ?['oauthReTerminalSyncDescription'] ??
      'This will allow reTerminal to sync\nyour IoT configurations and cloud\nsensor data.';
  String get oauthSecureIndustrialTunnel =>
      _localizedValues[locale.languageCode]?['oauthSecureIndustrialTunnel'] ??
      'SECURE INDUSTRIAL TUNNEL';
  String get oauthGithubPermReadProfileTitle =>
      _localizedValues[locale.languageCode]
          ?['oauthGithubPermReadProfileTitle'] ??
      'Read your public profile';
  String get oauthGithubPermReadProfileSubtitle =>
      _localizedValues[locale.languageCode]
          ?['oauthGithubPermReadProfileSubtitle'] ??
      'Includes your name, photo, and bio.';
  String get oauthGithubPermEmailTitle =>
      _localizedValues[locale.languageCode]?['oauthGithubPermEmailTitle'] ??
      'Access your email address';
  String get oauthGithubPermEmailSubtitle =>
      _localizedValues[locale.languageCode]?['oauthGithubPermEmailSubtitle'] ??
      'Primary email address will be synced.';
  String get oauthPermViewProfileTitle =>
      _localizedValues[locale.languageCode]?['oauthPermViewProfileTitle'] ??
      'View your basic profile info';
  String get oauthPermViewProfileSubtitle =>
      _localizedValues[locale.languageCode]?['oauthPermViewProfileSubtitle'] ??
      '';
  String get oauthPermManageHwTitle =>
      _localizedValues[locale.languageCode]?['oauthPermManageHwTitle'] ??
      'Manage hardware config files';
  String get oauthPermManageHwSubtitle =>
      _localizedValues[locale.languageCode]?['oauthPermManageHwSubtitle'] ?? '';
  String get wifiTransferTitle =>
      _localizedValues[locale.languageCode]?['wifiTransferTitle'] ??
      'WiFi Transfer';
  String get wifiTransferStart =>
      _localizedValues[locale.languageCode]?['wifiTransferStart'] ??
      'Start WiFi Transfer';
  String syncedFileEntriesCount(int n) =>
      (_localizedValues[locale.languageCode]?['syncedFileEntriesCount'] ??
              'Synced {n} file index entries')
          .replaceAll('{n}', '$n');
  String sttConfigDeleteFailed(String error) =>
      (_localizedValues[locale.languageCode]?['sttConfigDeleteFailed'] ??
              'Delete failed: {error}')
          .replaceAll('{error}', error);
  String get sessionMissingCannotSync =>
      _localizedValues[locale.languageCode]?['sessionMissingCannotSync'] ??
      'The device did not return a session, and the latest session could not be read from the device. Files cannot be synced yet.';
  String get promptTemplateSubtitleMeeting =>
      _localizedValues[locale.languageCode]?['promptTemplateSubtitleMeeting'] ??
      'Core agenda, tasks, highlights';
  String get promptTemplateSubtitleLecture =>
      _localizedValues[locale.languageCode]?['promptTemplateSubtitleLecture'] ??
      'Key takeaways, questions';
  String get promptTemplateSubtitleClass =>
      _localizedValues[locale.languageCode]?['promptTemplateSubtitleClass'] ??
      'Key takeaways, questions';
  String get promptTemplateSubtitleDailyDialogue =>
      _localizedValues[locale.languageCode]
          ?['promptTemplateSubtitleDailyDialogue'] ??
      'Who / what / when action items';
  String get promptTemplateSubtitleDailyConversation =>
      _localizedValues[locale.languageCode]
          ?['promptTemplateSubtitleDailyConversation'] ??
      'Who+what+when action items';
  String get promptTemplateSubtitleCustomDefault =>
      _localizedValues[locale.languageCode]
          ?['promptTemplateSubtitleCustomDefault'] ??
      'Default template';
  String get promptTemplateSubtitleCustomUser =>
      _localizedValues[locale.languageCode]
          ?['promptTemplateSubtitleCustomUser'] ??
      'User-created template';
  // Server / API error messages (by bizCode or generic)
  String get errorNetworkTimeout =>
      _localizedValues[locale.languageCode]?['errorNetworkTimeout'] ??
      'Network request timed out. Please try again later.';
  String get errorNetworkUnavailable =>
      _localizedValues[locale.languageCode]?['errorNetworkUnavailable'] ??
      'Network unavailable. Please check your connection and try again.';
  String get errorRequestFailed =>
      _localizedValues[locale.languageCode]?['errorRequestFailed'] ??
      'Request failed. Please try again later.';
  String get errorUnknown =>
      _localizedValues[locale.languageCode]?['errorUnknown'] ??
      'An error occurred.';
  String get errorLoginFailed =>
      _localizedValues[locale.languageCode]?['errorLoginFailed'] ??
      'Login failed.';
  String get errorUserNotFound =>
      _localizedValues[locale.languageCode]?['errorUserNotFound'] ??
      'User not found.';
  String get errorPasswordIncorrect =>
      _localizedValues[locale.languageCode]?['errorPasswordIncorrect'] ??
      'Incorrect password.';
  String get errorUserAlreadyExists =>
      _localizedValues[locale.languageCode]?['errorUserAlreadyExists'] ??
      'User already exists.';
  String get errorEmailAlreadyRegistered =>
      _localizedValues[locale.languageCode]?['errorEmailAlreadyRegistered'] ??
      'This email is already registered.';
  String get errorTokenExpired =>
      _localizedValues[locale.languageCode]?['errorTokenExpired'] ??
      'Session expired. Please sign in again.';
  String get errorTokenInvalid =>
      _localizedValues[locale.languageCode]?['errorTokenInvalid'] ??
      'Invalid session. Please sign in again.';
  String get errorVerifyCodeInvalid =>
      _localizedValues[locale.languageCode]?['errorVerifyCodeInvalid'] ??
      'Invalid or expired verification code.';
  String get errorVerifyCodeExpired =>
      _localizedValues[locale.languageCode]?['errorVerifyCodeExpired'] ??
      'Verification code expired or incorrect. Request a new code.';
  String get errorEmailNotVerified =>
      _localizedValues[locale.languageCode]?['errorEmailNotVerified'] ??
      'Email not verified.';
  String get errorUnauthorized =>
      _localizedValues[locale.languageCode]?['errorUnauthorized'] ??
      'Unauthorized.';
  String get errorForbidden =>
      _localizedValues[locale.languageCode]?['errorForbidden'] ??
      'Access denied.';
  String get errorInvalidParams =>
      _localizedValues[locale.languageCode]?['errorInvalidParams'] ??
      'Invalid parameters.';
  String get errorInternalError =>
      _localizedValues[locale.languageCode]?['errorInternalError'] ??
      'Server error. Please try again later.';
  String get errorTimeout =>
      _localizedValues[locale.languageCode]?['errorTimeout'] ??
      'Request timed out.';
  String get errorUploadFailed =>
      _localizedValues[locale.languageCode]?['errorUploadFailed'] ??
      'Upload failed.';
  String get errorRecordNotFound =>
      _localizedValues[locale.languageCode]?['errorRecordNotFound'] ??
      'Record not found.';
  String get errorAsrVendorNotConfigured =>
      _localizedValues[locale.languageCode]?['errorAsrVendorNotConfigured'] ??
      'ASR vendor not configured.';
  String get errorAsrUnsupportedFormat =>
      _localizedValues[locale.languageCode]?['errorAsrUnsupportedFormat'] ??
      'Unsupported audio format.';
  String get errorDuplicateRecord =>
      _localizedValues[locale.languageCode]?['errorDuplicateRecord'] ??
      'A record with the same key already exists.';
  String get errorAuditNotFound =>
      _localizedValues[locale.languageCode]?['errorAuditNotFound'] ??
      'Audit record not found.';
  String get errorAuditExists =>
      _localizedValues[locale.languageCode]?['errorAuditExists'] ??
      'Audit record already exists.';
  String get errorRbacPolicyExists =>
      _localizedValues[locale.languageCode]?['errorRbacPolicyExists'] ??
      'Permission policy already exists.';
  String get errorRbacPolicyNotFound =>
      _localizedValues[locale.languageCode]?['errorRbacPolicyNotFound'] ??
      'Permission policy not found.';
  String get errorRbacRoleExists =>
      _localizedValues[locale.languageCode]?['errorRbacRoleExists'] ??
      'Role already exists.';
  String get errorRbacRoleNotFound =>
      _localizedValues[locale.languageCode]?['errorRbacRoleNotFound'] ??
      'Role not found.';
  String get errorAsrConfigAlreadyExists =>
      _localizedValues[locale.languageCode]?['errorAsrConfigAlreadyExists'] ??
      'ASR configuration already exists.';
  String get errorAsrConfigNotFound =>
      _localizedValues[locale.languageCode]?['errorAsrConfigNotFound'] ??
      'ASR configuration not found. Please create one first.';
  String get errorAsrVendorNotFound =>
      _localizedValues[locale.languageCode]?['errorAsrVendorNotFound'] ??
      'ASR vendor not found.';
  String get errorAsrResultNotFound =>
      _localizedValues[locale.languageCode]?['errorAsrResultNotFound'] ??
      'Transcription result not found or access denied.';
  String get errorAsrJobNotFound =>
      _localizedValues[locale.languageCode]?['errorAsrJobNotFound'] ??
      'Transcription job not found or access denied.';
  String get errorLlmVendorNotConfigured =>
      _localizedValues[locale.languageCode]?['errorLlmVendorNotConfigured'] ??
      'LLM vendor not configured.';
  String get errorPromptTemplateNotFound =>
      _localizedValues[locale.languageCode]?['errorPromptTemplateNotFound'] ??
      'Prompt template not found.';
  String get errorLlmConfigAlreadyExists =>
      _localizedValues[locale.languageCode]?['errorLlmConfigAlreadyExists'] ??
      'LLM configuration already exists for this vendor.';
  String get errorLlmConfigNotFound =>
      _localizedValues[locale.languageCode]?['errorLlmConfigNotFound'] ??
      'LLM configuration not found.';
  String get errorPromptAlreadyImported =>
      _localizedValues[locale.languageCode]?['errorPromptAlreadyImported'] ??
      'This template has already been imported.';
  String get promptTemplateUnsupportedChars =>
      _localizedValues[locale.languageCode]
          ?['promptTemplateUnsupportedChars'] ??
      'Template name or content contains characters the server cannot store (such as emoji). '
          'Update the server database to utf8mb4 or remove emoji and try again.';
  String get promptTemplateFieldsInvalid =>
      _localizedValues[locale.languageCode]?['promptTemplateFieldsInvalid'] ??
      'Enter a template name (1–128 characters) and prompt content.';
  String get errorNetworkRequestFailed =>
      _localizedValues[locale.languageCode]?['errorNetworkRequestFailed'] ??
      'Network request failed. Please check your connection and try again.';
  String get errorNotImplemented =>
      _localizedValues[locale.languageCode]?['errorNotImplemented'] ??
      'This feature is not available yet.';
  String get errorBusySystem =>
      _localizedValues[locale.languageCode]?['errorBusySystem'] ??
      'Server is busy. Please try again later.';
  String get errorAccountNotFound =>
      _localizedValues[locale.languageCode]?['errorAccountNotFound'] ??
      'Account not found. Check your email or sign up first.';
  String get errorAccountFrozen =>
      _localizedValues[locale.languageCode]?['errorAccountFrozen'] ??
      'This account has been frozen. Contact support.';
  String get errorTooManyLoginAttempts =>
      _localizedValues[locale.languageCode]?['errorTooManyLoginAttempts'] ??
      'Too many login attempts. Please try again later.';
  String get errorOauthFailed =>
      _localizedValues[locale.languageCode]?['errorOauthFailed'] ??
      'Sign-in with this provider failed. Please try again.';
  String get errorUnsupportedOAuthProvider =>
      _localizedValues[locale.languageCode]?['errorUnsupportedOAuthProvider'] ??
      'This sign-in provider is not supported.';
  String get errorUserInfoError =>
      _localizedValues[locale.languageCode]?['errorUserInfoError'] ??
      'Could not load account information. Please sign in again.';
  String get errorVerifyCodeNotExpired =>
      _localizedValues[locale.languageCode]?['errorVerifyCodeNotExpired'] ??
      'A verification code was already sent. Check your email or wait before requesting another.';
  String get errorRecordNotUpdate =>
      _localizedValues[locale.languageCode]?['errorRecordNotUpdate'] ??
      'Could not update this record.';
  String get errorClusterNotFound =>
      _localizedValues[locale.languageCode]?['errorClusterNotFound'] ??
      'Service cluster not found.';
  String get errorTenantNotFound =>
      _localizedValues[locale.languageCode]?['errorTenantNotFound'] ??
      'Account not found.';
  String get errorTenantExists =>
      _localizedValues[locale.languageCode]?['errorTenantExists'] ??
      'Account already exists.';
  String get errorRemoteCalled =>
      _localizedValues[locale.languageCode]?['errorRemoteCalled'] ??
      'Remote service error. Please try again later.';
  String get errorPathNotFound =>
      _localizedValues[locale.languageCode]?['errorPathNotFound'] ??
      'Requested API path not found.';
  String get errorMissingParams =>
      _localizedValues[locale.languageCode]?['errorMissingParams'] ??
      'Missing required parameters. Please sign in again.';
  String get errorNewPasswordSameAsOld =>
      _localizedValues[locale.languageCode]?['errorNewPasswordSameAsOld'] ??
      'New password must be different from the current password.';
  String get errorMobileAlreadyRegistered =>
      _localizedValues[locale.languageCode]?['errorMobileAlreadyRegistered'] ??
      'This mobile number is already registered.';
  String get errorSmsCodeAlreadySent =>
      _localizedValues[locale.languageCode]?['errorSmsCodeAlreadySent'] ??
      'SMS code already sent. Please wait before requesting another.';
  String get errorMobileRequired =>
      _localizedValues[locale.languageCode]?['errorMobileRequired'] ??
      'Mobile number is required.';
  String get errorMobileFormatInvalid =>
      _localizedValues[locale.languageCode]?['errorMobileFormatInvalid'] ??
      'Invalid mobile number format.';
  String get errorOssUploadNotConfigured =>
      _localizedValues[locale.languageCode]?['errorOssUploadNotConfigured'] ??
      'File upload is not configured on the server.';
  String get errorOssPresignFailed =>
      _localizedValues[locale.languageCode]?['errorOssPresignFailed'] ??
      'Failed to prepare file upload. Please try again.';
  String get errorAuthorizeCodeInvalid =>
      _localizedValues[locale.languageCode]?['errorAuthorizeCodeInvalid'] ??
      'Authorization code is invalid. Please try again.';
  String get errorOauthStateMismatch =>
      _localizedValues[locale.languageCode]?['errorOauthStateMismatch'] ??
      'Sign-in session expired. Please start again.';
  String get errorOauthCodeMissing =>
      _localizedValues[locale.languageCode]?['errorOauthCodeMissing'] ??
      'Authorization code was not provided.';
  String get errorOauthStateMissing =>
      _localizedValues[locale.languageCode]?['errorOauthStateMissing'] ??
      'Sign-in state was not provided. Please try again.';
  String get errorOauthAccountNeedBind =>
      _localizedValues[locale.languageCode]?['errorOauthAccountNeedBind'] ??
      'This email is already registered. Sign in with email or bind the account.';
  String get errorChildAccountCannotDelete =>
      _localizedValues[locale.languageCode]?['errorChildAccountCannotDelete'] ??
      'This sub-account cannot be deleted.';
  String get errorTermsAcceptanceRequired =>
      _localizedValues[locale.languageCode]?['errorTermsAcceptanceRequired'] ??
      'You must accept the Terms of Service to sign in.';
  String get errorOauthForeignIdTaken =>
      _localizedValues[locale.languageCode]?['errorOauthForeignIdTaken'] ??
      'This third-party account is already linked to another account.';
  String get errorOauthOrgAlreadyBound =>
      _localizedValues[locale.languageCode]?['errorOauthOrgAlreadyBound'] ??
      'This account is already linked to another sign-in method.';
  String get errorOauthWechatNoUnionid =>
      _localizedValues[locale.languageCode]?['errorOauthWechatNoUnionid'] ??
      'WeChat did not return unionid. Check Open Platform binding and user authorization.';

  // Auth API errors
  String get authLoginResponseFormat =>
      _localizedValues[locale.languageCode]?['authLoginResponseFormat'] ??
      'Login failed: invalid response format.';
  String get authLoginFailed =>
      _localizedValues[locale.languageCode]?['authLoginFailed'] ??
      'Login failed.';
  String get authRegisterMissingResult =>
      _localizedValues[locale.languageCode]?['authRegisterMissingResult'] ??
      'Registration failed: response missing result.';
  String get authLoginMissingResult =>
      _localizedValues[locale.languageCode]?['authLoginMissingResult'] ??
      'Login failed: response missing result.';
  String get authRequestFormat =>
      _localizedValues[locale.languageCode]?['authRequestFormat'] ??
      'Request failed: invalid response format.';

  // ASR API errors
  String get asrRequestFormat =>
      _localizedValues[locale.languageCode]?['asrRequestFormat'] ??
      'Request failed: invalid response format.';
  String get asrGetConfigMissingResult =>
      _localizedValues[locale.languageCode]?['asrGetConfigMissingResult'] ??
      'Failed to get config: response missing result.';
  String get asrTranscribeMissingResult =>
      _localizedValues[locale.languageCode]?['asrTranscribeMissingResult'] ??
      'Transcription failed: response missing result.';

  // User API errors (for server_error_localizer messageKey lookup)
  String get userApiUploadTypeEmpty =>
      _localizedValues[locale.languageCode]?['userApiUploadTypeEmpty'] ??
      'Upload failed: type cannot be empty.';
  String get userApiUploadFileNotFound =>
      _localizedValues[locale.languageCode]?['userApiUploadFileNotFound'] ??
      'Upload failed: file not found.';
  String get userApiUploadFailed =>
      _localizedValues[locale.languageCode]?['userApiUploadFailed'] ??
      'Upload failed.';
  String get userApiUploadMissingResult =>
      _localizedValues[locale.languageCode]?['userApiUploadMissingResult'] ??
      'Upload failed: response missing result.';
  String get userApiUploadMissingPublicUrl =>
      _localizedValues[locale.languageCode]?['userApiUploadMissingPublicUrl'] ??
      'Upload failed: response missing public_url.';
  String get userApiLogoutFailed =>
      _localizedValues[locale.languageCode]?['userApiLogoutFailed'] ??
      'Logout failed.';
  String get userApiDeactivateFailed =>
      _localizedValues[locale.languageCode]?['userApiDeactivateFailed'] ??
      'Account deactivation failed.';
  String get userApiResetPasswordFailed =>
      _localizedValues[locale.languageCode]?['userApiResetPasswordFailed'] ??
      'Password reset failed.';
  String get userApiChangePasswordFailed =>
      _localizedValues[locale.languageCode]?['userApiChangePasswordFailed'] ??
      'Password change failed.';
  String get userApiUpdateProfileFailed =>
      _localizedValues[locale.languageCode]?['userApiUpdateProfileFailed'] ??
      'Update profile failed.';
  String get userApiUpdateEmailFailed =>
      _localizedValues[locale.languageCode]?['userApiUpdateEmailFailed'] ??
      'Update email failed.';
  String get userApiGetMeFailed =>
      _localizedValues[locale.languageCode]?['userApiGetMeFailed'] ??
      'Failed to get user info.';
  String get userApiGetMeMissingResult =>
      _localizedValues[locale.languageCode]?['userApiGetMeMissingResult'] ??
      'Failed to get user info: response missing result.';

  // LLM API errors (for server_error_localizer messageKey lookup)
  String get llmErrorResponseFormat =>
      _localizedValues[locale.languageCode]?['llmErrorResponseFormat'] ??
      'Request failed: invalid response format.';
  String get llmErrorPublicTemplatesMissingResult =>
      _localizedValues[locale.languageCode]
          ?['llmErrorPublicTemplatesMissingResult'] ??
      'Failed to get public templates: response missing result list.';
  String get llmErrorGetTemplateMissingResult =>
      _localizedValues[locale.languageCode]
          ?['llmErrorGetTemplateMissingResult'] ??
      'Failed to get template: response missing result.';
  String get llmErrorCreateTemplateMissingResult =>
      _localizedValues[locale.languageCode]
          ?['llmErrorCreateTemplateMissingResult'] ??
      'Failed to create template: response missing result.';
  String get llmErrorPreviewTemplateMissingResult =>
      _localizedValues[locale.languageCode]
          ?['llmErrorPreviewTemplateMissingResult'] ??
      'Failed to preview template: response missing result.';
  String get llmErrorImportTemplateMissingResult =>
      _localizedValues[locale.languageCode]
          ?['llmErrorImportTemplateMissingResult'] ??
      'Failed to import template: response missing result.';
  String get llmErrorStartShareMissingResult =>
      _localizedValues[locale.languageCode]
          ?['llmErrorStartShareMissingResult'] ??
      'Failed to start share: response missing result.';
  String get llmErrorConfigNotSynced =>
      _localizedValues[locale.languageCode]?['llmErrorConfigNotSynced'] ??
      'LLM config not synced to server.';
  String get llmErrorSystemPromptEmpty =>
      _localizedValues[locale.languageCode]?['llmErrorSystemPromptEmpty'] ??
      'system_prompt cannot be empty.';
  String get llmErrorResponseEmpty =>
      _localizedValues[locale.languageCode]?['llmErrorResponseEmpty'] ??
      'Request failed: empty response.';
  String get llmErrorSummaryEmpty =>
      _localizedValues[locale.languageCode]?['llmErrorSummaryEmpty'] ??
      'Summary is empty.';

  /// Returns localized message for a [ServerException.messageKey], or null if unknown.
  String? messageForKey(String key) {
    switch (key) {
      case 'llmErrorResponseFormat':
        return llmErrorResponseFormat;
      case 'llmErrorPublicTemplatesMissingResult':
        return llmErrorPublicTemplatesMissingResult;
      case 'llmErrorGetTemplateMissingResult':
        return llmErrorGetTemplateMissingResult;
      case 'llmErrorCreateTemplateMissingResult':
        return llmErrorCreateTemplateMissingResult;
      case 'llmErrorPreviewTemplateMissingResult':
        return llmErrorPreviewTemplateMissingResult;
      case 'llmErrorImportTemplateMissingResult':
        return llmErrorImportTemplateMissingResult;
      case 'llmErrorStartShareMissingResult':
        return llmErrorStartShareMissingResult;
      case 'llmErrorConfigNotSynced':
        return llmErrorConfigNotSynced;
      case 'llmErrorSystemPromptEmpty':
        return llmErrorSystemPromptEmpty;
      case 'llmErrorResponseEmpty':
        return llmErrorResponseEmpty;
      case 'llmErrorSummaryEmpty':
        return llmErrorSummaryEmpty;
      case 'errorRequestFailed':
        return errorRequestFailed;
      case 'errorNetworkRequestFailed':
        return errorNetworkRequestFailed;
      case 'errorNetworkTimeout':
        return errorNetworkTimeout;
      case 'errorNetworkUnavailable':
        return errorNetworkUnavailable;
      case 'errorUploadFailed':
        return errorUploadFailed;
      case 'authLoginResponseFormat':
        return authLoginResponseFormat;
      case 'authLoginFailed':
        return authLoginFailed;
      case 'authRegisterMissingResult':
        return authRegisterMissingResult;
      case 'authLoginMissingResult':
        return authLoginMissingResult;
      case 'authRequestFormat':
        return authRequestFormat;
      case 'asrRequestFormat':
        return asrRequestFormat;
      case 'asrGetConfigMissingResult':
        return asrGetConfigMissingResult;
      case 'asrTranscribeMissingResult':
        return asrTranscribeMissingResult;
      case 'userApiUploadTypeEmpty':
        return userApiUploadTypeEmpty;
      case 'userApiUploadFileNotFound':
        return userApiUploadFileNotFound;
      case 'userApiUploadFailed':
        return userApiUploadFailed;
      case 'userApiUploadMissingResult':
        return userApiUploadMissingResult;
      case 'userApiUploadMissingPublicUrl':
        return userApiUploadMissingPublicUrl;
      case 'userApiLogoutFailed':
        return userApiLogoutFailed;
      case 'userApiDeactivateFailed':
        return userApiDeactivateFailed;
      case 'userApiResetPasswordFailed':
        return userApiResetPasswordFailed;
      case 'userApiChangePasswordFailed':
        return userApiChangePasswordFailed;
      case 'userApiUpdateProfileFailed':
        return userApiUpdateProfileFailed;
      case 'userApiUpdateEmailFailed':
        return userApiUpdateEmailFailed;
      case 'userApiGetMeFailed':
        return userApiGetMeFailed;
      case 'userApiGetMeMissingResult':
        return userApiGetMeMissingResult;
      case 'registerMissingVerificationCode':
        return registerMissingVerificationCode;
      default:
        return null;
    }
  }

  // Router / App
  String get pageNotFound =>
      _localizedValues[locale.languageCode]?['pageNotFound'] ??
      'Page not found';
  String get appTitle =>
      _localizedValues[locale.languageCode]?['appTitle'] ?? 'SenseCraft Voice';

  static final Map<String, Map<String, String>> _localizedValues = {
    'en': {
      'loginLandingTitle': 'Login',
      'externalIdentity': 'EXTERNAL IDENTITY',
      'continueWithApple': 'Continue with Apple',
      'continueWithGoogle': 'Continue with Google',
      'continueWithGithub': 'Continue with Github',
      'emailLogin': 'Email Login',
      'passwordLogin': 'Password Login',
      'loginWithPassword': 'Login with Password',
      'loginWithEmailCode': 'Login with Email Code',
      'terminalSessionProtected': 'This terminal session is protected by',
      'technicalStandards': 'Technical Standards',
      'safetyProtocols': 'Safety Protocols',
      'identityVerification': 'IDENTITY VERIFICATION',
      'emailLoginTitle': 'Email Login',
      'emailLoginDescription':
          'Enter your email to receive a verification code. If the email is not registered, an account will be automatically created.',
      'email': 'EMAIL',
      'emailHint': 'you@example.com',
      'emailExample': 'name@example.com',
      'verificationCode': 'Verification Code',
      'verificationCodeHint': 'Enter code',
      'getCode': 'Get Code',
      'resendIn': 'Resend in',
      'seconds': 's',
      'emailNotRegisteredHint':
          'If this email is not registered, an account will be automatically created.',
      'agreeToTerms': 'I have read and agree to the',
      'agreeToTermsRequired':
          'Please read and agree to the User Agreement and Privacy Policy first.',
      'privacyConsentTitle': 'Privacy Policy',
      'privacyConsentBodyPrefix':
          'Welcome to SenseCraft Voice. Please carefully read the ',
      'privacyConsentBodySuffix':
          '. Tap Agree to continue. If you do not agree, tap Refuse to exit the app.',
      'privacyConsentAgree': 'Agree',
      'privacyConsentRefuse': 'Refuse',
      'loginOptions': 'Login',
      'thirdPartyLogin': 'Third-party login',
      'errorOAuthDisplayNameDbCharset':
          'Your account display name contains unsupported characters (such as emoji). '
              'Change the name in your Apple/Google account settings, or sign in with email.',
      'userAgreement': 'User Agreement',
      'and': 'and',
      'privacyPolicy': 'Privacy Policy',
      'orWithEmail': 'Or with email',
      'agreePrefixLanding':
          'By clicking on the "Continue" buttons below, you agree to the',
      'serverEnvLabel': 'Server',
      'serverEnvRelease': 'Release',
      'serverEnvTest': 'Test',
      'serverEnvDev': 'Dev',
      'signIn': 'Sign In',
      'signingIn': 'Signing In...',
      'fillEmailCodeAndAgree':
          'Please fill in email/verification code and agree to the terms',
      'continueAction': 'Continue',
      'continueLoading': 'Continue...',
      'invalidCode6': 'Please enter the 6-digit code',
      'passwordLoginTitle': 'Password Login',
      'passwordLoginDescription': 'Sign in with your email and password.',
      'password': 'PASSWORD',
      'passwordHint': 'Enter password',
      'emailOrPasswordEmpty': 'Please enter email and password',
      'invalidEmail': 'Please enter a valid email address',
      'forgotPasswordLink': 'Forgot Password?',
      'authenticatedVia': 'AUTHENTICATED VIA',
      'linkYourIdentity': 'Link Your Identity',
      'linkIdentityDescription':
          'To sync your data, please provide an email address.',
      'verifyAndContinue': 'Verify & Continue',
      'dataPrivacy': 'DATA PRIVACY',
      'dataPrivacyDescription':
          'Your email will be used to synchronize engineering configurations across your reTerminal devices via an encrypted secure tunnel.',
      'enterValidEmail': 'Please enter a valid email',
      'setPassword': 'Set Password',
      'setPasswordDescription':
          'It is recommended to set a password after successful login for easier access using "Password Login". This step can be skipped.',
      'confirm': 'Confirm',
      'passwordHintSet': '8-16 characters, must contain letters and numbers',
      'confirmPasswordHint': 'Re-enter password',
      'passwordRule':
          'Rule: 8-16 characters, must contain both letters and numbers.',
      'passwordInvalid': 'Password does not meet the requirements',
      'passwordMismatch': 'Passwords do not match',
      'saving': 'Saving...',
      'skip': 'Skip',
      'secureYourAccount': 'Secure Your Account',
      'setPasswordForFuture': 'Set a password for future logins',
      'skipForNow': 'Skip for Now',
      'resetPasswordMissingCode':
          'Reset password failed: missing verification code',
      'registerMissingVerificationCode':
          'Missing registration code. Return to the verification step and enter the 6-digit code from your email.',
      'resetPasswordSuccess': 'Password reset. Please sign in again.',
      'registerCompleteSignInWithEmailCode':
          'Account created. Go back to sign in and tap Continue to send a login verification code to your email.',
      'forgotPasswordTitle': 'Forgot Password',
      'forgotPasswordDesc': 'Enter your email to receive a verification code',
      'enterVerificationCodeTitle': 'Enter verification code',
      'enterVerificationCodeDesc': 'Enter the 6-digit code sent to your email',
      'universalAccess': 'UNIVERSAL ACCESS',
      'passwordLoginSubtitle': 'PASSWORD LOGIN',
      'passwordLoginNotImplemented':
          'Password login feature is not yet implemented',

      // Settings - Common
      'save': 'Save',
      'saving2': 'Saving...',
      'cancel': 'Cancel',
      'delete': 'Delete',
      'clear': 'Clear',
      'enabled': 'Enabled',
      'notEnabled': 'Not enabled',
      'latest': 'LATEST',
      'languageEnglish': 'English',
      'languageChinese': 'Simplified Chinese',
      // Settings - SettingsPage
      'settings': 'Settings',
      'security': 'Security',
      'community': 'Community',
      'about': 'About',
      'permissions': 'Permissions',
      'language': 'Language',
      'passwordItem': 'Password',
      'deleteAccount': 'Delete Account',
      'followUs': 'Follow Us',
      'followUsTwitter': 'X (Twitter)',
      'followUsLinkedIn': 'LinkedIn',
      'followUsDiscord': 'Discord',
      'followUsFacebook': 'Facebook',
      'helpFeedback': 'Help & Feedback',
      'appVersion': 'App Version',
      'clearCache': 'Clear Cache',
      'cacheCleared':
          'Cache cleared. Synced recordings in the app are not deleted.',
      'clearCacheFailed': 'Failed to clear cache',
      'policies': 'Policies',
      'logOut': 'Log Out',
      'pushNotifications': 'Push Notifications',
      // Settings - Personal Information
      'personalInformation': 'Personal Information',
      'profileUpdated': 'Profile updated',
      'tapToChangeProfilePhoto': 'Tap to change profile photo',
      'nickname': 'Nickname',
      'boundEmail': 'Bound Email',
      'connectedAccounts': 'Connected Accounts',
      'senseCraftAccount': 'SenseCraft account',
      'connected': 'Connected',
      'notConnected': 'Not Connected',
      // Settings - Change Email
      'changeEmail': 'Change Email',
      'emailAddress': 'Email address',
      'emailAddressDesc':
          'We will use this email for account login and notifications.',
      'sendCode': 'Send Code',
      'sendCodeLoading': 'Send Code...',
      'resendInSeconds': 'Resend in {s}s',
      'emailChangedSuccess':
          'Email updated. Please sign in with your new email.',
      // Settings - Change Password
      'changePassword': 'Change Password',
      'oldPassword': 'OLD PASSWORD',
      'oldPasswordHint': 'Old password',
      'newPassword': 'NEW PASSWORD',
      'confirmNewPassword': 'CONFIRM NEW PASSWORD',
      'repeatNewPasswordHint': 'Repeat new password',
      'updatePassword': 'Update Password',
      'confirmPasswordLabel': 'CONFIRM PASSWORD',
      'repeatPasswordHint': 'Repeat password',
      'passwordSetSuccess': 'Password set successfully',
      'updating': 'Updating...',
      'passwordChangedSuccess': 'Password updated',
      'fillAllFields': 'Please fill in all fields.',
      'newPasswordSameAsOld':
          'New password cannot be the same as the old password.',
      // Settings - Delete Account
      'accountDeletion': 'Account Deletion',
      'accountDeletionDesc':
          'This action is irreversible. All device data\nand web templates will be permanently\ndeleted.',
      'confirmDeletion': 'Confirm Deletion',
      'deleteAccountConfirmTitle': 'Delete Account',
      'deleteAccountConfirmMessage': 'This action is irreversible. Continue?',
      // Settings - Help & Feedback
      'helpCenter': 'Help Center',
      'productWiki': 'Product Wiki',
      'contactUs': 'Contact Us',
      'feedback': 'Feedback',
      'feedbackPrompt': 'Have a feature request or found a bug? Let us know!',
      'feedbackHint': 'Share your suggestions...',
      'submitSuggestion': 'Submit Suggestion',
      'feedbackTypeLabel': 'Feedback type',
      'feedbackTypeBug': 'Bug',
      'feedbackTypeEnhancement': 'Enhancement',
      'feedbackTypeFeature': 'New feature',
      'feedbackAddPhotos': 'Add screenshots (optional)',
      'feedbackPhotosLimit': 'Up to 3 images',
      'feedbackDescriptionRequired': 'Please describe your feedback',
      'feedbackSubmitSuccess': 'Thank you — your feedback was submitted.',
      'feedbackSubmitFailed': 'Failed to submit feedback',
      // Settings - Policies/About/Permissions
      'privacyPolicy2': 'Privacy Policy',
      'userAgreement2': 'User Agreement',
      'openSourceLicenses': 'Open Source Licenses',
      'linkOpenFailed': 'Could not open the link.',
      'bluetooth': 'Bluetooth',
      'microphone': 'Microphone',
      'notifications': 'Notifications',
      'checkForUpdates': 'Check for Updates',
      'checkingForUpdates': 'Checking for updates...',
      'updateAvailableTitle': 'Update Available',
      'updateNow': 'Update Now',
      'updateLater': 'Later',
      'noUpdateAvailable': 'You are already on the latest version.',
      'updateCheckFailed': 'Failed to check for updates.',
      'updateServiceNotConfigured': 'Update service is not configured.',
      'versionLabel': 'Version {v}',
      'cacheUsedLabel': '{v} used',
      'aboutCopyright': '© 2026 SenseCraft Voice. ALL RIGHTS RESERVED.',
      'helpCopyright': '© 2026 SenseCraft Voice. All rights reserved.',

      // Recordings / Home
      'recordingsLoadFailed': 'Load failed',
      'recordingsListEndHint': 'No more files',
      'recordingsLoadingMoreFooter': 'Loading more…',
      'selectedCount': 'Selected ({n})',
      'done': 'Done',
      'searchRecordings': 'Search recordings',
      'noRecordingsYet': 'No recordings yet',
      'noResults': 'No Results',
      'importDemoData': 'Import demo data',
      'filterSort': 'Filter & Sort',
      'allFiles': 'All Files',
      'all': 'All',
      'downloaded': 'Downloaded',
      'unclassified': 'Unclassified',
      'folder': 'Folder',
      'recycleBin': 'Recycle Bin',
      'folders': 'Folders',
      'deviceSourcePlaceholder': 'Note Pro  (2)',
      'from': 'From',
      'createTime': 'Created Time',
      'operationTime': 'Operation Time',
      'moveToRecycleBin': 'Move to Recycle Bin',
      'restoreFromRecycleBin': 'Restore',
      'moveToRecycleBinConfirm': 'Move {n} files to Recycle Bin?',
      'move': 'Move',
      'moveTo': 'Move to',
      'rename': 'Rename',
      'generate': 'Generate',
      'deleteFolder': 'Delete folder',
      'renameFolder': 'Rename folder',
      'deleteFolderMessage':
          'This folder will be deleted and all files inside will be moved to "All Files". Continue?',
      'generateAiSummary': 'Generate AI Summary',
      'moveToFolder': 'Move to Folder',
      'syncing': 'Syncing',
      'syncingPercent': 'Syncing {p}%',
      'resync': 'Resync',
      'resyncStarted': 'Resync started',
      'connectDeviceToResync': 'Please connect device to resync',
      'resyncBlockedWhileRecordingOtherSession':
          'The device is recording another session. Stop or finish that recording before resyncing this one.',
      'resyncCouldNotStart':
          'Could not start sync right now. If you just started recording or Wi‑Fi fast sync is running, wait a moment and try again.',
      'transferring': 'Transferring',
      'transferBannerMinimizeTip': 'Hide to edge',
      'transferBannerRestoreTip': 'Tap to show transfer progress',
      'fastSync': 'Fast Sync',
      'transferSpeedLabel': 'Speed: {s}',
      'fastSyncSheetTitle': 'Wi‑Fi fast sync',
      'fastSyncCloseTurnOffWifi': 'Close',
      'fastSyncDismissHint':
          'This sheet closes when transfer starts; progress is on the home list. '
              'Closing manually (button, outside, or swipe) turns off the device hotspot.',
      'fastSyncStoppingBle': 'Stopping Bluetooth transfer…',
      'fastSyncSwitchedNetworkTitle': 'Connected to a different Wi‑Fi',
      'fastSyncSwitchedNetworkMessage':
          'Your phone keeps switching back to a saved Wi‑Fi instead of the recorder’s '
              'network, so fast sync can’t run. Open Wi‑Fi settings, tap your other '
              'saved networks and choose "Forget" (or turn off their auto‑join), then '
              'join the recorder’s hotspot (the "ClipAP_" network). Once the saved '
              'networks are forgotten the phone stops switching away. Continuing over '
              'Bluetooth for now.',
      'fastSyncOpenWifiSettings': 'Open Settings',
      'fastSyncWifiFallbackTitle': 'Wi‑Fi fast sync didn’t complete',
      'fastSyncWifiFallbackMessage':
          'Fast sync over Wi‑Fi couldn’t finish — your phone may be on a different '
              'Wi‑Fi, didn’t join the recorder’s hotspot, or the signal was too '
              'weak. Switched to Bluetooth to keep syncing. For faster transfers, '
              'open Wi‑Fi settings and join the device hotspot below, and turn off '
              'auto‑join (or forget) your usual Wi‑Fi so the phone stops switching '
              'away.',
      'fastSyncWifiDisconnectedTitle': 'Wi‑Fi disconnected',
      'fastSyncWifiDisconnectedMessage':
          'Your phone is not on the recorder’s Wi‑Fi (Wi‑Fi may be off or you switched '
              'networks). Continuing over Bluetooth. Turn Wi‑Fi back on only if you '
              'want to try fast sync again later.',
      'fastSyncWifiVerifyTimeoutTitle': 'Could not join device Wi‑Fi',
      'fastSyncWifiVerifyTimeoutMessage':
          'The recorder’s hotspot is on, but the phone did not connect in time. '
              'Continuing over Bluetooth. Next time, open Wi‑Fi settings, join the '
              'device hotspot below, and turn off auto‑join (or forget) your usual '
              'Wi‑Fi so the phone stops switching away.',
      'fastSyncDeviceWifiNetworkLabel': 'Device Wi‑Fi',
      'fastSyncDeviceWifiPasswordLabel': 'Password',
      'fastSyncCopied': 'Copied',
      'fastSyncWifiFailedTitle': 'Wi‑Fi sync didn’t go through',
      'fastSyncWifiFailedMessage':
          'Your phone joined the recorder’s Wi‑Fi but the connection was too weak '
              'to transfer data. Continuing over Bluetooth. If this keeps happening, '
              'move closer to the device or reconnect to its Wi‑Fi and try again.',
      'fastSyncCancelBleFailed': 'Could not stop Bluetooth transfer',
      'fastSyncUnavailableWhileRecording':
          'Fast Sync is not available while the device is recording. Stop recording first.',
      'fastSyncStillRunningCannotRecord':
          'Wi‑Fi sync is still stopping. Wait a moment, then try recording again.',
      'fastSyncNoSession': 'Missing session id for this recording',
      'fastSyncPreparing': 'Preparing…',
      'fastSyncLaunchingWifi': 'Starting hotspot and Wi‑Fi sync…',
      'fastSyncEnablingHotspot': 'Starting device hotspot…',
      'fastSyncJoiningWifi': 'Joining device Wi‑Fi…',
      'fastSyncIosLocalNetworkTitle': 'Local network access',
      'fastSyncIosLocalNetworkMessage':
          'Wi‑Fi fast sync reaches your recorder on the local network. When iOS asks, tap Allow for local network access. If you chose Don’t Allow before, turn it on under Settings → Privacy & Security → Local Network for this app.',
      'fastSyncOpenAppSettings': 'Open Settings',
      'fastSyncVerifyingUdp': 'Verifying connection…',
      'fastSyncTransferring': 'Transferring over Wi‑Fi…',
      'fastSyncMerging': 'Merging files…',
      'fastSyncRestoringWifi': 'Restoring phone Wi‑Fi…',
      'fastSyncDone': 'Done',
      'fastSyncFailed': 'Transfer failed',
      'fastSyncBytesProgress': '{r} / {t}',
      'errWifiHandoff': 'Switching to Wi‑Fi…',
      'errWifiFastSyncUnreachable':
          'Wi‑Fi fast sync could not reach the device. Use Bluetooth sync, or join the recorder hotspot in Settings → Wi‑Fi and try Fast Sync again.',
      'errWifiFastSyncDisconnected':
          'Wi‑Fi is off or not on the device network. Continuing over Bluetooth.',
      'errInvalidSessionId':
          'Invalid session id for this recording (bad device list). Refresh the recordings list or reconnect the device.',
      'syncAll': 'Sync All',
      'syncAllResult': 'Synced {n} session(s)',
      'syncComplete': 'Sync complete',
      'syncFailed': 'Sync failed',
      'errDeviceDisconnectedResume':
          'Device disconnected. Will resume after reconnecting.',
      'errCreateLocalDirFailed': 'Failed to create local directory.',
      'errTransferIncompleteSize':
          'Transfer incomplete (size too small). Will re-download.',
      'errLocalFileDeleted': 'Local file deleted. Will re-download.',
      'errLocalFileIncomplete': 'Local file incomplete. Will re-download.',
      'errDeviceSessionMissing': 'Recording no longer on device.',
      'errDeviceSessionMissingCannotResume':
          'Recording no longer on device. Cannot resume.',
      'errTransferIncompleteResume':
          'Transfer incomplete. Will resume after reconnecting.',
      'errNoValidAudio': 'No valid audio data received.',
      'errUserCancelled': 'Cancelled.',
      'errDeviceRecordingResumeLater':
          'Device is recording. Transfer will resume when recording ends.',
      'errDeviceDisconnectedResumeAfterReconnect':
          'Device disconnected. Will resume after reconnecting.',
      'errStalledNoData3Min':
          'No data for 3 minutes. Transfer paused — tap resync to continue.',
      'errMergedFileIncomplete':
          'Merge failed: the merged file is incomplete (some slices were missing). Try syncing again.',
      'transferCancelled': 'Transfer cancelled',
      'cancelTransferOnlyActive':
          'Only the currently transferring recording can be cancelled',
      'transferringWhileRecording': 'Unavailable while recording',
      'waitCurrentTransferToRetry':
          'Please wait for the current transfer to complete before retrying',
      'today': 'TODAY',
      'yesterday': 'YESTERDAY',
      'earlier': 'EARLIER',
      'createFolder': 'Create Folder',
      'folderName': 'FOLDER NAME',
      'folderNameExample': 'e.g., University Lectures',
      'chooseColor': 'CHOOSE COLOR',
      'chooseIcon': 'CHOOSE ICON',
      'newName': 'New name',
      'folderNameHint': 'Folder name',

      // Recording Detail / AI actions
      'source': 'Source',
      'note': 'Note',
      'localAudioMissing':
          'Local audio file not found. Please sync to your phone first.',
      'localAudioUnplayable':
          'This audio file cannot be played. Try syncing again from the recorder, or contact support if it keeps happening.',
      'needTranscriptFirst':
          'Please generate transcript first, then summarize.',
      'llmTemplateNotSelected': 'LLM/Template not selected',
      'noTranscriptYet': 'No Transcript Yet',
      'configureApiAndTranscribe':
          'Configure your API and click below to transcribe\nand summarize',
      'transcribeAndSummarize': 'Transcribe & Summarize',
      'transcription': 'Transcription',
      'generateSummary': 'Generate Summary',
      'chooseSummaryVersion': 'Choose summary version',
      'summary': 'Summary',
      'summaryVersionPrefix': 'Summary',
      'deleteCurrentSummary': 'Delete current summary',
      'aiGenerating': 'AI is generating…',
      'summaryComplete': 'Summary complete',
      'backgroundingEnabled': 'BACKGROUNDING ENABLED',
      'aiDisclaimer': 'Content generated by AI for reference only',
      'noSummaryYet': 'No Summary Yet',
      'configureApiAndClickPlus': 'Configure your API and click + to summarize',
      'template': 'Template',
      'autoSpeakerLabeling': 'Auto Speaker Labeling',
      'autoSpeakerHint':
          'Speaker labeling prefers Deepgram when available for more stable diarization.',
      'audioLanguage': 'Audio Language',
      'sttModel': 'STT Model',
      'sttConfiguration': 'STT Configuration',
      'llmModel': 'LLM Model',
      'llmConfiguration': 'LLM Configuration',
      'generateNow': 'Generate Now',
      'aiDataSharingConsentTitle': 'AI data sharing',
      'aiDataSharingConsentIntro':
          'To use transcription or summary generation, this app needs to send selected recording data to cloud AI services.',
      'aiDataSharingConsentShortMessage':
          'To use transcription or summary, the app will send the selected recording audio, transcript text, and necessary device/recording information to {recipients} for AI processing. Please confirm whether you agree.',
      'aiDataSharingConsentAudio':
          'Audio data: the selected recording audio may be uploaded for speech-to-text processing.',
      'aiDataSharingConsentTranscript':
          'Transcript data: transcript text may be sent for summary generation.',
      'aiDataSharingConsentMetadata':
          'Related metadata: recording ID, device ID, language, speaker-labeling option, and selected AI configuration may be sent to process the request.',
      'aiDataSharingConsentRecipients': 'Recipients: {recipients}.',
      'aiDataSharingConsentProtection':
          'The data is used only to provide the requested AI result and is handled under the privacy policy and the selected provider protections.',
      'aiDataSharingConsentCheckbox':
          'I agree to send the above data for AI processing.',
      'aiDataSharingConsentAllow': 'Allow and continue',
      'aiDataSharingConsentDecline': 'Do not allow',
      'aiDataSharingConsentSenseCraftCloud': 'SenseCraft Voice cloud service',
      'aiDataSharingConsentSelectedAiProviders':
          'the selected or configured third-party AI service providers',

      // AI Config
      'aiConfiguration': 'AI Configuration',
      'guide': 'Guide',
      'serviceConfiguration': 'SERVICE CONFIGURATION',
      'sttService': 'STT Service',
      'llmService': 'LLM Service',
      'notConfigured': 'Not configured',
      'configured': 'CONFIGURED',
      'configure': 'CONFIGURE',
      'loading': 'Loading...',
      'promptTemplates': 'PROMPT TEMPLATES',
      'viewMoreTemplates': 'view more templates',
      'sessionHistory': 'SESSION HISTORY',
      'sessionMessages': 'Session Messages',
      'noSessions': 'No sessions yet',
      'noMessages': 'No messages yet',
      'deleteSession': 'Delete session',
      'deleteSessionMessage': 'Delete this session and its messages?',
      'deleteMessage': 'Delete message',
      'deleteMessageConfirm': 'Delete the latest message in this session?',
      'custom': 'Custom',
      'summarize': 'Summarize',
      'summarizeAgain': 'Summarize Again',
      'transcribeAgain': 'Transcribe Again',
      'batchTranscribe': 'Batch transcribe',
      'batchTranscribeSummary':
          'Batch transcribe done: {ok} succeeded, {fail} skipped or failed.',
      'batchTranscribingFilesProgress': 'Transcribing file {c} of {t}…',
      'batchTranscribingFloatingHint':
          'You can leave this page; each file updates in the list when done.',
      'batchTranscribeSwipeToHide': 'Swipe sideways to hide',
      'batchTranscribeShowProgress': 'Show transcribe progress',
      'batchTranscribeAlreadyRunning':
          'Batch transcribe is already in progress',
      'processing': 'Processing...',
      'preparingAudioForTranscription': 'Preparing audio on device… {p}%',
      'transcriptionWorkInProgress': 'Working on transcription…',
      'transcribingChunkProgress': 'Transcribing… {c}/{t} segments done',
      'statusQueued': 'File uploading...',
      'statusCompleted': 'Completed',
      'statusFailed': 'Failed',
      'transcribing': 'Transcribing...',
      'waveformBuilding': 'Building waveform…',
      'playbackPreparing': 'Preparing playback…',
      'summarizing': 'Summarizing...',
      'errorTitle': 'Error',
      'saveAs': 'Save As',
      'speakerModeSwitchedProvider':
          'Speaker labeling switched transcription provider to {provider}.',
      'speakerModeFallbackNormal':
          '{provider} does not support speaker labeling. Continued with normal transcription.',
      'newFileNameHint': 'New file name',
      'trimmedAudio': 'Trimmed audio',
      'trimSuffix': '(trim)',
      'trimOnlyWavSupported':
          'Only WAV(PCM16) audio is supported for trimming.',
      'trim': 'Trim',
      'smartEdit': 'Smart Edit',
      'smartEditTodo': 'Smart Edit (TODO)',
      'deleteTodo': 'Delete (TODO)',
      'asrVendorIdNotConfigured':
          'ASR vendor ID not configured. Please sync configs first.',
      'transcriptionFailed': 'Transcription failed: {error}',
      'uploadFileTooLarge': 'File too large (over {n}MB). Please trim first.',
      'uploadFileTooLarge413':
          'Upload failed: file too large. Please trim the recording first.',
      'uploadingProgress': 'Uploading... {n}%',
      'transcriptionGatewayTimeout':
          'Transcription timed out. The server is still processing. Please try again.',
      'transcriptionGatewayTimeoutRetry': 'Retry',
      'summaryFailed': 'Summary failed: {error}',
      'moveToRecycleBinConfirmName': 'Move "{name}" to Recycle Bin?',
      'viewAll': 'View All',
      'select': 'Select',
      'auto': 'Auto',
      'share': 'Share',
      'shareLink': 'Share Link',
      'copyToClipboard': 'Copy to Clipboard',
      'copySuccess': 'Copied',
      'transcriptCopied': 'Transcript copied',
      'noteCopied': 'Note copied',
      'exportFile': 'Export File',
      'audio': 'Audio',
      'shareContent': 'Share Content',
      'shareLinkExpiry': 'Anyone with the link can access. Expires in 7 days.',
      'linkCopied': 'Link copied',
      'copyLink': 'Copy Link',
      'exportAudio': 'Export Audio',
      'exportTranscript': 'Export Transcript',
      'exportNote': 'Export Note',
      'exportFormat': 'Export Format',
      'export': 'Export',
      'exportRecording': 'Export Recording',
      'exporting': 'Exporting...',
      'exportingPercent': 'Exporting ({p}%)',
      'noAudioToExport': 'No audio file to export.',
      'audioFileNotFound': 'Audio file not found.',
      'shareFailed': 'Share failed: {error}',
      'transcodeFailed': 'Transcode failed: {error}',
      'wavExportNeedsConversion':
          'WAV export requires conversion (server endpoint reserved).',
      'mp3ExportNeedsConversion':
          'MP3 export requires conversion (server endpoint reserved).',
      'unsupportedAudioFormat': 'Unsupported audio export format.',
      'noTranscriptToExport': 'No transcript to export.',
      'formatExportNeedsServer':
          '{format} export requires server generation (endpoint reserved).',
      'noNoteToExport': 'No note to export.',
      'searchRecordingsOrQa': 'Search recordings or Q&A',
      'loadFailed': 'Load failed: {error}',
      'totalResults': 'Total {count} Results',
      'recentSearches': 'RECENT SEARCHES',
      'searchEmptyHint': 'Enter keywords to search recordings or\nQ&A',
      'creationTime': 'Creation Time',
      'last7Days': 'Last 7 Days',
      'last30Days': 'Last 30 Days',
      'last3Months': 'Last 3 Months',
      'last6Months': 'Last 6 Months',
      'lastYear': 'Last Year',
      'sinceRegistration': 'Since Registration',
      'fromDevice': 'From Device',
      'sourceLocal': 'Local',
      'transcriptStatus': 'Transcript Status',
      'transcribed': 'Transcribed',
      'notTranscribed': 'Not Transcribed',
      'transcriptionFailedShort': 'Transcription failed',
      'deviceN': 'Device {n}',
      'startsAt': 'STARTS AT',
      'endsAt': 'ENDS AT',
      'selectDate': 'Select Date',
      'apply': 'Apply',
      'deleteSegment': 'Delete segment',
      'keepSegment': 'Keep segment',
      'recordingStartFailed': 'Failed to start recording',
      'markFailedNotRecording': 'Mark failed: not recording',
      'markAdded': 'Marked at {time}',
      'markFailedDeviceNotReady':
          'Mark failed: not recording or device not ready',
      'markByDeviceButton': 'Bookmark added from device at {time}',
      'deviceButtonStartedRecording': 'Device started recording',
      'deviceButtonStoppedRecording': 'Device stopped recording',
      'endRecording': 'End recording?',
      'endRecordingMessage':
          'Stop and save this recording, or continue recording?',
      'stopAndSave': 'Stop & Save',
      'continueRecording': 'Continue Recording',
      'continueRecordingSnack': 'Continuing recording',
      'recordingStopFailed': 'Failed to stop recording',
      'pauseFailed': 'Failed to pause recording',
      'resumeFailed': 'Failed to resume recording',
      'recordingFinishedSyncing': 'Recording ended and syncing started',
      'microphonePermissionDenied':
          'Microphone permission denied. Unable to record.',
      'photoPermissionRequiredTitle': 'Photo access required',
      'photoPermissionRequiredForAvatarMessage':
          'Allow photo library access for this app in Settings to change your profile photo.',
      'notificationPermissionDenied':
          'Notification permission denied. Push will be off.',
      'bluetoothPermissionDenied':
          'Bluetooth permission denied. Unable to scan devices.',
      'bluetoothDisabledTitle': 'Bluetooth is off',
      'bluetoothDisabledHint':
          'Turn on Bluetooth to search for nearby devices.',
      'turnOnBluetooth': 'Turn on Bluetooth',
      'bluetoothRequiredTitle': 'Bluetooth required',
      'bluetoothOffForConnectMessage':
          'Turn on Bluetooth in Settings to connect or add a device.',
      'bluetoothPermissionRequiredForConnectMessage':
          'Allow Bluetooth access for this app in Settings to connect or add a device.',
      'openSettingsAction': 'Open Settings',
      'scanLocationRequiredTitle': 'Location needed to find devices',
      'scanLocationServiceOffMessage':
          "Your phone's location switch is off. Android needs location turned "
              'on to discover Bluetooth devices. Turn it on, then scan again.',
      'scanLocationPermissionMessage':
          'This app needs location permission to discover Bluetooth devices on '
              'your Android version. Grant it, then scan again.',
      'opusNotSupported': 'Current device does not support Opus encoding',
      'recordingSavedLocally':
          'Recording saved locally (for server API testing)',
      'noDeviceConnected': 'No Device Connected',
      'connectDeviceToRecord':
          'Please connect your SenseCraft Voice via\nBluetooth to start recording.',
      'deviceDisconnectedReconnecting':
          'Device disconnected. Attempting to reconnect...',
      'reconnectFailed': 'Reconnect failed. Please connect manually.',
      'connectNow': 'Connect Now',
      'recordingFinished': 'Recording Finished',
      'recordingFinishedLocal': 'Recording finished and saved locally.',
      'recordingFinishedDevice': 'Recording finished and saved to device.',
      'backToFiles': 'Back to Files',
      'ready': 'Ready',
      'paused': 'Paused',
      'deviceRecording': 'Device Recording',
      'preparingRecording': 'Preparing to record…',
      'localRecording': 'Local Recording',
      'mark': 'MARK',
      'pause': 'PAUSE',
      'resume': 'RESUME',
      'record': 'RECORD',
      'recording': 'Recording',
      'finish': 'FINISH',
      'keyAt': 'Key {time}',
      'localRecordingName': 'Local Recording {ts}',
      'recordingName': 'Recording {ts}',
      'seekBack5s': 'Seek back 5s',
      'seekForward5s': 'Seek forward 5s',
      'content': 'Content',
      'shareLinkText': 'SenseCraft Voice share link ({content})\n{link}',
      'shareAudioExportText': 'SenseCraft Voice audio export',
      'shareAudioExportOpusText': 'SenseCraft Voice audio export (Opus)',
      'shareTranscriptExportText': 'SenseCraft Voice transcript export',
      'shareNoteExportText': 'SenseCraft Voice note export',
      'ffmpegError': 'FFmpeg error',
      'sttProviderAliyun': 'Aliyun',
      'sttProviderFunasr': 'Self-hosted FunASR',
      'sttProviderOpenAiWhisper': 'OpenAI Whisper',
      'sttProviderGoogleGemini': 'Google Gemini',
      'sttProviderDeepgram': 'Deepgram',
      'sttProviderLocalWhisper': 'Local Whisper',
      'sttProviderVosk': 'Vosk',
      'sttProviderIflytek': 'iFlytek',
      'sttProviderTencent': 'Tencent',
      'sttProviderBaidu': 'Baidu',
      'sttProviderDoubao': 'Doubao ASR',
      'sttProviderOnDevice': 'On-device Local STT',
      'llmProviderOpenAi': 'OpenAI GPT',
      'llmProviderAnthropic': 'Anthropic Claude',
      'llmProviderGoogleGemini': 'Google Gemini',
      'llmProviderLlama': 'Llama',
      'llmProviderDoubao': 'Doubao',
      'llmProviderQwen': 'Qwen',
      'llmProviderDeepseek': 'DeepSeek',
      'llmProviderOpenRouter': 'OpenRouter',

      // Home bottom tabs
      'filesTab': 'FILES',
      'aiConfigTab': 'AI CONFIG',

      // Device
      'device': 'Device',
      'disconnect': 'Disconnect',
      'atDebug': 'AT Debug',
      'connect': 'Connect',
      'noValue': '—',
      'lastResponseLabel': 'Last response: {value}',
      'scanResultsCount': 'Scan results ({n})',
      'scanning': 'Scanning...',
      'startScan': 'Start Scan',
      'noName': '(no name)',
      'deviceDetailsInfo': 'Device Details & Info',
      'deviceNotFound': 'Device not found',
      'online': 'Online',
      'offline': 'Offline',
      'deviceNameLabel': 'Device Name',
      'statusLabel': 'Status',
      'modelLabel': 'Model',
      'batteryLabel': 'Battery',
      'recordingModeLabel': 'Recording Mode',
      'firmwareVersionLabel': 'Firmware Version',
      'disconnectAction': 'Disconnect',
      'resetDeviceAction': 'Reset Device',
      'unbindDeviceAction': 'Unbind Device',
      'unpairDeviceAction': 'Unpair',
      'unpairDeviceTitle': 'Unpair Device',
      'unpairDeviceMessage':
          'Required before this device can pair with another phone.\n\n'
              'Clears pairing info on the device and disconnects. '
              'Recordings on the device are not deleted.',
      'unpairConfirm': 'Unpair',
      'unpairDoneSnack': 'Pairing cleared',
      'unpairFailedSnack': 'Unpair failed, please try again later',
      'unpairSentSnack':
          'Pairing cleared and disconnected. Re-pair on next connect.',
      'unpairConnectFirst': 'Please connect the device first to unpair',
      'renameDeviceTitle': 'Rename Device',
      'deviceNameHint': 'Device Name',
      'renameOfflineHint':
          'Device is not connected. The new name will be saved locally now '
              'and pushed to the device on next connection.',
      'renameInvalid':
          'Invalid name. Use 1-32 characters, no control characters.',
      'folderNameInvalid':
          'Invalid folder name. Use 1-24 characters, no control characters.',
      'renameSavedOnDevice': 'Name updated and saved on device',
      'renameSavedLocallyWillSync':
          'Name saved locally; will sync to device on next connection',
      'renameFailed': 'Rename failed, please try again',
      'renameDeviceRejected': 'Device rejected the name: {detail}',
      'renameAtFailed': 'Could not save to device: {detail}',
      'deviceModificationSuccess': 'Modification successful',
      'disconnectDeviceTitle': 'Disconnect Device',
      'disconnectDeviceMessage':
          'This will only break the Bluetooth connection between your phone and SenseCraft Voice. The device remains bound to your account.',
      'disconnectedSnack': 'Disconnected',
      'disconnectSentSnack':
          'Disconnected. Device keeps running. You can reconnect anytime.',
      'resetDeviceTitle': 'Reset Device',
      'resetDeviceMessage':
          'This will reset all device parameters to factory defaults.',
      'resetDoneSnack': 'Reset initiated (Demo)',
      'resetSentSnack':
          'Command sent. Device will factory reset and reboot. Connection closed.',
      'resetConfirm': 'Reset',
      'purgeDeviceSessions': 'Purge Device Sessions',
      'purgeDeviceSessionsConfirm':
          'This will permanently delete all recordings on the device. This cannot be undone.',
      'purging': 'Purging...',
      'purgeDeviceSessionsDone': 'All device sessions deleted',
      'purgeDeviceSessionsFailed': 'Purge failed, please try again',
      'purgeDeviceSessionsConnectFirst':
          'Please connect this device first to delete recordings on it.',
      'unbindDeviceTitle': 'Unbind Device',
      'unbindConfirm': 'Unbind',
      'unbindDeviceMessage':
          'Disconnects if connected, clears pairing on the device when connected, '
              'then removes this device from the app list. '
              'Does not delete recordings on the device.',
      'unbindIosForgetReminderTitle': 'Device unbound',
      'unbindIosForgetReminderMessage':
          'Pairing on the device has been cleared, but the phone usually still keeps the old Bluetooth record.\n\n'
              'Before you reconnect, open Settings > Bluetooth, find this device, choose Forget / Unpair, then return to the app and add it again.',
      'unbinding': 'Unbinding...',
      'unbindDoneSnack': 'Device unbound and removed from app',
      'recordingModeNormal': 'Normal',
      'recordingModeEnhanced': 'Enhanced',
      'deviceDetailsRefresh': 'Refresh',
      'deviceDetailsConnectFirstToRefresh':
          'Please connect the device first to refresh.',
      'deviceDetailsRefreshed': 'Device info refreshed.',
      'deviceDetailsRuntimeSectionTitle': 'Device runtime status (AT)',
      'deviceDetailsReadingAtInfo': 'Reading AT info from device…',
      'deviceDetailsDeviceTime': 'Device time',
      'deviceDetailsWorkState': 'Work state',
      'deviceDetailsBatteryAt': 'Battery (AT)',
      'deviceDetailsModeAt': 'Mode (AT)',
      'deviceDetailsPairStatus': 'Pair status',
      'deviceDetailsPairAddress': 'Pair address',
      'deviceDetailsAtInfoUnavailable':
          'Unable to get AT info (device not connected or response timed out).',
      'deviceDetailsSettingFailedRetry':
          'Setting failed, please try again later.',
      'deviceDetailsConnectFirstToReset':
          'Please connect the device first to reset.',
      'connectingTo': 'Connecting to {name}...',
      'connectedTo': 'Connected to {name}',
      'connectionFailedCheck': 'Connection failed. Please check device status.',
      'connectionFailedScanAndAdd':
          'Connection failed. Please scan and add the device manually.',
      'connectionFailedUnpairHint':
          'If it still fails, open the phone\'s Bluetooth settings, Forget this device, then add it again.',
      'connectionFailedIosForgetTitle': 'Forget device in Bluetooth settings',
      'forgetDeviceInSettingsAction': 'Open Settings to Forget',
      'errIosPeerRemovedPairingInfo':
          'Connection failed: the Bluetooth pairing keys on this phone and the device no longer match (common after unbinding).\n\n'
              'Open Settings > Bluetooth, find this device, choose Forget / Unpair, then return to the app and add it again.',
      'errIosStaleBluetoothPairing':
          'Connection failed: the Bluetooth pairing keys on this phone and the device no longer match (common after unbinding).\n\n'
              'Open Settings > Bluetooth, find this device, choose Forget / Unpair, then return to the app and add it again.',
      'addDevice': 'Add Device',
      'lastSeenJustNow': 'just now',
      'lastSeenMinutesAgo': '{m}m ago',
      'lastSeenHoursAgo': '{h}h ago',
      'lastSeenDaysAgo': '{d}d ago',
      'currentLabel': 'CURRENT',
      'searchingForDevices': 'Searching for devices...',
      'ensureDeviceOn':
          'Please ensure that the device is powered on\nand not bound to other accounts.',
      'devicesFound': 'DEVICES FOUND',
      'rescan': 'RESCAN',
      'setupHelp': 'Setup Help',
      'step1': 'STEP 1',
      'step2': 'STEP 2',
      'longPressRecording':
          'Long press the Recording Button\nuntil the screen lights up.',
      'bringDeviceClose': 'Bring the device close to your phone.',
      'keepWithinMeters': 'KEEP WITHIN 0.5 METERS',
      'needMoreHelp': 'Need more help?',
      'gotItTryAgain': 'Got it, try again',
      'startUsing': 'Start Using',
      'retry': 'Retry',
      'connecting': 'Connecting...',
      'androidPairingConfirmHint':
          'If a system pairing dialog appears, confirm the pairing code to continue.',
      'connectedSuccessfully': 'Connected Successfully',
      'connectionFailed': 'Connection failed',
      'firmwareUpdate': 'Firmware Update',
      'downloadingNewVersion': 'Downloading New Version...',
      'installing': 'Installing...',
      'keepDeviceClose': 'Keep the device close and Bluetooth\nconnected.',
      'doNotTurnOffDuringInstall':
          'Do not turn off your device or close the app during\nthe installation process to ensure firmware\nintegrity.',
      'remaining': '~4 min remaining',
      'lastSeenLabel': 'Last seen {time}',
      'snLabel': 'SN',
      'deviceProtocolSummary':
          'Protocol: Clip AT over BLE(GATT)\n- Service=6E400001...\n- Command(Write)=6E400002...\n- Response/Progress(Notify)=6E400003...\n- FileData(Notify)=6E400004...',
      'deviceMtuLabel': 'Current MTU: {mtu} (payload ≈ {payload} bytes)',
      'canNotFindDevice': "Can't find your device?",
      'notLightingUpHint': "Not lighting up? Charge for 10 mins and try again.",
      'defaultDeviceName': 'SenseCraft Voice Lav',
      'connectionFailedTryAgain':
          'Please check device status. Make sure the device is powered on and within range.',
      'scanningChip': 'SCANNING',
      'firmwareUpToDate': 'Firmware is up to date',
      'versionColon': 'version: {v}',
      'newFirmwareTitle': 'New Firmware',
      'newFeaturesTitle': 'New Features',
      'systemCheckTitle': 'SYSTEM CHECK',
      'downloadUpdateNow': 'Download Update Now',
      'laterButton': 'Later',
      'newFirmwareVersion': 'New Firmware: {v}',
      'updateSuccessfulTitle': 'Update Successful',
      'updateSuccessfulMessage':
          'Your SenseCraft Voice has been updated to the latest version {version}.',
      'updateSuccessfulMessageWait':
          'Your device has been upgraded to the latest. Please wait for the device to complete the upgrade.',
      'updateFailedTitle': 'Update Failed',
      'updateFailedMessage':
          'Upgrade failed. Please keep Bluetooth connected and try again later.',
      'backToDevice': 'Back to Device',
      'batteryCheckLabel': 'Charging or battery ≥ 50%',
      'notRecordingLabel': 'Not Recording',
      'deviceConnectedLabel': 'Device Connected',
      'firmwareLabel': 'Firmware',
      'selectFirmwareFile': 'Select Firmware File (ZIP/BIN)',
      'startFirmwareUpdate': 'Start Firmware Update',
      'uploadingFirmware': 'Uploading firmware...',
      'otaCompleting': 'Completing, please wait...',
      'otaDeviceNotConnected':
          'Please connect the device first to perform firmware update.',
      'cloudFirmwareTitle': 'CLOUD UPDATE',
      'cloudFirmwareChecking': 'Checking for updates...',
      'cloudFirmwareCheckAgain': 'Check again',
      'cloudFirmwareCheckFailed': 'Failed to check for updates',
      'cloudFirmwareDownloading': 'Downloading firmware...',
      'downloadFirmwareButton': 'Download Firmware',
      'firmwareDownloadedReady': 'Firmware downloaded, ready to install.',
      'firmwareMustUpdate': 'REQUIRED UPDATE',
      'localFirmwareTitle': 'LOCAL FILE',
      'selectFirmwareFileAgain': 'Choose another file',
      'fromCloudLabel': 'From cloud',
      'fromLocalLabel': 'Local file',
      'cancelButton': 'Cancel',
      'cloudFirmwareNoPermission':
          'Your account does not have permission to check cloud firmware updates. You can still install a local firmware file.',
      'cloudFirmwareInvalidToken':
          'Cloud firmware check failed (invalid login session). Try signing out and back in, or use a local firmware file.',
      // Recording - extra
      'deviceRecordingNoPauseResume':
          'Device recording does not support pause/resume yet.',
      'playbackSpeedTimes': '{s}x',
      'trimTimeZero': '0:00',
      // AI Config - extra
      'providerLabel': 'Provider',
      'hintModelExample': 'e.g., gpt-4o',
      'hintJsonExample': '{"foo":"bar"}',
      'savedLocalSyncFailed': 'Saved locally, server sync failed: {error}',
      'deleteConfigurationTitle': 'Delete Configuration',
      'deleteConfigurationConfirm': 'Are you sure you want to delete "{name}"?',
      'deletedLocalDeleteFailed':
          'Deleted locally, server delete failed: {error}',
      'llmProviders': 'LLM Providers',
      'sttProviders': 'STT Providers',
      'noProvidersYet': 'No providers configured yet',
      'addLlmConfigSubtitle':
          'Add an LLM configuration to enable summary generation.',
      'addSttConfigSubtitle':
          'Add an STT configuration to enable transcription.',
      'addNewConfiguration': 'Add New Configuration',
      'saveConfiguration': 'Save Configuration',
      'pleaseAddLlm': 'Please add your LLM configuration.',
      'pleaseAddStt': 'Please add your STT configuration.',
      'getStarted': 'Get Started',
      'llmConfigurationTitle': 'LLM Configuration',
      'llmConfigurationSubtitle': 'Large Language Model settings',
      'llmProviderTitle': 'LLM Provider',
      'sttConfigurationTitle': 'STT Configuration',
      'sttConfigurationSubtitle': 'Speech-to-Text service settings',
      'sttProviderTitle': 'STT Provider',
      'addConfiguration': 'Add Configuration',
      'finishSetup': 'Finish Setup',
      'sttProviderChip': 'STT PROVIDER',
      'llmProviderChip': 'LLM PROVIDER',
      'templatesTitle': 'Templates',
      'addNewTemplate': 'Add New Template',
      'createTemplate': 'Create Template',
      'hintMeetingMinutes': 'e.g., Meeting Minutes',
      'hintEnterPrompt': 'Enter prompt...',
      'importTemplate': 'Import Template',
      'hintShareKey': 'e.g. xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',
      'importAction': 'Import',
      'invalidKeyOrSharingStopped': 'Invalid key or sharing stopped.',
      'importFailed': 'Import failed: {error}',
      'templateDetails': 'Template Details',
      'notFound': 'Not found',
      'templateNameHint': 'Template name',
      'promptHint': 'Prompt...',
      'stopSharingFailed': 'Stop sharing failed: {error}',
      'generateShareKey': 'Generate Share Key',
      'copied': 'Copied',
      'saveChanges': 'Save Changes',
      'deleteTemplateTitle': 'Delete Template',
      'deleteTemplateConfirm': 'Are you sure you want to delete "{name}"?',
      'importWithKey': 'Import with Key',
      'templateKey': 'TEMPLATE KEY',
      'hintWhisperExample': 'e.g., whisper-1',
      'hintWssUrl': 'wss://',
      'hintBaseUrlExample': 'e.g., http://localhost:10095',
      'hintBaseUrlExampleHttps': 'e.g., https://api.openai.com',
      'hintRegionExample': 'e.g., cn-hangzhou',
      'hintModelPathExample': 'e.g., /path/to/model.bin',
      'hintIflytekApiSecret': 'APISecret from xfyun.cn (接口密钥)',
      'hintAliyunTingwuAppKey': 'Tingwu AppKey',
      'hintAliyunAccessKeyId': 'AccessKey ID',
      'hintAliyunAccessKeySecret': 'AccessKey Secret',
      'hintLocalhostVosk': 'http://localhost:2700',
      'hintLocalhostLocalWhisper': 'http://localhost:8080',
      'hintIflytekAppId': 'APPID',
      'hintLlmDoubaoModelName': 'e.g. ep-xxx or doubao-seed-2-0-pro-260215',
      'hintLlmOpenRouterModelName':
          'e.g. anthropic/claude-sonnet-4, google/gemini-2.5-flash, openai/gpt-4o. See openrouter.ai/models',
      'hintLlmOpenAiModelName': 'e.g. gpt-4o, gpt-4o-mini',
      'hintLlmAnthropicModelName':
          'e.g. claude-sonnet-4-0, claude-3-5-haiku-latest',
      'hintLlmGoogleGeminiModelName': 'e.g. gemini-2.5-flash, gemini-2.0-flash',
      'hintLlmQwenModelName': 'e.g. qwen-turbo, qwen-plus',
      'hintLlmDeepseekModelName': 'e.g. deepseek-chat, deepseek-reasoner',
      'hintLlmLlamaModelName': 'Model name on your Ollama / local server',
      'hintLlmCustomBaseUrl': 'e.g. http://localhost:11434/v1',
      'hintLlmQwenApiKey': 'DashScope API Key (dashscope.console.aliyun.com)',
      'hintLlmDeepseekApiKey': 'sk-... from platform.deepseek.com',
      'hintLlmOpenAiApiKey': 'sk-... from platform.openai.com',
      'hintLlmAnthropicApiKey': 'sk-ant-... from console.anthropic.com',
      'hintLlmGoogleGeminiApiKey': 'API key from aistudio.google.com',
      'hintLlmDoubaoApiKey': 'API key from Volcengine Ark console',
      'hintLlmOpenRouterApiKey': 'API key from openrouter.ai/keys',
      'hintLlmLlamaApiKey': 'Optional for local Ollama',
      'hintLlmModelCaption':
          'LLM model for summary generation. Not the same as STT / transcription models.',
      'hintLlmQwenModelCaption':
          'Use qwen-turbo or qwen-plus for summaries. Do not use fun-asr-realtime (that is STT only).',
      'hintLlmDeepseekModelCaption':
          'Use deepseek-chat for summaries. Base URL must be api.deepseek.com/v1, not the platform web page.',
      'hintSttModelCaption':
          'Speech-to-text model. For AI summaries configure a separate LLM service.',
      'hintSttAliyunModelCaption':
          'Transcription only: fun-asr-realtime. Summaries use LLM config with qwen-turbo.',
      'hintSttBaiduModelName': 'Leave empty for default or see Baidu ASR docs',
      'hintSttTencentModelName':
          'Leave empty for default or see Tencent ASR docs',
      'hintSttDoubaoModelName': 'See Volcengine ASR docs',
      // Guide flow
      'guideWelcomeTitle': 'Welcome!',
      'guideWelcomeSubtitle':
          "Let's configure your AI services to\nenable voice transcription and\nsmart summaries.",
      'guideSttServiceTitle': 'STT Service',
      'guideSttServiceSubtitle': 'Convert voice to text in real-time',
      'guideLlmServiceTitle': 'LLM Service',
      'guideLlmServiceSubtitle': 'Extract key points and summaries',
      'guideBackLabel': 'Back',
      'guideNextStepLabel': 'Next Step',
      'guideAddEditLaterHint':
          'You can add/edit configurations later in AI Configuration.',
      'guideAllSetTitle': 'All Set!',
      'guideAllSetSubtitle': 'Your AI services are ready to go.',
      'guideSttProviderLabel': 'STT PROVIDER',
      'guideLlmProviderLabel': 'LLM PROVIDER',
      'guideUpdateLaterHint':
          "You can always update these settings later from the\napp's settings menu.",
      // Template labels
      'templateNameLabel': 'TEMPLATE NAME',
      'promptContentLabel': 'PROMPT CONTENT',
      'tapTemplateToEdit': 'Tap any template to edit name and prompt details.',
      'enterKeyToImport': 'Enter the key shared by others to import',
      'shareTemplateLabel': 'SHARE TEMPLATE',
      'stopSharingLabel': 'Stop Sharing',
      'shareKeyDescription':
          'Share this key with others to let them import your custom prompt configuration.',
      // AI Config editor
      'configuredFilesLabel': 'CONFIGURED FILES',
      'addTooltip': 'Add',
      'apiKeyConfigDetails': 'API Key Configuration Details',
      'requiredLabel': 'REQUIRED',
      'optionalLabel': 'OPTIONAL',
      'advancedLabel': 'Advanced',
      'testConnection': 'Test Connection',
      'testConnectionSuccess': 'Test Connection ✓',
      'testFailed': 'Test failed: {error}',
      'updateConfigurationLabel': 'Update Configuration',
      // AI Config editor field labels
      'fieldLabelProvider': 'PROVIDER',
      'fieldLabelName': 'NAME',
      'fieldLabelApiKey': 'API KEY',
      'fieldLabelApiKeyOptional': 'API KEY (OPTIONAL)',
      'fieldLabelApiKeyRequired': 'API KEY (REQUIRED)',
      'fieldLabelBaseUrl': 'BASE URL',
      'fieldLabelBaseUrlRequired': 'BASE URL (REQUIRED)',
      'fieldLabelBaseUrlOptional': 'BASE URL (OPTIONAL)',
      'fieldLabelModelName': 'MODEL NAME',
      'fieldLabelModelNameOptional': 'MODEL NAME (OPTIONAL)',
      'fieldLabelModelNameRequired': 'MODEL NAME (REQUIRED)',
      'fieldLabelModelNameAdvanced': 'MODEL NAME (ADVANCED)',
      'fieldLabelModuleNameOptional': 'MODULE NAME (OPTIONAL)',
      'fieldLabelApiSecret': 'API SECRET',
      'fieldLabelApiSecretOptional': 'API SECRET (OPTIONAL)',
      'fieldLabelAppId': 'APP ID',
      'fieldLabelAppIdOptional': 'APP ID (OPTIONAL)',
      'fieldLabelAppIdRequired': 'APP ID (REQUIRED)',
      'fieldLabelAccessKeyId': 'ACCESS KEY ID',
      'fieldLabelAccessKeyIdOptional': 'ACCESS KEY ID (OPTIONAL)',
      'fieldLabelAccessKeySecret': 'ACCESS KEY SECRET',
      'fieldLabelAccessKeySecretOptional': 'ACCESS KEY SECRET (OPTIONAL)',
      'fieldLabelRegion': 'REGION',
      'fieldLabelRegionOptional': 'REGION (OPTIONAL)',
      'fieldLabelExtraJsonAdvanced': 'EXTRA JSON (ADVANCED)',
      'fieldLabelWsUrlOptional': 'WS URL (OPTIONAL)',
      'fieldLabelSecretKey': 'SECRET KEY',
      'fieldLabelSecretKeyOptional': 'SECRET KEY (OPTIONAL)',
      'fieldLabelSecretKeyRequired': 'SECRET KEY (REQUIRED)',
      'fieldLabelSecretId': 'SECRET ID',
      'fieldLabelSecretIdOptional': 'SECRET ID (OPTIONAL)',
      'fieldLabelSecretIdRequired': 'SECRET ID (REQUIRED)',
      'aliyunCredentialChoiceHint':
          'Fill in either API KEY (DashScope) OR App Key + Secret ID + Secret Key (Tingwu). Either set is enough.',
      'fieldLabelAliyunApiKeyChoice':
          'API KEY (DASHSCOPE, OR USE TINGWU BELOW)',
      'fieldLabelAliyunAppKeyChoice':
          'APP KEY (TINGWU, REQUIRED WITH ACCESS KEY)',
      'fieldLabelAliyunAccessKeyIdChoice':
          'ACCESS KEY ID (TINGWU, REQUIRED WITH APP KEY)',
      'fieldLabelAliyunAccessKeySecretChoice':
          'ACCESS KEY SECRET (TINGWU, REQUIRED WITH APP KEY)',
      'fieldLabelCluster': 'CLUSTER',
      'fieldLabelClusterRequired': 'CLUSTER (REQUIRED)',
      'fieldLabelAccessToken': 'ACCESS TOKEN',
      'fieldLabelAccessTokenRequired': 'ACCESS TOKEN (REQUIRED)',
      'fieldLabelModelPath': 'MODEL PATH',
      'fieldLabelLanguage': 'LANGUAGE',
      'fieldLabelTranscriptionMode': 'TRANSCRIPTION MODE',
      'iflytekModeFile': 'File transcription (recommended, record first)',
      'iflytekModeRealtime': 'Realtime transcription',
      'iflytekFileHint': 'Console → Recording file transcription (standard)',
      'iflytekRealtimeHint': 'Console → Realtime transcription (standard)',
      'validationIflytekSecretKeyForFile':
          'SecretKey required for file transcription',
      // AI Config validation
      'validationNameRequired': 'name required',
      'validationApiKeyRequired': 'API KEY required',
      'validationAliyunCredentialRequired':
          'Fill in DashScope API KEY, or complete Tingwu credentials.',
      'validationApiKeyRequiredLlc': 'API key required',
      'validationInvalidWsUrl': 'invalid WS URL',
      'validationBaseUrlRequired': 'BASE URL required',
      'validationAppIdRequired': 'APP ID required',
      'validationSecretKeyRequired': 'SECRET KEY required',
      'validationSecretIdRequired': 'SECRET ID required',
      'validationClusterAccessTokenRequired':
          'CLUSTER and ACCESS TOKEN required',
      'validationExtraJsonMustBeObject': 'EXTRA JSON must be an object',
      'validationExtraJsonMustBeValid': 'EXTRA JSON must be valid JSON',
      'validationAccessKeyIdRequired': 'ACCESS KEY ID required',
      'validationAccessKeySecretRequired': 'ACCESS KEY SECRET required',
      'validationRegionRequired': 'REGION required',
      'validationModelPathRequired': 'MODEL PATH required',
      'validationApiSecretRequired': 'API SECRET required',
      'validationBaseUrlRequiredLlc': 'Base URL required',
      'validationInvalidBaseUrl': 'invalid Base URL',
      'validationModelNameRequired': 'MODEL NAME required',
      'validationGeminiModelNameInvalid':
          'Gemini model name must look like gemini-2.5-flash',
      'validationModelNameFormatInvalid':
          '{provider} model name format is invalid. Example: {example}',
      'validationDoubaoModelEndpointRequired':
          'Create an endpoint in Volcano Ark console first, then fill the endpoint ID (e.g. ep-xxx)',
      // Auth - extra
      'appleSignInNotSupported':
          'Apple Sign-In is not supported on this device (please test on a real iOS device with Apple ID signed in).',
      'appleSignInNoToken':
          'Apple Sign-In did not return a token (check Sign in with Apple capability and signing).',
      'appleSignInError': 'Apple Sign-In error: {error}',
      'appleSignInCanceled': 'Apple Sign-In canceled',
      'appleSignInNotHandled':
          'Apple Sign-In not handled (system did not complete authorization).',
      'appleSignInNotInteractive':
          'Apple Sign-In not interactive (unlock device / disable screen recording limit).',
      'appleSignInCredentialExport':
          'Apple Sign-In failed: credential export failed.',
      'appleSignInCredentialImport':
          'Apple Sign-In failed: credential import failed.',
      'appleSignInMatchedExcluded':
          'Apple Sign-In failed: matched excluded credential.',
      'appleSignInFailed': 'Apple Sign-In failed. Please try again.',
      'appleSignInInvalidResponse':
          'Apple Sign-In failed: invalid response (check network and system).',
      'appleSignInUnknown':
          'Apple Sign-In failed: unknown error. Common causes: Sign in with Apple not enabled for App ID / certificates not updated / BundleId mismatch.',
      'passwordHintDots': '••••••••',
      'googleSignInFailedCode': 'Google Sign-In failed: {code}',
      'googleSignInFailed': 'Google Sign-In failed: {error}',
      'googleSignInNoTokenAndroid':
          'Google Sign-In did not return a token. Register OAuth for package cc.seeed.voice with your Debug/Release SHA-1 in Google Cloud, and set the Web client as serverClientId (app env or --dart-define=GOOGLE_SERVER_CLIENT_ID).',
      'googleSignInNoTokenGeneric':
          'Google Sign-In did not return a token. Check platform and Google Cloud configuration.',
      'googleSignInCanceledOrMisconfigured':
          'Google sign-in stopped (canceled). If you already picked an account, this is usually misconfiguration: verify package cc.seeed.voice, your build SHA-1, and the Web OAuth client used as serverClientId in Google Cloud.',
      'githubSignInNotConfigured':
          'GitHub sign-in is not configured (missing client_id).',
      'githubSignInFailedShort': 'GitHub sign-in failed',
      'oauthGitHubStateMismatch': 'GitHub sign-in failed: state mismatch',
      'oauthGitHubMissingCode': 'GitHub sign-in failed: callback missing code',
      'oauthUnsupportedProvider': 'This sign-in method is not supported',
      'oauthAllowAccess': 'Allow Access',
      'appleOauthPageTitle': 'Sign in with Apple',
      'appleOauthPageSubtitle':
          'A system sign-in dialog will open. We do not fake Apple account or email pickers in the app.',
      'oauthPartnerProductName': 'SenseCraft Voice',
      'oauthWantsAccessAfterBrand': ' wants to\naccess your Account',
      'oauthReTerminalSyncDescription':
          'This will allow reTerminal to sync\nyour IoT configurations and cloud\nsensor data.',
      'oauthSecureIndustrialTunnel': 'SECURE INDUSTRIAL TUNNEL',
      'oauthGithubPermReadProfileTitle': 'Read your public profile',
      'oauthGithubPermReadProfileSubtitle':
          'Includes your name, photo, and bio.',
      'oauthGithubPermEmailTitle': 'Access your email address',
      'oauthGithubPermEmailSubtitle': 'Primary email address will be synced.',
      'oauthPermViewProfileTitle': 'View your basic profile info',
      'oauthPermViewProfileSubtitle': '',
      'oauthPermManageHwTitle': 'Manage hardware config files',
      'oauthPermManageHwSubtitle': '',
      'wifiTransferTitle': 'WiFi Transfer',
      'wifiTransferStart': 'Start WiFi Transfer',
      'syncedFileEntriesCount': 'Synced {n} file index entries',
      'sttConfigDeleteFailed': 'Delete failed: {error}',
      'sessionMissingCannotSync':
          'The device did not return a session, and the latest session could not be read from the device. Files cannot be synced yet.',
      'promptTemplateSubtitleMeeting': 'Core agenda, tasks, highlights',
      'promptTemplateSubtitleLecture': 'Key takeaways, questions',
      'promptTemplateSubtitleClass': 'Key takeaways, questions',
      'promptTemplateSubtitleDailyDialogue': 'Who / what / when action items',
      'promptTemplateSubtitleDailyConversation': 'Who+what+when action items',
      'promptTemplateSubtitleCustomDefault': 'Default template',
      'promptTemplateSubtitleCustomUser': 'User-created template',
      // Server / API errors
      'errorNetworkTimeout':
          'Network request timed out. Please try again later.',
      'errorNetworkUnavailable':
          'Network unavailable. Please check your connection and try again.',
      'errorRequestFailed': 'Request failed. Please try again later.',
      'errorUnknown': 'An error occurred.',
      'errorLoginFailed': 'Login failed.',
      'errorUserNotFound': 'User not found.',
      'errorPasswordIncorrect': 'Incorrect password.',
      'errorUserAlreadyExists': 'User already exists.',
      'errorEmailAlreadyRegistered': 'This email is already registered.',
      'errorTokenExpired': 'Session expired. Please sign in again.',
      'errorTokenInvalid': 'Invalid session. Please sign in again.',
      'errorVerifyCodeInvalid': 'Invalid or expired verification code.',
      'errorVerifyCodeExpired':
          'Verification code expired or incorrect. Request a new code.',
      'errorEmailNotVerified': 'Email not verified.',
      'errorUnauthorized': 'Unauthorized.',
      'errorForbidden': 'Access denied.',
      'errorInvalidParams': 'Invalid parameters.',
      'errorInternalError': 'Server error. Please try again later.',
      'errorTimeout': 'Request timed out.',
      'errorUploadFailed': 'Upload failed.',
      'errorRecordNotFound': 'Record not found.',
      'errorAsrVendorNotConfigured': 'ASR vendor not configured.',
      'errorAsrUnsupportedFormat': 'Unsupported audio format.',
      'errorDuplicateRecord': 'A record with the same key already exists.',
      'errorAuditNotFound': 'Audit record not found.',
      'errorAuditExists': 'Audit record already exists.',
      'errorRbacPolicyExists': 'Permission policy already exists.',
      'errorRbacPolicyNotFound': 'Permission policy not found.',
      'errorRbacRoleExists': 'Role already exists.',
      'errorRbacRoleNotFound': 'Role not found.',
      'errorAsrConfigAlreadyExists': 'ASR configuration already exists.',
      'errorAsrConfigNotFound':
          'ASR configuration not found. Please create one first.',
      'errorAsrVendorNotFound': 'ASR vendor not found.',
      'errorAsrResultNotFound':
          'Transcription result not found or access denied.',
      'errorAsrJobNotFound': 'Transcription job not found or access denied.',
      'errorLlmVendorNotConfigured': 'LLM vendor not configured.',
      'errorPromptTemplateNotFound': 'Prompt template not found.',
      'errorLlmConfigAlreadyExists':
          'LLM configuration already exists for this vendor.',
      'errorLlmConfigNotFound': 'LLM configuration not found.',
      'errorPromptAlreadyImported': 'Template already imported.',
      'promptTemplateUnsupportedChars':
          'Template name or content contains characters the server cannot store (such as emoji). '
              'Update the server database to utf8mb4 or remove emoji and try again.',
      'promptTemplateFieldsInvalid':
          'Enter a template name (1–128 characters) and prompt content.',
      'errorNetworkRequestFailed':
          'Network request failed. Please check your connection and try again.',
      'errorNotImplemented': 'This feature is not available yet.',
      'errorBusySystem': 'Server is busy. Please try again later.',
      'errorAccountNotFound':
          'Account not found. Check your email or sign up first.',
      'errorAccountFrozen': 'This account has been frozen. Contact support.',
      'errorTooManyLoginAttempts':
          'Too many login attempts. Please try again later.',
      'errorOauthFailed':
          'Sign-in with this provider failed. Please try again.',
      'errorUnsupportedOAuthProvider':
          'This sign-in provider is not supported.',
      'errorUserInfoError':
          'Could not load account information. Please sign in again.',
      'errorVerifyCodeNotExpired':
          'A verification code was already sent. Check your email or wait before requesting another.',
      'errorRecordNotUpdate': 'Could not update this record.',
      'errorClusterNotFound': 'Service cluster not found.',
      'errorTenantNotFound': 'Account not found.',
      'errorTenantExists': 'Account already exists.',
      'errorRemoteCalled': 'Remote service error. Please try again later.',
      'errorPathNotFound': 'Requested API path not found.',
      'errorMissingParams':
          'Missing required parameters. Please sign in again.',
      'errorNewPasswordSameAsOld':
          'New password must be different from the current password.',
      'errorMobileAlreadyRegistered':
          'This mobile number is already registered.',
      'errorSmsCodeAlreadySent':
          'SMS code already sent. Please wait before requesting another.',
      'errorMobileRequired': 'Mobile number is required.',
      'errorMobileFormatInvalid': 'Invalid mobile number format.',
      'errorOssUploadNotConfigured':
          'File upload is not configured on the server.',
      'errorOssPresignFailed':
          'Failed to prepare file upload. Please try again.',
      'errorAuthorizeCodeInvalid':
          'Authorization code is invalid. Please try again.',
      'errorOauthStateMismatch': 'Sign-in session expired. Please start again.',
      'errorOauthCodeMissing': 'Authorization code was not provided.',
      'errorOauthStateMissing':
          'Sign-in state was not provided. Please try again.',
      'errorOauthAccountNeedBind':
          'This email is already registered. Sign in with email or bind the account.',
      'errorChildAccountCannotDelete': 'This sub-account cannot be deleted.',
      'errorTermsAcceptanceRequired':
          'You must accept the Terms of Service to sign in.',
      'errorOauthForeignIdTaken':
          'This third-party account is already linked to another account.',
      'errorOauthOrgAlreadyBound':
          'This account is already linked to another sign-in method.',
      'errorOauthWechatNoUnionid':
          'WeChat did not return unionid. Check Open Platform binding and user authorization.',
      // Auth API errors
      'authLoginResponseFormat': 'Login failed: invalid response format.',
      'authLoginFailed': 'Login failed.',
      'authRegisterMissingResult':
          'Registration failed: response missing result.',
      'authLoginMissingResult': 'Login failed: response missing result.',
      'authRequestFormat': 'Request failed: invalid response format.',
      // ASR API errors
      'asrRequestFormat': 'Request failed: invalid response format.',
      'asrGetConfigMissingResult':
          'Failed to get config: response missing result.',
      'asrTranscribeMissingResult':
          'Transcription failed: response missing result.',
      // User API errors
      'userApiUploadTypeEmpty': 'Upload failed: type cannot be empty.',
      'userApiUploadFileNotFound': 'Upload failed: file not found.',
      'userApiUploadFailed': 'Upload failed.',
      'userApiUploadMissingResult': 'Upload failed: response missing result.',
      'userApiUploadMissingPublicUrl':
          'Upload failed: response missing public_url.',
      'userApiLogoutFailed': 'Logout failed.',
      'userApiDeactivateFailed': 'Account deactivation failed.',
      'userApiResetPasswordFailed': 'Password reset failed.',
      'userApiChangePasswordFailed': 'Password change failed.',
      'userApiUpdateProfileFailed': 'Update profile failed.',
      'userApiUpdateEmailFailed': 'Update email failed.',
      'userApiGetMeFailed': 'Failed to get user info.',
      'userApiGetMeMissingResult':
          'Failed to get user info: response missing result.',
      // LLM API errors
      'llmErrorResponseFormat': 'Request failed: invalid response format.',
      'llmErrorPublicTemplatesMissingResult':
          'Failed to get public templates: response missing result list.',
      'llmErrorGetTemplateMissingResult':
          'Failed to get template: response missing result.',
      'llmErrorCreateTemplateMissingResult':
          'Failed to create template: response missing result.',
      'llmErrorPreviewTemplateMissingResult':
          'Failed to preview template: response missing result.',
      'llmErrorImportTemplateMissingResult':
          'Failed to import template: response missing result.',
      'llmErrorStartShareMissingResult':
          'Failed to start share: response missing result.',
      'llmErrorConfigNotSynced': 'LLM config not synced to server.',
      'llmErrorSystemPromptEmpty': 'system_prompt cannot be empty.',
      'llmErrorResponseEmpty': 'Request failed: empty response.',
      'llmErrorSummaryEmpty': 'Summary is empty.',
      // Router / App
      'pageNotFound': 'Page not found',
      'appTitle': 'SenseCraft Voice',
    },
    'zh': {
      'loginLandingTitle': '登录',
      'externalIdentity': '外部身份',
      'continueWithApple': '使用 Apple 登录',
      'continueWithGoogle': '使用 Google 登录',
      'continueWithGithub': '使用 Github 登录',
      'emailLogin': '邮箱登录',
      'passwordLogin': '密码登录',
      'loginWithPassword': '使用密码登录',
      'loginWithEmailCode': '使用邮箱验证码登录',
      'terminalSessionProtected': '此终端会话受以下保护',
      'technicalStandards': '技术标准',
      'safetyProtocols': '安全协议',
      'identityVerification': '身份验证',
      'emailLoginTitle': '邮箱登录',
      'emailLoginDescription': '输入邮箱获取验证码登录。若邮箱未注册，将自动注册并关联。',
      'email': '邮箱',
      'emailHint': 'you@example.com',
      'emailExample': 'name@example.com',
      'verificationCode': '验证码',
      'verificationCodeHint': '请输入验证码',
      'getCode': '获取验证码',
      'resendIn': '重新发送',
      'seconds': '秒',
      'emailNotRegisteredHint': '如果此邮箱未注册，将自动创建账户。',
      'agreeToTerms': '我已阅读并同意',
      'agreeToTermsRequired': '请先阅读并同意用户协议与隐私政策',
      'privacyConsentTitle': '隐私政策',
      'privacyConsentBodyPrefix': '欢迎使用 SenseCraft Voice。请仔细阅读',
      'privacyConsentBodySuffix': '。点击「同意」即表示您已阅读并同意上述内容；若您不同意，请点击「拒绝」并退出应用。',
      'privacyConsentAgree': '同意',
      'privacyConsentRefuse': '拒绝',
      'loginOptions': '登录',
      'thirdPartyLogin': '第三方登录',
      'errorOAuthDisplayNameDbCharset':
          '账号显示名称含有暂不支持的字符（如表情符号）。请在 Apple/Google 账号设置中修改姓名，或改用邮箱登录。',
      'userAgreement': '用户协议',
      'and': '和',
      'privacyPolicy': '隐私政策',
      'orWithEmail': '或使用邮箱',
      'agreePrefixLanding': '点击下方「继续」即表示同意',
      'serverEnvLabel': '服务器',
      'serverEnvRelease': '正式',
      'serverEnvTest': '测试',
      'serverEnvDev': '开发',
      'signIn': '登录',
      'signingIn': '登录中...',
      'fillEmailCodeAndAgree': '请填写邮箱/验证码并同意协议',
      'continueAction': '继续',
      'continueLoading': '继续...',
      'invalidCode6': '请输入 6 位验证码',
      'passwordLoginTitle': '密码登录',
      'passwordLoginDescription': '使用邮箱和密码登录您的账户。',
      'password': '密码',
      'passwordHint': '请输入密码',
      'emailOrPasswordEmpty': '请输入邮箱和密码',
      'invalidEmail': '请输入正确的邮箱地址',
      'forgotPasswordLink': '忘记密码？',
      'authenticatedVia': '已通过',
      'linkYourIdentity': '关联您的身份',
      'linkIdentityDescription': '为了同步您的数据，请提供邮箱地址。',
      'verifyAndContinue': '验证并继续',
      'dataPrivacy': '数据隐私',
      'dataPrivacyDescription': '您的邮箱将用于通过加密安全隧道在您的 reTerminal 设备之间同步工程配置。',
      'enterValidEmail': '请输入正确邮箱',
      'setPassword': '设置密码',
      'setPasswordDescription': '登录成功后建议设置密码，便于后续使用"密码登录"。此步骤可跳过。',
      'confirm': '确认',
      'passwordHintSet': '8-16位，必须包含字母和数字',
      'confirmPasswordHint': '再次输入密码',
      'passwordRule': '规则：8-16 位，必须同时包含字母和数字。',
      'passwordInvalid': '密码不符合规则',
      'passwordMismatch': '两次输入的密码不一致',
      'saving': '保存中...',
      'skip': '跳过',
      'secureYourAccount': '保护你的账户',
      'setPasswordForFuture': '设置密码用于后续登录',
      'skipForNow': '暂不设置',
      'resetPasswordMissingCode': '重置密码失败：缺少验证码',
      'registerMissingVerificationCode': '缺少注册验证码，请返回上一步填写邮箱中收到的 6 位验证码。',
      'resetPasswordSuccess': '密码已重置，请重新登录',
      'registerCompleteSignInWithEmailCode':
          '账号注册成功。请在登录页输入邮箱并点击继续，使用登录验证码完成验证后进入应用。',
      'forgotPasswordTitle': '忘记密码',
      'forgotPasswordDesc': '输入邮箱获取验证码',
      'enterVerificationCodeTitle': '输入验证码',
      'enterVerificationCodeDesc': '请输入发送到邮箱的 6 位验证码',
      'universalAccess': '通用访问',
      'passwordLoginSubtitle': '密码登录',
      'passwordLoginNotImplemented': '密码登录功能待实现',

      // Settings - Common
      'save': '保存',
      'saving2': '保存中...',
      'cancel': '取消',
      'delete': '删除',
      'clear': '清除',
      'enabled': '已启用',
      'notEnabled': '未启用',
      'latest': '最新',
      'languageEnglish': 'English',
      'languageChinese': '简体中文',
      // Settings - SettingsPage
      'settings': '设置',
      'security': '安全',
      'community': '社区',
      'about': '关于',
      'permissions': '权限',
      'language': '语言',
      'passwordItem': '密码',
      'deleteAccount': '删除账号',
      'followUs': '关注我们',
      'followUsTwitter': 'X (Twitter)',
      'followUsLinkedIn': 'LinkedIn',
      'followUsDiscord': 'Discord',
      'followUsFacebook': 'Facebook',
      'helpFeedback': '帮助与反馈',
      'appVersion': '应用版本',
      'clearCache': '清理缓存',
      'cacheCleared': '缓存已清理，不会删除已同步的录音文件',
      'clearCacheFailed': '清理缓存失败',
      'policies': '政策与协议',
      'logOut': '退出登录',
      'pushNotifications': '推送通知',
      // Settings - Personal Information
      'personalInformation': '个人信息',
      'profileUpdated': '资料已更新',
      'tapToChangeProfilePhoto': '点击更换头像',
      'nickname': '昵称',
      'boundEmail': '绑定邮箱',
      'connectedAccounts': '关联账号',
      'senseCraftAccount': 'SenseCraft 账号',
      'connected': '已关联',
      'notConnected': '未关联',
      // Settings - Change Email
      'changeEmail': '修改邮箱',
      'emailAddress': '邮箱',
      'emailAddressDesc': '该邮箱将用于账号登录与通知。',
      'sendCode': '发送验证码',
      'sendCodeLoading': '发送中...',
      'resendInSeconds': '{s}s 后可重发',
      'emailChangedSuccess': '邮箱已修改，请使用新邮箱登录',
      // Settings - Change Password
      'changePassword': '修改密码',
      'oldPassword': '旧密码',
      'oldPasswordHint': '请输入旧密码',
      'newPassword': '新密码',
      'confirmNewPassword': '确认新密码',
      'repeatNewPasswordHint': '再次输入新密码',
      'updatePassword': '更新密码',
      'confirmPasswordLabel': '确认密码',
      'repeatPasswordHint': '再次输入密码',
      'passwordSetSuccess': '密码设置成功',
      'updating': '更新中...',
      'passwordChangedSuccess': '密码修改成功',
      'fillAllFields': '请填写完整信息',
      'newPasswordSameAsOld': '新密码不能与旧密码相同',
      // Settings - Delete Account
      'accountDeletion': '删除账号',
      'accountDeletionDesc': '此操作不可撤销。\n所有设备数据与网页模板将被永久删除。',
      'confirmDeletion': '确认删除',
      'deleteAccountConfirmTitle': '删除账号',
      'deleteAccountConfirmMessage': '此操作不可撤销，是否继续？',
      // Settings - Help & Feedback
      'helpCenter': '帮助中心',
      'productWiki': '产品 Wiki',
      'contactUs': '联系我们',
      'feedback': '反馈',
      'feedbackPrompt': '有功能建议或发现问题？欢迎反馈给我们！',
      'feedbackHint': '请输入你的建议...',
      'submitSuggestion': '提交反馈',
      'feedbackTypeLabel': '反馈类型',
      'feedbackTypeBug': '缺陷/Bug',
      'feedbackTypeEnhancement': '功能优化',
      'feedbackTypeFeature': '新需求',
      'feedbackAddPhotos': '添加截图（可选）',
      'feedbackPhotosLimit': '最多 3 张图片',
      'feedbackDescriptionRequired': '请填写反馈内容',
      'feedbackSubmitSuccess': '感谢反馈，我们已收到。',
      'feedbackSubmitFailed': '反馈提交失败',
      // Settings - Policies/About/Permissions
      'privacyPolicy2': '隐私政策',
      'userAgreement2': '用户协议',
      'openSourceLicenses': '开源许可',
      'linkOpenFailed': '无法打开链接。',
      'bluetooth': '蓝牙',
      'microphone': '麦克风',
      'notifications': '通知',
      'checkForUpdates': '检查更新',
      'checkingForUpdates': '正在检查更新...',
      'updateAvailableTitle': '发现新版本',
      'updateNow': '立即更新',
      'updateLater': '稍后',
      'noUpdateAvailable': '当前已经是最新版本。',
      'updateCheckFailed': '检查更新失败。',
      'updateServiceNotConfigured': '更新服务尚未配置。',
      'versionLabel': '版本 {v}',
      'cacheUsedLabel': '已使用 {v}',
      'aboutCopyright': '© 2026 Seeed Technology Inc. 保留所有权利。',
      'helpCopyright': '© 2026 Seeed Technology Inc. 保留所有权利。',

      // Recordings / Home
      'recordingsLoadFailed': '加载失败',
      'recordingsListEndHint': '没有更多了',
      'recordingsLoadingMoreFooter': '正在加载更多…',
      'selectedCount': '已选择（{n}）',
      'done': '完成',
      'searchRecordings': '搜索录音',
      'noRecordingsYet': '暂无录音',
      'noResults': '无结果',
      'importDemoData': '导入演示数据',
      'filterSort': '筛选与排序',
      'allFiles': '全部文件',
      'all': '全部',
      'downloaded': '已下载',
      'unclassified': '未分类',
      'folder': '文件夹',
      'recycleBin': '回收站',
      'folders': '文件夹',
      'deviceSourcePlaceholder': 'Note Pro  (2)',
      'from': '来源',
      'createTime': '创建时间',
      'operationTime': '操作时间',
      'moveToRecycleBin': '移至回收站',
      'restoreFromRecycleBin': '放回原处',
      'moveToRecycleBinConfirm': '将 {n} 个文件移至回收站？',
      'move': '移动',
      'moveTo': '移动到',
      'rename': '重命名',
      'generate': '生成',
      'deleteFolder': '删除文件夹',
      'renameFolder': '重命名文件夹',
      'deleteFolderMessage': '此文件夹将被删除，文件夹内所有文件将移动到“全部文件”。是否继续？',
      'generateAiSummary': '生成 AI 总结',
      'moveToFolder': '移动到文件夹',
      'syncing': '同步中',
      'syncingPercent': '同步中 {p}%',
      'resync': '重新同步',
      'resyncStarted': '已开始重新同步',
      'connectDeviceToResync': '请先连接设备以重新同步',
      'resyncBlockedWhileRecordingOtherSession': '设备正在录制其他会话，请先结束当前录音后再重新同步此条。',
      'resyncCouldNotStart': '暂时无法开始同步。若刚点过录音、或正在使用 Wi‑Fi 快速同步，请稍等几秒再试。',
      'transferring': '传输中',
      'transferBannerMinimizeTip': '收起到边缘隐藏',
      'transferBannerRestoreTip': '点击展开传输进度',
      'fastSync': '快速同步',
      'transferSpeedLabel': '速率：{s}',
      'fastSyncSheetTitle': 'Wi‑Fi 快速同步',
      'fastSyncCloseTurnOffWifi': '关闭',
      'fastSyncDismissHint':
          '连接成功开始传输后本页会自动关闭，进度请在首页传输卡片查看。若手动关闭（按钮、点空白或下滑），将关闭设备热点。',
      'fastSyncStoppingBle': '正在停止蓝牙传输…',
      'fastSyncSwitchedNetworkTitle': '已连接到其他 Wi‑Fi',
      'fastSyncSwitchedNetworkMessage':
          '手机总是自动切回已保存的其他 Wi‑Fi，没连到录音设备的热点，无法进行快速同步。请打开 Wi‑Fi 设置，把其他已保存的网络点“忽略此网络/取消保存”（或关闭它们的“自动连接”），然后手动连接设备热点（“ClipAP_”开头的网络）。把这些已保存的网络忽略后，手机就不会再自动切走了。本次先继续通过蓝牙传输。',
      'fastSyncOpenWifiSettings': '打开设置',
      'fastSyncWifiFallbackTitle': 'Wi‑Fi 快速同步未完成',
      'fastSyncWifiFallbackMessage':
          '无法通过 Wi‑Fi 完成快速同步——可能是手机连到了别的 Wi‑Fi、没连上设备热点，或信号太弱。已自动改用蓝牙继续传输。想要更快，请在 Wi‑Fi 设置里连接下方的设备热点，并把常用 Wi‑Fi 的“自动连接”关掉或“忽略此网络”，避免手机自动切走。',
      'fastSyncWifiDisconnectedTitle': 'Wi‑Fi 已断开',
      'fastSyncWifiDisconnectedMessage':
          '手机未连接设备 Wi‑Fi（可能已关闭 Wi‑Fi 或切到了其他网络）。已改用蓝牙继续同步。若之后想再试快速同步，请先打开 Wi‑Fi。',
      'fastSyncWifiVerifyTimeoutTitle': '未能连接设备 Wi‑Fi',
      'fastSyncWifiVerifyTimeoutMessage':
          '设备热点已开启，但手机未能及时连上。已改用蓝牙继续同步。下次请在 Wi‑Fi 设置中连接下方设备热点，并将常用 Wi‑Fi 的“自动连接”关闭或“忽略此网络”，避免手机自动切走。',
      'fastSyncDeviceWifiNetworkLabel': '设备 Wi‑Fi',
      'fastSyncDeviceWifiPasswordLabel': '密码',
      'fastSyncCopied': '已复制',
      'fastSyncWifiFailedTitle': 'Wi‑Fi 同步未成功',
      'fastSyncWifiFailedMessage':
          '手机已连上设备 Wi‑Fi，但信号太弱、数据传不过去。本次将继续通过蓝牙同步。若多次出现，请靠近设备或重新连接设备 Wi‑Fi 后再试。',
      'fastSyncCancelBleFailed': '无法停止蓝牙传输',
      'fastSyncUnavailableWhileRecording': '设备正在录音时不能使用快速同步，请先结束录音。',
      'fastSyncStillRunningCannotRecord': 'Wi‑Fi 同步仍在结束中，请稍后再开始录音。',
      'fastSyncNoSession': '缺少该录音的会话标识',
      'fastSyncPreparing': '准备中…',
      'fastSyncLaunchingWifi': '正在开启热点并启动 Wi‑Fi 同步…',
      'fastSyncEnablingHotspot': '正在开启设备热点…',
      'fastSyncJoiningWifi': '正在连接设备 Wi‑Fi…',
      'fastSyncIosLocalNetworkTitle': '需要访问本地网络',
      'fastSyncIosLocalNetworkMessage':
          'Wi‑Fi 快速同步需要通过本地网络与录音设备通信。接下来若系统询问「本地网络」，请选择「允许」。若之前选过「不允许」，请到 设置 → 隐私与安全性 → 本地网络，为本应用打开开关。',
      'fastSyncOpenAppSettings': '打开设置',
      'fastSyncVerifyingUdp': '正在验证连接…',
      'fastSyncTransferring': '正在通过 Wi‑Fi 传输…',
      'fastSyncMerging': '正在合并文件…',
      'fastSyncRestoringWifi': '正在恢复手机网络…',
      'fastSyncDone': '完成',
      'fastSyncFailed': '传输失败',
      'fastSyncBytesProgress': '{r} / {t}',
      'errWifiHandoff': '正在切换到 Wi‑Fi…',
      'errWifiFastSyncUnreachable':
          'Wi‑Fi 快速同步未能连上设备。可用蓝牙继续同步，或在 设置 → 无线局域网 手动连接设备热点后再试快速同步。',
      'errWifiFastSyncDisconnected': 'Wi‑Fi 已关闭或未连接设备网络，已改用蓝牙继续同步。',
      'errInvalidSessionId': '该录音的会话标识异常（设备列表解析错误）。请下拉刷新录音列表或重新连接设备。',
      'syncAll': '同步全部',
      'syncAllResult': '已同步 {n} 个录音',
      'syncComplete': '同步完成',
      'syncFailed': '同步失败',
      'errDeviceDisconnectedResume': '设备已断开连接，重连后将自动续传',
      'errCreateLocalDirFailed': '创建本地目录失败',
      'errTransferIncompleteSize': '传输未完成（大小不足），将重新下载',
      'errLocalFileDeleted': '本地文件已删除，将重新下载',
      'errLocalFileIncomplete': '本地文件不完整，将重新下载',
      'errDeviceSessionMissing': '设备上已无此录音',
      'errDeviceSessionMissingCannotResume': '设备上已无此录音，无法续传',
      'errTransferIncompleteResume': '传输未完成，重连设备后将自动续传',
      'errNoValidAudio': '未收到有效音频数据',
      'errUserCancelled': '已取消',
      'errDeviceRecordingResumeLater': '设备正在录音，录音结束后将自动续传',
      'errDeviceDisconnectedResumeAfterReconnect': '设备断开连接，重连后将自动续传',
      'errStalledNoData3Min': '已超过 3 分钟未收到数据，传输已暂停，请点击重新同步继续',
      'errMergedFileIncomplete': '合并失败，合并文件不完整。可尝试重新同步补全。',
      'transferCancelled': '已取消传输',
      'cancelTransferOnlyActive': '只能取消当前正在传输的录音',
      'transferringWhileRecording': '录音中不可用',
      'waitCurrentTransferToRetry': '请等待当前传输完成后再重试',
      'today': '今天',
      'yesterday': '昨天',
      'earlier': '更早',
      'createFolder': '新建文件夹',
      'folderName': '文件夹名称',
      'folderNameExample': '例如：大学课程',
      'chooseColor': '选择颜色',
      'chooseIcon': '选择图标',
      'newName': '新名称',
      'folderNameHint': '文件夹名称',

      // Recording Detail / AI actions
      'source': '原音',
      'note': '笔记',
      'localAudioMissing': '本地音频文件不存在，请先同步到手机',
      'localAudioUnplayable': '本地音频无法播放，可尝试从设备重新同步；若仍失败请联系支持',
      'needTranscriptFirst': '请先生成转写，再进行总结',
      'llmTemplateNotSelected': '未选择 LLM/模板',
      'noTranscriptYet': '暂无转写',
      'configureApiAndTranscribe': '请先配置接口，然后点击下方按钮\n进行转写与总结',
      'transcribeAndSummarize': '转写并总结',
      'transcription': '转写内容',
      'generateSummary': '生成总结',
      'chooseSummaryVersion': '选择总结版本',
      'summary': '总结',
      'summaryVersionPrefix': '总结',
      'deleteCurrentSummary': '删除当前总结',
      'aiGenerating': 'AI 生成中…',
      'summaryComplete': '总结完成',
      'backgroundingEnabled': '后台生成已开启',
      'aiDisclaimer': 'AI 生成内容仅供参考',
      'noSummaryYet': '暂无总结',
      'configureApiAndClickPlus': '请先配置接口，然后点击 + 生成总结',
      'template': '模板',
      'autoSpeakerLabeling': '自动说话人标注',
      'autoSpeakerHint': '开启后会优先使用 Deepgram，以获得更稳定的说话人分离效果。',
      'audioLanguage': '音频语言',
      'sttModel': 'STT 模型',
      'sttConfiguration': 'STT 配置',
      'llmModel': 'LLM 模型',
      'llmConfiguration': 'LLM 配置',
      'generateNow': '立即生成',
      'aiDataSharingConsentTitle': 'AI 数据共享',
      'aiDataSharingConsentIntro': '使用转写或总结功能时，App 需要将所选录音数据发送到云端 AI 服务处理。',
      'aiDataSharingConsentShortMessage':
          '使用转写或总结功能时，App 会将所选录音音频、转写文本及必要的设备/录音信息发送至 {recipients}，用于 AI 处理。请确认是否同意。',
      'aiDataSharingConsentAudio': '音频数据：所选录音音频可能会被上传，用于语音转文字处理。',
      'aiDataSharingConsentTranscript': '转写数据：转写文本可能会被发送，用于生成总结。',
      'aiDataSharingConsentMetadata':
          '相关元数据：录音 ID、设备 ID、语言、说话人标注选项和所选 AI 配置可能会被发送，用于处理本次请求。',
      'aiDataSharingConsentRecipients': '接收方：{recipients}。',
      'aiDataSharingConsentProtection':
          '这些数据仅用于提供你请求的 AI 结果，并会按照隐私政策和所选服务商的保护措施处理。',
      'aiDataSharingConsentCheckbox': '我同意发送上述数据用于 AI 处理。',
      'aiDataSharingConsentAllow': '同意并继续',
      'aiDataSharingConsentDecline': '不同意',
      'aiDataSharingConsentSenseCraftCloud': 'SenseCraft Voice 云服务',
      'aiDataSharingConsentSelectedAiProviders': '所选或已配置的第三方 AI 服务商',

      // AI Config
      'aiConfiguration': 'AI 配置',
      'guide': '引导',
      'serviceConfiguration': '服务配置',
      'sttService': 'STT 服务',
      'llmService': 'LLM 服务',
      'notConfigured': '未配置',
      'configured': '已配置',
      'configure': '去配置',
      'loading': '加载中...',
      'promptTemplates': '提示词模板',
      'viewMoreTemplates': '查看更多模板',
      'sessionHistory': '会话历史',
      'sessionMessages': '会话详情',
      'noSessions': '暂无会话',
      'noMessages': '暂无消息',
      'deleteSession': '删除会话',
      'deleteSessionMessage': '确认删除该会话及其消息吗？',
      'deleteMessage': '删除消息',
      'deleteMessageConfirm': '确认删除该会话的最新一条消息吗？',
      'custom': '自定义',
      'summarize': '总结',
      'summarizeAgain': '重新总结',
      'transcribeAgain': '重新转写',
      'batchTranscribe': '批量转写',
      'batchTranscribeSummary': '批量转写结束：成功 {ok} 个，跳过或失败 {fail} 个。',
      'batchTranscribingFilesProgress': '正在转写 {c}/{t} 个文件…',
      'batchTranscribingFloatingHint': '可继续浏览列表，各文件完成后会自动更新状态。',
      'batchTranscribeSwipeToHide': '左右滑动可收起',
      'batchTranscribeShowProgress': '显示转写进度',
      'batchTranscribeAlreadyRunning': '批量转写正在进行中，请稍后再试',
      'processing': '处理中…',
      'preparingAudioForTranscription': '正在本机准备音频（分段解码）… {p}%',
      'transcriptionWorkInProgress': '转写处理中…',
      'transcribingChunkProgress': '转写中 已完成 {c}/{t} 段',
      'statusQueued': '文件上传中…',
      'statusCompleted': '已完成',
      'statusFailed': '失败',
      'transcribing': '转写中…',
      'waveformBuilding': '正在生成波形…',
      'playbackPreparing': '正在准备播放…',
      'summarizing': '总结中…',
      'errorTitle': '错误',
      'saveAs': '另存为',
      'speakerModeSwitchedProvider': '已切换为 {provider} 进行说话人标注。',
      'speakerModeFallbackNormal': '{provider} 暂不支持说话人标注，已按普通转写继续。',
      'newFileNameHint': '新文件名',
      'trimmedAudio': '裁剪音频',
      'trimSuffix': '（裁剪）',
      'trimOnlyWavSupported': '当前仅支持 WAV(PCM16) 音频另存为裁剪结果',
      'trim': '裁剪',
      'smartEdit': '智能编辑',
      'smartEditTodo': '智能编辑（待实现）',
      'deleteTodo': '删除（待实现）',
      'asrVendorIdNotConfigured': 'ASR 厂商未配置 ID，请先同步配置',
      'transcriptionFailed': '语音识别失败：{error}',
      'uploadFileTooLarge': '文件过大（超过 {n}MB），请先裁剪后再转写',
      'uploadFileTooLarge413': '上传失败：文件过大，请先裁剪录音',
      'uploadingProgress': '上传中… {n}%',
      'transcriptionGatewayTimeout': '转写超时，服务器处理时间较长，请稍后重试',
      'transcriptionGatewayTimeoutRetry': '重试',
      'summaryFailed': '总结失败：{error}',
      'moveToRecycleBinConfirmName': '将“{name}”移至回收站？',
      'viewAll': '查看全部',
      'select': '选择',
      'auto': '自动',
      'share': '分享',
      'shareLink': '分享链接',
      'copyToClipboard': '复制到剪贴板',
      'copySuccess': '复制成功',
      'transcriptCopied': '已复制转写',
      'noteCopied': '已复制笔记',
      'exportFile': '导出文件',
      'audio': '音频',
      'shareContent': '分享内容',
      'shareLinkExpiry': '持有链接者可访问，有效期7天',
      'linkCopied': '已复制链接',
      'copyLink': '复制链接',
      'exportAudio': '导出音频',
      'exportTranscript': '导出转写',
      'exportNote': '导出笔记',
      'exportFormat': '导出格式',
      'export': '导出',
      'exportRecording': '导出录音',
      'exporting': '正在导出',
      'exportingPercent': '正在导出({p}%)',
      'noAudioToExport': '暂无可导出的音频文件',
      'audioFileNotFound': '音频文件不存在',
      'shareFailed': '分享失败：{error}',
      'transcodeFailed': '转码失败：{error}',
      'wavExportNeedsConversion': 'WAV 导出需要转换（已预留服务端入口）',
      'mp3ExportNeedsConversion': 'MP3 导出需要转换（已预留服务端入口）',
      'unsupportedAudioFormat': '暂不支持的音频导出格式',
      'noTranscriptToExport': '暂无转写可导出',
      'formatExportNeedsServer': '{format} 导出需要服务端生成（已预留入口）',
      'noNoteToExport': '暂无笔记可导出',
      'searchRecordingsOrQa': '搜索录音或问答',
      'loadFailed': '加载失败：{error}',
      'totalResults': '共 {count} 条结果',
      'recentSearches': '最近搜索',
      'searchEmptyHint': '输入关键词搜索录音或\n问答',
      'creationTime': '创建时间',
      'last7Days': '近7天',
      'last30Days': '近30天',
      'last3Months': '近3个月',
      'last6Months': '近6个月',
      'lastYear': '近1年',
      'sinceRegistration': '全部',
      'fromDevice': '来自设备',
      'sourceLocal': '本地',
      'transcriptStatus': '转写状态',
      'transcribed': '已转写',
      'notTranscribed': '未转写',
      'transcriptionFailedShort': '转写失败',
      'deviceN': '设备 {n}',
      'startsAt': '开始于',
      'endsAt': '结束于',
      'selectDate': '选择日期',
      'apply': '应用',
      'deleteSegment': '删除片段',
      'keepSegment': '保留片段',
      'recordingStartFailed': '启动录音失败',
      'markFailedNotRecording': '标记失败：未在录音',
      'markAdded': '已标记：{time}',
      'markFailedDeviceNotReady': '标记失败：未在录音或设备未就绪',
      'markByDeviceButton': '设备已添加书签：{time}',
      'deviceButtonStartedRecording': '设备已开始录音',
      'deviceButtonStoppedRecording': '设备已结束录音',
      'endRecording': '结束录音？',
      'endRecordingMessage': '停止并保存本次录音，或继续录音？',
      'stopAndSave': '停止并保存',
      'continueRecording': '继续录音',
      'continueRecordingSnack': '继续录音中',
      'recordingStopFailed': '停止录音失败',
      'pauseFailed': '暂停录音失败',
      'resumeFailed': '继续录音失败',
      'recordingFinishedSyncing': '录音已结束并开始同步',
      'microphonePermissionDenied': '没有麦克风权限，无法录音',
      'photoPermissionRequiredTitle': '需要访问照片',
      'photoPermissionRequiredForAvatarMessage': '请在系统设置中允许本 App 访问照片库，以便更换头像。',
      'notificationPermissionDenied': '未授予通知权限，推送将关闭',
      'bluetoothPermissionDenied': '未授予蓝牙权限，无法扫描设备',
      'bluetoothDisabledTitle': '蓝牙未开启',
      'bluetoothDisabledHint': '请开启蓝牙以搜索附近设备。',
      'turnOnBluetooth': '开启蓝牙',
      'bluetoothRequiredTitle': '需要蓝牙',
      'bluetoothOffForConnectMessage': '请在系统设置中开启蓝牙后再连接或添加设备。',
      'bluetoothPermissionRequiredForConnectMessage':
          '请在设置中允许本 App 使用蓝牙后再连接或添加设备。',
      'openSettingsAction': '前往设置',
      'scanLocationRequiredTitle': '需要定位才能扫描设备',
      'scanLocationServiceOffMessage':
          '手机的定位总开关已关闭。Android 需要开启定位才能扫描到蓝牙设备。请开启后重新扫描。',
      'scanLocationPermissionMessage':
          '在你的 Android 版本上，扫描蓝牙设备需要定位权限。请授予后重新扫描。',
      'opusNotSupported': '当前设备不支持 Opus 编码',
      'recordingSavedLocally': '录音已保存到本地（可用于测试服务器接口）',
      'noDeviceConnected': '未连接设备',
      'connectDeviceToRecord': '请通过蓝牙连接 SenseCraft Voice 开始录音。',
      'deviceDisconnectedReconnecting': '设备已断开，正在尝试重连…',
      'reconnectFailed': '重连失败，请手动连接设备。',
      'connectNow': '立即连接',
      'recordingFinished': '录音完成',
      'recordingFinishedLocal': '录音已完成并保存到本地。',
      'recordingFinishedDevice': '录音已完成并保存到设备。',
      'backToFiles': '返回文件',
      'ready': '就绪',
      'preparingRecording': '正在准备录音…',
      'paused': '已暂停',
      'deviceRecording': '设备录音中',
      'localRecording': '本地录音中',
      'mark': '标记',
      'pause': '暂停',
      'resume': '继续',
      'record': '录制',
      'recording': '录音',
      'finish': '结束',
      'keyAt': '标记 {time}',
      'localRecordingName': '本地录音 {ts}',
      'recordingName': '录音 {ts}',
      'seekBack5s': '后退 5 秒',
      'seekForward5s': '前进 5 秒',
      'content': '内容',
      'shareLinkText': 'SenseCraft Voice 分享链接（{content}）\n{link}',
      'shareAudioExportText': 'SenseCraft Voice 音频导出',
      'shareAudioExportOpusText': 'SenseCraft Voice 音频导出（Opus）',
      'shareTranscriptExportText': 'SenseCraft Voice 转写导出',
      'shareNoteExportText': 'SenseCraft Voice 笔记导出',
      'ffmpegError': 'FFmpeg 错误',
      'sttProviderAliyun': '阿里云',
      'sttProviderFunasr': '自建 FunASR',
      'sttProviderOpenAiWhisper': 'OpenAI Whisper',
      'sttProviderGoogleGemini': 'Google Gemini',
      'sttProviderDeepgram': 'Deepgram',
      'sttProviderLocalWhisper': '本地 Whisper',
      'sttProviderVosk': 'Vosk',
      'sttProviderIflytek': '讯飞',
      'sttProviderTencent': '腾讯',
      'sttProviderBaidu': '百度',
      'sttProviderDoubao': '豆包 ASR',
      'sttProviderOnDevice': '端侧本地 STT',
      'llmProviderOpenAi': 'OpenAI GPT',
      'llmProviderAnthropic': 'Anthropic Claude',
      'llmProviderGoogleGemini': 'Google Gemini',
      'llmProviderLlama': 'Llama',
      'llmProviderDoubao': '豆包',
      'llmProviderQwen': '通义千问',
      'llmProviderDeepseek': 'DeepSeek',
      'llmProviderOpenRouter': 'OpenRouter',

      // Home bottom tabs
      'filesTab': '文件',
      'aiConfigTab': 'AI 配置',

      // Device
      'device': '设备',
      'disconnect': '断开',
      'atDebug': 'AT 调试',
      'connect': '连接',
      'noValue': '无',
      'lastResponseLabel': '最后回包：{value}',
      'scanResultsCount': '扫描结果（{n}）',
      'scanning': '扫描中...',
      'startScan': '开始扫描',
      'noName': '（无名称）',
      'deviceDetailsInfo': '设备详情与信息',
      'deviceNotFound': '未找到设备',
      'online': '在线',
      'offline': '离线',
      'deviceNameLabel': '设备名称',
      'statusLabel': '状态',
      'batteryLabel': '电量',
      'modelLabel': '型号',
      'recordingModeLabel': '录音模式',
      'firmwareVersionLabel': '固件版本',
      'disconnectAction': '断开连接',
      'resetDeviceAction': '重置设备',
      'unbindDeviceAction': '解绑设备',
      'unpairDeviceAction': '取消配对',
      'unpairDeviceTitle': '取消配对',
      'unpairDeviceMessage': '需要先取消配对，本设备才能与其他手机配对。\n\n'
          '将清除设备上的配对信息并断开连接，不会删除设备上的录音。',
      'unpairConfirm': '取消配对',
      'unpairDoneSnack': '已取消配对',
      'unpairFailedSnack': '取消配对失败，请稍后重试',
      'unpairSentSnack': '已清除配对并断开连接，下次连接需重新配对。',
      'unpairConnectFirst': '请先连接该设备再执行取消配对',
      'renameDeviceTitle': '重命名设备',
      'deviceNameHint': '设备名称',
      'renameOfflineHint': '设备当前未连接。新名称会先保存在本地，下次连接设备时自动同步到设备。',
      'renameInvalid': '名称不合法，长度需在 1-32 个字符之间，且不能包含控制字符。',
      'folderNameInvalid': '文件夹名称不合法，长度需在 1-24 个字符之间，且不能包含控制字符。',
      'renameSavedOnDevice': '名称已更新并保存到设备',
      'renameSavedLocallyWillSync': '名称已保存到本地，下次连接设备时会同步',
      'renameFailed': '重命名失败，请稍后重试',
      'renameDeviceRejected': '设备拒绝该名称：{detail}',
      'renameAtFailed': '无法写入设备：{detail}',
      'deviceModificationSuccess': '修改成功',
      'disconnectDeviceTitle': '断开设备',
      'disconnectDeviceMessage': '仅会断开手机与 SenseCraft Voice 的蓝牙连接，设备仍绑定当前账号。',
      'disconnectedSnack': '已断开连接',
      'disconnectSentSnack': '已断开连接，设备将保持运行，可随时重新连接。',
      'resetDeviceTitle': '重置设备',
      'resetDeviceMessage': '将恢复设备所有参数为出厂设置。',
      'resetDoneSnack': '已发起重置（演示）',
      'resetSentSnack': '已发送指令，设备将恢复出厂设置并重启，连接已断开。',
      'resetConfirm': '重置',
      'purgeDeviceSessions': '清空设备录音',
      'purgeDeviceSessionsConfirm': '将永久删除设备上的所有录音，此操作不可恢复。',
      'purging': '清空中...',
      'purgeDeviceSessionsDone': '设备上的所有 session 已删除',
      'purgeDeviceSessionsFailed': '清空失败，请稍后重试',
      'purgeDeviceSessionsConnectFirst': '请先连接该设备，再清空设备上的录音。',
      'unbindDeviceTitle': '解绑设备',
      'unbindConfirm': '解绑',
      'unbindDeviceMessage':
          '将断开连接；若当前已连接，会清除设备上的配对信息，并从本 App 设备列表中移除。不会删除设备上的录音。',
      'unbindIosForgetReminderTitle': '已解绑',
      'unbindIosForgetReminderMessage': '设备端配对信息已清除，但手机系统蓝牙里通常仍会保留该设备。\n\n'
          '重新连接前，请打开「设置 > 蓝牙」，找到该设备并选择「忽略此设备 / 取消配对」，再返回 App 重新添加。',
      'unbinding': '正在解绑...',
      'unbindDoneSnack': '已解绑并从 App 移除设备',
      'recordingModeNormal': '普通',
      'recordingModeEnhanced': '增强',
      'deviceDetailsRefresh': '刷新',
      'deviceDetailsConnectFirstToRefresh': '请先连接该设备再刷新。',
      'deviceDetailsRefreshed': '已刷新设备信息。',
      'deviceDetailsRuntimeSectionTitle': '设备运行状态（AT）',
      'deviceDetailsReadingAtInfo': '正在从设备读取 AT 信息…',
      'deviceDetailsDeviceTime': '设备时间',
      'deviceDetailsWorkState': '工作状态',
      'deviceDetailsBatteryAt': '电量（AT）',
      'deviceDetailsModeAt': '模式（AT）',
      'deviceDetailsPairStatus': '配对状态',
      'deviceDetailsPairAddress': '配对地址',
      'deviceDetailsAtInfoUnavailable': '暂时无法获取 AT 信息（设备未连接或响应超时）。',
      'deviceDetailsSettingFailedRetry': '设置失败，请稍后重试。',
      'deviceDetailsConnectFirstToReset': '请先连接该设备再执行重置。',
      'connectingTo': '正在连接 {name}...',
      'connectedTo': '已连接到 {name}',
      'connectionFailedCheck': '连接失败，请检查设备状态。',
      'connectionFailedScanAndAdd': '连接失败，请手动扫描重新添加设备。',
      'connectionFailedUnpairHint': '若仍失败，请到手机「设置 > 蓝牙」中忽略该设备后，再重新添加。',
      'connectionFailedIosForgetTitle': '请在系统蓝牙中忽略设备',
      'forgetDeviceInSettingsAction': '前往设置忽略设备',
      'errIosPeerRemovedPairingInfo':
          '连接失败：手机与设备的蓝牙配对密钥不一致（常见于解绑后未在系统中忽略/取消配对）。\n\n'
              '请打开「设置 > 蓝牙」，找到该设备并选择「忽略此设备 / 取消配对」，然后返回 App 重新添加。',
      'errIosStaleBluetoothPairing':
          '连接失败：手机与设备的蓝牙配对密钥不一致（常见于解绑后未在系统中忽略/取消配对）。\n\n'
              '请打开「设置 > 蓝牙」，找到该设备并选择「忽略此设备 / 取消配对」，然后返回 App 重新添加。',
      'addDevice': '添加设备',
      'lastSeenJustNow': '刚刚',
      'lastSeenMinutesAgo': '{m} 分钟前',
      'lastSeenHoursAgo': '{h} 小时前',
      'lastSeenDaysAgo': '{d} 天前',
      'currentLabel': '当前',
      'searchingForDevices': '正在搜索设备...',
      'ensureDeviceOn': '请确保设备已开机且未绑定其他账号。',
      'devicesFound': '发现的设备',
      'rescan': '重新扫描',
      'setupHelp': '设置帮助',
      'step1': '步骤 1',
      'step2': '步骤 2',
      'longPressRecording': '长按录音键直至屏幕亮起。',
      'bringDeviceClose': '将设备靠近手机。',
      'keepWithinMeters': '请保持 0.5 米内',
      'needMoreHelp': '需要更多帮助？',
      'gotItTryAgain': '知道了，再试一次',
      'startUsing': '开始使用',
      'retry': '重试',
      'connecting': '连接中...',
      'androidPairingConfirmHint': '若出现系统配对弹窗，请确认配对码后继续。',
      'connectedSuccessfully': '连接成功',
      'connectionFailed': '连接失败',
      'firmwareUpdate': '固件更新',
      'downloadingNewVersion': '正在下载新版本...',
      'installing': '安装中...',
      'keepDeviceClose': '请保持设备靠近并保持蓝牙连接。',
      'doNotTurnOffDuringInstall': '安装过程中请勿关闭设备或退出应用，以确保固件完整。',
      'remaining': '约剩余 4 分钟',
      'lastSeenLabel': '最后可见 {time}',
      'snLabel': '序列号',
      'deviceProtocolSummary':
          '协议要点：Clip AT over BLE(GATT)\n- Service=6E400001...\n- Command(Write)=6E400002...\n- Response/Progress(Notify)=6E400003...\n- FileData(Notify)=6E400004...',
      'deviceMtuLabel': '当前 MTU: {mtu}（有效载荷≈{payload} 字节）',
      'canNotFindDevice': '找不到设备？',
      'notLightingUpHint': '不亮？充电约 10 分钟后再试。',
      'defaultDeviceName': 'SenseCraft Voice Lav',
      'connectionFailedTryAgain': '请检查设备状态，确保设备已开机且在范围内。',
      'scanningChip': '扫描中',
      'firmwareUpToDate': '固件已是最新',
      'versionColon': '版本：{v}',
      'newFirmwareTitle': '新固件',
      'newFeaturesTitle': '新功能',
      'systemCheckTitle': '系统检查',
      'downloadUpdateNow': '立即下载更新',
      'laterButton': '稍后',
      'newFirmwareVersion': '新固件：{v}',
      'updateSuccessfulTitle': '更新成功',
      'updateSuccessfulMessage': '您的 SenseCraft Voice 已更新至最新版本 {version}。',
      'updateSuccessfulMessageWait': '你的设备已经升级到最新，请等待设备升级。',
      'updateFailedTitle': '更新失败',
      'updateFailedMessage': '升级失败。请保持蓝牙连接后重试。',
      'backToDevice': '返回设备',
      'batteryCheckLabel': '充电中或电量 ≥ 50%',
      'notRecordingLabel': '未在录音',
      'deviceConnectedLabel': '设备已连接',
      'firmwareLabel': '固件',
      'selectFirmwareFile': '选择固件文件 (ZIP/BIN)',
      'startFirmwareUpdate': '开始升级',
      'uploadingFirmware': '正在上传固件...',
      'otaCompleting': '正在完成，请稍候...',
      'otaDeviceNotConnected': '请先连接设备后再进行固件升级。',
      'cloudFirmwareTitle': '云端更新',
      'cloudFirmwareChecking': '正在检查更新...',
      'cloudFirmwareCheckAgain': '重新检查',
      'cloudFirmwareCheckFailed': '检查更新失败',
      'cloudFirmwareDownloading': '正在下载固件...',
      'downloadFirmwareButton': '下载固件',
      'firmwareDownloadedReady': '固件已下载，可开始升级。',
      'firmwareMustUpdate': '必须升级',
      'localFirmwareTitle': '本地文件',
      'selectFirmwareFileAgain': '重新选择文件',
      'fromCloudLabel': '云端固件',
      'fromLocalLabel': '本地文件',
      'cancelButton': '取消',
      'cloudFirmwareNoPermission': '当前账号暂无云端固件升级权限，您仍可使用本地固件文件升级。',
      'cloudFirmwareInvalidToken': '云端固件检查失败（登录状态无效）。请尝试重新登录，或使用本地固件文件升级。',
      // Recording - extra
      'deviceRecordingNoPauseResume': '设备录音暂不支持暂停/继续',
      'playbackSpeedTimes': '{s}x',
      'trimTimeZero': '0:00',
      // AI Config - extra
      'providerLabel': 'Provider',
      'hintModelExample': '例如 gpt-4o',
      'hintJsonExample': '{"foo":"bar"}',
      'savedLocalSyncFailed': '已保存本地，服务端同步失败：{error}',
      'deleteConfigurationTitle': '删除配置',
      'deleteConfigurationConfirm': '确定要删除「{name}」吗？',
      'deletedLocalDeleteFailed': '已删除本地，服务端删除失败：{error}',
      'llmProviders': 'LLM 服务',
      'sttProviders': 'STT 服务',
      'noProvidersYet': '暂无已配置的 LLM',
      'addLlmConfigSubtitle': '添加 LLM 配置以启用总结生成。',
      'addSttConfigSubtitle': '添加 STT 配置以启用转写。',
      'addNewConfiguration': '添加新配置',
      'saveConfiguration': '保存配置',
      'pleaseAddLlm': '请先添加 LLM 配置。',
      'pleaseAddStt': '请先添加 STT 配置。',
      'getStarted': '开始',
      'llmConfigurationTitle': 'LLM 配置',
      'llmConfigurationSubtitle': '大语言模型设置',
      'llmProviderTitle': 'LLM 服务',
      'sttConfigurationTitle': 'STT 配置',
      'sttConfigurationSubtitle': '语音转文字服务设置',
      'sttProviderTitle': 'STT 服务',
      'addConfiguration': '添加配置',
      'finishSetup': '完成设置',
      'sttProviderChip': 'STT 服务',
      'llmProviderChip': 'LLM 服务',
      'templatesTitle': '模板',
      'addNewTemplate': '添加新模板',
      'createTemplate': '创建模板',
      'hintMeetingMinutes': '例如：会议纪要',
      'hintEnterPrompt': '输入提示词...',
      'importTemplate': '导入模板',
      'hintShareKey': '例如 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',
      'importAction': '导入',
      'invalidKeyOrSharingStopped': '无效的密钥或分享已停止。',
      'importFailed': '导入失败：{error}',
      'templateDetails': '模板详情',
      'notFound': '未找到',
      'templateNameHint': '模板名称',
      'promptHint': '提示词...',
      'stopSharingFailed': '停止分享失败：{error}',
      'generateShareKey': '生成分享密钥',
      'copied': '已复制',
      'saveChanges': '保存修改',
      'deleteTemplateTitle': '删除模板',
      'deleteTemplateConfirm': '确定要删除「{name}」吗？',
      'importWithKey': '通过密钥导入',
      'templateKey': '模板密钥',
      'hintWhisperExample': '例如 whisper-1',
      'hintWssUrl': 'wss://',
      'hintBaseUrlExample': '例如 http://localhost:10095',
      'hintBaseUrlExampleHttps': '例如 https://api.openai.com',
      'hintRegionExample': '例如 cn-hangzhou',
      'hintModelPathExample': '例如 /path/to/model.bin',
      'hintIflytekApiSecret': '讯飞开放平台的「接口密钥」APISecret',
      'hintAliyunTingwuAppKey': '听悟 AppKey',
      'hintAliyunAccessKeyId': 'AccessKey ID',
      'hintAliyunAccessKeySecret': 'AccessKey Secret',
      'hintLocalhostVosk': 'http://localhost:2700',
      'hintLocalhostLocalWhisper': 'http://localhost:8080',
      'hintIflytekAppId': 'APPID',
      'hintLlmDoubaoModelName': '例如 ep-xxx 或 doubao-seed-2-0-pro-260215',
      'hintLlmOpenRouterModelName':
          '如 anthropic/claude-sonnet-4、google/gemini-2.5-flash、openai/gpt-4o。见 openrouter.ai/models',
      'hintLlmOpenAiModelName': '例如 gpt-4o、gpt-4o-mini',
      'hintLlmAnthropicModelName':
          '例如 claude-sonnet-4-0、claude-3-5-haiku-latest',
      'hintLlmGoogleGeminiModelName': '例如 gemini-2.5-flash、gemini-2.0-flash',
      'hintLlmQwenModelName': '例如 qwen-turbo、qwen-plus',
      'hintLlmDeepseekModelName': '例如 deepseek-chat、deepseek-reasoner',
      'hintLlmLlamaModelName': '本地 Ollama 服务上的模型名',
      'hintLlmCustomBaseUrl': '例如 http://localhost:11434/v1',
      'hintLlmQwenApiKey': 'DashScope API Key（dashscope.console.aliyun.com）',
      'hintLlmDeepseekApiKey': 'sk-...（platform.deepseek.com 获取）',
      'hintLlmOpenAiApiKey': 'sk-...（platform.openai.com 获取）',
      'hintLlmAnthropicApiKey': 'sk-ant-...（console.anthropic.com 获取）',
      'hintLlmGoogleGeminiApiKey': 'aistudio.google.com 获取的 API Key',
      'hintLlmDoubaoApiKey': '火山方舟控制台获取的 API Key',
      'hintLlmOpenRouterApiKey': 'openrouter.ai/keys 获取的 API Key',
      'hintLlmLlamaApiKey': '本地 Ollama 可选',
      'hintLlmModelCaption': '总结用大语言模型，与 STT 转写模型不是同一类，请勿混填。',
      'hintLlmQwenModelCaption':
          '总结请用 qwen-turbo 或 qwen-plus；勿填 fun-asr-realtime（那是 STT 转写专用）。',
      'hintLlmDeepseekModelCaption':
          '总结请用 deepseek-chat；基址 URL 填 api.deepseek.com/v1，不要填 platform 网页地址。',
      'hintSttModelCaption': '语音转文字模型；AI 总结请在 LLM 配置中单独设置。',
      'hintSttAliyunModelCaption':
          '转写专用：fun-asr-realtime；总结请在 LLM 配置中使用 qwen-turbo。',
      'hintSttBaiduModelName': '留空使用默认，或见百度 ASR 文档',
      'hintSttTencentModelName': '留空使用默认，或见腾讯 ASR 文档',
      'hintSttDoubaoModelName': '见火山引擎 ASR 文档',
      // Guide flow
      'guideWelcomeTitle': '欢迎！',
      'guideWelcomeSubtitle': '配置 AI 服务以启用语音转写与智能总结。',
      'guideSttServiceTitle': 'STT 服务',
      'guideSttServiceSubtitle': '实时将语音转为文字',
      'guideLlmServiceTitle': 'LLM 服务',
      'guideLlmServiceSubtitle': '提取要点与总结',
      'guideBackLabel': '返回',
      'guideNextStepLabel': '下一步',
      'guideAddEditLaterHint': '您可稍后在 AI 配置中添加或修改配置。',
      'guideAllSetTitle': '准备就绪！',
      'guideAllSetSubtitle': '您的 AI 服务已可使用。',
      'guideSttProviderLabel': 'STT 服务',
      'guideLlmProviderLabel': 'LLM 服务',
      'guideUpdateLaterHint': '您可随时在应用设置中更新这些配置。',
      // Template labels
      'templateNameLabel': '模板名称',
      'promptContentLabel': '提示词内容',
      'tapTemplateToEdit': '点击任意模板可编辑名称与提示词。',
      'enterKeyToImport': '输入他人分享的密钥以导入',
      'shareTemplateLabel': '分享模板',
      'stopSharingLabel': '停止分享',
      'shareKeyDescription': '将此密钥分享给他人，以便他们导入您的自定义提示词配置。',
      // AI Config editor
      'configuredFilesLabel': '已配置的文件',
      'addTooltip': '添加',
      'apiKeyConfigDetails': 'API 密钥配置详情',
      'requiredLabel': '必填',
      'optionalLabel': '选填',
      'advancedLabel': '高级',
      'testConnection': '测试连接',
      'testConnectionSuccess': '测试连接 ✓',
      'testFailed': '测试失败：{error}',
      'updateConfigurationLabel': '更新配置',
      // AI Config editor field labels
      'fieldLabelProvider': '服务商',
      'fieldLabelName': '名称',
      'fieldLabelApiKey': 'API 密钥',
      'fieldLabelApiKeyOptional': 'API 密钥（选填）',
      'fieldLabelApiKeyRequired': 'API 密钥（必填）',
      'fieldLabelBaseUrl': '基址 URL',
      'fieldLabelBaseUrlRequired': '基址 URL（必填）',
      'fieldLabelBaseUrlOptional': '基址 URL（选填）',
      'fieldLabelModelName': '模型名称',
      'fieldLabelModelNameOptional': '模型名称（选填）',
      'fieldLabelModelNameRequired': '模型名称（必填）',
      'fieldLabelModelNameAdvanced': '模型名称（高级）',
      'fieldLabelModuleNameOptional': '模块名称（选填）',
      'fieldLabelApiSecret': 'API 密钥/Secret',
      'fieldLabelApiSecretOptional': 'API Secret（选填）',
      'fieldLabelAppId': '应用 ID',
      'fieldLabelAppIdOptional': '应用 ID（选填）',
      'fieldLabelAppIdRequired': '应用 ID（必填）',
      'fieldLabelAccessKeyId': 'Access Key ID',
      'fieldLabelAccessKeyIdOptional': 'Access Key ID（选填）',
      'fieldLabelAccessKeySecret': 'Access Key Secret',
      'fieldLabelAccessKeySecretOptional': 'Access Key Secret（选填）',
      'fieldLabelRegion': '区域',
      'fieldLabelRegionOptional': '区域（选填）',
      'fieldLabelExtraJsonAdvanced': '扩展 JSON（高级）',
      'fieldLabelWsUrlOptional': 'WS URL（选填）',
      'fieldLabelSecretKey': 'Secret Key',
      'fieldLabelSecretKeyOptional': 'Secret Key（选填）',
      'fieldLabelSecretKeyRequired': 'Secret Key（必填）',
      'fieldLabelSecretId': 'Secret ID',
      'fieldLabelSecretIdOptional': 'Secret ID（选填）',
      'fieldLabelSecretIdRequired': 'Secret ID（必填）',
      'aliyunCredentialChoiceHint':
          '填写 API 密钥（DashScope），或 应用 ID + Secret ID + Secret Key（听悟），其中一组即可。',
      'fieldLabelAliyunApiKeyChoice': 'API 密钥（DashScope，或使用下方听悟凭据）',
      'fieldLabelAliyunAppKeyChoice': 'App Key（听悟，需同时填写 Access Key）',
      'fieldLabelAliyunAccessKeyIdChoice': 'Access Key ID（听悟，需同时填写 App Key）',
      'fieldLabelAliyunAccessKeySecretChoice':
          'Access Key Secret（听悟，需同时填写 App Key）',
      'fieldLabelCluster': '集群',
      'fieldLabelClusterRequired': '集群（必填）',
      'fieldLabelAccessToken': 'Access Token',
      'fieldLabelAccessTokenRequired': 'Access Token（必填）',
      'fieldLabelModelPath': '模型路径',
      'fieldLabelLanguage': '语言',
      'fieldLabelTranscriptionMode': '转写模式',
      'iflytekModeFile': '文件转写（推荐，先录后转）',
      'iflytekModeRealtime': '实时转写',
      'iflytekFileHint': '控制台「录音文件转写标准版」',
      'iflytekRealtimeHint': '控制台「实时语音转写标准版」',
      'validationIflytekSecretKeyForFile': '文件转写需填写 SecretKey',
      // AI Config validation
      'validationNameRequired': '请填写名称',
      'validationApiKeyRequired': '请填写 API 密钥',
      'validationAliyunCredentialRequired': '请填写 DashScope API 密钥，或完整填写听悟凭据。',
      'validationApiKeyRequiredLlc': '请填写 API 密钥',
      'validationInvalidWsUrl': 'WS URL 格式无效',
      'validationBaseUrlRequired': '请填写基址 URL',
      'validationAppIdRequired': '请填写应用 ID',
      'validationSecretKeyRequired': '请填写 Secret Key',
      'validationSecretIdRequired': '请填写 Secret ID',
      'validationClusterAccessTokenRequired': '请填写集群与 Access Token',
      'validationExtraJsonMustBeObject': '扩展 JSON 须为对象',
      'validationExtraJsonMustBeValid': '扩展 JSON 须为合法 JSON',
      'validationAccessKeyIdRequired': '请填写 Access Key ID',
      'validationAccessKeySecretRequired': '请填写 Access Key Secret',
      'validationRegionRequired': '请填写区域',
      'validationModelPathRequired': '请填写模型路径',
      'validationApiSecretRequired': '请填写 API Secret',
      'validationBaseUrlRequiredLlc': '请填写基址 URL',
      'validationInvalidBaseUrl': '基址 URL 格式无效',
      'validationModelNameRequired': '请填写 MODEL NAME',
      'validationGeminiModelNameInvalid':
          'Gemini 模型名格式不正确，请填写类似 gemini-2.5-flash 的名称',
      'validationModelNameFormatInvalid':
          '{provider} 模型名格式不正确，请填写类似 {example} 的名称',
      'validationDoubaoModelEndpointRequired':
          '需先在火山方舟控制台创建推理接入点，再将获得的接入点 ID 填入此处',
      // Auth - extra
      'appleSignInNotSupported':
          '当前设备不支持 Apple 登录（请在 iOS 真机上测试，并确认已登录 Apple ID）',
      'appleSignInNoToken': 'Apple 登录未返回 token（请检查 Sign in with Apple 能力与签名配置）',
      'appleSignInError': 'Apple 登录异常：{error}',
      'appleSignInCanceled': '已取消 Apple 登录',
      'appleSignInNotHandled': 'Apple 登录未处理（系统未能完成授权流程）',
      'appleSignInNotInteractive': 'Apple 登录不可交互（请解锁设备/关闭屏幕录制限制等）',
      'appleSignInCredentialExport':
          'Apple 登录失败：凭证导出失败（请检查系统钥匙串/iCloud 钥匙串状态后重试）',
      'appleSignInCredentialImport':
          'Apple 登录失败：凭证导入失败（请检查系统钥匙串/iCloud 钥匙串状态后重试）',
      'appleSignInMatchedExcluded':
          'Apple 登录失败：匹配到被排除的凭证（请在系统设置中检查 Apple ID 登录/钥匙串状态）',
      'appleSignInFailed': 'Apple 登录失败（请稍后重试）',
      'appleSignInInvalidResponse': 'Apple 登录失败：无效响应（请检查网络与系统状态）',
      'appleSignInUnknown':
          'Apple 登录失败：授权服务返回未知错误。常见原因：App ID 未开启 Sign in with Apple / 证书与描述文件未更新 / BundleId 不匹配。',
      'passwordHintDots': '••••••••',
      'googleSignInFailedCode': 'Google 登录失败：{code}',
      'googleSignInFailed': 'Google 登录失败：{error}',
      'googleSignInNoTokenAndroid':
          'Google 登录未返回 token。Android：在 Google Cloud 为包名 cc.seeed.voice 配置 OAuth（含 Debug/Release 的 SHA-1），并在 App 内使用正确的 Web serverClientId（见登录环境或 --dart-define=GOOGLE_SERVER_CLIENT_ID）。',
      'googleSignInNoTokenGeneric':
          'Google 登录未返回 token（请检查平台与 Google Cloud 配置）',
      'googleSignInCanceledOrMisconfigured':
          'Google 登录中断（canceled）。若您已选择账号，多为配置问题：请在 Google Cloud 核对包名 cc.seeed.voice、当前安装包签名的 SHA-1，以及 Web 类型的 serverClientId。',
      'githubSignInNotConfigured': 'GitHub 登录未配置：缺少 client_id',
      'githubSignInFailedShort': 'GitHub 登录失败',
      'oauthGitHubStateMismatch': 'GitHub 登录失败：state 不匹配',
      'oauthGitHubMissingCode': 'GitHub 登录失败：回调缺少 code',
      'oauthUnsupportedProvider': '不支持的登录方式',
      'oauthAllowAccess': '允许访问',
      'appleOauthPageTitle': '使用 Apple ID 登录',
      'appleOauthPageSubtitle':
          '点击下方按钮后会弹出系统 Apple 授权窗口。我们不会在 App 内“伪造”Apple 的账号/邮箱选择界面。',
      'oauthPartnerProductName': 'SenseCraft Voice',
      'oauthWantsAccessAfterBrand': ' 希望\n访问你的账户',
      'oauthReTerminalSyncDescription':
          '将允许 reTerminal 同步\n你的物联网配置与云端\n传感器等数据。',
      'oauthSecureIndustrialTunnel': '安全工业隧道',
      'oauthGithubPermReadProfileTitle': '读取你的公开个人资料',
      'oauthGithubPermReadProfileSubtitle': '含姓名、头像与简介等',
      'oauthGithubPermEmailTitle': '访问你的邮箱',
      'oauthGithubPermEmailSubtitle': '主邮箱地址会用于同步',
      'oauthPermViewProfileTitle': '查看你的基本资料',
      'oauthPermViewProfileSubtitle': '',
      'oauthPermManageHwTitle': '管理硬件配置文件',
      'oauthPermManageHwSubtitle': '',
      'wifiTransferTitle': 'WiFi 快传',
      'wifiTransferStart': '开始 WiFi 传输',
      'syncedFileEntriesCount': '已同步 {n} 个文件索引条目',
      'sttConfigDeleteFailed': '删除失败：{error}',
      'sessionMissingCannotSync': '设备未返回 session，且无法从设备拉取最新 session，暂无法同步文件',
      'promptTemplateSubtitleMeeting': '会议议程、任务与要点',
      'promptTemplateSubtitleLecture': '要点与问题',
      'promptTemplateSubtitleClass': '要点与问题',
      'promptTemplateSubtitleDailyDialogue': '人物 / 事项 / 时间与行动项',
      'promptTemplateSubtitleDailyConversation': '人物+事项+时间行动项',
      'promptTemplateSubtitleCustomDefault': '默认模版',
      'promptTemplateSubtitleCustomUser': '用户自定义模版',
      // Server / API errors
      'errorNetworkTimeout': '网络请求超时，请稍后重试。',
      'errorNetworkUnavailable': '网络不可用，请检查网络连接后重试。',
      'errorRequestFailed': '请求失败，请稍后重试。',
      'errorUnknown': '发生错误。',
      'errorLoginFailed': '登录失败。',
      'errorUserNotFound': '用户不存在。',
      'errorPasswordIncorrect': '密码错误。',
      'errorUserAlreadyExists': '用户已存在。',
      'errorEmailAlreadyRegistered': '该邮箱已被注册。',
      'errorTokenExpired': '登录已过期，请重新登录。',
      'errorTokenInvalid': '登录无效，请重新登录。',
      'errorVerifyCodeInvalid': '验证码错误。',
      'errorVerifyCodeExpired': '验证码已过期或错误，请重新获取。',
      'errorEmailNotVerified': '邮箱未验证。',
      'errorUnauthorized': '未授权。',
      'errorForbidden': '无访问权限。',
      'errorInvalidParams': '参数错误。',
      'errorInternalError': '服务器错误，请稍后重试。',
      'errorTimeout': '请求超时。',
      'errorUploadFailed': '上传失败。',
      'errorRecordNotFound': '记录不存在。',
      'errorAsrVendorNotConfigured': 'ASR 服务未配置。',
      'errorAsrUnsupportedFormat': '不支持的音频格式。',
      'errorDuplicateRecord': '相同键的记录已存在。',
      'errorAuditNotFound': '审计记录不存在。',
      'errorAuditExists': '审计记录已存在。',
      'errorRbacPolicyExists': '权限策略已存在。',
      'errorRbacPolicyNotFound': '权限策略不存在。',
      'errorRbacRoleExists': '角色已存在。',
      'errorRbacRoleNotFound': '角色不存在。',
      'errorAsrConfigAlreadyExists': 'ASR 配置已存在。',
      'errorAsrConfigNotFound': 'ASR 配置不存在，请先创建。',
      'errorAsrVendorNotFound': 'ASR 厂商不存在。',
      'errorAsrResultNotFound': '转写结果不存在或无权访问。',
      'errorAsrJobNotFound': '转写任务不存在或无权访问。',
      'errorLlmVendorNotConfigured': 'LLM 服务未配置。',
      'errorPromptTemplateNotFound': '提示词模版不存在。',
      'errorLlmConfigAlreadyExists': '该厂商的 LLM 配置已存在。',
      'errorLlmConfigNotFound': 'LLM 配置不存在。',
      'errorPromptAlreadyImported': '已经导入过该模版。',
      'promptTemplateUnsupportedChars':
          '模板名称或提示词包含服务端无法保存的字符（如表情）。请将数据库升级为 utf8mb4，或去掉表情后重试。',
      'promptTemplateFieldsInvalid': '请填写模板名称（1–128 个字符）和提示词内容。',
      'errorNetworkRequestFailed': '网络请求失败，请检查网络连接后重试。',
      'errorNotImplemented': '该功能暂未开放。',
      'errorBusySystem': '系统繁忙，请稍后重试。',
      'errorAccountNotFound': '账号不存在，请检查邮箱或先注册。',
      'errorAccountFrozen': '账号已冻结，请联系客服。',
      'errorTooManyLoginAttempts': '登录尝试次数过多，请稍后再试。',
      'errorOauthFailed': '第三方登录失败，请重试。',
      'errorUnsupportedOAuthProvider': '不支持该第三方登录方式。',
      'errorUserInfoError': '无法获取账号信息，请重新登录。',
      'errorVerifyCodeNotExpired': '验证码仍在有效期内，请查收邮件或稍后再试。',
      'errorRecordNotUpdate': '记录更新失败。',
      'errorClusterNotFound': '服务集群不存在。',
      'errorTenantNotFound': '账号不存在。',
      'errorTenantExists': '账号已存在。',
      'errorRemoteCalled': '远程服务调用失败，请稍后重试。',
      'errorPathNotFound': '请求的接口路径不存在。',
      'errorMissingParams': '缺少必要参数，请重新登录。',
      'errorNewPasswordSameAsOld': '新密码不能与当前密码相同。',
      'errorMobileAlreadyRegistered': '该手机号已被注册。',
      'errorSmsCodeAlreadySent': '短信验证码已发送，请稍后再试。',
      'errorMobileRequired': '请填写手机号。',
      'errorMobileFormatInvalid': '手机号格式不正确。',
      'errorOssUploadNotConfigured': '服务器未配置文件上传。',
      'errorOssPresignFailed': '生成上传地址失败，请重试。',
      'errorAuthorizeCodeInvalid': '授权码无效，请重试。',
      'errorOauthStateMismatch': '登录状态已失效，请重新发起授权。',
      'errorOauthCodeMissing': '未提供授权码。',
      'errorOauthStateMissing': '未提供登录状态，请重试。',
      'errorOauthAccountNeedBind': '该邮箱已注册，请使用邮箱登录或绑定账号。',
      'errorChildAccountCannotDelete': '子账号无法注销。',
      'errorTermsAcceptanceRequired': '请先同意服务条款后再登录。',
      'errorOauthForeignIdTaken': '该第三方账号已绑定其他账号。',
      'errorOauthOrgAlreadyBound': '当前账号已绑定其他登录方式。',
      'errorOauthWechatNoUnionid': '微信未返回 unionid，请确认应用已绑定开放平台且用户已授权。',
      // Auth API errors
      'authLoginResponseFormat': '登录失败：响应格式错误。',
      'authLoginFailed': '登录失败。',
      'authRegisterMissingResult': '注册失败：响应缺少 result。',
      'authLoginMissingResult': '登录失败：响应缺少 result。',
      'authRequestFormat': '请求失败：响应格式错误。',
      // ASR API errors
      'asrRequestFormat': '请求失败：响应格式错误。',
      'asrGetConfigMissingResult': '获取配置失败：响应缺少 result。',
      'asrTranscribeMissingResult': '识别失败：响应缺少 result。',
      // User API errors
      'userApiUploadTypeEmpty': '上传失败：type 不能为空。',
      'userApiUploadFileNotFound': '上传失败：文件不存在。',
      'userApiUploadFailed': '上传失败。',
      'userApiUploadMissingResult': '上传失败：响应缺少 result。',
      'userApiUploadMissingPublicUrl': '上传失败：响应缺少 public_url。',
      'userApiLogoutFailed': '退出登录失败。',
      'userApiDeactivateFailed': '删除账号失败。',
      'userApiResetPasswordFailed': '重置密码失败。',
      'userApiChangePasswordFailed': '修改密码失败。',
      'userApiUpdateProfileFailed': '修改用户信息失败。',
      'userApiUpdateEmailFailed': '修改邮箱失败。',
      'userApiGetMeFailed': '获取用户信息失败。',
      'userApiGetMeMissingResult': '获取用户信息失败：响应缺少 result。',
      // LLM API errors
      'llmErrorResponseFormat': '请求失败：响应格式错误。',
      'llmErrorPublicTemplatesMissingResult': '获取公共模版失败：响应缺少 result 列表。',
      'llmErrorGetTemplateMissingResult': '获取模版失败：响应缺少 result。',
      'llmErrorCreateTemplateMissingResult': '创建模版失败：响应缺少 result。',
      'llmErrorPreviewTemplateMissingResult': '预览模版失败：响应缺少 result。',
      'llmErrorImportTemplateMissingResult': '导入模版失败：响应缺少 result。',
      'llmErrorStartShareMissingResult': '开始分享失败：响应缺少 result。',
      'llmErrorConfigNotSynced': 'LLM 配置未同步到服务端。',
      'llmErrorSystemPromptEmpty': 'system_prompt 不能为空。',
      'llmErrorResponseEmpty': '请求失败：响应为空。',
      'llmErrorSummaryEmpty': '总结为空。',
      // Router / App
      'pageNotFound': '页面不存在',
      'appTitle': 'SenseCraft Voice',
    },
  };
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => ['en', 'zh'].contains(locale.languageCode);

  @override
  Future<AppLocalizations> load(Locale locale) async {
    return AppLocalizations(locale);
  }

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}
