// Planner contract tests. The parent crate can include this file from its
// integration test target once Cargo/lib.rs are introduced.
#[cfg(test)]
mod tests {
    use lumia_gigascan_core::scan::*;
    fn request(grid: Grid) -> ScanRequest {
        let fov = Fov {
            horizontal: 82.0,
            vertical: 52.0,
            mechanical_pan: 260.0,
            mechanical_tilt: 130.0,
        };
        ScanRequest {
            source: Pose {
                pan: 0.0,
                tilt: 0.0,
                zoom: 1.0,
            },
            source_fov: fov,
            roi: Roi::new(0.1, 0.1, 0.9, 0.9),
            target_fov: fov,
            overlap_x: 0.45,
            overlap_y: 0.45,
            grid,
            traversal: Traversal::Snake,
            estimated_bytes_per_tile: 10,
            maximum_tiles: 4096,
        }
    }
    #[test]
    fn explicit_3x3() {
        let p = ScanPlanner::plan(request(Grid::Explicit {
            rows: 3,
            columns: 3,
        }))
        .unwrap();
        assert_eq!((p.rows, p.columns, p.tiles.len()), (3, 3, 9));
    }
    #[test]
    fn explicit_5x5() {
        let p = ScanPlanner::plan(request(Grid::Explicit {
            rows: 5,
            columns: 5,
        }))
        .unwrap();
        assert_eq!(p.tiles.len(), 25);
    }
    #[test]
    fn explicit_10x10() {
        let mut r = request(Grid::Explicit {
            rows: 10,
            columns: 10,
        });
        r.target_fov.horizontal = 30.0;
        r.target_fov.vertical = 20.0;
        let p = ScanPlanner::plan(r).unwrap();
        assert_eq!(p.tiles.len(), 100);
    }
    #[test]
    fn auto_covers_roi() {
        let mut r = request(Grid::Auto);
        r.source_fov.horizontal = 100.0;
        r.source_fov.vertical = 70.0;
        r.target_fov.horizontal = 20.0;
        r.target_fov.vertical = 20.0;
        r.overlap_x = 0.3;
        r.overlap_y = 0.3;
        let p = ScanPlanner::plan(r).unwrap();
        assert!(p.rows > 1 && p.columns > 1);
    }
    #[test]
    fn invalid_roi_rejected() {
        let mut r = request(Grid::Auto);
        r.roi = Roi::new(-0.1, 0.0, 0.5, 0.5);
        assert!(matches!(
            ScanPlanner::plan(r),
            Err(ScanError::InvalidArgument(_))
        ));
    }
    #[test]
    fn tiny_target_fov_does_not_panic() {
        let mut r = request(Grid::Auto);
        r.target_fov.horizontal = 1e-300;
        r.target_fov.vertical = 1e-300;
        assert!(ScanPlanner::plan(r).is_err());
    }
    #[test]
    fn estimated_bytes_overflow_is_rejected() {
        let mut r = request(Grid::Explicit {
            rows: 3,
            columns: 3,
        });
        r.estimated_bytes_per_tile = u64::MAX;
        assert!(matches!(
            ScanPlanner::plan(r),
            Err(ScanError::EstimatedBytesOverflow)
        ));
    }
    #[test]
    fn row_and_column_orders_are_monotonic() {
        let mut r = request(Grid::Explicit {
            rows: 3,
            columns: 3,
        });
        r.traversal = Traversal::RowByRow;
        let p = ScanPlanner::plan(r).unwrap();
        assert_eq!((p.tiles[0].row, p.tiles[0].column), (0, 0));
        assert_eq!((p.tiles[3].row, p.tiles[3].column), (1, 0));
        r.traversal = Traversal::ColumnByColumn;
        let p = ScanPlanner::plan(r).unwrap();
        assert_eq!((p.tiles[3].row, p.tiles[3].column), (0, 1));
    }
}
