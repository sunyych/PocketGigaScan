//! Focus stacking extension contract.
//!
//! The core crate deliberately does not ship a fake focus-stack result. A
//! camera/backend integration implements [`FocusStacker`] and returns the
//! actual persisted output tile it produced.

use crate::{
    metadata::CaptureTile,
    pipeline::{CancellationToken, Progress},
    Result,
};
use std::path::{Path, PathBuf};

pub trait FocusStacker: Send + Sync {
    /// Stack the supplied captures into `output`, returning the persisted tile
    /// path. Implementations must check cancellation between expensive stages,
    /// report monotonically increasing progress in `0..=1`, and leave no
    /// partially published output when cancelled or failed.
    fn stack(
        &self,
        tiles: &[CaptureTile],
        output: &Path,
        cancel: &CancellationToken,
        progress: &mut dyn FnMut(Progress),
    ) -> Result<PathBuf>;
}
