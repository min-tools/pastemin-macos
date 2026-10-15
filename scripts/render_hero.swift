import Accelerate
import AppKit
import SwiftUI

// Compiled with every app source except PasteminMain.swift, which owns the app's entry point.

/// Renders Pastemin's marketing images without launching the app: the clipboard panel with a
/// fictional history, drawn offscreen at 2x and composed as a glass panel over an original
/// wallpaper, the way the floating panel looks on macOS 26 and later.
///
/// Usage: render-hero <scratch directory> [--readme <directory>] [--profile <directory>]
///        [--app-store <directory>]
@main
enum RenderHero {
    // The panel's size and corner radius match ClipboardPanel and ClipboardPanelSurface.
    static let panelSize = NSSize(width: 900, height: 590)
    static let panelCornerRadius: CGFloat = 27
    static let scale: CGFloat = 2

    /// One captured state of the panel: a search query and the item shown in the preview pane.
    struct Scene {
        let query: String
        let selectedTitle: String
    }

    /// A Mac App Store screenshot: one scene in one appearance, with its headline and subtitle.
    struct Screenshot {
        let file: String
        let scene: Scene
        let dark: Bool
        let headline: String
        let subtitle: String
    }

    static let overview = Scene(query: "", selectedTitle: "Project brief")
    static let search = Scene(query: "release", selectedTitle: "Release checklist")
    static let imagePreview = Scene(query: "", selectedTitle: localized("image", "Image"))

    // The App Store set, in listing order: what the app is, search, images, and privacy.
    static let screenshots = [
        Screenshot(
            file: "pastemin-1-overview-light.png", scene: overview, dark: false,
            headline: "Your clipboard, ready when you need it.",
            subtitle: "Everything you copy, searchable in one place."
        ),
        Screenshot(
            file: "pastemin-2-search-dark.png", scene: search, dark: true,
            headline: "Find an earlier copy in seconds.",
            subtitle: "Search the complete text of your clipboard history."
        ),
        Screenshot(
            file: "pastemin-3-image-light.png", scene: imagePreview, dark: false,
            headline: "Text and images together.",
            subtitle: "Preview a copied image without opening another app."
        ),
        Screenshot(
            file: "pastemin-4-private-dark.png", scene: overview, dark: true,
            headline: "Your history stays on this Mac.",
            subtitle: "No account, no analytics, and no server."
        ),
    ]

    // main(): Parse the output directories, stage the fixture, and write every requested image.
    @MainActor static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        var arguments = Array(CommandLine.arguments.dropFirst())
        let usage = "usage: render-hero <scratch directory> [--readme <dir>] [--profile <dir>] [--app-store <dir>]"
        guard !arguments.isEmpty else {
            print(usage)
            exit(2)
        }
        let scratch = URL(fileURLWithPath: arguments.removeFirst(), isDirectory: true)
        var readme: URL?
        var profile: URL?
        var appStore: URL?
        while !arguments.isEmpty {
            let flag = arguments.removeFirst()
            guard !arguments.isEmpty else {
                print(usage)
                exit(2)
            }
            let directory = URL(fileURLWithPath: arguments.removeFirst(), isDirectory: true)
            switch flag {
            case "--readme": readme = directory
            case "--profile": profile = directory
            case "--app-store": appStore = directory
            default:
                print(usage)
                exit(2)
            }
        }
        NSApplication.shared.setActivationPolicy(.prohibited)

        // This process has its own defaults domain; anything the views store is removed at the end.
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }

        // The fictional history lives in a throwaway store under the scratch directory.
        let fixture: Fixture
        do {
            fixture = try Fixture.stage(in: scratch)
        } catch {
            print("could not stage the fixture: \(error)")
            exit(1)
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let renderer = PanelRenderer(fixture: fixture)
        for directory in [readme, profile, appStore].compactMap({ $0 }) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // README heroes and their 900-pixel GitHub profile copies show the overview scene.
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            guard readme != nil || profile != nil else { break }
            let canvas = renderer.readmeImage(scene: overview, dark: dark)
            if let readme {
                write(renderer.png(canvas), to: readme.appendingPathComponent("hero-\(suffix).png"))
            }
            if let profile {
                let small = renderer.png(canvas, scaledToWidth: 900)
                write(small, to: profile.appendingPathComponent("pastemin-hero-\(suffix).png"))
            }
        }

        // The App Store set at 2880x1800, one of the sizes App Store Connect accepts for Mac.
        if let appStore {
            for screenshot in screenshots {
                let canvas = renderer.appStoreImage(screenshot)
                write(renderer.png(canvas), to: appStore.appendingPathComponent(screenshot.file))
            }
        }
    }

    // write(data, to url): Save one image and stop on failure, so a half-finished set is noticed.
    static func write(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: [])
            print("wrote \(url.path)")
        } catch {
            print("could not write \(url.lastPathComponent): \(error)")
            exit(1)
        }
    }
}

