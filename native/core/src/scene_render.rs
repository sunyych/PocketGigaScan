//! Bounded scene-mask support for tiled spherical rendering.
//!
//! Semantic masks stay in source-image coordinates on disk. Person components
//! are projected once into sparse output-row runs so every render tile sees
//! the same object owner; water masks are read through per-tile source windows.

use super::{sample_geometry, Source, TILE};
use crate::{fingerprint, Result};
use png::{BitDepth, ColorType, Decoder, Transformations};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, HashMap},
    fs::{self, File},
    io::{BufReader, BufWriter, Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
};

const SCENE_SCHEMA_VERSION: u64 = 1;
const SCENE_ALGORITHM_VERSION: u64 = 1;
const PERSON_THRESHOLD: u8 = 128;
const WATER_THRESHOLD: u8 = 128;
const PERSON_BUFFER_PX: u32 = 3;
const MASK_WINDOW_BYTES_CAP: u64 = 8 * 1024 * 1024;
const MAX_COMPONENT_RUNS: usize = 8_000_000;
// Projection can create one BTreeMap row node and one small Vec allocation
// per output sample in the worst case. Include container slack and the
// compressed runs that coexist briefly with the row map.
const PROJECTED_SAMPLE_PEAK_BYTES: u64 = 512;

#[derive(Clone, Debug)]
pub(crate) struct SceneIdentity {
    pub enabled: bool,
    pub protect_people: bool,
    pub smooth_water: bool,
    pub model_id: String,
    pub model_sha256: String,
    pub mask_sha256s: Vec<String>,
}

impl SceneIdentity {
    pub(crate) fn json(&self) -> Value {
        if !self.enabled {
            return Value::Null;
        }
        json!({
            "protectPeople": self.protect_people,
            "smoothWater": self.smooth_water,
            "semanticSchemaVersion": SCENE_SCHEMA_VERSION,
            "semanticAlgorithmVersion": SCENE_ALGORITHM_VERSION,
            "modelId": self.model_id,
            "modelSha256": self.model_sha256,
            "maskSha256s": self.mask_sha256s,
        })
    }
}

#[derive(Clone, Copy, Debug)]
struct MaskSourceDescriptor {
    width: u32,
    height: u32,
}

#[derive(Clone, Debug)]
struct SourceRun {
    y: u32,
    x0: u32,
    x1: u32,
    component: usize,
    confidence_sum: u64,
}

#[derive(Clone, Debug)]
struct Component {
    bounds: [u32; 4],
    area: u64,
    confidence: f32,
    projected_coverage: f32,
    sharpness: f64,
    truncated: bool,
    projected_bounds: [i32; 4],
    projected_runs: Vec<OutputRun>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct OutputRun {
    y: i32,
    x0: i32,
    x1: i32,
}

#[derive(Clone, Debug)]
struct PersonGroup {
    preferred_source: usize,
    source_candidates: Vec<usize>,
    runs: Vec<OutputRun>,
    bounds: [i32; 4],
}

#[derive(Clone, Debug)]
struct MaskSource {
    descriptor: MaskSourceDescriptor,
    raw_path: PathBuf,
    components: Vec<Component>,
}

#[derive(Clone, Debug)]
pub(crate) struct ScenePlan {
    pub(crate) identity: SceneIdentity,
    sources: Vec<MaskSource>,
    person_groups: Vec<PersonGroup>,
    output_width: u32,
    output_height: u32,
    mask_window_bytes: u64,
    projected_run_bytes: u64,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct SceneTile {
    /// Per output pixel, the globally selected source for protected people.
    pub(crate) person_owner: Vec<Option<usize>>,
    /// Per output pixel, whether at least one valid water mask is present.
    pub(crate) water_count: Vec<u32>,
    /// Feather override strength after requiring every valid source to be
    /// confidently classified as water. Zero keeps the selected base mode.
    pub(crate) water_blend: Vec<u8>,
    pub(crate) object_fallbacks: u64,
    pub(crate) person_pixels: u64,
    pub(crate) water_pixels: u64,
}

pub(crate) fn identity(
    layout: &Value,
    sources: &[Source],
    protect_people: bool,
    smooth_water: bool,
) -> Result<SceneIdentity> {
    let enabled = protect_people || smooth_water;
    if !enabled {
        return Ok(SceneIdentity {
            enabled: false,
            protect_people,
            smooth_water,
            model_id: String::new(),
            model_sha256: String::new(),
            mask_sha256s: Vec::new(),
        });
    }
    let analysis = &layout["semanticAnalysis"];
    if analysis["schemaVersion"].as_u64() != Some(SCENE_SCHEMA_VERSION)
        || analysis["algorithmVersion"].as_u64() != Some(SCENE_ALGORITHM_VERSION)
    {
        return Err(crate::Error::Invalid(
            "unsupported semanticAnalysis schema or algorithm version".into(),
        ));
    }
    let model_id = analysis["modelId"]
        .as_str()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| crate::Error::Invalid("semanticAnalysis.modelId is required".into()))?
        .to_owned();
    let model_sha256 = analysis["modelSha256"]
        .as_str()
        .filter(|value| value.len() == 64)
        .ok_or_else(|| crate::Error::Invalid("semanticAnalysis.modelSha256 is invalid".into()))?
        .to_owned();
    let descriptors = analysis["sources"]
        .as_array()
        .ok_or_else(|| crate::Error::Invalid("semanticAnalysis.sources must be an array".into()))?;
    if descriptors.len() != sources.len() {
        return Err(crate::Error::Invalid(
            "semanticAnalysis source count does not match layout tiles".into(),
        ));
    }
    let resolved_descriptors = descriptors_for_sources(descriptors, sources)?;
    let mut mask_sha256s = Vec::with_capacity(sources.len());
    for (source, descriptor) in sources.iter().zip(resolved_descriptors) {
        let path = descriptor["path"]
            .as_str()
            .ok_or_else(|| crate::Error::Invalid("semantic mask source path is required".into()))?;
        let width = u32::try_from(descriptor["width"].as_u64().unwrap_or(0)).unwrap_or(0);
        let height = u32::try_from(descriptor["height"].as_u64().unwrap_or(0)).unwrap_or(0);
        let mask_path = descriptor["maskPath"].as_str().ok_or_else(|| {
            crate::Error::Invalid("semantic maskPath is required for every source".into())
        })?;
        let expected_hash = descriptor["maskSha256"].as_str().ok_or_else(|| {
            crate::Error::Invalid("semantic maskSha256 is required for every source".into())
        })?;
        if !Path::new(path).is_absolute()
            || width != source.width
            || height != source.height
            || !Path::new(mask_path).is_absolute()
            || expected_hash.len() != 64
        {
            return Err(crate::Error::Invalid(
                "semantic mask source identity does not match the spherical layout".into(),
            ));
        }
        let mask_path = PathBuf::from(mask_path);
        let actual_hash = fingerprint::sha256_file(&mask_path).map_err(|error| {
            crate::Error::Invalid(format!(
                "could not hash semantic mask {}: {error}",
                mask_path.display()
            ))
        })?;
        if actual_hash != expected_hash {
            return Err(crate::Error::Invalid(format!(
                "semantic mask hash mismatch for {}",
                mask_path.display()
            )));
        }
        mask_sha256s.push(actual_hash);
    }
    Ok(SceneIdentity {
        enabled,
        protect_people,
        smooth_water,
        model_id,
        model_sha256,
        mask_sha256s,
    })
}

/// Match source descriptors by asking the filesystem to canonicalize both
/// paths. On Windows this normalizes ordinary absolute paths and `\\?\`
/// extended paths according to the real filesystem rules, including casing.
/// Require exactly one descriptor so normalization cannot silently make an
/// ambiguous manifest acceptable.
fn descriptors_for_sources<'a>(
    descriptors: &'a [Value],
    sources: &[Source],
) -> Result<Vec<&'a Value>> {
    if descriptors.len() != sources.len() {
        return Err(crate::Error::Invalid(
            "semanticAnalysis source count does not match layout tiles".into(),
        ));
    }
    let mut by_path = HashMap::<PathBuf, &'a Value>::with_capacity(descriptors.len());
    for descriptor in descriptors {
        let path = descriptor["path"]
            .as_str()
            .ok_or_else(|| crate::Error::Invalid("semantic mask source path is required".into()))?;
        let path = Path::new(path);
        if !path.is_absolute() {
            return Err(crate::Error::Invalid(
                "semantic mask source paths must be absolute".into(),
            ));
        }
        let canonical = path.canonicalize().map_err(|error| {
            crate::Error::Invalid(format!(
                "could not canonicalize semantic source descriptor {}: {error}",
                path.display()
            ))
        })?;
        if by_path.insert(canonical, descriptor).is_some() {
            return Err(crate::Error::Invalid(format!(
                "semantic source path matches multiple descriptors: {}",
                path.display()
            )));
        }
    }
    let mut resolved = Vec::with_capacity(sources.len());
    for source in sources {
        let canonical = source.path.canonicalize().map_err(|error| {
            crate::Error::Invalid(format!(
                "could not canonicalize semantic source {}: {error}",
                source.path.display()
            ))
        })?;
        let descriptor = by_path.remove(&canonical).ok_or_else(|| {
            crate::Error::Invalid(format!(
                "semantic mask is missing for source {}",
                source.path.display()
            ))
        })?;
        resolved.push(descriptor);
    }
    if !by_path.is_empty() {
        return Err(crate::Error::Invalid(
            "semanticAnalysis contains unmatched source descriptors".into(),
        ));
    }
    Ok(resolved)
}

