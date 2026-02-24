import Cocoa
import AVFoundation

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

    nonisolated func requestAccessibilityAccess() {
        let prompt = "AXTrustedCheckOptionPrompt" as CFString
        let options = [prompt: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func checkAllPermissions() async -> (microphone: Bool, accessibility: Bool) {
        var mic = hasMicrophoneAccess
        if !mic {
            mic = await requestMicrophoneAccess()
        }
        let accessibility = hasAccessibilityAccess
        if !accessibility {
            requestAccessibilityAccess()
        }
        return (mic, accessibility)
    }
}
