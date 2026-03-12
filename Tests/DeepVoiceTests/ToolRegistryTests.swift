import XCTest
@testable import DeepVoice

final class ToolRegistryTests: XCTestCase {
    func testSafeModeHidesFileWriteAndGuardsShellTools() {
        var config = DeepVoiceConfig.defaults
        config.safeMode = true
        config.confirmDestructive = false

        let registry = ToolRegistry.withDefaultTools(config: config)
        let names = Set(registry.registeredToolNames())

        XCTAssertFalse(names.contains("file_write"))
        XCTAssertTrue(registry.needsApproval("safe_bash"))
        XCTAssertTrue(registry.needsApproval("applescript"))
        XCTAssertFalse(registry.needsApproval("file_read"))
    }

    func testUnsafeModeRestoresFileWriteAndUsesConfirmDestructiveForApproval() {
        var config = DeepVoiceConfig.defaults
        config.safeMode = false
        config.confirmDestructive = false

        let registry = ToolRegistry.withDefaultTools(config: config)
        let names = Set(registry.registeredToolNames())

        XCTAssertTrue(names.contains("file_write"))
        XCTAssertFalse(registry.needsApproval("safe_bash"))
        XCTAssertFalse(registry.needsApproval("applescript"))
        XCTAssertFalse(registry.needsApproval("file_write"))
    }
}
