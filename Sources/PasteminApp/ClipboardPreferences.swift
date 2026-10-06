#if !PASTEMIN_APP_STORE
import CoreGraphics
#endif
import Foundation

@MainActor
final class ClipboardPreferences: ObservableObject {
    @Published var retention: RetentionPeriod {
        didSet {
            defaults.set(retention.rawValue, forKey: Keys.retention)
            onRetentionChange?(retention)
        }
    }

    @Published var shortcut: GlobalShortcut {
        didSet {
            if let data = try? JSONEncoder().encode(shortcut) {
                defaults.set(data, forKey: Keys.shortcut)
            }
            onShortcutChange?(shortcut)
        }
    }

    @Published var showInMenuBar: Bool {
        didSet {
            defaults.set(showInMenuBar, forKey: Keys.showInMenuBar)
            onMenuBarVisibilityChange?(showInMenuBar)
        }
    }

    #if !PASTEMIN_APP_STORE
    // Keep the local edition's choice out of Store reads and writes.
    @Published var pasteAutomatically: Bool {
        didSet {
            defaults.set(pasteAutomatically, forKey: Keys.pasteAutomatically)
        }
    }

    @Published private(set) var automaticPasteAuthorized: Bool
    #endif

    @Published var hotKeyError: String?
    var onRetentionChange: ((RetentionPeriod) -> Void)?
    var onShortcutChange: ((GlobalShortcut) -> Void)?
    var onMenuBarVisibilityChange: ((Bool) -> Void)?
    private let defaults: UserDefaults

    private enum Keys {
        static let retention = "PasteminRetentionPeriod"
        static let shortcut = "PasteminGlobalShortcut"
        static let showInMenuBar = "PasteminShowInMenuBar"
        #if !PASTEMIN_APP_STORE
        static let pasteAutomatically = "PasteminPasteAutomatically"
        #endif
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        retention = defaults.string(forKey: Keys.retention)
            .flatMap(RetentionPeriod.init(rawValue:)) ?? .oneMonth
        shortcut = defaults.data(forKey: Keys.shortcut)
            .flatMap { try? JSONDecoder().decode(GlobalShortcut.self, from: $0) }
            ?? .defaultShortcut
        showInMenuBar = defaults.object(forKey: Keys.showInMenuBar) as? Bool ?? true
        #if !PASTEMIN_APP_STORE
        pasteAutomatically = defaults.object(forKey: Keys.pasteAutomatically) as? Bool ?? false
        automaticPasteAuthorized = CGPreflightPostEventAccess()
        #endif
    }

    #if !PASTEMIN_APP_STORE
    /// refreshAutomaticPasteAuthorization() updates the local permission indicator.
    func refreshAutomaticPasteAuthorization() {
        automaticPasteAuthorized = CGPreflightPostEventAccess()
    }
    #endif
}
