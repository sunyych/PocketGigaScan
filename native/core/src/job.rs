//! Asynchronous, persistent spherical rendering jobs exposed through the JSON ABI.
use crate::job_resources::{self, Limits};
use crate::{fingerprint, spherical, spherical_renderer};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Condvar, Mutex, OnceLock,
    },
    thread,
    time::Instant,
};

const STATE_FILE: &str = "job-state.json";
const ALIGNMENT_CACHE_ALGORITHM_VERSION: u32 = 14;
static JOBS: OnceLock<Mutex<BTreeMap<PathBuf, Arc<Control>>>> = OnceLock::new();
static ALIGNMENT_CACHE_IO: OnceLock<Mutex<()>> = OnceLock::new();
fn jobs() -> &'static Mutex<BTreeMap<PathBuf, Arc<Control>>> {
    JOBS.get_or_init(|| Mutex::new(BTreeMap::new()))
}

#[derive(Clone, Serialize, Deserialize)]
struct Snapshot {
    schema_version: u32,
    job_id: String,
    request: Value,
    memory_budget_mib: usize,
    workers_requested: usize,
    #[serde(default)]
    workers_effective: usize,
    state: String,
    stage: String,
    progress: f64,
    backend: String,
    #[serde(default)]
    request_hash: String,
    #[serde(default)]
    source_hashes: BTreeMap<String, String>,
    #[serde(default)]
    error: Option<Value>,
    #[serde(default)]
    result_stats: Option<Value>,
    #[serde(default)]
    layout_path: Option<String>,
    #[serde(default)]
    manifest_path: Option<String>,
    #[serde(default)]
    operation: String,
    #[serde(default)]
    export_destination: Option<String>,
    #[serde(default)]
    layout_hash: Option<String>,
    #[serde(default)]
    width: Option<u32>,
    #[serde(default)]
    height: Option<u32>,
    #[serde(default)]
    commit_started: bool,
}
struct Control {
    root: PathBuf,
    snapshot: Mutex<Snapshot>,
    changed: Condvar,
    cancel: AtomicBool,
    worker_active: AtomicBool,
    verify_on_resume: AtomicBool,
}

#[derive(Debug)]
enum RunFailure {
    CooperativeCancellation,
    Failed(String),
}

impl From<String> for RunFailure {
    fn from(message: String) -> Self {
        if matches!(
            message.as_str(),
            "cancelled" | "cancelled before manifest publication" | "job cancelled"
        ) {
            Self::CooperativeCancellation
        } else {
            Self::Failed(message)
        }
    }
}

impl From<&str> for RunFailure {
    fn from(message: &str) -> Self {
        Self::from(message.to_owned())
    }
}
impl Control {
    fn snapshot(&self) -> Snapshot {
        self.snapshot.lock().expect("job lock").clone()
    }
    fn update(&self, f: impl FnOnce(&mut Snapshot)) {
        let mut s = self.snapshot.lock().expect("job lock");
        f(&mut s);
        if let Err(e) = persist(&self.root, &s) {
            s.state = "failed".into();
            s.error = Some(json!({"code":"PERSISTENCE_ERROR","message":e.to_string()}));
        }
    }
    /// Atomically close the cancellation window before publishing a completed artifact.
    /// `cancel` takes the same mutex, so either cancellation wins and this returns
    /// false, or this transition wins and later cancellation is rejected.
    fn begin_commit(&self, stage: &str) -> bool {
        loop {
            // This handles a pause that arrives during final hashing, fsync, or
            // PNG finalization, including input revalidation after live resume.
            if !self.checkpoint(stage, None) {
                return false;
            }
            let mut s = self.snapshot.lock().expect("job lock");
            if s.state == "running" && !s.commit_started && !self.cancel.load(Ordering::SeqCst) {
                s.stage = stage.into();
                s.commit_started = true;
                if let Err(e) = persist(&self.root, &s) {
                    s.state = "failed".into();
                    s.error = Some(json!({"code":"PERSISTENCE_ERROR","message":e.to_string()}));
                    return false;
                }
                return true;
            }
            if ["failed", "cancelled"].contains(&s.state.as_str()) || s.commit_started {
                return false;
            }
        }
    }
    fn checkpoint(&self, stage: &str, progress: Option<f64>) -> bool {
        let mut s = self.snapshot.lock().expect("job lock");
        if s.state == "failed" {
            return false;
        }
        if s.state == "cancelled" || self.cancel.load(Ordering::SeqCst) {
            s.state = "cancelled".into();
            s.stage = stage.into();
            let _ = persist(&self.root, &s);
            return false;
        }
        if s.state == "pausing" {
            let _ = stage;
            let _ = progress;
            return false;
        }
        if s.state == "paused" {
            return false;
        }
        if s.state == "failed" {
            return false;
        }
        if self.cancel.load(Ordering::SeqCst) {
            s.state = "cancelled".into();
            let _ = persist(&self.root, &s);
            return false;
        }
        let verify = self.verify_on_resume.swap(false, Ordering::SeqCst);
        if verify {
            drop(s);
            if !verify_fingerprints(self) {
                let mut failed = self.snapshot.lock().expect("job lock");
                failed.state = "failed".into();
                failed.error = Some(
                    json!({"code":"INPUT_CHANGED","message":"source or request fingerprint changed while paused"}),
                );
                let _ = persist(&self.root, &failed);
                return false;
            }
            s = self.snapshot.lock().expect("job lock");
            if self.cancel.load(Ordering::SeqCst) {
                s.state = "cancelled".into();
                let _ = persist(&self.root, &s);
                return false;
            }
        }
        if s.state == "paused" {
            s.state = "running".into();
        }
        let stage_changed = s.stage != stage;
        let old_progress = s.progress;
        s.stage = stage.into();
        if let Some(p) = progress {
            s.progress = p;
        }
        let should_persist =
            stage_changed || progress.is_some_and(|p| (p - old_progress).abs() >= 0.005);
        if should_persist {
            if let Err(e) = persist(&self.root, &s) {
                s.state = "failed".into();
                s.error = Some(json!({"code":"PERSISTENCE_ERROR","message":e.to_string()}));
                return false;
            }
        }
        drop(s);
        true
    }
}
fn persist(root: &Path, s: &Snapshot) -> std::io::Result<()> {
    let p = root.join(STATE_FILE);
    let temp = root.join("job-state.json.tmp");
    let bytes = serde_json::to_vec_pretty(s).map_err(std::io::Error::other)?;
    let mut f = fs::File::create(&temp)?;
    f.write_all(&bytes)?;
    f.sync_all()?;
    fs::rename(temp, p)?;
    Ok(())
}
fn response(s: &Snapshot) -> Value {
    let operation_workers = if s.operation == "export" {
        1
    } else {
        s.workers_effective
    };
    let export_format = s
        .export_destination
        .as_deref()
        .map(|path| export_format_for_path(Path::new(path)).unwrap_or("unknown"));
    json!({"ok":true,"abiVersion":1,"jobId":s.job_id,"state":s.state,"stage":s.stage,"progress":s.progress,"backend":s.backend,"operation":s.operation,"workersRequested":s.workers_requested,"workersEffective":s.workers_effective,"operationWorkers":operation_workers,"memoryBudgetMiB":s.memory_budget_mib,"layoutPath":s.layout_path,"manifestPath":s.manifest_path,"exportDestination":s.export_destination,"exportFormat":export_format,"dimensions":s.width.zip(s.height).map(|(w,h)|json!([w,h])),"resultStats":s.result_stats,"error":s.error})
}
fn fail(code: &str, msg: impl ToString) -> Value {
    json!({"ok":false,"abiVersion":1,"error":{"code":code,"message":msg.to_string()}})
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Command {
    command: String,
    #[serde(default)]
    request: Option<Value>,
    #[serde(default)]
    output_dir: Option<String>,
    #[serde(default)]
    job_id: Option<String>,
    #[serde(default)]
    destination: Option<String>,
    #[serde(default = "default_budget")]
    #[serde(rename = "memoryBudgetMiB", alias = "memoryBudgetMib")]
    memory_budget_mib: usize,
    #[serde(default = "default_workers")]
    workers: usize,
    #[serde(default)]
    total_cpu_workers: Option<usize>,
    #[serde(default)]
    #[serde(rename = "totalMemoryBudgetMiB", alias = "totalMemoryBudgetMib")]
    total_memory_budget_mib: Option<usize>,
    #[serde(default)]
    max_concurrent_jobs: Option<usize>,
}
fn default_budget() -> usize {
    128
}
fn export_format_for_path(destination: &Path) -> Option<&'static str> {
    match destination
        .extension()
        .and_then(|extension| extension.to_str())
    {
        None | Some("") => Some("png"),
        Some(extension) if extension.eq_ignore_ascii_case("png") => Some("png"),
        Some(extension)
            if extension.eq_ignore_ascii_case("tif") || extension.eq_ignore_ascii_case("tiff") =>
        {
            Some("tiff")
        }
        Some(extension) if extension.eq_ignore_ascii_case("jxl") => Some("jxl"),
        _ => None,
    }
}
fn default_workers() -> usize {
    1
}

