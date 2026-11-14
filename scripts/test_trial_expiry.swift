import Foundation

// Advance time without waiting 30 days or changing the workstation clock.
enum TrialClock {
    static var now = Date()
}

@MainActor enum TrialExpiryTests {
    // run(): Exercise live expiry with local, sandbox, and signed trial dates.
    static func run() async throws {
        let originalTime = TrialClock.now
        defer {
            TrialClock.now = originalTime
            TrialFixture.defaults.values = [:]
            TrialFixture.transaction = TrialFixture.Transaction()
        }
        let environments: [TrialFixture.Environment] = PasteminEdition.isAppStoreBuild
            ? [.production, .sandbox] : [.sandbox]
        for environment in environments {
            TrialFixture.transaction.environment = environment
            // Cover an on-time callback and a refresh before an overdue timer runs.
            for refreshBeforeTimer in [false, true] {
                try await checkExpiry(refreshBeforeTimer: refreshBeforeTimer)
            }
        }
        print("Live trial expiry, search limits, and purchase recovery passed")
    }

    // checkExpiry(refreshBeforeTimer): Keep one history model alive across expiry.
    static func checkExpiry(refreshBeforeTimer: Bool) async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let records = (0..<8).map { index in
            ClipboardRecord(
                id: UUID(), createdAt: Date(), kind: .text, text: "Item \(index)",
                textFilename: nil, imageFilename: nil, sourceAppName: "Fixture",
                sourceBundleIdentifier: nil, byteCount: 6, signature: "fixture-\(index)"
            )
        }
        try JSONEncoder().encode(records).write(to: root.appendingPathComponent("history.json"))
        let history = try ClipboardHistoryStore(rootURL: root, retention: .oneMonth)
        let model = ClipboardViewModel(store: history, itemLimit: 5)
        let startedAt = TrialClock.now.addingTimeInterval(-PasteminFreeAccessPolicy.trialDuration + 60)
        TrialFixture.defaults.values = [
            "PasteminAppTrialStartedAt": startedAt,
            "PasteminAppTrialDisclosureAccepted": true,
            "PasteminTestTrialClockV1": true,
        ]
        TrialFixture.transaction.originalPurchaseDate = startedAt
        let store = PasteminStore()
        store.hasResolvedEntitlement = true

        // Use the same notification and object filter as the clipboard controller.
        let observer = NotificationCenter.default.addObserver(
            forName: PasteminStore.entitlementDidChange, object: store, queue: .main
        ) { _ in
            Task { @MainActor in model.updateItemLimit(store.hasFullAccess ? nil : 5) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        await refreshTrial(store)
        try await TrialStartupTests.waitFor("The active trial must unlock all eight items") {
            model.filteredItems.count == 8
        }
        precondition(!bannerIsVisible(store))
        var timer = store.appTrialTimer!

        // A clock correction can leave the trial active when the timer fires.
        if !refreshBeforeTimer {
            TrialClock.now = TrialClock.now.addingTimeInterval(-60)
            timer.fire()
            try await TrialStartupTests.waitFor("An early expiry timer must be re-armed") {
                guard let scheduled = store.appTrialTimer else { return false }
                return scheduled !== timer && scheduled.isValid
            }
            precondition(store.hasFullAccess && model.filteredItems.count == 8)
            timer = store.appTrialTimer!
        }

        // Leave an old item selected and a full-history search pending at expiry.
        model.select(records.last!.id)
        model.updateQuery("Item 7")
        TrialClock.now = startedAt.addingTimeInterval(PasteminFreeAccessPolicy.trialDuration)
        if refreshBeforeTimer {
            // Activation after sleep can refresh the same date before the timer fires.
            await refreshTrial(store)
        } else {
            // The regular timer must apply the limit while the history stays open.
            timer.fire()
        }
        precondition(bannerIsVisible(store), "The trial banner must reflect expiry")
        try await TrialStartupTests.waitFor(
            "Expiry must limit history to five items; refresh before timer: \(refreshBeforeTimer)"
        ) { model.filteredItems.count == 5 }
        await model.waitForSearchCompletion()
        precondition(model.filteredItems.map(\.id) == Array(records.prefix(5)).map(\.id))
        precondition(model.selectedID == records.first?.id, "Expiry clears an inaccessible selection")
        model.updateQuery("Item 7")
        await model.waitForSearchCompletion()
        precondition(model.filteredItems.isEmpty, "Search must not expose older items after expiry")
        precondition(history.items.count == 8, "Expiry must retain the complete stored history")

        // Rechecking the same access must not clear an active search.
        await refreshTrial(store)
        await Task.yield()
        precondition(model.query == "Item 7", "Unchanged access must preserve the search")

        // A purchase restores the retained history without recreating the model.
        store.apply(PasteminEntitlement(kind: .lifetime))
        try await TrialStartupTests.waitFor("A purchase must restore all eight items") {
            model.filteredItems.count == 8
        }
        precondition(!bannerIsVisible(store))
    }

    // refreshTrial(store): Recheck the date through the edition's production path.
    static func refreshTrial(_ store: PasteminStore) async {
        if PasteminEdition.isAppStoreBuild {
            // Store builds use the verified transaction's environment and date.
            await store.refreshAppTrial(now: TrialClock.now)
        } else {
            // Source builds restore the disclosed local date.
            store.prepareLocalAppTrial(now: TrialClock.now)
        }
    }
}
