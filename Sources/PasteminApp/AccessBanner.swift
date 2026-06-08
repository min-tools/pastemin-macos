import SwiftUI

@MainActor
final class AccessLimitedBannerState: ObservableObject {
    @Published var isRestoring = false
    @Published var restoreMessage: String?
}

/// Keeps expired or missing access recoverable without blocking the five-item clipboard view.
struct AccessLimitedBanner: View {
    @ObservedObject var state: AccessLimitedBannerState
    let showPurchases: () -> Void
    let restorePurchases: () async -> String?

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(localized(
                    "trial_expired_title",
                    "Trial ended"
                ))
                    .font(.system(size: 12, weight: .semibold))
                Text(state.restoreMessage ?? localized(
                    "trial_expired_purchase_message",
                    "Pastemin now shows your 5 most recent items."
                ))
                    .font(.system(size: 11))
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Button(
                state.isRestoring
                    ? localized("restoring_purchases", "Restoring…")
                    : localized("restore_purchases", "Restore Purchases"),
                action: restore
            )
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.isRestoring)
            Button(
                localized("purchase_or_subscribe", "Purchase"),
                action: showPurchases
            )
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.isRestoring)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .frame(minHeight: 58)
        .background(Color(nsColor: .systemOrange).opacity(0.16))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(nsColor: .systemOrange).opacity(0.48)).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func restore() {
        guard !state.isRestoring else { return }
        state.isRestoring = true
        state.restoreMessage = nil
        Task {
            state.restoreMessage = await restorePurchases()
            state.isRestoring = false
        }
    }
}
