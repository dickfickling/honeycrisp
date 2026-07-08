import Testing
@testable import CompanionKit

@Test func smokeTestVersionIsSet() {
    #expect(CompanionKit.version == "0.1.0")
}