pub(crate) fn prepare(
    layout: &Value,
    sources: &[Source],
    identity: SceneIdentity,
    output: &Path,
    bounds: [f64; 4],
    output_width: u32,
    output_height: u32,
    memory_budget_bytes: u64,
    mut checkpoint: impl FnMut() -> bool,
) -> Result<Option<ScenePlan>> {
    if !identity.enabled {
        return Ok(None);
    }
    let descriptors = layout["semanticAnalysis"]["sources"]
        .as_array()
        .expect("identity validated semantic source list");
    let resolved_descriptors = descriptors_for_sources(descriptors, sources)?;
    let raw_dir = output.join(".scene-mask-cache");
    fs::create_dir_all(&raw_dir)?;
    let mut mask_sources = Vec::with_capacity(sources.len());
    let mut projected_run_bytes = 0u64;
    let mut retained_component_count = 0u64;
    for (index, (source, descriptor)) in sources
        .iter()
        .zip(resolved_descriptors.into_iter())
        .enumerate()
    {
        if !checkpoint() {
            return Err(crate::Error::Cancelled);
        }
        let mask_path = PathBuf::from(descriptor["maskPath"].as_str().unwrap());
        let raw_path = raw_dir.join(format!("{}.luma8", identity.mask_sha256s[index]));
        let max_run_count = MAX_COMPONENT_RUNS
            .min((memory_budget_bytes / 4 / std::mem::size_of::<SourceRun>() as u64) as usize);
        let (mut runs, components) = prepare_raw_mask(
            &mask_path,
            &raw_path,
            source.width,
            source.height,
            identity.protect_people,
            max_run_count,
            &mut checkpoint,
        )?;
        retained_component_count = retained_component_count.saturating_add(components.len() as u64);
        let source_index_bytes = retained_component_count
            .saturating_mul(std::mem::size_of::<Component>() as u64)
            .saturating_add(
                (runs.len() as u64).saturating_mul(std::mem::size_of::<SourceRun>() as u64),
            )
            .saturating_add(
                (components.len() as u64 + 1).saturating_mul(std::mem::size_of::<usize>() as u64),
            );
        if source_index_bytes > memory_budget_bytes / 3 {
            return Err(crate::Error::Invalid(format!(
                "semantic component directory exceeds its bounded memory budget: {source_index_bytes} bytes"
            )));
        }
        let source_run_count = runs.len();
        runs.sort_unstable_by_key(|run| run.component);
        let mut component_offsets = vec![0usize; components.len() + 1];
        for (run_index, run) in runs.iter().enumerate() {
            component_offsets[run.component + 1] = run_index + 1;
        }
        for component_index in 1..component_offsets.len() {
            if component_offsets[component_index] == 0 {
                component_offsets[component_index] = component_offsets[component_index - 1];
            }
        }
        let mut components = components;
        if identity.protect_people {
            for (component_index, component) in components.iter_mut().enumerate() {
                if !checkpoint() {
                    return Err(crate::Error::Cancelled);
                }
                let (projected_runs, projected_samples) = project_component_runs(
                    source,
                    &runs[component_offsets[component_index]
                        ..component_offsets[component_index + 1]],
                    component,
                    bounds,
                    output_width,
                    output_height,
                    (memory_budget_bytes / 4 / PROJECTED_SAMPLE_PEAK_BYTES).min(usize::MAX as u64)
                        as usize,
                    &mut checkpoint,
                )?;
                component.projected_runs = projected_runs;
                component.projected_coverage = (projected_samples as f64
                    / component.area.max(1) as f64)
                    .clamp(0.0, 1.0) as f32;
                if let Some(bounds) = run_bounds(&component.projected_runs) {
                    component.projected_bounds = bounds;
                } else {
                    component.projected_bounds = [0, 0, -1, -1];
                }
                projected_run_bytes = projected_run_bytes.saturating_add(
                    (component.projected_runs.capacity() * std::mem::size_of::<OutputRun>()) as u64,
                );
                let sparse_bytes = retained_component_count
                    .saturating_mul(std::mem::size_of::<Component>() as u64)
                    .saturating_add(
                        (source_run_count as u64)
                            .saturating_mul(std::mem::size_of::<SourceRun>() as u64)
                            .saturating_add(projected_run_bytes),
                    );
                if sparse_bytes > memory_budget_bytes / 3 {
                    return Err(crate::Error::Invalid(format!(
                        "semantic sparse person directory exceeds its bounded render budget: {sparse_bytes} bytes"
                    )));
                }
            }
            let quality_map_bytes = (super::SourceQualityMap::byte_len()
                + std::mem::size_of::<super::SourceQualityMap>() as u64
                + std::mem::size_of::<std::sync::Arc<super::SourceQualityMap>>() as u64)
                .saturating_mul(sources.len() as u64);
            let decode_peak = u64::from(source.width)
                .saturating_mul(u64::from(source.height))
                .saturating_mul(8);
            let prepass_bytes = retained_component_count
                .saturating_mul(std::mem::size_of::<Component>() as u64)
                .saturating_add(
                    (source_run_count as u64)
                        .saturating_mul(std::mem::size_of::<SourceRun>() as u64)
                        .saturating_add(projected_run_bytes)
                        .saturating_add(quality_map_bytes)
                        .saturating_add(decode_peak),
                );
            if prepass_bytes > memory_budget_bytes / 2 {
                return Err(crate::Error::Invalid(format!(
                    "semantic person quality prepass needs {prepass_bytes} bounded bytes, above its memory reserve"
                )));
            }
            let mut quality = source.quality_map.lock().expect("source quality map lock");
            if quality.is_none() {
                let image = image::open(&source.path)?.into_rgba8();
                *quality = Some(std::sync::Arc::new(super::SourceQualityMap::from_image(
                    &image,
                )));
            }
            let quality = quality.as_ref().expect("quality map prepared");
            for (component_index, component) in components.iter_mut().enumerate() {
                let component_runs = &runs
                    [component_offsets[component_index]..component_offsets[component_index + 1]];
                let (center_x, center_y) = component_sample_point(component_runs, component);
                component.sharpness =
                    quality.sharpness(source.width, source.height, center_x, center_y);
            }
        }
        mask_sources.push(MaskSource {
            descriptor: MaskSourceDescriptor {
                width: source.width,
                height: source.height,
            },
            raw_path,
            components,
        });
    }
    let person_groups = if identity.protect_people {
        group_components(
            &mask_sources,
            sources,
            output_width,
            output_height,
            memory_budget_bytes,
            &mut checkpoint,
        )?
    } else {
        Vec::new()
    };
    // Components retain their projected runs. Groups retain only the merged
    // union; group construction accounts for its temporary reference array.
    projected_run_bytes = projected_run_bytes.saturating_add(
        person_groups
            .iter()
            .map(|group| (group.runs.capacity() * std::mem::size_of::<OutputRun>()) as u64)
            .sum::<u64>(),
    );
    let max_mask_bytes = mask_sources
        .iter()
        .map(|mask| u64::from(mask.descriptor.width) * u64::from(mask.descriptor.height) * 2)
        .max()
        .unwrap_or(0);
    let mask_window_bytes = max_mask_bytes.min(MASK_WINDOW_BYTES_CAP);
    let component_bytes = projected_run_bytes.saturating_add(
        retained_component_count.saturating_mul(std::mem::size_of::<Component>() as u64),
    );
    let scene_scratch_bytes = (TILE as u64 + 2 * PERSON_BUFFER_PX as u64)
        .pow(2)
        .saturating_mul(if identity.protect_people {
            4 * std::mem::size_of::<Option<usize>>() as u64
        } else {
            0
        })
        .saturating_add(
            (TILE as u64)
                .pow(2)
                .saturating_mul(if identity.smooth_water {
                    (2 * std::mem::size_of::<u32>() + 2) as u64
                } else {
                    0
                }),
        );
    if component_bytes
        .saturating_add(mask_window_bytes)
        .saturating_add(scene_scratch_bytes)
        > memory_budget_bytes / 2
    {
        return Err(crate::Error::Invalid(format!(
            "semantic masks need {} bytes for bounded components and one mask window, exceeding the scene-render reserve",
            component_bytes.saturating_add(mask_window_bytes).saturating_add(scene_scratch_bytes)
        )));
    }
    Ok(Some(ScenePlan {
        identity,
        sources: mask_sources,
        person_groups,
        output_width,
        output_height,
        mask_window_bytes,
        projected_run_bytes,
    }))
}

