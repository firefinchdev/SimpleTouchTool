import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

// MARK: - Settings

enum Settings {
    static let defaults = UserDefaults.standard
    static var middleClickEnabled: Bool {
        get { defaults.object(forKey: "middleClick") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "middleClick") }
    }
    static var rightSimpleTouchToolEnabled: Bool {
        get { defaults.object(forKey: "rightSimpleTouchTool") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "rightSimpleTouchTool") }
    }
    static var showMenuBarIcon: Bool {
        get { defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showMenuBarIcon") }
    }
    /// Set once we've made the first-run "start at login" decision, so a later opt-out sticks.
    static var didInitialLoginSetup: Bool {
        get { defaults.bool(forKey: "didInitialLoginSetup") }
        set { defaults.set(newValue, forKey: "didInitialLoginSetup") }
    }
}

// MARK: - Three-finger tap -> middle click

final class ThreeFingerTap {
    static let shared = ThreeFingerTap()

    private let maxTapDuration: Double = 0.30   // seconds
    private let maxTapMovement: Float = 0.04    // normalized trackpad units

    private var devices: [MTDeviceRef] = []
    private var register: MTRegisterContactFrameCallbackFn?
    private var unregister: MTUnregisterContactFrameCallbackFn?
    private var start: MTDeviceStartFn?
    private var stop: MTDeviceStopFn?
    private var createList: MTDeviceCreateListFn?

    // Gesture state (touched only from the multitouch callback thread)
    private var maxFingers = 0
    private var threeStart: Double = 0
    private var threeStartCentroid = MTPoint(x: 0, y: 0)
    private var lastCentroid = MTPoint(x: 0, y: 0)
    private var tracking = false

    private init() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else {
            NSLog("SimpleTouchTool: could not load MultitouchSupport")
            return
        }
        func sym<T>(_ name: String, _: T.Type) -> T? {
            guard let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        createList = sym("MTDeviceCreateList", MTDeviceCreateListFn.self)
        register = sym("MTRegisterContactFrameCallback", MTRegisterContactFrameCallbackFn.self)
        unregister = sym("MTUnregisterContactFrameCallback", MTUnregisterContactFrameCallbackFn.self)
        start = sym("MTDeviceStart", MTDeviceStartFn.self)
        stop = sym("MTDeviceStop", MTDeviceStopFn.self)
    }

    func startListening() {
        stopListening()
        guard let createList, let register, let start,
              let list = createList()?.takeRetainedValue() as NSArray? else { return }
        for case let dev as AnyObject in list {
            let ref = Unmanaged.passUnretained(dev).toOpaque()
            register(ref, threeFingerCallback)
            start(ref, 0)
            devices.append(ref)
        }
        // Keep the device objects alive for as long as we use them.
        retainedList = list
    }

    func stopListening() {
        for ref in devices {
            unregister?(ref, threeFingerCallback)
            stop?(ref)
        }
        devices.removeAll()
        retainedList = nil
    }

    private var retainedList: NSArray?

    fileprivate func handle(_ touches: UnsafePointer<MTTouch>?, count: Int, timestamp: Double) {
        if count == 0 {
            if tracking, maxFingers == 3,
               timestamp - threeStart <= maxTapDuration,
               distance(threeStartCentroid, lastCentroid) <= maxTapMovement {
                DispatchQueue.main.async { postMiddleClick() }
            }
            tracking = false
            maxFingers = 0
            return
        }

        let centroid = Self.centroid(touches, count)
        if count > maxFingers {
            maxFingers = count
            if count == 3 {
                tracking = true
                threeStart = timestamp
                threeStartCentroid = centroid
            } else if count > 3 {
                tracking = false
            }
        }
        if count == 3 { lastCentroid = centroid }
        if tracking, timestamp - threeStart > maxTapDuration { tracking = false }
    }

    private static func centroid(_ t: UnsafePointer<MTTouch>?, _ n: Int) -> MTPoint {
        guard let t, n > 0 else { return MTPoint(x: 0, y: 0) }
        var x: Float = 0, y: Float = 0
        for i in 0..<n { x += t[i].normalized.position.x; y += t[i].normalized.position.y }
        return MTPoint(x: x / Float(n), y: y / Float(n))
    }

