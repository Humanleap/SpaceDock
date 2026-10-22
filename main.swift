import Cocoa
import ApplicationServices

typealias CGSConnectionID = UInt32
@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID
// Private API. The array is the live left-to-right Spaces order.
@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ conn: CGSConnectionID) -> CFArray?

private let dockDomain = "com.apple.dock" as CFString
private let addedKey = "addedBundleIDs"
private let delegate = AppDelegate()

struct SpaceApp {
    let bundleID: String
    let url: URL
    let label: String
}

struct SwitchItem {
    let bundleID: String
    let url: URL
    let label: String
    let running: NSRunningApplication
}

private enum TapDecision: Equatable {
    case pass
    case swallow
    case open(forward: Bool)
    case move(forward: Bool)
    case commit
    case cancel
}

/// macOS will not change Command-Tab order, so only the plain chord is handled here.
private func decideSwitch(type: CGEventType, keyCode: Int64, flags: CGEventFlags, visible: Bool) -> TapDecision {
    if type == .flagsChanged {
        return visible && !flags.contains(.maskCommand) ? .commit : .pass
    }
    let tab = keyCode == 48
    let escape = keyCode == 53
    let command = flags.contains(.maskCommand)
    let plain = command && !flags.contains(.maskControl) && !flags.contains(.maskAlternate)
    if type == .keyDown && escape && visible { return .cancel }
    if type == .keyDown && tab && plain {
        let forward = !flags.contains(.maskShift)
        return visible ? .move(forward: forward) : .open(forward: forward)
    }
    if type == .keyDown && visible && plain && (keyCode == 123 || keyCode == 124) {
        return .move(forward: keyCode == 124)
    }
    if visible && (type == .keyDown || type == .keyUp) { return .swallow }
    return .pass
}

private func switcherTap(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let switcher = Switcher.shared else { return Unmanaged.passUnretained(event) }
    return switcher.handle(type: type, event: event)
}