fn prepare_raw_mask(
    mask_path: &Path,
    raw_path: &Path,
    width: u32,
    height: u32,
    include_person: bool,
    max_runs: usize,
    checkpoint: &mut impl FnMut() -> bool,
) -> Result<(Vec<SourceRun>, Vec<Component>)> {
    let expected_bytes = u64::from(width)
        .checked_mul(u64::from(height))
        .and_then(|pixels| pixels.checked_mul(2))
        .ok_or_else(|| crate::Error::Invalid("semantic mask size overflows".into()))?;
    let raw_hash_path = raw_path.with_extension("luma8.sha256");
    if raw_path.is_file()
        && fs::metadata(raw_path)?.len() == expected_bytes
        && fs::read_to_string(&raw_hash_path)
            .ok()
            .is_some_and(|saved| {
                fingerprint::sha256_file(raw_path).ok().as_deref() == Some(saved.trim())
            })
    {
        return scan_raw_person_runs(
            raw_path,
            width,
            height,
            include_person,
            max_runs,
            checkpoint,
        );
    }
    let file = File::open(mask_path)?;
    let mut decoder = Decoder::new(BufReader::new(file));
    decoder.set_transformations(Transformations::IDENTITY);
    let mut reader = decoder.read_info().map_err(|error| {
        crate::Error::Invalid(format!(
            "invalid semantic mask {}: {error}",
            mask_path.display()
        ))
    })?;
    let info = reader.info();
    if info.width != width
        || info.height != height
        || info.color_type != ColorType::GrayscaleAlpha
        || info.bit_depth != BitDepth::Eight
        || info.interlaced
    {
        return Err(crate::Error::Invalid(format!(
            "semantic mask must be non-interlaced {}x{} LumaA8: {}",
            width,
            height,
            mask_path.display()
        )));
    }
    let temp_path = raw_path.with_extension(format!("luma8.tmp-{}", std::process::id()));
    let mut temp_guard = TempMaskFile {
        path: temp_path.clone(),
        committed: false,
    };
    let out = File::create(&temp_path)?;
    let mut out = BufWriter::new(out);
    let mut runs = Vec::new();
    let mut previous = Vec::<usize>::new();
    let mut sets = DisjointSets::default();
    let mut row_index = 0u32;
    while let Some(row) = reader.next_row().map_err(|error| {
        crate::Error::Invalid(format!("could not decode semantic mask row: {error}"))
    })? {
        if row_index % 64 == 0 && !checkpoint() {
            return Err(crate::Error::Cancelled);
        }
        let bytes = row.data();
        out.write_all(bytes)?;
        let current = if include_person {
            append_row_runs(
                bytes, width, row_index, &mut runs, &mut sets, max_runs, checkpoint,
            )?
        } else {
            Vec::new()
        };
        let mut left = 0usize;
        for &current_index in &current {
            let run = &runs[current_index];
            while left < previous.len() && runs[previous[left]].x1.saturating_add(1) < run.x0 {
                left += 1;
            }
            let mut prev = left;
            while prev < previous.len() && runs[previous[prev]].x0 <= run.x1.saturating_add(1) {
                sets.union(current_index, previous[prev]);
                prev += 1;
            }
        }
        previous = current;
        row_index += 1;
    }
    if row_index != height {
        return Err(crate::Error::Invalid(
            "semantic mask ended before its declared height".into(),
        ));
    }
    out.flush()?;
    drop(out);
    if raw_path.exists() {
        fs::remove_file(raw_path)?;
    }
    fs::rename(&temp_path, raw_path)?;
    temp_guard.committed = true;
    let raw_hash = fingerprint::sha256_file(raw_path)?;
    fs::write(raw_hash_path, raw_hash)?;
    components_from_runs(&mut runs, &mut sets, width, height)
}

struct TempMaskFile {
    path: PathBuf,
    committed: bool,
}

impl Drop for TempMaskFile {
    fn drop(&mut self) {
        if !self.committed {
            let _ = fs::remove_file(&self.path);
        }
    }
}

