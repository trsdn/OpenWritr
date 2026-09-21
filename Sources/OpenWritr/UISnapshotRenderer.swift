import AppKit
import SwiftUI

enum UISnapshotAppearance: String, CaseIterable, Sendable {
    case light
    case dark

    var colorScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }

    var appKitAppearance: NSAppearance.Name {
        switch self {
        case .light: .aqua
        case .dark: .darkAqua
        }
    }
}

enum UISnapshotSurface: String, CaseIterable, Sendable {
    case settings
    case about
    case overlayListening = "overlay-listening"
    case overlayTranscribing = "overlay-transcribing"
    case overlayEnhancing = "overlay-enhancing"
    case overlayDone = "overlay-done"
    case overlayError = "overlay-error"
}

struct UISnapshotPlan: Equatable, Sendable {
    static let scale = 2

    let surface: UISnapshotSurface
    let appearance: UISnapshotAppearance
    let accessibilityText: Bool

    var filename: String {
        let textSuffix = accessibilityText ? "-accessibility-text" : ""
        return "\(surface.rawValue)-\(appearance.rawValue)\(textSuffix).png"
    }

    static let all: [UISnapshotPlan] = {
        let standard = UISnapshotSurface.allCases.flatMap { surface in
            UISnapshotAppearance.allCases.map {
                UISnapshotPlan(surface: surface, appearance: $0, accessibilityText: false)
            }
        }
        return standard + [
            UISnapshotPlan(surface: .settings, appearance: .light, accessibilityText: true),
            UISnapshotPlan(surface: .about, appearance: .dark, accessibilityText: true),
        ]
    }()
}

enum UISnapshotRendererError: LocalizedError {
    case missingOutputDirectory
    case cannotCreateBitmap(String)
    case emptyPNG(String)
    case missingAsset(String)

    var errorDescription: String? {
        switch self {
        case .missingOutputDirectory:
            "usage: OpenWritr --render-ui-snapshots <output-directory>"
        case .cannotCreateBitmap(let filename):
            "Could not create a bitmap for \(filename)."
        case .emptyPNG(let filename):
            "Rendered PNG is empty: \(filename)."
        case .missingAsset(let path):
            "Required snapshot asset is missing: \(path)."
        }
    }
}

@MainActor
enum UISnapshotRenderer {
    private static let settingsSize = NSSize(width: 560, height: 1_180)
    private static let accessibilitySettingsSize = NSSize(width: 640, height: 1_380)
    private static let aboutSize = NSSize(width: 480, height: 540)
    private static let overlaySize = NSSize(width: 320, height: 120)

