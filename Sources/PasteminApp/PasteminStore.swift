import AppKit
import StoreKit
import SwiftUI

@MainActor
final class PasteminStore: ObservableObject {
    static let shared = PasteminStore()
    static let entitlementDidChange = Notification.Name("tools.min.pastemin.entitlementDidChange")
    static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

    enum PurchaseOutcome {
        case unlocked
        case pending
        case cancelled
    }

    struct StoreError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @Published private(set) var entitlement: PasteminEntitlement = .none
    @Published private(set) var yearly: Product?
    @Published private(set) var lifetime: Product?
    @Published private(set) var appTrialStartedAt: Date?
    @Published private(set) var hasResolvedEntitlement = false

    private var updatesTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var refreshGeneration = 0
    private var entitlementTimer: Timer?
    private var appTrialTimer: Timer?
    private let defaults = UserDefaults.standard

    private static let appTrialStartedAtKey = "PasteminAppTrialStartedAt"
    private static let appTrialDisclosureAcceptedKey = "PasteminAppTrialDisclosureAccepted"
    private var developerOverride: Bool? { PasteminEdition.localAccess }

    var isPro: Bool { developerOverride ?? entitlement.hasAccess }
    var isAppTrialActive: Bool {
        guard developerOverride == nil, !entitlement.hasAccess, let appTrialStartedAt else {
            return false
        }
        return PasteminFreeAccessPolicy.isTrialActive(startedAt: appTrialStartedAt)
    }
    var hasFullAccess: Bool { isPro || isAppTrialActive }
    var canManageSubscription: Bool {
        developerOverride == nil && entitlement.kind == .subscription && !entitlement.isFamilyShared
    }