fn scan_raw_person_runs(
    raw_path: &Path,
    width: u32,
    height: u32,
    include_person: bool,
    max_runs: usize,
    checkpoint: &mut impl FnMut() -> bool,
) -> Result<(Vec<SourceRun>, Vec<Component>)> {
    if !include_person {
        return Ok((Vec::new(), Vec::new()));
    }
    let mut file = BufReader::new(File::open(raw_path)?);
    let mut runs = Vec::new();
    let mut previous = Vec::<usize>::new();
    let mut sets = DisjointSets::default();
    let mut row = vec![0u8; width as usize * 2];
    for y in 0..height {
        if y % 64 == 0 && !checkpoint() {
            return Err(crate::Error::Cancelled);
        }
        file.read_exact(&mut row)?;
        let current = append_row_runs(&row, width, y, &mut runs, &mut sets, max_runs, checkpoint)?;
        let mut left = 0usize;
        for &current_index in &current {
            let run = &runs[current_index];
            while left < previous.len() && runs[previous[left]].x1.saturating_add(1) < run.x0 {
                left += 1;
            }
            let mut prev = left;
            while prev < previous.len() && runs[previous[prev]].x0 <= run.x1.saturating_add(1) {
                sets.union(current_index, previous[prev]);
                prev += 1;
            }
        }
        previous = current;
    }
    components_from_runs(&mut runs, &mut sets, width, height)
}

fn append_row_runs(
    row: &[u8],
    width: u32,
    y: u32,
    runs: &mut Vec<SourceRun>,
    sets: &mut DisjointSets,
    max_runs: usize,
    checkpoint: &mut impl FnMut() -> bool,
) -> Result<Vec<usize>> {
    let mut current = Vec::new();
    let mut x = 0u32;
    while x < width {
        if x % 4096 == 0 && !checkpoint() {
            return Err(crate::Error::Cancelled);
        }
        let confidence = row[x as usize * 2];
        if confidence < PERSON_THRESHOLD {
            x += 1;
            continue;
        }
        let x0 = x;
        let mut sum = 0u64;
        while x < width && row[x as usize * 2] >= PERSON_THRESHOLD {
            sum += u64::from(row[x as usize * 2]);
            x += 1;
        }
        if runs.len() >= max_runs {
            return Err(crate::Error::Invalid(
                "semantic person mask exceeds the bounded component-run limit".into(),
            ));
        }
        let index = runs.len();
        runs.push(SourceRun {
            y,
            x0,
            x1: x - 1,
            component: index,
            confidence_sum: sum,
        });
        sets.push();
        current.push(index);
    }
    Ok(current)
}

fn components_from_runs(
    runs: &mut [SourceRun],
    sets: &mut DisjointSets,
    width: u32,
    height: u32,
) -> Result<(Vec<SourceRun>, Vec<Component>)> {
    // Root IDs are assigned from scan-order runs. Ordered traversal keeps the
    // component indices (and every downstream tie) stable across processes.
    let mut aggregates = BTreeMap::<usize, Component>::new();
    for index in 0..runs.len() {
        let root = sets.find(index);
        runs[index].component = root;
        let run = &runs[index];
        let entry = aggregates.entry(root).or_insert(Component {
            bounds: [run.x0, run.y, run.x1, run.y],
            area: 0,
            confidence: 0.0,
            projected_coverage: 0.0,
            sharpness: 0.0,
            truncated: false,
            projected_bounds: [0, 0, -1, -1],
            projected_runs: Vec::new(),
        });
        entry.bounds[0] = entry.bounds[0].min(run.x0);
        entry.bounds[1] = entry.bounds[1].min(run.y);
        entry.bounds[2] = entry.bounds[2].max(run.x1);
        entry.bounds[3] = entry.bounds[3].max(run.y);
        entry.area += u64::from(run.x1 - run.x0 + 1);
        entry.confidence += run.confidence_sum as f32;
    }
    let mut components = Vec::with_capacity(aggregates.len());
    let mut root_to_component = HashMap::with_capacity(aggregates.len());
    for (root, mut component) in aggregates {
        component.confidence = if component.area == 0 {
            0.0
        } else {
            (component.confidence / component.area as f32) / 255.0
        };
        component.truncated = component.bounds[0] == 0
            || component.bounds[1] == 0
            || component.bounds[2] + 1 >= width
            || component.bounds[3] + 1 >= height;
        root_to_component.insert(root, components.len());
        components.push(component);
    }
    for run in runs.iter_mut() {
        run.component = *root_to_component.get(&run.component).ok_or_else(|| {
            crate::Error::Invalid("semantic component index is inconsistent".into())
        })?;
    }
    Ok((runs.to_vec(), components))
}

#[derive(Default)]
struct DisjointSets {
    parent: Vec<usize>,
    rank: Vec<u8>,
}

impl DisjointSets {
    fn push(&mut self) {
        let index = self.parent.len();
        self.parent.push(index);
        self.rank.push(0);
    }

    fn find(&mut self, value: usize) -> usize {
        if self.parent[value] != value {
            self.parent[value] = self.find(self.parent[value]);
        }
        self.parent[value]
    }

    fn union(&mut self, left: usize, right: usize) {
        let mut left = self.find(left);
        let mut right = self.find(right);
        if left == right {
            return;
        }
        if self.rank[left] < self.rank[right] {
            std::mem::swap(&mut left, &mut right);
        }
        self.parent[right] = left;
        if self.rank[left] == self.rank[right] {
            self.rank[left] = self.rank[left].saturating_add(1);
        }
    }
}

fn project_component_runs(
    source: &Source,
    source_runs: &[SourceRun],
    component: &Component,
    bounds: [f64; 4],
    width: u32,
    height: u32,
    max_scratch_samples: usize,
    checkpoint: &mut impl FnMut() -> bool,
) -> Result<(Vec<OutputRun>, usize)> {
    let mut rows = BTreeMap::<i32, Vec<i32>>::new();
    let mut sample_count = 0usize;
    for (run_index, run) in source_runs.iter().enumerate() {
        if run_index % 256 == 0 && !checkpoint() {
            return Err(crate::Error::Cancelled);
        }
        if run.y < component.bounds[1] || run.y > component.bounds[3] {
            continue;
        }
        for (offset, x) in (run.x0..=run.x1).enumerate() {
            if offset % 4096 == 0 && !checkpoint() {
                return Err(crate::Error::Cancelled);
            }
            if let Some((out_x, out_y)) =
                source_pixel_to_output(source, x as f64, run.y as f64, bounds, width, height)
            {
                rows.entry(out_y).or_default().push(out_x);
                sample_count += 1;
                if sample_count > max_scratch_samples {
                    return Err(crate::Error::Invalid(
                        "one projected person component exceeds the bounded scratch-memory budget"
                            .into(),
                    ));
                }
            }
        }
    }
    Ok((compress_output_points(rows), sample_count))
}

fn source_pixel_to_output(
    source: &Source,
    x: f64,
    y: f64,
    bounds: [f64; 4],
    width: u32,
    height: u32,
) -> Option<(i32, i32)> {
    let (x, y) = if let Some(warp) = source.source_plane_warp.as_ref() {
        crate::texture_warp::source_to_corrected(warp, source.width, source.height, x, y)?
    } else {
        (x, y)
    };
    let camera = [
        (x - source.cx) / source.fx,
        -(y - source.cy) / source.fy,
        1.0,
    ];
    let m = source.camera_to_world;
    let world = [
        m[0] * camera[0] + m[1] * camera[1] + m[2],
        m[3] * camera[0] + m[4] * camera[1] + m[5],
        m[6] * camera[0] + m[7] * camera[1] + m[8],
    ];
    let norm = world[0].hypot(world[1]).hypot(world[2]);
    if !norm.is_finite() || norm <= 0.0 {
        return None;
    }
    let yaw = world[0].atan2(world[2]);
    let pitch = (world[1] / norm).clamp(-1.0, 1.0).asin();
    if yaw < bounds[0] || yaw > bounds[1] || pitch < bounds[2] || pitch > bounds[3] {
        return None;
    }
    Some((
        (((yaw - bounds[0]) / (bounds[1] - bounds[0]) * f64::from(width)).floor() as i32)
            .clamp(0, width as i32 - 1),
        (((bounds[3] - pitch) / (bounds[3] - bounds[2]) * f64::from(height)).floor() as i32)
            .clamp(0, height as i32 - 1),
    ))
}

