//! Optional Windows CPU semantic segmentation for people protection and water smoothing.
//!
//! The runtime is loaded only on Windows and only when either semantic option is
//! enabled. Cached masks are two-channel PNGs: luminance stores person confidence
//! and the PNG alpha sample stores water confidence.
use crate::fingerprint;
use image::{imageops::FilterType, GrayAlphaImage, ImageBuffer, LumaA, RgbImage};
use serde_json::{json, Value};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
};

pub const MODEL_ID: &str =
    "openmmlab/upernet-convnext-tiny@876ffc56b819a829448f7e81e9f8606deef6fb65";
pub const ALGORITHM_VERSION: u32 = 1;
const PREPROCESSING_VERSION: u32 = 1;
const TILE: u32 = 512;
const STRIDE: u32 = 256;
static CACHE_IO: OnceLock<Mutex<()>> = OnceLock::new();

#[derive(Debug)]
pub struct SourceMask {
    pub source_path: String,
    pub width: u32,
    pub height: u32,
    pub mask_path: String,
    pub mask_sha256: String,
}

#[cfg(windows)]
mod ort {
    use std::{ffi::c_void, path::Path};
    #[link(name = "lumia_scene_bridge", kind = "static")]
    unsafe extern "C" {
        fn lumia_scene_open(
            model: *const u16,
            intra_op_threads: u32,
            session: *mut *mut c_void,
            error: *mut u16,
            error_cap: usize,
        ) -> i32;
        fn lumia_scene_infer(
            session: *mut c_void,
            input: *const f32,
            output: *mut f32,
            output_len: usize,
            error: *mut u16,
            error_cap: usize,
        ) -> i32;
        fn lumia_scene_close(session: *mut c_void);
    }
    fn wide(path: &Path) -> Vec<u16> {
        use std::os::windows::ffi::OsStrExt;
        path.as_os_str().encode_wide().chain(Some(0)).collect()
    }
    fn error_text(buffer: &[u16]) -> String {
        String::from_utf16_lossy(
            &buffer[..buffer.iter().position(|c| *c == 0).unwrap_or(buffer.len())],
        )
    }
    pub struct Session(*mut c_void);
    unsafe impl Send for Session {}
    impl Session {
        pub fn open(model: &Path, intra_op_threads: u32) -> Result<Self, String> {
            let model = wide(model);
            let mut session = std::ptr::null_mut();
            let mut error = [0u16; 1024];
            let code = unsafe {
                lumia_scene_open(
                    model.as_ptr(),
                    intra_op_threads,
                    &mut session,
                    error.as_mut_ptr(),
                    error.len(),
                )
            };
            if code != 0 {
                return Err(error_text(&error));
            }
            Ok(Self(session))
        }
        pub fn infer(&mut self, input: &[f32], output: &mut [f32]) -> Result<(), String> {
            let mut error = [0u16; 1024];
            let code = unsafe {
                lumia_scene_infer(
                    self.0,
                    input.as_ptr(),
                    output.as_mut_ptr(),
                    output.len(),
                    error.as_mut_ptr(),
                    error.len(),
                )
            };
            if code != 0 {
                return Err(error_text(&error));
            }
            Ok(())
        }
    }
    impl Drop for Session {
        fn drop(&mut self) {
            if !self.0.is_null() {
                unsafe { lumia_scene_close(self.0) }
            }
        }
    }
}

