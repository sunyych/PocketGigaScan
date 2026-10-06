import groovy.json.JsonSlurper
import java.security.MessageDigest
import java.nio.file.Files
import java.nio.file.StandardCopyOption

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

fun sha256(file: File): String {
    val digest = MessageDigest.getInstance("SHA-256")
    file.inputStream().use { input ->
        val buffer = ByteArray(64 * 1024)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            digest.update(buffer, 0, count)
        }
    }
    return digest.digest().joinToString("") { "%02x".format(it) }
}

private val localPropertiesNormalizationLock = Any()
private val windowsDriveProperty = Regex("(?m)^(sdk\\.dir|flutter\\.sdk)=([A-Za-z]):(?=[\\\\/])")

fun normalizeGeneratedWindowsLocalProperties(propertiesFile: File) {
    synchronized(localPropertiesNormalizationLock) {
        if (!propertiesFile.isFile) return
        val original = propertiesFile.readText()
        val normalized = windowsDriveProperty.replace(original) { match ->
            "${match.groupValues[1]}=${match.groupValues[2]}\\:"
        }
        if (normalized == original) return
        val temporary = File(propertiesFile.parentFile, "${propertiesFile.name}.lint-normalizing")
        temporary.writeText(normalized)
        try {
            Files.move(
                temporary.toPath(),
                propertiesFile.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
                StandardCopyOption.ATOMIC_MOVE,
            )
        } finally {
            temporary.delete()
        }
    }
}

fun verifyNativeLicenseAssets(assetRoot: File, cargoLock: File) {
    val licenseRoot = assetRoot.resolve("native-licenses").canonicalFile
    val manifestFile = licenseRoot.resolve("manifest.json")
    check(manifestFile.isFile) { "Generated native license manifest is missing: ${manifestFile.absolutePath}" }
    val manifest = JsonSlurper().parse(manifestFile) as? Map<*, *>
        ?: error("Native license manifest must be a JSON object")
    check((manifest["schemaVersion"] as? Number)?.toInt() == 1 && manifest["complete"] == true) {
        "Native license manifest is incomplete or uses an unsupported schema"
    }
    val entries = manifest["files"] as? List<*>
        ?: error("Native license manifest has no files list")
    val listedPaths = mutableSetOf<String>()
    for (entry in entries) {
        val item = entry as? Map<*, *> ?: error("Invalid native license manifest entry")
        val relative = item["path"] as? String ?: error("Native license entry has no path")
        val expectedHash = item["sha256"] as? String ?: error("Native license entry has no sha256")
        val file = licenseRoot.resolve(relative).canonicalFile
        check(file.path.startsWith(licenseRoot.path + File.separator) && file.isFile) {
            "Native license manifest points outside its root or to a missing file: $relative"
        }
        check(listedPaths.add(relative)) { "Duplicate native license manifest entry: $relative" }
        check(sha256(file).equals(expectedHash, ignoreCase = true)) {
            "Native license asset checksum mismatch: $relative"
        }
    }

    val required = setOf(
        "project/LICENSE",
        "project/NOTICE",
        "project/native-core/LICENSE",
        "opencv/LICENSE",
        "upstream/libjxl-0.12.0/LICENSE",
        "upstream/Brotli/LICENSE",
        "upstream/Highway/LICENSE",
        "upstream/skcms/LICENSE",
        "THIRD_PARTY_NOTICES.md",
    )
    check(listedPaths.containsAll(required)) {
        "Native license manifest is missing required files: ${required - listedPaths}"
    }
    check(listedPaths.any { it.startsWith("opencv/sdk/etc/licenses/") }) {
        "Native license manifest is missing OpenCV SDK license files"
    }

    val registryPackages = cargoLock.readText().split(Regex("(?m)^\\[\\[package\\]\\]\\s*$"))
        .drop(1)
        .mapNotNull { block ->
            val source = Regex("(?m)^source\\s*=\\s*\"([^\"]+)\"").find(block)?.groupValues?.get(1)
            if (source?.startsWith("registry+") != true) return@mapNotNull null
            val name = Regex("(?m)^name\\s*=\\s*\"([^\"]+)\"").find(block)?.groupValues?.get(1)
                ?: error("Cargo registry package has no name")
            val version = Regex("(?m)^version\\s*=\\s*\"([^\"]+)\"").find(block)?.groupValues?.get(1)
                ?: error("Cargo registry package has no version")
            "$name-$version"
        }
    check(registryPackages.isNotEmpty()) { "Cargo.lock contains no registry dependencies" }
    val missingCargoLicenses = registryPackages.filter { packageId ->
        listedPaths.none { it.startsWith("cargo/$packageId/") }
    }
    check(missingCargoLicenses.isEmpty()) {
        "Native license manifest is missing Cargo dependency license folders: ${missingCargoLicenses.joinToString()}"
    }

    val actualPaths = licenseRoot.walkTopDown()
        .filter { it.isFile && it.canonicalFile != manifestFile.canonicalFile }
        .map { licenseRoot.toPath().relativize(it.toPath()).toString().replace('\\', '/') }
        .toSet()
    check(actualPaths == listedPaths) {
        "Native license manifest does not cover the generated tree (unlisted=${actualPaths - listedPaths}, missing=${listedPaths - actualPaths})"
    }
}