/// The fictional clipboard history, staged as a real store under the scratch directory.
@MainActor
struct Fixture {
    let root: URL
    let store: ClipboardHistoryStore
    let model: ClipboardViewModel
    let preferences: ClipboardPreferences
    let bannerState: AccessLimitedBannerState

    /// One history item: text or an image, its source app, and its time today.
    struct Item {
        let text: String?
        let image: Data?
        let source: String
        let bundle: String
        let hour: Int
        let minute: Int
        let second: Int
    }

    // Newest first, as the panel lists them. Searching "release" matches two of these.
    static let items = [
        Item(
            text: """
            Project brief

            Build a lightweight macOS clipboard history app that helps users quickly find and \
            reuse everything they copy. Keep the experience native, fast, and privacy-focused, \
            with a clean interface and powerful search.
            """,
            image: nil, source: "Notes", bundle: "com.apple.Notes", hour: 14, minute: 32, second: 17
        ),
        Item(
            text: """
            Meeting notes

            Thursday sync: the launch moves to the 24th. Mira owns the notes, Tom takes the \
            pricing page, and we go through the beta feedback next week.
            """,
            image: nil, source: "Mail", bundle: "com.apple.mail", hour: 14, minute: 28, second: 5
        ),
        Item(
            text: """
            Release checklist

            Tag the build
            Update the screenshots
            Check every public link
            Submit for review
            """,
            image: nil, source: "Notes", bundle: "com.apple.Notes", hour: 14, minute: 20, second: 41
        ),
        Item(
            text: "https://min.tools", image: nil,
            source: "Safari", bundle: "com.apple.Safari", hour: 14, minute: 18, second: 22
        ),
        Item(
            text: nil, image: FixtureArt.designReference(),
            source: "Preview", bundle: "com.apple.Preview", hour: 14, minute: 12, second: 9
        ),
        Item(
            text: "Running ten minutes late, start without me", image: nil,
            source: "Messages", bundle: "com.apple.MobileSMS", hour: 13, minute: 51, second: 30
        ),
        Item(
            text: "git tag -a 26.10 -m \"October release\"", image: nil,
            source: "Terminal", bundle: "com.apple.Terminal", hour: 13, minute: 47, second: 12
        ),
    ]

    // The source apps' icon files, read directly because a sandbox has no icon service.
    static let iconFiles = [
        "com.apple.Notes": "/System/Applications/Notes.app/Contents/Resources/AppIcon.icns",
        "com.apple.mail": "/System/Applications/Mail.app/Contents/Resources/ApplicationIcon.icns",
        "com.apple.Safari": "/Applications/Safari.app/Contents/Resources/AppIconUpdated.icns",
        "com.apple.Preview": "/System/Applications/Preview.app/Contents/Resources/AppIcon.icns",
        "com.apple.MobileSMS": "/System/Applications/Messages.app/Contents/Resources/AppIcon.icns",
        "com.apple.Terminal": "/System/Applications/Utilities/Terminal.app/Contents/Resources/Terminal.icns",
    ]

    // stage(in scratch): Write the history index and image payload, then open the store on it.
    static func stage(in scratch: URL) throws -> Fixture {
        let root = scratch.appendingPathComponent("history", isDirectory: true)
        let images = root.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)

