import AppKit

private final class PrivacyPolicyPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { close() }
}

final class PrivacyPolicyController: NSObject, NSTextViewDelegate {
    static let shared = PrivacyPolicyController()
    private var window: NSPanel?
    private var textView: NSTextView!

    func show() {
        if window == nil { buildWindow() }
        textView.textStorage?.setAttributedString(Self.policyText(
            at: Self.bundledPolicyURL
        ))
        textView.scrollToBeginningOfDocument(nil)
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let panel = PrivacyPolicyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = localized("privacy_policy", "Privacy Policy")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentMinSize = NSSize(width: 420, height: 320)

        let content = NSView(frame: panel.contentView?.bounds ?? .zero)
        panel.contentView = content

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 500))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 28, height: 24)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.delegate = self
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        textView.setAccessibilityLabel(localized("privacy_policy", "Privacy Policy"))
        scroll.documentView = textView

        let close = NSButton(
            title: localized("ok", "OK"),
            target: self,
            action: #selector(dismiss(_:))
        )
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"

        for view in [scroll, close] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -14),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            close.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])
        window = panel
    }

    private static var bundledPolicyURL: URL? {
#if SWIFT_PACKAGE
        Bundle.module.url(forResource: "PRIVACY", withExtension: "md")
#else
        Bundle.main.url(forResource: "PRIVACY", withExtension: "md")
#endif
    }

    static func policyText(at url: URL?) -> NSAttributedString {
        do {
            guard let url else { throw CocoaError(.fileNoSuchFile) }
            let markdown = try String(contentsOf: url, encoding: .utf8)
            guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return attributedPolicy(markdown)
        } catch {
            let title = localized("privacy_policy", "Privacy Policy")
            return attributedPolicy(
                "# \(title)\n\n\(error.localizedDescription)\n\n[\(title)](https://min.tools/pastemin/privacy/)"
            )
        }
    }

    static func attributedPolicy(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        for block in normalized.components(separatedBy: "\n\n") {
            var text = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let heading = text.prefix { $0 == "#" }.count
            let isHeading = (1...6).contains(heading) && text.dropFirst(heading).first == " "
            if isHeading { text = String(text.dropFirst(heading + 1)) }
            text = text.replacingOccurrences(of: "\n", with: " ")

            let size: CGFloat = isHeading ? (heading == 1 ? 24 : heading == 2 ? 18 : 15) : 14
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.paragraphSpacing = isHeading ? 12 : 18
            paragraph.paragraphSpacingBefore = isHeading && result.length > 0 ? 8 : 0
            let parsed = (try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(text)

            for run in parsed.runs {
                let intent = run.inlinePresentationIntent ?? []
                let weight: NSFont.Weight = isHeading || intent.contains(.stronglyEmphasized)
                    ? .semibold : .regular
                var font = intent.contains(.code)
                    ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                    : NSFont.systemFont(ofSize: size, weight: weight)
                if intent.contains(.emphasized) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                }
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph
                ]
                if let link = run.link { attributes[.link] = link }
                result.append(NSAttributedString(
                    string: String(parsed[run.range].characters),
                    attributes: attributes
                ))
            }
            result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
        }

        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(location: 0, length: result.length)
        for match in detector?.matches(in: result.string, range: range) ?? [] {
            if let url = match.url,
               result.attribute(.link, at: match.range.location, effectiveRange: nil) == nil {
                result.addAttribute(.link, value: url, range: match.range)
            }
        }
        return result
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        if let url, ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        return true
    }

    @objc private func dismiss(_ sender: Any?) { window?.close() }
}
