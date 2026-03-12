import XCTest
@testable import DeepVoice

final class VoiceAgentKeepAlivePolicyTests: XCTestCase {
    func testNextDelayReturnsRemainderOfEightSecondIdleWindow() {
        let now = Date(timeIntervalSinceReferenceDate: 10)
        let lastOutbound = Date(timeIntervalSinceReferenceDate: 4.5)

        let delay = VoiceAgentKeepAlivePolicy.nextDelay(since: lastOutbound, now: now)

        XCTAssertEqual(delay, 2.5, accuracy: 0.001)
    }

    func testNextDelayClampsAtZeroOnceIdleWindowHasElapsed() {
        let now = Date(timeIntervalSinceReferenceDate: 20)
        let lastOutbound = Date(timeIntervalSinceReferenceDate: 5)

        let delay = VoiceAgentKeepAlivePolicy.nextDelay(since: lastOutbound, now: now)

        XCTAssertEqual(delay, 0, accuracy: 0.001)
    }
}
