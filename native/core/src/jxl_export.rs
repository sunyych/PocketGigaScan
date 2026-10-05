//! Lossless JPEG XL export using libjxl's chunked-frame API.
//!
//! Pixels are assembled one row at a time to a private raw RGBA spool on disk.
//! The C++ bridge serves bounded 2064x2064 chunks from that 64-bit-offset spool
//! (libjxl 0.12.0 has requested 2056x2056 despite documenting 2048x2048) and
//! streams encoder output through a fixed-size seekable buffer.
use crate::{spherical_export, Error, Result};
use serde_json::{json, Value};
use std::{
    fs::{self, OpenOptions},
    io::{BufWriter, Read, Write},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

const MAX_PIXELS: u64 = 4_000_000_000;
// libjxl 0.12.0 requested a 2056x2056 rect for large images despite its
// documented 2048 cap; the bridge bounds dimensions to the next 8-pixel step.
const MAX_JXL_CALLBACK_BYTES: u64 = 2064 * 2064 * 3;
const MAX_JXL_ACTIVE_CHUNK_BYTES: u64 = 64 * 1024 * 1024;
const JXL_FALLBACK_BUFFER_BYTES: u64 = 2064 * 2064 * 4;
const CALLBACK_ERROR_BYTES: usize = 512;

struct TempDir(PathBuf);
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn invalid(message: impl Into<String>) -> Error {
    Error::Invalid(message.into())
}

#[cfg(lumia_jxl)]
type NativeCheckpoint = unsafe extern "C" fn(*mut std::ffi::c_void) -> i32;

#[cfg(lumia_jxl)]
unsafe extern "C" {
    fn lumia_jxl_encode_rgba_spool(
        input_path: *const u16,
        output_path: *const u16,
        width: u32,
        height: u32,
        memory_budget_mib: u64,
        checkpoint: Option<NativeCheckpoint>,
        checkpoint_opaque: *mut std::ffi::c_void,
        error_message: *mut u8,
        error_capacity: usize,
        peak_chunk_bytes: *mut u64,
    ) -> i32;
}

#[cfg(lumia_jxl)]
struct CheckpointContext<'a> {
    callback: &'a mut dyn FnMut(u32, u32) -> Result<()>,
    cancelled: bool,
    panicked: bool,
}

#[cfg(lumia_jxl)]
unsafe extern "C" fn rust_checkpoint(opaque: *mut std::ffi::c_void) -> i32 {
    let context = &mut *opaque.cast::<CheckpointContext<'_>>();
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| (context.callback)(0, 1))) {
        Ok(Ok(())) => 1,
        Ok(Err(_)) => {
            context.cancelled = true;
            0
        }
        Err(_) => {
            context.panicked = true;
            0
        }
    }
}

#[cfg(lumia_jxl)]
fn native_encode(
    input: &Path,
    output: &Path,
    width: u32,
    height: u32,
    memory_budget_mib: usize,
    checkpoint: &mut dyn FnMut(u32, u32) -> Result<()>,
) -> Result<u64> {
    use std::{ffi::c_void, os::windows::ffi::OsStrExt};
    let input: Vec<u16> = input.as_os_str().encode_wide().chain([0]).collect();
    let output: Vec<u16> = output.as_os_str().encode_wide().chain([0]).collect();
    let mut context = CheckpointContext {
        callback: checkpoint,
        cancelled: false,
        panicked: false,
    };
    let mut error = [0u8; CALLBACK_ERROR_BYTES];
    let mut peak_chunk_bytes = 0;
    let status = unsafe {
        lumia_jxl_encode_rgba_spool(
            input.as_ptr(),
            output.as_ptr(),
            width,
            height,
            memory_budget_mib as u64,
            Some(rust_checkpoint),
            (&mut context as *mut CheckpointContext<'_>).cast::<c_void>(),
            error.as_mut_ptr(),
            error.len(),
            &mut peak_chunk_bytes,
        )
    };
    if context.cancelled {
        return Err(Error::Cancelled);
    }
    if context.panicked {
        return Err(invalid("panic contained at the JPEG XL callback boundary"));
    }
    if status != 0 {
        let end = error
            .iter()
            .position(|byte| *byte == 0)
            .unwrap_or(error.len());
        let detail = String::from_utf8_lossy(&error[..end]);
        return Err(invalid(if detail.is_empty() {
            format!("libjxl chunked encoder failed with status {status}")
        } else {
            format!("libjxl chunked encoder failed: {detail}")
        }));
    }
    Ok(peak_chunk_bytes)
}

#[cfg(not(lumia_jxl))]
fn native_encode(
    _input: &Path,
    _output: &Path,
    _width: u32,
    _height: u32,
    _memory_budget_mib: usize,
    _checkpoint: &mut dyn FnMut(u32, u32) -> Result<()>,
) -> Result<u64> {
    Err(invalid(
        "CAPABILITY_UNAVAILABLE: this core was built without the official libjxl 0.12.0 SDK",
    ))
}

#[cfg(lumia_jxl)]
pub(crate) fn available() -> bool {
    true
}

#[cfg(not(lumia_jxl))]
pub(crate) fn available() -> bool {
    false
}

fn make_private_dir(parent: &Path, destination: &Path) -> Result<TempDir> {
    let name = destination
        .file_name()
        .ok_or_else(|| invalid("JPEG XL destination filename is empty"))?
        .to_string_lossy();
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos());
    for attempt in 0..16u8 {
        let path = parent.join(format!(
            ".{name}.jxl-{}-{nonce}-{attempt}.tmpdir",
            std::process::id()
        ));
        match fs::create_dir(&path) {
            Ok(()) => return Ok(TempDir(path)),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.into()),
        }
    }
    Err(invalid(
        "could not allocate a private JPEG XL temporary directory",
    ))
}

