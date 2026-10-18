//! Device independent PTZ scan planning.
//!
//! Ported from `PTZ Manager/lib/src/gigapixel/scan_planner.dart`.  This module
//! operates on normalized camera coordinates and calibrated angles only;
//! native camera-control units and hardware limits belong to the caller.

use std::fmt;

#[derive(Debug, Clone, PartialEq)]
pub enum ScanError {
    InvalidArgument(&'static str),
    InvalidGrid(&'static str),
    GridTooSmall {
        required_rows: usize,
        required_columns: usize,
    },
    MechanicalRangeExceeded {
        row: usize,
        column: usize,
    },
    ResourceLimitExceeded {
        tiles: usize,
        maximum: usize,
    },
    EstimatedBytesOverflow,
}

impl fmt::Display for ScanError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidArgument(s) | Self::InvalidGrid(s) => f.write_str(s),
            Self::GridTooSmall {
                required_rows,
                required_columns,
            } => write!(f, "grid requires {required_rows}x{required_columns} tiles"),
            Self::MechanicalRangeExceeded { row, column } => {
                write!(f, "tile ({row},{column}) exceeds mechanical range")
            }
            Self::ResourceLimitExceeded { tiles, maximum } => {
                write!(f, "scan has {tiles} tiles, maximum is {maximum}")
            }
            Self::EstimatedBytesOverflow => f.write_str("estimated scan size overflows u64"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Roi {
    pub left: f64,
    pub top: f64,
    pub right: f64,
    pub bottom: f64,
}

impl Roi {
    pub fn new(left: f64, top: f64, right: f64, bottom: f64) -> Self {
        Self {
            left,
            top,
            right,
            bottom,
        }
    }
    pub fn validate(self) -> Result<(), ScanError> {
        if [self.left, self.top, self.right, self.bottom]
            .iter()
            .any(|v| !v.is_finite())
            || self.left < 0.0
            || self.top < 0.0
            || self.right > 1.0
            || self.bottom > 1.0
            || self.right <= self.left
            || self.bottom <= self.top
        {
            return Err(ScanError::InvalidArgument(
                "ROI must be finite, inside 0..1, and have positive size",
            ));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Pose {
    pub pan: f64,
    pub tilt: f64,
    pub zoom: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Fov {
    pub horizontal: f64,
    pub vertical: f64,
    pub mechanical_pan: f64,
    pub mechanical_tilt: f64,
}

impl Fov {
    pub fn validate(self) -> Result<(), ScanError> {
        if [
            self.horizontal,
            self.vertical,
            self.mechanical_pan,
            self.mechanical_tilt,
        ]
        .iter()
        .any(|v| !v.is_finite() || *v <= 0.0)
        {
            return Err(ScanError::InvalidArgument(
                "FOV and mechanical ranges must be finite and positive",
            ));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Grid {
    Explicit { rows: usize, columns: usize },
    Auto,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Traversal {
    #[default]
    Snake,
    RowByRow,
    ColumnByColumn,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ScanRequest {
    pub source: Pose,
    /// FOV of the source/survey frame in which the normalized ROI was drawn.
    pub source_fov: Fov,
    /// FOV of each planned tile at the requested capture zoom.
    pub roi: Roi,
    pub target_fov: Fov,
    pub overlap_x: f64,
    pub overlap_y: f64,
    pub grid: Grid,
    pub traversal: Traversal,
    pub estimated_bytes_per_tile: u64,
    pub maximum_tiles: usize,
}

impl ScanRequest {
    pub fn validate(&self) -> Result<(), ScanError> {
        self.roi.validate()?;
        self.source_fov.validate()?;
        self.target_fov.validate()?;
        if (self.source_fov.mechanical_pan - self.target_fov.mechanical_pan).abs() > f64::EPSILON
            || (self.source_fov.mechanical_tilt - self.target_fov.mechanical_tilt).abs()
                > f64::EPSILON
        {
            return Err(ScanError::InvalidArgument(
                "source and target FOV must use the same mechanical ranges",
            ));
        }
        if !self.source.pan.is_finite()
            || !self.source.tilt.is_finite()
            || !self.source.zoom.is_finite()
            || self.source.pan < -1.0
            || self.source.pan > 1.0
            || self.source.tilt < -1.0
            || self.source.tilt > 1.0
            || self.source.zoom <= 0.0
        {
            return Err(ScanError::InvalidArgument(
                "source pose must be finite and normalized to -1..1",
            ));
        }
        if !self.overlap_x.is_finite()
            || !self.overlap_y.is_finite()
            || !(0.0..1.0).contains(&self.overlap_x)
            || !(0.0..1.0).contains(&self.overlap_y)
        {
            return Err(ScanError::InvalidArgument(
                "overlap must be between 0 and 1",
            ));
        }
        if self.estimated_bytes_per_tile == 0 || self.maximum_tiles == 0 {
            return Err(ScanError::InvalidArgument(
                "resource estimates and limits must be positive",
            ));
        }
        if let Grid::Explicit { rows, columns } = self.grid {
            if rows == 0 || columns == 0 {
                return Err(ScanError::InvalidGrid(
                    "explicit grid dimensions must be positive",
                ));
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Tile {
    pub sequence: usize,
    pub row: usize,
    pub column: usize,
    pub pose: Pose,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ScanPlan {
    pub rows: usize,
    pub columns: usize,
    pub tiles: Vec<Tile>,
    pub estimated_bytes: u64,
    pub horizontal_step: f64,
    pub vertical_step: f64,
}

pub struct ScanPlanner;

impl ScanPlanner {
    pub fn plan(request: ScanRequest) -> Result<ScanPlan, ScanError> {
        request.validate()?;
        let roi_width = (request.roi.right - request.roi.left) * request.source_fov.horizontal;
        let roi_height = (request.roi.bottom - request.roi.top) * request.source_fov.vertical;
        let step_x = request.target_fov.horizontal * (1.0 - request.overlap_x);
        let step_y = request.target_fov.vertical * (1.0 - request.overlap_y);
        let required_columns = required_count(roi_width, request.target_fov.horizontal, step_x)?;
        let required_rows = required_count(roi_height, request.target_fov.vertical, step_y)?;
        let (rows, columns) = match request.grid {
            Grid::Auto => (required_rows.max(1), required_columns.max(1)),
            Grid::Explicit { rows, columns } => {
                if rows < required_rows || columns < required_columns {
                    return Err(ScanError::GridTooSmall {
                        required_rows,
                        required_columns,
                    });
                }
                (rows, columns)
            }
        };
        let tiles = rows
            .checked_mul(columns)
            .ok_or(ScanError::ResourceLimitExceeded {
                tiles: usize::MAX,
                maximum: request.maximum_tiles,
            })?;
        if tiles > request.maximum_tiles {
            return Err(ScanError::ResourceLimitExceeded {
                tiles,
                maximum: request.maximum_tiles,
            });
        }
        // ROI center is converted from normalized preview coordinates to an
        // angle using the supplied FOV, then to a normalized mechanical-range
        // offset. Tile centers use the same normalized offset convention:
        // -1 is the mechanical minimum, 0 the center, and +1 the maximum.
        let center_pan = request.source.pan
            + ((request.roi.left + request.roi.right) / 2.0 - 0.5)
                * request.source_fov.horizontal
                * 2.0
                / request.source_fov.mechanical_pan;
        let center_tilt = request.source.tilt
            - ((request.roi.top + request.roi.bottom) / 2.0 - 0.5)
                * request.source_fov.vertical
                * 2.0
                / request.source_fov.mechanical_tilt;
        let nx = step_x * 2.0 / request.target_fov.mechanical_pan;
        let ny = step_y * 2.0 / request.target_fov.mechanical_tilt;
        let mut tiles_out = Vec::with_capacity(tiles);
        for sequence in 0..tiles {
            let (row, column) = match request.traversal {
                Traversal::RowByRow | Traversal::Snake => {
                    let row = sequence / columns;
                    let c = sequence % columns;
                    (
                        row,
                        if matches!(request.traversal, Traversal::Snake) && row % 2 == 1 {
                            columns - 1 - c
                        } else {
                            c
                        },
                    )
                }
                Traversal::ColumnByColumn => {
                    let column = sequence / rows;
                    (sequence % rows, column)
                }
            };
            let pan = center_pan + (column as f64 - (columns - 1) as f64 / 2.0) * nx;
            let tilt = center_tilt + ((rows - 1) as f64 / 2.0 - row as f64) * ny;
            if !(-1.0..=1.0).contains(&pan) || !(-1.0..=1.0).contains(&tilt) {
                return Err(ScanError::MechanicalRangeExceeded { row, column });
            }
            tiles_out.push(Tile {
                sequence,
                row,
                column,
                pose: Pose {
                    pan,
                    tilt,
                    zoom: request.source.zoom,
                },
            });
        }
        let estimated_bytes = (tiles as u64)
            .checked_mul(request.estimated_bytes_per_tile)
            .ok_or(ScanError::EstimatedBytesOverflow)?;
        Ok(ScanPlan {
            rows,
            columns,
            tiles: tiles_out,
            estimated_bytes,
            horizontal_step: step_x,
            vertical_step: step_y,
        })
    }
}

fn required_count(span: f64, tile: f64, step: f64) -> Result<usize, ScanError> {
    let count = ((span - tile).max(0.0) / step).ceil();
    if !count.is_finite() || count > (usize::MAX - 1) as f64 {
        return Err(ScanError::InvalidArgument(
            "FOV values produce an unrepresentable grid",
        ));
    }
    Ok(count as usize + 1)
}
