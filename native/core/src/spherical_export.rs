//! Bounded-memory export from a rendered level-zero tile grid to a PNG.
use crate::{Error, Result};
use png::{BitDepth, ColorType, Compression, Filter};
use serde_json::Value;
use std::{
    collections::HashMap,
    fs::{self, File, OpenOptions},
    io::{BufWriter, Read, Write},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

const TILE_SIZE: u32 = 512;
const MAX_DIMENSION: u32 = 131_072;
const MAX_PIXELS: u64 = 4_000_000_000;

#[derive(Clone)]
pub(crate) struct ValidatedLevel0 {
    pub(crate) width: u32,
    pub(crate) height: u32,
    rows: u32,
    columns: u32,
    pub(crate) root: PathBuf,
    tiles: HashMap<(u32, u32), (PathBuf, u32, u32)>,
    pub(crate) total_tile_bytes: u64,
}

pub(crate) struct AssemblyStats {
    pub(crate) rows_written: u32,
    pub(crate) source_tile_decodes: u64,
    pub(crate) source_decode_ms: u64,
    pub(crate) peak_spool_bytes: u64,
    pub(crate) peak_working_bytes: u64,
}

pub(crate) fn validate_level0(
    job_dir: &Path,
    manifest: &Value,
    max_pixels: u64,
    label: &str,
) -> Result<ValidatedLevel0> {
    let width = u32::try_from(manifest["width"].as_u64().unwrap_or(0))
        .map_err(|_| invalid(format!("{label} width is invalid")))?;
    let height = u32::try_from(manifest["height"].as_u64().unwrap_or(0))
        .map_err(|_| invalid(format!("{label} height is invalid")))?;
    if width == 0
        || height == 0
        || width > MAX_DIMENSION
        || height > MAX_DIMENSION
        || u64::from(width) * u64::from(height) > max_pixels
    {
        return Err(invalid(format!(
            "unsupported {label} dimensions {width}x{height}"
        )));
    }
    let columns = width.div_ceil(TILE_SIZE);
    let rows = height.div_ceil(TILE_SIZE);
    if manifest["tileSize"].as_u64() != Some(u64::from(TILE_SIZE)) {
        return Err(invalid("manifest tileSize must be 512"));
    }
    let levels = manifest["levels"]
        .as_array()
        .ok_or_else(|| invalid("manifest has no levels array"))?;
    let level0 = levels
        .iter()
        .find(|level| level["level"].as_u64() == Some(0))
        .ok_or_else(|| invalid("manifest has no level-zero entry"))?;
    let occupied = level0["occupied"]
        .as_array()
        .ok_or_else(|| invalid("manifest level zero has no occupied tile list"))?;
    let root = job_dir
        .canonicalize()
        .map_err(|e| invalid(format!("job directory unavailable: {e}")))?;
    let mut tiles = HashMap::<(u32, u32), (PathBuf, u32, u32)>::new();
    let mut total_tile_bytes = 0u64;
    for tile in occupied {
        let row = u32::try_from(tile["row"].as_u64().unwrap_or(u64::MAX))
            .map_err(|_| invalid("level-zero tile row is invalid"))?;
        let column = u32::try_from(tile["column"].as_u64().unwrap_or(u64::MAX))
            .map_err(|_| invalid("level-zero tile column is invalid"))?;
        if row >= rows || column >= columns {
            return Err(invalid("level-zero tile coordinate exceeds output grid"));
        }
        let expected_width = (width - column * TILE_SIZE).min(TILE_SIZE);
        let expected_height = (height - row * TILE_SIZE).min(TILE_SIZE);
        let declared_width = u32::try_from(tile["width"].as_u64().unwrap_or(0))
            .map_err(|_| invalid("level-zero tile width is invalid"))?;
        let declared_height = u32::try_from(tile["height"].as_u64().unwrap_or(0))
            .map_err(|_| invalid("level-zero tile height is invalid"))?;
        if (declared_width, declared_height) != (expected_width, expected_height) {
            return Err(invalid(format!(
                "level-zero tile ({row},{column}) dimensions do not match output grid"
            )));
        }
        let relative = tile["path"]
            .as_str()
            .filter(|value| !value.is_empty())
            .ok_or_else(|| invalid("level-zero tile path is empty"))?;
        let canonical = root
            .join(relative)
            .canonicalize()
            .map_err(|e| invalid(format!("level-zero tile unavailable: {e}")))?;
        if !canonical.starts_with(&root) {
            return Err(invalid("level-zero tile path escapes job directory"));
        }
        if tiles.contains_key(&(row, column)) {
            return Err(invalid(format!(
                "duplicate level-zero tile ({row},{column})"
            )));
        }
        tiles.insert((row, column), (canonical, expected_width, expected_height));
        total_tile_bytes = total_tile_bytes
            .checked_add(u64::from(expected_width) * u64::from(expected_height) * 4)
            .ok_or_else(|| invalid("level-zero spool size overflow"))?;
    }
    Ok(ValidatedLevel0 {
        width,
        height,
        rows,
        columns,
        root,
        tiles,
        total_tile_bytes,
    })
}

pub(crate) fn for_each_level0_row(
    grid: &ValidatedLevel0,
    spool_path: &Path,
    memory_budget_mib: usize,
    checkpoint: &mut dyn FnMut(u32, u32) -> Result<()>,
    mut visit_row: impl FnMut(&[u8]) -> Result<()>,
) -> Result<AssemblyStats> {
    let mut row_buffer = vec![0u8; grid.width as usize * 4];
    let budget_bytes = memory_budget_mib as u64 * 1024 * 1024;
    let mut rows_written = 0u32;
    let mut source_tile_decodes = 0u64;
    let mut source_decode_ms = 0u64;
    let mut peak_spool_bytes = 0u64;
    let mut peak_working_bytes = row_buffer.len() as u64;
    for tile_row in 0..grid.rows {
        let tile_height = (grid.height - tile_row * TILE_SIZE).min(TILE_SIZE);
        let row_tile_bytes = (0..grid.columns)
            .filter_map(|column| grid.tiles.get(&(tile_row, column)))
            .map(|(_, tw, th)| u64::from(*tw) * u64::from(*th) * 4)
            .sum::<u64>();
        let max_decode_transient = (0..grid.columns)
            .filter_map(|column| grid.tiles.get(&(tile_row, column)))
            .map(|(_, tw, th)| u64::from(*tw) * u64::from(*th) * 8)
            .max()
            .unwrap_or(0);
        let writer_reserve = 64 * 1024;
        let resident_estimate =
            row_tile_bytes + max_decode_transient + row_buffer.len() as u64 + writer_reserve;
        let keep_row_in_memory = resident_estimate <= budget_bytes;
        let working_estimate = max_decode_transient
            + row_buffer.len() as u64
            + writer_reserve
            + if keep_row_in_memory {
                row_tile_bytes
            } else {
                0
            };
        peak_working_bytes = peak_working_bytes.max(working_estimate);
        let mut row_images =
            Vec::<Option<::image::RgbaImage>>::with_capacity(grid.columns as usize);
        let mut row_files = Vec::<Option<(File, u32)>>::with_capacity(grid.columns as usize);
        let mut row_spool_paths = Vec::<PathBuf>::new();
        for column in 0..grid.columns {
            if let Some((png_path, tile_width, tile_height)) = grid.tiles.get(&(tile_row, column)) {
                checkpoint(rows_written, grid.height)?;
                let reader = ::image::ImageReader::open(png_path)?.with_guessed_format()?;
                if reader.into_dimensions()? != (*tile_width, *tile_height) {
                    return Err(invalid(format!(
                        "level-zero tile ({tile_row},{column}) dimensions changed"
                    )));
                }
                let decode_started = std::time::Instant::now();
                let decoded = ::image::open(png_path)?.into_rgba8();
                source_decode_ms += decode_started.elapsed().as_millis() as u64;
                source_tile_decodes += 1;
                if (decoded.width(), decoded.height()) != (*tile_width, *tile_height) {
                    return Err(invalid(format!(
                        "level-zero tile ({tile_row},{column}) dimensions changed"
                    )));
                }
                if keep_row_in_memory {
                    row_images.push(Some(decoded));
                    row_files.push(None);
                } else {
                    let raw_path = spool_path.join(format!("{tile_row}-{column}.rgba"));
                    let mut raw = OpenOptions::new()
                        .write(true)
                        .create_new(true)
                        .open(&raw_path)?;
                    raw.write_all(decoded.as_raw())?;
                    raw.flush()?;
                    drop(raw);
                    row_files.push(Some((File::open(&raw_path)?, *tile_width)));
                    row_images.push(None);
                    row_spool_paths.push(raw_path);
                }
            } else {
                row_images.push(None);
                row_files.push(None);
            }
        }
        if !keep_row_in_memory {
            peak_spool_bytes = peak_spool_bytes.max(row_tile_bytes);
        }
        for local_y in 0..tile_height {
            row_buffer.fill(0);
            for column in 0..grid.columns as usize {
                let start = column * TILE_SIZE as usize * 4;
                if let Some(image) = row_images[column].as_ref() {
                    let bytes = image.width() as usize * 4;
                    let source_start = local_y as usize * bytes;
                    row_buffer[start..start + bytes]
                        .copy_from_slice(&image.as_raw()[source_start..source_start + bytes]);
                } else if let Some((file, tile_width)) = row_files[column].as_mut() {
                    let bytes = *tile_width as usize * 4;
                    file.read_exact(&mut row_buffer[start..start + bytes])?;
                }
            }
            visit_row(&row_buffer)?;
            rows_written += 1;
            checkpoint(rows_written, grid.height)?;
        }
        drop(row_files);
        drop(row_images);
        for path in row_spool_paths {
            fs::remove_file(path)?;
        }
    }
    Ok(AssemblyStats {
        rows_written,
        source_tile_decodes,
        source_decode_ms,
        peak_spool_bytes,
        peak_working_bytes,
    })
}

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
struct OwnedDestination(PathBuf, bool);
impl Drop for OwnedDestination {
    fn drop(&mut self) {
        if !self.1 {
            let _ = fs::remove_file(&self.0);
        }
    }
}

fn invalid(message: impl Into<String>) -> Error {
    Error::Invalid(message.into())
}

/// Assemble the renderer's independent level-zero PNG tiles into one streamed PNG.
/// The spool contains decoded tile pixels on disk, so source tile files are decoded once
/// and RAM use does not grow with panorama dimensions or tile count.
pub(crate) fn export_level0_png(
    job_dir: &Path,
    manifest: &Value,
    destination: &Path,
    memory_budget_mib: usize,
    checkpoint: &mut dyn FnMut(u32, u32) -> Result<()>,
    begin_commit: &mut dyn FnMut() -> Result<()>,
) -> Result<Value> {
    if !(16..=4096).contains(&memory_budget_mib) {
        return Err(invalid("memoryBudgetMiB must be 16..=4096"));
    }
    let grid = validate_level0(job_dir, manifest, MAX_PIXELS, "PNG")?;
    let width = grid.width;
    let height = grid.height;
    let parent = destination
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)?;
    if destination.exists() {
        return Err(invalid("PNG export destination already exists"));
    }
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos());
    let spool_path = grid
        .root
        .join(format!(".png-export-{}-{nonce}", std::process::id()));
    fs::create_dir(&spool_path)?;
    let _spool = TempDir(spool_path.clone());
    let name = destination
        .file_name()
        .ok_or_else(|| invalid("PNG destination filename is empty"))?
        .to_string_lossy();
    let temporary = parent.join(format!(".{name}.{}.{}.tmp", std::process::id(), nonce));
    let output_file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)?;
    let _temporary = TempFile(temporary.clone());
    let mut encoder = png::Encoder::new(BufWriter::new(output_file), width, height);
    encoder.set_color(ColorType::Rgba);
    encoder.set_depth(BitDepth::Eight);
    encoder.set_compression(Compression::Fast);
    encoder.set_filter(Filter::NoFilter);
    let mut writer = encoder.write_header().map_err(|e| invalid(e.to_string()))?;
    let mut stream = writer.stream_writer().map_err(|e| invalid(e.to_string()))?;
    let export_started = std::time::Instant::now();
    let assembly = for_each_level0_row(&grid, &spool_path, memory_budget_mib, checkpoint, |row| {
        stream.write_all(row).map_err(Error::Io)
    })?;
    stream.finish().map_err(|e| invalid(e.to_string()))?;
    writer.finish().map_err(|e| invalid(e.to_string()))?;
    let mut file = OpenOptions::new().read(true).write(true).open(&temporary)?;
    file.flush()?;
    file.sync_all()?;
    drop(file);
    begin_commit()?;
    let publication = publish_no_overwrite(&temporary, destination)?;
    let export_ms = export_started.elapsed().as_millis() as u64;
    Ok(serde_json::json!({
        "path": destination,
        "width": width,
        "height": height,
        "rowsWritten": assembly.rows_written,
        "fullHeight": height,
        "sourceTileDecodes": assembly.source_tile_decodes,
        "spoolBytes": assembly.peak_spool_bytes,
        "totalOccupiedTileBytes": grid.total_tile_bytes,
        "sourceDecodeMs": assembly.source_decode_ms,
        "exportMs": export_ms,
        "memoryBudgetMiB": memory_budget_mib,
        "peakWorkingBytesEstimate": assembly.peak_working_bytes,
        "compression": "fast-lossless",
        "exportFormat": "png",
        "publication": publication
    }))
}

