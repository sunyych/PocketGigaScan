//! Per-source-image lens correction and projection.
//!
//! The projection deliberately does not place or align images.  It maps one
//! source image into another image of the same dimensions and returns the
//! validity of every output sample in its alpha channel.  Registration and
//! canvas placement remain separate concerns.

use crate::{Error, Result};
use ::image::{DynamicImage, RgbaImage};

/// The inverse mapping used to project one source tile.
#[repr(i32)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum Projection {
    /// Preserve the image's planar pixel coordinates.
    #[default]
    Planar = 0,
    /// Project through a cylinder using the horizontal field of view.
    Cylindrical = 1,
    /// Project through a sphere using horizontal and vertical fields of view.
    Spherical = 2,
}

/// Brown-Conrady radial and tangential distortion coefficients.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct DistortionCoefficients {
    pub k1: f64,
    pub k2: f64,
    pub p1: f64,
    pub p2: f64,
    pub k3: f64,
}

impl DistortionCoefficients {
    /// True when every coefficient is a no-op for `initUndistortRectifyMap`.
    pub fn is_identity(self) -> bool {
        self.k1.abs() <= 1e-12
            && self.k2.abs() <= 1e-12
            && self.p1.abs() <= 1e-12
            && self.p2.abs() <= 1e-12
            && self.k3.abs() <= 1e-12
    }
}

/// Optional camera calibration used before the selected projection map.
///
/// FOV values are degrees.  The principal point is normalized to the source
/// image (`0.5, 0.5` is the optical center), matching the Dart/OpenCV profile.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LensCalibration {
    pub horizontal_fov_deg: Option<f64>,
    pub vertical_fov_deg: Option<f64>,
    pub distortion: Option<DistortionCoefficients>,
    pub principal_point: Option<(f64, f64)>,
}

impl LensCalibration {
    /// Validate values before crossing the C ABI or constructing camera maps.
    pub fn validate(&self) -> Result<()> {
        for (name, value) in [
            ("horizontal FOV", self.horizontal_fov_deg),
            ("vertical FOV", self.vertical_fov_deg),
        ] {
            if let Some(value) = value {
                if !value.is_finite() || !(0.0 < value && value < 180.0) {
                    return Err(Error::Invalid(format!(
                        "{name} must be finite and between 0 and 180 degrees"
                    )));
                }
            }
        }
        if let Some((x, y)) = self.principal_point {
            if !x.is_finite()
                || !y.is_finite()
                || !(0.0..=1.0).contains(&x)
                || !(0.0..=1.0).contains(&y)
            {
                return Err(Error::Invalid(
                    "principal point must be finite normalized coordinates in [0, 1]".into(),
                ));
            }
        }
        if let Some(d) = self.distortion {
            for (name, value) in [
                ("k1", d.k1),
                ("k2", d.k2),
                ("p1", d.p1),
                ("p2", d.p2),
                ("k3", d.k3),
            ] {
                if !value.is_finite() {
                    return Err(Error::Invalid(format!(
                        "distortion coefficient {name} is not finite"
                    )));
                }
            }
        }
        Ok(())
    }
}

/// Options for projecting one source image.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ProjectionOptions {
    pub projection: Projection,
    pub calibration: Option<LensCalibration>,
}