        // Every item is timestamped today, so rows show a time and the footer shows the full date.
        let calendar = Calendar.current
        let today = Date()
        var records: [ClipboardRecord] = []
        for (index, item) in items.enumerated() {
            let id = UUID()
            let createdAt = calendar.date(
                bySettingHour: item.hour, minute: item.minute, second: item.second, of: today
            ) ?? today
            if let image = item.image {
                let filename = "\(id.uuidString).png"
                try image.write(to: images.appendingPathComponent(filename), options: [])
                records.append(ClipboardRecord(
                    id: id, createdAt: createdAt, kind: .image, text: nil, textFilename: nil,
                    imageFilename: filename, sourceAppName: item.source,
                    sourceBundleIdentifier: item.bundle, byteCount: image.count,
                    signature: "fixture-\(index)"
                ))
            } else if let text = item.text {
                records.append(ClipboardRecord(
                    id: id, createdAt: createdAt, kind: .text, text: text, textFilename: nil,
                    imageFilename: nil, sourceAppName: item.source,
                    sourceBundleIdentifier: item.bundle, byteCount: Data(text.utf8).count,
                    signature: "fixture-\(index)"
                ))
            }
        }
        try JSONEncoder().encode(records).write(to: root.appendingPathComponent("history.json"), options: [])

        let store = try ClipboardHistoryStore(rootURL: root, retention: .forever)
        guard store.items.count == items.count else {
            throw NSError(domain: "RenderHero", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "the store loaded \(store.items.count) of \(items.count) items",
            ])
        }
        // The icon service answers with placeholders in a sandbox, so load the icon files directly.
        for (bundle, path) in iconFiles {
            if let icon = NSImage(contentsOfFile: path) {
                store.registerSourceIcon(icon, forBundleIdentifier: bundle)
            } else {
                print("no icon file for \(bundle); its rows show a generic symbol")
            }
        }
        return Fixture(
            root: root, store: store, model: ClipboardViewModel(store: store),
            preferences: ClipboardPreferences(), bannerState: AccessLimitedBannerState()
        )
    }

    // view: The panel's real content view over this fixture; its menu actions do nothing here.
    var view: ClipboardHistoryView {
        ClipboardHistoryView(
            model: model, store: store, preferences: preferences, proStore: PasteminStore.shared,
            accessBannerState: bannerState, recordingChanged: { _ in }, showPurchases: {},
            restorePurchases: { nil }, showPrivacyPolicy: {}, showAbout: {}, revealStorage: {},
            clearCurrentClipboard: {}, clearHistory: {}
        )
    }
}

/// Draws the fictional "design reference" image a user might have copied from Preview.
enum FixtureArt {
    // designReference(): A 1600x1000 moodboard, three overlapping discs and a palette strip, as PNG.
    static func designReference() -> Data {
        let size = NSSize(width: 1600, height: 1000)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("no bitmap") }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        let cg = context.cgContext

        // A warm paper background with a faint diagonal gradient.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let paper = CGGradient(
            colorsSpace: space,
            colors: [
                CGColor(srgbRed: 0.98, green: 0.96, blue: 0.93, alpha: 1),
                CGColor(srgbRed: 0.94, green: 0.92, blue: 0.90, alpha: 1),
            ] as CFArray,
            locations: [0, 1]
        )!
        cg.drawLinearGradient(paper, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])

        // Three translucent discs whose overlaps mix into new colors.
        let discs: [(CGPoint, CGFloat, CGColor)] = [
            (CGPoint(x: 560, y: 560), 300, CGColor(srgbRed: 0.98, green: 0.45, blue: 0.40, alpha: 0.88)),
            (CGPoint(x: 880, y: 600), 300, CGColor(srgbRed: 0.97, green: 0.73, blue: 0.22, alpha: 0.88)),
            (CGPoint(x: 720, y: 330), 300, CGColor(srgbRed: 0.18, green: 0.70, blue: 0.64, alpha: 0.88)),
        ]
        for (center, radius, color) in discs {
            cg.setFillColor(color)
            cg.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }

        // A palette strip in the lower right, like swatches pinned beside the composition.
        let swatches = [
            CGColor(srgbRed: 0.98, green: 0.45, blue: 0.40, alpha: 1),
            CGColor(srgbRed: 0.97, green: 0.73, blue: 0.22, alpha: 1),
            CGColor(srgbRed: 0.18, green: 0.70, blue: 0.64, alpha: 1),
            CGColor(srgbRed: 0.16, green: 0.17, blue: 0.24, alpha: 1),
            CGColor(srgbRed: 0.98, green: 0.96, blue: 0.93, alpha: 1),
        ]
        for (index, color) in swatches.enumerated() {
            let rect = CGRect(x: 1160 + CGFloat(index) * 76, y: 80, width: 64, height: 64)
            cg.setFillColor(color)
            cg.addPath(CGPath(roundedRect: rect, cornerWidth: 14, cornerHeight: 14, transform: nil))
            cg.fillPath()
            cg.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.10))
            cg.setLineWidth(2)
            cg.addPath(CGPath(roundedRect: rect, cornerWidth: 14, cornerHeight: 14, transform: nil))
            cg.strokePath()
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("no png") }
        return data
    }
}

