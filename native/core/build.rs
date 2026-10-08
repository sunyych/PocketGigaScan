fn main() {
    println!("cargo:rustc-check-cfg=cfg(lumia_jxl)");
    println!("cargo:rustc-check-cfg=cfg(lumia_jxl_test_helpers)");
    println!("cargo:rerun-if-changed=src/native/sift_bridge.cpp");
    println!("cargo:rerun-if-changed=src/native/projection_bridge.cpp");
    println!("cargo:rerun-if-changed=src/native/jxl_stream_bridge.cpp");
    println!("cargo:rerun-if-env-changed=OPENCV_DIR");
    println!("cargo:rerun-if-env-changed=OPENCV_INCLUDE_PATHS");
    println!("cargo:rerun-if-env-changed=OPENCV_LINK_PATHS");
    println!("cargo:rerun-if-env-changed=OPENCV_LINK_LIBS");
    println!("cargo:rerun-if-env-changed=OPENCV_LINK_FRAMEWORKS");
    println!("cargo:rerun-if-env-changed=LUMIA_JXL_SDK");
    println!("cargo:rerun-if-env-changed=LUMIA_JXL_LINK_PATHS");
    println!("cargo:rerun-if-env-changed=LUMIA_JXL_TEST_HELPERS");
    println!("cargo:rerun-if-changed=windows/lumia_gigascan_core.rc");
    let root = std::env::var("OPENCV_DIR").expect(
        "OPENCV_DIR must point to an OpenCV install (include/ and a platform library directory)",
    );
    let root = std::path::PathBuf::from(root);
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let target_env = std::env::var("CARGO_CFG_TARGET_ENV").unwrap_or_default();
    if target_os == "windows" && target_env == "msvc" {
        add_windows_version_resource();
    }
    let mut build = cc::Build::new();
    build
        .cpp(true)
        .file("src/native/sift_bridge.cpp")
        .file("src/native/projection_bridge.cpp");
    let include_paths = std::env::var("OPENCV_INCLUDE_PATHS")
        .ok()
        .map(|paths| std::env::split_paths(&paths).collect::<Vec<_>>())
        .unwrap_or_else(|| vec![root.join("include")]);
    for include in &include_paths {
        build.include(include);
    }
    if target_os == "windows" {
        build.flag_if_supported("/EHsc");
        build.flag_if_supported("/std:c++17");
        build.static_crt(true);
    } else {
        build.flag_if_supported("-std=c++17");
    }
    build.compile("lumia_sift_bridge");

    let jxl_sdk = std::env::var_os("LUMIA_JXL_SDK").map(std::path::PathBuf::from);
    if target_os == "windows" || target_os == "android" || target_os == "ios" {
        if let Some(sdk) = jxl_sdk {
            let include = sdk.join("include");
            let lib = std::env::var_os("LUMIA_JXL_LINK_PATHS")
                .map(|paths| std::env::split_paths(&paths).collect::<Vec<_>>())
                .unwrap_or_else(|| vec![sdk.join("lib")]);
            let (required, libraries): (&[&str], &[&str]) = if target_os == "windows" {
                (
                    &[
                        "jxl.lib",
                        "jxl_cms.lib",
                        "hwy.lib",
                        "brotlienc.lib",
                        "brotlidec.lib",
                    ],
                    &[
                        "jxl",
                        "jxl_cms",
                        "hwy",
                        "brotlienc",
                        "brotlidec",
                        "brotlicommon",
                    ],
                )
            } else {
                (
                    &[
                        "libjxl.a",
                        "libjxl_cms.a",
                        "libhwy.a",
                        "libbrotlienc.a",
                        "libbrotlidec.a",
                        "libbrotlicommon.a",
                    ],
                    &[
                        "jxl",
                        "jxl_cms",
                        "hwy",
                        "brotlienc",
                        "brotlidec",
                        "brotlicommon",
                    ],
                )
            };
            for name in required {
                let present = lib.iter().any(|directory| directory.join(name).is_file());
                if !present {
                    panic!(
                        "LUMIA_JXL_SDK is missing {name} in {}",
                        lib.iter()
                            .map(|p| p.display().to_string())
                            .collect::<Vec<_>>()
                            .join("; ")
                    );
                }
            }
            let mut jxl = cc::Build::new();
            jxl.cpp(true)
                .file("src/native/jxl_stream_bridge.cpp")
                .include(&include)
                .define("JXL_STATIC_DEFINE", None);
            if target_os == "windows" {
                jxl.flag_if_supported("/EHsc")
                    .flag_if_supported("/std:c++17")
                    .static_crt(true);
            } else {
                jxl.flag_if_supported("-std=c++17");
            }
            let test_helpers = std::env::var("LUMIA_JXL_TEST_HELPERS").as_deref() == Ok("1");
            if test_helpers {
                jxl.define("LUMIA_JXL_TEST_HELPERS", None);
            }
            jxl.compile("lumia_jxl_stream_bridge");
            if test_helpers {
                println!("cargo:rustc-cfg=lumia_jxl_test_helpers");
            }
            for directory in &lib {
                println!("cargo:rustc-link-search=native={}", directory.display());
            }
            for name in libraries {
                println!("cargo:rustc-link-lib=static={name}");
            }
            println!("cargo:rustc-cfg=lumia_jxl");
        } else {
            println!(
                "cargo:warning=LUMIA_JXL_SDK is unset; JPEG XL export is unavailable in this build"
            );
        }
    }

    let windows = target_os == "windows";
    let android = target_os == "android";
    let ios = target_os == "ios";
    let lib_paths = std::env::var("OPENCV_LINK_PATHS")
        .ok()
        .map(|paths| std::env::split_paths(&paths).collect::<Vec<_>>())
        .unwrap_or_else(|| {
            vec![if windows {
                root.join("x64").join("vc16").join("staticlib")
            } else {
                root.join("lib")
            }]
        });
    for lib_dir in &lib_paths {
        println!("cargo:rustc-link-search=native={}", lib_dir.display());
    }
    let custom_libs = std::env::var("OPENCV_LINK_LIBS").ok();
    if ios && (custom_libs.is_none() || std::env::var_os("OPENCV_LINK_PATHS").is_none()) {
        panic!("iOS builds require explicit OPENCV_LINK_PATHS and OPENCV_LINK_LIBS for the supplied static OpenCV SDK");
    }
    if windows {
        for name in custom_libs
            .as_deref()
            .map(|s| s.split(';').collect::<Vec<_>>())
            .unwrap_or_else(|| {
                vec![
                    "opencv_stitching4130",
                    "opencv_calib3d4130",
                    "opencv_features2d4130",
                    "opencv_flann4130",
                    "opencv_imgcodecs4130",
                    "opencv_imgproc4130",
                    "opencv_core4130",
                    "opencv_photo4130",
                    "libjpeg-turbo",
                    "libopenjp2",
                    "libpng",
                    "libtiff",
                    "libwebp",
                    "zlib",
                ]
            })
        {
            println!("cargo:rustc-link-lib=static={name}");
        }
        println!("cargo:rustc-link-lib=ole32");
    } else {
        for name in custom_libs
            .as_deref()
            .map(|s| s.split(';').collect::<Vec<_>>())
            .unwrap_or_else(|| {
                vec![
                    "opencv_stitching",
                    "opencv_calib3d",
                    "opencv_features2d",
                    "opencv_flann",
                    "opencv_imgcodecs",
                    "opencv_imgproc",
                    "opencv_core",
                    "opencv_photo",
                ]
            })
        {
            if android || ios {
                if ["z", "dl", "log", "m"].contains(&name) {
                    println!("cargo:rustc-link-lib={name}");
                } else {
                    println!("cargo:rustc-link-lib=static={name}");
                }
            } else {
                println!("cargo:rustc-link-lib={name}");
            }
        }
    }
    if ios {
        println!("cargo:rustc-link-lib=dylib=c++");
        if let Ok(frameworks) = std::env::var("OPENCV_LINK_FRAMEWORKS") {
            for framework in frameworks
                .split(';')
                .map(str::trim)
                .filter(|name| !name.is_empty())
            {
                println!("cargo:rustc-link-lib=framework={framework}");
            }
        }
    }
}

