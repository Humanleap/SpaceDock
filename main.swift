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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var apps: [SpaceApp] = []
    private var pending: [String] = []
    private var pendingSince: Date?
    private var busyUntil = Date.distantPast
    private var failedApplies = 0
    private let switcher = Switcher()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "Spaces")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Dock follows your spaces"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        let timer = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in
            self?.tick(force: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        switcher.start()
        tick(force: false)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let heading = NSMenuItem(title: "Dock follows your spaces", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        if !switcher.isOn {
            let allow = NSMenuItem(title: "Allow the app switcher", action: #selector(allowSwitcher), keyEquivalent: "")
            allow.target = self
            menu.addItem(allow)
        }
        if apps.isEmpty {
            let none = NSMenuItem(title: "No full-screen apps", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for (index, app) in apps.enumerated() {
                let item = NSMenuItem(title: "\(index + 1)  \(app.label)", action: #selector(openApp(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = app.bundleID
                menu.addItem(item)
            }
        }
        if !pending.isEmpty {
            let updating = NSMenuItem(title: "Updating the Dock…", action: nil, keyEquivalent: "")
            updating.isEnabled = false
            menu.addItem(updating)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func allowSwitcher() {
        switcher.prompt()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func openApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return }
        app.activate(from: .current, options: [])
    }

    private func tick(force: Bool) {
        guard !switcher.isStopping else { return }
        switcher.installIfNeeded()
        switcher.recover()
        guard Date() >= busyUntil else { return }
        guard let spaces = fullscreenApps() else { return }
        apps = spaces

        let current = dockTiles()
        var added = Set(UserDefaults.standard.stringArray(forKey: addedKey) ?? [])
        let desired = arrangedTiles(current: current, spaces: spaces, added: &added)
        let wanted = desired.map(tileID)
        let have = current.map(tileID)
        // static-only makes the Dock ignore pinned order and show apps in the order they were opened.
        let hidesPinOrder = (CFPreferencesCopyAppValue("static-only" as CFString, dockDomain) as? Bool) == true
        if wanted == have && !hidesPinOrder {
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

    /// Full-screen spaces, left to right, on the display that has the most of them.
    private func fullscreenApps() -> [SpaceApp]? {
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

    private func arrangedTiles(current: [[String: Any]], spaces: [SpaceApp], added: inout Set<String>) -> [[String: Any]] {
        let sample = current.first { ($0["tile-type"] as? String) == "file-tile" }
        var byID: [String: [String: Any]] = [:]
        for tile in current {
            let id = tileID(tile)
            if byID[id] == nil { byID[id] = tile }
        }
        var result: [[String: Any]] = []
        var seen = Set<String>()
        for app in spaces where seen.insert(app.bundleID).inserted {
            if let tile = byID[app.bundleID] {
                result.append(tile)
            } else {
                result.append(makeTile(like: sample, app: app))
                added.insert(app.bundleID)
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

    private func makeTile(like sample: [String: Any]?, app: SpaceApp) -> [String: Any] {
        var tile = sample ?? ["tile-type": "file-tile"]
        var data = tile["tile-data"] as? [String: Any] ?? [:]
        var url = app.url
        if !url.hasDirectoryPath {
            url = URL(fileURLWithPath: url.path, isDirectory: true)
        }
        data["bundle-identifier"] = app.bundleID
        data["file-label"] = app.label
        data["file-type"] = 1
        data["dock-extra"] = false
        data["is-beta"] = false
        data["file-data"] = [
            "_CFURLString": url.absoluteString,
            "_CFURLStringType": 15,
        ]
        if let book = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            data["book"] = book
        }
        tile["tile-data"] = data
        tile["tile-type"] = "file-tile"
        return tile
    }
}

private final class StripView: NSView {
    var names: [String] = []
    var icons: [NSImage] = []
    var selection = 0
    var cellWidth: CGFloat = 96

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.16).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 22, yRadius: 22)
        border.lineWidth = 1
        border.stroke()

        let iconCenterY = bounds.height - 43
        for index in names.indices {
            let selected = index == selection
            let rect = NSRect(x: 8 + cellWidth * CGFloat(index), y: 0, width: cellWidth, height: bounds.height)
            let iconSize: CGFloat = selected ? 62 : 52
            let iconRect = NSRect(
                x: rect.midX - iconSize / 2,
                y: iconCenterY - iconSize / 2,
                width: iconSize,
                height: iconSize
            )
            if selected {
                NSColor.white.withAlphaComponent(0.2).setFill()
                NSBezierPath(roundedRect: iconRect.insetBy(dx: -10, dy: -10), xRadius: 16, yRadius: 16).fill()
            }
            icons[index].draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: selected ? 1 : 0.92)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let nameRect = NSRect(x: rect.minX + 2, y: 10, width: rect.width - 4, height: 16)
            names[index].draw(in: nameRect, withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(selected ? 1 : 0.78),
                .paragraphStyle: paragraph,
            ])
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
    private var wasTrusted = AXIsProcessTrusted()

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 124),
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
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 22
        effect.layer?.masksToBounds = true
        panel.contentView = effect
        strip.frame = effect.bounds
        strip.autoresizingMask = [.width, .height]
        effect.addSubview(strip)
        Switcher.shared = self
    }

    func start() {
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
        if isOn || isStopping { return }
        let trusted = AXIsProcessTrusted()
        if trusted && !wasTrusted {
            wasTrusted = true
            relaunch()
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
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        self.source = source
        isOn = true
        let found = switcherItems()
        let whereFrom = found.fromDock ? "the Dock" : "pinned apps"
        log("Switcher on, from \(whereFrom). Order: \(found.items.map(\.label).joined(separator: ", "))")
    }

    func recover() {
        guard visible else { return }
        if !CGEventSource.flagsState(.hidSystemState).contains(.maskCommand) {
            commit()
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        switch decideSwitch(type: type, keyCode: keyCode, flags: event.flags, visible: visible) {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        case .open(let forward):
            return begin(forward: forward) ? nil : Unmanaged.passUnretained(event)
        case .move(let forward):
            move(forward: forward)
            return nil
        case .commit:
            commit()
            return Unmanaged.passUnretained(event)
        case .cancel:
            cancel()
            return nil
        }
    }

    private func begin(forward: Bool) -> Bool {
        let found = switcherItems()
        guard !found.items.isEmpty else { return false }
        items = found.items
        selection = initialIndex(forward: forward)
        strip.names = items.map(\.label)
        strip.icons = items.map { NSWorkspace.shared.icon(forFile: $0.url.path) }
        strip.selection = selection
        let screen = targetScreen()
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let count = CGFloat(items.count)
        var cell: CGFloat = 96
        let chrome: CGFloat = 16
        if chrome + cell * count > visibleFrame.width - 48 {
            cell = max(68, (visibleFrame.width - 48 - chrome) / count)
        }
        strip.cellWidth = cell
        let width = chrome + cell * count
        let height: CGFloat = 124
        let frame = NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        )
        panel.setFrame(frame, display: true)
        strip.frame = panel.contentView?.bounds ?? NSRect(origin: .zero, size: frame.size)
        strip.needsDisplay = true
        panel.orderFrontRegardless()
        visible = true
        return true
    }

    private func move(forward: Bool) {
        guard !items.isEmpty else { return }
        if forward {
            selection = (selection + 1) % items.count
        } else {
            selection = (selection - 1 + items.count) % items.count
        }
        strip.selection = selection
        strip.needsDisplay = true
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
        guard visible else { return }
        visible = false
        let app = items.indices.contains(selection) ? items[selection].running : nil
        panel.orderOut(nil)
        app?.activate(from: .current, options: [])
    }

    private func cancel() {
        guard visible else { return }
        visible = false
        panel.orderOut(nil)
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

    private func switcherItems() -> (items: [SwitchItem], fromDock: Bool) {
        if let dock = dockApplicationItems(), !dock.isEmpty {
            return (dock, true)
        }
        return (pinnedRunningApps(), false)
    }

    /// Application icons on the Dock, in the order they are drawn.
    private func dockApplicationItems() -> [SwitchItem]? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let application = AXUIElementCreateApplication(dock.processIdentifier)
        let icons = axDockItems(application, depth: 0).filter {
            axString($0, kAXSubroleAttribute) == "AXApplicationDockItem"
        }
        guard !icons.isEmpty else { return nil }
        let orientation = (CFPreferencesCopyAppValue("orientation" as CFString, dockDomain) as? String) ?? "bottom"
        let vertical = orientation == "left" || orientation == "right"
        var ranked: [(point: CGPoint, item: SwitchItem)] = []
        var seen = Set<String>()
        for icon in icons {
            guard let url = axURL(icon),
                  let running = runningApp(at: url),
                  let bundleID = running.bundleIdentifier,
                  seen.insert(bundleID).inserted
            else { continue }
            let fallback = clean(running.localizedName ?? url.deletingPathExtension().lastPathComponent)
            let label = clean(axString(icon, kAXTitleAttribute) ?? fallback)
            let point = axPoint(icon) ?? .zero
            ranked.append((point, SwitchItem(bundleID: bundleID, url: url, label: label, running: running)))
        }
        guard !ranked.isEmpty else { return nil }
        if ranked.contains(where: { axMissing($0.point) }) {
            return ranked.map(\.item)
        }
        ranked.sort { vertical ? $0.point.y < $1.point.y : $0.point.x < $1.point.x }
        return ranked.map(\.item)
    }

    private func pinnedRunningApps() -> [SwitchItem] {
        var items: [SwitchItem] = []
        var seen = Set<String>()
        func add(_ app: NSRunningApplication) {
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  let url = app.bundleURL,
                  seen.insert(bundleID).inserted
            else { return }
            let label = clean(app.localizedName ?? url.deletingPathExtension().lastPathComponent)
            items.append(SwitchItem(bundleID: bundleID, url: url, label: label, running: app))
        }
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").forEach(add)
        for tile in dockTiles() {
            NSRunningApplication.runningApplications(withBundleIdentifier: tileID(tile)).forEach(add)
        }
        let others = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
        others.forEach(add)
        return items
    }
}

private func axMissing(_ point: CGPoint) -> Bool {
    point == .zero
}

private func axDockItems(_ element: AXUIElement, depth: Int) -> [AXUIElement] {
    guard depth <= 4 else { return [] }
    var found: [AXUIElement] = []
    for child in axChildren(element) {
        if axString(child, kAXRoleAttribute) == "AXDockItem" {
            found.append(child)
        } else {
            found.append(contentsOf: axDockItems(child, depth: depth + 1))
        }
    }
    return found
}

private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
    return value as? [AXUIElement] ?? []
}

private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
    if let string = value as? String { return string }
    if let url = value as? URL { return url.absoluteString }
    return nil
}

private func axURL(_ element: AXUIElement) -> URL? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success, let value else { return nil }
    if let url = value as? URL { return url }
    if let string = value as? String { return URL(string: string) }
    return nil
}

private func axPoint(_ element: AXUIElement) -> CGPoint? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
          let value,
          CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
    return point
}

private func runningApp(at url: URL) -> NSRunningApplication? {
    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
    if let bundleID = Bundle(url: url)?.bundleIdentifier,
       let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
        return app
    }
    return NSWorkspace.shared.runningApplications.first {
        $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == path
    }
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
    fputs("switcher checks ok\n", stdout)
}
#endif
