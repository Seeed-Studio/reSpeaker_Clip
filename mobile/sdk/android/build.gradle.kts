plugins {
    id("com.android.library") version "8.9.1"
    id("org.jetbrains.kotlin.android") version "2.1.0"
    id("maven-publish")
}

group = "io.sensecraft"
version = "0.1.0"

android {
    namespace = "io.sensecraft.voice.android"
    compileSdk = 36

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }
}

publishing {
    publications {
        register<MavenPublication>("release") {
            groupId = project.group.toString()
            artifactId = "sensecraft-voice-android"
            version = project.version.toString()
            afterEvaluate {
                from(components["release"])
            }
            pom {
                name.set("SenseCraft Voice Android SDK")
                description.set("Native Android SDK for SenseCraft Voice devices")
                url.set("https://github.com/Seeed-Studio/sensecraft-voice-android")
                licenses {
                    license {
                        name.set("SenseCraft Voice SDK Commercial License")
                        distribution.set("repo")
                    }
                }
            }
        }
    }
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.1")
    // Public OTA transport constructors expose mcumgr types, so consumers need
    // the dependency on their compile classpath as well as at runtime.
    api("no.nordicsemi.android:mcumgr-ble:2.7.4")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.1")
}