fn add_windows_version_resource() {
    use std::path::PathBuf;
    use std::process::Command;

    let manifest_dir = PathBuf::from(
        std::env::var_os("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR is set by Cargo"),
    );
    let repository_root = manifest_dir
        .parent()
        .and_then(|parent| parent.parent())
        .expect("native/core must be within the repository root");
    let pubspec = repository_root.join("Apps/Flutter/stitch_app/pubspec.yaml");
    println!("cargo:rerun-if-changed={}", pubspec.display());
    let app_version = read_flutter_app_version(&pubspec);
    let version_resource = manifest_dir.join("windows/lumia_gigascan_core.rc");
    let template = std::fs::read_to_string(&version_resource)
        .unwrap_or_else(|error| panic!("cannot read {}: {error}", version_resource.display()));
    let generated = template
        .replace("@FILE_VERSION@", &app_version.file_version)
        .replace("@STRING_VERSION@", &app_version.string_version);
    if generated.contains('@') {
        panic!("unexpanded placeholder in {}", version_resource.display());
    }

    let out_dir = PathBuf::from(std::env::var_os("OUT_DIR").expect("OUT_DIR is set by Cargo"));
    let resource_input = out_dir.join("lumia_gigascan_core.version.rc");
    let resource_output = out_dir.join("lumia_gigascan_core.version.res");
    std::fs::write(&resource_input, generated)
        .unwrap_or_else(|error| panic!("cannot write {}: {error}", resource_input.display()));

    let resource_compiler = find_resource_compiler();
    let output = Command::new(&resource_compiler)
        .arg("/nologo")
        .arg("/fo")
        .arg(&resource_output)
        .arg(&resource_input)
        .output()
        .unwrap_or_else(|error| panic!("could not run {}: {error}", resource_compiler.display()));
    if !output.status.success() {
        panic!(
            "Windows resource compiler failed for {}:\n{}{}",
            resource_input.display(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
    println!("cargo:rustc-link-arg-cdylib={}", resource_output.display());
}

struct AppVersion {
    file_version: String,
    string_version: String,
}

fn read_flutter_app_version(pubspec: &std::path::Path) -> AppVersion {
    let contents = std::fs::read_to_string(pubspec)
        .unwrap_or_else(|error| panic!("cannot read {}: {error}", pubspec.display()));
    let version = contents
        .lines()
        .find_map(|line| line.trim().strip_prefix("version:").map(str::trim))
        .unwrap_or_else(|| panic!("version is missing from {}", pubspec.display()));
    let (release, build) = version.split_once('+').unwrap_or((version, "0"));
    let release_parts = release.split('.').collect::<Vec<_>>();
    if release_parts.len() != 3 {
        panic!("expected a three-part Flutter version, got '{version}'");
    }
    let mut numbers = Vec::with_capacity(4);
    for part in release_parts.into_iter().chain(std::iter::once(build)) {
        let number = part
            .parse::<u16>()
            .unwrap_or_else(|_| panic!("invalid numeric Flutter version component in '{version}'"));
        numbers.push(number);
    }
    AppVersion {
        file_version: format!(
            "{},{},{},{}",
            numbers[0], numbers[1], numbers[2], numbers[3]
        ),
        string_version: version.to_owned(),
    }
}

fn find_resource_compiler() -> std::path::PathBuf {
    use std::path::PathBuf;
    use std::process::Command;

    if let Some(sdk_dir) = std::env::var_os("WindowsSdkDir") {
        let sdk_dir = PathBuf::from(sdk_dir);
        if let Some(sdk_version) = std::env::var_os("WindowsSDKVersion") {
            let candidate = sdk_dir
                .join("bin")
                .join(
                    sdk_version
                        .to_string_lossy()
                        .trim_end_matches(|character| character == '\\' || character == '/'),
                )
                .join("x64/rc.exe");
            if candidate.is_file() {
                return candidate;
            }
        }
        let candidate = sdk_dir.join("bin/x64/rc.exe");
        if candidate.is_file() {
            return candidate;
        }
    }
    if let Ok(output) = Command::new("where.exe").arg("rc.exe").output() {
        if output.status.success() {
            if let Some(path) = String::from_utf8_lossy(&output.stdout).lines().next() {
                let candidate = PathBuf::from(path.trim());
                if candidate.is_file() {
                    return candidate;
                }
            }
        }
    }
    panic!("Windows SDK resource compiler rc.exe was not found on PATH or under WindowsSdkDir");
}
