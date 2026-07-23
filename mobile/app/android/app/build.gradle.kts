import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "cc.seeed.voice"
    // flutter_web_auth_2 -> androidx.browser:browser:1.9.0 requires compileSdk 36+
    compileSdk = 36
    // Must match a *fully installed* NDK under ANDROID_SDK/ndk/<revision> (with source.properties).
    // 28.2.13676358 was left incomplete (.installer only) — use a complete side-by-side install.
    ndkVersion = "28.0.12674087"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "cc.seeed.voice"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // The `record` / `ffmpeg_kit_flutter_new` plugins require a higher minSdk on Android.
        // Flutter's default flutter.minSdkVersion is usually 21; raise it to avoid manifest merger failures.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    /**
     * Release signing (secure approach)
     *
     * - Local: put the keystore path and passwords in `android/key.properties` (not committed to git)
     * - CI: inject via environment variables (also never written to disk)
     *
     * See android/key.properties.example for the key.properties template.
     */
    val keystoreProperties = Properties()
    val keystorePropertiesFile = rootProject.file("key.properties")
    if (keystorePropertiesFile.exists()) {
        keystoreProperties.load(FileInputStream(keystorePropertiesFile))
    }

    val storeFilePath = (keystoreProperties["storeFile"] as String?)
        ?: System.getenv("ANDROID_KEYSTORE_FILE")
    val storePasswordValue = (keystoreProperties["storePassword"] as String?)
        ?: System.getenv("ANDROID_KEYSTORE_PASSWORD")
    val keyAliasValue = (keystoreProperties["keyAlias"] as String?)
        ?: System.getenv("ANDROID_KEY_ALIAS")
    val keyPasswordValue = (keystoreProperties["keyPassword"] as String?)
        ?: System.getenv("ANDROID_KEY_PASSWORD")

    val canSignRelease = !storeFilePath.isNullOrBlank() &&
        !storePasswordValue.isNullOrBlank() &&
        !keyAliasValue.isNullOrBlank() &&
        !keyPasswordValue.isNullOrBlank()

    // Only require signing when a release build is actually requested, so debug (flutter run/assembleDebug) is unaffected.
    val isReleaseTaskRequested = gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }
    if (isReleaseTaskRequested && !canSignRelease) {
        throw GradleException(
            "Missing Android release signing config. " +
                "Create android/key.properties or set env vars: " +
                "ANDROID_KEYSTORE_FILE, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD."
        )
    }

    signingConfigs {
        if (canSignRelease) {
            create("release") {
                storeFile = file(storeFilePath!!)
                storePassword = storePasswordValue
                keyAlias = keyAliasValue
                keyPassword = keyPasswordValue
            }
        }
    }

    buildTypes {
        debug {
            // Option B: Debug and Release share the `release` signing config (needs android/key.properties or CI env vars).
            // This makes the APK installed by `flutter run` share the SHA-1 with the store build, so the Google OAuth
            // Android client only needs a single fingerprint. Falls back to the default android.debug.keystore when no
            // production key is configured.
            if (canSignRelease) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
        release {
            // Release uses the production signing config (secure: keys are not committed).
            signingConfig = if (canSignRelease) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
            // Disable code shrinking/obfuscation to avoid Pigeon channels being stripped, which causes channel-error
            // (native channels of plugins like shared_preferences, google_sign_in would fail to connect).
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}
