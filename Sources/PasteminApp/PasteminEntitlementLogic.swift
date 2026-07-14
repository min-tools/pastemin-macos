import Foundation

// Product identifiers must match App Store Connect exactly.
enum PasteminProductID {
    static let yearly = "tools.min.pastemin.pro.yearly"
    static let lifetime = "tools.min.pastemin.pro.lifetime"
    static let all = [yearly, lifetime]
}

// The public app grants its first 30 days locally, without starting a subscription.
enum PasteminFreeAccessPolicy {
    static let trialLengthDays = 30
    static let trialDuration = TimeInterval(trialLengthDays * 24 * 60 * 60)

    // isTrialActive(startedAt, [now]): Return whether the local full-access period remains active.
    static func isTrialActive(startedAt: Date, now: Date = Date()) -> Bool {
        now < startedAt.addingTimeInterval(trialDuration)
    }

    // trialDaysRemaining(startedAt, [now]): Round a partial remaining day up for status text.
    static func trialDaysRemaining(startedAt: Date, now: Date = Date()) -> Int {
        let seconds = startedAt.addingTimeInterval(trialDuration).timeIntervalSince(now)
        return max(0, Int(ceil(seconds / (24 * 60 * 60))))
    }
}
