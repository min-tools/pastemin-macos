import AppKit

private final class PrivacyPolicyPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { close() }
}
