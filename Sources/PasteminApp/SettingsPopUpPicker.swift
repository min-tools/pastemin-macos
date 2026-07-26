import AppKit
import SwiftUI

struct SettingsPopUpPicker<Value: Equatable>: NSViewRepresentable {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    let accessibilityLabel: String
    let activationNotification: Notification.Name

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.setAccessibilityLabel(accessibilityLabel)
        context.coordinator.button = button
        update(button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        update(button, coordinator: context.coordinator)
    }

    private func update(_ button: NSPopUpButton, coordinator: Coordinator) {
        let titles = options.map(title)
        if button.itemArray.map(\.title) != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        if let index = options.firstIndex(of: selection), button.indexOfSelectedItem != index {
            button.selectItem(at: index)
        }
    }

    final class Coordinator: NSObject {
        var parent: SettingsPopUpPicker
        weak var button: NSPopUpButton?

        init(parent: SettingsPopUpPicker) {
            self.parent = parent
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(openMenu),
                name: parent.activationNotification,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard parent.options.indices.contains(index) else { return }
            parent.selection = parent.options[index]
        }

        @objc private func openMenu() {
            button?.performClick(nil)
        }
    }
}
