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
/// - Direct: the web view sits inside the screen saver view. Smooth, and what macOS 12-15 always use.
/// - Snapshot: the web view lives in an off-screen window and the screen saver shows snapshots of it. Slower.
/// Since macOS 26.4 a web view inside a screen saver goes blank a few seconds after it appears, because WebKit
/// decides the window is covered up. On macOS 26 the saver turns WebKit's occlusion detection off and stays
/// direct, while a watchdog compares what the view shows with a snapshot of the page every few seconds; if the
/// view has gone black while the page hasn't, it moves to snapshot mode, and remembers that for this macOS version.
/// Either way the screen saver host can treat the page as hidden and stop its animation frames, so the page is
/// told it is visible, and animateOneFrame drives it through window.BAS_TICK.
@objc(BigAppleSamView)
final class BigAppleSamView: ScreenSaverView {
    private var webView: PassiveWebView?
    private var hostWindow: NSWindow?
    private var frameImage: CGImage?
    private var snapping = false
    private var lastSnapFrame = -1
    private var latestFrame = -1
    /// Fraction of full resolution snapshots are taken at. Drops to 1x pixels on a Retina screen if
    /// full-resolution snapshots turn out too slow to keep up.
    private var snapScale: CGFloat = 1
    private var timedSnaps = 0
    /// Snapshots are shown on this layer, so the GPU puts them on screen instead of draw() copying every pixel.
    private let imageLayer: CALayer = {
        let l = CALayer()
        l.contentsGravity = .resize
        l.magnificationFilter = .nearest
        l.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        return l
    }()
    /// For the test harness: how many new pictures were shown, the average time a snapshot took, and whether
    /// the watchdog moved a direct web view to snapshot mode.
    @objc private(set) var framesShown = 0
    @objc private(set) var snapMillis = 0.0
    @objc private(set) var fellBack = false
    private var watching = false
    private var checking = false
    private var strikes = 0
    private var startedAt = 0.0
    private var lastCheck = 0.0
    private static let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

