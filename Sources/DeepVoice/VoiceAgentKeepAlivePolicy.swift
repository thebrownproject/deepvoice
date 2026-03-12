import Foundation

struct VoiceAgentKeepAlivePolicy {
    static let interval: TimeInterval = 8.0

    static func nextDelay(since lastOutboundActivity: Date, now: Date = Date()) -> TimeInterval {
        max(0, interval - now.timeIntervalSince(lastOutboundActivity))
    }
}
