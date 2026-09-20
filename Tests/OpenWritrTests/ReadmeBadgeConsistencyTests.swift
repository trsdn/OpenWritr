import Foundation
import Testing

/// The README's license and platform badges are typed by hand, so this test
/// fails when they drift from the sources they report (criterion P08).
@Suite("README badges match their sources")
struct ReadmeBadgeConsistencyTests {
    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func platformBadgeMatchesTheManifest() throws {
        let manifest = try read("Package.swift")
        let match = try #require(manifest.firstMatch(of: /\.macOS\(\.v(\d+)\)/))
        let readme = try read("README.md")
        #expect(
            readme.contains("img.shields.io/badge/macOS-\(match.1)%2B-"),
            "README platform badge must say macOS \(match.1)+ to match Package.swift"
        )
    }

    @Test func licenseBadgeMatchesTheLicenseFile() throws {
        let license = try read("LICENSE")
        #expect(license.hasPrefix("MIT License"), "LICENSE is no longer the MIT licence")
        #expect(try read("README.md").contains("img.shields.io/badge/License-MIT-"))
    }
}
