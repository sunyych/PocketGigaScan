import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum LumiaGigaScanCoreError: Error, Equatable {
    case unavailable(String)
    case invalidRequest
    case nullResponse
    case invalidResponse
    case incompatibleABI(expected: UInt32, actual: UInt32)
}

public struct LumiaGigaScanPlanRequest: Codable, Sendable {
    public struct Pose: Codable, Sendable {
        public let pan: Double
        public let tilt: Double
        public let zoom: Double

        public init(pan: Double, tilt: Double, zoom: Double) {
            self.pan = pan
            self.tilt = tilt
            self.zoom = zoom
        }
    }

    public struct FOV: Codable, Sendable {
        public let horizontal: Double
        public let vertical: Double
        public let mechanicalPan: Double
        public let mechanicalTilt: Double

        public init(
            horizontal: Double,
            vertical: Double,
            mechanicalPan: Double,
            mechanicalTilt: Double
        ) {
            self.horizontal = horizontal
            self.vertical = vertical
            self.mechanicalPan = mechanicalPan
            self.mechanicalTilt = mechanicalTilt
        }
    }

    public struct ROI: Codable, Sendable {
        public let left: Double
        public let top: Double
        public let right: Double
        public let bottom: Double

        public init(left: Double, top: Double, right: Double, bottom: Double) {
            self.left = left
            self.top = top
            self.right = right
            self.bottom = bottom
        }
    }

    public struct Grid: Codable, Sendable {
        public let mode: String
        public let rows: Int?
        public let columns: Int?

        public static let auto = Grid(mode: "auto", rows: nil, columns: nil)

        public static func explicit(rows: Int, columns: Int) -> Grid {
            Grid(mode: "explicit", rows: rows, columns: columns)
        }
    }

    public let source: Pose
    public let sourceFov: FOV
    public let roi: ROI
    public let targetFov: FOV
    public let overlapX: Double
    public let overlapY: Double
    public let grid: Grid
    public let traversal: String
    public let estimatedBytesPerTile: UInt64
    public let maximumTiles: Int

    public init(
        source: Pose,
        sourceFov: FOV,
        roi: ROI,
        targetFov: FOV,
        overlapX: Double,
        overlapY: Double,
        grid: Grid,
        traversal: String = "snake",
        estimatedBytesPerTile: UInt64,
        maximumTiles: Int
    ) {
        self.source = source
        self.sourceFov = sourceFov
        self.roi = roi
        self.targetFov = targetFov
        self.overlapX = overlapX
        self.overlapY = overlapY
        self.grid = grid
        self.traversal = traversal
        self.estimatedBytesPerTile = estimatedBytesPerTile
        self.maximumTiles = maximumTiles
    }
}

public final class LumiaGigaScanCore: @unchecked Sendable {
    public static let supportedABIVersion: UInt32 = 1

    private typealias ABIFunction = @convention(c) () -> UInt32
    private typealias PlanFunction =
        @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias ProgressFunction =
        @convention(c) (UnsafePointer<CChar>?, Float, UnsafeMutableRawPointer?) -> Void
    private typealias StitchFunction =
        @convention(c) (
            UnsafePointer<CChar>?,
            ProgressFunction?,
            UnsafeMutableRawPointer?
        ) -> UnsafeMutablePointer<CChar>?
    private typealias FreeFunction = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    private let handle: UnsafeMutableRawPointer?
    private let closeHandle: Bool
    private let abi: ABIFunction?
    private let planFunction: PlanFunction?
    private let stitchFunction: StitchFunction?
    private let freeFunction: FreeFunction?

    public let unavailableReason: String?

    public var isAvailable: Bool {
        abi != nil && planFunction != nil && stitchFunction != nil && freeFunction != nil
    }

    public init(libraryPath: String? = nil) {
        #if canImport(Darwin) || canImport(Glibc)
        let loaded = Self.load(libraryPath: libraryPath)
        let loadedABI = Self.symbol(
            loaded.handle,
            "lumia_gigascan_abi_version",
            as: ABIFunction.self
        )
        let loadedPlan = Self.symbol(
            loaded.handle,
            "lumia_gigascan_plan_json",
            as: PlanFunction.self
        )
        let loadedStitch = Self.symbol(
            loaded.handle,
            "lumia_gigascan_stitch_json",
            as: StitchFunction.self
        )
        let loadedFree = Self.symbol(
            loaded.handle,
            "lumia_gigascan_free",
            as: FreeFunction.self
        )
        let available =
            loadedABI != nil && loadedPlan != nil && loadedStitch != nil && loadedFree != nil
        handle = loaded.handle
        closeHandle = loaded.closeHandle
        abi = loadedABI
        planFunction = loadedPlan
        stitchFunction = loadedStitch
        freeFunction = loadedFree
        unavailableReason = available ? nil : loaded.reason
        #else
        handle = nil
        closeHandle = false
        abi = nil
        planFunction = nil
        stitchFunction = nil
        freeFunction = nil
        unavailableReason = "Dynamic loading is unsupported on this platform"
        #endif
    }

