// Loads the built "Big Apple Sam.saver", runs it in a window for a while the way the screen saver host does
// (startAnimation, then animateOneFrame on a timer), and checks the picture isn't black.
// Usage: saver_test <path to .saver> <out.png> [seconds]
// BAS_RENDER=direct|snapshot picks the rendering path (default: whatever the OS gets).
import AppKit
import ScreenSaver

let args = CommandLine.arguments
guard args.count >= 3, let bundle = Bundle(path: args[1]), bundle.load(),
      let cls = bundle.principalClass as? ScreenSaverView.Type else {
    FileHandle.standardError.write("could not load the screen saver bundle\n".data(using: .utf8)!)
    exit(2)
}
let out = args[2]
let seconds = args.count > 3 ? Double(args[3]) ?? 10 : 10

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let rect = NSRect(x: 0, y: 0, width: 1280, height: 800)
let win = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
guard let view = cls.init(frame: rect, isPreview: false) else { exit(3) }
win.contentView = view
win.center()
win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
view.startAnimation()
let tick = Timer.scheduledTimer(withTimeInterval: view.animationTimeInterval, repeats: true) { _ in view.animateOneFrame() }

/// Fraction of sampled pixels that aren't (nearly) black in a picture.
func lit(_ rep: NSBitmapImageRep?) -> Double {
    guard let rep = rep else { return -1 }
    var on = 0, n = 0
    for y in stride(from: 40, to: rep.pixelsHigh, by: 17) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 17) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            n += 1
            if c.redComponent + c.greenComponent + c.blueComponent > 0.15 { on += 1 }
        }
    }
    return n > 0 ? Double(on) / Double(n) : -1
}
/// The window as it is on screen (what a person would see), saved to path.
func screen(_ path: String) -> Double {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l", String(win.windowNumber), path]
    try? p.run(); p.waitUntilExit()
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return -1 }
    return lit(NSBitmapImageRep(data: d))
}
/// What the view itself draws (covers snapshot mode even where screen capture isn't allowed).
func drawn() -> Double {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return -1 }
    view.cacheDisplay(in: view.bounds, to: rep)
    return lit(rep)
}

var report: [String] = [], final = (-1.0, -1.0)
for (i, t) in [3.0, seconds].enumerated() {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: i == 0 ? t : t - 3.0))
    let s = screen(i == 0 ? out.replacingOccurrences(of: ".png", with: "-3s.png") : out), d = drawn()
    report.append(String(format: "%.0fs: screen %.0f%% lit, view %.0f%% lit", t, s * 100, d * 100))
    final = (s, d)
}
tick.invalidate()
view.stopAnimation()
print(report.joined(separator: " | "))
// Pass if a real picture is there at the end: a black screen is 0% lit, the city at night still shows lit windows and stars.
exit(max(final.0, final.1) > 0.05 ? 0 : 1)