    /// How to show the page: (snapshot, occlusion detection off, watchdog). BAS_RENDER (snapshot, direct,
    /// direct-noocc, direct-watch) forces one for testing.
    private var renderPlan: (snapshot: Bool, noOcclusion: Bool, watch: Bool) {
        switch ProcessInfo.processInfo.environment["BAS_RENDER"] {
        case "snapshot": return (true, false, false)
        case "direct": return (false, false, false)
        case "direct-noocc": return (false, true, false)
        case "direct-watch": return (false, false, true)
        default: break
        }
        if #available(macOS 26.0, *) {
            if defaults?.string(forKey: "snapshotFallbackOS") == BigAppleSamView.osVersion { return (true, false, false) }
            return (false, true, true)
        }
        return (false, false, false)
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
        layer?.addSublayer(imageLayer)
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

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
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
        guard hostWindow != nil else {
            wv.evaluateJavaScript("window.BAS_TICK && window.BAS_TICK()", completionHandler: nil)
            if watching {
                // Every 3 seconds for the first half minute (when the blanking shows up), then every 15.
                let t = CACurrentMediaTime()
                if t - lastCheck >= (t - startedAt < 30 ? 3 : 15) { lastCheck = t; checkDirect() }
            }
            return
        }
        // Snapshot mode: tick the page on every frame; BAS_TICK says how many frames it has drawn, and a new one
        // gets photographed as soon as the last snapshot is done.
        wv.evaluateJavaScript("window.BAS_TICK ? window.BAS_TICK() : -1") { [weak self] result, _ in
            guard let self = self else { return }
            self.latestFrame = (result as? NSNumber)?.intValue ?? -1
            self.snapIfNeeded()
        }
    }

    private func snapIfNeeded() {
        guard let wv = webView, !snapping else { return }
        let n = latestFrame
        if n >= 0 && n == lastSnapFrame { return }
        snapping = true
        let cfg = WKSnapshotConfiguration()
        cfg.rect = wv.bounds
        cfg.afterScreenUpdates = false
        if snapScale < 1 { cfg.snapshotWidth = NSNumber(value: Double(wv.bounds.width * snapScale)) }
        let t0 = CACurrentMediaTime()
        wv.takeSnapshot(with: cfg) { [weak self] image, _ in
            guard let self = self else { return }
            self.snapping = false
            guard self.webView != nil, let image = image,
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            self.lastSnapFrame = n
            self.timed((CACurrentMediaTime() - t0) * 1000)
            self.framesShown += 1
            self.frameImage = cg
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.imageLayer.frame = self.bounds
            self.imageLayer.contents = cg
            CATransaction.commit()
            self.snapIfNeeded()
        }
    }

    /// Keeps a running average of snapshot times; if full-resolution snapshots on a Retina screen average
    /// more than about a frame, switch to 1x pixels, which takes a quarter of the work.
    private func timed(_ ms: Double) {
        timedSnaps += 1
        snapMillis += (ms - snapMillis) / Double(min(timedSnaps, 30))
        let scale = hostWindow?.backingScaleFactor ?? 1
        if snapScale == 1, scale > 1, timedSnaps >= 20, snapMillis > 28 {
            snapScale = 1 / scale
            timedSnaps = 0
        }
    }

    /// Fraction of sampled pixels that aren't (nearly) black.
    private static func lit(_ rep: NSBitmapImageRep) -> Double {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0 else { return 0 }
        let step = max(1, Int((Double(w * h) / 4000).squareRoot()))
        var on = 0, n = 0
        if rep.bitsPerSample == 8, !rep.isPlanar, rep.samplesPerPixel >= 3, let d = rep.bitmapData {
            let bpr = rep.bytesPerRow, spp = rep.samplesPerPixel
            let alphaFirst = rep.bitmapFormat.contains(.alphaFirst) && rep.hasAlpha
            let o = alphaFirst ? 1 : 0
            for y in stride(from: 0, to: h, by: step) {
                for x in stride(from: 0, to: w, by: step) {
                    let p = d + y * bpr + x * spp + o
                    n += 1
                    if Int(p[0]) + Int(p[1]) + Int(p[2]) > 40 { on += 1 }
                }
            }
        } else {
            for y in stride(from: 0, to: h, by: step * 2) {
                for x in stride(from: 0, to: w, by: step * 2) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    n += 1
                    if c.redComponent + c.greenComponent + c.blueComponent > 0.15 { on += 1 }
                }
            }
        }
        return n > 0 ? Double(on) / Double(n) : 0
    }

    /// Watchdog for direct mode: compares a band across the middle of what the view shows with a small snapshot
    /// of the same band of the page. Twice in a row black on screen while the page isn't means WebKit has blanked
    /// the view, so switch to snapshots.
    private func checkDirect() {
        guard let wv = webView, hostWindow == nil, !checking, bounds.width > 10, bounds.height > 10 else { return }
        let band = NSRect(x: bounds.width * 0.3, y: bounds.height * 0.42, width: bounds.width * 0.4, height: bounds.height * 0.16)
        guard let rep = bitmapImageRepForCachingDisplay(in: band) else { return }
        cacheDisplay(in: band, to: rep)
        let shown = BigAppleSamView.lit(rep)
        checking = true
        let cfg = WKSnapshotConfiguration()
        cfg.rect = wv.convert(band, from: self)
        cfg.afterScreenUpdates = false
        cfg.snapshotWidth = 240
        wv.takeSnapshot(with: cfg) { [weak self] image, _ in
            guard let self = self else { return }
            self.checking = false
            guard self.webView != nil, self.hostWindow == nil,
                  let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let truth = BigAppleSamView.lit(NSBitmapImageRep(cgImage: cg))
            self.strikes = (truth > 0.02 && shown < 0.002) ? self.strikes + 1 : 0
            if self.strikes >= 2 { self.switchToSnapshots() }
        }
    }

    private func switchToSnapshots() {
        guard let wv = webView, hostWindow == nil else { return }
        watching = false
        fellBack = true
        if !isPreview { defaults?.set(BigAppleSamView.osVersion, forKey: "snapshotFallbackOS"); defaults?.synchronize() }
        wv.removeFromSuperview()
        hostWindow = makeHostWindow(wv, size: targetSize())
        sizeWebView()
    }

    /// Off-screen, never ordered in: the page renders here and the screen saver shows snapshots of it.
    private func makeHostWindow(_ wv: WKWebView, size: NSSize) -> NSWindow {
        let hw = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                          styleMask: .borderless, backing: .buffered, defer: false)
        hw.isReleasedWhenClosed = false
        hw.contentView = wv
        return hw
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
        imageLayer.contents = nil
        snapping = false
        lastSnapFrame = -1
        latestFrame = -1
        snapScale = 1
        timedSnaps = 0
        watching = false
        checking = false
        strikes = 0
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
        let plan = renderPlan
        if plan.noOcclusion {
            // Keep WebKit from deciding the screen saver's window is covered up and blanking the page.
            let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
            if wv.responds(to: sel) {
                typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
                unsafeBitCast(wv.method(for: sel), to: Setter.self)(wv, sel, false)
            }
        }
        if plan.snapshot {
            hostWindow = makeHostWindow(wv, size: size)
        } else {
            addSubview(wv)
            watching = plan.watch
            startedAt = CACurrentMediaTime()
            lastCheck = startedAt
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