    static func run(arguments: [String]) -> Never {
        do {
            guard let flag = arguments.firstIndex(of: "--render-ui-snapshots"),
                  arguments.count == flag + 2
            else {
                throw UISnapshotRendererError.missingOutputDirectory
            }

            let outputDirectory = URL(
                fileURLWithPath: arguments[flag + 1],
                isDirectory: true
            )
            try renderAll(to: outputDirectory)
            print("Rendered \(UISnapshotPlan.all.count) UI snapshots to \(outputDirectory.path)")
            exit(EXIT_SUCCESS)
        } catch {
            fputs("UI snapshot rendering failed: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    static func renderAll(to outputDirectory: URL) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let viewModel = makeSettingsViewModel()
        let aboutMetadata = try loadAboutMetadata()

        for plan in UISnapshotPlan.all {
            let destination = outputDirectory.appendingPathComponent(plan.filename)
            let rendered = try render(
                view: view(
                    for: plan,
                    viewModel: viewModel,
                    aboutMetadata: aboutMetadata
                ),
                size: size(for: plan),
                plan: plan
            )
            guard !rendered.isEmpty else {
                throw UISnapshotRendererError.emptyPNG(plan.filename)
            }
            try rendered.write(to: destination, options: .atomic)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
                  let fileSize = attributes[.size] as? NSNumber,
                  fileSize.intValue > 0
            else {
                throw UISnapshotRendererError.emptyPNG(plan.filename)
            }
        }
    }

    private static func makeSettingsViewModel() -> AppViewModel {
        let viewModel = AppViewModel()
        viewModel.state = .ready
        viewModel.availableInputDevices = [
            AudioInputDevice(id: 101, name: "Studio Display Microphone", uid: "snapshot-studio-display"),
            AudioInputDevice(id: 102, name: "USB Podcast Microphone", uid: "snapshot-usb-microphone"),
        ]
        viewModel.selectedInputDeviceID = nil
        viewModel.inputDeviceStatusMessage = "OpenWritr follows the current macOS system input device."
        viewModel.hotkeyChoice = .fn
        viewModel.autoPasteEnabled = true
        viewModel.soundEnabled = true
        viewModel.enhancedModeEnabled = true
        viewModel.alwaysEnhancedEnabled = false
        viewModel.enhancedProvider = .copilot
        viewModel.enhancedModel = .luna
        viewModel.appleIntelligenceAvailability = .available
        viewModel.launchAtLogin = false
        viewModel.debugModeEnabled = false
        return viewModel
    }

    private static func view(
        for plan: UISnapshotPlan,
        viewModel: AppViewModel,
        aboutMetadata: (version: String, icon: NSImage)
    ) -> AnyView {
        switch plan.surface {
        case .settings:
            return AnyView(
                SettingsView(
                    viewModel: viewModel,
                    snapshotConfiguration: SettingsSnapshotConfiguration(
                        automaticUpdatesEnabled: true
                    )
                )
            )
        case .about:
            return AnyView(
                AboutView(
                    versionTextOverride: aboutMetadata.version,
                    iconOverride: aboutMetadata.icon
                )
            )
        case .overlayListening:
            return overlayView(state: .listening(enhanced: false), audioLevel: 0.42)
        case .overlayTranscribing:
            return overlayView(state: .transcribing)
        case .overlayEnhancing:
            return overlayView(state: .enhancing)
        case .overlayDone:
            return overlayView(state: .done)
        case .overlayError:
            return overlayView(state: .error("Try again"))
        }
    }

    private static func overlayView(
        state: OverlayState,
        audioLevel: Float = 0
    ) -> AnyView {
        let presentation = OverlayPresentation()
        presentation.setState(state)
        presentation.updateAudioLevel(audioLevel)
        presentation.isVisible = true

        return AnyView(
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                OverlayContentView(presentation: presentation, snapshotPhase: 1.75)
            }
        )
    }

    private static func size(for plan: UISnapshotPlan) -> NSSize {
        switch plan.surface {
        case .settings:
            plan.accessibilityText ? accessibilitySettingsSize : settingsSize
        case .about: aboutSize
        case .overlayListening, .overlayTranscribing, .overlayEnhancing, .overlayDone, .overlayError:
            overlaySize
        }
    }

    private static func render(
        view: AnyView,
        size: NSSize,
        plan: UISnapshotPlan
    ) throws -> Data {
        let sizedView: AnyView
        if plan.accessibilityText {
            sizedView = AnyView(
                view
                    .environment(\.font, .system(size: 18))
                    .dynamicTypeSize(.accessibility3)
            )
        } else {
            sizedView = view
        }
        let rootView = ZStack {
            Color(nsColor: .windowBackgroundColor)
            sizedView
        }
        .environment(\.colorScheme, plan.appearance.colorScheme)
        .environment(\.displayScale, CGFloat(UISnapshotPlan.scale))
        .frame(width: size.width, height: size.height)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.appearance = NSAppearance(named: plan.appearance.appKitAppearance)

        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = hostingView.appearance
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.contentView = hostingView
        window.orderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let pixelWidth = Int(size.width) * UISnapshotPlan.scale
        let pixelHeight = Int(size.height) * UISnapshotPlan.scale
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw UISnapshotRendererError.cannotCreateBitmap(plan.filename)
        }
        bitmap.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        window.orderOut(nil)

        guard let data = bitmap.representation(using: .png, properties: [:]),
              !data.isEmpty
        else {
            throw UISnapshotRendererError.emptyPNG(plan.filename)
        }
        return data
    }

    private static func loadAboutMetadata() throws -> (version: String, icon: NSImage) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoURL = root.appendingPathComponent("Info.plist")
        let iconURL = root.appendingPathComponent("Resources/AppIcon.icns")

        guard let infoData = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: infoData,
                options: [],
                format: nil
              ) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String
        else {
            throw UISnapshotRendererError.missingAsset(infoURL.path)
        }
        guard let icon = NSImage(contentsOf: iconURL) else {
            throw UISnapshotRendererError.missingAsset(iconURL.path)
        }
        let build = plist["CFBundleVersion"] as? String ?? version
        let versionText = version == build ? "Version \(version)" : "Version \(version) (\(build))"
        return (versionText, icon)
    }
}