/// Validate and run analysis in source order. A completed mask is persisted
/// atomically after each source, so pause/cancel keeps useful work for resume.
pub fn analyze(
    sources: &[(PathBuf, String)],
    model_path: &Path,
    expected_model_sha256: &str,
    cache_dir: &Path,
    memory_budget_mib: usize,
    cpu_workers: usize,
    mut checkpoint: impl FnMut(usize, usize) -> bool,
) -> Result<Value, String> {
    #[cfg(not(windows))]
    {
        let _ = (
            sources,
            model_path,
            expected_model_sha256,
            cache_dir,
            memory_budget_mib,
            cpu_workers,
            &mut checkpoint,
        );
        return Err("scene semantic analysis is supported only on Windows".into());
    }
    #[cfg(windows)]
    {
        if !model_path.is_absolute() {
            return Err("sceneModelPath must be absolute".into());
        }
        let model = model_path
            .canonicalize()
            .map_err(|e| format!("scene model path is invalid: {e}"))?;
        let actual_model_sha =
            fingerprint::sha256_file(&model).map_err(|e| format!("read scene model: {e}"))?;
        if actual_model_sha != expected_model_sha256 {
            return Err(format!("scene model SHA-256 mismatch (expected {expected_model_sha256}, got {actual_model_sha})"));
        }
        if !cache_dir.is_absolute() {
            return Err("sceneCacheDir must be absolute".into());
        }
        fs::create_dir_all(cache_dir).map_err(|e| format!("create scene mask cache: {e}"))?;
        let cache_dir = cache_dir
            .canonicalize()
            .map_err(|e| format!("resolve scene mask cache: {e}"))?;
        let model_bytes = fs::metadata(&model)
            .map_err(|e| format!("read scene model metadata: {e}"))?
            .len();
        let budget = (memory_budget_mib as u64).saturating_mul(1024 * 1024);
        // Native profiling of the pinned CPU graph reached ~1.24 GiB for a
        // 3888x2592 source. Reserve two model copies plus a 1 GiB ORT workspace
        // allowance; this is a conservative estimate, not an OS hard limit.
        let runtime_reserve = model_bytes
            .saturating_mul(2)
            .saturating_add(1024 * 1024 * 1024);
        for (source, _) in sources {
            let (width, height) = image::image_dimensions(source)
                .map_err(|e| format!("read scene source dimensions {}: {e}", source.display()))?;
            let pixels = (width as u64)
                .checked_mul(height as u64)
                .ok_or("source dimensions overflow")?;
            let estimate = pixels
                .checked_mul(7)
                .and_then(|v| v.checked_add(runtime_reserve))
                .ok_or("scene analysis memory estimate overflow")?;
            if estimate > budget {
                return Err(format!("scene analysis needs approximately {} MiB for {}x{} source, model and ONNX Runtime workspace, above the {} MiB job budget",estimate.div_ceil(1024*1024),width,height,memory_budget_mib));
            }
        }
        let progress_total = sources.len().saturating_mul(1_000_000);
        if !checkpoint(0, progress_total) {
            return Err("cancelled".into());
        }
        let cpu_workers = cpu_workers.clamp(1, 8);
        let mut session = ort::Session::open(&model, cpu_workers as u32)
            .map_err(|e| format!("ONNX Runtime scene model initialization failed: {e}"))?;
        let mut masks = Vec::with_capacity(sources.len());
        for (index, (source_path, source_sha)) in sources.iter().enumerate() {
            let source_progress = index.saturating_mul(1_000_000);
            if !checkpoint(source_progress, progress_total) {
                return Err("cancelled".into());
            }
            let key = scene_cache_key(source_sha, &actual_model_sha);
            let destination = cache_dir.join(format!("{key}.png"));
            let metadata_path = destination.with_extension("json");
            let cached = {
                let _cache_guard = CACHE_IO
                    .get_or_init(|| Mutex::new(()))
                    .lock()
                    .unwrap_or_else(|e| e.into_inner());
                if destination.exists() || metadata_path.exists() {
                    Some(validate_cached_mask(
                        &destination,
                        &metadata_path,
                        &key,
                        source_path,
                        source_sha,
                        &actual_model_sha,
                    )?)
                } else {
                    None
                }
            };
            if let Some(mask) = cached {
                masks.push(mask);
                if !checkpoint(
                    index.saturating_add(1).saturating_mul(1_000_000),
                    progress_total,
                ) {
                    return Err("cancelled".into());
                }
                continue;
            }
            let rgb = image::open(source_path)
                .map_err(|e| format!("decode scene source {}: {e}", source_path.display()))?
                .into_rgb8();
            let (width, height) = rgb.dimensions();
            let mut person = vec![
                0u8;
                (width as usize)
                    .checked_mul(height as usize)
                    .ok_or("source dimensions overflow")?
            ];
            let mut water = vec![0u8; person.len()];
            let starts = |extent: u32| -> Vec<u32> {
                if extent <= TILE {
                    vec![0]
                } else {
                    let mut v = Vec::new();
                    let mut s = 0;
                    while s + TILE < extent {
                        v.push(s);
                        s = s.saturating_add(STRIDE);
                    }
                    let last = extent - TILE;
                    if v.last().copied() != Some(last) {
                        v.push(last);
                    }
                    v
                }
            };
            let xs = starts(width);
            let ys = starts(height);
            let total = xs.len() * ys.len();
            let mut done: usize = 0;
            let mut input = vec![0f32; 3 * TILE as usize * TILE as usize];
            let mut output = vec![0f32; 2 * TILE as usize * TILE as usize];
            // A context pass preserves full-scene recognition for people and
            // broad water regions; detailed overlapping crops still supply
            // original-scale edges and small objects below.
            let scale = (TILE as f64 / width as f64).min(TILE as f64 / height as f64);
            let coarse_width = ((width as f64 * scale).round() as u32).clamp(1, TILE);
            let coarse_height = ((height as f64 * scale).round() as u32).clamp(1, TILE);
            let coarse =
                image::imageops::resize(&rgb, coarse_width, coarse_height, FilterType::Triangle);
            let offset_x = (TILE - coarse_width) / 2;
            let offset_y = (TILE - coarse_height) / 2;
            let coarse_tile: RgbImage = ImageBuffer::from_fn(TILE, TILE, |x, y| {
                *coarse.get_pixel(
                    x.saturating_sub(offset_x).min(coarse_width - 1),
                    y.saturating_sub(offset_y).min(coarse_height - 1),
                )
            });
            normalize_rgb_tile(&coarse_tile, &mut input);
            session.infer(&input, &mut output).map_err(|e| {
                format!(
                    "scene context inference failed for {}: {e}",
                    source_path.display()
                )
            })?;
            let coarse_mask: GrayAlphaImage =
                ImageBuffer::from_fn(coarse_width, coarse_height, |x, y| {
                    let i = (y + offset_y) as usize * TILE as usize + (x + offset_x) as usize;
                    LumaA([
                        (output[i].clamp(0.0, 1.0) * 255.0).round() as u8,
                        (output[TILE as usize * TILE as usize + i].clamp(0.0, 1.0) * 255.0).round()
                            as u8,
                    ])
                });
            let coarse_full =
                image::imageops::resize(&coarse_mask, width, height, FilterType::Triangle);
            for (i, pixel) in coarse_full.pixels().enumerate() {
                person[i] = person[i].max(pixel.0[0]);
                water[i] = water[i].max(pixel.0[1]);
            }
            for &top in &ys {
                for &left in &xs {
                    if !checkpoint(source_progress, progress_total) {
                        return Err("cancelled".into());
                    }
                    let crop_w = (width - left).min(TILE);
                    let crop_h = (height - top).min(TILE);
                    let tile: RgbImage = ImageBuffer::from_fn(TILE, TILE, |x, y| {
                        *rgb.get_pixel((left + x).min(width - 1), (top + y).min(height - 1))
                    });
                    normalize_rgb_tile(&tile, &mut input);
                    session.infer(&input, &mut output).map_err(|e| {
                        format!("scene inference failed for {}: {e}", source_path.display())
                    })?;
                    for y in 0..crop_h as usize {
                        for x in 0..crop_w as usize {
                            let i = y * TILE as usize + x;
                            let target = (top as usize + y) * width as usize + left as usize + x;
                            let edge = edge_confidence_weight(x as u32, TILE, left, width)
                                .min(edge_confidence_weight(y as u32, TILE, top, height));
                            person[target] = person[target]
                                .max((output[i].clamp(0.0, 1.0) * edge * 255.0).round() as u8);
                            water[target] = water[target].max(
                                (output[TILE as usize * TILE as usize + i].clamp(0.0, 1.0)
                                    * edge
                                    * 255.0)
                                    .round() as u8,
                            );
                        }
                    }
                    done += 1;
                    let within_source = done.saturating_mul(1_000_000) / total.max(1);
                    if !checkpoint(
                        source_progress.saturating_add(within_source),
                        progress_total,
                    ) {
                        return Err("cancelled".into());
                    }
                }
            }
            let mut mask: GrayAlphaImage = ImageBuffer::new(width, height);
            for (i, pixel) in mask.pixels_mut().enumerate() {
                *pixel = LumaA([person[i], water[i]]);
            }
            let nonce = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos();
            let temp = unique_temp_path(&destination, nonce);
            mask.save_with_format(&temp, image::ImageFormat::Png)
                .map_err(|e| format!("write scene mask {}: {e}", temp.display()))?;
            let metadata_temp = unique_temp_path(&metadata_path, nonce);
            let published = {
                let _cache_guard = CACHE_IO
                    .get_or_init(|| Mutex::new(()))
                    .lock()
                    .unwrap_or_else(|e| e.into_inner());
                if destination.exists() || metadata_path.exists() {
                    let existing = validate_cached_mask(
                        &destination,
                        &metadata_path,
                        &key,
                        source_path,
                        source_sha,
                        &actual_model_sha,
                    );
                    let _ = fs::remove_file(&temp);
                    let _ = fs::remove_file(&metadata_temp);
                    existing?
                } else {
                    let mask_sha = fingerprint::sha256_file(&temp).map_err(|e| e.to_string())?;
                    let record = json!({"schemaVersion":1,"key":key,"sourceSha256":source_sha,"modelSha256":actual_model_sha,"preprocessingVersion":PREPROCESSING_VERSION,"algorithmVersion":ALGORITHM_VERSION,"width":width,"height":height,"maskSha256":mask_sha});
                    write_scene_metadata(&metadata_temp, &record).map_err(|e| {
                        format!("write scene mask metadata {}: {e}", metadata_temp.display())
                    })?;
                    fs::rename(&temp, &destination).map_err(|e| {
                        format!("publish scene mask {}: {e}", destination.display())
                    })?;
                    fs::rename(&metadata_temp, &metadata_path).map_err(|e| {
                        format!(
                            "publish scene mask metadata {}: {e}",
                            metadata_path.display()
                        )
                    })?;
                    SourceMask {
                        source_path: source_path.to_string_lossy().into_owned(),
                        width,
                        height,
                        mask_path: destination.to_string_lossy().into_owned(),
                        mask_sha256: mask_sha,
                    }
                }
            };
            masks.push(published);
            if !checkpoint(
                index.saturating_add(1).saturating_mul(1_000_000),
                progress_total,
            ) {
                return Err("cancelled".into());
            }
        }
        Ok(
            json!({"schemaVersion":1,"algorithmVersion":ALGORITHM_VERSION,"modelId":MODEL_ID,"modelSha256":actual_model_sha,"sources":masks.into_iter().map(|m|json!({"path":m.source_path,"width":m.width,"height":m.height,"maskPath":m.mask_path,"maskSha256":m.mask_sha256})).collect::<Vec<_>>()}),
        )
    }
}

