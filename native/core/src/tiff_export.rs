//! Bounded-memory, lossless RGBA8 BigTIFF/TIFF export from level-zero tiles.
use crate::{spherical_export, Error, Result};
use serde_json::{json, Value};
use std::{
    fs::{self, File, OpenOptions},
    io::{BufWriter, Write},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};
use tiff::encoder::{
    colortype::RGB8, Compression, TiffEncoder, TiffKind, TiffKindBig, TiffKindStandard,
};
use tiff::tags::ExtraSamples;

const MAX_PIXELS: u64 = 4_000_000_000;
const MAX_STRIP_BYTES: u64 = 1024 * 1024;

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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TiffVariant {
    Classic,
    Big,
}

fn rows_per_strip(width: u32, height: u32) -> u32 {
    let row_bytes = u64::from(width) * 4;
    (MAX_STRIP_BYTES / row_bytes).max(1).min(u64::from(height)) as u32
}

fn estimated_classic_size(width: u32, height: u32, strip_rows: u32) -> Option<u64> {
    let raw = u64::from(width)
        .checked_mul(u64::from(height))?
        .checked_mul(4)?;
    let strips = u64::from(height).div_ceil(u64::from(strip_rows));
    // Raw RGBA bytes plus conservative offset/count arrays, the IFD, and header.
    raw.checked_add(strips.checked_mul(24)?)?.checked_add(4096)
}

fn choose_variant(width: u32, height: u32, strip_rows: u32) -> TiffVariant {
    match estimated_classic_size(width, height, strip_rows) {
        Some(upper_bound) if upper_bound < u64::from(u32::MAX) => TiffVariant::Classic,
        _ => TiffVariant::Big,
    }
}

pub(crate) fn export_level0_tiff(
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
    let grid = spherical_export::validate_level0(job_dir, manifest, MAX_PIXELS, "TIFF")?;
    let strip_rows = rows_per_strip(grid.width, grid.height);
    let variant = choose_variant(grid.width, grid.height, strip_rows);
    let strip_count = u64::from(grid.height).div_ceil(u64::from(strip_rows));
    let directory_metadata_bytes = strip_count
        * match variant {
            TiffVariant::Classic => 8,
            TiffVariant::Big => 16,
        };
    let parent = destination
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)?;
    if destination.exists() {
        return Err(invalid("TIFF export destination already exists"));
    }
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos());
    let spool_path = grid
        .root
        .join(format!(".tiff-export-{}-{nonce}", std::process::id()));
    fs::create_dir(&spool_path)?;
    let _spool = TempDir(spool_path.clone());
    let name = destination
        .file_name()
        .ok_or_else(|| invalid("TIFF destination filename is empty"))?
        .to_string_lossy();
    let temporary = parent.join(format!(".{name}.{}.{}.tmp", std::process::id(), nonce));
    let output_file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)?;
    let _temporary = TempFile(temporary.clone());
    let export_started = std::time::Instant::now();
    let (assembly, peak_strip_bytes) = match variant {
        TiffVariant::Classic => encode::<TiffKindStandard>(
            output_file,
            &grid,
            &spool_path,
            memory_budget_mib,
            strip_rows,
            checkpoint,
        )?,
        TiffVariant::Big => encode::<TiffKindBig>(
            output_file,
            &grid,
            &spool_path,
            memory_budget_mib,
            strip_rows,
            checkpoint,
        )?,
    };
    let mut file = OpenOptions::new().read(true).write(true).open(&temporary)?;
    file.flush()?;
    file.sync_all()?;
    drop(file);
    begin_commit()?;
    let publication = spherical_export::publish_no_overwrite(&temporary, destination)?;
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
        "exportMs": export_started.elapsed().as_millis() as u64,
        "memoryBudgetMiB": memory_budget_mib,
        "peakWorkingBytesEstimate": assembly.peak_working_bytes.saturating_add(peak_strip_bytes).saturating_add(directory_metadata_bytes),
        "directoryMetadataBytesEstimate": directory_metadata_bytes,
        "compression": "none-lossless",
        "sampleFormat": "RGBA8",
        "alpha": "unassociated",
        "exportFormat": "tiff",
        "tiffVariant": match variant { TiffVariant::Classic => "classic", TiffVariant::Big => "bigtiff" },
        "publication": publication
    }))
}

