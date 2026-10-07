//! Process-wide admission control for persistent render and export jobs.
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
};

pub const MAX_CONCURRENT_JOBS: usize = 8;
pub const MAX_WORKERS_PER_JOB: usize = 32;
pub const MIN_JOB_MEMORY_MIB: usize = 128;
pub const MIN_EXPORT_MEMORY_MIB: usize = 16;
/// Hard accounting ceiling; the UI recommends a lower value based on measured headroom.
pub const MAX_JOB_MEMORY_MIB: usize = 131_072;
pub const MAX_TOTAL_MEMORY_MIB: usize = 131_072;
pub const PYRAMID_WORKER_RESERVE_BYTES: u64 = 16 * 1024 * 1024;

/// Convert a MiB reservation to bytes without relying on platform-sized multiplication.
pub fn checked_memory_budget_bytes(memory_budget_mib: usize) -> Option<u64> {
    u64::try_from(memory_budget_mib)
        .ok()?
        .checked_mul(1024 * 1024)
}

fn kibibytes_to_mib(kibibytes: u64) -> Option<usize> {
    usize::try_from(kibibytes / 1024).ok()
}

/// Current physical memory and OS-reported available headroom, in MiB.
/// Mobile callers should prefer the platform runtime's validated live reading.
pub fn system_memory_mib() -> Option<(usize, usize)> {
    #[cfg(windows)]
    {
        #[repr(C)]
        struct MemoryStatusEx {
            length: u32,
            memory_load: u32,
            total_physical: u64,
            available_physical: u64,
            total_page_file: u64,
            available_page_file: u64,
            total_virtual: u64,
            available_virtual: u64,
            available_extended_virtual: u64,
        }
        #[link(name = "kernel32")]
        extern "system" {
            fn GlobalMemoryStatusEx(status: *mut MemoryStatusEx) -> i32;
        }
        let mut status = MemoryStatusEx {
            length: std::mem::size_of::<MemoryStatusEx>() as u32,
            memory_load: 0,
            total_physical: 0,
            available_physical: 0,
            total_page_file: 0,
            available_page_file: 0,
            total_virtual: 0,
            available_virtual: 0,
            available_extended_virtual: 0,
        };
        // SAFETY: the status structure matches MEMORYSTATUSEX and is initialized with its size.
        if unsafe { GlobalMemoryStatusEx(&mut status) } == 0 {
            return None;
        }
        return Some((
            kibibytes_to_mib(status.total_physical / 1024)?,
            kibibytes_to_mib(status.available_physical / 1024)?,
        ));
    }
    #[cfg(target_os = "linux")]
    {
        let contents = std::fs::read_to_string("/proc/meminfo").ok()?;
        let mut total_kib = None;
        let mut available_kib = None;
        for line in contents.lines() {
            let (key, value) = line.split_once(':')?;
            let kib = value.split_whitespace().next()?.parse::<u64>().ok()?;
            match key {
                "MemTotal" => total_kib = Some(kib),
                "MemAvailable" => available_kib = Some(kib),
                _ => {}
            }
        }
        return Some((
            kibibytes_to_mib(total_kib?)?,
            kibibytes_to_mib(available_kib?)?,
        ));
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        None
    }
}

#[cfg(test)]
mod memory_budget_tests {
    use super::*;

    #[test]
    fn memory_budget_conversion_uses_checked_mib_arithmetic() {
        assert_eq!(checked_memory_budget_bytes(128), Some(128 * 1024 * 1024));
        assert_eq!(
            checked_memory_budget_bytes(65_536),
            Some(65_536_u64 * 1024 * 1024)
        );
        assert_eq!(
            checked_memory_budget_bytes(MAX_JOB_MEMORY_MIB),
            Some(MAX_JOB_MEMORY_MIB as u64 * 1024 * 1024)
        );
        #[cfg(target_pointer_width = "64")]
        assert_eq!(checked_memory_budget_bytes(usize::MAX), None);
    }
}

#[cfg(test)]
mod pending_limit_tests {
    use super::*;