fn compress_output_points(mut rows: BTreeMap<i32, Vec<i32>>) -> Vec<OutputRun> {
    let mut runs = Vec::new();
    for (y, xs) in rows.iter_mut() {
        xs.sort_unstable();
        xs.dedup();
        let Some(&first) = xs.first() else { continue };
        let mut x0 = first;
        let mut x1 = first;
        for &x in &xs[1..] {
            if x <= x1 + 1 {
                x1 = x;
            } else {
                runs.push(OutputRun { y: *y, x0, x1 });
                x0 = x;
                x1 = x;
            }
        }
        runs.push(OutputRun { y: *y, x0, x1 });
    }
    runs
}

fn merge_output_runs(mut runs: Vec<OutputRun>) -> Vec<OutputRun> {
    runs.sort_unstable_by_key(|run| (run.y, run.x0, run.x1));
    let mut merged: Vec<OutputRun> = Vec::with_capacity(runs.len());
    for run in runs {
        if let Some(last) = merged.last_mut() {
            if last.y == run.y && run.x0 <= last.x1.saturating_add(1) {
                last.x1 = last.x1.max(run.x1);
                continue;
            }
        }
        merged.push(run);
    }
    merged
}

fn run_bounds(runs: &[OutputRun]) -> Option<[i32; 4]> {
    let first = runs.first()?;
    Some(
        runs.iter()
            .fold([first.x0, first.y, first.x1, first.y], |mut bounds, run| {
                bounds[0] = bounds[0].min(run.x0);
                bounds[1] = bounds[1].min(run.y);
                bounds[2] = bounds[2].max(run.x1);
                bounds[3] = bounds[3].max(run.y);
                bounds
            }),
    )
}

fn component_sample_point(runs: &[SourceRun], component: &Component) -> (f64, f64) {
    let center_x = (f64::from(component.bounds[0]) + f64::from(component.bounds[2])) * 0.5;
    let center_y = (f64::from(component.bounds[1]) + f64::from(component.bounds[3])) * 0.5;
    runs.iter()
        .map(|run| {
            let x = center_x.clamp(f64::from(run.x0), f64::from(run.x1));
            let y = f64::from(run.y);
            let distance = (x - center_x).powi(2) + (y - center_y).powi(2);
            (distance, x, y)
        })
        .min_by(|left, right| left.0.total_cmp(&right.0))
        .map(|(_, x, y)| (x, y))
        .unwrap_or((center_x, center_y))
}

fn group_components(
    masks: &[MaskSource],
    sources: &[Source],
    width: u32,
    height: u32,
    memory_budget_bytes: u64,
    checkpoint: &mut impl FnMut() -> bool,
) -> Result<Vec<PersonGroup>> {
    let mut flat = Vec::<(usize, usize, &Component)>::new();
    for (source_index, mask) in masks.iter().enumerate() {
        for (component_index, component) in mask.components.iter().enumerate() {
            if !component.projected_runs.is_empty() {
                flat.push((source_index, component_index, component));
            }
        }
    }
    flat.sort_by(|left, right| {
        left.2.projected_bounds[0]
            .cmp(&right.2.projected_bounds[0])
            .then_with(|| left.2.projected_bounds[1].cmp(&right.2.projected_bounds[1]))
            .then_with(|| sources[left.0].path.cmp(&sources[right.0].path))
            .then_with(|| left.1.cmp(&right.1))
    });
    let mut parent: Vec<usize> = (0..flat.len()).collect();
    let mut pair_checks = 0usize;
    for left in 0..flat.len() {
        if !checkpoint() {
            return Err(crate::Error::Cancelled);
        }
        for right in left + 1..flat.len() {
            if flat[right].2.projected_bounds[0]
                > flat[left].2.projected_bounds[2].saturating_add(3)
            {
                break;
            }
            pair_checks += 1;
            if pair_checks % 256 == 0 && !checkpoint() {
                return Err(crate::Error::Cancelled);
            }
            if flat[left].0 == flat[right].0
                || !bounds_overlap(
                    flat[left].2.projected_bounds,
                    flat[right].2.projected_bounds,
                    3,
                )
            {
                continue;
            }
            if projected_runs_overlap(&flat[left].2.projected_runs, &flat[right].2.projected_runs) {
                union_indices(&mut parent, left, right);
            }
        }
    }
    let mut groups = BTreeMap::<usize, Vec<usize>>::new();
    for index in 0..flat.len() {
        let root = find_index(&mut parent, index);
        groups.entry(root).or_default().push(index);
    }
    let group_count = groups.len();
    let mut result: Vec<PersonGroup> = Vec::with_capacity(group_count);
    let retained_projected_capacity = flat
        .iter()
        .map(|(_, _, component)| component.projected_runs.capacity() as u64)
        .sum::<u64>();
    let grouping_metadata_bytes = (flat.len() as u64)
        .saturating_mul(128) // member vectors, allocator slack, and per-component group bookkeeping
        .saturating_add((group_count as u64).saturating_mul(256)); // BTree nodes and map/vector headers
    let mut grouping_scratch_peak =
        (flat.capacity() * std::mem::size_of::<(usize, usize, &Component)>()) as u64
            + (parent.capacity() * std::mem::size_of::<usize>()) as u64
            + grouping_metadata_bytes
            + (result.capacity() * std::mem::size_of::<PersonGroup>()) as u64;
    for members in groups.into_values() {
        let preferred_source = members
            .iter()
            .copied()
            .max_by(|&left, &right| {
                component_rank(
                    &flat[left].2,
                    &sources[flat[left].0],
                    &flat[right].2,
                    &sources[flat[right].0],
                )
            })
            .map(|index| flat[index].0)
            .unwrap_or(flat[members[0]].0);
        let member_run_count = members
            .iter()
            .map(|&index| flat[index].2.projected_runs.len())
            .sum::<usize>();
        let prior_group_bytes = result
            .iter()
            .map(|group| {
                (group.runs.capacity() * std::mem::size_of::<OutputRun>()
                    + group.source_candidates.capacity() * std::mem::size_of::<usize>())
                    as u64
            })
            .sum::<u64>();
        let planned_scratch = (flat.capacity() * std::mem::size_of::<(usize, usize, &Component)>())
            as u64
            + (parent.capacity() * std::mem::size_of::<usize>()) as u64
            + grouping_metadata_bytes
            + (result.capacity() * std::mem::size_of::<PersonGroup>()) as u64
            + retained_projected_capacity * std::mem::size_of::<OutputRun>() as u64
            + (member_run_count
                * (std::mem::size_of::<&OutputRun>() + std::mem::size_of::<OutputRun>()))
                as u64
            + prior_group_bytes
            + (members.capacity() * std::mem::size_of::<usize>()) as u64;
        if planned_scratch > memory_budget_bytes / 3 {
            return Err(crate::Error::Invalid(format!(
                "semantic person grouping needs {planned_scratch} bounded scratch bytes"
            )));
        }
        // Sort references to already-sorted component runs, then emit the
        // union directly. This avoids copying every run into a second input
        // Vec while retaining the original component directories.
        let mut ordered_runs: Vec<&OutputRun> = Vec::with_capacity(member_run_count);
        for &index in &members {
            ordered_runs.extend(flat[index].2.projected_runs.iter());
        }
        ordered_runs.sort_unstable_by_key(|run| (run.y, run.x0, run.x1));
        let mut runs = Vec::<OutputRun>::with_capacity(ordered_runs.len());
        for run in ordered_runs.iter() {
            if let Some(last) = runs.last_mut() {
                if last.y == run.y && run.x0 <= last.x1.saturating_add(1) {
                    last.x1 = last.x1.max(run.x1);
                    continue;
                }
            }
            runs.push(**run);
        }
        let Some(mut bounds) = run_bounds(&runs) else {
            continue;
        };
        bounds[0] = (bounds[0] - PERSON_BUFFER_PX as i32).max(0);
        bounds[1] = (bounds[1] - PERSON_BUFFER_PX as i32).max(0);
        bounds[2] = (bounds[2] + PERSON_BUFFER_PX as i32).min(width as i32 - 1);
        bounds[3] = (bounds[3] + PERSON_BUFFER_PX as i32).min(height as i32 - 1);
        let mut source_candidates = members
            .iter()
            .map(|index| flat[*index].0)
            .collect::<Vec<_>>();
        source_candidates.sort_unstable();
        source_candidates.dedup();
        source_candidates.sort_by(|&left, &right| {
            let left_component = members
                .iter()
                .filter(|index| flat[**index].0 == left)
                .map(|index| &flat[*index].2)
                .max_by(|a, b| component_rank(a, &sources[left], b, &sources[left]));
            let right_component = members
                .iter()
                .filter(|index| flat[**index].0 == right)
                .map(|index| &flat[*index].2)
                .max_by(|a, b| component_rank(a, &sources[right], b, &sources[right]));
            match (left_component, right_component) {
                (Some(a), Some(b)) => {
                    component_rank(a, &sources[left], b, &sources[right]).reverse()
                }
                _ => left.cmp(&right),
            }
        });
        let preferred_source = source_candidates
            .first()
            .copied()
            .unwrap_or(preferred_source);
        let current_group_bytes = (runs.capacity() * std::mem::size_of::<OutputRun>()
            + source_candidates.capacity() * std::mem::size_of::<usize>())
            as u64;
        grouping_scratch_peak = grouping_scratch_peak.max(
            (flat.capacity() * std::mem::size_of::<(usize, usize, &Component)>()) as u64
                + (parent.capacity() * std::mem::size_of::<usize>()) as u64
                + grouping_metadata_bytes
                + (result.capacity() * std::mem::size_of::<PersonGroup>()) as u64
                + retained_projected_capacity * std::mem::size_of::<OutputRun>() as u64
                + (ordered_runs.capacity() * std::mem::size_of::<&OutputRun>()) as u64
                + prior_group_bytes
                + current_group_bytes,
        );
        if grouping_scratch_peak > memory_budget_bytes / 3 {
            return Err(crate::Error::Invalid(format!(
                "semantic person grouping needs {grouping_scratch_peak} bounded scratch bytes"
            )));
        }
        result.push(PersonGroup {
            preferred_source,
            source_candidates,
            runs,
            bounds,
        });
    }
    result.sort_by(|left, right| {
        (left.bounds[1], left.bounds[0])
            .cmp(&(right.bounds[1], right.bounds[0]))
            .then_with(|| {
                sources[left.preferred_source]
                    .path
                    .cmp(&sources[right.preferred_source].path)
            })
    });
    let group_capacity_bytes = result
        .iter()
        .map(|group| {
            (group.runs.capacity() * std::mem::size_of::<OutputRun>()
                + group.source_candidates.capacity() * std::mem::size_of::<usize>())
                as u64
        })
        .sum::<u64>();
    if grouping_scratch_peak.saturating_add(group_capacity_bytes) > memory_budget_bytes / 3 {
        return Err(crate::Error::Invalid(format!(
            "semantic person groups need {} bounded bytes",
            grouping_scratch_peak.saturating_add(group_capacity_bytes)
        )));
    }
    Ok(result)
}