/// Captures the panel content offscreen and composes the marketing images around it.
@MainActor
final class PanelRenderer {
    let fixture: Fixture

    init(fixture: Fixture) {
        self.fixture = fixture
    }

    // MARK: Compositions

    // readmeImage(scene, dark): The panel on a rounded wallpaper card with a transparent margin,
    // 1040x700 points, for the README's light and dark variants.
    func readmeImage(scene: RenderHero.Scene, dark: Bool) -> NSBitmapImageRep {
        let canvasSize = NSSize(width: 1040, height: 700)
        let panelOrigin = NSPoint(x: 70, y: 55)
        let capture = capture(scene: scene, dark: dark)
        let canvas = Self.bitmap(size: canvasSize)
        Self.draw(into: canvas) { cg in
            // The card clips the wallpaper and the panel shadow alike.
            let card = CGPath(
                roundedRect: CGRect(origin: .zero, size: canvasSize),
                cornerWidth: 16, cornerHeight: 16, transform: nil
            )
            cg.addPath(card)
            cg.clip()
            self.drawWallpaper(in: cg, size: canvasSize, dark: dark)
            self.drawPanel(in: cg, canvasSize: canvasSize, origin: panelOrigin, capture: capture, dark: dark)
        }
        return canvas
    }

    // appStoreImage(screenshot): A full-bleed 1440x900 point canvas with the headline above the panel.
    func appStoreImage(_ screenshot: RenderHero.Screenshot) -> NSBitmapImageRep {
        let canvasSize = NSSize(width: 1440, height: 900)
        let panelOrigin = NSPoint(x: (canvasSize.width - RenderHero.panelSize.width) / 2, y: 104)
        let capture = capture(scene: screenshot.scene, dark: screenshot.dark)
        let canvas = Self.bitmap(size: canvasSize)
        Self.draw(into: canvas) { cg in
            self.drawWallpaper(in: cg, size: canvasSize, dark: screenshot.dark)
            self.drawCaption(
                headline: screenshot.headline, subtitle: screenshot.subtitle,
                canvasSize: canvasSize, dark: screenshot.dark
            )
            self.drawPanel(in: cg, canvasSize: canvasSize, origin: panelOrigin, capture: capture, dark: screenshot.dark)
        }
        return canvas
    }

    // png(canvas, [scaledToWidth]): Encode a canvas, optionally resampled to a pixel width.
    func png(_ canvas: NSBitmapImageRep, scaledToWidth width: CGFloat? = nil) -> Data {
        var rep = canvas
        if let width, let source = canvas.cgImage {
            let factor = width / CGFloat(source.width)
            let size = NSSize(width: width.rounded(), height: (CGFloat(source.height) * factor).rounded())
            let small = Self.bitmap(size: size, scale: 1)
            Self.draw(into: small) { cg in
                cg.interpolationQuality = .high
                cg.draw(source, in: CGRect(origin: .zero, size: size))
            }
            rep = small
        }
        guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
        return data
    }

    // MARK: Capturing the panel

    /// The panel content with a transparent background, plus the caret's frame in panel points.
    struct Capture {
        let content: NSBitmapImageRep
        let caret: NSRect?
    }