    #[test]
    fn pending_lower_limits_atomically_block_new_admissions_until_drain() {
        let current = Limits {
            total_cpu_workers: 8,
            total_memory_mib: 32_768,
            max_concurrent_jobs: 8,
        };
        let pending = Limits {
            total_cpu_workers: 4,
            total_memory_mib: 512,
            max_concurrent_jobs: 1,
        };
        let effective = admission_limits(current, Some(pending));
        assert_eq!(effective.total_cpu_workers, 4);
        assert_eq!(effective.total_memory_mib, 512);
        assert_eq!(effective.max_concurrent_jobs, 1);
        assert!(!can_reserve(effective, 3, 3, 384, 1, 128));
        assert!(!can_reserve(effective, 0, 0, 512, 1, 128));
        assert!(can_reserve(effective, 0, 0, 0, 1, 128));
    }

    #[test]
    fn pending_limits_apply_only_after_existing_reservations_fit() {
        let current = Limits {
            total_cpu_workers: 8,
            total_memory_mib: 32_768,
            max_concurrent_jobs: 8,
        };
        let pending = Limits {
            total_cpu_workers: 4,
            total_memory_mib: 512,
            max_concurrent_jobs: 1,
        };
        let mut state = State {
            limits: current,
            pending_limits: Some(pending),
            reservations: BTreeMap::from([(
                PathBuf::from("held-job"),
                Reservation {
                    workers: 2,
                    memory_mib: 1024,
                    output: PathBuf::from("held-output"),
                },
            )]),
        };
        apply_pending_if_drained(&mut state);
        assert_eq!(state.limits.total_memory_mib, current.total_memory_mib);
        assert!(state.pending_limits.is_some());

        state.reservations.clear();
        apply_pending_if_drained(&mut state);
        assert_eq!(state.limits.total_memory_mib, pending.total_memory_mib);
        assert_eq!(state.limits.max_concurrent_jobs, 1);
        assert!(state.pending_limits.is_none());
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Limits {
    pub total_cpu_workers: usize,
    pub total_memory_mib: usize,
    pub max_concurrent_jobs: usize,
}

#[derive(Clone, Debug)]
struct Reservation {
    workers: usize,
    memory_mib: usize,
    output: PathBuf,
}

#[derive(Debug)]
struct State {
    limits: Limits,
    pending_limits: Option<Limits>,
    reservations: BTreeMap<PathBuf, Reservation>,
}

fn admission_limits(current: Limits, pending: Option<Limits>) -> Limits {
    let Some(pending) = pending else {
        return current;
    };
    Limits {
        total_cpu_workers: current.total_cpu_workers.min(pending.total_cpu_workers),
        total_memory_mib: current.total_memory_mib.min(pending.total_memory_mib),
        max_concurrent_jobs: current.max_concurrent_jobs.min(pending.max_concurrent_jobs),
    }
}

fn usage_fits(limits: Limits, jobs: usize, workers: usize, memory_mib: usize) -> bool {
    jobs <= limits.max_concurrent_jobs
        && workers <= limits.total_cpu_workers
        && memory_mib <= limits.total_memory_mib
}

fn can_reserve(
    limits: Limits,
    jobs: usize,
    workers: usize,
    memory_mib: usize,
    requested_workers: usize,
    requested_memory_mib: usize,
) -> bool {
    usage_fits(
        limits,
        jobs.saturating_add(1),
        workers.saturating_add(requested_workers),
        memory_mib.saturating_add(requested_memory_mib),
    )
}

fn reservation_usage(state: &State) -> (usize, usize, usize) {
    state
        .reservations
        .values()
        .fold((0, 0, 0), |(jobs, workers, memory), item| {
            (jobs + 1, workers + item.workers, memory + item.memory_mib)
        })
}

fn apply_pending_if_drained(state: &mut State) {
    let Some(pending) = state.pending_limits else {
        return;
    };
    let (jobs, workers, memory) = reservation_usage(state);
    if usage_fits(pending, jobs, workers, memory) {
        state.limits = pending;
        state.pending_limits = None;
    }
}

fn logical_cpu_count() -> usize {
    std::thread::available_parallelism()
        .map(usize::from)
        .unwrap_or(1)
        .max(1)
}

fn state() -> &'static Mutex<State> {
    static STATE: OnceLock<Mutex<State>> = OnceLock::new();
    STATE.get_or_init(|| {
        let logical = logical_cpu_count();
        Mutex::new(State {
            limits: Limits {
                total_cpu_workers: logical.saturating_sub(1).max(1),
                total_memory_mib: 1024,
                max_concurrent_jobs: 2,
            },
            pending_limits: None,
            reservations: BTreeMap::new(),
        })
    })
}

pub fn logical_cpus() -> usize {
    logical_cpu_count()
}

pub fn limits() -> Limits {
    state().lock().unwrap_or_else(|e| e.into_inner()).limits
}

pub fn pending_limits() -> Option<Limits> {
    state()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .pending_limits
}

pub fn usage() -> (usize, usize, usize) {
    let state = state().lock().unwrap_or_else(|e| e.into_inner());
    state
        .reservations
        .values()
        .fold((0, 0, 0), |(jobs, workers, memory), item| {
            (jobs + 1, workers + item.workers, memory + item.memory_mib)
        })
}

pub fn configure(
    total_cpu_workers: usize,
    total_memory_mib: usize,
    max_concurrent_jobs: usize,
) -> Result<Limits, String> {
    let logical = logical_cpu_count();
    if !(1..=logical).contains(&total_cpu_workers) {
        return Err(format!("totalCpuWorkers must be 1..={logical}"));
    }
    if !(MIN_JOB_MEMORY_MIB..=MAX_TOTAL_MEMORY_MIB).contains(&total_memory_mib) {
        return Err(format!(
            "totalMemoryBudgetMiB must be {MIN_JOB_MEMORY_MIB}..={MAX_TOTAL_MEMORY_MIB}"
        ));
    }
    if !(1..=MAX_CONCURRENT_JOBS).contains(&max_concurrent_jobs) {
        return Err(format!(
            "maxConcurrentJobs must be 1..={MAX_CONCURRENT_JOBS}"
        ));
    }
    let mut guard = state().lock().unwrap_or_else(|e| e.into_inner());
    let requested = Limits {
        total_cpu_workers,
        total_memory_mib,
        max_concurrent_jobs,
    };
    let (jobs, workers, memory) = reservation_usage(&guard);
    if !usage_fits(requested, jobs, workers, memory) {
        guard.pending_limits = Some(requested);
        return Err(format!("requested limits are below active reservations (jobs={jobs}, workers={workers}, memoryMiB={memory})"));
    }
    guard.limits = requested;
    guard.pending_limits = None;
    Ok(guard.limits)
}

/// Reserve resources and an output path atomically. The job ID is its canonical output directory.
pub fn reserve(
    job_id: &Path,
    output: &Path,
    workers: usize,
    memory_mib: usize,
) -> Result<(), String> {
    if workers == 0 || workers > MAX_WORKERS_PER_JOB {
        return Err(format!("workers must be 1..={MAX_WORKERS_PER_JOB}"));
    }
    if !(MIN_JOB_MEMORY_MIB..=MAX_JOB_MEMORY_MIB).contains(&memory_mib) {
        return Err(format!(
            "memoryBudgetMiB must be {MIN_JOB_MEMORY_MIB}..={MAX_JOB_MEMORY_MIB}"
        ));
    }
    let mut guard = state().lock().unwrap_or_else(|e| e.into_inner());
    let job_key = normalized(job_id);
    let output_key = normalized(output);
    if guard.reservations.contains_key(&job_key) {
        return Err("job already has an active operation".into());
    }
    if guard
        .reservations
        .values()
        .any(|held| paths_overlap(&output_key, &held.output))
    {
        return Err("output path conflicts with another active operation".into());
    }
    let (jobs, workers_used, memory_used) = reservation_usage(&guard);
    let effective = admission_limits(guard.limits, guard.pending_limits);
    if !can_reserve(
        effective,
        jobs,
        workers_used,
        memory_used,
        workers,
        memory_mib,
    ) {
        return Err("native job resource pool is full".into());
    }
    guard.reservations.insert(
        job_key,
        Reservation {
            workers,
            memory_mib,
            output: output_key,
        },
    );
    Ok(())
}

pub fn release(job_id: &Path) -> bool {
    let mut guard = state().lock().unwrap_or_else(|e| e.into_inner());
    let removed = guard.reservations.remove(&normalized(job_id)).is_some();
    apply_pending_if_drained(&mut guard);
    removed
}

fn normalized(path: &Path) -> PathBuf {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().unwrap_or_default().join(path)
    };
    let mut ancestor = absolute.as_path();
    let mut suffix = Vec::new();
    while !ancestor.exists() {
        let Some(name) = ancestor.file_name() else {
            break;
        };
        suffix.push(name.to_os_string());
        let Some(parent) = ancestor.parent() else {
            break;
        };
        ancestor = parent;
    }
    let mut stable = ancestor
        .canonicalize()
        .unwrap_or_else(|_| ancestor.to_path_buf());
    for component in suffix.iter().rev() {
        stable.push(component);
    }
    #[cfg(windows)]
    {
        let text = stable.to_string_lossy();
        let normalized = text
            .strip_prefix(r"\\?\UNC\")
            .map(|rest| format!(r"\\{rest}"))
            .or_else(|| text.strip_prefix(r"\\?\").map(str::to_owned))
            .unwrap_or_else(|| text.into_owned())
            .to_lowercase();
        PathBuf::from(normalized)
    }
    #[cfg(not(windows))]
    {
        stable
    }
}

fn paths_overlap(a: &Path, b: &Path) -> bool {
    a.starts_with(b) || b.starts_with(a)
}

#[cfg(test)]
pub(crate) static TEST_LOCK: Mutex<()> = Mutex::new(());

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        time::{SystemTime, UNIX_EPOCH},
    };

    fn lock() -> std::sync::MutexGuard<'static, ()> {
        TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner())
    }
    fn root() -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path =
            std::env::temp_dir().join(format!("lumia-resources-{}-{nonce}", std::process::id()));
        fs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    fn admits_parallel_disjoint_jobs_and_rejects_exhaustion_without_leak() {
        let _guard = lock();
        let base = root();
        let original = limits();
        if logical_cpus() < 2 {
            fs::remove_dir_all(base).unwrap();
            return;
        }
        configure(2, 512, 2).unwrap();
        let first = base.join("one");
        let second = base.join("two");
        assert!(reserve(&first, &first, 1, 256).is_ok());
        assert!(reserve(&second, &second, 1, 256).is_ok());
        let third = base.join("three");
        assert!(reserve(&third, &third, 1, 128).is_err());
        assert_eq!(usage(), (2, 2, 512));
        assert!(release(&first));
        assert!(!release(&first));
        assert!(reserve(&third, &third, 1, 128).is_ok());
        release(&second);
        release(&third);
        configure(
            original.total_cpu_workers,
            original.total_memory_mib,
            original.max_concurrent_jobs,
        )
        .unwrap();
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn sixteen_gib_jobs_respect_shared_pool_and_active_lowering() {
        let _guard = lock();
        if logical_cpus() < 2 {
            return;
        }
        let base = root();
        let original = limits();
        configure(2, 32 * 1024, 2).unwrap();
        let first = base.join("sixteen-gib-one");
        let second = base.join("sixteen-gib-two");
        let third = base.join("sixteen-gib-three");
        assert!(reserve(&first, &first, 1, 16 * 1024).is_ok());
        assert!(reserve(&second, &second, 1, 16 * 1024).is_ok());
        assert!(reserve(&third, &third, 1, 16 * 1024).is_err());
        assert_eq!(usage(), (2, 2, 32 * 1024));
        assert!(configure(2, 16 * 1024, 2).is_err());
        assert_eq!(usage(), (2, 2, 32 * 1024));
        assert!(release(&first));
        assert_eq!(usage(), (1, 1, 16 * 1024));
        assert!(configure(2, 16 * 1024, 2).is_ok());
        assert!(reserve(&third, &third, 1, 16 * 1024).is_err());
        assert!(release(&second));
        assert_eq!(usage(), (0, 0, 0));
        assert!(reserve(&third, &third, 1, 16 * 1024).is_ok());
        assert!(release(&third));
        configure(
            original.total_cpu_workers,
            original.total_memory_mib,
            original.max_concurrent_jobs,
        )
        .unwrap();
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn two_admitted_workers_can_overlap_execution() {
        let _guard = lock();
        if logical_cpus() < 2 {
            return;
        }
        let base = root();
        let original = limits();
        configure(2, 256, 2).unwrap();
        let start = std::sync::Arc::new(std::sync::Barrier::new(3));
        let finish = std::sync::Arc::new(std::sync::Barrier::new(3));
        let handles = (0..2)
            .map(|index| {
                let job = base.join(format!("job-{index}"));
                let start = start.clone();
                let finish = finish.clone();
                std::thread::spawn(move || {
                    reserve(&job, &job, 1, 128).unwrap();
                    start.wait();
                    finish.wait();
                    release(&job);
                })
            })
            .collect::<Vec<_>>();
        start.wait();
        assert_eq!(usage(), (2, 2, 256));
        finish.wait();
        for handle in handles {
            handle.join().unwrap();
        }
        assert_eq!(usage(), (0, 0, 0));
        configure(
            original.total_cpu_workers,
            original.total_memory_mib,
            original.max_concurrent_jobs,
        )
        .unwrap();
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn rejects_same_job_and_overlapping_output_paths() {
        let _guard = lock();
        let base = root();
        let original = limits();
        configure(logical_cpus().min(4), 512, 4).unwrap();
        let first = base.join("one");
        let nested = first.join("export.png");
        assert!(reserve(&first, &first, 1, 128).is_ok());
        assert!(reserve(&first, &nested, 1, 128).is_err());
        let other = base.join("other");
        assert!(reserve(&other, &nested, 1, 128).is_err());
        assert_eq!(usage(), (1, 1, 128));
        release(&first);
        configure(
            original.total_cpu_workers,
            original.total_memory_mib,
            original.max_concurrent_jobs,
        )
        .unwrap();
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn reservation_key_stays_stable_after_output_directory_is_created() {
        let _guard = lock();
        let base = root();
        let original = limits();
        configure(logical_cpus().min(4), 512, 4).unwrap();
        let job = base.join("created-later");
        assert!(reserve(&job, &job, 1, 128).is_ok());
        fs::create_dir_all(&job).unwrap();
        assert!(release(&job));
        assert_eq!(usage(), (0, 0, 0));
        configure(
            original.total_cpu_workers,
            original.total_memory_mib,
            original.max_concurrent_jobs,
        )
        .unwrap();
        fs::remove_dir_all(base).unwrap();
    }

    #[cfg(windows)]
    #[test]
    fn path_comparison_is_case_insensitive_on_windows() {
        let _guard = lock();
        let base = root();
        let original = limits();
        configure(logical_cpus().min(4), 512, 4).unwrap();
        let job = base.join("Camera");
        assert!(reserve(&job, &job, 1, 128).is_ok());
        let alias = PathBuf::from(job.to_string_lossy().to_uppercase());
        assert!(reserve(&alias, &alias, 1, 128).is_err());
        release(&job);
        configure(
            original.total_cpu_workers,
            original.total_memory_mib,
            original.max_concurrent_jobs,
        )
        .unwrap();
        fs::remove_dir_all(base).unwrap();
    }

    #[cfg(windows)]
    #[test]
    fn extended_unc_paths_keep_both_leading_separators() {
        let path = normalized(Path::new(r"\\?\UNC\server\share\Folder"));
        assert_eq!(path.to_string_lossy(), r"\\server\share\folder");
    }
}