fun verifyAndroidElf(file: File, abi: String) {
    val header = ByteArray(20)
    file.inputStream().use { input ->
        var offset = 0
        while (offset < header.size) {
            val count = input.read(header, offset, header.size - offset)
            check(count > 0) { "Staged native library has a truncated ELF header: ${file.absolutePath}" }
            offset += count
        }
    }
    check(header[0] == 0x7f.toByte() && header[1] == 'E'.code.toByte() &&
        header[2] == 'L'.code.toByte() && header[3] == 'F'.code.toByte()) {
        "Staged native library is not ELF: ${file.absolutePath}"
    }
    check(header[4] == 2.toByte() && header[5] == 1.toByte()) {
        "Staged native library must be 64-bit little-endian ELF: ${file.absolutePath}"
    }
    val machine = (header[18].toInt() and 0xff) or ((header[19].toInt() and 0xff) shl 8)
    val expectedMachine = when (abi) {
        "arm64-v8a" -> 183
        "x86_64" -> 62
        else -> error("Unsupported staged ABI: $abi")
    }
    check(machine == expectedMachine) {
        "Staged ELF machine $machine does not match ABI $abi: ${file.absolutePath}"
    }
    val elfType = (header[16].toInt() and 0xff) or ((header[17].toInt() and 0xff) shl 8)
    check(elfType == 3) { "Staged native library must be an ELF shared object: ${file.absolutePath}" }
}

