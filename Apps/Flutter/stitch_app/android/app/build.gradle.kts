plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.lumia.stitch_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.lumia.stitch_app"
        minSdk = 29
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    implementation("androidx.core:core:1.15.0")
}

// The coordinator stages ABI-matched job-core artifacts here; no older core is bundled.
val stagedCore = rootProject.projectDir.resolve("../../../../.local/flutter-stitch-core/jniLibs")
android.sourceSets["main"].jniLibs.srcDir(stagedCore)
tasks.configureEach {
    if (name == "preBuild") doLast {
        val requested = listOf("arm64-v8a", "x86_64")
        val absent = requested.filter { !stagedCore.resolve("$it/liblumia_gigascan_core.so").isFile }
        if (absent.isNotEmpty()) logger.warn("Lumia Stitch native core unavailable for ${absent.joinToString()}; native jobs will remain disabled")
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