pub fn handle(input: &str) -> Value {
    let c: Command = match serde_json::from_str(input) {
        Ok(c) => c,
        Err(e) => return fail("INVALID_REQUEST", e),
    };
    match c.command.as_str() {
        "capabilities" => capabilities(),
        "configureResources" => configure_resources(c),
        "start" => start(c),
        "status" => with_job(c.job_id.as_deref(), status),
        "pause" => with_job(c.job_id.as_deref(), pause),
        "resume" => with_job(c.job_id.as_deref(), resume),
        "cancel" => with_job(c.job_id.as_deref(), cancel),
        "export" => export(c),
        _ => fail(
            "INVALID_COMMAND",
            "command must be capabilities, configureResources, start, status, pause, resume, cancel, or export",
        ),
    }
}
fn capabilities_value(limits: Limits) -> Value {
    let (active_jobs, reserved_workers, reserved_memory_mib) = job_resources::usage();
    json!({"backend":"cpu-rust-tiled","gpuAvailable":false,"memoryBudgetKind":"reservation","logicalCpuCount":job_resources::logical_cpus(),"maxWorkersPerJob":job_resources::MAX_WORKERS_PER_JOB,"maxConcurrentJobs":limits.max_concurrent_jobs,"maxConcurrentJobsLimit":job_resources::MAX_CONCURRENT_JOBS,"maxTotalMemoryBudgetMiB":job_resources::MAX_TOTAL_MEMORY_MIB,"totalCpuWorkers":limits.total_cpu_workers,"totalMemoryBudgetMiB":limits.total_memory_mib,"activeJobs":active_jobs,"reservedWorkers":reserved_workers,"reservedMemoryMiB":reserved_memory_mib,"exportFormats":{"png":true,"tiff":true,"jxl":crate::jxl_export::available()},"jpegXlAvailable":crate::jxl_export::available(),"jpegXlEncoder":"libjxl-c-api-0.12.0","jpegXlLossless":true})
}
fn capabilities() -> Value {
    json!({"ok":true,"capabilities":capabilities_value(job_resources::limits())})
}
fn configure_resources(c: Command) -> Value {
    let (Some(cpu), Some(memory), Some(slots)) = (
        c.total_cpu_workers,
        c.total_memory_budget_mib,
        c.max_concurrent_jobs,
    ) else {
        return fail(
            "INVALID_REQUEST",
            "totalCpuWorkers, totalMemoryBudgetMiB, and maxConcurrentJobs are required",
        );
    };
    match job_resources::configure(cpu, memory, slots) {
        Ok(limits) => json!({"ok":true,"capabilities":capabilities_value(limits)}),
        Err(message) => {
            let code = if message.starts_with("requested limits are below active reservations") {
                "RESOURCE_BUSY"
            } else {
                "INVALID_REQUEST"
            };
            fail(code, message)
        }
    }
}
fn canonical_job(value: &str) -> Result<PathBuf, String> {
    let p = PathBuf::from(value);
    let parent = p.parent().ok_or("output directory must have a parent")?;
    let cparent = parent
        .canonicalize()
        .map_err(|e| format!("output parent unavailable: {e}"))?;
    Ok(cparent.join(p.file_name().ok_or("output directory name is empty")?))
}
fn sources(req: &Value) -> Result<Vec<PathBuf>, String> {
    let tiles = req["tiles"]
        .as_array()
        .ok_or("request.tiles must be an array")?;
    if tiles.is_empty() {
        return Err("request.tiles must contain at least one source".into());
    }
    let mut out = Vec::new();
    out.try_reserve_exact(tiles.len())
        .map_err(|_| format!("could not allocate paths for {} sources", tiles.len()))?;
    for t in tiles {
        let p = t["path"]
            .as_str()
            .filter(|s| !s.is_empty())
            .ok_or("each source path must be nonempty")?;
        let p = PathBuf::from(p)
            .canonicalize()
            .map_err(|e| format!("source file unavailable {p}: {e}"))?;
        if !p.is_file() {
            return Err(format!("source path is not a file: {}", p.display()));
        }
        out.push(p);
    }
    Ok(out)
}
fn disjoint(root: &Path, src: &[PathBuf]) -> Result<(), String> {
    for s in src {
        if s.starts_with(root) || root.starts_with(s) {
            return Err(format!(
                "source/output paths must be disjoint: {} and {}",
                s.display(),
                root.display()
            ));
        }
    }
    Ok(())
}
fn validate_request_shape(r: &Value) -> Result<(), String> {
    let rows = r["rows"].as_u64().ok_or("rows must be an integer")?;
    let cols = r["columns"].as_u64().ok_or("columns must be an integer")?;
    if rows == 0 || cols == 0 {
        return Err("rows and columns must be positive".into());
    }
    let tiles = r["tiles"].as_array().ok_or("tiles must be an array")?;
    let cell_count = rows
        .checked_mul(cols)
        .ok_or("rows*columns overflows supported dimensions")?;
    if u64::try_from(tiles.len()).ok() != Some(cell_count) {
        return Err("tile count must match rows*columns".into());
    }
    let w = r["sourceWidth"]
        .as_u64()
        .ok_or("sourceWidth must be an integer")?;
    let h = r["sourceHeight"]
        .as_u64()
        .ok_or("sourceHeight must be an integer")?;
    if w == 0 || h == 0 || w > 32768 || h > 32768 || w * h > 80_000_000 {
        return Err("source dimensions exceed supported bounds".into());
    }
    for k in ["fx", "fy", "cx", "cy"] {
        let v = r[k].as_f64().ok_or_else(|| format!("{k} must be finite"))?;
        if !v.is_finite() || ((k == "fx" || k == "fy") && v <= 0.) {
            return Err(format!("{k} must be finite and focal lengths positive"));
        }
    }
    let mut cells = std::collections::HashSet::new();
    for t in tiles {
        let row = t["row"].as_u64().ok_or("tile row must be integer")?;
        let col = t["column"].as_u64().ok_or("tile column must be integer")?;
        if row >= rows || col >= cols || !cells.insert((row, col)) {
            return Err("tile coordinates must be unique and within grid".into());
        }
    }
    Ok(())
}
fn start(c: Command) -> Value {
    if !(job_resources::MIN_JOB_MEMORY_MIB..=job_resources::MAX_JOB_MEMORY_MIB)
        .contains(&c.memory_budget_mib)
    {
        return fail("INVALID_REQUEST", "memoryBudgetMiB must be 128..=4096");
    }
    if !(1..=job_resources::MAX_WORKERS_PER_JOB).contains(&c.workers) {
        return fail("INVALID_REQUEST", "workers must be 1..=32");
    }
    let Some(mut request) = c.request else {
        return fail("INVALID_REQUEST", "request is required");
    };
    if let Err(e) = validate_request_shape(&request) {
        return fail("INVALID_REQUEST", e);
    }
    let photo_count = request["tiles"].as_array().map_or(0, Vec::len);
    let workers_effective = c
        .workers
        .min(photo_count)
        .min(job_resources::logical_cpus())
        .min(job_resources::limits().total_cpu_workers);
    if workers_effective == 0 {
        return fail(
            "INVALID_REQUEST",
            "request.tiles must contain at least one photo",
        );
    }
    for key in [
        "parallelRendering",
        "parallelMatching",
        "useSourceCache",
        "useAlignmentCache",
    ] {
        if request.get(key).is_some_and(|value| !value.is_boolean()) {
            return fail(
                "INVALID_REQUEST",
                format!("request.{key} must be a boolean"),
            );
        }
    }
    let Some(dir) = c.output_dir else {
        return fail("INVALID_REQUEST", "outputDir is required");
    };
    let root = match canonical_job(&dir) {
        Ok(p) => p,
        Err(e) => return fail("INVALID_PATH", e),
    };
    if root.exists() {
        if !root.is_dir()
            || fs::read_dir(&root)
                .map(|mut it| it.next().is_some())
                .unwrap_or(true)
        {
            return fail(
                "OUTPUT_EXISTS",
                "outputDir must be new or an existing empty directory",
            );
        }
    }
    if let Some(obj) = request.as_object_mut() {
        obj.insert("workers".into(), json!(workers_effective));
        obj.insert("outputDir".into(), json!(""));
    } else {
        return fail("INVALID_REQUEST", "request must be an object");
    }
    let src = match sources(&request) {
        Ok(p) => p,
        Err(e) => return fail("INVALID_REQUEST", e),
    };
    if let Err(e) = disjoint(&root, &src) {
        return fail("PATH_OVERLAP", e);
    }
    if let Some(cache_dir) = request["alignmentCacheDir"].as_str() {
        let requested_cache = PathBuf::from(cache_dir);
        if !requested_cache.is_absolute()
            || requested_cache.file_name().and_then(|name| name.to_str())
                != Some(".alignment-cache")
        {
            return fail(
                "INVALID_PATH",
                "alignmentCacheDir must be an absolute .alignment-cache directory",
            );
        }
        let cache_target = match canonical_job(cache_dir) {
            Ok(path) => path,
            Err(e) => return fail("INVALID_PATH", format!("alignmentCacheDir: {e}")),
        };
        if cache_target.starts_with(&root)
            || root.starts_with(&cache_target)
            || src
                .iter()
                .any(|source| source.starts_with(&cache_target) || source == &cache_target)
        {
            return fail(
                "PATH_OVERLAP",
                "alignmentCacheDir cannot overlap outputDir or contain a source",
            );
        }
        if let Err(error) = fs::create_dir_all(&cache_target) {
            return fail(
                "INVALID_PATH",
                format!("alignmentCacheDir cannot be created: {error}"),
            );
        }
        let cache = match cache_target.canonicalize() {
            Ok(path) => path,
            Err(e) => return fail("INVALID_PATH", format!("alignmentCacheDir: {e}")),
        };
        if !cache.is_dir()
            || cache.starts_with(&root)
            || root.starts_with(&cache)
            || src
                .iter()
                .any(|source| source.starts_with(&cache) || source == &cache)
        {
            return fail(
                "PATH_OVERLAP",
                "alignmentCacheDir resolves through a conflicting path",
            );
        }
        if let Some(obj) = request.as_object_mut() {
            obj.insert("alignmentCacheDir".into(), json!(cache.to_string_lossy()));
        }
    } else if request
        .get("alignmentCacheDir")
        .is_some_and(|v| !v.is_null())
    {
        return fail(
            "INVALID_REQUEST",
            "request.alignmentCacheDir must be a path string",
        );
    }
    if let Err(e) = job_resources::reserve(&root, &root, workers_effective, c.memory_budget_mib) {
        return fail("RESOURCE_BUSY", e);
    }
    if let Err(e) = fs::create_dir_all(&root) {
        job_resources::release(&root);
        return fail("IO_ERROR", e);
    }
    let snapshot = Snapshot {
        schema_version: 1,
        job_id: root.to_string_lossy().into_owned(),
        request,
        memory_budget_mib: c.memory_budget_mib,
        workers_requested: c.workers,
        workers_effective,
        state: "queued".into(),
        stage: "validate".into(),
        progress: 0.,
        backend: "cpu-rust-tiled".into(),
        request_hash: String::new(),
        source_hashes: BTreeMap::new(),
        error: None,
        result_stats: None,
        layout_path: None,
        manifest_path: None,
        operation: "render".into(),
        export_destination: None,
        layout_hash: None,
        width: None,
        height: None,
        commit_started: false,
    };
    let control = Arc::new(Control {
        root: root.clone(),
        snapshot: Mutex::new(snapshot),
        changed: Condvar::new(),
        cancel: AtomicBool::new(false),
        worker_active: AtomicBool::new(true),
        verify_on_resume: AtomicBool::new(false),
    });
    if let Err(e) = persist(&root, &control.snapshot()) {
        job_resources::release(&root);
        return fail("PERSISTENCE_ERROR", e);
    }
    jobs().lock().unwrap().insert(root.clone(), control.clone());
    let spawn = thread::Builder::new()
        .name("lumia-render-job".into())
        .spawn({
            let worker = control.clone();
            move || run(worker, false)
        });
    if let Err(error) = spawn {
        job_resources::release(&root);
        control.worker_active.store(false, Ordering::SeqCst);
        control.update(|s| {
            s.state = "failed".into();
            s.error = Some(json!({"code":"SPAWN_FAILED","message":error.to_string()}));
        });
        return fail("SPAWN_FAILED", error);
    }
    response(&control.snapshot())
}
fn get_job(id: Option<&str>) -> Result<Arc<Control>, String> {
    let id = id.ok_or("jobId is required")?;
    let path = PathBuf::from(id);
    let mut registry = jobs().lock().map_err(|_| "job registry is unavailable")?;
    if let Some(j) = registry.get(&path) {
        return Ok(j.clone());
    }
    let mut s: Snapshot = serde_json::from_slice(
        &fs::read(path.join(STATE_FILE)).map_err(|e| format!("job state unavailable: {e}"))?,
    )
    .map_err(|e| format!("invalid persisted job state: {e}"))?;
    if s.job_id != id {
        return Err("jobId does not match persisted state".into());
    }
    if s.workers_effective == 0 {
        s.workers_effective = s
            .workers_requested
            .min(s.request["tiles"].as_array().map_or(1, Vec::len))
            .min(job_resources::logical_cpus())
            .max(1);
    }
    if ["running", "queued", "pausing", "committing"].contains(&s.state.as_str()) {
        s.state = "paused".into();
        s.commit_started = false;
        persist(&path, &s).map_err(|e| format!("could not recover job state: {e}"))?;
    }
    let control = Arc::new(Control {
        root: path.clone(),
        snapshot: Mutex::new(s),
        changed: Condvar::new(),
        cancel: AtomicBool::new(false),
        worker_active: AtomicBool::new(false),
        verify_on_resume: AtomicBool::new(false),
    });
    registry.insert(path, control.clone());
    Ok(control)
}
fn with_job(id: Option<&str>, f: fn(Arc<Control>) -> Value) -> Value {
    match get_job(id) {
        Ok(j) => f(j),
        Err(e) => fail("JOB_NOT_FOUND", e),
    }
}
fn status(j: Arc<Control>) -> Value {
    response(&j.snapshot())
}
fn pause(j: Arc<Control>) -> Value {
    let mut snapshot = j.snapshot.lock().expect("job lock");
    if snapshot.commit_started {
        return fail(
            "INVALID_STATE",
            "artifact publication has entered its short non-pausable commit window",
        );
    }
    if ["completed", "failed", "cancelled"].contains(&snapshot.state.as_str()) {
        return fail(
            "INVALID_STATE",
            format!("cannot pause state {}", snapshot.state),
        );
    }
    if snapshot.state == "running" || snapshot.state == "queued" {
        snapshot.state = "pausing".into();
        if let Err(e) = persist(&j.root, &snapshot) {
            snapshot.state = "failed".into();
            snapshot.error = Some(json!({"code":"PERSISTENCE_ERROR","message":e.to_string()}));
        }
    }
    let v = response(&snapshot);
    v
}
fn cancel(j: Arc<Control>) -> Value {
    let mut s = j.snapshot.lock().expect("job lock");
    if s.commit_started {
        return fail(
            "INVALID_STATE",
            "artifact publication has entered its short non-cancellable commit window",
        );
    }
    if ["completed", "failed", "cancelled"].contains(&s.state.as_str()) || s.commit_started {
        return fail("INVALID_STATE", format!("cannot cancel state {}", s.state));
    }
    if !j.worker_active.load(Ordering::SeqCst) {
        s.state = "cancelled".into();
        s.stage = "cancelled".into();
        if let Err(e) = persist(&j.root, &s) {
            s.state = "failed".into();
            s.error = Some(json!({"code":"PERSISTENCE_ERROR","message":e.to_string()}));
        }
        return response(&s);
    }
    s.state = "pausing".into();
    j.cancel.store(true, Ordering::SeqCst);
    if let Err(e) = persist(&j.root, &s) {
        s.state = "failed".into();
        s.error = Some(json!({"code":"PERSISTENCE_ERROR","message":e.to_string()}));
    }
    drop(s);
    j.changed.notify_all();
    let mut v = response(&j.snapshot());
    v["cancelRequested"] = json!(true);
    v
}
fn resume(j: Arc<Control>) -> Value {
    let s = j.snapshot();
    if s.state != "paused" {
        return fail(
            "INVALID_STATE",
            format!("resume requires paused state; was {}", s.state),
        );
    }
    let output = if s.operation == "export" {
        s.export_destination
            .as_deref()
            .map(PathBuf::from)
            .unwrap_or_else(|| j.root.join("panorama.png"))
    } else {
        j.root.clone()
    };
    let reserved_workers = if s.operation == "export" {
        1
    } else {
        s.workers_effective
    };
    if let Err(e) = job_resources::reserve(&j.root, &output, reserved_workers, s.memory_budget_mib)
    {
        return fail("RESOURCE_BUSY", e);
    }
    j.cancel.store(false, Ordering::SeqCst);
    j.verify_on_resume.store(false, Ordering::SeqCst);
    j.update(|s| {
        if s.state != "pausing" {
            s.state = "running".into();
        }
        s.stage = "validate".into();
        s.error = None;
    });
    j.worker_active.store(true, Ordering::SeqCst);
    if s.operation == "export" {
        j.verify_on_resume.store(false, Ordering::SeqCst);
        let worker = j.clone();
        if let Err(error) = thread::Builder::new()
            .name("lumia-export-job".into())
            .spawn(move || run_export(worker))
        {
            j.update(|s| {
                s.state = "paused".into();
                s.error = Some(json!({"code":"SPAWN_FAILED","message":error.to_string()}));
            });
            j.worker_active.store(false, Ordering::SeqCst);
            job_resources::release(&j.root);
            return fail("SPAWN_FAILED", error);
        }
    } else {
        j.verify_on_resume.store(false, Ordering::SeqCst);
        let worker = j.clone();
        if let Err(error) = thread::Builder::new()
            .name("lumia-render-resume".into())
            .spawn(move || run(worker, true))
        {
            j.update(|s| {
                s.state = "paused".into();
                s.error = Some(json!({"code":"SPAWN_FAILED","message":error.to_string()}));
            });
            j.worker_active.store(false, Ordering::SeqCst);
            job_resources::release(&j.root);
            return fail("SPAWN_FAILED", error);
        }
    }
    response(&j.snapshot())
}
struct ActiveLease {
    control: Arc<Control>,
    released: bool,
}
impl ActiveLease {
    fn new(control: Arc<Control>) -> Self {
        Self {
            control,
            released: false,
        }
    }
    fn release(&mut self) {
        if !self.released {
            self.control.worker_active.store(false, Ordering::SeqCst);
            job_resources::release(&self.control.root);
            self.released = true;
        }
    }
}
impl Drop for ActiveLease {
    fn drop(&mut self) {
        self.release();
    }
}
fn run(j: Arc<Control>, resume: bool) {
    let mut lease = ActiveLease::new(j.clone());
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run_inner(&j, resume)));
    match result {
        Ok(Ok(())) => {
            j.update(|s| {
                s.state = "completed".into();
                s.stage = "done".into();
                s.progress = 1.;
                s.error = None;
                s.commit_started = false;
            });
        }
        Ok(Err(e)) => finish_run_failure(&j, e),
        Err(p) => {
            let e = p
                .downcast_ref::<&str>()
                .copied()
                .or_else(|| p.downcast_ref::<String>().map(String::as_str))
                .unwrap_or("worker panicked");
            j.update(|s| {
                if s.state != "paused" {
                    s.state = "failed".into();
                    s.error = Some(json!({"code":"PANIC","message":e}));
                    s.commit_started = false;
                }
            });
        }
    }
    lease.release();
}
fn finish_run_failure(j: &Control, failure: RunFailure) {
    // Cancellation from a renderer checkpoint is the signal used to unwind a
    // pause. A concurrent user cancel takes precedence; genuine errors are
    // never hidden merely because a pause was requested.
    j.update(|s| {
        if s.state == "failed" {
            return;
        }
        match failure {
            RunFailure::CooperativeCancellation if j.cancel.load(Ordering::SeqCst) => {
                s.state = "cancelled".into();
                s.stage = "cancelled".into();
                s.error = None;
            }
            RunFailure::CooperativeCancellation if s.state == "pausing" => {
                s.state = "paused".into();
                s.stage = "paused".into();
                s.error = None;
            }
            RunFailure::CooperativeCancellation => {
                s.state = "failed".into();
                s.error = Some(
                    json!({"code":"JOB_FAILED","message":"unexpected cooperative cancellation"}),
                );
            }
            RunFailure::Failed(message) if j.cancel.load(Ordering::SeqCst) => {
                s.state = "cancelled".into();
                s.stage = "cancelled".into();
                s.error = None;
                let _ = message;
            }
            RunFailure::Failed(message) => {
                s.state = "failed".into();
                s.error = Some(json!({"code":"JOB_FAILED","message":message}));
            }
        }
        s.commit_started = false;
    });
}
fn run_inner(j: &Arc<Control>, resume: bool) -> Result<(), RunFailure> {
    let total_started = Instant::now();
    let validation_started = Instant::now();
    let s = j.snapshot();
    let source_paths = sources(&s.request)?;
    disjoint(&j.root, &source_paths)?;
    let request_bytes = serde_json::to_vec(
        &json!({"request":s.request,"memoryBudgetMiB":s.memory_budget_mib,"workers":s.workers_requested}),
    )
    .map_err(|e| e.to_string())?;
    let request_hash = fingerprint::sha256_bytes(&request_bytes);
    let mut source_hashes = BTreeMap::new();
    for p in &source_paths {
        if !j.checkpoint("validate", None) {
            return Err("cancelled".into());
        }
        source_hashes.insert(
            p.to_string_lossy().into_owned(),
            fingerprint::sha256_file(p).map_err(|e| format!("hash source {}: {e}", p.display()))?,
        );
    }
    let validation_hash_ms = validation_started.elapsed().as_secs_f64() * 1000.0;
    if resume
        && (!s.request_hash.is_empty()
            && (s.request_hash != request_hash || s.source_hashes != source_hashes))
    {
        return Err("source or request fingerprint changed; refusing resume".into());
    }
    j.update(|s| {
        s.request_hash = request_hash;
        s.source_hashes = source_hashes.clone();
        if s.state != "pausing" {
            s.state = "running".into();
        }
        s.stage = "register".into();
        s.progress = s.progress.max(0.02);
    });
    let request_text = serde_json::to_string(&j.snapshot().request).map_err(|e| e.to_string())?;
    let mut check = |stage: &str| {
        if j.checkpoint(stage, None) {
            Ok(())
        } else {
            Err("cancelled".into())
        }
    };
    let registration_started = Instant::now();
    let layout_path = j.root.join("layout.json");
    let mut alignment_cache_hit = false;
    let layout = if resume && layout_path.is_file() {
        let bytes = fs::read(&layout_path).map_err(|e| e.to_string())?;
        let hash = fingerprint::sha256_bytes(&bytes);
        if j.snapshot().layout_hash.as_deref() != Some(hash.as_str()) {
            return Err("saved layout hash changed; refusing resume".into());
        }
        serde_json::from_slice(&bytes).map_err(|e| e.to_string())?
    } else if s.request["useAlignmentCache"].as_bool().unwrap_or(true) {
        if let Some(cache_dir) = s.request["alignmentCacheDir"].as_str() {
            let cache_key = alignment_cache_key(&s.request, &source_hashes);
            let entry = PathBuf::from(cache_dir).join(format!("{cache_key}.json"));
            if let Some(cached_layout) = read_alignment_cache(&entry, &cache_key) {
                alignment_cache_hit = true;
                cached_layout
            } else {
                let result = spherical::align_json_with_checkpoint(&request_text, &mut check)
                    .map_err(|e| e.message)?;
                let layout_bytes = serde_json::to_vec(&result).map_err(|e| e.to_string())?;
                let layout_json =
                    String::from_utf8(layout_bytes.clone()).map_err(|e| e.to_string())?;
                let record = json!({"schemaVersion":1,"key":cache_key,"layoutHash":fingerprint::sha256_bytes(&layout_bytes),"layoutJson":layout_json});
                let dir = PathBuf::from(cache_dir);
                if fs::create_dir_all(&dir).is_ok() {
                    let _ = write_json_cache_atomic(&entry, &record);
                }
                result
            }
        } else {
            spherical::align_json_with_checkpoint(&request_text, &mut check)
                .map_err(|e| e.message)?
        }
    } else {
        spherical::align_json_with_checkpoint(&request_text, &mut check).map_err(|e| e.message)?
    };
    if !layout_path.exists() {
        write_json_atomic(&layout_path, &layout)?;
        let hash = fingerprint::sha256_file(&layout_path).map_err(|e| e.to_string())?;
        j.update(|s| s.layout_hash = Some(hash));
    }
    let registration_ms = registration_started.elapsed().as_secs_f64() * 1000.0;
    let width = layout["width"].as_u64().unwrap_or(0) as u32;
    let height = layout["height"].as_u64().unwrap_or(0) as u32;
    j.update(|s| {
        s.layout_path = Some("layout.json".into());
        s.width = Some(width);
        s.height = Some(height);
        s.stage = "render-level-0".into();
        s.progress = 0.2;
    });
    if resume && j.root.join("manifest.json").is_file() {
        let m: Value = serde_json::from_slice(
            &fs::read(j.root.join("manifest.json")).map_err(|e| e.to_string())?,
        )
        .map_err(|e| e.to_string())?;
        let current = j.snapshot();
        if m["complete"].as_bool() == Some(true)
            && m["requestHash"].as_str() == Some(&current.request_hash)
            && m["sourceHashes"] == json!(current.source_hashes)
        {
            j.update(|s| {
                s.result_stats = Some(json!({"operation":"render","renderer":m["rendererStats"],"pyramid":m["pyramidStats"],"alignmentCacheHit":m["alignmentCacheHit"],"alignment":m["alignmentStats"],"phaseTimesMs":m["phaseTimesMs"]}));
                s.manifest_path = Some("manifest.json".into());
                s.stage = "done".into();
                s.progress = 1.;
            });
            return Ok(());
        }
        return Err("persisted manifest fingerprints do not match; refusing resume".into());
    }
    let stats = spherical_renderer::render_layout_tiles_with_options(
        &layout,
        &j.root,
        j.snapshot().memory_budget_mib,
        if j.snapshot().request["parallelRendering"]
            .as_bool()
            .unwrap_or(true)
        {
            j.snapshot().workers_effective
        } else {
            1
        },
        j.snapshot().request["useSourceCache"]
            .as_bool()
            .unwrap_or(true),
        |done, total| {
            j.checkpoint(
                "render-level-0",
                Some(0.2 + 0.72 * done as f64 / total.max(1) as f64),
            )
        },
    )
    .map_err(|e| e.to_string())?;
    if j.snapshot().state == "cancelled" {
        return Err("cancelled".into());
    }
    j.update(|s| s.stage = "pyramid".into());
    let pyramid_started = Instant::now();
    let pyramid_workers = if j.snapshot().request["parallelRendering"]
        .as_bool()
        .unwrap_or(true)
    {
        j.snapshot().workers_effective
    } else {
        1
    };
    let (levels, pyramid_stats) = spherical_renderer::build_pyramid_levels_with_options(
        &j.root,
        width,
        height,
        j.snapshot().memory_budget_mib,
        pyramid_workers,
        |done, total| {
            j.checkpoint(
                "pyramid",
                Some(0.92 + 0.06 * done as f64 / total.max(1) as f64),
            )
        },
    )
    .map_err(|e| e.to_string())?;
    let pyramid_ms = pyramid_stats["pyramidMs"]
        .as_f64()
        .unwrap_or_else(|| pyramid_started.elapsed().as_secs_f64() * 1000.0);
    if !verify_fingerprints(j) {
        return Err("source or request fingerprint changed during rendering; refusing to publish a complete manifest".into());
    }
    if !j.begin_commit("commit-render") {
        return Err("cancelled before manifest publication".into());
    }
    let bounds = [
        layout["yawMinRad"].clone(),
        layout["yawMaxRad"].clone(),
        layout["pitchMinRad"].clone(),
        layout["pitchMaxRad"].clone(),
    ];
    let render_ms = stats["renderMs"].as_f64().unwrap_or(0.0);
    let phase_times = json!({"validationAndHash":validation_hash_ms,"registration":registration_ms,"render":render_ms,"pyramid":pyramid_ms,"total":total_started.elapsed().as_secs_f64()*1000.0});
    let alignment_report = alignment_stats(&layout, alignment_cache_hit);
    let manifest = json!({"schemaVersion":1,"projection":"spherical","tileSize":512,"width":width,"height":height,"yawMinRad":bounds[0],"yawMaxRad":bounds[1],"pitchMinRad":bounds[2],"pitchMaxRad":bounds[3],"complete":true,"backend":"cpu-rust-tiled","memoryBudgetMiB":j.snapshot().memory_budget_mib,"workersRequested":j.snapshot().workers_requested,"workersEffective":j.snapshot().workers_effective,"renderWorkers":stats["workersEffective"],"pyramidWorkersEffective":pyramid_stats["workersEffective"],"alignmentCacheHit":alignment_cache_hit,"alignmentStats":alignment_report,"registrationMs":registration_ms,"phaseTimesMs":phase_times,"requestHash":j.snapshot().request_hash,"sourceHashes":j.snapshot().source_hashes,"rendererStats":stats,"pyramidStats":pyramid_stats,"levels":levels});
    write_json_atomic(&j.root.join("manifest.json"), &manifest)?;
    j.update(|s| {
        s.result_stats = Some(json!({"operation":"render","alignmentCacheHit":alignment_cache_hit,"alignment":alignment_report,"phaseTimesMs":phase_times,"renderer":manifest["rendererStats"],"pyramid":manifest["pyramidStats"]}));
        s.manifest_path = Some("manifest.json".into());
        s.stage = "done".into();
        s.progress = 1.;
    });
    Ok(())
}
fn verify_fingerprints(j: &Control) -> bool {
    let s = j.snapshot();
    let bytes = match serde_json::to_vec(
        &json!({"request":s.request,"memoryBudgetMiB":s.memory_budget_mib,"workers":s.workers_requested}),
    ) {
        Ok(v) => v,
        Err(_) => return false,
    };
    if fingerprint::sha256_bytes(&bytes) != s.request_hash {
        return false;
    }
    let paths = match sources(&s.request) {
        Ok(v) => v,
        Err(_) => return false,
    };
    let mut hashes = BTreeMap::new();
    for p in paths {
        let h = match fingerprint::sha256_file(&p) {
            Ok(h) => h,
            Err(_) => return false,
        };
        hashes.insert(p.to_string_lossy().into_owned(), h);
    }
    hashes == s.source_hashes
}
fn fingerprint_request(request: &Value) -> Value {
    let mut value = request.clone();
    if let Some(obj) = value.as_object_mut() {
        for key in [
            "outputDir",
            "workers",
            "parallelRendering",
            "useSourceCache",
            "useAlignmentCache",
            "parallelMatching",
            "alignmentCacheDir",
            "memoryBudgetMiB",
            "memoryBudgetMib",
        ] {
            obj.remove(key);
        }
    }
    value
}
fn alignment_stats(layout: &Value, cache_hit: bool) -> Value {
    let report = &layout["report"];
    json!({
        "cached":cache_hit,
        "matchingWorkers":report["effectiveMatchingWorkers"],
        "parallelMatching":report["parallelMatching"],
        "requestedMatchingWorkers":report["requestedMatchingWorkers"],
        "effectiveMatchingWorkers":report["effectiveMatchingWorkers"],
        "requestedWorkers":report["requestedWorkers"],
        "effectiveWorkers":report["effectiveWorkers"],
        "featureType":report["featureType"],
        "matcherType":report["matcherType"],
        "registrationMegapixels":report["registrationMegapixels"],
        "neighborMode":report["neighborMode"],
        "qualityStatus":report["qualityStatus"],
        "gridOverlapEstimate":report["gridOverlapEstimate"],
        "featureExtractionMs":report["featureExtractionMs"],
        "initialMatchingMs":report["initialMatchingMs"],
        "lowContrastRetryMs":report["lowContrastRetryMs"],
        "claheRetryMs":report["claheRetryMs"],
        "poseOptimizationMs":report["poseOptimizationMs"],
        "totalAlignmentMs":report["totalAlignmentMs"]
    })
}
fn alignment_cache_key(request: &Value, hashes: &BTreeMap<String, String>) -> String {
    alignment_cache_key_for_version(ALIGNMENT_CACHE_ALGORITHM_VERSION, request, hashes)
}
fn alignment_cache_key_for_version(
    version: u32,
    request: &Value,
    hashes: &BTreeMap<String, String>,
) -> String {
    let bytes = serde_json::to_vec(&json!({"schemaVersion":1,"algorithmVersion":version,"request":fingerprint_request(request),"sourceHashes":hashes})).unwrap_or_default();
    fingerprint::sha256_bytes(&bytes)
}
fn valid_alignment_record(record: &Value, key: &str) -> bool {
    if record["schemaVersion"].as_u64() != Some(1) || record["key"].as_str() != Some(key) {
        return false;
    }
    let Some(layout_json) = record["layoutJson"].as_str() else {
        return false;
    };
    let expected_hash = fingerprint::sha256_bytes(layout_json.as_bytes());
    let Some(layout) = serde_json::from_str::<Value>(layout_json).ok() else {
        return false;
    };
    record["layoutHash"].as_str() == Some(expected_hash.as_str())
        && layout["schemaVersion"].as_u64() == Some(1)
        && layout["projection"].as_str() == Some("spherical")
        && layout["width"].as_u64().is_some_and(|n| n > 0)
        && layout["height"].as_u64().is_some_and(|n| n > 0)
        && layout["tiles"]
            .as_array()
            .is_some_and(|tiles| !tiles.is_empty())
}
fn read_alignment_cache(path: &Path, key: &str) -> Option<Value> {
    let _guard = ALIGNMENT_CACHE_IO
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let bytes = fs::read(path).ok()?;
    let record = serde_json::from_slice::<Value>(&bytes).ok()?;
    if !valid_alignment_record(&record, key) {
        return None;
    }
    serde_json::from_str(record["layoutJson"].as_str()?).ok()
}
fn write_json_cache_atomic(path: &Path, value: &Value) -> std::io::Result<()> {
    let _guard = ALIGNMENT_CACHE_IO
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let temp = path.with_extension("json.tmp");
    let mut file = fs::File::create(&temp)?;
    file.write_all(&serde_json::to_vec(value).map_err(std::io::Error::other)?)?;
    file.sync_all()?;
    if path.exists() {
        let backup = path.with_extension("json.old");
        if backup.exists() {
            fs::remove_file(&backup)?;
        }
        fs::rename(path, &backup)?;
        if let Err(error) = fs::rename(&temp, path) {
            let _ = fs::rename(&backup, path);
            return Err(error);
        }
        let _ = fs::remove_file(backup);
        return Ok(());
    }
    fs::rename(temp, path)
}
fn write_json_atomic(p: &Path, v: &Value) -> Result<(), String> {
    let temp = p.with_extension("json.tmp");
    let data = serde_json::to_vec_pretty(v).map_err(|e| e.to_string())?;
    let mut f = fs::File::create(&temp).map_err(|e| e.to_string())?;
    f.write_all(&data).map_err(|e| e.to_string())?;
    f.sync_all().map_err(|e| e.to_string())?;
    if p.exists() {
        let old = fs::read(p).map_err(|e| e.to_string())?;
        if old == data {
            let _ = fs::remove_file(temp);
            return Ok(());
        }
        let _ = fs::remove_file(temp);
        return Err(format!(
            "refusing to replace existing job artifact {}",
            p.display()
        ));
    }
    fs::rename(temp, p).map_err(|e| e.to_string())
}
fn has_completed_render_checkpoint(j: &Control, snapshot: &Snapshot) -> bool {
    if snapshot.operation != "export"
        || snapshot.layout_path.as_deref() != Some("layout.json")
        || snapshot.manifest_path.as_deref() != Some("manifest.json")
    {
        return false;
    }
    let layout_bytes = match fs::read(j.root.join("layout.json")) {
        Ok(bytes) => bytes,
        Err(_) => return false,
    };
    let Some(expected_layout_hash) = snapshot.layout_hash.as_deref() else {
        return false;
    };
    if fingerprint::sha256_bytes(&layout_bytes) != expected_layout_hash {
        return false;
    }
    let layout: Value = match serde_json::from_slice(&layout_bytes) {
        Ok(value) => value,
        Err(_) => return false,
    };
    if layout["schemaVersion"].as_u64() != Some(1)
        || layout["projection"].as_str() != Some("spherical")
        || layout["width"].as_u64().map_or(true, |value| value == 0)
        || layout["height"].as_u64().map_or(true, |value| value == 0)
        || !layout["tiles"]
            .as_array()
            .is_some_and(|tiles| !tiles.is_empty())
    {
        return false;
    }
    let manifest: Value = match fs::read(j.root.join("manifest.json"))
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
    {
        Some(value) => value,
        None => return false,
    };
    manifest["schemaVersion"].as_u64() == Some(1)
        && manifest["complete"].as_bool() == Some(true)
        && manifest["requestHash"].as_str() == Some(snapshot.request_hash.as_str())
        && manifest["sourceHashes"] == json!(snapshot.source_hashes)
        && manifest["width"] == layout["width"]
        && manifest["height"] == layout["height"]
        && snapshot.width == layout["width"].as_u64().map(|value| value as u32)
        && snapshot.height == layout["height"].as_u64().map(|value| value as u32)
        && manifest["levels"]
            .as_array()
            .is_some_and(|levels| !levels.is_empty())
}
fn export(c: Command) -> Value {
    let j = match get_job(c.job_id.as_deref()) {
        Ok(j) => j,
        Err(e) => return fail("JOB_NOT_FOUND", e),
    };
    let snap = j.snapshot();
    let retrying_failed_export = ["failed", "cancelled"].contains(&snap.state.as_str())
        && has_completed_render_checkpoint(&j, &snap);
    if snap.state != "completed" && !retrying_failed_export {
        return fail("INVALID_STATE", "export requires a completed render");
    }
    let Some(dest) = c.destination else {
        return fail("INVALID_REQUEST", "destination is required");
    };
    let destination = PathBuf::from(dest);
    if export_format_for_path(&destination).is_none() {
        return fail(
            "INVALID_REQUEST",
            "export destination extension must be .png, .tif, .tiff, or .jxl",
        );
    }
    if destination.exists() {
        return fail("OUTPUT_EXISTS", "export destination already exists");
    }
    if export_format_for_path(&destination) == Some("jxl") && !crate::jxl_export::available() {
        return fail(
            "CAPABILITY_UNAVAILABLE",
            "this core was built without the official libjxl chunked encoder",
        );
    }
    if let Ok(src) = sources(&snap.request) {
        let target = destination
            .parent()
            .and_then(|p| p.canonicalize().ok())
            .and_then(|p| destination.file_name().map(|n| p.join(n)))
            .unwrap_or_else(|| destination.clone());
        if src
            .iter()
            .any(|p| target.starts_with(p) || p.starts_with(&target))
        {
            return fail(
                "PATH_OVERLAP",
                "export destination cannot overwrite a source",
            );
        }
    }
    if let Err(e) = job_resources::reserve(&j.root, &destination, 1, snap.memory_budget_mib) {
        return fail("RESOURCE_BUSY", e);
    }
    j.cancel.store(false, Ordering::SeqCst);
    j.update(|s| {
        s.state = "running".into();
        s.stage = "export".into();
        s.progress = 0.92;
        s.operation = "export".into();
        s.error = None;
        s.commit_started = false;
        s.export_destination = Some(destination.to_string_lossy().into_owned());
    });
    j.worker_active.store(true, Ordering::SeqCst);
    let worker = j.clone();
    if let Err(error) = thread::Builder::new()
        .name("lumia-export-job".into())
        .spawn(move || run_export_to(worker, destination))
    {
        j.update(|s| {
            s.state = "failed".into();
            s.error = Some(json!({"code":"SPAWN_FAILED","message":error.to_string()}));
        });
        j.worker_active.store(false, Ordering::SeqCst);
        job_resources::release(&j.root);
        return fail("SPAWN_FAILED", error);
    }
    let mut v = response(&get_job(Some(&snap.job_id)).unwrap().snapshot());
    v["exportQueued"] = json!(true);
    v
}
fn run_export(j: Arc<Control>) {
    let dest = PathBuf::from(
        j.snapshot()
            .export_destination
            .unwrap_or_else(|| j.root.join("panorama.png").to_string_lossy().into_owned()),
    );
    run_export_to(j, dest)
}
fn run_export_to(j: Arc<Control>, dest: PathBuf) {
    let export_started = Instant::now();
    let previous_stats = j.snapshot().result_stats.unwrap_or(Value::Null);
    let previous_render_stats = if previous_stats["operation"].as_str() == Some("render") {
        previous_stats
    } else {
        previous_stats["renderStats"].clone()
    };
    let mut lease = ActiveLease::new(j.clone());
    if !verify_fingerprints(&j) {
        j.update(|s|{s.state="failed".into();s.error=Some(json!({"code":"INPUT_CHANGED","message":"source or request fingerprint changed before export"}));});
        lease.release();
        return;
    }
    let res = (|| -> crate::Result<Value> {
        let bytes = fs::read(j.root.join("manifest.json"))?;
        let manifest: Value =
            serde_json::from_slice(&bytes).map_err(|e| crate::Error::Invalid(e.to_string()))?;
        let mut checkpoint = |done: u32, total: u32| {
            let checkpoint_stage = if export_format_for_path(&dest) == Some("jxl") {
                "spool-jxl"
            } else {
                "export"
            };
            if j.checkpoint(
                checkpoint_stage,
                Some(0.92 + 0.08 * done as f64 / total.max(1) as f64),
            ) {
                Ok(())
            } else {
                Err(crate::Error::Cancelled)
            }
        };
        let mut encode_checkpoint = |done: u32, total: u32| {
            if j.checkpoint(
                "encode-jxl",
                Some(0.92 + 0.08 * done as f64 / total.max(1) as f64),
            ) {
                Ok(())
            } else {
                Err(crate::Error::Cancelled)
            }
        };
        let mut commit = || {
            if j.begin_commit("commit-export") {
                Ok(())
            } else if let Some(error) = j.snapshot().error {
                Err(crate::Error::Invalid(error.to_string()))
            } else {
                Err(crate::Error::Cancelled)
            }
        };
        match export_format_for_path(&dest) {
            Some("png") => crate::spherical_export::export_level0_png(
                &j.root,
                &manifest,
                &dest,
                j.snapshot().memory_budget_mib,
                &mut checkpoint,
                &mut commit,
            ),
            Some("tiff") => crate::tiff_export::export_level0_tiff(
                &j.root,
                &manifest,
                &dest,
                j.snapshot().memory_budget_mib,
                &mut checkpoint,
                &mut commit,
            ),
            Some("jxl") => {
                j.update(|state| state.stage = "spool-jxl".into());
                crate::jxl_export::export_level0_jxl(
                    &j.root,
                    &manifest,
                    &dest,
                    j.snapshot().memory_budget_mib,
                    1,
                    &mut checkpoint,
                    &mut encode_checkpoint,
                    &mut commit,
                )
            }
            _ => Err(crate::Error::Invalid(
                "export destination extension must be .png, .tif, .tiff, or .jxl".into(),
            )),
        }
    })();
    j.update(|s| match res {
        Ok(mut stats) => {
            stats["exportMs"] = json!(export_started.elapsed().as_secs_f64() * 1000.0);
            if let Some(previous) = previous_render_stats.as_object() {
                for (key, value) in previous {
                    if key != "operation" && stats.get(key).is_none() {
                        stats[key.as_str()] = value.clone();
                    }
                }
            }
            stats["operation"] = json!("export");
            s.state = "completed".into();
            s.stage = "done".into();
            s.progress = 1.;
            s.error = None;
            s.result_stats = Some(stats);
            s.commit_started = false;
        }
        Err(e) => {
            let cooperative_cancel = matches!(e, crate::Error::Cancelled);
            let cancelled = j.cancel.load(Ordering::SeqCst);
            let paused = cooperative_cancel && s.state == "pausing" && !cancelled;
            s.state = if paused {
                "paused".into()
            } else if cancelled {
                "cancelled".into()
            } else {
                "failed".into()
            };
            if paused {
                s.stage = "paused".into();
                s.error = None;
            } else {
                s.error = Some(json!({"code":"EXPORT_FAILED","message":e.to_string()}));
            }
            s.commit_started = false;
        }
    });
    lease.release();
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::MutexGuard;
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    fn grid_shape_request(rows: u64, columns: u64) -> Value {
        let tiles = if let Some(count) = rows
            .checked_mul(columns)
            .and_then(|n| usize::try_from(n).ok())
        {
            (0..count).map(|index| json!({"row": index / columns as usize, "column": index % columns as usize})).collect::<Vec<_>>()
        } else {
            Vec::new()
        };
        json!({
            "rows": rows, "columns": columns, "tiles": tiles,
            "sourceWidth": 100, "sourceHeight": 80,
            "fx": 75.0, "fy": 75.0, "cx": 49.5, "cy": 39.5
        })
    }

    #[test]
    fn job_shape_accepts_more_than_1024_tiles_and_rejects_dimension_overflow() {
        assert!(validate_request_shape(&grid_shape_request(33, 33)).is_ok());
        assert!(validate_request_shape(&grid_shape_request(129, 2)).is_ok());
        let overflow = json!({
            "rows": u64::MAX, "columns": 2, "tiles": [],
            "sourceWidth": 100, "sourceHeight": 80,
            "fx": 75.0, "fy": 75.0, "cx": 49.5, "cy": 39.5
        });
        assert!(validate_request_shape(&overflow)
            .unwrap_err()
            .contains("overflow"));
    }

    #[test]
    fn export_format_is_inferred_from_supported_destination_extensions() {
        assert_eq!(
            export_format_for_path(Path::new("panorama.png")),
            Some("png")
        );
        assert_eq!(
            export_format_for_path(Path::new("panorama.PNG")),
            Some("png")
        );
        assert_eq!(export_format_for_path(Path::new("panorama")), Some("png"));
        assert_eq!(
            export_format_for_path(Path::new("panorama.tif")),
            Some("tiff")
        );
        assert_eq!(
            export_format_for_path(Path::new("panorama.TIFF")),
            Some("tiff")
        );
        assert_eq!(
            export_format_for_path(Path::new("panorama.jxl")),
            Some("jxl")
        );
        assert_eq!(
            export_format_for_path(Path::new("panorama.JXL")),
            Some("jxl")
        );
        assert_eq!(export_format_for_path(Path::new("panorama.webp")), None);
    }

    fn lock_jobs() -> MutexGuard<'static, ()> {
        job_resources::TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner())
    }

    fn temp_dir(label: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!("lumia-job-{label}-{}-{nonce}", std::process::id()))
    }

    #[test]
    fn alignment_cache_key_ignores_execution_options_but_tracks_algorithm_and_sources() {
        let request = json!({"fov":70,"grid":{"rows":2},"parallelRendering":true,"workers":4,"useAlignmentCache":true});
        let mut hashes = BTreeMap::new();
        hashes.insert("source.jpg".into(), "a".repeat(64));
        let key = alignment_cache_key(&request, &hashes);
        let mut execution_changed = request.clone();
        execution_changed["parallelRendering"] = json!(false);
        execution_changed["workers"] = json!(1);
        execution_changed["useAlignmentCache"] = json!(false);
        assert_eq!(key, alignment_cache_key(&execution_changed, &hashes));
        execution_changed["fov"] = json!(71);
        assert_ne!(key, alignment_cache_key(&execution_changed, &hashes));
        assert_ne!(key, alignment_cache_key_for_version(4, &request, &hashes));
        assert_eq!(
            key,
            alignment_cache_key_for_version(14, &request, &hashes),
            "the current component-pose algorithm must use cache version 14"
        );
        assert_ne!(
            key,
            alignment_cache_key_for_version(13, &request, &hashes),
            "cache version 13 must not return layouts from the coordinate-descent algorithm"
        );
        assert_ne!(key, alignment_cache_key_for_version(12, &request, &hashes));
        hashes.insert("source.jpg".into(), "b".repeat(64));
        assert_ne!(key, alignment_cache_key(&request, &hashes));
    }

    #[test]
    fn corrupt_alignment_cache_record_is_rejected() {
        let layout = json!({"schemaVersion":1,"projection":"spherical","width":2,"height":1,"yawMinRad":0.12345678901234566,"tiles":[{"cameraToWorld":[0.12345678901234566]}],"report":{"qualityStatus":"needs-visual-review","effectiveMatchingWorkers":3}});
        let layout_json = serde_json::to_string(&layout).unwrap();
        let hash = fingerprint::sha256_bytes(layout_json.as_bytes());
        let valid =
            json!({"schemaVersion":1,"key":"abc","layoutHash":hash,"layoutJson":layout_json});
        assert!(valid_alignment_record(&valid, "abc"));
        let parsed = serde_json::from_str::<Value>(valid["layoutJson"].as_str().unwrap()).unwrap();
        assert_eq!(parsed, layout);
        let summary = alignment_stats(&layout, true);
        assert_eq!(summary["qualityStatus"], "needs-visual-review");
        assert_eq!(summary["matchingWorkers"], 3);
        assert_eq!(summary["cached"], true);
        let mut corrupt_layout = layout.clone();
        corrupt_layout["width"] = json!(9);
        let mut corrupt = valid.clone();
        corrupt["layoutJson"] = json!(serde_json::to_string(&corrupt_layout).unwrap());
        assert!(!valid_alignment_record(&corrupt, "abc"));
        assert!(!valid_alignment_record(&valid, "different-key"));
        let path = temp_dir("alignment-cache-corrupt");
        fs::write(&path, b"truncated json").unwrap();
        assert!(read_alignment_cache(&path, "abc").is_none());
        fs::write(&path, serde_json::to_vec(&valid).unwrap()).unwrap();
        assert_eq!(read_alignment_cache(&path, "abc"), Some(layout.clone()));
        fs::write(&path, serde_json::to_vec(&corrupt).unwrap()).unwrap();
        assert!(read_alignment_cache(&path, "abc").is_none());
        let _ = fs::remove_file(path);
    }

    #[test]
    fn concurrent_same_key_cache_writes_remain_readable() {
        let path = temp_dir("alignment-cache-concurrent");
        let layout = json!({"schemaVersion":1,"projection":"spherical","width":2,"height":1,"yawMinRad":0.0,"tiles":[{"cameraToWorld":[1.0]}]});
        let layout_json = serde_json::to_string(&layout).unwrap();
        let record = json!({
            "schemaVersion": 1,
            "key": "shared-key",
            "layoutHash": fingerprint::sha256_bytes(layout_json.as_bytes()),
            "layoutJson": layout_json
        });
        let start = Arc::new(std::sync::Barrier::new(3));
        let readers_path = path.clone();
        let readers_start = start.clone();
        let reader = thread::spawn(move || {
            readers_start.wait();
            for _ in 0..64 {
                if let Some(value) = read_alignment_cache(&readers_path, "shared-key") {
                    assert!(valid_alignment_record(&record_for(&value), "shared-key"));
                }
            }
        });
        let writer_threads = (0..2)
            .map(|_| {
                let path = path.clone();
                let record = record.clone();
                let start = start.clone();
                thread::spawn(move || {
                    start.wait();
                    for _ in 0..16 {
                        write_json_cache_atomic(&path, &record).unwrap();
                    }
                })
            })
            .collect::<Vec<_>>();
        for writer in writer_threads {
            writer.join().unwrap();
        }
        reader.join().unwrap();
        assert_eq!(read_alignment_cache(&path, "shared-key"), Some(layout));
        let _ = fs::remove_file(path);
    }

    fn record_for(layout: &Value) -> Value {
        let layout_json = serde_json::to_string(layout).unwrap();
        json!({
            "schemaVersion": 1,
            "key": "shared-key",
            "layoutHash": fingerprint::sha256_bytes(layout_json.as_bytes()),
            "layoutJson": layout_json
        })
    }

    #[test]
    fn start_command_reads_documented_memory_budget_key_and_enforces_limit() {
        let command: Command = serde_json::from_value(json!({
            "command": "start",
            "memoryBudgetMiB": 512
        }))
        .unwrap();
        assert_eq!(command.memory_budget_mib, 512);

        let legacy: Command = serde_json::from_value(json!({
            "command": "start",
            "memoryBudgetMib": 256
        }))
        .unwrap();
        assert_eq!(legacy.memory_budget_mib, 256);

        let invalid: Command = serde_json::from_value(json!({
            "command": "start",
            "memoryBudgetMiB": 4097
        }))
        .unwrap();
        let result = start(invalid);
        assert_eq!(result["error"]["code"], "INVALID_REQUEST");
        assert!(result["error"]["message"]
            .as_str()
            .unwrap()
            .contains("memoryBudgetMiB"));
    }

    #[test]
    fn capabilities_and_configure_resources_report_reservations_and_safe_limits() {
        let _guard = lock_jobs();
        let original = job_resources::limits();
        let cap = handle(r#"{"command":"capabilities"}"#);
        assert_eq!(cap["ok"], true);
        assert_eq!(cap["capabilities"]["backend"], "cpu-rust-tiled");
        assert_eq!(cap["capabilities"]["gpuAvailable"], false);
        assert_eq!(cap["capabilities"]["memoryBudgetKind"], "reservation");
        assert_eq!(cap["capabilities"]["maxConcurrentJobsLimit"], 8);

        job_resources::configure(1, 256, 2).unwrap();
        let job = temp_dir("resource-config");
        assert!(job_resources::reserve(&job, &job, 1, 256).is_ok());
        let busy = handle(
            r#"{"command":"configureResources","totalCpuWorkers":1,"totalMemoryBudgetMiB":128,"maxConcurrentJobs":2}"#,
        );
        assert_eq!(busy["error"]["code"], "RESOURCE_BUSY");
        let current = handle(r#"{"command":"capabilities"}"#);
        assert_eq!(current["capabilities"]["activeJobs"], 1);
        assert_eq!(current["capabilities"]["reservedWorkers"], 1);
        assert_eq!(current["capabilities"]["reservedMemoryMiB"], 256);
        let invalid = handle(
            r#"{"command":"configureResources","totalCpuWorkers":1,"totalMemoryBudgetMiB":128,"maxConcurrentJobs":9}"#,
        );
        assert_eq!(invalid["error"]["code"], "INVALID_REQUEST");
        job_resources::release(&job);
        job_resources::configure(
            original.total_cpu_workers,
            original.total_memory_mib,
            original.max_concurrent_jobs,
        )
        .unwrap();
    }

    fn test_control(root: &Path, source: &Path) -> Arc<Control> {
        fs::create_dir_all(root).unwrap();
        let canonical_source = source.canonicalize().unwrap();
        let request = json!({
            "rows": 1,
            "columns": 1,
            "sourceWidth": 1,
            "sourceHeight": 1,
            "fx": 1.0,
            "fy": 1.0,
            "cx": 0.0,
            "cy": 0.0,
            "tiles": [{"row": 0, "column": 0, "path": canonical_source.to_string_lossy()}]
        });
        let memory_budget_mib = 128;
        let workers_requested = 1;
        let workers_effective = 1;
        let request_bytes = serde_json::to_vec(&json!({
            "request": request,
            "memoryBudgetMiB": memory_budget_mib,
            "workers": workers_requested
        }))
        .unwrap();
        let mut source_hashes = BTreeMap::new();
        source_hashes.insert(
            canonical_source.to_string_lossy().into_owned(),
            fingerprint::sha256_file(&canonical_source).unwrap(),
        );
        let snapshot = Snapshot {
            schema_version: 1,
            job_id: root.to_string_lossy().into_owned(),
            request,
            memory_budget_mib,
            workers_requested,
            workers_effective,
            state: "running".into(),
            stage: "render-level-0".into(),
            progress: 0.5,
            backend: "cpu-rust-tiled".into(),
            request_hash: fingerprint::sha256_bytes(&request_bytes),
            source_hashes,
            error: None,
            result_stats: None,
            layout_path: None,
            manifest_path: None,
            operation: "render".into(),
            export_destination: None,
            layout_hash: None,
            width: None,
            height: None,
            commit_started: false,
        };
        persist(root, &snapshot).unwrap();
        Arc::new(Control {
            root: root.to_path_buf(),
            snapshot: Mutex::new(snapshot),
            changed: Condvar::new(),
            cancel: AtomicBool::new(false),
            worker_active: AtomicBool::new(true),
            verify_on_resume: AtomicBool::new(false),
        })
    }

    #[test]
    fn pause_unwinds_at_checkpoint_and_releases_resources_before_resume() {
        let _guard = lock_jobs();
        let original = job_resources::limits();
        let root = temp_dir("pause-resume");
        let source = root.with_extension("source");
        fs::write(&source, b"immutable source fixture").unwrap();
        let control = test_control(&root, &source);
        assert!(job_resources::reserve(&root, &root, 1, 128).is_ok());
        let pause_result = pause(control.clone());
        assert_eq!(pause_result["ok"], true);
        let worker_control = control.clone();
        let worker = thread::spawn(move || worker_control.checkpoint("render-level-0", Some(0.6)));
        assert!(!worker.join().unwrap());
        assert_eq!(control.snapshot().state, "pausing");
        // run() performs this state transition after render locals have unwound.
        control.update(|s| {
            s.state = "paused".into();
            s.stage = "paused".into();
        });
        control.worker_active.store(false, Ordering::SeqCst);
        assert!(job_resources::release(&root));
        assert_eq!(job_resources::usage(), (0, 0, 0));
        job_resources::configure(1, 128, 1).unwrap();
        let blocker = root.with_extension("blocker");
        assert!(job_resources::reserve(&blocker, &blocker, 1, 128).is_ok());
        let resume_result = resume(control.clone());
        assert_eq!(resume_result["error"]["code"], "RESOURCE_BUSY");
        assert_eq!(control.snapshot().state, "paused");
        job_resources::release(&blocker);
        job_resources::configure(
            original.total_cpu_workers,
            original.total_memory_mib,
            original.max_concurrent_jobs,
        )
        .unwrap();
        let _ = fs::remove_file(source);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn renderer_tile_checkpoint_pauses_releases_and_resumes() {
        let _guard = lock_jobs();
        let original = job_resources::limits();
        job_resources::configure(1, 128, 1).unwrap();
        let root = temp_dir("renderer-pause-resume");
        let source = root.with_extension("source.png");
        image::RgbaImage::from_pixel(8, 8, image::Rgba([90, 120, 150, 255]))
            .save(&source)
            .unwrap();
        let control = test_control(&root, &source);
        let layout = json!({
            "schemaVersion":1,"projection":"spherical","width":512,"height":512,
            "yawMinRad":-0.08,"yawMaxRad":0.08,"pitchMinRad":-0.08,"pitchMaxRad":0.08,
            "tiles":[{"path":source.canonicalize().unwrap().to_string_lossy(),
                "width":8,"height":8,"fx":20.0,"fy":20.0,"cx":3.5,"cy":3.5,
                "cameraToWorld":[1.0,0.0,0.0,0.0,1.0,0.0,0.0,0.0,1.0]}]
        });
        let layout_path = root.join("layout.json");
        write_json_atomic(&layout_path, &layout).unwrap();
        let layout_hash = fingerprint::sha256_file(&layout_path).unwrap();
        control.update(|s| {
            s.layout_path = Some("layout.json".into());
            s.layout_hash = Some(layout_hash);
            s.width = Some(512);
            s.height = Some(512);
        });
        assert!(job_resources::reserve(&root, &root, 1, 128).is_ok());

        let mut lease = ActiveLease::new(control.clone());
        let mut requested_pause = false;
        let render = spherical_renderer::render_layout_tiles_with_options(
            &layout,
            &root,
            128,
            1,
            true,
            |done, total| {
                if !requested_pause {
                    requested_pause = true;
                    assert_eq!(pause(control.clone())["ok"], true);
                }
                control.checkpoint(
                    "render-level-0",
                    Some(0.2 + 0.72 * done as f64 / total.max(1) as f64),
                )
            },
        );
        assert!(matches!(render, Err(crate::Error::Cancelled)));
        finish_run_failure(&control, RunFailure::from("job cancelled"));
        lease.release();
        assert!(requested_pause);
        assert_eq!(control.snapshot().state, "paused");
        assert_eq!(job_resources::usage(), (0, 0, 0));

        let resumed = resume(control.clone());
        assert_eq!(resumed["ok"], true);
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            let state = control.snapshot().state;
            if state == "completed" || state == "failed" || state == "cancelled" {
                assert_eq!(
                    state,
                    "completed",
                    "{}",
                    control.snapshot().error.unwrap_or(Value::Null)
                );
                break;
            }
            assert!(Instant::now() < deadline, "resume did not finish: {state}");
            thread::sleep(Duration::from_millis(20));
        }
        assert_eq!(job_resources::usage(), (0, 0, 0));
        job_resources::configure(
            original.total_cpu_workers,
            original.total_memory_mib,
            original.max_concurrent_jobs,
        )
        .unwrap();
        let _ = fs::remove_file(source);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn cold_export_resume_uses_one_worker_and_persisted_destination() {
        let _guard = lock_jobs();
        let original = job_resources::limits();
        job_resources::configure(1, 128, 1).unwrap();
        let root = temp_dir("export-resume");
        let source = root.with_extension("source");
        fs::write(&source, b"immutable source fixture").unwrap();
        let control = test_control(&root, &source);
        let destination = root.with_extension("panorama.png");
        fs::create_dir_all(root.join("level-0")).unwrap();
        image::RgbaImage::from_pixel(1, 1, image::Rgba([10, 20, 30, 255]))
            .save(root.join("level-0/0-0.png"))
            .unwrap();
        fs::write(
            root.join("manifest.json"),
            serde_json::to_vec(&json!({
                "width":1,"height":1,"tileSize":512,
                "levels":[{"level":0,"occupied":[{"row":0,"column":0,"path":"level-0/0-0.png","width":1,"height":1}]}]
            }))
            .unwrap(),
        )
        .unwrap();
        control.update(|s| {
            s.state = "paused".into();
            s.stage = "export".into();
            s.operation = "export".into();
            s.export_destination = Some(destination.to_string_lossy().into_owned());
            s.workers_requested = 9;
            s.workers_effective = 9;
            let request_bytes = serde_json::to_vec(&json!({
                "request": s.request.clone(),
                "memoryBudgetMiB": s.memory_budget_mib,
                "workers": s.workers_requested
            }))
            .unwrap();
            s.request_hash = fingerprint::sha256_bytes(&request_bytes);
        });
        let job_id = root.to_string_lossy().into_owned();
        let cold = get_job(Some(&job_id)).unwrap();
        let before_resume = status(cold.clone());
        assert_eq!(before_resume["operation"], "export");
        assert_eq!(before_resume["workersRequested"], 9);
        assert_eq!(before_resume["workersEffective"], 9);
        assert_eq!(before_resume["operationWorkers"], 1);
        assert_eq!(
            before_resume["exportDestination"],
            destination.to_string_lossy().as_ref()
        );

        let resumed = resume(cold.clone());
        assert_eq!(resumed["ok"], true);
        assert_eq!(resumed["operationWorkers"], 1);
        let deadline = Instant::now() + Duration::from_secs(5);
        while cold.snapshot().state == "running" && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(cold.snapshot().state, "completed");
        assert!(destination.is_file());
        assert_eq!(job_resources::usage(), (0, 0, 0));
        job_resources::configure(
            original.total_cpu_workers,
            original.total_memory_mib,
            original.max_concurrent_jobs,
        )
        .unwrap();
        jobs().lock().unwrap().remove(&root);
        let _ = fs::remove_file(source);
        let _ = fs::remove_file(destination);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn failed_export_can_retry_new_destination_from_completed_render_checkpoint() {
        let _guard = lock_jobs();
        let original = job_resources::limits();
        job_resources::configure(1, 128, 1).unwrap();
        let root = temp_dir("failed-export-retry");
        let source = root.with_extension("source");
        fs::write(&source, b"immutable source fixture").unwrap();
        let control = test_control(&root, &source);
        let layout = json!({
            "schemaVersion": 1,
            "projection": "spherical",
            "width": 1,
            "height": 1,
            "tiles": [{"row": 0, "column": 0}]
        });
        let layout_path = root.join("layout.json");
        fs::write(&layout_path, serde_json::to_vec(&layout).unwrap()).unwrap();
        let layout_hash = fingerprint::sha256_file(&layout_path).unwrap();
        fs::create_dir_all(root.join("level-0")).unwrap();
        image::RgbaImage::from_pixel(1, 1, image::Rgba([10, 20, 30, 255]))
            .save(root.join("level-0/0-0.png"))
            .unwrap();
        let before = control.snapshot();
        let manifest = json!({
            "schemaVersion": 1,
            "projection": "spherical",
            "width": 1,
            "height": 1,
            "tileSize": 512,
            "complete": true,
            "requestHash": before.request_hash,
            "sourceHashes": before.source_hashes,
            "levels": [{"level": 0, "occupied": [{
                "row": 0, "column": 0, "path": "level-0/0-0.png",
                "width": 1, "height": 1
            }]}]
        });
        fs::write(
            root.join("manifest.json"),
            serde_json::to_vec(&manifest).unwrap(),
        )
        .unwrap();
        control.update(|snapshot| {
            snapshot.state = "failed".into();
            snapshot.stage = "encode-jxl".into();
            snapshot.operation = "export".into();
            snapshot.error = Some(json!({"code":"EXPORT_FAILED","message":"encoder failed"}));
            snapshot.result_stats = Some(json!({"operation":"render"}));
            snapshot.layout_path = Some("layout.json".into());
            snapshot.manifest_path = Some("manifest.json".into());
            snapshot.layout_hash = Some(layout_hash);
            snapshot.width = Some(1);
            snapshot.height = Some(1);
        });
        control.worker_active.store(false, Ordering::SeqCst);
        jobs().lock().unwrap().insert(root.clone(), control.clone());

        let destination = root.join("retry.png");
        let response = export(Command {
            command: "export".into(),
            request: None,
            output_dir: None,
            job_id: Some(root.to_string_lossy().into_owned()),
            destination: Some(destination.to_string_lossy().into_owned()),
            memory_budget_mib: 128,
            workers: 1,
            total_cpu_workers: None,
            total_memory_budget_mib: None,
            max_concurrent_jobs: None,
        });
        assert_eq!(response["ok"], true, "{response}");
        assert_eq!(response["exportQueued"], true);
        let deadline = Instant::now() + Duration::from_secs(5);
        while control.snapshot().state == "running" && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(control.snapshot().state, "completed");
        assert!(destination.is_file());
        assert_eq!(job_resources::usage(), (0, 0, 0));

        jobs().lock().unwrap().remove(&root);
        job_resources::configure(
            original.total_cpu_workers,
            original.total_memory_mib,
            original.max_concurrent_jobs,
        )
        .unwrap();
        let _ = fs::remove_file(source);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn failed_render_cannot_retry_export_from_incomplete_checkpoint() {
        let _guard = lock_jobs();
        let root = temp_dir("failed-render-export");
        let source = root.with_extension("source");
        fs::write(&source, b"immutable source fixture").unwrap();
        let control = test_control(&root, &source);
        control.update(|snapshot| {
            snapshot.state = "failed".into();
            snapshot.operation = "render".into();
        });
        control.worker_active.store(false, Ordering::SeqCst);
        jobs().lock().unwrap().insert(root.clone(), control.clone());
        let response = export(Command {
            command: "export".into(),
            request: None,
            output_dir: None,
            job_id: Some(root.to_string_lossy().into_owned()),
            destination: Some(root.join("retry.png").to_string_lossy().into_owned()),
            memory_budget_mib: 128,
            workers: 1,
            total_cpu_workers: None,
            total_memory_budget_mib: None,
            max_concurrent_jobs: None,
        });
        assert_eq!(response["ok"], false);
        assert_eq!(response["error"]["code"], "INVALID_STATE");
        assert_eq!(job_resources::usage(), (0, 0, 0));
        jobs().lock().unwrap().remove(&root);
        let _ = fs::remove_file(source);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn cancel_and_final_commit_are_serialized() {
        let _guard = lock_jobs();
        let root = temp_dir("commit-race");
        let source = root.with_extension("source");
        fs::write(&source, b"immutable source fixture").unwrap();
        let control = test_control(&root, &source);

        let cancel_response = cancel(control.clone());
        assert_eq!(cancel_response["cancelRequested"], true);
        assert!(!control.begin_commit("commit-test"));
        assert_eq!(control.snapshot().state, "cancelled");

        control.update(|s| s.state = "running".into());
        control.cancel.store(false, Ordering::SeqCst);
        assert!(control.begin_commit("commit-test"));
        let late_cancel = cancel(control.clone());
        assert_eq!(late_cancel["ok"], false);
        assert_eq!(late_cancel["error"]["code"], "INVALID_STATE");
        assert_eq!(control.snapshot().state, "running");
        assert!(control.snapshot().commit_started);
        assert!(!control.cancel.load(Ordering::SeqCst));

        let job_id = root.to_string_lossy().into_owned();
        let recovered = get_job(Some(&job_id)).unwrap();
        assert_eq!(recovered.snapshot().state, "paused");
        assert!(!recovered.snapshot().commit_started);
        assert_eq!(cancel(recovered)["state"], "cancelled");

        control.worker_active.store(false, Ordering::SeqCst);
        let _ = fs::remove_file(source);
        let _ = fs::remove_dir_all(root);
    }
}
