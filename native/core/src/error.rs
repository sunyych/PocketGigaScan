use crate::metadata::StitchReport;
use thiserror::Error;
#[derive(Debug, Error)]
pub enum Error {
    #[error("image decode failed: {0}")]
    Decode(#[from] image::ImageError),
    #[error("invalid input: {0}")]
    Invalid(String),
    #[error("output failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("registration failed: {0}")]
    Registration(String),
    #[error("registration failed: {message}")]
    RegistrationReport {
        message: String,
        report: Box<StitchReport>,
    },
    #[error("job cancelled")]
    Cancelled,
}
pub type Result<T> = std::result::Result<T, Error>;