pub(crate) fn export_level0_jxl(
    job_dir: &Path,
    manifest: &Value,
    destination: &Path,
    memory_budget_mib: usize,
    encoder_threads: usize,
    spool_checkpoint: &mut dyn FnMut(u32, u32) -> Result<()>,
    encode_checkpoint: &mut dyn FnMut(u32, u32) -> Result<()>,
    begin_commit: &mut dyn FnMut() -> Result<()>,
) -> Result<Value> {
    if !(16..=4096).contains(&memory_budget_mib) {
        return Err(invalid("memoryBudgetMiB must be 16..=4096"));
    }
    if !available() {
        return Err(invalid(
            "CAPABILITY_UNAVAILABLE: libjxl encoder is not linked",
        ));
    }
    let grid = spherical_export::validate_level0(job_dir, manifest, MAX_PIXELS, "JPEG XL")?;
    let raw_bytes = u64::from(grid.width)
        .checked_mul(u64::from(grid.height))
        .and_then(|pixels| pixels.checked_mul(4))
        .ok_or_else(|| invalid("JPEG XL raw spool size overflow"))?;
    let parent = destination
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)?;
    if destination.exists() {
        return Err(invalid("JPEG XL export destination already exists"));
    }
    let private = make_private_dir(parent, destination)?;
    let raw_path = private.0.join("pixels.rgba");
    let encoded_path = private.0.join("result.jxl");
    let raw_file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&raw_path)?;
    drop(raw_file);
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&encoded_path)?;
    let spool_started = std::time::Instant::now();
    let raw_file = OpenOptions::new().write(true).open(&raw_path)?;
    let mut writer = BufWriter::with_capacity(1024 * 1024, raw_file);
    let assembly = spherical_export::for_each_level0_row(
        &grid,
        &private.0,
        memory_budget_mib,
        spool_checkpoint,
        |row| writer.write_all(row).map_err(Error::Io),
    )?;
    writer.flush()?;
    writer.get_ref().sync_all()?;
    drop(writer);
    let spool_ms = spool_started.elapsed().as_millis() as u64;
    let encoder_started = std::time::Instant::now();
    let peak_chunk_bytes = native_encode(
        &raw_path,
        &encoded_path,
        grid.width,
        grid.height,
        memory_budget_mib,
        encode_checkpoint,
    )?;
    let encoder_ms = encoder_started.elapsed().as_millis() as u64;
    let mut output = OpenOptions::new()
        .read(true)
        .write(true)
        .open(&encoded_path)?;
    let mut header = [0u8; 12];
    output.read_exact(&mut header)?;
    const CONTAINER: [u8; 12] = [0, 0, 0, 12, b'J', b'X', b'L', b' ', 13, 10, 135, 10];
    if header != CONTAINER {
        return Err(invalid("libjxl produced an invalid container header"));
    }
    output.sync_all()?;
    drop(output);
    let output_bytes = fs::metadata(&encoded_path)?.len();
    begin_commit()?;
    let publication = spherical_export::publish_no_overwrite(&encoded_path, destination)?;
    Ok(json!({
        "path": destination,
        "width": grid.width,
        "height": grid.height,
        "rowsWritten": assembly.rows_written,
        "fullHeight": grid.height,
        "sourceTileDecodes": assembly.source_tile_decodes,
        "spoolBytes": assembly.peak_spool_bytes,
        "totalOccupiedTileBytes": grid.total_tile_bytes,
        "sourceDecodeMs": assembly.source_decode_ms,
        "exportFormat": "jxl",
        "compression": "lossless",
        "sampleFormat": "RGBA8",
        "alpha": "preserved-including-invisible-rgb",
        "jxlEncoder": "libjxl-c-api-0.12.0",
        "jxlEncoderSource": "statically-linked-chunked-frame",
        "jxlEncoderThreads": encoder_threads.max(1),
        "jxlEncoderMemoryModel": "chunked-input;encoder-internal-RSS-not-hard-capped-by-native-reservation",
        "jxlEncoderRssLimitEnforced": false,
        "jxlCallbackMaximumBytes": MAX_JXL_CALLBACK_BYTES,
        "jxlActiveChunkLimitBytes": MAX_JXL_ACTIVE_CHUNK_BYTES,
        "jxlChunkBytesPeakObserved": peak_chunk_bytes,
        "jxlFallbackBufferBytes": JXL_FALLBACK_BUFFER_BYTES,
        "jxlRawIntermediateBytes": raw_bytes,
        "jxlOutputBytes": output_bytes,
        "jxlSpoolMs": spool_ms,
        "jxlEncodeMs": encoder_ms,
        "memoryBudgetMiB": memory_budget_mib,
        "peakWorkingBytesEstimate": assembly
            .peak_working_bytes
            .saturating_add(peak_chunk_bytes)
            .saturating_add(JXL_FALLBACK_BUFFER_BYTES),
        "publication": publication
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{Rgba, RgbaImage};
    use serde_json::json;

    #[cfg(all(lumia_jxl, lumia_jxl_test_helpers))]
    unsafe extern "C" {
        fn lumia_jxl_test_chunk_budget_probe(
            peak_bytes: *mut u64,
            remaining_bytes: *mut u64,
        ) -> i32;
        fn lumia_jxl_test_read_rgba_pixel(
            input_path: *const u16,
            width: u32,
            height: u32,
            x: u32,
            y: u32,
            rgba: *mut u8,
        ) -> i32;
    }

    #[cfg(all(lumia_jxl, lumia_jxl_test_helpers))]
    #[test]
    fn native_chunk_allocator_enforces_aggregate_limit_and_releases_burst() {
        let mut peak = 0;
        let mut remaining = u64::MAX;
        let result = unsafe { lumia_jxl_test_chunk_budget_probe(&mut peak, &mut remaining) };
        assert_eq!(result, 0);
        assert_eq!(remaining, 0);
        assert!(peak <= MAX_JXL_ACTIVE_CHUNK_BYTES);
        assert!(peak > MAX_JXL_ACTIVE_CHUNK_BYTES - MAX_JXL_CALLBACK_BYTES);
    }

    #[cfg(all(lumia_jxl, lumia_jxl_test_helpers))]
    #[test]
    fn native_chunk_reader_seeks_sparse_rgba_spool_past_four_gib() {
        use std::ffi::c_void;
        use std::io::{Seek, SeekFrom};
        use std::os::windows::{ffi::OsStrExt, io::AsRawHandle};

        #[link(name = "kernel32")]
        unsafe extern "system" {
            #[link_name = "DeviceIoControl"]
            fn device_io_control(
                device: *mut c_void,
                control_code: u32,
                input: *mut c_void,
                input_size: u32,
                output: *mut c_void,
                output_size: u32,
                returned: *mut u32,
                overlapped: *mut c_void,
            ) -> i32;
        }

        let width = 65_536u32;
        let height = 16_385u32;
        let x = 7u32;
        let y = 16_384u32;
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "lgs-jxl-sparse-{}-{nonce}.rgba",
            std::process::id()
        ));
        let offset = (u64::from(y) * u64::from(width) + u64::from(x)) * 4;
        assert!(offset > u64::from(u32::MAX));
        let mut file = fs::File::create(&path).unwrap();
        let sparse = unsafe {
            device_io_control(
                file.as_raw_handle(),
                0x0009_00C4, // FSCTL_SET_SPARSE
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        assert_ne!(
            sparse, 0,
            "test spool must be sparse to avoid a 4 GiB allocation"
        );
        file.set_len(u64::from(width) * u64::from(height) * 4)
            .unwrap();
        file.seek(SeekFrom::Start(offset)).unwrap();
        file.write_all(&[19, 73, 211, 127]).unwrap();
        file.sync_all().unwrap();
        drop(file);

        let wide: Vec<u16> = path.as_os_str().encode_wide().chain([0]).collect();
        let mut actual = [0u8; 4];
        let result = unsafe {
            lumia_jxl_test_read_rgba_pixel(wide.as_ptr(), width, height, x, y, actual.as_mut_ptr())
        };
        assert_eq!(result, 0);
        assert_eq!(actual, [19, 73, 211, 127]);
        fs::remove_file(path).unwrap();
    }

    #[cfg(lumia_jxl)]
    fn fixture(label: &str, width: u32, height: u32) -> (PathBuf, Value) {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root =
            std::env::temp_dir().join(format!("lgs-jxl-{label}-{}-{nonce}", std::process::id()));
        fs::create_dir_all(root.join("level-0")).unwrap();
        let image = RgbaImage::from_fn(width, height, |x, y| match (x % 3, y % 3) {
            (0, 0) => Rgba([91, 29, 207, 0]),
            (1, 1) => Rgba([15, 160, 250, 127]),
            _ => Rgba([(x & 255) as u8, (y & 255) as u8, 83, 255]),
        });
        image.save(root.join("level-0/0-0.png")).unwrap();
        let manifest = json!({
            "width": width,
            "height": height,
            "tileSize": 512,
            "levels": [{"level": 0, "occupied": [{
                "row": 0, "column": 0, "path": "level-0/0-0.png",
                "width": width, "height": height
            }]}]
        });
        (root, manifest)
    }

    #[test]
    fn jxl_capability_is_explicitly_reported_for_this_build() {
        assert_eq!(available(), cfg!(lumia_jxl));
    }

    #[cfg(not(lumia_jxl))]
    #[test]
    fn missing_static_encoder_fails_closed() {
        assert!(native_encode(
            Path::new("unused"),
            Path::new("unused"),
            1,
            1,
            128,
            &mut |_, _| Ok(())
        )
        .unwrap_err()
        .to_string()
        .contains("CAPABILITY_UNAVAILABLE"));
    }

    #[cfg(lumia_jxl)]
    #[test]
    fn chunked_jxl_export_preserves_container_and_handles_unicode_paths() {
        let (root, manifest) = fixture("unicode", 48, 24);
        let output_dir = root.join("照片 输出");
        fs::create_dir_all(&output_dir).unwrap();
        let destination = output_dir.join("拼接结果.jxl");
        let mut encode_checkpoints = 0usize;
        let mut committed = false;
        let stats = export_level0_jxl(
            &root,
            &manifest,
            &destination,
            128,
            1,
            &mut |_, _| Ok(()),
            &mut |_, _| {
                encode_checkpoints += 1;
                Ok(())
            },
            &mut || {
                committed = true;
                Ok(())
            },
        )
        .unwrap();
        assert!(committed);
        assert!(
            encode_checkpoints > 0,
            "encoding runner must be checkpointed"
        );
        assert_eq!(stats["exportFormat"], "jxl");
        assert_eq!(stats["sampleFormat"], "RGBA8");
        assert_eq!(stats["jxlEncoderThreads"], 1);
        assert!(stats["jxlChunkBytesPeakObserved"].as_u64().unwrap() > 0);
        assert_eq!(
            fs::metadata(&destination).unwrap().len(),
            stats["jxlOutputBytes"]
        );
        let mut file = fs::File::open(&destination).unwrap();
        let mut header = [0u8; 12];
        file.read_exact(&mut header).unwrap();
        assert_eq!(
            header,
            [0, 0, 0, 12, b'J', b'X', b'L', b' ', 13, 10, 135, 10]
        );
        if let Some(djxl) = std::env::var_os("LUMIA_DJXL_PATH") {
            let decoded = output_dir.join("independent-decode.png");
            let status = std::process::Command::new(djxl)
                .arg(&destination)
                .arg(&decoded)
                .status()
                .unwrap();
            assert!(status.success());
            let expected = image::open(root.join("level-0/0-0.png"))
                .unwrap()
                .into_rgba8();
            let actual = image::open(decoded).unwrap().into_rgba8();
            assert_eq!(
                actual, expected,
                "JXL roundtrip must preserve every RGBA sample"
            );
        }
        assert!(fs::read_dir(&output_dir).unwrap().all(|entry| !entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .contains("tmpdir")));
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(lumia_jxl)]
    #[test]
    fn large_chunked_jxl_roundtrip_handles_2056_rectangles_and_tile_boundaries() {
        let width = 2057u32;
        let height = 2065u32;
        let tile_size = 512u32;
        let columns = width.div_ceil(tile_size);
        let rows = height.div_ceil(tile_size);
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root =
            std::env::temp_dir().join(format!("lgs-jxl-large-{}-{nonce}", std::process::id()));
        fs::create_dir_all(root.join("level-0")).unwrap();
        let mut expected = RgbaImage::new(width, height);
        let mut occupied = Vec::new();
        for row in 0..rows {
            for column in 0..columns {
                let x0 = column * tile_size;
                let y0 = row * tile_size;
                let tile_width = (width - x0).min(tile_size);
                let tile_height = (height - y0).min(tile_size);
                let tile = RgbaImage::from_fn(tile_width, tile_height, |x, y| {
                    let global_x = x0 + x;
                    let global_y = y0 + y;
                    let alpha = match (global_x + global_y) % 3 {
                        0 => 0,
                        1 => 127,
                        _ => 255,
                    };
                    Rgba([
                        (global_x.wrapping_mul(13) & 255) as u8,
                        (global_y.wrapping_mul(29) & 255) as u8,
                        (global_x.wrapping_add(global_y * 7) & 255) as u8,
                        alpha,
                    ])
                });
                for (x, y, pixel) in tile.enumerate_pixels() {
                    expected.put_pixel(x0 + x, y0 + y, *pixel);
                }
                let path = format!("level-0/{row}-{column}.png");
                tile.save(root.join(&path)).unwrap();
                occupied.push(json!({
                    "row": row,
                    "column": column,
                    "path": path,
                    "width": tile_width,
                    "height": tile_height
                }));
            }
        }
        let expected_path = root.join("expected.png");
        expected.save(&expected_path).unwrap();
        let manifest = json!({
            "width": width,
            "height": height,
            "tileSize": tile_size,
            "levels": [{"level": 0, "occupied": occupied}]
        });
        let destination = root.join("large.jxl");
        let stats = export_level0_jxl(
            &root,
            &manifest,
            &destination,
            128,
            1,
            &mut |_, _| Ok(()),
            &mut |_, _| Ok(()),
            &mut || Ok(()),
        )
        .unwrap();
        assert_eq!(stats["width"], width);
        assert_eq!(stats["height"], height);
        assert!(stats["jxlChunkBytesPeakObserved"].as_u64().unwrap() <= MAX_JXL_ACTIVE_CHUNK_BYTES);
        if let Some(djxl) = std::env::var_os("LUMIA_DJXL_PATH") {
            let decoded = root.join("decoded.png");
            let status = std::process::Command::new(djxl)
                .arg(&destination)
                .arg(&decoded)
                .status()
                .unwrap();
            assert!(status.success());
            assert_eq!(
                image::open(decoded).unwrap().into_rgba8(),
                image::open(expected_path).unwrap().into_rgba8(),
                "chunk callbacks must preserve exact samples across 2048/2056 padding and tile edges"
            );
        }
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(lumia_jxl)]
    #[test]
    fn pause_or_cancel_checkpoint_during_jxl_encoding_removes_partial_output() {
        let (root, manifest) = fixture("cancel", 256, 256);
        let output_dir = root.join("outputs");
        fs::create_dir_all(&output_dir).unwrap();
        let destination = output_dir.join("cancelled.jxl");
        let mut encode_checkpoints = 0usize;
        let result = export_level0_jxl(
            &root,
            &manifest,
            &destination,
            128,
            1,
            &mut |_, _| Ok(()),
            &mut |_, _| {
                encode_checkpoints += 1;
                if encode_checkpoints > 5 {
                    Err(Error::Cancelled)
                } else {
                    Ok(())
                }
            },
            &mut || Ok(()),
        );
        assert!(matches!(result, Err(Error::Cancelled)));
        assert!(
            encode_checkpoints > 5,
            "cancellation must reach the encoder phase"
        );
        assert!(!destination.exists());
        assert!(fs::read_dir(&output_dir).unwrap().next().is_none());
        fs::remove_dir_all(root).unwrap();
    }
}