pub(crate) fn publish_no_overwrite(temporary: &Path, destination: &Path) -> Result<&'static str> {
    match fs::hard_link(temporary, destination) {
        Ok(()) => {
            let _ = fs::remove_file(temporary);
            Ok("hard-link")
        }
        Err(_error) if destination.exists() => Err(invalid("export destination already exists")),
        Err(_) => {
            let mut output = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(destination)?;
            let mut owned = OwnedDestination(destination.to_path_buf(), false);
            let mut input = File::open(temporary)?;
            std::io::copy(&mut input, &mut output)?;
            output.flush()?;
            output.sync_all()?;
            owned.1 = true;
            let _ = fs::remove_file(temporary);
            Ok("create-new-copy-fallback")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ::image::{Rgba, RgbaImage};
    use serde_json::json;

    fn test_dir() -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path =
            std::env::temp_dir().join(format!("lgs-export-test-{}-{stamp}", std::process::id()));
        fs::create_dir_all(path.join("level-0")).unwrap();
        path
    }

    fn write_tile(root: &Path, row: u32, column: u32, width: u32, height: u32, color: [u8; 4]) {
        let image = RgbaImage::from_pixel(width, height, Rgba(color));
        image
            .save(root.join(format!("level-0/{row}-{column}.png")))
            .unwrap();
    }

    fn write_gradient_tile(root: &Path, width: u32, height: u32) {
        let image = RgbaImage::from_fn(width, height, |x, y| {
            Rgba([(x & 255) as u8, (y & 255) as u8, 200, 255])
        });
        image.save(root.join("level-0/0-0.png")).unwrap();
    }

    fn manifest() -> Value {
        json!({"width":513,"height":513,"tileSize":512,"levels":[{"level":1,"occupied":[]},{"level":0,"occupied":[
            {"row":0,"column":0,"path":"level-0/0-0.png","width":512,"height":512},
            {"row":0,"column":1,"path":"level-0/0-1.png","width":1,"height":512},
            {"row":1,"column":1,"path":"level-0/1-1.png","width":1,"height":1}
        ]}]})
    }

    #[test]
    fn streamed_png_preserves_pixels_and_missing_cells_are_transparent() {
        let root = test_dir();
        write_gradient_tile(&root, 512, 512);
        write_tile(&root, 0, 1, 1, 512, [20, 30, 210, 255]);
        write_tile(&root, 1, 1, 1, 1, [40, 220, 60, 255]);
        let destination = root.join("panorama.png");
        let mut checkpoints = 0;
        let stats = export_level0_png(
            &root,
            &manifest(),
            &destination,
            32,
            &mut |row, h| {
                assert!(row <= h);
                checkpoints += 1;
                Ok(())
            },
            &mut || Ok(()),
        )
        .unwrap();
        let result = ::image::open(&destination).unwrap().into_rgba8();
        assert_eq!(result.dimensions(), (513, 513));
        assert_eq!(result.get_pixel(5, 8).0, [5, 8, 200, 255]);
        assert_eq!(result.get_pixel(5, 300).0, [5, 44, 200, 255]);
        assert_eq!(result.get_pixel(511, 511).0, [255, 255, 200, 255]);
        assert_eq!(result.get_pixel(512, 200).0, [20, 30, 210, 255]);
        assert_eq!(result.get_pixel(200, 512).0, [0, 0, 0, 0]);
        assert_eq!(result.get_pixel(512, 512).0, [40, 220, 60, 255]);
        assert_eq!(stats["sourceTileDecodes"], 3);
        assert_eq!(stats["rowsWritten"], 513);
        assert!(stats["peakWorkingBytesEstimate"].as_u64().unwrap() < 32 * 1024 * 1024);
        assert_eq!(stats["spoolBytes"], 0);
        assert_eq!(checkpoints, 3 + 513);
        assert!(export_level0_png(
            &root,
            &manifest(),
            &destination,
            32,
            &mut |_, _| Ok(()),
            &mut || Ok(()),
        )
        .is_err());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cancellation_does_not_publish_partial_png() {
        let root = test_dir();
        write_tile(&root, 0, 0, 512, 512, [1, 2, 3, 255]);
        write_tile(&root, 0, 1, 1, 512, [4, 5, 6, 255]);
        write_tile(&root, 1, 1, 1, 1, [7, 8, 9, 255]);
        let destination = root.join("cancelled.png");
        let result = export_level0_png(
            &root,
            &manifest(),
            &destination,
            32,
            &mut |row, _| {
                if row > 0 {
                    Err(Error::Cancelled)
                } else {
                    Ok(())
                }
            },
            &mut || Ok(()),
        );
        assert!(matches!(result, Err(Error::Cancelled)));
        assert!(!destination.exists());
        assert_eq!(
            fs::read_dir(&root)
                .unwrap()
                .filter_map(|entry| entry.ok())
                .filter(|entry| entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".png-export-"))
                .count(),
            0
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cancellation_at_final_commit_boundary_does_not_publish_png() {
        let root = test_dir();
        write_tile(&root, 0, 0, 512, 512, [1, 2, 3, 255]);
        write_tile(&root, 0, 1, 1, 512, [4, 5, 6, 255]);
        write_tile(&root, 1, 1, 1, 1, [7, 8, 9, 255]);
        let destination = root.join("cancel-at-commit.png");
        let mut rows_written = 0;
        let result = export_level0_png(
            &root,
            &manifest(),
            &destination,
            32,
            &mut |_, _| {
                rows_written += 1;
                Ok(())
            },
            &mut || Err(Error::Cancelled),
        );
        assert!(matches!(result, Err(Error::Cancelled)));
        assert_eq!(rows_written, 516); // three tile-start plus 513 row-boundary checks
        assert!(!destination.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn over_budget_tile_row_uses_and_releases_bounded_spool() {
        let root = test_dir();
        let count = 17u32;
        let occupied = (0..count)
            .map(|column| {
                write_tile(&root, 0, column, 512, 512, [column as u8, 20, 30, 255]);
                json!({"row":0,"column":column,"path":format!("level-0/0-{column}.png"),"width":512,"height":512})
            })
            .collect::<Vec<_>>();
        let manifest = json!({"width":count*512,"height":512,"tileSize":512,"levels":[{"level":0,"occupied":occupied}]});
        let destination = root.join("wide.png");
        let stats = export_level0_png(
            &root,
            &manifest,
            &destination,
            16,
            &mut |_, _| Ok(()),
            &mut || Ok(()),
        )
        .unwrap();
        assert_eq!(stats["sourceTileDecodes"], count);
        assert_eq!(stats["spoolBytes"], u64::from(count) * 512 * 512 * 4);
        assert!(stats["peakWorkingBytesEstimate"].as_u64().unwrap() < 16 * 1024 * 1024);
        let result = ::image::open(destination).unwrap().into_rgba8();
        assert_eq!(result.dimensions(), (count * 512, 512));
        assert_eq!(result.get_pixel(16 * 512 + 3, 100).0, [16, 20, 30, 255]);
        fs::remove_dir_all(root).unwrap();
    }
}
