import ScreenSaver
import WebKit

/// A web view that never takes mouse or keyboard input, so every event reaches the
/// screen saver host and dismisses the screen saver as usual.
final class PassiveWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

/// Big Apple Sam as a macOS screen saver: hosts the bundled index.html in autopilot mode.
///
/// Two ways to show the page:
/// - Direct (macOS 12-15): the web view sits inside the screen saver view.
/// - Snapshot (macOS 26 and later): since macOS 26.4, a web view inside a screen saver view goes blank a few
///   seconds after it appears. There the web view lives in an off-screen window instead, and the screen saver
///   draws snapshots of it.
/// Either way the screen saver host can treat the page as hidden and stop its animation frames, so the page is
/// told it is visible, and animateOneFrame drives it through window.BAS_TICK.
@objc(BigAppleSamView)
final class BigAppleSamView: ScreenSaverView {
    private var webView: PassiveWebView?
    private var hostWindow: NSWindow?
    private var frameImage: CGImage?
    private var snapping = false
    private var snapshotMode: Bool {
        if let forced = ProcessInfo.processInfo.environment["BAS_RENDER"] { return forced == "snapshot" }
        if #available(macOS 26.0, *) { return true }
        return false
    }
    private static var stopObserver: NSObjectProtocol?
    private static let visibleScript = """
    try {
      Object.defineProperty(Document.prototype, 'hidden', { configurable: true, get: function () { return false; } });
      Object.defineProperty(Document.prototype, 'visibilityState', { configurable: true, get: function () { return 'visible'; } });
    } catch (e) {}
    """

    // Options sheet controls
    private var sheet: NSWindow?
    private var codeField: NSTextField!
    private var speedPopup: NSPopUpButton!
    private var displayPopup: NSPopUpButton!
    private var nightBox: NSButton!
    private var captionBox: NSButton!
    private var cyberBox: NSButton!

