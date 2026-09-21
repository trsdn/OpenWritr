import Testing
@testable import OpenWritr

@Suite("UI snapshot plan")
struct UISnapshotPlanTests {
    @Test func coversEverySurfaceInLightAndDark() {
        for surface in UISnapshotSurface.allCases {
            for appearance in UISnapshotAppearance.allCases {
                #expect(
                    UISnapshotPlan.all.contains {
                        $0.surface == surface
                            && $0.appearance == appearance
                            && !$0.accessibilityText
                    }
                )
            }
        }
    }

    @Test func includesLargerAccessibilityText() {
        let accessibilityPlans = UISnapshotPlan.all.filter(\.accessibilityText)
        #expect(accessibilityPlans.map(\.surface) == [.settings, .about])
    }

    @Test func filenamesAreUniqueAndStable() {
        let filenames = UISnapshotPlan.all.map(\.filename)
        #expect(filenames.count == 16)
        #expect(Set(filenames).count == filenames.count)
        #expect(filenames.contains("settings-light.png"))
        #expect(filenames.contains("overlay-error-dark.png"))
        #expect(filenames.contains("settings-light-accessibility-text.png"))
    }
}
