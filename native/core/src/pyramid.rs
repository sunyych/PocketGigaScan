//! Multi-resolution pyramid extension contract.
//!
//! Pyramid generation is backend-specific; this module defines the stable
//! filesystem contract used by callers without pretending to implement a
//! successful generator.

use crate::{
    pipeline::{CancellationToken, Progress},
    Result,
};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PyramidConfig {
    pub tile_size: u32,
    pub levels: u32,
}

impl PyramidConfig {
    pub fn validate(&self) -> Result<()> {
        if self.tile_size == 0 || self.levels == 0 {
            return Err(crate::Error::Invalid(
                "pyramid tile size and levels must be positive".into(),
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PyramidManifest {
    pub root: PathBuf,
    pub levels: Vec<Vec<PathBuf>>,
}

pub trait PyramidGenerator: Send + Sync {
    /// Generate pyramid tiles from `source` beneath `output_root` and return
    /// every persisted tile path grouped by level. Implementations must call
    /// [`PyramidConfig::validate`], observe cancellation, report progress in
    /// `0..=1`, and publish a manifest only after all tiles are complete.
    fn generate(
        &self,
        source: &Path,
        output_root: &Path,
        config: &PyramidConfig,
        cancel: &CancellationToken,
        progress: &mut dyn FnMut(Progress),
    ) -> Result<PyramidManifest>;
}