    func start() {
        // Private local builds resolve immediately without contacting StoreKit.
        guard developerOverride == nil else {
            hasResolvedEntitlement = true
            return
        }
        // Source and private previews restore their local trial immediately.
        if !PasteminEdition.isAppStoreBuild {
            prepareLocalAppTrial()
        }
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                }
                await self?.refreshEntitlement()
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !PasteminEdition.isAppStoreBuild {
                    self.prepareLocalAppTrial()
                    self.objectWillChange.send()
                    NotificationCenter.default.post(name: Self.entitlementDidChange, object: self)
                }
                await self.refreshEntitlement()
            }
        }
        Task { [weak self] in await self?.refreshEntitlement() }
    }

    deinit {
        updatesTask?.cancel()
        entitlementTimer?.invalidate()
        appTrialTimer?.invalidate()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    func refreshEntitlement() async {
        // Private access does not need a receipt refresh.
        guard developerOverride == nil else {
            hasResolvedEntitlement = true
            return
        }
        await refreshAppTrial()
        refreshGeneration += 1
        let generation = refreshGeneration
        var summaries: [PasteminTransactionSummary] = []
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            summaries.append(summary(of: transaction))
        }
        guard generation == refreshGeneration else { return }
        // Avoid presenting a false expired-access banner before StoreKit's cached state resolves.
        hasResolvedEntitlement = true
        var updated = PasteminEntitlementLogic.evaluate(summaries)
        if updated.kind == entitlement.kind,
           updated.expirationDate == entitlement.expirationDate,
           updated.isFamilyShared == entitlement.isFamilyShared {
            updated.willAutoRenew = entitlement.willAutoRenew
        }
        apply(updated)
        scheduleRefresh()
        if updated.kind == .subscription {
            updated.willAutoRenew = await subscriptionWillAutoRenew(for: updated)
            guard generation == refreshGeneration else { return }
            apply(updated)
        }
    }

    func loadProducts() async throws {
        // The ignored local build has no purchasable state to load.
        guard developerOverride == nil else { return }
        let products = try await Product.products(for: PasteminProductID.all)
        let yearly = products.first { $0.id == PasteminProductID.yearly }
        let lifetime = products.first { $0.id == PasteminProductID.lifetime }
        guard yearly != nil || lifetime != nil else {
            throw StoreError(message: localized(
                "purchases_unavailable",
                "Pastemin purchases are unavailable right now. Please try again later."
            ))
        }
        self.yearly = yearly
        self.lifetime = lifetime
    }

    func purchase(_ product: Product) async throws -> PurchaseOutcome {
        // Private access is already unlocked and must not start a purchase.
        if developerOverride == true { return .unlocked }
        switch try await product.purchase(options: []) {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                throw StoreError(message: localized(
                    "purchase_verification_failed",
                    "The App Store could not verify this purchase."
                ))
            }
            await transaction.finish()
            await refreshEntitlement()
            return .unlocked
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    func restore() async throws -> Bool {
        // Private access is already available without an Apple Account.
        if developerOverride == true { return true }
        try await AppStore.sync()
        await refreshEntitlement()
        return isPro
    }

    func statusText() -> String {
        // Identify private development access separately from a purchase.
        if developerOverride == true {
            return PasteminEdition.localAccessStatus ?? localized("lifetime_access", "Lifetime access")
        }
        // Describe the independent app trial before purchase entitlement details.
        if isAppTrialActive, let appTrialStartedAt {
            let days = PasteminFreeAccessPolicy.trialDaysRemaining(startedAt: appTrialStartedAt)
            return days == 1
                ? localized("app_trial_one_day", "Full access trial · 1 day remaining")
                : localizedFormat(
                    "app_trial_days",
                    "Full access trial · %lld days remaining",
                    Int64(days)
                )
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        switch entitlement.kind {
        case .none:
            return localized("trial_or_purchase_required", "Trial or purchase required")
        case .lifetime:
            return entitlement.isFamilyShared
                ? localized("lifetime_family_shared", "Lifetime · shared with your family")
                : localized("lifetime_access", "Lifetime access")
        case .subscription:
            if entitlement.isFamilyShared {
                return localized("subscription_family_shared", "Subscription · shared with your family")
            }
            guard let date = entitlement.expirationDate else {
                return localized("yearly_subscription_active", "Yearly subscription active")
            }
            let formatted = formatter.string(from: date)
            if entitlement.isTrial {
                if entitlement.willAutoRenew == true {
                    return localizedFormat("trial_first_payment", "Trial · first payment %@", formatted)
                }
                if entitlement.willAutoRenew == false {
                    return localizedFormat("trial_ends", "Trial · ends %@", formatted)
                }
                return localizedFormat("trial_through", "Trial · through %@", formatted)
            }
            if entitlement.willAutoRenew == true {
                return localizedFormat(
                    "yearly_subscription_renews",
                    "Yearly subscription · renews %@",
                    formatted
                )
            }
            if entitlement.willAutoRenew == false {
                return localizedFormat(
                    "yearly_subscription_ends",
                    "Yearly subscription · ends %@",
                    formatted
                )
            }
            return localizedFormat(
                "yearly_subscription_through",
                "Yearly subscription · through %@",
                formatted
            )
        }
    }

    /// Records acceptance of the disclosed trial and resolves its start date.
    func beginAppTrial(now: Date = Date()) {
        defaults.set(true, forKey: Self.appTrialDisclosureAcceptedKey)
        // App Store builds must verify the transaction environment before choosing a clock.
        if PasteminEdition.isAppStoreBuild {
            Task { @MainActor [weak self] in
                await self?.refreshAppTrial(now: now)
            }
        } else {
            prepareLocalAppTrial(startIfNeeded: true, now: now)
        }
    }

    // refreshAppTrial([now]): Use Apple's signed acquisition date in production.
    // Verified sandbox builds retain the local clock needed for review and testing.
    private func refreshAppTrial(now: Date = Date()) async {
        guard PasteminEdition.isAppStoreBuild else { return }
        guard let result = try? await AppTransaction.shared,
              case .verified(let transaction) = result,
              transaction.bundleID == PasteminEdition.bundleIdentifier else {
            // A production build must never replace a failed signed lookup with local state.
            return
        }
        if transaction.environment == .production {
            let authoritative = PasteminFreeAccessPolicy.authoritativeTrialStartDate(
                appStoreOriginalPurchaseDate: transaction.originalPurchaseDate,
                localStartedAt: nil,
                usesAppStoreDate: true
            )
            if let authoritative {
                applyAppTrialStartDate(authoritative, now: now)
            }
        } else {
            let accepted = defaults.bool(forKey: Self.appTrialDisclosureAcceptedKey)
            prepareLocalAppTrial(
                startIfNeeded: accepted,
                now: now,
                allowAppStoreSandbox: true
            )
        }
    }

    // prepareLocalAppTrial([startIfNeeded = false], [now],
    // [allowAppStoreSandbox = false]): Restore or start the local test clock.
    private func prepareLocalAppTrial(
        startIfNeeded: Bool = false,
        now: Date = Date(),
        allowAppStoreSandbox: Bool = false
    ) {
        // Only a verified sandbox transaction may use local state in an App Store build.
        guard developerOverride == nil,
              !PasteminEdition.isAppStoreBuild || allowAppStoreSandbox else { return }
        let previousStart = appTrialStartedAt
        if let forced = PasteminEdition.forcedTrialStartedAt {
            // Private previews must not change the real trial date in preferences.
            appTrialStartedAt = forced
        } else if appTrialStartedAt == nil {
            if let stored = defaults.object(forKey: Self.appTrialStartedAtKey) as? Date {
                appTrialStartedAt = stored
            } else if startIfNeeded {
                appTrialStartedAt = now
                defaults.set(now, forKey: Self.appTrialStartedAtKey)
            }
        }
        if appTrialStartedAt != previousStart {
            NotificationCenter.default.post(name: Self.entitlementDidChange, object: self)
        }
        scheduleAppTrialExpiry(now: now)
    }

    // applyAppTrialStartDate(startedAt, [now]): Publish the signed production clock.
    private func applyAppTrialStartDate(_ startedAt: Date, now: Date = Date()) {
        if appTrialStartedAt != startedAt {
            appTrialStartedAt = startedAt
            NotificationCenter.default.post(name: Self.entitlementDidChange, object: self)
        }
        scheduleAppTrialExpiry(now: now)
    }

    // scheduleAppTrialExpiry([now]): Limit visible history as soon as the trial expires.
    private func scheduleAppTrialExpiry(now: Date = Date()) {
        appTrialTimer?.invalidate()
        appTrialTimer = nil
        guard let appTrialStartedAt,
              PasteminFreeAccessPolicy.isTrialActive(startedAt: appTrialStartedAt, now: now) else {
            return
        }
        let expiry = appTrialStartedAt.addingTimeInterval(PasteminFreeAccessPolicy.trialDuration)
        appTrialTimer = Timer.scheduledTimer(
            withTimeInterval: max(1, expiry.timeIntervalSince(now)),
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.objectWillChange.send()
                NotificationCenter.default.post(name: Self.entitlementDidChange, object: self)
            }
        }
    }

    private func apply(_ updated: PasteminEntitlement) {
        guard updated != entitlement else { return }
        entitlement = updated
        NotificationCenter.default.post(name: Self.entitlementDidChange, object: self)
    }

    private func scheduleRefresh() {
        entitlementTimer?.invalidate()
        entitlementTimer = nil
        guard entitlement.kind == .subscription else { return }
        let remaining = entitlement.expirationDate?.timeIntervalSinceNow ?? 60
        let delay = remaining > 0 ? max(1, min(60, remaining)) : 60
        entitlementTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshEntitlement() }
        }
    }

    private func subscriptionWillAutoRenew(for current: PasteminEntitlement) async -> Bool? {
        if yearly == nil { try? await loadProducts() }
        guard let statuses = try? await yearly?.subscription?.status else { return nil }
        for status in statuses {
            guard case .verified(let transaction) = status.transaction,
                  transaction.productID == PasteminProductID.yearly,
                  transaction.revocationDate == nil,
                  transaction.expirationDate == current.expirationDate,
                  (transaction.ownershipType == .familyShared) == current.isFamilyShared,
                  case .verified(let renewal) = status.renewalInfo else { continue }
            return renewal.willAutoRenew
        }
        return nil
    }

    private func summary(of transaction: StoreKit.Transaction) -> PasteminTransactionSummary {
        let introductory: Bool
        if #available(macOS 14.2, *) {
            introductory = transaction.offer?.type == .introductory
        } else {
            introductory = transaction.offerType == .introductory
        }
        return PasteminTransactionSummary(
            productID: transaction.productID,
            expirationDate: transaction.expirationDate,
            revocationDate: transaction.revocationDate,
            isFamilyShared: transaction.ownershipType == .familyShared,
            isIntroductoryOffer: introductory
        )
    }
}

