import Foundation

// Product identifiers must match App Store Connect exactly.
enum PasteminProductID {
    static let yearly = "tools.min.pastemin.pro.yearly"
    static let lifetime = "tools.min.pastemin.pro.lifetime"
    static let all = [yearly, lifetime]
}

// The app grants 30 days of full access without starting a subscription.
enum PasteminFreeAccessPolicy {
    static let trialLengthDays = 30
    static let trialDuration = TimeInterval(trialLengthDays * 24 * 60 * 60)

    // authoritativeTrialStartDate(appStoreOriginalPurchaseDate,
    // localStartedAt, usesAppStoreDate): Never fall back to resettable local
    // state when a production App Store build requires Apple's signed date.
    static func authoritativeTrialStartDate(
        appStoreOriginalPurchaseDate: Date?,
        localStartedAt: Date?,
        usesAppStoreDate: Bool
    ) -> Date? {
        usesAppStoreDate ? appStoreOriginalPurchaseDate : localStartedAt
    }

    // isTrialActive(startedAt, [now]): Return whether the full-access period remains active.
    static func isTrialActive(startedAt: Date, now: Date = Date()) -> Bool {
        now < startedAt.addingTimeInterval(trialDuration)
    }

    // trialDaysRemaining(startedAt, [now]): Round a partial remaining day up for status text.
    static func trialDaysRemaining(startedAt: Date, now: Date = Date()) -> Int {
        let seconds = startedAt.addingTimeInterval(trialDuration).timeIntervalSince(now)
        return max(0, Int(ceil(seconds / (24 * 60 * 60))))
    }
}

// Keep StoreKit out of the entitlement decisions so they remain easy to test.
struct PasteminTransactionSummary: Equatable {
    var productID: String
    var expirationDate: Date?
    var revocationDate: Date?
    var isFamilyShared: Bool
    var isIntroductoryOffer: Bool
}

struct PasteminEntitlement: Equatable {
    enum Kind: Equatable {
        case none
        case lifetime
        case subscription
    }

    var kind: Kind = .none
    var expirationDate: Date?
    var isTrial = false
    var isFamilyShared = false
    var willAutoRenew: Bool?

    var hasAccess: Bool { kind != .none }
    static let none = PasteminEntitlement()
}

enum PasteminEntitlementLogic {
    // StoreKit's current-entitlement sequence already accounts for expiry and billing grace.
    static func evaluate(_ transactions: [PasteminTransactionSummary]) -> PasteminEntitlement {
        let live = transactions.filter {
            $0.revocationDate == nil && PasteminProductID.all.contains($0.productID)
        }
        if let lifetime = preferred(live.filter { $0.productID == PasteminProductID.lifetime }) {
            return PasteminEntitlement(kind: .lifetime, isFamilyShared: lifetime.isFamilyShared)
        }
        guard let yearly = preferred(live.filter { $0.productID == PasteminProductID.yearly }) else {
            return .none
        }
        return PasteminEntitlement(
            kind: .subscription,
            expirationDate: yearly.expirationDate,
            isTrial: yearly.isIntroductoryOffer,
            isFamilyShared: yearly.isFamilyShared
        )
    }

    private static func preferred(_ candidates: [PasteminTransactionSummary]) -> PasteminTransactionSummary? {
        candidates.max { first, second in
            if first.isFamilyShared != second.isFamilyShared {
                return first.isFamilyShared
            }
            return (first.expirationDate ?? .distantFuture) < (second.expirationDate ?? .distantFuture)
        }
    }
}
