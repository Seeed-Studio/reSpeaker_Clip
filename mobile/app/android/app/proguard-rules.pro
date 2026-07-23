# ----------------------------------------------------------------------------
# Prevent Pigeon channels from being stripped by R8/ProGuard in release builds, which causes channel-error.
# See: https://github.com/flutter/flutter/issues/153075
# Example error: SharedPreferencesApi.getAll / GoogleSignInApi.getCredential
# ----------------------------------------------------------------------------

# Keep all plugin classes implementing FlutterPlugin so method channels can connect.
-if class * implements io.flutter.embedding.engine.plugins.FlutterPlugin
-keep,allowshrinking,allowobfuscation class <1>

# Keep Pigeon-generated API implementation classes (shared_preferences_android, google_sign_in_android, etc.)
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-keep class io.flutter.plugins.googlesignin.** { *; }

# Keep GeneratedPluginRegistrant to ensure plugins are registered correctly.
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }

# Sentry (sentry_flutter) — reflectively reads SDK / event fields
# https://docs.sentry.io/platforms/android/configuration/proguard/
-keep class io.sentry.** { *; }
-keep class io.sentry.android.** { *; }
-dontwarn io.sentry.**
