//! Bounded-memory JPEG export from level-zero panorama tiles.
use crate::{spherical_export, Error, Result};
use image::{codecs::jpeg::JpegEncoder, GenericImageView, Rgb};
use serde_json::{json, Value};
use std::{
    fs::{self, File, OpenOptions},
    io::{BufWriter, Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    sync::Mutex,
    time::{SystemTime, UNIX_EPOCH},
};

// Common JPEG decoders such as libjpeg-turbo reject dimensions above 65500,
// even though the SOF field and image crate encoder accept u16::MAX.
const MAX_JPEG_DIMENSION: u32 = 65_500;
const MAX_PIXELS: u64 = 4_000_000_000;
const QUALITY: u8 = 90;

struct TempDir(PathBuf);
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
struct TempFile(PathBuf);
impl Drop for TempFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}
fn invalid(message: impl Into<String>) -> Error {
    Error::Invalid(message.into())
}

fn output_dimensions(width: u32, height: u32) -> (u32, u32) {
    let scale = (MAX_JPEG_DIMENSION as f64 / width as f64)
        .min(MAX_JPEG_DIMENSION as f64 / height as f64)
        .min(1.0);
    if scale == 1.0 {
        return (width, height);
    }
    (
        (width as f64 * scale)
            .round()
            .clamp(1.0, MAX_JPEG_DIMENSION as f64) as u32,
        (height as f64 * scale)
            .round()
            .clamp(1.0, MAX_JPEG_DIMENSION as f64) as u32,
    )
}

/// File-backed RGB view. The JPEG encoder requests pixels in 8x8 blocks; cache
/// those eight rows so encoder access stays sequential without loading the image.
struct CachedRgbView {
    file: Mutex<File>,
    cache: Mutex<(u32, Vec<u8>)>,
    width: u32,
    height: u32,
    io_error: Mutex<Option<String>>,
}

struct CheckpointWriter<'a, W> {
    inner: W,
    checkpoint: &'a mut dyn FnMut(u32, u32) -> Result<()>,
    checkpoint_error: &'a mut Option<Error>,
    bytes_since_checkpoint: usize,
}
impl<W: Write> Write for CheckpointWriter<'_, W> {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if self.checkpoint_error.is_some() {
            return Err(std::io::Error::other("JPEG export checkpoint failed"));
        }
        if self.bytes_since_checkpoint >= 64 * 1024 {
            if let Err(error) = (self.checkpoint)(0, 1) {
                *self.checkpoint_error = Some(error);
                return Err(std::io::Error::other("JPEG export checkpoint failed"));
            }
            self.bytes_since_checkpoint = 0;
        }
        let written = self.inner.write(bytes)?;
        self.bytes_since_checkpoint = self.bytes_since_checkpoint.saturating_add(written);
        Ok(written)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}
impl CachedRgbView {
    fn new(path: &Path, width: u32, height: u32) -> Result<Self> {
        Ok(Self {
            file: Mutex::new(File::open(path)?),
            cache: Mutex::new((u32::MAX, Vec::new())),
            width,
            height,
            io_error: Mutex::new(None),
        })
    }
    fn error(&self) -> Option<String> {
        self.io_error.lock().unwrap().clone()
    }
}
impl GenericImageView for CachedRgbView {
    type Pixel = Rgb<u8>;
    fn dimensions(&self) -> (u32, u32) {
        (self.width, self.height)
    }
    fn get_pixel(&self, x: u32, y: u32) -> Rgb<u8> {
        let block = y / 8 * 8;
        let mut cache = self.cache.lock().unwrap();
        if cache.0 != block {
            let rows = (self.height - block).min(8);
            let len = self.width as usize * rows as usize * 3;
            cache.1.resize(len, 0);
            let offset = u64::from(block) * u64::from(self.width) * 3;
            let result = {
                let mut file = self.file.lock().unwrap();
                file.seek(SeekFrom::Start(offset))
                    .and_then(|_| file.read_exact(&mut cache.1))
            };
            if let Err(error) = result {
                *self.io_error.lock().unwrap() = Some(error.to_string());
            }
            cache.0 = block;
        }
        let i = (y - block) as usize * self.width as usize * 3 + x as usize * 3;
        Rgb([cache.1[i], cache.1[i + 1], cache.1[i + 2]])
    }
}