    private lazy var defaults: ScreenSaverDefaults? = {
        let id = Bundle(for: BigAppleSamView.self).bundleIdentifier ?? "com.samuelling.BigAppleSam"
        let d = ScreenSaverDefaults(forModuleWithName: id)
        d?.register(defaults: ["cityCode": "", "alwaysNight": false, "captions": true, "speed": 1, "display": 1, "cyber": false])
        return d
    }()

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 30.0
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        // Since Sonoma, legacyScreenSaver can keep running a saver after it is dismissed.
        // Quit the host process shortly after the system says the screen saver is stopping.
        if !isPreview && BigAppleSamView.stopObserver == nil {
            BigAppleSamView.stopObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screensaver.willstop"), object: nil, queue: .main
            ) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { exit(0) }
            }
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
        if let img = frameImage, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.interpolationQuality = .none
            ctx.draw(img, in: bounds)
        }
    }

    override func startAnimation() {
        super.startAnimation()
        if webView == nil { loadPage() } else { sizeWebView() }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        sizeWebView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sizeWebView()
    }

    /// The host sometimes hands over a 0x0 frame, or one in backing pixels; trust the screen instead.
    private func targetSize() -> NSSize {
        if isPreview, bounds.width > 1, bounds.height > 1 { return bounds.size }
        let screen = window?.screen?.frame.size ?? NSScreen.main?.frame.size ?? .zero
        if screen.width > 1, screen.height > 1 {
            if bounds.width > 1, bounds.height > 1 {
                return NSSize(width: min(bounds.width, screen.width), height: min(bounds.height, screen.height))
            }
            return screen
        }
        return bounds.width > 1 ? bounds.size : NSSize(width: 1440, height: 900)
    }

    private func sizeWebView() {
        guard let wv = webView else { return }
        let size = targetSize()
        if let hw = hostWindow {
            if hw.frame.size != size { hw.setContentSize(size) }
            wv.frame = NSRect(origin: .zero, size: size)
        } else {
            wv.frame = NSRect(origin: .zero, size: size)
        }
    }

    override func stopAnimation() {
        super.stopAnimation()
        if !isPreview { teardown() }
    }

    override func animateOneFrame() {
        guard let wv = webView else { return }
        wv.evaluateJavaScript("window.BAS_TICK && window.BAS_TICK()", completionHandler: nil)
        guard hostWindow != nil, !snapping else { return }
        snapping = true
        let cfg = WKSnapshotConfiguration()
        cfg.rect = wv.bounds
        cfg.afterScreenUpdates = false
        wv.takeSnapshot(with: cfg) { [weak self] image, _ in
            guard let self = self else { return }
            self.snapping = false
            if let image = image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                self.frameImage = cg
                self.needsDisplay = true
            }
        }
    }

    private func teardown() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        hostWindow?.contentView = nil
        hostWindow?.close()
        hostWindow = nil
        frameImage = nil
        snapping = false
    }

    private func loadPage() {
        let screenIndex: Int = {
            guard let screen = window?.screen else { return 0 }
            return NSScreen.screens.firstIndex(of: screen) ?? 0
        }()
        let cfg: [String: Any] = [
            "code": defaults?.string(forKey: "cityCode") ?? "",
            "night": defaults?.bool(forKey: "alwaysNight") ?? false,
            "captions": isPreview ? false : (defaults?.bool(forKey: "captions") ?? true),
            "speed": defaults?.integer(forKey: "speed") ?? 1,
            "gfx": ["cga", "vga", "svga", "ega"][max(0, min(3, defaults?.integer(forKey: "display") ?? 1))],
            "cyber": defaults?.bool(forKey: "cyber") ?? false,
            "display": screenIndex,
            "preview": isPreview,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: cfg))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.userContentController.addUserScript(
            WKUserScript(source: "window.BAS_SAVER=\(json);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addUserScript(
            WKUserScript(source: BigAppleSamView.visibleScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        let size = targetSize()
        let wv = PassiveWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        wv.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) { wv.isInspectable = true }
        if snapshotMode {
            // Off-screen, never ordered in: the page renders here and the screen saver draws snapshots of it.
            let hw = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
            hw.isReleasedWhenClosed = false
            hw.contentView = wv
            hostWindow = hw
        } else {
            addSubview(wv)
        }
        webView = wv

        if let url = Bundle(for: BigAppleSamView.self).url(forResource: "index", withExtension: "html") {
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    // MARK: - Options sheet

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        if sheet == nil { buildSheet() }
        codeField.stringValue = defaults?.string(forKey: "cityCode") ?? ""
        nightBox.state = (defaults?.bool(forKey: "alwaysNight") ?? false) ? .on : .off
        captionBox.state = (defaults?.bool(forKey: "captions") ?? true) ? .on : .off
        cyberBox.state = (defaults?.bool(forKey: "cyber") ?? false) ? .on : .off
        let speed = defaults?.integer(forKey: "speed") ?? 1
        speedPopup.selectItem(withTag: [1, 10, 60].contains(speed) ? speed : 1)
        displayPopup.selectItem(withTag: max(0, min(3, defaults?.integer(forKey: "display") ?? 1)))
        return sheet
    }

    private func buildSheet() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 290),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Big Apple Sam"
        guard let v = w.contentView else { return }

        let codeLabel = NSTextField(labelWithString: "City code:")
        codeLabel.frame = NSRect(x: 20, y: 244, width: 90, height: 20)
        v.addSubview(codeLabel)

        codeField = NSTextField(frame: NSRect(x: 115, y: 242, width: 265, height: 24))
        codeField.placeholderString = "e.g. bod5nr-g09"
        v.addSubview(codeField)

        let help = NSTextField(wrappingLabelWithString:
            "Copy the city code from the controls window in the web version to watch the same city. Leave it blank and the screen saver keeps a city of its own.")
        help.frame = NSRect(x: 115, y: 190, width: 265, height: 46)
        help.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        help.textColor = .secondaryLabelColor
        v.addSubview(help)

        let speedLabel = NSTextField(labelWithString: "Clock:")
        speedLabel.frame = NSRect(x: 20, y: 156, width: 90, height: 20)
        v.addSubview(speedLabel)

        speedPopup = NSPopUpButton(frame: NSRect(x: 112, y: 151, width: 180, height: 28), pullsDown: false)
        for (title, tag) in [("Live (real time)", 1), ("10× faster", 10), ("60× faster", 60)] {
            speedPopup.addItem(withTitle: title)
            speedPopup.lastItem?.tag = tag
        }
        v.addSubview(speedPopup)

        let displayLabel = NSTextField(labelWithString: "Display:")
        displayLabel.frame = NSRect(x: 20, y: 116, width: 90, height: 20)
        v.addSubview(displayLabel)

        displayPopup = NSPopUpButton(frame: NSRect(x: 112, y: 111, width: 230, height: 28), pullsDown: false)
        for (title, tag) in [("CGA (4 colors)", 0), ("EGA (16 colors)", 3), ("VGA", 1), ("SVGA (sharper close-ups)", 2)] {
            displayPopup.addItem(withTitle: title)
            displayPopup.lastItem?.tag = tag
        }
        v.addSubview(displayPopup)

        nightBox = NSButton(checkboxWithTitle: "Always night", target: nil, action: nil)
        nightBox.frame = NSRect(x: 113, y: 84, width: 120, height: 20)
        v.addSubview(nightBox)

        cyberBox = NSButton(checkboxWithTitle: "Cyberpunk mode", target: nil, action: nil)
        cyberBox.frame = NSRect(x: 240, y: 84, width: 150, height: 20)
        v.addSubview(cyberBox)

        captionBox = NSButton(checkboxWithTitle: "Show what's happening in each apartment", target: nil, action: nil)
        captionBox.frame = NSRect(x: 113, y: 60, width: 280, height: 20)
        v.addSubview(captionBox)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSheet))
        cancel.frame = NSRect(x: 214, y: 14, width: 82, height: 32)
        cancel.keyEquivalent = "\u{1b}"
        v.addSubview(cancel)

        let ok = NSButton(title: "OK", target: self, action: #selector(saveSheet))
        ok.frame = NSRect(x: 300, y: 14, width: 82, height: 32)
        ok.keyEquivalent = "\r"
        v.addSubview(ok)

        sheet = w
    }

    @objc private func cancelSheet() { closeSheet() }

    @objc private func saveSheet() {
        let code = codeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        defaults?.set(code, forKey: "cityCode")
        defaults?.set(nightBox.state == .on, forKey: "alwaysNight")
        defaults?.set(captionBox.state == .on, forKey: "captions")
        defaults?.set(cyberBox.state == .on, forKey: "cyber")
        defaults?.set(speedPopup.selectedTag(), forKey: "speed")
        defaults?.set(displayPopup.selectedTag(), forKey: "display")
        defaults?.synchronize()
        closeSheet()
        if isPreview { teardown(); loadPage() }
    }

    private func closeSheet() {
        guard let w = sheet else { return }
        if let parent = w.sheetParent { parent.endSheet(w) } else { w.orderOut(nil) }
    }
}
