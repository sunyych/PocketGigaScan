import Foundation

public enum CapabilitySupport: String, Codable, Equatable, Sendable {
    case unknown
    case supported
    case unsupported
}

public enum LiveCodecHint: String, Codable, Equatable, Sendable {
    case unknown
    case avc
    case hevc
}

/// Protocol-facing capabilities for Pocket-family cameras.
///
/// `unknown` is intentional: a physical feature does not prove that the
/// corresponding DUML command, feedback stream, or media endpoint has been
/// captured. This evidence record is distinct from low-level diagnostic probes.
public struct PocketCapabilities: Codable, Equatable, Sendable {
    public let profile: String
    public let liveCodecHint: LiveCodecHint
    public let gimbalControl: CapabilitySupport
    public let gimbalFeedback: CapabilitySupport
    public let tapFocus: CapabilitySupport
    public let focusMode: CapabilitySupport
    public let photoCapture: CapabilitySupport
    public let photoDownload: CapabilitySupport
    public let rawCapture: CapabilitySupport
    public let opticalTele: CapabilitySupport
    public let builtInPanorama: CapabilitySupport

    public static let pocket2Unverified = PocketCapabilities(
        profile: "pocket2-unverified",
        liveCodecHint: .unknown,
        gimbalControl: .unknown,
        gimbalFeedback: .unknown,
        tapFocus: .unknown,
        focusMode: .unknown,
        photoCapture: .unknown,
        photoDownload: .unknown,
        rawCapture: .unknown,
        opticalTele: .unsupported,
        builtInPanorama: .unknown
    )

    public static func resolve(for model: CameraModel) -> PocketCapabilities? {
        guard model.family == .pocket else { return nil }
        if model.isPocket2 { return .pocket2Unverified }
        return PocketCapabilities(
            profile: model.verified ? "captured-pocket" : "generic-pocket",
            liveCodecHint: .unknown,
            gimbalControl: .supported,
            gimbalFeedback: .supported,
            tapFocus: model.supportsTapFocus ? .supported : .unsupported,
            focusMode: model.supportsFocusMode ? .supported : .unsupported,
            photoCapture: .supported,
            photoDownload: .supported,
            rawCapture: .unknown,
            opticalTele: model.name.lowercased().contains("4 pro") ? .supported : .unsupported,
            builtInPanorama: .unknown
        )
    }
}
