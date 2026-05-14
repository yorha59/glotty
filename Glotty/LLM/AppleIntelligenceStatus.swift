import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether Apple's on-device LLM (`SystemLanguageModel`) is usable on this Mac.
/// Drives the Settings status badge and decides whether the Apple Foundation
/// provider should be offered as a polishing engine option.
enum AppleIntelligenceStatus: Equatable {
    case available
    case notEnabled            // user has Apple Intelligence toggle off
    case deviceNotEligible     // hardware doesn't support it (older / Intel Mac)
    case modelDownloading      // OS is still pulling the model
    case osNotSupported        // running on something below macOS 26
    case unknown(String)       // future-proofing for new failure modes

    /// Short label suitable for a Settings badge.
    var displayName: String {
        switch self {
        case .available:           return "Available"
        case .notEnabled:          return "Apple Intelligence is off"
        case .deviceNotEligible:   return "This Mac doesn't support Apple Intelligence"
        case .modelDownloading:    return "Apple Intelligence is downloading"
        case .osNotSupported:      return "Requires macOS 26"
        case .unknown(let msg):    return "Unavailable (\(msg))"
        }
    }

    /// A concrete next step the user can take, if any.
    var fixInstructions: String? {
        switch self {
        case .available:
            return nil
        case .notEnabled:
            return "Enable in System Settings → Apple Intelligence & Siri."
        case .deviceNotEligible:
            return "Apple Intelligence requires an Apple Silicon Mac with sufficient memory. Use a cloud LLM provider instead."
        case .modelDownloading:
            return "The model is still downloading. Try again in a few minutes."
        case .osNotSupported:
            return "Glotty targets macOS 26+; this status should never appear in a normal build."
        case .unknown:
            return nil
        }
    }
}

extension AppleIntelligenceStatus {
    /// Probe the OS for the current Apple Intelligence availability.
    static func current() -> AppleIntelligenceStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled:
                    return .notEnabled
                case .deviceNotEligible:
                    return .deviceNotEligible
                case .modelNotReady:
                    return .modelDownloading
                @unknown default:
                    return .unknown(String(describing: reason))
                }
            @unknown default:
                return .unknown("future availability case")
            }
        } else {
            return .osNotSupported
        }
        #else
        return .osNotSupported
        #endif
    }
}