fn encode<K: TiffKind>(
    file: File,
    grid: &spherical_export::ValidatedLevel0,
    spool_path: &Path,
    memory_budget_mib: usize,
    strip_rows: u32,
    checkpoint: &mut dyn FnMut(u32, u32) -> Result<()>,
) -> Result<(spherical_export::AssemblyStats, u64)> {
    let mut encoder = TiffEncoder::<_, K>::new_generic(BufWriter::new(file))
        .map_err(|e| invalid(format!("TIFF encoder initialization failed: {e}")))?
        .with_compression(Compression::Uncompressed);
    let mut image = encoder
        .new_image::<RGB8>(grid.width, grid.height)
        .map_err(|e| invalid(format!("TIFF image initialization failed: {e}")))?;
    image
        .extra_samples(&[ExtraSamples::UnassociatedAlpha])
        .map_err(|e| invalid(format!("TIFF alpha tag failed: {e}")))?;
    image
        .rows_per_strip(strip_rows)
        .map_err(|e| invalid(format!("TIFF strip configuration failed: {e}")))?;
    let strip_capacity = grid.width as usize * 4 * strip_rows as usize;
    let mut strip = Vec::with_capacity(strip_capacity);
    let mut strip_line_count = 0u32;
    let mut rows_seen = 0u32;
    let mut peak_strip_bytes = 0u64;
    let assembly = spherical_export::for_each_level0_row(
        grid,
        spool_path,
        memory_budget_mib,
        checkpoint,
        |row| {
            strip.extend_from_slice(row);
            strip_line_count += 1;
            rows_seen += 1;
            if strip_line_count == strip_rows || rows_seen == grid.height {
                image
                    .write_strip(&strip)
                    .map_err(|e| invalid(format!("TIFF strip write failed: {e}")))?;
                peak_strip_bytes = peak_strip_bytes.max(strip.len() as u64);
                strip.clear();
                strip_line_count = 0;
            }
            Ok(())
        },
    )?;
    if !strip.is_empty() {
        image
            .write_strip(&strip)
            .map_err(|e| invalid(format!("TIFF final strip write failed: {e}")))?;
        peak_strip_bytes = peak_strip_bytes.max(strip.len() as u64);
    }
    image
        .finish()
        .map_err(|e| invalid(format!("TIFF directory finalization failed: {e}")))?;
    Ok((assembly, peak_strip_bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{Rgba, RgbaImage};
    use serde_json::json;
    use std::{
        collections::BTreeMap,
        io::{Seek, SeekFrom},
    };

    fn test_dir() -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path =
            std::env::temp_dir().join(format!("lgs-tiff-export-{}-{stamp}", std::process::id()));
        fs::create_dir_all(path.join("level-0")).unwrap();
        path
    }

    fn write_tile(root: &Path, row: u32, column: u32, width: u32, height: u32, color: [u8; 4]) {
        RgbaImage::from_pixel(width, height, Rgba(color))
            .save(root.join(format!("level-0/{row}-{column}.png")))
            .unwrap();
    }

    fn test_manifest() -> Value {
        json!({"width":513,"height":513,"tileSize":512,"levels":[{"level":0,"occupied":[
            {"row":0,"column":0,"path":"level-0/0-0.png","width":512,"height":512},
            {"row":0,"column":1,"path":"level-0/0-1.png","width":1,"height":512},
            {"row":1,"column":1,"path":"level-0/1-1.png","width":1,"height":1}
        ]}]})
    }

    #[test]
    fn classic_upper_bound_switches_before_classic_offsets_can_overflow() {
        assert_eq!(choose_variant(512, 512, 512), TiffVariant::Classic);
        let rows = rows_per_strip(16_384, 65_536);
        assert_eq!(rows, 16);
        assert_eq!(choose_variant(16_384, 65_536, rows), TiffVariant::Big);
        assert!(estimated_classic_size(16_384, 65_536, rows).unwrap() > u64::from(u32::MAX));
    }

    #[test]
    fn tiff_round_trip_keeps_rgba_and_transparent_missing_edge_tiles() {
        let root = test_dir();
        let image = RgbaImage::from_fn(512, 512, |x, y| {
            Rgba([
                (x & 255) as u8,
                (y & 255) as u8,
                200,
                (x.wrapping_add(y) & 255) as u8,
            ])
        });
        image.save(root.join("level-0/0-0.png")).unwrap();
        write_tile(&root, 0, 1, 1, 512, [20, 30, 210, 255]);
        write_tile(&root, 1, 1, 1, 1, [40, 220, 60, 128]);
        let destination = root.join("roundtrip.tif");
        let mut checkpoint_count = 0;
        let stats = export_level0_tiff(
            &root,
            &test_manifest(),
            &destination,
            32,
            &mut |done, height| {
                assert!(done <= height);
                checkpoint_count += 1;
                Ok(())
            },
            &mut || Ok(()),
        )
        .unwrap();
        let bytes = fs::read(&destination).unwrap();
        assert_eq!(&bytes[..4], b"II*\0");
        let decoded = image::open(&destination).unwrap().into_rgba8();
        assert_eq!(decoded.dimensions(), (513, 513));
        assert_eq!(decoded.get_pixel(5, 8).0, [5, 8, 200, 13]);
        assert_eq!(decoded.get_pixel(512, 200).0, [20, 30, 210, 255]);
        assert_eq!(decoded.get_pixel(200, 512).0, [0, 0, 0, 0]);
        assert_eq!(decoded.get_pixel(512, 512).0, [40, 220, 60, 128]);
        assert_eq!(stats["exportFormat"], "tiff");
        assert_eq!(stats["tiffVariant"], "classic");
        assert_eq!(stats["sampleFormat"], "RGBA8");
        assert_eq!(stats["alpha"], "unassociated");
        assert_eq!(checkpoint_count, 3 + 513);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cancellation_and_existing_destination_leave_no_owned_artifacts() {
        let root = test_dir();
        write_tile(&root, 0, 0, 512, 512, [1, 2, 3, 255]);
        write_tile(&root, 0, 1, 1, 512, [4, 5, 6, 255]);
        write_tile(&root, 1, 1, 1, 1, [7, 8, 9, 255]);
        let manifest = test_manifest();
        let cancelled = root.join("cancelled.tiff");
        let result = export_level0_tiff(
            &root,
            &manifest,
            &cancelled,
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
        assert!(!cancelled.exists());
        assert_eq!(
            fs::read_dir(&root)
                .unwrap()
                .filter_map(|e| e.ok())
                .filter(|e| e.file_name().to_string_lossy().starts_with(".tiff-export-"))
                .count(),
            0
        );

        let existing = root.join("existing.tif");
        fs::write(&existing, b"keep me").unwrap();
        let result = export_level0_tiff(
            &root,
            &manifest,
            &existing,
            32,
            &mut |_, _| Ok(()),
            &mut || Ok(()),
        );
        assert!(result.is_err());
        assert_eq!(fs::read(existing).unwrap(), b"keep me");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn duplicate_tiles_and_paths_outside_job_directory_are_rejected() {
        let root = test_dir();
        write_tile(&root, 0, 0, 512, 512, [1, 2, 3, 255]);
        write_tile(&root, 0, 1, 1, 512, [4, 5, 6, 255]);
        write_tile(&root, 1, 1, 1, 1, [7, 8, 9, 255]);
        let destination = root.join("invalid.tiff");

        let mut duplicate = test_manifest();
        let first_tile = duplicate["levels"][0]["occupied"][0].clone();
        duplicate["levels"][0]["occupied"]
            .as_array_mut()
            .unwrap()
            .push(first_tile);
        assert!(export_level0_tiff(
            &root,
            &duplicate,
            &destination,
            32,
            &mut |_, _| Ok(()),
            &mut || Ok(()),
        )
        .is_err());

        let mut escaped = test_manifest();
        escaped["levels"][0]["occupied"][0]["path"] = json!("../../outside.png");
        assert!(export_level0_tiff(
            &root,
            &escaped,
            &destination,
            32,
            &mut |_, _| Ok(()),
            &mut || Ok(()),
        )
        .is_err());
        assert!(!destination.exists());
        fs::remove_dir_all(root).unwrap();
    }

    struct SparseSeekWriter {
        position: u64,
        len: u64,
        small_writes: BTreeMap<u64, Vec<u8>>,
    }

    impl Write for SparseSeekWriter {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            if bytes.len() <= 64 {
                self.small_writes.insert(self.position, bytes.to_vec());
            }
            self.position += bytes.len() as u64;
            self.len = self.len.max(self.position);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    impl Seek for SparseSeekWriter {
        fn seek(&mut self, from: SeekFrom) -> std::io::Result<u64> {
            self.position = match from {
                SeekFrom::Start(position) => position,
                SeekFrom::Current(offset) => self
                    .position
                    .checked_add_signed(offset)
                    .ok_or_else(|| std::io::Error::other("seek before start"))?,
                SeekFrom::End(offset) => self
                    .len
                    .checked_add_signed(offset)
                    .ok_or_else(|| std::io::Error::other("seek before start"))?,
            };
            Ok(self.position)
        }
    }

    fn sparse_bytes(writes: &BTreeMap<u64, Vec<u8>>, offset: u64, length: usize) -> Vec<u8> {
        let mut bytes = vec![0; length];
        for (write_offset, write_bytes) in writes {
            let start = (*write_offset).max(offset);
            let end = (write_offset + write_bytes.len() as u64).min(offset + length as u64);
            if start < end {
                let source_start = (start - write_offset) as usize;
                let destination_start = (start - offset) as usize;
                let count = (end - start) as usize;
                bytes[destination_start..destination_start + count]
                    .copy_from_slice(&write_bytes[source_start..source_start + count]);
            }
        }
        bytes
    }

    #[test]
    fn bigtiff_encoder_writes_ifd_pointer_above_u32_without_allocating_file() {
        let width = 131_072;
        let height = 8_192;
        let rows = 2;
        let mut sparse = SparseSeekWriter {
            position: 0,
            len: 0,
            small_writes: BTreeMap::new(),
        };
        {
            let mut encoder = TiffEncoder::new_big(&mut sparse).unwrap();
            let mut image = encoder.new_image::<RGB8>(width, height).unwrap();
            image
                .extra_samples(&[ExtraSamples::UnassociatedAlpha])
                .unwrap();
            image.rows_per_strip(rows).unwrap();
            let strip = vec![0u8; width as usize * 4 * rows as usize];
            for _ in 0..height / rows {
                image.write_strip(&strip).unwrap();
            }
            image.finish().unwrap();
        }
        assert!(sparse.len > u64::from(u32::MAX));
        assert_eq!(sparse_bytes(&sparse.small_writes, 0, 8), b"II+\0\x08\0\0\0");
        let ifd_pointer =
            u64::from_le_bytes(sparse_bytes(&sparse.small_writes, 8, 8).try_into().unwrap());
        assert!(ifd_pointer > u64::from(u32::MAX));
        assert!(sparse.small_writes.contains_key(&ifd_pointer));
    }
}