@main
enum Main {
    static func main() {
        #if SPACE_DOCK_TEST
        runSwitcherChecks()
        #else
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        #endif
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var timer: Timer?
    private var pending: [String] = []
    private var pendingSince: Date?
    private var busyUntil = Date.distantPast
    private var failedApplies = 0
    private let switcher = Switcher()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let timer = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in
            self?.tick(force: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        switcher.prepare()
        switcher.start()
        tick(force: false)
    }

    private func tick(force: Bool) {
        guard !switcher.isStopping else { return }
        switcher.installIfNeeded()
        switcher.prepare()
        switcher.recover()
        guard Date() >= busyUntil else { return }
        guard let spaces = spaceApps() else { return }

        let current = dockTiles()
        var added = Set(UserDefaults.standard.stringArray(forKey: addedKey) ?? [])
        let desired = arrangedTiles(current: current, spaces: spaces, added: &added)
        let wanted = desired.map(tileID)
        let have = current.map(tileID)
        // static-only makes the Dock ignore pinned order and show apps in the order they were opened.
        let hidesPinOrder = (CFPreferencesCopyAppValue("static-only" as CFString, dockDomain) as? Bool) == true
        if wanted == have && !hidesPinOrder && !iconsStale(current, spaces: spaces) {
            pending = []
            pendingSince = nil
            failedApplies = 0
            UserDefaults.standard.set(Array(added), forKey: addedKey)
            return
        }
        if !force {
            if wanted != pending {
                pending = wanted
                pendingSince = Date()
                return
            }
            if Date().timeIntervalSince(pendingSince ?? Date()) < 1.5 { return }
        }
        apply(desired, added: added, names: spaces.map(\.label))
    }

    private func arrangedTiles(current: [[String: Any]], spaces: [SpaceApp], added: inout Set<String>) -> [[String: Any]] {
        var byID: [String: [String: Any]] = [:]
        for tile in current {
            let id = tileID(tile)
            if byID[id] == nil { byID[id] = tile }
        }
        var result: [[String: Any]] = []
        var seen = Set<String>()
        var guids = Set<Int>()
        var mods = Set<Int>()
        for app in spaces where seen.insert(app.bundleID).inserted {
            if let tile = byID[app.bundleID], claimTile(tile, guids: &guids, mods: &mods) {
                result.append(tile)
            } else {
                result.append(makeTile(app: app, guids: &guids, mods: &mods))
                if byID[app.bundleID] == nil { added.insert(app.bundleID) }
            }
        }
        let spaceIDs = Set(spaces.map(\.bundleID))
        for tile in current {
            let id = tileID(tile)
            if seen.contains(id) { continue }
            if added.contains(id) && !spaceIDs.contains(id) { continue }
            result.append(tile)
            seen.insert(id)
        }
        added = added.intersection(spaceIDs)
        return result
    }

    private func apply(_ tiles: [[String: Any]], added: Set<String>, names: [String]) {
        CFPreferencesSetAppValue("persistent-apps" as CFString, tiles as CFArray, dockDomain)
        CFPreferencesSetAppValue("static-only" as CFString, kCFBooleanFalse, dockDomain)
        CFPreferencesSetAppValue("show-recents" as CFString, kCFBooleanFalse, dockDomain)
        CFPreferencesSynchronize(dockDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        UserDefaults.standard.set(Array(added), forKey: addedKey)
        // Kill so the Dock cannot write its old in-memory order back over the new one.
        let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        if dock?.forceTerminate() != true {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            kill.arguments = ["-9", "Dock"]
            try? kill.run()
        }
        pending = []
        pendingSince = nil
        busyUntil = Date().addingTimeInterval(4)
        failedApplies += 1
        log("Dock set to \(names.joined(separator: ", "))")
        if failedApplies >= 3 {
            busyUntil = Date().addingTimeInterval(60)
            log("Dock did not keep the new order. Pausing for a minute.")
        }
    }

    /// The Dock caches an icon by GUID and by this date. A shared date keeps the first app's icon.
    private func makeTile(app: SpaceApp, guids: inout Set<Int>, mods: inout Set<Int>) -> [String: Any] {
        var url = app.url
        if !url.hasDirectoryPath {
            url = URL(fileURLWithPath: url.path, isDirectory: true)
        }
        var guid = 0
        repeat {
            guid = Int.random(in: 1_000_000_000..<10_000_000_000)
        } while !guids.insert(guid).inserted
        let mod = uniqueModDate(url, salt: app.bundleID, used: &mods)
        var data: [String: Any] = [
            "bundle-identifier": app.bundleID,
            "file-label": app.label,
            "file-type": 41,
            "dock-extra": false,
            "is-beta": false,
            "file-mod-date": mod,
            "parent-mod-date": uniqueModDate(url.deletingLastPathComponent(), salt: app.bundleID + "/", used: &mods),
            "file-data": [
                "_CFURLString": url.absoluteString,
                "_CFURLStringType": 15,
            ],
        ]
        if let book = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            data["book"] = book
        }
        return ["tile-type": "file-tile", "GUID": guid, "tile-data": data]
    }

    private func claimTile(_ tile: [String: Any], guids: inout Set<Int>, mods: inout Set<Int>) -> Bool {
        let data = tile["tile-data"] as? [String: Any] ?? [:]
        guard (data["file-type"] as? NSNumber)?.intValue == 41 else { return false }
        let guid = (tile["GUID"] as? NSNumber)?.intValue ?? 0
        let mod = (data["file-mod-date"] as? NSNumber)?.intValue ?? 0
        guard guid != 0, mod != 0 else { return false }
        return guids.insert(guid).inserted && mods.insert(mod).inserted
    }

    private func iconsStale(_ tiles: [[String: Any]], spaces: [SpaceApp]) -> Bool {
        let spaceIDs = Set(spaces.map(\.bundleID))
        var guids = Set<Int>()
        var mods = Set<Int>()
        for tile in tiles where spaceIDs.contains(tileID(tile)) {
            if !claimTile(tile, guids: &guids, mods: &mods) { return true }
        }
        return false
    }

    private func uniqueModDate(_ url: URL, salt: String, used: inout Set<Int>) -> Int {
        let unix = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        var date = Int(unix) + 2_082_844_800 + stableMix(salt)
        while !used.insert(date).inserted { date += 1 }
        return date
    }

    private func stableMix(_ text: String) -> Int {
        var hash = 5381
        for byte in text.utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        let mixed = hash % 100_000
        return mixed < 0 ? -mixed : mixed
    }
}

private final class StripView: NSView {
    var icons: [NSImage] = []
    var selection = 0
    var iconSide: CGFloat = 148
    var spacing: CGFloat = 16
    var padX: CGFloat = 14
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    let padTop: CGFloat = 10
    let padBottom: CGFloat = 10

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.set()
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        guard let index = index(at: event.locationInWindow) else { return }
        onHover?(index)
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = index(at: event.locationInWindow) else { return }
        onClick?(index)
    }