impl ProjectionOptions {
    pub fn validate(&self) -> Result<()> {
        if let Some(calibration) = self.calibration {
            calibration.validate()?;
        }
        Ok(())
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
struct NativeLensCalibration {
    has_horizontal_fov: i32,
    horizontal_fov_deg: f64,
    has_vertical_fov: i32,
    vertical_fov_deg: f64,
    has_distortion: i32,
    k1: f64,
    k2: f64,
    p1: f64,
    p2: f64,
    k3: f64,
    has_principal_point: i32,
    principal_x: f64,
    principal_y: f64,
}

impl From<LensCalibration> for NativeLensCalibration {
    fn from(value: LensCalibration) -> Self {
        let mut native = Self::default();
        if let Some(fov) = value.horizontal_fov_deg {
            native.has_horizontal_fov = 1;
            native.horizontal_fov_deg = fov;
        }
        if let Some(fov) = value.vertical_fov_deg {
            native.has_vertical_fov = 1;
            native.vertical_fov_deg = fov;
        }
        if let Some(d) = value.distortion {
            native.has_distortion = 1;
            native.k1 = d.k1;
            native.k2 = d.k2;
            native.p1 = d.p1;
            native.p2 = d.p2;
            native.k3 = d.k3;
        }
        if let Some((x, y)) = value.principal_point {
            native.has_principal_point = 1;
            native.principal_x = x;
            native.principal_y = y;
        }
        native
    }
}

extern "C" {
    fn lg_projection_apply_rgb(
        source_rgb: *const u8,
        source_len: usize,
        width: i32,
        height: i32,
        projection: i32,
        calibration: *const NativeLensCalibration,
        output_rgba: *mut u8,
        output_len: usize,
    ) -> i32;
}

/// Project an RGB buffer into an RGBA image.  The returned alpha channel is
/// the OpenCV remapped validity mask, so pixels outside the inverse map are
/// zero and edge samples may be fractional.
pub fn project_rgb(
    rgb: &[u8],
    width: u32,
    height: u32,
    options: ProjectionOptions,
) -> Result<RgbaImage> {
    options.validate()?;
    let pixel_count = (width as usize)
        .checked_mul(height as usize)
        .ok_or_else(|| Error::Invalid("source dimensions overflow".into()))?;
    let source_len = pixel_count
        .checked_mul(3)
        .ok_or_else(|| Error::Invalid("source RGB buffer length overflow".into()))?;
    if rgb.len() != source_len {
        return Err(Error::Invalid(format!(
            "RGB buffer has {} bytes, expected {source_len}",
            rgb.len()
        )));
    }
    let output_len = pixel_count
        .checked_mul(4)
        .ok_or_else(|| Error::Invalid("output RGBA buffer length overflow".into()))?;
    if width == 0 || height == 0 || width > i32::MAX as u32 || height > i32::MAX as u32 {
        return Err(Error::Invalid(
            "source dimensions must be non-zero 32-bit values".into(),
        ));
    }
    let native_calibration = options.calibration.map(NativeLensCalibration::from);
    let calibration_ptr = native_calibration
        .as_ref()
        .map_or(std::ptr::null(), |value| value as *const _);
    let mut output = vec![0u8; output_len];
    // SAFETY: all pointers refer to live, correctly sized Rust allocations;
    // the native function validates them again before touching memory.
    let code = unsafe {
        lg_projection_apply_rgb(
            rgb.as_ptr(),
            rgb.len(),
            width as i32,
            height as i32,
            options.projection as i32,
            calibration_ptr,
            output.as_mut_ptr(),
            output.len(),
        )
    };
    if code != 0 {
        return Err(Error::Invalid(format!("native projection failed ({code})")));
    }
    RgbaImage::from_raw(width, height, output)
        .ok_or_else(|| Error::Invalid("native projection returned invalid image dimensions".into()))
}

/// Project an image after converting it to RGB.  Existing source alpha is not
/// copied because output alpha is reserved for the geometric validity mask.
pub fn project_image(image: &DynamicImage, options: ProjectionOptions) -> Result<RgbaImage> {
    let rgb = image.to_rgb8();
    project_rgb(&rgb, rgb.width(), rgb.height(), options)
}

/// Decode and project an encoded image (PNG/JPEG/TIFF and formats supported by
/// the `image` crate).
pub fn project_encoded(encoded: &[u8], options: ProjectionOptions) -> Result<RgbaImage> {
    let image = ::image::load_from_memory(encoded)?;
    project_image(&image, options)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rgb_fixture(width: u32, height: u32) -> Vec<u8> {
        (0..width * height)
            .flat_map(|i| [i as u8, i.wrapping_add(31) as u8, i.wrapping_add(63) as u8])
            .collect()
    }

    #[test]
    fn calibration_validation_rejects_invalid_values() {
        let mut c = LensCalibration {
            horizontal_fov_deg: Some(180.0),
            ..Default::default()
        };
        assert!(c.validate().is_err());
        c.horizontal_fov_deg = Some(82.0);
        c.principal_point = Some((1.1, 0.5));
        assert!(c.validate().is_err());
        c.principal_point = Some((0.5, 0.5));
        c.distortion = Some(DistortionCoefficients {
            k1: f64::NAN,
            ..Default::default()
        });
        assert!(c.validate().is_err());
    }

    #[test]
    fn planar_projection_preserves_rgb_and_marks_every_sample_valid() {
        let source = rgb_fixture(3, 2);
        let image = project_rgb(
            &source,
            3,
            2,
            ProjectionOptions {
                projection: Projection::Planar,
                calibration: None,
            },
        )
        .unwrap();
        assert_eq!(image.width(), 3);
        assert_eq!(image.height(), 2);
        for (pixel, rgb) in image.pixels().zip(source.chunks(3)) {
            assert_eq!(&pixel.0[..3], rgb);
            assert_eq!(pixel.0[3], 255);
        }
    }

    #[test]
    fn cylindrical_projection_exposes_invalid_border_in_alpha() {
        let image = project_rgb(
            &rgb_fixture(32, 16),
            32,
            16,
            ProjectionOptions {
                projection: Projection::Cylindrical,
                calibration: None,
            },
        )
        .unwrap();
        assert_eq!(image.get_pixel(16, 8).0[3], 255);
        assert!(image.pixels().any(|pixel| pixel.0[3] < 255));
    }

    #[test]
    fn invalid_dimensions_and_fov_are_rejected_before_native_call() {
        assert!(project_rgb(&[], 0, 1, ProjectionOptions::default()).is_err());
        assert!(project_rgb(&[0, 1], 1, 1, ProjectionOptions::default()).is_err());
        let options = ProjectionOptions {
            projection: Projection::Spherical,
            calibration: Some(LensCalibration {
                vertical_fov_deg: Some(0.0),
                ..Default::default()
            }),
        };
        assert!(project_rgb(&[0, 1, 2], 1, 1, options).is_err());
    }

    #[test]
    fn identity_distortion_matches_native_zero_threshold() {
        assert!(DistortionCoefficients::default().is_identity());
        assert!(DistortionCoefficients {
            k1: 1e-13,
            ..Default::default()
        }
        .is_identity());
        assert!(!DistortionCoefficients {
            k1: 0.01,
            ..Default::default()
        }
        .is_identity());
    }

    #[test]
    fn optional_zero_calibration_keeps_planar_projection_identity() {
        let source = rgb_fixture(2, 2);
        let image = project_rgb(
            &source,
            2,
            2,
            ProjectionOptions {
                projection: Projection::Planar,
                calibration: Some(LensCalibration::default()),
            },
        )
        .unwrap();
        assert!(image.pixels().all(|pixel| pixel.0[3] == 255));
        let actual: Vec<u8> = image
            .as_raw()
            .chunks(4)
            .flat_map(|pixel| pixel[..3].iter().copied())
            .collect();
        assert_eq!(actual, source);
    }
}
