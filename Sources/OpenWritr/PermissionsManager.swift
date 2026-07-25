import Cocoa
import AVFoundation

struct PermissionStatus: Sendable {
    let microphone: Bool
    let accessibility: Bool

    var allGranted: Bool {
        microphone && accessibility
    }
}

@MainActor
final class PermissionsManager {

    var hasMicrophoneAccess: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    var hasAccessibilityAccess: Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    @discardableResult
    func requestAccessibilityAccess() -> Bool {
        let prompt = "AXTrustedCheckOptionPrompt" as CFString
        let options = [prompt: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func checkAllPermissions() async -> PermissionStatus {
        var mic = hasMicrophoneAccess
        if !mic {
            mic = await requestMicrophoneAccess()
        }

        var accessibility = hasAccessibilityAccess
        if !accessibility {
            accessibility = requestAccessibilityAccess()
        }

        return PermissionStatus(microphone: mic, accessibility: accessibility)
    }
}