fn normalize_rgb_tile(tile: &RgbImage, input: &mut [f32]) {
    let plane = TILE as usize * TILE as usize;
    for y in 0..TILE as usize {
        for x in 0..TILE as usize {
            let p = tile.get_pixel(x as u32, y as u32).0;
            let i = y * TILE as usize + x;
            input[i] = (p[0] as f32 / 255.0 - 0.485) / 0.229;
            input[plane + i] = (p[1] as f32 / 255.0 - 0.456) / 0.224;
            input[2 * plane + i] = (p[2] as f32 / 255.0 - 0.406) / 0.225;
        }
    }
}
fn edge_confidence_weight(local: u32, tile: u32, start: u32, source_extent: u32) -> f32 {
    if source_extent <= tile
        || (start == 0 && local < 64)
        || (start.saturating_add(tile) >= source_extent && local >= tile.saturating_sub(64))
    {
        return 1.0;
    }
    let edge = local.min(TILE - 1 - local);
    if edge >= 64 {
        1.0
    } else {
        0.35 + 0.65 * edge as f32 / 64.0
    }
}

fn unique_temp_path(path: &Path, nonce: u128) -> PathBuf {
    let name = path
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("scene-mask");
    path.with_file_name(format!("{name}.{}.{}.tmp", std::process::id(), nonce))
}
fn write_scene_metadata(path: &Path, value: &Value) -> std::io::Result<()> {
    use std::io::Write;
    let mut file = fs::File::create(path)?;
    file.write_all(&serde_json::to_vec_pretty(value).map_err(std::io::Error::other)?)?;
    file.sync_all()
}
fn validate_cached_mask(
    path: &Path,
    metadata_path: &Path,
    key: &str,
    source: &Path,
    source_sha: &str,
    model_sha: &str,
) -> Result<SourceMask, String> {
    let record: Value = serde_json::from_slice(&fs::read(metadata_path).map_err(|e| {
        format!(
            "scene mask cache metadata is missing or unreadable {}: {e}",
            metadata_path.display()
        )
    })?)
    .map_err(|e| {
        format!(
            "scene mask cache metadata is corrupt {}: {e}",
            metadata_path.display()
        )
    })?;
    if record["schemaVersion"].as_u64() != Some(1)
        || record["key"].as_str() != Some(key)
        || record["sourceSha256"].as_str() != Some(source_sha)
        || record["modelSha256"].as_str() != Some(model_sha)
        || record["preprocessingVersion"].as_u64() != Some(PREPROCESSING_VERSION as u64)
        || record["algorithmVersion"].as_u64() != Some(ALGORITHM_VERSION as u64)
    {
        return Err(format!(
            "scene mask cache identity mismatch: {}",
            metadata_path.display()
        ));
    }
    let actual = fingerprint::sha256_file(path)
        .map_err(|e| format!("scene mask cache is unreadable {}: {e}", path.display()))?;
    if record["maskSha256"].as_str() != Some(actual.as_str()) {
        return Err(format!(
            "scene mask cache hash mismatch: {}",
            path.display()
        ));
    }
    let decoded = image::open(path)
        .map_err(|e| format!("scene mask cache is corrupt {}: {e}", path.display()))?;
    if decoded.color() != image::ColorType::La8 {
        return Err(format!(
            "scene mask cache is not two-channel LumaA8: {}",
            path.display()
        ));
    }
    let image = decoded.into_luma_alpha8();
    let (width, height) = image.dimensions();
    let expected = image::image_dimensions(source)
        .map_err(|e| format!("read source dimensions {}: {e}", source.display()))?;
    if (width, height) != expected
        || record["width"].as_u64() != Some(width as u64)
        || record["height"].as_u64() != Some(height as u64)
        || actual.is_empty()
    {
        return Err(format!("scene mask cache dimensions mismatch for {}: expected {}x{}, got {}x{} (source {source_sha}, model {model_sha})",path.display(),expected.0,expected.1,width,height));
    }
    Ok(SourceMask {
        source_path: source.to_string_lossy().into_owned(),
        width,
        height,
        mask_path: path.to_string_lossy().into_owned(),
        mask_sha256: actual,
    })
}