fn component_rank(
    left: &Component,
    left_source: &Source,
    right: &Component,
    right_source: &Source,
) -> std::cmp::Ordering {
    // Full silhouettes with stronger geometric projection win first, then
    // confidence and local image sharpness. File path resolves exact ties.
    (!left.truncated)
        .cmp(&(!right.truncated))
        .then_with(|| left.projected_coverage.total_cmp(&right.projected_coverage))
        .then_with(|| left.confidence.total_cmp(&right.confidence))
        .then_with(|| left.sharpness.total_cmp(&right.sharpness))
        .then_with(|| left_source.path.cmp(&right_source.path))
}

fn bounds_overlap(left: [i32; 4], right: [i32; 4], padding: i32) -> bool {
    left[0] <= right[2] + padding
        && right[0] <= left[2] + padding
        && left[1] <= right[3] + padding
        && right[1] <= left[3] + padding
}

fn projected_runs_overlap(left: &[OutputRun], right: &[OutputRun]) -> bool {
    // Bboxes only narrow the candidate pairs. Require actual projected mask
    // intersection with enough support to avoid joining nearby people whose
    // expanded silhouettes merely touch. Exact overlap is conservative under
    // perspective differences, but avoids turning crowded groups into one owner.
    let mut overlap = 0u64;
    let mut left_area = 0u64;
    let mut right_area = 0u64;
    for run in left {
        left_area = left_area.saturating_add((run.x1 - run.x0 + 1) as u64);
    }
    let mut left_index = 0;
    let mut right_index = 0;
    while left_index < left.len() && right_index < right.len() {
        let a = left[left_index];
        let b = right[right_index];
        if a.y < b.y {
            left_index += 1;
            continue;
        }
        if b.y < a.y {
            right_area = right_area.saturating_add((b.x1 - b.x0 + 1) as u64);
            right_index += 1;
            continue;
        }
        right_area = right_area.saturating_add((b.x1 - b.x0 + 1) as u64);
        let start = a.x0.max(b.x0);
        let end = a.x1.min(b.x1);
        if start <= end {
            overlap = overlap.saturating_add((end - start + 1) as u64);
        }
        if a.x1 <= b.x1 {
            left_index += 1;
        }
        if b.x1 <= a.x1 {
            right_index += 1;
        }
    }
    while right_index < right.len() {
        let run = right[right_index];
        right_area = right_area.saturating_add((run.x1 - run.x0 + 1) as u64);
        right_index += 1;
    }
    let smaller_area = left_area.min(right_area);
    overlap >= smaller_area.min(2) && overlap.saturating_mul(10) >= smaller_area
}

fn find_index(parent: &mut [usize], value: usize) -> usize {
    if parent[value] != value {
        parent[value] = find_index(parent, parent[value]);
    }
    parent[value]
}

fn union_indices(parent: &mut [usize], left: usize, right: usize) {
    let a = find_index(parent, left);
    let b = find_index(parent, right);
    if a != b {
        parent[b] = a;
    }
}

impl ScenePlan {
    pub(crate) fn estimated_bytes(&self) -> u64 {
        self.mask_window_bytes
            .saturating_add(self.projected_run_bytes)
            .saturating_add(
                self.sources
                    .iter()
                    .map(|source| {
                        (source.components.len() * std::mem::size_of::<Component>()) as u64
                    })
                    .sum::<u64>(),
            )
    }

