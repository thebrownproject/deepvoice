import Foundation
import XCTest
@testable import DeepVoice

final class ShellToolsTests: XCTestCase {
    func testSafeBashTruncatesHighOutputWithoutHanging() async throws {
        let url = URL(fileURLWithPath: "/tmp/deepvoice-safe-bash-\(UUID().uuidString)")
        let content = String(repeating: "a", count: 20_000)
        try Data(content.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let payload = try XCTUnwrap(
            String(
                data: JSONSerialization.data(withJSONObject: ["command": "cat \(url.path)"]),
                encoding: .utf8
            )
        )

        let result = try await safeBashHandler(payload)

        XCTAssertTrue(result.contains("truncated"))
        XCTAssertLessThan(result.count, 11_500)
    }
}