/// Check every manifest mask before accepting a completed job during recovery.
pub fn validate_manifest(
    value: &Value,
    model_path: &Path,
    expected_model_sha: &str,
    expected_sources: &[(PathBuf, String)],
) -> Result<(), String> {
    if value["schemaVersion"].as_u64() != Some(1)
        || value["algorithmVersion"].as_u64() != Some(ALGORITHM_VERSION as u64)
        || value["modelSha256"].as_str() != Some(expected_model_sha)
    {
        return Err("scene analysis manifest identity mismatch".into());
    }
    if fingerprint::sha256_file(model_path)
        .map_err(|e| format!("scene model is missing or unreadable: {e}"))?
        != expected_model_sha
    {
        return Err("scene model SHA-256 mismatch while validating completed manifest".into());
    }
    let sources = value["sources"]
        .as_array()
        .ok_or("scene analysis manifest sources are missing")?;
    if sources.len() != expected_sources.len() {
        return Err("scene analysis manifest source count mismatch".into());
    }
    for (index, source) in sources.iter().enumerate() {
        let (expected_path, expected_hash) = &expected_sources[index];
        if source["path"].as_str() != Some(expected_path.to_string_lossy().as_ref()) {
            return Err(format!(
                "scene analysis source path mismatch at index {index}"
            ));
        }
        let expected_dims = image::image_dimensions(expected_path).map_err(|e| {
            format!(
                "read scene source dimensions {}: {e}",
                expected_path.display()
            )
        })?;
        if fingerprint::sha256_file(expected_path).map_err(|e| e.to_string())? != *expected_hash {
            return Err(format!(
                "scene source hash mismatch: {}",
                expected_path.display()
            ));
        }
        let path = Path::new(
            source["maskPath"]
                .as_str()
                .ok_or("scene mask path is missing")?,
        );
        let key = scene_cache_key(expected_hash, expected_model_sha);
        let mask = validate_cached_mask(
            path,
            &path.with_extension("json"),
            &key,
            expected_path,
            expected_hash,
            expected_model_sha,
        )?;
        if source["maskSha256"].as_str() != Some(mask.mask_sha256.as_str())
            || mask.width != expected_dims.0
            || mask.height != expected_dims.1
            || source["width"].as_u64() != Some(mask.width as u64)
            || source["height"].as_u64() != Some(mask.height as u64)
        {
            return Err(format!(
                "scene mask dimensions or hash metadata mismatch: {}",
                path.display()
            ));
        }
    }
    Ok(())
}