pub(crate) fn export_level0_jpeg(
    job_dir: &Path,
    manifest: &Value,
    destination: &Path,
    memory_budget_mib: usize,
    checkpoint: &mut dyn FnMut(u32, u32) -> Result<()>,
    encode_checkpoint: &mut dyn FnMut(u32, u32) -> Result<()>,
    begin_commit: &mut dyn FnMut() -> Result<()>,
) -> Result<Value> {
    if !(crate::job_resources::MIN_EXPORT_MEMORY_MIB..=crate::job_resources::MAX_JOB_MEMORY_MIB)
        .contains(&memory_budget_mib)
    {
        return Err(invalid(format!(
            "memoryBudgetMiB must be {}..={} MiB",
            crate::job_resources::MIN_EXPORT_MEMORY_MIB,
            crate::job_resources::MAX_JOB_MEMORY_MIB
        )));
    }
    let grid = spherical_export::validate_level0(job_dir, manifest, MAX_PIXELS, "JPEG")?;
    let (width, height) = output_dimensions(grid.width, grid.height);
    let parent = destination
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)?;
    if destination.exists() {
        return Err(invalid("JPEG export destination already exists"));
    }
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos());
    let spool_path = grid
        .root
        .join(format!(".jpeg-export-{}-{nonce}", std::process::id()));
    fs::create_dir(&spool_path)?;
    let _spool = TempDir(spool_path.clone());
    let rgb_path = spool_path.join("rgb.raw");
    let mut rgb = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&rgb_path)?;
    let mut white = |row: &[u8]| {
        let mut flattened = Vec::with_capacity(row.len() / 4 * 3);
        for pixel in row.chunks_exact(4) {
            let alpha = u16::from(pixel[3]);
            for channel in &pixel[..3] {
                flattened
                    .push(((u16::from(*channel) * alpha + 255 * (255 - alpha) + 127) / 255) as u8);
            }
        }
        rgb.write_all(&flattened).map_err(Error::from)
    };
    let assembly = spherical_export::for_each_level0_row(
        &grid,
        &spool_path,
        memory_budget_mib,
        checkpoint,
        &mut white,
    )?;
    rgb.flush()?;
    drop(rgb);
    let resized_path = spool_path.join("resized.raw");
    let resized = width != grid.width || height != grid.height;
    let source_path = if resized {
        resize_rgb(
            &rgb_path,
            &resized_path,
            grid.width,
            grid.height,
            width,
            height,
            checkpoint,
        )?;
        resized_path.as_path()
    } else {
        rgb_path.as_path()
    };
    let source_spool_bytes = u64::from(grid.width) * u64::from(grid.height) * 3;
    let output_spool_bytes = if resized {
        u64::from(width) * u64::from(height) * 3
    } else {
        0
    };
    let peak_working_bytes = assembly
        .peak_working_bytes
        .saturating_add(u64::from(grid.width) * 3)
        .max(u64::from(grid.width) * 6 + u64::from(width) * 3)
        .max(u64::from(width) * 24 + 256 * 1024);
    let memory_budget_bytes = crate::job_resources::checked_memory_budget_bytes(memory_budget_mib)
        .ok_or_else(|| invalid("memoryBudgetMiB overflows byte accounting"))?;
    if peak_working_bytes > memory_budget_bytes {
        return Err(invalid(format!("JPEG export requires an estimated {peak_working_bytes} working bytes, exceeding memoryBudgetMiB")));
    }
    let filename = destination
        .file_name()
        .ok_or_else(|| invalid("JPEG destination filename is empty"))?
        .to_string_lossy();
    let temporary = parent.join(format!(".{filename}.{}.{}.tmp", std::process::id(), nonce));
    let output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)?;
    let _temporary = TempFile(temporary.clone());
    let view = CachedRgbView::new(source_path, width, height)?;
    encode_checkpoint(0, 1)?;
    let mut checkpoint_error = None;
    let encode_result = {
        let writer = CheckpointWriter {
            inner: output,
            checkpoint: encode_checkpoint,
            checkpoint_error: &mut checkpoint_error,
            bytes_since_checkpoint: 0,
        };
        let mut buffered = BufWriter::new(writer);
        let result = JpegEncoder::new_with_quality(&mut buffered, QUALITY).encode_image(&view);
        let flush_result = buffered.flush().map_err(image::ImageError::IoError);
        result.and(flush_result)
    };
    if let Some(error) = checkpoint_error {
        return Err(error);
    }
    encode_result.map_err(|e| invalid(format!("JPEG encoder failed: {e}")))?;
    if let Some(error) = view.error() {
        return Err(invalid(format!("JPEG source cache read failed: {error}")));
    }
    encode_checkpoint(1, 1)?;
    let mut file = OpenOptions::new().read(true).write(true).open(&temporary)?;
    file.flush()?;
    file.sync_all()?;
    drop(file);
    begin_commit()?;
    let publication = spherical_export::publish_no_overwrite(&temporary, destination)?;
    Ok(json!({
        "path":destination,"sourceWidth":grid.width,"sourceHeight":grid.height,
        "width":width,"height":height,"scaled":resized,"scale":width as f64/grid.width as f64,
        "scaleX":width as f64/grid.width as f64,"scaleY":height as f64/grid.height as f64,
        "rowsWritten":height,"sourceRowsRead":assembly.rows_written,"fullHeight":height,
        "sourceTileDecodes":assembly.source_tile_decodes,"sourceDecodeMs":assembly.source_decode_ms,
        "totalOccupiedTileBytes":grid.total_tile_bytes,"spoolBytes":source_spool_bytes + output_spool_bytes,"memoryBudgetMiB":memory_budget_mib,
        "peakWorkingBytesEstimate":peak_working_bytes,"quality":QUALITY,
        "compression":"lossy","sampleFormat":"RGB8","alpha":"flattened-white",
        "exportFormat":"jpeg","publication":publication
    }))
}

