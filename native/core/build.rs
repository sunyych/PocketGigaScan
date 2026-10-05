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
    println!("cargo:rerun-if-env-changed=LUMIA_JXL_SDK");
    println!("cargo:rerun-if-env-changed=LUMIA_JXL_TEST_HELPERS");
    let root = std::env::var("OPENCV_DIR").expect(
        "OPENCV_DIR must point to an OpenCV install (include/ and a platform library directory)",
    );
    let root = std::path::PathBuf::from(root);
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
    if cfg!(windows) {
        build.flag_if_supported("/EHsc");
        build.flag_if_supported("/std:c++17");
        build.static_crt(true);
    } else {
        build.flag_if_supported("-std=c++17");
    }
    build.compile("lumia_sift_bridge");

    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let jxl_sdk = std::env::var_os("LUMIA_JXL_SDK").map(std::path::PathBuf::from);
    if target_os == "windows" {
        if let Some(sdk) = jxl_sdk {
            let include = sdk.join("include");
            let lib = sdk.join("lib");
            for required in [
                "jxl.lib",
                "jxl_cms.lib",
                "hwy.lib",
                "brotlienc.lib",
                "brotlidec.lib",
            ] {
                if !lib.join(required).is_file() {
                    panic!("LUMIA_JXL_SDK is missing {}", lib.join(required).display());
                }
            }
            let mut jxl = cc::Build::new();
            jxl.cpp(true)
                .file("src/native/jxl_stream_bridge.cpp")
                .include(&include)
                .define("JXL_STATIC_DEFINE", None)
                .flag_if_supported("/EHsc")
                .flag_if_supported("/std:c++17")
                .static_crt(true);
            let test_helpers = std::env::var("LUMIA_JXL_TEST_HELPERS").as_deref() == Ok("1");
            if test_helpers {
                jxl.define("LUMIA_JXL_TEST_HELPERS", None);
            }
            jxl.compile("lumia_jxl_stream_bridge");
            if test_helpers {
                // Test-only native probes are excluded from normal/release builds.
                println!("cargo:rustc-cfg=lumia_jxl_test_helpers");
            }
            println!("cargo:rustc-link-search=native={}", lib.display());
            // libjxl.pc dependencies for the official static Windows package.
            for name in [
                "jxl",
                "jxl_cms",
                "hwy",
                "brotlienc",
                "brotlidec",
                "brotlicommon",
            ] {
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
                ]
            })
        {
            println!("cargo:rustc-link-lib={name}");
        }
    }
}