    private func index(at windowPoint: NSPoint) -> Int? {
        let point = convert(windowPoint, from: nil)
        let stride = iconSide + spacing
        guard stride > 0 else { return nil }
        let index = Int((point.x - padX + spacing / 2) / stride)
        return icons.indices.contains(index) ? index : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let iconY = padBottom
        let stride = iconSide + spacing
        let outset = max(2, iconSide * 0.025)
        for index in icons.indices {
            let iconRect = NSRect(
                x: padX + CGFloat(index) * stride,
                y: iconY,
                width: iconSide,
                height: iconSide
            )
            if index == selection {
                let ring = iconRect.insetBy(dx: -outset, dy: -outset)
                let radius = iconSide * 0.225 + outset
                let path = NSBezierPath(roundedRect: ring, xRadius: radius, yRadius: radius)
                NSColor.black.withAlphaComponent(0.32).setFill()
                path.fill()
            }
            icons[index].draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }
}

final class Switcher {
    fileprivate static weak var shared: Switcher?
    fileprivate private(set) var isOn = false
    fileprivate private(set) var isStopping = false

    private let strip = StripView()
    private let panel: NSPanel
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var items: [SwitchItem] = []
    private var selection = 0
    private var visible = false
    private var reportedBlocked = false
    private var reportedPass = false
    private var wasTrusted = AXIsProcessTrusted()
    private var activity: NSObjectProtocol?
    private var rebuildAfter = Date.distantPast
    private var tapBroken = false
    private var readyItems: [SwitchItem] = []
    private var readyIcons: [NSImage] = []
    private let readyLock = NSLock()
    private let stateLock = NSLock()
    private var keyLoop: CFRunLoop?
    private let keyLoopReady = DispatchSemaphore(value: 0)
    private var keyLoopStarted = false
    private var commandAt = Date.distantPast

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 92),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        strip.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 30
            if #available(macOS 27.0, *) {
                glass.effectIsInteractive = false
            }
            glass.contentView = strip
            panel.contentView = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 30
            effect.layer?.masksToBounds = true
            panel.contentView = effect
            effect.addSubview(strip)
        }
        strip.onHover = { [weak self] index in self?.hover(index) }
        strip.onClick = { [weak self] index in self?.click(index) }
        Switcher.shared = self
    }

    func start() {
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "App switcher")
        }
        if !AXIsProcessTrusted() && !UserDefaults.standard.bool(forKey: "askedForAccessibility") {
            UserDefaults.standard.set(true, forKey: "askedForAccessibility")
            prompt()
        }
        installIfNeeded()
    }

    func prompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            installIfNeeded()
            if !isOn { relaunch() }
        }
    }

    func installIfNeeded() {
        if isStopping { return }
        ensureKeyLoop()
        guard let keyLoop else { return }
        // tapIsEnabled talks to the window server. Doing that on the key thread stalls
        // the listener, macOS drops the tap, and Command-Tab falls back to the system.
        if tapHealthy() { return }
        CFRunLoopPerformBlock(keyLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.installOnKeyLoop()
        }
        CFRunLoopWakeUp(keyLoop)
    }

    /// The key listener has to live on its own loop. The main thread reads Spaces, and a slow
    /// listener lets macOS show its own switcher and then switch this one off.
    private func ensureKeyLoop() {
        if keyLoopStarted { return }
        keyLoopStarted = true
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            let loop = CFRunLoopGetCurrent()
            self.keyLoop = loop
            // An empty loop returns at once. A parked source keeps it waiting for keys.
            var context = CFRunLoopSourceContext()
            if let parked = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context) {
                CFRunLoopAddSource(loop, parked, .commonModes)
            }
            self.installOnKeyLoop()
            self.keyLoopReady.signal()
            CFRunLoopRun()
        }
        keyLoopReady.wait()
    }

    private func installOnKeyLoop() {
        if isStopping { return }
        if Date() < rebuildAfter { return }
        rebuildAfter = Date().addingTimeInterval(3)
        stateLock.lock()
        let restarting = tap != nil
        stateLock.unlock()
        removeTap()
        let trusted = AXIsProcessTrusted()
        if trusted && !wasTrusted {
            wasTrusted = true
            DispatchQueue.main.async { [weak self] in self?.relaunch() }
            return
        }
        wasTrusted = trusted
        guard trusted else {
            reportBlocked("Switcher needs Accessibility. Command-Tab is unchanged.")
            return
        }
        let mask = eventMask(.keyDown) | eventMask(.keyUp) | eventMask(.flagsChanged)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: switcherTap,
            userInfo: nil
        ) else {
            reportBlocked("Switcher could not install. Command-Tab is unchanged.")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        guard CGEvent.tapIsEnabled(tap: port) else {
            reportBlocked("Switcher tap did not stay on. Command-Tab is unchanged.")
            return
        }
        stateLock.lock()
        tap = port
        isOn = true
        tapBroken = false
        stateLock.unlock()
        self.source = source
        readyLock.lock()
        let names = readyItems.map(\.label)
        readyLock.unlock()
        if restarting {
            log("Switcher tap stopped. Back on. Order: \(names.joined(separator: ", "))")
        } else {
            log("Switcher on. Order: \(names.joined(separator: ", "))")
        }
    }

    /// Runs on the main thread. The window-server check must not run on the key thread.
    private func tapHealthy() -> Bool {
        stateLock.lock()
        let port = tap
        let broken = tapBroken
        let on = isOn
        stateLock.unlock()
        guard on, !broken, let port else { return false }
        return CGEvent.tapIsEnabled(tap: port)
    }

    func prepare() {
        let found = switcherItems()
        guard !found.isEmpty else { return }
        readyLock.lock()
        let same = found.map(\.bundleID) == readyItems.map(\.bundleID) && readyIcons.count == found.count
        readyLock.unlock()
        if same {
            readyLock.lock()
            readyItems = found
            readyLock.unlock()
            return
        }
        let icons = found.map { item in
            let icon = NSWorkspace.shared.icon(forFile: item.url.path)
            icon.size = NSSize(width: 256, height: 256)
            return icon
        }
        readyLock.lock()
        readyItems = found
        readyIcons = icons
        readyLock.unlock()
    }

    private func isReady() -> Bool {
        readyLock.lock()
        defer { readyLock.unlock() }
        return !readyItems.isEmpty && readyIcons.count == readyItems.count
    }

    private func removeTap() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        stateLock.lock()
        let port = tap
        tap = nil
        isOn = false
        tapBroken = false
        stateLock.unlock()
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        source = nil
    }

    func recover() {
        guard isVisible() else { return }
        stateLock.lock()
        let since = Date().timeIntervalSince(commandAt)
        stateLock.unlock()
        // A Command chord just arrived. The hardware flag can flicker while it is held.
        if since < 1.5 { return }
        if !CGEventSource.flagsState(.hidSystemState).contains(.maskCommand) {
            commit()
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stateLock.lock()
            let port = tap
            stateLock.unlock()
            if let port {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return nil
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        note(type: type, flags: flags)
        switch decideSwitch(type: type, keyCode: keyCode, flags: flags, visible: isVisible()) {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        case .open(let forward), .move(let forward):
            guard isReady() || isVisible() else {
                if !reportedPass {
                    reportedPass = true
                    log("Switcher let Command-Tab through.")
                }
                return Unmanaged.passUnretained(event)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.visible {
                    self.move(forward: forward)
                } else {
                    _ = self.begin(forward: forward)
                }
            }
            return nil
        case .commit:
            DispatchQueue.main.async { [weak self] in self?.commit() }
            return Unmanaged.passUnretained(event)
        case .cancel:
            DispatchQueue.main.async { [weak self] in self?.cancel() }
            return nil
        }
    }

    private func note(type: CGEventType, flags: CGEventFlags) {
        stateLock.lock()
        if flags.contains(.maskCommand) {
            commandAt = Date()
        } else if type == .flagsChanged {
            commandAt = .distantPast
        }
        stateLock.unlock()
    }

    private func isVisible() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return visible
    }

    private func setVisible(_ on: Bool) {
        stateLock.lock()
        visible = on
        stateLock.unlock()
    }

    private func begin(forward: Bool) -> Bool {
        readyLock.lock()
        let found = readyItems
        let icons = readyIcons
        readyLock.unlock()
        guard !found.isEmpty, icons.count == found.count else { return false }
        items = found
        selection = initialIndex(forward: forward)
        strip.icons = icons
        let screen = targetScreen()
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let fitted = metrics(count: items.count, maxWidth: visibleFrame.width)
        strip.iconSide = fitted.icon
        strip.spacing = fitted.spacing
        strip.padX = fitted.padX
        let frame = NSRect(
            x: visibleFrame.midX - fitted.width / 2,
            y: visibleFrame.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
        panel.setFrame(frame, display: true)
        strip.frame = panel.contentView?.bounds ?? NSRect(origin: .zero, size: frame.size)
        showSelection()
        strip.needsDisplay = true
        panel.orderFrontRegardless()
        strip.updateTrackingAreas()
        setVisible(true)
        return true
    }

    private func hover(_ index: Int) {
        guard items.indices.contains(index), index != selection else { return }
        selection = index
        showSelection()
    }

    /// Ten or fewer apps use a 148pt icon. The row shrinks to fit the screen.
    private func metrics(count: Int, maxWidth: CGFloat) -> (icon: CGFloat, spacing: CGFloat, padX: CGFloat, width: CGFloat, height: CGFloat) {
        let n = CGFloat(max(count, 1))
        let samples: [(n: CGFloat, icon: CGFloat, spacing: CGFloat)] = [
            (10, 148, 16), (15, 112, 14), (20, 84, 12), (25, 64, 10), (30, 52, 8),
        ]
        var icon = samples[0].icon
        var spacing = samples[0].spacing
        if n >= samples.last!.n {
            icon = samples.last!.icon
            spacing = samples.last!.spacing
        } else if n > samples[0].n {
            for index in 0..<(samples.count - 1) where n >= samples[index].n && n <= samples[index + 1].n {
                let start = samples[index]
                let end = samples[index + 1]
                let t = (n - start.n) / (end.n - start.n)
                icon = start.icon + (end.icon - start.icon) * t
                spacing = start.spacing + (end.spacing - start.spacing) * t
            }
        }
        var padX: CGFloat = 14
        var width = padX * 2 + n * icon + max(0, n - 1) * spacing
        let limit = max(320, maxWidth - 48)
        if width > limit {
            let scale = limit / width
            icon *= scale
            spacing *= scale
            padX *= scale
            width = padX * 2 + n * icon + max(0, n - 1) * spacing
        }
        let height = strip.padTop + icon + strip.padBottom
        return (icon, spacing, padX, width, height)
    }

    private func showSelection() {
        guard items.indices.contains(selection) else { return }
        strip.selection = selection
        strip.needsDisplay = true
    }

    private func click(_ index: Int) {
        guard items.indices.contains(index) else { return }
        selection = index
        strip.selection = index
        NSCursor.arrow.set()
        commit()
    }

    private func move(forward: Bool) {
        guard !items.isEmpty else { return }
        if forward {
            selection = (selection + 1) % items.count
        } else {
            selection = (selection - 1 + items.count) % items.count
        }
        showSelection()
        panel.orderFrontRegardless()
    }

    private func initialIndex(forward: Bool) -> Int {
        guard !items.isEmpty else { return 0 }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let current = items.firstIndex(where: { $0.bundleID == front }) else {
            return forward ? 0 : items.count - 1
        }
        if forward { return (current + 1) % items.count }
        return (current - 1 + items.count) % items.count
    }

    private func commit() {
        guard isVisible() else { return }
        setVisible(false)
        let app = items.indices.contains(selection) ? items[selection].running : nil
        panel.orderOut(nil)
        NSCursor.arrow.set()
        app?.activate(from: .current, options: [])
    }

    private func cancel() {
        guard isVisible() else { return }
        setVisible(false)
        panel.orderOut(nil)
        NSCursor.arrow.set()
    }

    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    private func relaunch() {
        guard !isStopping else { return }
        isStopping = true
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] app, _ in
            DispatchQueue.main.async {
                if app != nil {
                    NSApp.terminate(nil)
                } else {
                    self?.isStopping = false
                    log("Switcher needs a restart to turn on.")
                }
            }
        }
    }

    private func reportBlocked(_ message: String) {
        guard !reportedBlocked else { return }
        reportedBlocked = true
        log(message)
    }

    private func switcherItems() -> [SwitchItem] {
        guard let spaces = spaceApps() else { return [] }
        return spaces.compactMap { space in
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: space.bundleID).first else {
                return nil
            }
            return SwitchItem(bundleID: space.bundleID, url: space.url, label: space.label, running: running)
        }
    }
}