    pub(crate) fn tile(
        &self,
        row: u32,
        col: u32,
        x_rays: &[(f64, f64)],
        y_rays: &[(f64, f64)],
        bounds: [f64; 4],
        sources: &[Source],
    ) -> Result<SceneTile> {
        let left = col * TILE;
        let top = row * TILE;
        let tw = x_rays.len() as u32;
        let th = y_rays.len() as u32;
        let count = tw as usize * th as usize;
        let mut tile = SceneTile {
            person_owner: if self.identity.protect_people {
                vec![None; count]
            } else {
                Vec::new()
            },
            water_count: if self.identity.smooth_water {
                vec![0; count]
            } else {
                Vec::new()
            },
            water_blend: if self.identity.smooth_water {
                vec![0; count]
            } else {
                Vec::new()
            },
            ..SceneTile::default()
        };
        if self.identity.protect_people {
            let halo = PERSON_BUFFER_PX;
            let halo_width = tw + 2 * halo;
            let halo_height = th + 2 * halo;
            let halo_left = left as i32 - halo as i32;
            let halo_top = top as i32 - halo as i32;
            let mut group_at = vec![None::<usize>; halo_width as usize * halo_height as usize];
            for (group_index, group) in self.person_groups.iter().enumerate() {
                if !bounds_overlap(
                    group.bounds,
                    [
                        halo_left,
                        halo_top,
                        halo_left + halo_width as i32 - 1,
                        halo_top + halo_height as i32 - 1,
                    ],
                    0,
                ) {
                    continue;
                }
                for run in &group.runs {
                    if run.y < halo_top || run.y >= halo_top + halo_height as i32 {
                        continue;
                    }
                    let start = run.x0.max(halo_left);
                    let end = run.x1.min(halo_left + halo_width as i32 - 1);
                    if start <= end {
                        let target = &mut group_at[((run.y - halo_top) as u32 * halo_width
                            + (start - halo_left) as u32)
                            as usize
                            ..=((run.y - halo_top) as u32 * halo_width + (end - halo_left) as u32)
                                as usize];
                        for slot in target {
                            *slot = Some(group_index);
                        }
                    }
                }
            }
            let mut owner = vec![None::<usize>; group_at.len()];
            for index in 0..group_at.len() {
                if let Some(group_index) = group_at[index] {
                    let group = &self.person_groups[group_index];
                    owner[index] = group
                        .source_candidates
                        .iter()
                        .copied()
                        .find(|source_index| {
                            let x = (index as u32 % halo_width) as i32 + halo_left;
                            let y = (index as u32 / halo_width) as i32 + halo_top;
                            if x < 0
                                || y < 0
                                || x >= self.output_width as i32
                                || y >= self.output_height as i32
                            {
                                return false;
                            }
                            sample_geometry(
                                &sources[*source_index],
                                output_ray(
                                    x as u32,
                                    y as u32,
                                    self.output_width,
                                    self.output_height,
                                    bounds,
                                ),
                            )
                            .is_some()
                        });
                    let local_x = index as u32 % halo_width;
                    let local_y = index as u32 / halo_width;
                    let is_core_pixel = local_x >= halo
                        && local_x < halo + tw
                        && local_y >= halo
                        && local_y < halo + th;
                    if is_core_pixel
                        && owner[index].is_some_and(|owner| owner != group.preferred_source)
                    {
                        tile.object_fallbacks += 1;
                    }
                }
            }
            dilate_owner_map(&mut owner, halo_width, halo_height, PERSON_BUFFER_PX);
            for index in 0..count {
                let x = index as u32 % tw;
                let y = index as u32 / tw;
                let halo_index = ((y + halo) * halo_width + x + halo) as usize;
                if let Some(source_index) = owner[halo_index] {
                    tile.person_owner[index] = Some(source_index);
                    tile.person_pixels += 1;
                }
            }
        }
        if self.identity.smooth_water {
            let mut valid_count = vec![0u32; count];
            let mut min_water_confidence = vec![u8::MAX; count];
            for (source_index, source) in sources.iter().enumerate() {
                let Some(window_bounds) = source_window_bounds(source, tw, th, x_rays, y_rays)
                else {
                    continue;
                };
                let window = self.water_window(source_index, window_bounds)?;
                for py in 0..th {
                    for px in 0..tw {
                        let world = [
                            x_rays[px as usize].0 * y_rays[py as usize].1,
                            y_rays[py as usize].0,
                            x_rays[px as usize].1 * y_rays[py as usize].1,
                        ];
                        if let Some((sx, sy, _, _)) = sample_geometry(source, world) {
                            let index = (py * tw + px) as usize;
                            valid_count[index] = valid_count[index].saturating_add(1);
                            let (_, water) = window.sample(sx, sy);
                            if water >= WATER_THRESHOLD {
                                tile.water_count[index] = tile.water_count[index].saturating_add(1);
                                min_water_confidence[index] =
                                    min_water_confidence[index].min(water);
                            }
                        }
                    }
                }
            }
            for index in 0..count {
                tile.water_blend[index] = reliable_water_blend(
                    valid_count[index],
                    tile.water_count[index],
                    min_water_confidence[index],
                );
            }
            tile.water_pixels = tile.water_blend.iter().filter(|value| **value > 0).count() as u64;
        }
        Ok(tile)
    }

    pub(crate) fn water_window(&self, source_index: usize, bounds: [u32; 4]) -> Result<MaskWindow> {
        let source = &self.sources[source_index];
        MaskWindow::load(source, bounds)
    }

    pub(crate) fn worker_bytes(&self) -> u64 {
        self.mask_window_bytes
            .saturating_add(
                (TILE as u64 + 2 * PERSON_BUFFER_PX as u64)
                    .pow(2)
                    .saturating_mul(if self.identity.protect_people {
                        4 * std::mem::size_of::<Option<usize>>() as u64
                    } else {
                        0
                    }),
            )
            .saturating_add(
                (TILE as u64)
                    .pow(2)
                    .saturating_mul(if self.identity.smooth_water {
                        (2 * std::mem::size_of::<u32>() + 2) as u64
                    } else {
                        0
                    }),
            )
    }
    pub(crate) fn shared_bytes(&self) -> u64 {
        self.estimated_bytes()
            .saturating_sub(self.mask_window_bytes)
    }
    pub(crate) fn component_count(&self) -> usize {
        self.sources
            .iter()
            .map(|source| source.components.len())
            .sum()
    }
    pub(crate) fn object_count(&self) -> usize {
        self.person_groups.len()
    }
}

fn water_confidence_feather(confidence: u8) -> u8 {
    const SOFT_END: f32 = 224.0;
    let t = ((f32::from(confidence) - f32::from(WATER_THRESHOLD))
        / (SOFT_END - f32::from(WATER_THRESHOLD)))
    .clamp(0.0, 1.0);
    (t * t * (3.0 - 2.0 * t) * 255.0).round() as u8
}

fn reliable_water_blend(valid_sources: u32, water_sources: u32, min_confidence: u8) -> u8 {
    if valid_sources < 2 || water_sources < 2 || water_sources != valid_sources {
        0
    } else {
        water_confidence_feather(min_confidence)
    }
}

fn source_window_bounds(
    source: &Source,
    tw: u32,
    th: u32,
    x_rays: &[(f64, f64)],
    y_rays: &[(f64, f64)],
) -> Option<[u32; 4]> {
    let (mut min_x, mut min_y, mut max_x, mut max_y) = (u32::MAX, u32::MAX, 0, 0);
    let mut found = false;
    for py in 0..th {
        for px in 0..tw {
            let (sy, cy) = x_rays[px as usize];
            let (sp, cp) = y_rays[py as usize];
            if let Some((x, y, _, _)) = sample_geometry(source, [sy * cp, sp, cy * cp]) {
                min_x = min_x.min(x.round().max(0.0) as u32);
                min_y = min_y.min(y.round().max(0.0) as u32);
                max_x = max_x.max(x.round().max(0.0) as u32);
                max_y = max_y.max(y.round().max(0.0) as u32);
                found = true;
            }
        }
    }
    found.then_some([
        min_x.saturating_sub(1),
        min_y.saturating_sub(1),
        max_x.saturating_add(1).min(source.width.saturating_sub(1)),
        max_y.saturating_add(1).min(source.height.saturating_sub(1)),
    ])
}

