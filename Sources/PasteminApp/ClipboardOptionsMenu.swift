import AppKit
import SwiftUI

extension Notification.Name {
    static let activateClipboardShortcutRecorder = Notification.Name(
        "tools.min.pastemin.activateShortcutRecorder"
    )
    static let activateClipboardRetentionPicker = Notification.Name(
        "tools.min.pastemin.activateRetentionPicker"
    )
}

/// One metric system for every row so titles, dividers and controls share the same edges.
private enum OptionsMetrics {
    /// Distance from the highlight edge to titles, dividers and the trailing control edge.
    static let inset: CGFloat = 10
    /// Even gap between the dropdown's edge and the row highlights on every side.
    static let edgePadding: CGFloat = 6
    static let width: CGFloat = 360
    static let actionRowHeight: CGFloat = 28
    static let controlRowHeight: CGFloat = 38
    static let detailRowHeight: CGFloat = 48
    static let controlWidth: CGFloat = 118
    static let controlHeight: CGFloat = 28
    static let highlightRadius: CGFloat = 6
}

struct ClipboardOptionsMenuView: View {
    @ObservedObject var preferences: ClipboardPreferences
    @ObservedObject var store: ClipboardHistoryStore
    @ObservedObject var selection: OptionsSelectionModel
    let recordingChanged: (Bool) -> Void
    let showPrivacyPolicy: () -> Void
    let showAbout: () -> Void
    let revealStorage: () -> Void
    let clearCurrentClipboard: () -> Void
    let clearHistory: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            OptionsActionRow(
                row: .clearCurrent,
                title: localized("clear_current_clipboard", "Clear Current Clipboard"),
                selection: selection,
                action: dismissThen(clearCurrentClipboard)
            )
            OptionsActionRow(
                row: .clearHistory,
                title: localized("clear_history_ellipsis", "Clear History…"),
                selection: selection,
                action: dismissThen(clearHistory)
            )

            OptionsDivider()

            OptionsControlRow(
                row: .retention,
                title: localized("keep_copied_items", "Keep copied items"),
                selection: selection
            ) {
                SettingsPopUpPicker(
                    selection: $preferences.retention,
                    options: RetentionPeriod.allCases,
                    title: { $0.title },
                    accessibilityLabel: localized("keep_copied_items", "Keep copied items"),
                    activationNotification: .activateClipboardRetentionPicker
                )
                .frame(width: OptionsMetrics.controlWidth, height: OptionsMetrics.controlHeight)
            }