/// Full-screen spaces, left to right. This is the order the Dock and the switcher follow.
private func spaceApps() -> [SpaceApp]? {
    guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]],
          !displays.isEmpty
    else {
        log("Could not read spaces")
        return nil
    }
    let ranked = displays.sorted { fullscreenCount($0) > fullscreenCount($1) }
    guard let display = ranked.first, fullscreenCount(display) > 0 else { return [] }
    let spaces = display["Spaces"] as? [[String: Any]] ?? []
    var apps: [SpaceApp] = []
    var seen = Set<String>()
    for space in spaces {
        guard number(space["type"]) == 4, let pid = pidValue(space["pid"]) else { continue }
        guard let running = NSRunningApplication(processIdentifier: pid),
              let bundleID = running.bundleIdentifier,
              let url = running.bundleURL,
              seen.insert(bundleID).inserted
        else { continue }
        let label = clean(running.localizedName ?? url.deletingPathExtension().lastPathComponent)
        apps.append(SpaceApp(bundleID: bundleID, url: url, label: label))
    }
    return apps
}

private func eventMask(_ type: CGEventType) -> CGEventMask {
    CGEventMask(1) << type.rawValue
}

private func dockTiles() -> [[String: Any]] {
    CFPreferencesCopyAppValue("persistent-apps" as CFString, dockDomain) as? [[String: Any]] ?? []
}

