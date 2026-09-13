import Foundation
import Testing
@testable import LumiaGigaScanCore

@Test
func explicitThreeByThreeRequestMatchesCoreABI() throws {
    let fov = LumiaGigaScanPlanRequest.FOV(
        horizontal: 82,
        vertical: 52,
        mechanicalPan: 260,
        mechanicalTilt: 130
    )
    let request = LumiaGigaScanPlanRequest(
        source: .init(pan: 0, tilt: 0, zoom: 1),
        sourceFov: fov,
        roi: .init(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9),
        targetFov: fov,
        overlapX: 0.3,
        overlapY: 0.3,
        grid: .explicit(rows: 3, columns: 3),
        traversal: "rowByRow",
        estimatedBytesPerTile: 10,
        maximumTiles: 4096
    )

    let data = try JSONEncoder().encode(request)
    let json = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let grid = try #require(json["grid"] as? [String: Any])

    #expect(grid["mode"] as? String == "explicit")
    #expect(grid["rows"] as? Int == 3)
    #expect(grid["columns"] as? Int == 3)
    #expect(json["traversal"] as? String == "rowByRow")
}

@Test
func missingNativeLibraryIsAnExplicitUnavailableState() {
    let core = LumiaGigaScanCore(libraryPath: "/missing/liblumia_gigascan_core.dylib")
    #expect(core.isAvailable == false)
    #expect(core.unavailableReason != nil)
}
