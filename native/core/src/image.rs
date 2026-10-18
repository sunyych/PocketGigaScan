use crate::{Error, Result};
use ::image::{DynamicImage, GrayImage, RgbaImage};
use std::path::Path;
pub fn load(path: &Path) -> Result<RgbaImage> {
    Ok(::image::open(path)?.to_rgba8())
}
pub fn gray(img: &RgbaImage) -> GrayImage {
    DynamicImage::ImageRgba8(img.clone()).to_luma8()
}
pub fn save(img: &RgbaImage, path: &Path) -> Result<()> {
    img.save(path).map_err(Error::from)
}