private func tileID(_ tile: [String: Any]) -> String {
    let data = tile["tile-data"] as? [String: Any] ?? [:]
    if let id = data["bundle-identifier"] as? String, !id.isEmpty { return id }
    if let file = data["file-data"] as? [String: Any], let path = file["_CFURLString"] as? String {
        return path
    }
    if let label = data["file-label"] as? String { return "label:\(label)" }
    return tile["tile-type"] as? String ?? "tile"
}

private func fullscreenCount(_ display: [String: Any]) -> Int {
    let spaces = display["Spaces"] as? [[String: Any]] ?? []
    return spaces.filter { number($0["type"]) == 4 }.count
}

private func number(_ value: Any?) -> Int? {
    (value as? NSNumber)?.intValue
}

private func pidValue(_ value: Any?) -> pid_t? {
    guard let number = value as? NSNumber else { return nil }
    let pid = pid_t(number.int32Value)
    return pid > 0 ? pid : nil
}

private func clean(_ label: String) -> String {
    label
        .replacingOccurrences(of: "\u{200E}", with: "")
        .replacingOccurrences(of: "\u{200F}", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    fputs("\(stamp) \(message)\n", stderr)
}

#if SPACE_DOCK_TEST
private func runSwitcherChecks() {
    func check(_ decision: TapDecision, _ type: CGEventType, _ key: Int64, _ flags: CGEventFlags, _ visible: Bool, _ name: String) {
        let got = decideSwitch(type: type, keyCode: key, flags: flags, visible: visible)
        if got != decision {
            fputs("fail \(name): \(got) != \(decision)\n", stderr)
            exit(1)
        }
    }
    let command: CGEventFlags = .maskCommand
    let commandShift: CGEventFlags = [.maskCommand, .maskShift]
    let commandOption: CGEventFlags = [.maskCommand, .maskAlternate]
    let commandControl: CGEventFlags = [.maskCommand, .maskControl]
    check(.open(forward: true), .keyDown, 48, command, false, "open")
    check(.open(forward: false), .keyDown, 48, commandShift, false, "open back")
    check(.pass, .keyDown, 48, commandOption, false, "option")
    check(.pass, .keyDown, 48, commandControl, false, "control")
    check(.pass, .keyDown, 48, [], false, "plain tab")
    check(.move(forward: true), .keyDown, 48, command, true, "move")
    check(.move(forward: false), .keyDown, 48, commandShift, true, "move back")
    check(.cancel, .keyDown, 53, command, true, "escape")
    check(.pass, .keyDown, 53, command, false, "escape closed")
    check(.commit, .flagsChanged, 55, [], true, "release")
    check(.pass, .flagsChanged, 55, command, true, "still held")
    check(.pass, .flagsChanged, 56, .maskShift, false, "shift only")
    check(.swallow, .keyUp, 48, command, true, "tab up")
    check(.pass, .keyUp, 48, command, false, "tab up closed")
    check(.swallow, .keyDown, 12, command, true, "other key")
    check(.move(forward: true), .keyDown, 124, command, true, "right")
    check(.move(forward: false), .keyDown, 123, command, true, "left")
    check(.pass, .keyDown, 123, command, false, "left closed")
    fputs("switcher checks ok\n", stdout)
}
#endif