fn scene_cache_key(source_sha: &str, model_sha: &str) -> String {
    let bytes=serde_json::to_vec(&json!({"sourceSha256":source_sha,"modelSha256":model_sha,"preprocessingVersion":PREPROCESSING_VERSION,"algorithmVersion":ALGORITHM_VERSION})).unwrap_or_default();
    fingerprint::sha256_bytes(&bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn detail_window_edges_keep_real_image_boundaries_and_fade_internal_seams() {
        assert_eq!(edge_confidence_weight(0, TILE, 0, 1024), 1.0);
        assert_eq!(edge_confidence_weight(511, TILE, 512, 1024), 1.0);
        assert!(edge_confidence_weight(0, TILE, 256, 1024) < 1.0);
        assert_eq!(edge_confidence_weight(256, TILE, 256, 1024), 1.0);
    }
    #[test]
    fn scene_cache_key_changes_with_source_or_model_identity() {
        let key = scene_cache_key("a", "m");
        assert_ne!(key, scene_cache_key("b", "m"));
        assert_ne!(key, scene_cache_key("a", "n"));
    }
    #[test]
    fn cache_sidecar_rejects_same_size_mask_tampering() {
        let dir =
            std::env::temp_dir().join(format!("scene-mask-cache-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let source = dir.join("source.png");
        let mask_path = dir.join("mask.png");
        let meta_path = dir.join("mask.json");
        image::GrayImage::from_pixel(2, 2, image::Luma([40]))
            .save(&source)
            .unwrap();
        let source_sha = fingerprint::sha256_file(&source).unwrap();
        let model_sha = "a".repeat(64);
        let key = scene_cache_key(&source_sha, &model_sha);
        let mut mask = GrayAlphaImage::new(2, 2);
        for pixel in mask.pixels_mut() {
            *pixel = LumaA([120, 0]);
        }
        mask.save(&mask_path).unwrap();
        let mask_sha = fingerprint::sha256_file(&mask_path).unwrap();
        let metadata = json!({"schemaVersion":1,"key":key,"sourceSha256":source_sha,"modelSha256":model_sha,"preprocessingVersion":PREPROCESSING_VERSION,"algorithmVersion":ALGORITHM_VERSION,"width":2,"height":2,"maskSha256":mask_sha});
        fs::write(&meta_path, serde_json::to_vec(&metadata).unwrap()).unwrap();
        assert!(validate_cached_mask(
            &mask_path,
            &meta_path,
            &key,
            &source,
            &source_sha,
            &model_sha
        )
        .is_ok());
        let mut altered = GrayAlphaImage::new(2, 2);
        for pixel in altered.pixels_mut() {
            *pixel = LumaA([121, 0]);
        }
        altered.save(&mask_path).unwrap();
        assert!(validate_cached_mask(
            &mask_path,
            &meta_path,
            &key,
            &source,
            &source_sha,
            &model_sha
        )
        .unwrap_err()
        .contains("hash mismatch"));
        let _ = fs::remove_dir_all(dir);
    }
    #[cfg(windows)]
    #[test]
    fn cancellation_before_runtime_initialization_is_cooperative() {
        let dir = std::env::temp_dir().join(format!("scene-cancel-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let source = dir.join("source.png");
        image::GrayImage::from_pixel(2, 2, image::Luma([40]))
            .save(&source)
            .unwrap();
        let model = dir.join("model.onnx");
        fs::write(&model, b"test model").unwrap();
        let model_sha = fingerprint::sha256_file(&model).unwrap();
        let source_sha = fingerprint::sha256_file(&source).unwrap();
        let result = analyze(
            &[(source, source_sha)],
            &model,
            &model_sha,
            &dir.join("cache"),
            2048,
            1,
            |_, _| false,
        );
        assert_eq!(result.unwrap_err(), "cancelled");
        let _ = fs::remove_dir_all(dir);
    }
    #[cfg(not(windows))]
    #[test]
    fn non_windows_analysis_is_explicitly_unsupported() {
        let result = analyze(
            &[],
            Path::new("model.onnx"),
            "sha",
            Path::new("cache"),
            512,
            1,
            |_, _| true,
        );
        assert!(result.unwrap_err().contains("supported only on Windows"));
    }
}
