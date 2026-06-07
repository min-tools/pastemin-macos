import SwiftUI

@MainActor
final class AccessLimitedBannerState: ObservableObject {
    @Published var isRestoring = false
    @Published var restoreMessage: String?
}
