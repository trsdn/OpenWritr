import Testing
@testable import OpenWritr

@Suite("SelfTest word matching")
struct SelfTestTests {
    @Test func ignoresCaseAndPunctuation() {
        let missing = SelfTest.missingWords(
            expected: ["hello", "world", "test"],
            in: "Hello World! This is a Test."
        )
        #expect(missing.isEmpty)
    }

    @Test func reportsWordsThatAreAbsent() {
        let missing = SelfTest.missingWords(expected: ["hello", "banana"], in: "Hello there.")
        #expect(missing == ["banana"])
    }

    @Test func matchesWholeWordsOnly() {
        #expect(SelfTest.missingWords(expected: ["test"], in: "Testing testers.") == ["test"])
    }
}