fn resize_rgb(
    src: &Path,
    dst: &Path,
    sw: u32,
    sh: u32,
    dw: u32,
    dh: u32,
    checkpoint: &mut dyn FnMut(u32, u32) -> Result<()>,
) -> Result<PathBuf> {
    // Two source rows and one output row bound RAM independently of image size.
    let mut input = File::open(src)?;
    let mut output = BufWriter::new(OpenOptions::new().write(true).create_new(true).open(dst)?);
    let mut row0 = vec![0u8; sw as usize * 3];
    let mut row1 = vec![0u8; sw as usize * 3];
    let mut out = vec![0u8; dw as usize * 3];
    for dy in 0..dh {
        checkpoint(dy, dh)?;
        let sy = ((dy as f64 + 0.5) * sh as f64 / dh as f64 - 0.5).clamp(0.0, (sh - 1) as f64);
        let y0 = sy.floor() as u32;
        let y1 = (y0 + 1).min(sh - 1);
        let fy = sy - y0 as f64;
        input.seek(SeekFrom::Start(u64::from(y0) * u64::from(sw) * 3))?;
        input.read_exact(&mut row0)?;
        input.seek(SeekFrom::Start(u64::from(y1) * u64::from(sw) * 3))?;
        input.read_exact(&mut row1)?;
        for dx in 0..dw {
            let sx = ((dx as f64 + 0.5) * sw as f64 / dw as f64 - 0.5).clamp(0.0, (sw - 1) as f64);
            let x0 = sx.floor() as usize;
            let x1 = (x0 + 1).min(sw as usize - 1);
            let fx = sx - x0 as f64;
            for c in 0..3 {
                let a = row0[x0 * 3 + c] as f64 * (1.0 - fx) + row0[x1 * 3 + c] as f64 * fx;
                let b = row1[x0 * 3 + c] as f64 * (1.0 - fx) + row1[x1 * 3 + c] as f64 * fx;
                out[dx as usize * 3 + c] =
                    (a * (1.0 - fy) + b * fy).round().clamp(0.0, 255.0) as u8;
            }
        }
        output.write_all(&out)?;
    }
    output.flush()?;
    Ok(dst.to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dimensions_scale_aspect_and_keep_under_limit() {
        assert_eq!(output_dimensions(10, 20), (10, 20));
        assert_eq!(output_dimensions(65_500, 65_500), (65_500, 65_500));
        assert_eq!(output_dimensions(131_072, 512), (65_500, 256));
        assert_eq!(output_dimensions(512, 131_072), (256, 65_500));
        assert_eq!(output_dimensions(65_501, 65_500), (65_500, 65_499));
        assert_eq!(output_dimensions(65_499, 65_500), (65_499, 65_500));
    }

    fn write_color_tile(root: &Path, row: u32, col: u32, width: u32, height: u32, color: [u8; 4]) {
        image::RgbaImage::from_pixel(width, height, image::Rgba(color))
            .save(root.join(format!("level-0/{row}-{col}.png")))
            .unwrap();
    }

    fn export_boundary(root: &Path, width: u32, height: u32) -> image::RgbImage {
        let cols = width.div_ceil(512);
        let rows = height.div_ceil(512);
        let first_w = width.min(512);
        let first_h = height.min(512);
        let last_col = cols - 1;
        let last_row = rows - 1;
        write_color_tile(root, 0, 0, first_w, first_h, [220, 20, 20, 255]);
        let mut occupied = vec![
            json!({"row":0,"column":0,"path":"level-0/0-0.png","width":first_w,"height":first_h}),
        ];
        if last_col != 0 {
            let tile_w = width - last_col * 512;
            write_color_tile(root, 0, last_col, tile_w, first_h, [20, 30, 220, 255]);
            occupied.push(json!({"row":0,"column":last_col,"path":format!("level-0/0-{last_col}.png"),"width":tile_w,"height":first_h}));
        }
        if last_row != 0 {
            let tile_h = height - last_row * 512;
            write_color_tile(root, last_row, 0, first_w, tile_h, [20, 30, 220, 255]);
            occupied.push(json!({"row":last_row,"column":0,"path":format!("level-0/{last_row}-0.png"),"width":first_w,"height":tile_h}));
        }
        let manifest = json!({"width":width,"height":height,"tileSize":512,"levels":[{"level":0,"occupied":occupied}]});
        let destination = root.join(format!("boundary-{width}x{height}.jpg"));
        let stats = export_level0_jpeg(
            root,
            &manifest,
            &destination,
            32,
            &mut |_, _| Ok(()),
            &mut |_, _| Ok(()),
            &mut || Ok(()),
        )
        .unwrap();
        if let Some(output) = std::env::var_os("JPEG_PRODUCT_FIXTURE_DIR") {
            let output = PathBuf::from(output);
            fs::create_dir_all(&output).unwrap();
            fs::copy(&destination, output.join(format!("{width}x{height}.jpg"))).unwrap();
        }
        let decoded = image::open(destination).unwrap().into_rgb8();
        assert_eq!(
            decoded.dimensions(),
            (
                stats["width"].as_u64().unwrap() as u32,
                stats["height"].as_u64().unwrap() as u32
            )
        );
        decoded
    }

    #[test]
    fn sparse_superwide_supertall_and_dimension_boundary_exports_decode() {
        let root = std::env::temp_dir().join(format!(
            "lgs-jpeg-boundary-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(root.join("level-0")).unwrap();
        let wide = export_boundary(&root, 65_536, 2);
        assert_eq!(wide.dimensions(), (65_500, 2));
        assert!(wide.get_pixel(100, 0)[0] > 170);
        assert!(wide.get_pixel(65_400, 0)[2] > 150);
        let tall = export_boundary(&root, 2, 65_536);
        assert_eq!(tall.dimensions(), (2, 65_500));
        assert!(tall.get_pixel(0, 100)[0] > 170);
        assert!(tall.get_pixel(0, 65_400)[2] > 150);
        let exact = export_boundary(&root, 65_500, 1);
        assert_eq!(exact.dimensions(), (65_500, 1));
        let under = export_boundary(&root, 65_499, 1);
        assert_eq!(under.dimensions(), (65_499, 1));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn jpeg_round_trip_uses_level_zero_and_flattens_holes_white() {
        let root = std::env::temp_dir().join(format!(
            "lgs-jpeg-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(root.join("level-0")).unwrap();
        image::RgbaImage::from_pixel(512, 512, image::Rgba([210, 30, 20, 255]))
            .save(root.join("level-0/0-0.png"))
            .unwrap();
        image::RgbaImage::from_pixel(1, 512, image::Rgba([20, 40, 210, 255]))
            .save(root.join("level-0/0-1.png"))
            .unwrap();
        image::RgbaImage::from_pixel(1, 1, image::Rgba([10, 200, 20, 255]))
            .save(root.join("level-0/1-1.png"))
            .unwrap();
        let manifest = json!({"width":513,"height":513,"tileSize":512,"levels":[{"level":0,"occupied":[
          {"row":0,"column":0,"path":"level-0/0-0.png","width":512,"height":512},
          {"row":0,"column":1,"path":"level-0/0-1.png","width":1,"height":512},
          {"row":1,"column":1,"path":"level-0/1-1.png","width":1,"height":1}
        ]}]});
        let dest = root.join("pano.jpg");
        let stats = export_level0_jpeg(
            &root,
            &manifest,
            &dest,
            32,
            &mut |_, _| Ok(()),
            &mut |_, _| Ok(()),
            &mut || Ok(()),
        )
        .unwrap();
        let decoded = image::open(&dest).unwrap().into_rgb8();
        assert_eq!(decoded.dimensions(), (513, 513));
        assert_eq!(stats["sourceWidth"], 513);
        assert_eq!(stats["width"], 513);
        assert_eq!(stats["quality"], 90);
        assert_eq!(stats["alpha"], "flattened-white");
        let red = decoded.get_pixel(100, 100).0;
        assert!(red[0] > 170 && red[1] < 70 && red[2] < 70, "{red:?}");
        let hole = decoded.get_pixel(200, 512).0;
        assert!(hole[0] > 220 && hole[1] > 220 && hole[2] > 220, "{hole:?}");
        let cancelled = root.join("cancelled.jpg");
        assert!(matches!(
            export_level0_jpeg(
                &root,
                &manifest,
                &cancelled,
                32,
                &mut |done, _| if done > 0 {
                    Err(Error::Cancelled)
                } else {
                    Ok(())
                },
                &mut |_, _| Ok(()),
                &mut || Ok(())
            ),
            Err(Error::Cancelled)
        ));
        assert!(!cancelled.exists());
        assert_eq!(
            fs::read_dir(&root)
                .unwrap()
                .filter_map(|e| e.ok())
                .filter(|e| e.file_name().to_string_lossy().starts_with(".jpeg-export-"))
                .count(),
            0
        );
        let existing = root.join("keep.jpg");
        fs::write(&existing, b"keep").unwrap();
        assert!(export_level0_jpeg(
            &root,
            &manifest,
            &existing,
            32,
            &mut |_, _| Ok(()),
            &mut |_, _| Ok(()),
            &mut || Ok(())
        )
        .is_err());
        assert_eq!(fs::read(existing).unwrap(), b"keep");
        let mut random = 0x1234_5678u32;
        let noisy = image::RgbaImage::from_fn(512, 512, |_, _| {
            let mut channels = [0u8; 3];
            for channel in &mut channels {
                random ^= random << 13;
                random ^= random >> 17;
                random ^= random << 5;
                *channel = random as u8;
            }
            image::Rgba([channels[0], channels[1], channels[2], 255])
        });
        noisy.save(root.join("level-0/noise.png")).unwrap();
        let noisy_manifest = json!({"width":512,"height":512,"tileSize":512,"levels":[{"level":0,"occupied":[{"row":0,"column":0,"path":"level-0/noise.png","width":512,"height":512}]}]});
        let mut encode_calls = 0;
        let mid_cancel = root.join("mid-encode-cancel.jpg");
        let result = export_level0_jpeg(
            &root,
            &noisy_manifest,
            &mid_cancel,
            32,
            &mut |_, _| Ok(()),
            &mut |_, _| {
                encode_calls += 1;
                if encode_calls >= 2 {
                    Err(Error::Cancelled)
                } else {
                    Ok(())
                }
            },
            &mut || Ok(()),
        );
        assert!(matches!(result, Err(Error::Cancelled)));
        assert!(encode_calls >= 2);
        assert!(!mid_cancel.exists());
        assert_eq!(
            fs::read_dir(&root)
                .unwrap()
                .filter_map(|e| e.ok())
                .filter(|e| e
                    .file_name()
                    .to_string_lossy()
                    .contains("mid-encode-cancel")
                    && e.file_name().to_string_lossy().ends_with(".tmp"))
                .count(),
            0
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn bilinear_resize_keeps_source_endpoints_and_dimensions() {
        let root = std::env::temp_dir().join(format!(
            "lgs-jpeg-resize-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        let src = root.join("src.raw");
        let dst = root.join("dst.raw");
        fs::write(&src, [0, 0, 0, 100, 100, 100, 200, 200, 200, 255, 255, 255]).unwrap();
        resize_rgb(&src, &dst, 2, 2, 1, 1, &mut |_, _| Ok(())).unwrap();
        let pixels = fs::read(&dst).unwrap();
        assert_eq!(pixels.len(), 3);
        assert!(pixels[0] > 100 && pixels[0] < 160);
        fs::remove_dir_all(root).unwrap();
    }
}