    // capture(scene, dark): Apply the scene to the model, host the real view in an offscreen
    // transparent window, and draw it into a 2x bitmap.
    func capture(scene: RenderHero.Scene, dark: Bool) -> Capture {
        apply(scene)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: RenderHero.panelSize),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        // The window is closed after capture while this function still holds it.
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: fixture.view)
        host.frame = NSRect(origin: .zero, size: RenderHero.panelSize)
        window.contentView = host
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))

        // The search field shows the typed query before the capture, whatever SwiftUI has synced.
        let field = searchField(in: host)
        if let field, field.string != scene.query {
            field.string = scene.query
            field.needsDisplay = true
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        }
        let content = Self.bitmap(size: RenderHero.panelSize)
        host.cacheDisplay(in: host.bounds, to: content)
        let caret = field.map { caretRect(of: $0, in: host) }
        window.close()
        return Capture(content: content, caret: caret)
    }

    // apply(scene): Reset the search, run the scene's query to completion, and select its item.
    private func apply(_ scene: RenderHero.Scene) {
        let model = fixture.model
        model.resetSearch()
        if !scene.query.isEmpty {
            model.updateQuery(scene.query)
            // The search runs on an actor after a short debounce; wait for the narrowed list.
            let deadline = Date(timeIntervalSinceNow: 3)
            while model.filteredItems.count == fixture.store.items.count, Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
            guard model.filteredItems.count < fixture.store.items.count else {
                print("the search for \(scene.query) did not narrow the history")
                exit(1)
            }
        }
        guard let record = model.filteredItems.first(where: { $0.title == scene.selectedTitle }) else {
            print("no history item titled \(scene.selectedTitle)")
            exit(1)
        }
        model.select(record.id)
    }

    // searchField(in view): The panel's search text view, found by its identifier.
    private func searchField(in view: NSView) -> NSTextView? {
        if let field = view as? NSTextView, field.identifier?.rawValue == "PasteminSearchField" {
            return field
        }
        for subview in view.subviews {
            if let field = searchField(in: subview) { return field }
        }
        return nil
    }

    // caretRect(of field, in host): Where the insertion point sits after the typed text, in
    // bottom-origin panel coordinates. The offscreen window is never key, so AppKit draws no
    // caret of its own.
    private func caretRect(of field: NSTextView, in host: NSView) -> NSRect {
        let font = field.font ?? NSFont.systemFont(ofSize: 26)
        let typed = (field.string as NSString).size(withAttributes: [.font: font]).width
        let origin = field.textContainerOrigin
        let height = ceil(font.ascender - font.descender)
        let rect = field.convert(NSRect(x: origin.x + typed, y: origin.y, width: 1, height: height), to: host)
        // The hosting view is flipped; the captured bitmap is not.
        guard host.isFlipped else { return rect }
        return NSRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: Drawing

    // drawPanel(in cg, wallpaper, origin, capture, dark): The glass panel: a soft shadow, the
    // wallpaper blurred and tinted behind the content, the caret, and a lit rim.
    private func drawPanel(in cg: CGContext, canvasSize: NSSize, origin: NSPoint, capture: Capture, dark: Bool) {
        let rect = CGRect(origin: origin, size: RenderHero.panelSize)
        let shape = Self.continuousRoundedRect(rect, radius: RenderHero.panelCornerRadius)

        // A floating panel's shadow: large, soft, and below the panel.
        cg.saveGState()
        cg.setShadow(
            offset: CGSize(width: 0, height: -24), blur: 64,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: dark ? 0.55 : 0.30)
        )
        cg.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        cg.addPath(shape)
        cg.fillPath()
        cg.restoreGState()

        // Liquid Glass: the backdrop blurred and saturated, then a tint that keeps text legible.
        cg.saveGState()
        cg.addPath(shape)
        cg.clip()
        cg.interpolationQuality = .high
        cg.draw(blurredBackdrop(canvasSize: canvasSize, under: rect, dark: dark), in: rect)
        cg.setFillColor(dark
            ? CGColor(srgbRed: 0.23, green: 0.23, blue: 0.24, alpha: 0.58)
            : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.80))
        cg.fill(rect)
        // Core Graphics composites source-over; NSBitmapImageRep.draw would copy its transparency.
        guard let content = capture.content.cgImage else { fatalError("no content image") }
        cg.draw(content, in: rect)
        if let caret = capture.caret {
            cg.setFillColor(dark ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1))
            cg.fill(caret.offsetBy(dx: origin.x, dy: origin.y))
        }
        // The rim: a light inner edge, brighter at the top, inside a dark hairline.
        cg.addPath(shape)
        cg.setLineWidth(2)
        cg.replacePathWithStrokedPath()
        cg.clip()
        let rim = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            colors: [
                CGColor(gray: 1, alpha: dark ? 0.34 : 0.95),
                CGColor(gray: 1, alpha: dark ? 0.10 : 0.45),
            ] as CFArray,
            locations: [0, 1]
        )!
        cg.drawLinearGradient(rim, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        cg.restoreGState()

        cg.saveGState()
        cg.addPath(shape)
        cg.setLineWidth(0.5)
        cg.setStrokeColor(CGColor(gray: 0, alpha: dark ? 0.45 : 0.16))
        cg.strokePath()
        cg.restoreGState()
    }

    // blurredBackdrop(canvasSize, under rect, dark): The wallpaper as seen through the glass. A
    // 1x copy is blurred with three box passes, close to a 26-point Gaussian, then saturated and
    // cropped to the panel. Core Image cannot render offscreen in a sandbox, so this uses vImage.
    private func blurredBackdrop(canvasSize: NSSize, under rect: CGRect, dark: Bool) -> CGImage {
        let source = Self.bitmap(size: canvasSize, scale: 1)
        Self.draw(into: source) { cg in self.drawWallpaper(in: cg, size: canvasSize, dark: dark) }
        let target = Self.bitmap(size: canvasSize, scale: 1)
        guard let sourceData = source.bitmapData, let targetData = target.bitmapData else { fatalError("no bitmap data") }
        var a = vImage_Buffer(
            data: sourceData, height: vImagePixelCount(source.pixelsHigh),
            width: vImagePixelCount(source.pixelsWide), rowBytes: source.bytesPerRow
        )
        var b = vImage_Buffer(
            data: targetData, height: vImagePixelCount(target.pixelsHigh),
            width: vImagePixelCount(target.pixelsWide), rowBytes: target.bytesPerRow
        )
        // Three passes of a 53-pixel box, alternating buffers, end in the target.
        let kernel: UInt32 = 53
        for pass in 0..<3 {
            let error = pass % 2 == 0
                ? vImageBoxConvolve_ARGB8888(&a, &b, nil, 0, 0, kernel, kernel, nil, vImage_Flags(kvImageEdgeExtend))
                : vImageBoxConvolve_ARGB8888(&b, &a, nil, 0, 0, kernel, kernel, nil, vImage_Flags(kvImageEdgeExtend))
            guard error == kvImageNoError else { fatalError("blur failed: \(error)") }
        }
        // Glass lifts color: push each channel away from its luminance.
        let saturation: Float = dark ? 1.35 : 1.5
        for y in 0..<target.pixelsHigh {
            let row = targetData + y * target.bytesPerRow
            for x in 0..<target.pixelsWide {
                let pixel = row + x * 4
                let r = Float(pixel[0]), g = Float(pixel[1]), b = Float(pixel[2])
                let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
                pixel[0] = UInt8(max(0, min(255, luminance + (r - luminance) * saturation)))
                pixel[1] = UInt8(max(0, min(255, luminance + (g - luminance) * saturation)))
                pixel[2] = UInt8(max(0, min(255, luminance + (b - luminance) * saturation)))
            }
        }
        // CGImage cropping counts rows from the top, unlike the AppKit rect.
        let crop = CGRect(x: rect.minX, y: canvasSize.height - rect.maxY, width: rect.width, height: rect.height)
        guard let image = target.cgImage?.cropping(to: crop) else { fatalError("no backdrop") }
        return image
    }

    // drawCaption(headline, subtitle, canvasSize, dark): Centered marketing text above the panel.
    private func drawCaption(headline: String, subtitle: String, canvasSize: NSSize, dark: Bool) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let title = NSAttributedString(string: headline, attributes: [
            .font: NSFont.systemFont(ofSize: 46, weight: .semibold),
            .foregroundColor: dark ? NSColor.white : NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1),
            .kern: -0.6,
            .paragraphStyle: paragraph,
        ])
        let detail = NSAttributedString(string: subtitle, attributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .regular),
            .foregroundColor: dark
                ? NSColor.white.withAlphaComponent(0.72)
                : NSColor(srgbRed: 0.24, green: 0.24, blue: 0.27, alpha: 0.9),
            .paragraphStyle: paragraph,
        ])
        // Rects are measured from the top of the canvas and converted to AppKit's bottom origin.
        let titleHeight = ceil(title.size().height)
        let detailHeight = ceil(detail.size().height)
        let titleTop: CGFloat = 60
        title.draw(in: NSRect(x: 0, y: canvasSize.height - titleTop - titleHeight, width: canvasSize.width, height: titleHeight))
        let detailTop = titleTop + titleHeight + 10
        detail.draw(in: NSRect(x: 0, y: canvasSize.height - detailTop - detailHeight, width: canvasSize.width, height: detailHeight))
    }

    // drawWallpaper(in cg, size, dark): An original desktop background, a dusk or daylight
    // gradient with soft color fields.
    private func drawWallpaper(in cg: CGContext, size: NSSize, dark: Bool) {
        do {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let bounds = CGRect(origin: .zero, size: size)
            let base: [CGColor] = dark
                ? [CGColor(srgbRed: 0.05, green: 0.08, blue: 0.20, alpha: 1), CGColor(srgbRed: 0.12, green: 0.06, blue: 0.24, alpha: 1)]
                : [CGColor(srgbRed: 0.90, green: 0.93, blue: 0.98, alpha: 1), CGColor(srgbRed: 0.96, green: 0.91, blue: 0.95, alpha: 1)]
            let gradient = CGGradient(colorsSpace: space, colors: base as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])

            // Color fields as unit positions, radii relative to the width, and peak alpha.
            let fields: [(CGFloat, CGFloat, CGFloat, CGColor, CGFloat)] = dark
                ? [
                    (0.16, 0.80, 0.55, CGColor(srgbRed: 0.18, green: 0.42, blue: 1.00, alpha: 1), 0.60),
                    (0.86, 0.72, 0.52, CGColor(srgbRed: 0.49, green: 0.30, blue: 1.00, alpha: 1), 0.55),
                    (0.74, 0.08, 0.48, CGColor(srgbRed: 1.00, green: 0.30, blue: 0.55, alpha: 1), 0.38),
                    (0.22, 0.10, 0.50, CGColor(srgbRed: 0.10, green: 0.78, blue: 0.84, alpha: 1), 0.42),
                ]
                : [
                    (0.14, 0.82, 0.55, CGColor(srgbRed: 0.49, green: 0.70, blue: 1.00, alpha: 1), 0.80),
                    (0.86, 0.74, 0.52, CGColor(srgbRed: 0.78, green: 0.70, blue: 1.00, alpha: 1), 0.75),
                    (0.74, 0.08, 0.48, CGColor(srgbRed: 1.00, green: 0.78, blue: 0.70, alpha: 1), 0.70),
                    (0.22, 0.10, 0.50, CGColor(srgbRed: 0.62, green: 0.91, blue: 0.87, alpha: 1), 0.65),
                ]
            for (x, y, radius, color, alpha) in fields {
                let components = color.components ?? [0, 0, 0, 1]
                let stops = [alpha, alpha * 0.38, 0].map {
                    CGColor(srgbRed: components[0], green: components[1], blue: components[2], alpha: $0)
                }
                let field = CGGradient(colorsSpace: space, colors: stops as CFArray, locations: [0, 0.42, 1])!
                let center = CGPoint(x: bounds.width * x, y: bounds.height * y)
                // Slightly flattened fields read as light on a surface rather than spotlights.
                cg.saveGState()
                cg.translateBy(x: center.x, y: center.y)
                cg.scaleBy(x: 1, y: 0.82)
                cg.drawRadialGradient(field, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: bounds.width * radius, options: [])
                cg.restoreGState()
            }
        }
    }

    // MARK: Helpers

    // bitmap(size, [scale]): A transparent bitmap, 2x by default, whose point size matches the
    // drawing coordinates.
    static func bitmap(size: NSSize, scale: CGFloat = RenderHero.scale) -> NSBitmapImageRep {
        guard let image = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { fatalError("no bitmap") }
        image.size = size
        return image
    }

    // draw(into canvas, body): Run drawing code with the canvas as the current context, so both
    // Core Graphics calls and AppKit string and image drawing land on it.
    static func draw(into canvas: NSBitmapImageRep, _ body: (CGContext) -> Void) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: canvas) else { fatalError("no drawing context") }
        NSGraphicsContext.current = context
        body(context.cgContext)
        context.flushGraphics()
    }

    // continuousRoundedRect(rect, radius): The corner curve macOS uses for panels, three cubic
    // segments per corner that ease into the straight edges instead of a circular arc.
    static func continuousRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = min(radius, rect.width / 3.06, rect.height / 3.06)
        let path = CGMutablePath()
        // Offsets along the edge from each corner, as fractions of the radius.
        let a: CGFloat = 1.528665 * r
        let b: CGFloat = 1.08849 * r
        let c: CGFloat = 0.868407 * r
        let d: CGFloat = 0.631494 * r
        let e: CGFloat = 0.372824 * r
        let f: CGFloat = 0.169060 * r
        let g: CGFloat = 0.074911 * r
        let (x0, x1, y0, y1) = (rect.minX, rect.maxX, rect.minY, rect.maxY)

        path.move(to: CGPoint(x: x0 + a, y: y1))
        path.addLine(to: CGPoint(x: x1 - a, y: y1))
        // Top right.
        path.addCurve(to: CGPoint(x: x1 - d, y: y1 - g), control1: CGPoint(x: x1 - b, y: y1), control2: CGPoint(x: x1 - c, y: y1))
        path.addCurve(to: CGPoint(x: x1 - g, y: y1 - d), control1: CGPoint(x: x1 - e, y: y1 - f), control2: CGPoint(x: x1 - f, y: y1 - e))
        path.addCurve(to: CGPoint(x: x1, y: y1 - a), control1: CGPoint(x: x1, y: y1 - c), control2: CGPoint(x: x1, y: y1 - b))
        path.addLine(to: CGPoint(x: x1, y: y0 + a))
        // Bottom right.
        path.addCurve(to: CGPoint(x: x1 - g, y: y0 + d), control1: CGPoint(x: x1, y: y0 + b), control2: CGPoint(x: x1, y: y0 + c))
        path.addCurve(to: CGPoint(x: x1 - d, y: y0 + g), control1: CGPoint(x: x1 - f, y: y0 + e), control2: CGPoint(x: x1 - e, y: y0 + f))
        path.addCurve(to: CGPoint(x: x1 - a, y: y0), control1: CGPoint(x: x1 - c, y: y0), control2: CGPoint(x: x1 - b, y: y0))
        path.addLine(to: CGPoint(x: x0 + a, y: y0))
        // Bottom left.
        path.addCurve(to: CGPoint(x: x0 + d, y: y0 + g), control1: CGPoint(x: x0 + b, y: y0), control2: CGPoint(x: x0 + c, y: y0))
        path.addCurve(to: CGPoint(x: x0 + g, y: y0 + d), control1: CGPoint(x: x0 + e, y: y0 + f), control2: CGPoint(x: x0 + f, y: y0 + e))
        path.addCurve(to: CGPoint(x: x0, y: y0 + a), control1: CGPoint(x: x0, y: y0 + c), control2: CGPoint(x: x0, y: y0 + b))
        path.addLine(to: CGPoint(x: x0, y: y1 - a))
        // Top left.
        path.addCurve(to: CGPoint(x: x0 + g, y: y1 - d), control1: CGPoint(x: x0, y: y1 - b), control2: CGPoint(x: x0, y: y1 - c))
        path.addCurve(to: CGPoint(x: x0 + d, y: y1 - g), control1: CGPoint(x: x0 + f, y: y1 - e), control2: CGPoint(x: x0 + e, y: y1 - f))
        path.addCurve(to: CGPoint(x: x0 + a, y: y1), control1: CGPoint(x: x0 + c, y: y1), control2: CGPoint(x: x0 + b, y: y1))
        path.closeSubpath()
        return path
    }
}
