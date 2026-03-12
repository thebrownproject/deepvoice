import XCTest
@testable import DeepVoice

final class ConfigAndFormattingTests: XCTestCase {
    func testConfigDecodeBackfillsMissingFieldsFromDefaults() throws {
        let json = """
        {
          "llm_model": "openai/gpt-4.1-mini",
          "safe_mode": false
        }
        """

        let decoded = try JSONDecoder().decode(DeepVoiceConfig.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.llmModel, "openai/gpt-4.1-mini")
        XCTAssertFalse(decoded.safeMode)
        XCTAssertEqual(decoded.sttModel, DeepVoiceConfig.defaults.sttModel)
        XCTAssertEqual(decoded.voice, DeepVoiceConfig.defaults.voice)
        XCTAssertEqual(decoded.confirmDestructive, DeepVoiceConfig.defaults.confirmDestructive)
    }

    func testCondenseForVoiceStripsMarkdownAndTruncates() {
        let input = """
        # Heading

        Here is a [link](https://example.com) and `inline code`.

        ```swift
        let ignored = true
        ```

        This sentence should stay. This sentence should also stay. This sentence should be cut off.
        """

        let condensed = condenseForVoice(input, maxChars: 70)

        XCTAssertFalse(condensed.contains("#"))
        XCTAssertFalse(condensed.contains("```"))
        XCTAssertFalse(condensed.contains("[link]"))
        XCTAssertFalse(condensed.contains("https://example.com"))
        XCTAssertTrue(condensed.contains("link"))
        XCTAssertTrue(condensed.count <= 71)
    }
}
