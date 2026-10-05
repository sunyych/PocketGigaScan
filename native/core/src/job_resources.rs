//! Process-wide admission control for persistent render and export jobs.
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
};

pub const MAX_CONCURRENT_JOBS: usize = 8;
pub const MAX_WORKERS_PER_JOB: usize = 32;
pub const MIN_JOB_MEMORY_MIB: usize = 128;
pub const MAX_JOB_MEMORY_MIB: usize = 4096;
pub const MAX_TOTAL_MEMORY_MIB: usize = 65_536;

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
    reservations: BTreeMap<PathBuf, Reservation>,
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
    let (jobs, workers, memory) =
        guard
            .reservations
            .values()
            .fold((0, 0, 0), |(jobs, workers, memory), item| {
                (jobs + 1, workers + item.workers, memory + item.memory_mib)
            });
    if total_cpu_workers < workers || total_memory_mib < memory || max_concurrent_jobs < jobs {
        return Err(format!("requested limits are below active reservations (jobs={jobs}, workers={workers}, memoryMiB={memory})"));
    }
    guard.limits = Limits {
        total_cpu_workers,
        total_memory_mib,
        max_concurrent_jobs,
    };
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
    let (jobs, workers_used, memory_used) =
        guard
            .reservations
            .values()
            .fold((0, 0, 0), |(jobs, workers, memory), item| {
                (jobs + 1, workers + item.workers, memory + item.memory_mib)
            });
    if jobs >= guard.limits.max_concurrent_jobs
        || workers_used.saturating_add(workers) > guard.limits.total_cpu_workers
        || memory_used.saturating_add(memory_mib) > guard.limits.total_memory_mib
    {
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
    state()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .reservations
        .remove(&normalized(job_id))
        .is_some()
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
