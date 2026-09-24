import Foundation

// Keep one app identity while separating public and private access policy.
enum PasteminEdition {
    static let bundleIdentifier = "tools.min.pastemin"

    #if PASTEMIN_APP_STORE
    // Production App Store builds use the signed app acquisition date.
    static let isAppStoreBuild = true
    #else
    // Source and private builds retain the disclosed local trial.
    static let isAppStoreBuild = false
    #endif

    // Reject a private override if an App Store flag is ever added to an archive.
    #if PASTEMIN_LOCAL_BUILD && PASTEMIN_APP_STORE
    #error("Local access must not be included in an App Store build.")
    #elseif PASTEMIN_LOCAL_BUILD && PASTEMIN_EXPIRED_TRIAL_BUILD
    // Preview the public post-trial state without granting local Pro access.
    static let localAccess: Bool? = nil
    static let localAccessStatus: String? = nil
    static let forcedTrialStartedAt: Date? = PasteminLocalAccess.expiredTrialStartedAt
    static let isExpiredTrialPreview = true
    #elseif PASTEMIN_LOCAL_BUILD
    static let localAccess: Bool? = PasteminLocalAccess.hasAccess
    static let localAccessStatus: String? = PasteminLocalAccess.status
    static let forcedTrialStartedAt: Date? = nil
    static let isExpiredTrialPreview = false
    #else
    // Public source and App Store builds both require verified access.
    static let localAccess: Bool? = nil
    static let localAccessStatus: String? = nil
    static let forcedTrialStartedAt: Date? = nil
    static let isExpiredTrialPreview = false
    #endif
}
