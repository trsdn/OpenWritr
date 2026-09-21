import AppKit
import SwiftUI

struct AboutView: View {
    private let versionTextOverride: String?
    private let iconOverride: NSImage?

    init(versionTextOverride: String? = nil, iconOverride: NSImage? = nil) {
        self.versionTextOverride = versionTextOverride
        self.iconOverride = iconOverride
    }

    private var versionText: String {
        if let versionTextOverride {
            return versionTextOverride
        }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info?["CFBundleVersion"] as? String ?? version
        return version == build ? "Version \(version)" : "Version \(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: iconOverride ?? NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            VStack(spacing: 5) {
                Text("OpenWritr")
                    .font(.title.bold())
                Text(versionText)
                    .foregroundStyle(.secondary)
                Text("Open-source push-to-talk voice-to-text for macOS.")
                    .multilineTextAlignment(.center)
            }

            Divider()

            VStack(spacing: 10) {
                destinationLink("Project Website", systemImage: "globe", destination: .website)
                destinationLink("Source Code", systemImage: "chevron.left.forwardslash.chevron.right", destination: .repository)
                destinationLink("Report an Issue", systemImage: "exclamationmark.bubble", destination: .newIssue)
                destinationLink("Downloads & Releases", systemImage: "arrow.down.circle", destination: .releases)
                destinationLink("MIT License", systemImage: "doc.text", destination: .license)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(spacing: 4) {
                Text("Made by Torsten Mahr")
                    .font(.subheadline.weight(.medium))
                Text("Copyright © 2026 Torsten · MIT licensed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(width: 430)
    }

    private func destinationLink(
        _ title: String,
        systemImage: String,
        destination: ProjectDestination
    ) -> some View {
        Link(destination: destination.url) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private enum ProjectDestination: String {
    case website = "https://trsdn.github.io/OpenWritr/"
    case repository = "https://github.com/trsdn/OpenWritr"
    case newIssue = "https://github.com/trsdn/OpenWritr/issues/new"
    case releases = "https://github.com/trsdn/OpenWritr/releases"
    case license = "https://github.com/trsdn/OpenWritr/blob/main/LICENSE"

    var url: URL {
        guard let url = URL(string: rawValue) else {
            preconditionFailure("Invalid project URL: \(rawValue)")
        }
        return url
    }
}
