plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

val supportedAndroidAbi = "arm64-v8a"
val swiftCoreJniLibsRoot = layout.buildDirectory.dir("generated/swiftCore/jniLibs")
val swiftCoreArm64Directory = swiftCoreJniLibsRoot.map { it.dir(supportedAndroidAbi) }
val lumiaCoreJniLibsRoot = layout.buildDirectory.dir("generated/lumiaCore/jniLibs").get().asFile
val lumiaCoreArm64Directory = lumiaCoreJniLibsRoot.resolve(supportedAndroidAbi)
val repositoryRoot = rootProject.projectDir.parentFile.parentFile
val stageSwiftCoreScript = repositoryRoot.resolve("scripts/android-stage-swift-core.sh")

fun File.bashPath(): String {
    val normalized = invariantSeparatorsPath
    val drivePath = Regex("^([A-Za-z]):/(.*)$").matchEntire(normalized)
    return if (drivePath == null) {
        normalized
    } else {
        "/mnt/${drivePath.groupValues[1].lowercase()}/${drivePath.groupValues[2]}"
    }
}

val resolvedVersionCode: Int =
    (findProperty("versionCode") ?: property("openpocketcine.versionCode")).toString().toInt()
val resolvedVersionName: String = property("openpocketcine.versionName").toString()

android {
    namespace = "com.opencapture.openpocketcine"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.opencapture.openpocketcine"
        minSdk = 29
        targetSdk = 36
        versionCode = resolvedVersionCode
        versionName = resolvedVersionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        ndk {
            abiFilters += supportedAndroidAbi
        }
        externalNativeBuild {
            cmake {
                arguments += "-DANDROID_STL=c++_static"
            }
        }
    }

    ndkVersion = "28.2.13676358"

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    // Play closed testing signs with the upload keystore from the environment.
    // Debug and unsigned local release stay possible when the env is unset.
    // See docs/android-play-ci.md.
    val uploadKeystorePath = System.getenv("ANDROID_KEYSTORE_FILE").orEmpty()
    if (uploadKeystorePath.isNotEmpty()) {
        val uploadKeystore = file(uploadKeystorePath)
        require(uploadKeystore.isFile) {
            "ANDROID_KEYSTORE_FILE is set but not a file: $uploadKeystorePath"
        }
        signingConfigs {
            create("release") {
                storeFile = uploadKeystore
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                    ?: error("ANDROID_KEYSTORE_PASSWORD is required when ANDROID_KEYSTORE_FILE is set")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                    ?: error("ANDROID_KEY_ALIAS is required when ANDROID_KEYSTORE_FILE is set")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
                    ?: System.getenv("ANDROID_KEYSTORE_PASSWORD")
                    ?: error("ANDROID_KEY_PASSWORD is required when ANDROID_KEYSTORE_FILE is set")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            if (uploadKeystorePath.isNotEmpty()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }

    sourceSets {
        getByName("main").jniLibs.directories.apply {
            clear()
            add(swiftCoreJniLibsRoot.get().asFile.absolutePath)
            add(lumiaCoreJniLibsRoot.absolutePath)
        }
    }
}

val stageSwiftCore =
    tasks.register<Exec>("stageSwiftCore") {
        group = "build"
        description = "Cross-compile and stage the Swift camera core for arm64-v8a."
        workingDir = repositoryRoot
        inputs.files(
            fileTree(repositoryRoot) {
                include("Package.swift", "Package.resolved", "Sources/**")
            },
            stageSwiftCoreScript,
        )
        inputs.property("swiftExecutable", providers.environmentVariable("SWIFT_EXECUTABLE").orElse("auto"))
        inputs.property(
            "swiftAndroidSdk",
            providers.environmentVariable("SWIFT_ANDROID_SDK_ID").orElse("swift-6.3.3-RELEASE_android"),
        )
        outputs.dir(swiftCoreArm64Directory)
        commandLine(
            "bash",
            stageSwiftCoreScript.bashPath(),
            "--output",
            swiftCoreArm64Directory.get().asFile.bashPath(),
        )
    }

val lumiaCoreArtifactDirectory =
    file(
        System.getenv("LUMIA_GIGASCAN_CORE_DIR")
            ?: repositoryRoot.parentFile.resolve(
                "lumia-gigascan-core/target/aarch64-linux-android/release",
            ).path,
    )
val lumiaCoreArtifact = lumiaCoreArtifactDirectory.resolve("liblumia_gigascan_core.so")

val stageLumiaGigaScanCore =
    tasks.register<Copy>("stageLumiaGigaScanCore") {
        group = "build"
        description = "Stage the independently built Lumia GigaScan Core for arm64-v8a."
        from(lumiaCoreArtifact)
        into(lumiaCoreArm64Directory)
    }

tasks.named("preBuild").configure {
    dependsOn(stageSwiftCore)
    dependsOn(stageLumiaGigaScanCore)
}

// Compose BOM / androidx.core AARs currently declare compileSdk 37. Local and
// CI SDKs stay on 36 (same gate OpenZCine uses). Disable only the AAR metadata
// check so the rest of the AGP graph still runs.
afterEvaluate {
    tasks.matching { it.name.startsWith("check") && it.name.endsWith("AarMetadata") }
        .configureEach { enabled = false }
}

dependencies {
    implementation(project(":core-api"))

    implementation(platform(libs.compose.bom))
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.core.splashscreen)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons.extended)
    implementation(libs.kyant.backdrop)
    implementation(libs.kyant.shapes)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.media3.common)
    implementation(libs.media3.effect)
    implementation(libs.media3.exoplayer)
    implementation(libs.media3.ui)
    implementation(libs.okhttp)
    implementation(libs.mlkit.face.detection)

    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.json)
    testImplementation(libs.kotlinx.coroutines.test)
}