fun verifyStagedCore(abiDirectory: File, abi: String) {
    val core = abiDirectory.resolve("liblumia_gigascan_core.so")
    val runtime = abiDirectory.resolve("libc++_shared.so")
    val manifestFile = abiDirectory.resolve("build-manifest.json")
    check(core.isFile && runtime.isFile && manifestFile.isFile) {
        "Staged native core, libc++_shared.so, or build manifest is missing for $abi"
    }
    val manifest = JsonSlurper().parse(manifestFile) as? Map<*, *>
        ?: error("Native core build manifest must be a JSON object for $abi")
    val expectedTarget = when (abi) {
        "arm64-v8a" -> "aarch64-linux-android"
        "x86_64" -> "x86_64-linux-android"
        else -> error("Unsupported staged ABI: $abi")
    }
    check(manifest["product"] == "PocketGigaScan native core" &&
        manifest["abi"] == abi && manifest["target"] == expectedTarget &&
        (manifest["apiLevel"] as? Number)?.toInt() == 29 &&
        manifest["ndkVersion"] == "28.2.13676358" &&
        manifest["noUndefinedSymbols"] == true && manifest["loadSegments16KiBAligned"] == true) {
        "Native core provenance does not match ABI/API/NDK or required link guarantees for $abi"
    }
    val requiredExports = setOf(
        "lumia_gigascan_abi_version",
        "lumia_gigascan_is_available",
        "lumia_gigascan_plan_json",
        "lumia_gigascan_stitch_json",
        "lumia_gigascan_register_json",
        "lumia_gigascan_spherical_json",
        "lumia_gigascan_job_json",
        "lumia_gigascan_free",
        "lumia_gigascan_free_json",
    )
    val exports = (manifest["ffiExports"] as? List<*>)?.filterIsInstance<String>()?.toSet()
        ?: error("Native core manifest is missing its FFI export list for $abi")
    check(exports.containsAll(requiredExports)) {
        "Native core FFI manifest is incomplete for $abi: ${requiredExports - exports}"
    }
    val coreHash = manifest["coreSha256"] as? String
        ?: error("Native core manifest is missing its core checksum for $abi")
    val runtimeHash = manifest["libcxxSha256"] as? String
        ?: error("Native core manifest is missing its libc++ checksum for $abi")
    check(coreHash.matches(Regex("[0-9a-fA-F]{64}")) && sha256(core).equals(coreHash, ignoreCase = true)) {
        "Staged native core checksum does not match its manifest for $abi"
    }
    check(runtimeHash.matches(Regex("[0-9a-fA-F]{64}")) && sha256(runtime).equals(runtimeHash, ignoreCase = true)) {
        "Staged libc++ checksum does not match its manifest for $abi"
    }
    for ((file, key) in listOf(core to "coreElf", runtime to "libcxxElf")) {
        val elf = manifest[key] as? Map<*, *> ?: error("Native core manifest is missing $key for $abi")
        val machine = if (abi == "arm64-v8a") "AArch64" else "Advanced Micro Devices X86-64"
        check(elf["machine"] == machine &&
            (elf["minimumLoadAlignmentBytes"] as? Number)?.toInt()?.let { it >= 16384 } == true &&
            elf["hasGnuRelro"] == true) {
            "Native ELF provenance does not meet architecture/alignment requirements for $abi ($key)"
        }
        verifyAndroidElf(file, abi)
    }
}

val selectedStitchAbis = providers.gradleProperty("stitchAbis")
    .orElse("arm64-v8a")
    .get()
    .split(',')
    .map { it.trim() }
    .filter { it.isNotEmpty() }
val supportedStitchAbis = setOf("arm64-v8a", "x86_64")
require(selectedStitchAbis.isNotEmpty() && selectedStitchAbis.all { it in supportedStitchAbis }) {
    "stitchAbis must select one or more supported ABIs: ${supportedStitchAbis.joinToString()}"
}

android {
    namespace = "com.lumia.stitch_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    // Flutter plugins can contribute their own JNI binaries after NDK ABI filters
    // are applied. Exclude every non-selected ABI at the final APK packaging layer.
    packaging {
        jniLibs {
            val knownAndroidAbis = setOf(
                "armeabi",
                "armeabi-v7a",
                "arm64-v8a",
                "x86",
                "x86_64",
                "mips",
                "mips64",
            )
            excludes += knownAndroidAbis
                .filterNot { it in selectedStitchAbis }
                .map { "lib/$it/**" }
        }
    }

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
        ndk {
            abiFilters.addAll(selectedStitchAbis)
        }
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
    testImplementation("junit:junit:4.13.2")
}

// The coordinator stages ABI-matched job-core artifacts here; no older core is bundled.
val stagedCore = rootProject.projectDir.resolve("../../../../.local/flutter-stitch-core/jniLibs")
android.sourceSets["main"].jniLibs.srcDir(stagedCore)
val stagedAndroidAssets = rootProject.projectDir.resolve("../../../../.local/flutter-stitch-core/android-assets")
android.sourceSets["main"].assets.srcDir(stagedAndroidAssets)
tasks.configureEach {
    if (name.startsWith("lintAnalyze")) doFirst {
        normalizeGeneratedWindowsLocalProperties(rootProject.projectDir.resolve("local.properties"))
    }
    if (name == "preBuild") doFirst {
        for (abi in selectedStitchAbis) {
            try {
                verifyStagedCore(stagedCore.resolve(abi), abi)
            } catch (error: Exception) {
                throw GradleException(
                    "Required ABI-matched native core validation failed for $abi at ${stagedCore.absolutePath}: ${error.message}",
                    error,
                )
            }
        }
        verifyNativeLicenseAssets(
            stagedAndroidAssets,
            rootProject.projectDir.resolve("../../../../native/core/Cargo.lock"),
        )
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