            OptionsControlRow(
                row: .menuBar,
                title: localized("show_in_menu_bar", "Show in menu bar"),
                selection: selection
            ) {
                Toggle("", isOn: $preferences.showInMenuBar)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            OptionsControlRow(
                row: .automaticPaste,
                title: localized("paste_automatically", "Paste automatically"),
                detail: automaticPasteDetail,
                selection: selection
            ) {
                Toggle("", isOn: automaticPasteBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            OptionsDivider()

            OptionsControlRow(
                row: .shortcut,
                title: localized("show_pastemin", "Show Pastemin"),
                selection: selection
            ) {
                ShortcutRecorder(
                    shortcut: $preferences.shortcut,
                    recordingChanged: recordingChanged
                )
                .frame(width: OptionsMetrics.controlWidth, height: OptionsMetrics.controlHeight)
            }

            if let error = preferences.hotKeyError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, OptionsMetrics.inset)
                    .padding(.bottom, 8)
            }

            OptionsControlRow(
                row: .storage,
                title: localized("local_storage", "Local storage"),
                detail: localStorageDetail,
                selection: selection
            ) {
                Button(localized("show_in_finder", "Show in Finder"), action: dismissThen(revealStorage))
            }

            OptionsDivider()

            privacyFooter
        }
        .padding(OptionsMetrics.edgePadding)
        .frame(width: OptionsMetrics.width)
        // Stay transparent so the dropdown's glass material shows through the content.
        .background(Color.clear)
        .onAppear(perform: configureKeyboard)
        .task(id: store.items.count) { await store.refreshStorageByteCount() }
        .onAppear { preferences.refreshAutomaticPasteAuthorization() }
    }

    private var privacyFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
                    .padding(.top, 1)
                Text(localized("privacy_local_history", "Clipboard history never leaves this Mac"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                OptionsFooterButton(
                    row: .about,
                    title: localized("about", "About"),
                    selection: selection,
                    action: dismissThen(showAbout)
                )
                Spacer(minLength: 8)
                OptionsFooterButton(
                    row: .privacy,
                    title: localized("privacy_policy", "Privacy Policy"),
                    selection: selection,
                    action: dismissThen(showPrivacyPolicy)
                )
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, OptionsMetrics.inset)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    /// Register the rows in display order and what Return, Space, Left and Right do on each.
    private func configureKeyboard() {
        var rows: [OptionsRow] = [.clearCurrent, .clearHistory, .retention, .menuBar]
        rows.append(.automaticPaste)
        rows.append(.shortcut)
        rows += [.storage, .about, .privacy]
        selection.rows = rows
        selection.activate = { row in
            switch row {
            case .clearCurrent: dismissThen(clearCurrentClipboard)()
            case .clearHistory: dismissThen(clearHistory)()
            case .retention:
                NotificationCenter.default.post(name: .activateClipboardRetentionPicker, object: nil)
            case .menuBar: preferences.showInMenuBar.toggle()
            case .automaticPaste: toggleAutomaticPaste()
            case .shortcut:
                NotificationCenter.default.post(name: .activateClipboardShortcutRecorder, object: nil)
            case .storage: dismissThen(revealStorage)()
            case .about: dismissThen(showAbout)()
            case .privacy: dismissThen(showPrivacyPolicy)()
            }
        }
        selection.adjust = { row, delta in
            switch row {
            case .retention:
                // Left and Right step through the retention periods without opening the pop-up.
                let periods = RetentionPeriod.allCases
                guard let index = periods.firstIndex(of: preferences.retention) else { return }
                let target = min(max(index + delta, 0), periods.count - 1)
                preferences.retention = periods[target]
            case .menuBar: preferences.showInMenuBar = delta > 0
            case .automaticPaste: setAutomaticPaste(delta > 0)
            default: break
            }
        }
    }

    private func dismissThen(_ action: @escaping () -> Void) -> () -> Void {
        {
            dismiss()
            DispatchQueue.main.async(execute: action)
        }
    }

    private func toggleAutomaticPaste() {
        setAutomaticPaste(!preferences.pasteAutomatically)
    }

    private func setAutomaticPaste(_ enabled: Bool) {
        preferences.pasteAutomatically = enabled
    }

    private var automaticPasteBinding: Binding<Bool> {
        Binding(
            get: { preferences.pasteAutomatically },
            set: { setAutomaticPaste($0) }
        )
    }

    private var automaticPasteDetail: String? {
        guard preferences.pasteAutomatically, !preferences.automaticPasteAuthorized else {
            return nil
        }
        return localized(
            "automatic_paste_access_needed",
            "macOS will ask for permission on first use"
        )
    }

    private var localStorageDetail: String {
        let count = store.items.count == 1
            ? localizedFormat("stored_item_count_one", "%lld stored item", Int64(store.items.count))
            : localizedFormat("stored_item_count_many", "%lld stored items", Int64(store.items.count))
        guard let storageByteCount = store.storageByteCount else { return count }
        let size = ByteCountFormatter.string(fromByteCount: storageByteCount, countStyle: .file)
        return localizedFormat("stored_items_with_size", "%@, %@", count, size)
    }
}

/// A compact footer link that participates in the dropdown's shared mouse and keyboard focus.
private struct OptionsFooterButton: View {
    let row: OptionsRow
    let title: String
    @ObservedObject var selection: OptionsSelectionModel
    let action: () -> Void

    private var isSelected: Bool { selection.selection == row }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(
                    isSelected ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: OptionsMetrics.highlightRadius)
                )
                .contentShape(RoundedRectangle(cornerRadius: OptionsMetrics.highlightRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovering in selection.hover(row, hovering) }
    }
}