fn output_ray(x: u32, y: u32, width: u32, height: u32, bounds: [f64; 4]) -> [f64; 3] {
    let yaw = bounds[0] + (f64::from(x) + 0.5) / f64::from(width) * (bounds[1] - bounds[0]);
    let pitch = bounds[3] - (f64::from(y) + 0.5) / f64::from(height) * (bounds[3] - bounds[2]);
    let (sy, cy) = yaw.sin_cos();
    let (sp, cp) = pitch.sin_cos();
    [sy * cp, sp, cy * cp]
}

fn dilate_owner_map(owner: &mut [Option<usize>], width: u32, height: u32, radius: u32) {
    if radius == 0 {
        return;
    }
    let original = owner.to_vec();
    for y in 0..height {
        for x in 0..width {
            let index = (y * width + x) as usize;
            if original[index].is_some() {
                continue;
            }
            let mut best: Option<(u32, usize)> = None;
            for dy in -(radius as i32)..=(radius as i32) {
                for dx in -(radius as i32)..=(radius as i32) {
                    let nx = x as i32 + dx;
                    let ny = y as i32 + dy;
                    if nx < 0 || ny < 0 || nx >= width as i32 || ny >= height as i32 {
                        continue;
                    }
                    let distance = (dx * dx + dy * dy) as u32;
                    if distance > radius * radius {
                        continue;
                    }
                    if let Some(source) = original[ny as usize * width as usize + nx as usize] {
                        let candidate = (distance, source);
                        if best.is_none_or(|current| candidate < current) {
                            best = Some(candidate);
                        }
                    }
                }
            }
            if let Some((_, source)) = best {
                owner[index] = Some(source);
            }
        }
    }
}

#[derive(Clone, Debug)]
pub(crate) struct MaskWindow {
    bounds: [u32; 4],
    width: u32,
    data: Vec<u8>,
}

impl MaskWindow {
    fn load(source: &MaskSource, bounds: [u32; 4]) -> Result<Self> {
        let x0 = bounds[0].min(source.descriptor.width.saturating_sub(1));
        let y0 = bounds[1].min(source.descriptor.height.saturating_sub(1));
        let x1 = bounds[2]
            .min(source.descriptor.width.saturating_sub(1))
            .max(x0);
        let y1 = bounds[3]
            .min(source.descriptor.height.saturating_sub(1))
            .max(y0);
        let width = x1 - x0 + 1;
        let height = y1 - y0 + 1;
        let bytes = u64::from(width) * u64::from(height) * 2;
        if bytes > MASK_WINDOW_BYTES_CAP {
            return Err(crate::Error::Invalid(format!(
                "semantic mask window is {bytes} bytes, above the bounded window cache cap"
            )));
        }
        let mut data = vec![0u8; bytes as usize];
        let mut file = File::open(&source.raw_path)?;
        let source_stride = u64::from(source.descriptor.width) * 2;
        let row_bytes = width as usize * 2;
        for row in 0..height {
            let offset = (u64::from(y0 + row) * source_stride) + u64::from(x0) * 2;
            file.seek(SeekFrom::Start(offset))?;
            file.read_exact(&mut data[row as usize * row_bytes..(row as usize + 1) * row_bytes])?;
        }
        Ok(Self {
            bounds: [x0, y0, x1, y1],
            width,
            data,
        })
    }

    pub(crate) fn sample(&self, x: f64, y: f64) -> (u8, u8) {
        if !x.is_finite() || !y.is_finite() {
            return (0, 0);
        }
        let x = x.round() as i64;
        let y = y.round() as i64;
        if x < i64::from(self.bounds[0])
            || y < i64::from(self.bounds[1])
            || x > i64::from(self.bounds[2])
            || y > i64::from(self.bounds[3])
        {
            return (0, 0);
        }
        let index =
            (((y as u32 - self.bounds[1]) * self.width + (x as u32 - self.bounds[0])) * 2) as usize;
        (self.data[index], self.data[index + 1])
    }
}

#[cfg(test)]
mod tests {
    use super::{
        bounds_overlap, compress_output_points, dilate_owner_map, merge_output_runs,
        projected_runs_overlap, reliable_water_blend, run_bounds, water_confidence_feather,
        OutputRun,
    };
    use std::collections::BTreeMap;

    #[test]
    fn sparse_person_runs_preserve_small_shapes_and_tile_edges() {
        let mut rows = BTreeMap::new();
        rows.insert(511, vec![510, 511, 512]);
        rows.insert(512, vec![510, 512]);
        let runs = compress_output_points(rows);
        assert_eq!(
            runs,
            vec![
                OutputRun {
                    y: 511,
                    x0: 510,
                    x1: 512
                },
                OutputRun {
                    y: 512,
                    x0: 510,
                    x1: 510
                },
                OutputRun {
                    y: 512,
                    x0: 512,
                    x1: 512
                }
            ]
        );
        let mut owners = vec![None; 4];
        owners[1] = Some(3);
        dilate_owner_map(&mut owners, 2, 2, 1);
        assert_eq!(owners, vec![Some(3), Some(3), None, Some(3)]);
    }

    #[test]
    fn disjoint_person_outlines_do_not_merge_just_because_bboxes_overlap() {
        let left = vec![
            OutputRun {
                y: 20,
                x0: 10,
                x1: 24,
            },
            OutputRun {
                y: 24,
                x0: 10,
                x1: 24,
            },
        ];
        let right = vec![
            OutputRun {
                y: 21,
                x0: 10,
                x1: 24,
            },
            OutputRun {
                y: 23,
                x0: 10,
                x1: 24,
            },
        ];
        assert!(bounds_overlap(
            run_bounds(&left).unwrap(),
            run_bounds(&right).unwrap(),
            0
        ));
        assert!(!projected_runs_overlap(&left, &right));
    }

    #[test]
    fn run_union_merges_intervals_without_expanding_every_pixel() {
        let runs = merge_output_runs(vec![
            OutputRun {
                y: 7,
                x0: 10,
                x1: 15,
            },
            OutputRun {
                y: 7,
                x0: 14,
                x1: 20,
            },
            OutputRun {
                y: 8,
                x0: 10,
                x1: 10,
            },
        ]);
        assert_eq!(
            runs,
            vec![
                OutputRun {
                    y: 7,
                    x0: 10,
                    x1: 20
                },
                OutputRun {
                    y: 8,
                    x0: 10,
                    x1: 10
                }
            ]
        );
    }

    #[test]
    fn water_overlap_excludes_a_third_valid_structure_source() {
        assert_eq!(reliable_water_blend(3, 2, 255), 0);
        assert!(reliable_water_blend(3, 3, 255) > 0);
    }

    #[test]
    fn water_confidence_has_a_soft_edge_then_reaches_full_feather() {
        assert_eq!(water_confidence_feather(127), 0);
        assert_eq!(water_confidence_feather(128), 0);
        let edge = water_confidence_feather(160);
        let interior = water_confidence_feather(224);
        assert!(edge > 0 && edge < interior);
        assert_eq!(interior, 255);
    }
}