@MainActor
final class PasteminPaywallController: NSWindowController, NSWindowDelegate {
    private static let panelWidth: CGFloat = 556

    private let store: PasteminStore
    private let state = PasteminPaywallState()
    private var onUnlock: (() -> Void)?

    init(store: PasteminStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pastemin Pro"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: PasteminPaywallView(
            store: store,
            state: state,
            close: { [weak self] in self?.window?.close() },
            unlocked: { [weak self] in
                guard let self else { return }
                self.window?.close()
                let action = self.onUnlock
                self.onUnlock = nil
                action?()
            },
            resize: { [weak self] height in self?.fitWindow(to: height) }
        ))
        window.contentView?.layoutSubtreeIfNeeded()
        if let height = window.contentView?.fittingSize.height, height > 0 {
            fitWindow(to: height, animate: false)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(onUnlock: (() -> Void)? = nil) {
        self.onUnlock = onUnlock
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // fitWindow(to, [animate = true]): Match the visible SwiftUI content while
    // keeping the panel's top edge fixed as its store state changes.
    private func fitWindow(to height: CGFloat, animate: Bool = true) {
        guard let window, height > 0 else { return }
        let size = NSSize(width: Self.panelWidth, height: ceil(height))
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        let current = window.frame
        guard abs(current.height - frame.height) >= 1 || abs(current.width - frame.width) >= 1 else { return }
        frame.origin = NSPoint(x: current.minX, y: current.maxY - frame.height)
        window.setFrame(frame, display: true, animate: animate && window.isVisible)
    }
}

@MainActor
private final class PasteminPaywallState: ObservableObject {
    @Published var isWorking = false
    @Published var storeError: String?
    @Published var message: String?
}

private struct PasteminPanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct PasteminPaywallView: View {
    @ObservedObject var store: PasteminStore
    @ObservedObject var state: PasteminPaywallState
    let close: () -> Void
    let unlocked: () -> Void
    let resize: (CGFloat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pastemin Pro")
                    .font(.system(size: 22, weight: .bold))
                Text(localized(
                    "paywall_description",
                    "Keep your clipboard history close, searchable, and private on your Mac."
                ))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                proFeature(
                    localized("wizard_trial_during_pastemin", "Keep and search your complete clipboard history."),
                    symbol: "doc.on.clipboard"
                )
                proFeature(
                    localized("privacy_local_history", "Clipboard history never leaves this Mac"),
                    symbol: "lock.shield"
                )
                proFeature(
                    localized("wizard_trial_plans_body", "Choose a yearly plan or lifetime access at any time."),
                    symbol: "creditcard"
                )
            }

            Text(localized(
                "wizard_trial_after_pastemin",
                "Pastemin keeps storing your history, but shows and searches only the 5 newest items."
            ))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                statusSection
                if state.isWorking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(localized("restoring_purchases", "Restoring…"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else if !store.isPro {
                    purchaseButtons
                }
                if let message = state.message {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }

            HStack {
                if !store.isPro {
                    Button(localized("restore_purchases", "Restore Purchases"), action: restore)
                        .buttonStyle(.link)
                        .disabled(state.isWorking)
                }
                Spacer()
                Button(localized(store.isPro ? "ok" : "close", store.isPro ? "OK" : "Close"), action: close)
                    .controlSize(.large)
                    .keyboardShortcut(store.isPro ? .defaultAction : .cancelAction)
            }
        }
        .padding(.init(top: 22, leading: 28, bottom: 24, trailing: 28))
        .frame(width: 556)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(key: PasteminPanelHeightKey.self, value: geometry.size.height)
            }
        )
        .onPreferenceChange(PasteminPanelHeightKey.self, perform: resize)
        .task { await load() }
    }

    @ViewBuilder private var statusSection: some View {
        if store.isPro || store.isAppTrialActive {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.isAppTrialActive
                     ? localized("wizard_trial_during_title", "Your first 30 days")
                     : "Pastemin Pro")
                    .font(.system(size: 13))
                Text(store.statusText())
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if store.isPro && store.canManageSubscription {
                Link(
                    localized("manage_subscription_ellipsis", "Manage Subscription…"),
                    destination: PasteminStore.manageSubscriptionsURL
                )
                    .font(.system(size: 12))
            }
        }
    }

    private func proFeature(_ title: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 13))
        }
    }

    @ViewBuilder private var purchaseButtons: some View {
        if let yearly = store.yearly {
            Button { purchase(yearly) } label: {
                Text(localized("yearly_subscription", "Yearly Subscription"))
                    .frame(maxWidth: .infinity)
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(state.isWorking)
            Text(localizedFormat("price_per_year", "%@ per year", yearly.displayPrice))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        if let lifetime = store.lifetime {
            Button { purchase(lifetime) } label: {
                Text(localizedFormat(
                    "lifetime_access_price",
                    "Lifetime Access — %@",
                    lifetime.displayPrice
                ))
                    .frame(maxWidth: .infinity)
            }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(state.isWorking)
        }
        if store.yearly == nil, store.lifetime == nil, let storeError = state.storeError {
            Text(storeError)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button(localized("try_again", "Try Again")) {
                Task { await load() }
            }
        }
        Text(localized(
            "yearly_plan_disclosure",
            "The yearly plan renews automatically unless canceled. Family Sharing is supported. Payment and renewal are managed by Apple."
        ))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
    }

    private func load() async {
        guard !store.isPro, store.yearly == nil, store.lifetime == nil else { return }
        state.isWorking = true
        state.storeError = nil
        state.message = nil
        defer { state.isWorking = false }
        do {
            try await store.loadProducts()
        } catch {
            state.storeError = error.localizedDescription
        }
    }

    private func purchase(_ product: Product) {
        guard !state.isWorking else { return }
        state.isWorking = true
        state.message = nil
        Task {
            defer { state.isWorking = false }
            do {
                switch try await store.purchase(product) {
                case .unlocked: unlocked()
                case .pending:
                    state.message = localized(
                        "purchase_waiting_for_approval",
                        "The purchase is waiting for approval."
                    )
                case .cancelled: break
                }
            } catch {
                state.message = error.localizedDescription
            }
        }
    }

    private func restore() {
        guard !state.isWorking else { return }
        state.isWorking = true
        state.message = nil
        Task {
            defer { state.isWorking = false }
            do {
                if try await store.restore() {
                    unlocked()
                } else {
                    state.message = localized(
                        "no_active_purchase",
                        "No active Pastemin purchase was found."
                    )
                }
            } catch {
                state.message = error.localizedDescription
            }
        }
    }
}
