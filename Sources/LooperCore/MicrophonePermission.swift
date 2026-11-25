import AVFoundation
import Foundation

public enum MicrophonePermission: Equatable, Sendable {
    case authorized, notDetermined, denied, restricted

    public static var current: MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        default: return .denied
        }
    }

    public static func request(_ completion: @escaping @MainActor (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            onMain { completion(granted) }
        }
    }

    /// Ajustes do Sistema › Privacidade e Segurança › Microfone.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
}