    deinit {
        #if canImport(Darwin) || canImport(Glibc)
        if closeHandle, let handle {
            dlclose(handle)
        }
        #endif
    }

    public func plan(_ request: LumiaGigaScanPlanRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try invoke(data: data, function: planFunction)
    }

    public func stitch(request: [String: Any]) throws -> [String: Any] {
        guard JSONSerialization.isValidJSONObject(request) else {
            throw LumiaGigaScanCoreError.invalidRequest
        }
        let data = try JSONSerialization.data(withJSONObject: request)
        guard let stitchFunction else {
            throw LumiaGigaScanCoreError.unavailable(
                unavailableReason ?? "lumia-gigascan-core is unavailable"
            )
        }
        return try invokeRaw(data: data) { pointer in
            stitchFunction(pointer, nil, nil)
        }
    }

    private func invoke(
        data: Data,
        function: PlanFunction?
    ) throws -> [String: Any] {
        guard let function else {
            throw LumiaGigaScanCoreError.unavailable(
                unavailableReason ?? "lumia-gigascan-core is unavailable"
            )
        }
        return try invokeRaw(data: data, function: function)
    }

    private func invokeRaw(
        data: Data,
        function: (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    ) throws -> [String: Any] {
        guard let abi, let freeFunction else {
            throw LumiaGigaScanCoreError.unavailable(
                unavailableReason ?? "lumia-gigascan-core is unavailable"
            )
        }
        let actualABI = abi()
        guard actualABI == Self.supportedABIVersion else {
            throw LumiaGigaScanCoreError.incompatibleABI(
                expected: Self.supportedABIVersion,
                actual: actualABI
            )
        }
        guard let request = String(data: data, encoding: .utf8) else {
            throw LumiaGigaScanCoreError.invalidRequest
        }
        let response = request.withCString { function($0) }
        guard let response else {
            throw LumiaGigaScanCoreError.nullResponse
        }
        defer { freeFunction(response) }
        guard
            let responseData = String(cString: response).data(using: .utf8),
            let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        else {
            throw LumiaGigaScanCoreError.invalidResponse
        }
        return object
    }

    #if canImport(Darwin) || canImport(Glibc)
    private static func load(
        libraryPath: String?
    ) -> (handle: UnsafeMutableRawPointer?, closeHandle: Bool, reason: String?) {
        var candidates = [String]()
        if let libraryPath, !libraryPath.isEmpty {
            candidates.append(libraryPath)
        }
        if let directory = ProcessInfo.processInfo.environment["LUMIA_GIGASCAN_CORE_DIR"] {
            candidates.append(
                URL(fileURLWithPath: directory)
                    .appendingPathComponent(platformLibraryName)
                    .path
            )
        }
        if let bundled = Bundle.main.privateFrameworksPath {
            candidates.append(
                URL(fileURLWithPath: bundled)
                    .appendingPathComponent(platformLibraryName)
                    .path
            )
        }
        for candidate in candidates {
            if let handle = dlopen(candidate, RTLD_NOW | RTLD_LOCAL) {
                return (handle, true, nil)
            }
        }
        if let process = dlopen(nil, RTLD_NOW | RTLD_LOCAL),
           symbol(process, "lumia_gigascan_abi_version", as: ABIFunction.self) != nil
        {
            return (process, false, nil)
        }
        let reason = dlerror().map { String(cString: $0) }
            ?? "lumia-gigascan-core symbols were not found"
        return (nil, false, reason)
    }

    private static func symbol<T>(
        _ handle: UnsafeMutableRawPointer?,
        _ name: String,
        as _: T.Type
    ) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else {
            return nil
        }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static var platformLibraryName: String {
        #if os(macOS) || os(iOS)
        return "liblumia_gigascan_core.dylib"
        #else
        return "liblumia_gigascan_core.so"
        #endif
    }
    #endif
}
