#![recursion_limit = "256"]

//! CPU panorama core. Registration is visual-first; nominal PTZ geometry is an
//! explicit fallback and is reported in diagnostics.
pub mod error;
pub mod ffi;
pub mod fingerprint;
pub mod focus;
pub mod grid_overlap;
pub mod image;
pub mod job;
pub mod job_resources;
pub(crate) mod jxl_export;
pub mod metadata;
pub mod pipeline;
pub mod projection;
pub mod pyramid;
pub mod scan;
mod seam_ownership;
pub mod spherical;
pub(crate) mod spherical_export;
pub mod spherical_renderer;
pub mod texture_warp;
pub(crate) mod tiff_export;

pub use error::{Error, Result};
pub use metadata::{CaptureGeometry, CaptureTile, StitchEdgeReport, StitchOptions, StitchReport};
pub use pipeline::{CancellationToken, Progress, StitchJob, StitchResult};