    private func distance(_ a: MTPoint, _ b: MTPoint) -> Float {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

private let threeFingerCallback: MTContactCallback = { _, touches, count, timestamp, _ in
    if Settings.middleClickEnabled {
        ThreeFingerTap.shared.handle(touches, count: Int(count), timestamp: timestamp)
    }
    return 0
}

private func postMiddleClick() {
    let loc = CGEvent(source: nil)?.location ?? .zero
    let src = CGEventSource(stateID: .hidSystemState)
    for type in [CGEventType.otherMouseDown, .otherMouseUp] {
        let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: loc, mouseButton: .center)
        e?.setIntegerValueField(.mouseEventClickState, value: 1)
        e?.post(tap: .cghidEventTap)
    }
}

// MARK: - Right click on a window's red close button -> quit that app

enum RightSimpleTouchTool {
    static let excludedBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.Spotlight",
        "com.apple.loginwindow",
        "com.apple.WindowManager",
        "com.apple.wallpaper.agent",
        "com.apple.screencaptureui",
        "com.apple.TextInputMenuAgent",
    ]

    fileprivate static var tap: CFMachPort?
    fileprivate static var swallowNextRightUp = false

    static func install() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.rightMouseUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                           callback: rightClickCallback, userInfo: nil) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        return true
    }

    private static let systemWide: AXUIElement = {
        let e = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(e, 0.25)   // never stall the event tap for long
        return e
    }()

    /// The app owning the red close button under `point`, if it is allowed to be quit.
    /// Uses Accessibility hit-testing, which ignores click-through overlays
    /// (e.g. the Dock's invisible full-screen window).
    static func quittableApp(at point: CGPoint) -> NSRunningApplication? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let element = hit, isCloseButton(element) else { return nil }

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular,
              app.processIdentifier != getpid(),
              let bid = app.bundleIdentifier,
              !excludedBundleIDs.contains(bid) else { return nil }
        return app
    }

    private static func isCloseButton(_ element: AXUIElement) -> Bool {
        var el: AXUIElement? = element
        for _ in 0..<3 {   // the hit may land on a child of the button
            guard let e = el else { return false }
            if (attribute(e, kAXSubroleAttribute) as String?) == kAXCloseButtonSubrole { return true }
            el = attribute(e, kAXParentAttribute)
        }
        return false
    }

    private static func attribute<T>(_ e: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}

private let rightClickCallback: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let tap = RightSimpleTouchTool.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    case .rightMouseDown:
        guard Settings.rightSimpleTouchToolEnabled,
              let app = RightSimpleTouchTool.quittableApp(at: event.location) else { break }
        RightSimpleTouchTool.swallowNextRightUp = true
        DispatchQueue.main.async { app.terminate() }
        return nil
    case .rightMouseUp:
        if RightSimpleTouchTool.swallowNextRightUp {
            RightSimpleTouchTool.swallowNextRightUp = false
            return nil
        }
    default: break
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - Shared state (menu bar + settings window)

final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var middleClick = Settings.middleClickEnabled {
        didSet { Settings.middleClickEnabled = middleClick }
    }
    @Published var closeButtonQuit = Settings.rightSimpleTouchToolEnabled {
        didSet { Settings.rightSimpleTouchToolEnabled = closeButtonQuit }
    }
    @Published var showMenuBarIcon = Settings.showMenuBarIcon {
        didSet { Settings.showMenuBarIcon = showMenuBarIcon; onMenuBarIconChange?() }
    }
    @Published private(set) var loginStatus = SMAppService.mainApp.status
    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()

    var onMenuBarIconChange: (() -> Void)?

    var startAtLogin: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    func setStartAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } else {
                try service.unregister()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change login item"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refresh()
    }

    func refresh() {
        loginStatus = SMAppService.mainApp.status
        accessibilityTrusted = AXIsProcessTrusted()
    }
}

func openAccessibilitySettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var model = AppModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !model.accessibilityTrusted {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text("SimpleTouchTool needs Accessibility permission to work.")
                    Spacer()
                    Button("Open Settings…") { openAccessibilitySettings() }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.15)))
            }

            GroupBox("Gestures") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Three-finger tap performs a middle click", isOn: $model.middleClick)
                    Toggle("Right-click a window's red close button to quit the app", isOn: $model.closeButtonQuit)
                    Text("Finder, the Dock and other system apps are never quit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox("General") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Start at login", isOn: Binding(get: { model.startAtLogin },
                                                           set: { model.setStartAtLogin($0) }))
                    if model.loginStatus == .requiresApproval {
                        Text("Approve SimpleTouchTool in System Settings → General → Login Items.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Show icon in menu bar", isOn: $model.showMenuBarIcon)
                    if !model.showMenuBarIcon {
                        Text("Open SimpleTouchTool again (e.g. from Applications or Spotlight) to get back to this window.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            HStack {
                Spacer()
                Button("Quit SimpleTouchTool") { NSApp.terminate(nil) }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { model.refresh() }
    }
}

// MARK: - App / menu bar

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel.shared
    private var statusItem: NSStatusItem!
    private var middleItem: NSMenuItem!
    private var quitItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var permissionTimer: Timer?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        // Must be read here, while the launch Apple Event is still current.
        let launchedAtLogin = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        let openedByUser = NSAppleEventManager.shared().currentAppleEvent != nil && !launchedAtLogin

        if !Settings.didInitialLoginSetup {
            Settings.didInitialLoginSetup = true
            try? SMAppService.mainApp.register()
            model.refresh()
        }

        setUpStatusItem()
        model.onMenuBarIconChange = { [weak self] in
            self?.statusItem.isVisible = self?.model.showMenuBarIcon ?? true
        }

        ThreeFingerTap.shared.startListening()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            // Trackpad devices are re-created after sleep.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ThreeFingerTap.shared.startListening() }
        }

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            if AXIsProcessTrusted() && RightSimpleTouchTool.install() {
                t.invalidate()
                self?.model.refresh()
            }
        }
        permissionTimer?.fire()

        if openedByUser || !model.showMenuBarIcon && !launchedAtLogin {
            showSettings()
        }
    }

    /// Opening the app again while it's running (Finder, Spotlight, Dock) shows the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: "SimpleTouchTool")
        statusItem.isVisible = model.showMenuBarIcon

        let menu = NSMenu()
        menu.delegate = self
        permissionItem = NSMenuItem(title: "⚠️ Grant Accessibility permission…", action: #selector(openAccessibility), keyEquivalent: "")
        menu.addItem(permissionItem)
        middleItem = NSMenuItem(title: "3-finger tap → Middle click", action: #selector(toggleMiddle), keyEquivalent: "")
        menu.addItem(middleItem)
        quitItem = NSMenuItem(title: "Right click red close button → Quit app", action: #selector(toggleQuit), keyEquivalent: "")
        menu.addItem(quitItem)
        menu.addItem(.separator())
        loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Hide Menu Bar Icon", action: #selector(hideIcon), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit SimpleTouchTool", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.refresh()
        permissionItem.isHidden = model.accessibilityTrusted
        middleItem.state = model.middleClick ? .on : .off
        quitItem.state = model.closeButtonQuit ? .on : .off
        switch model.loginStatus {
        case .enabled: loginItem.state = .on
        case .requiresApproval: loginItem.state = .mixed
        default: loginItem.state = .off
        }
    }

    @objc private func toggleMiddle() { model.middleClick.toggle() }
    @objc private func toggleQuit() { model.closeButtonQuit.toggle() }
    @objc private func toggleLogin() { model.setStartAtLogin(!model.startAtLogin) }
    @objc private func openAccessibility() { openAccessibilitySettings() }
    @objc private func openSettings() { showSettings() }

    @objc private func hideIcon() {
        let alert = NSAlert()
        alert.messageText = "Hide the menu bar icon?"
        alert.informativeText = "SimpleTouchTool keeps running. Open SimpleTouchTool again (from Applications or Spotlight) to show its settings window."
        alert.addButton(withTitle: "Hide")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { model.showMenuBarIcon = false }
    }

    private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "SimpleTouchTool"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
