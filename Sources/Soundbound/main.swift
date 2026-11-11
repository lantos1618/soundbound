import AppKit
import SwiftUI
import SoundboundKit

struct DesktopHubView: View {
    @ObservedObject var store: HubStore
    @ObservedObject var audio: SoundModel
    var body: some View {
        SoundboundRootView(store: store, localAudioDevices: audio.localAudioDevices, audioMessage: audio.message,
            onAudioAction: { audio.perform($0, id: $1) }, onAudioVolume: { audio.setVolume($0, level: $1) })
            .onAppear { audio.onError = { store.notice = $0 }; audio.onTestStarted = { store.activity.chirp($0); store.activity.chirp(store.deviceID) }; audio.onTestFrame = { store.activity.updateLevel($0, pcm: $1) } }
    }
}

struct ToastView: View {
    let name: String
    let reconnect: () -> Void
    @State private var elapsed = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer").font(.system(size: 20, weight: .light))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Headphones left this Mac").font(.system(size: 13, weight: .medium))
                    Text(name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("Reconnect", action: reconnect).font(.system(size: 11)).buttonStyle(.borderless)
            }.padding(18)
            GeometryReader { proxy in
                Rectangle().fill(Color.primary.opacity(0.35)).frame(width: elapsed ? 0 : proxy.size.width)
            }.frame(height: 2)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(8)
        .onAppear { withAnimation(.linear(duration: 1)) { elapsed = true } }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = SoundModel()
    private let hub = HubStore()
    private let mixer = AppMixer()
    private let quickPopover = NSPopover()
    private var hubWindow: NSWindow?
    private var item: NSStatusItem!
    private let quickMenu = NSMenu()
    private var quickHeadphoneID: String?
    private var toast: NSPanel?
    private var dismissal: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installApplicationMenu()
        hub.onAudioNotice = { [weak self] message in
            guard let self, !(NSApp.isActive && self.hubWindow?.isVisible == true) else { return }
            self.showEventToast(message)
        }
        item = NSStatusBar.system.statusItem(withLength: 30)
        let mark = Bundle.main.url(forResource: "SoundboundMark", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) } ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Soundbound")!
        mark.size = NSSize(width: 24, height: 20)
        mark.isTemplate = true
        item.button?.image = mark
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleNone
        item.button?.setAccessibilityLabel("Soundbound")
        item.button?.toolTip = "Soundbound — sound stays here"
        quickMenu.delegate = self
        quickMenu.autoenablesItems = false
        item.button?.target = self
        item.button?.action = #selector(toggleMenu)
        quickPopover.behavior = .transient
        quickPopover.animates = true
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        DispatchQueue.main.async { [weak self] in self?.showHub() }
    }

    private func installApplicationMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(title: "Soundbound", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Soundbound")
        let about = NSMenuItem(title: "About Soundbound", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        about.target = NSApp
        appMenu.addItem(about)
        let quick = NSMenuItem(title: "Quick controls", action: #selector(toggleMenu), keyEquivalent: "m")
        quick.keyEquivalentModifierMask = [.command, .shift]
        quick.target = self
        appMenu.addItem(quick)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Soundbound", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: key))
        }
        editItem.submenu = edit; main.addItem(editItem)
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = window; main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    @objc private func woke() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.model.refresh() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showHub()
        return true
    }

    @objc private func showHub() {
        if hubWindow == nil {
            let available = (NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 1080))
            let size = NSSize(width: min(1180, available.width * 0.92), height: min(960, available.height * 0.92))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Soundbound"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: DesktopHubView(store: hub, audio: model))
            if !window.setFrameUsingName("SoundboundMainWindow.v2") { window.center() }
            window.setFrameAutosaveName("SoundboundMainWindow.v2")
            hubWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        hubWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleMenu() { DispatchQueue.main.async { [weak self] in self?.showMenu() } }

    private var quickHeadphones: [LocalAudioDevice] { model.localAudioDevices.filter { $0.connection == .bluetooth } }
    private var quickHeadphone: LocalAudioDevice? { quickHeadphones.first { $0.id == quickHeadphoneID } ?? quickHeadphones.first }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === quickMenu else { return }
        model.refresh()
        quickMenu.removeAllItems()
        func add(_ title: String, _ action: Selector? = nil, value: String? = nil, enabled: Bool = true, checked: Bool = false) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.representedObject = value; item.isEnabled = enabled
            item.state = checked ? .on : .off
            quickMenu.addItem(item)
            return item
        }
        if let headphone = quickHeadphone {
            if quickHeadphones.count > 1 {
                let selector = add(headphone.name)
                let choices = NSMenu()
                for device in quickHeadphones {
                    let choice = NSMenuItem(title: device.name, action: #selector(selectQuickHeadphone(_:)), keyEquivalent: "")
                    choice.target = self; choice.representedObject = device.id
                    choice.state = device.id == headphone.id ? .on : .off
                    choices.addItem(choice)
                }
                selector.submenu = choices
            } else { _ = add(headphone.name, enabled: false) }
            _ = add(headphone.status, enabled: false)
            quickMenu.addItem(.separator())
            _ = add("Use on " + hub.name, #selector(quickDestination(_:)), value: hub.deviceID, enabled: !headphone.busy, checked: headphone.selectedOutput)
            for peer in hub.friends {
                let online = hub.nearby.contains { $0.id == peer.id }
                _ = add("Request on " + peer.card.name + (online ? "" : " (offline)"), #selector(quickDestination(_:)), value: peer.id, enabled: online && !headphone.busy)
            }
            let roomItem = add("Rooms")
            let roomMenu = NSMenu()
            for room in hub.rooms {
                let choice = NSMenuItem(title: room.name, action: #selector(quickRoom(_:)), keyEquivalent: "")
                choice.target = self; choice.representedObject = room.id
                choice.state = hub.audioMemberships[headphone.id]?.contains(room.id) == true ? .on : .off
                choice.isEnabled = room.owner == hub.deviceID
                roomMenu.addItem(choice)
            }
            if !hub.rooms.isEmpty { roomMenu.addItem(.separator()) }
            let setup = NSMenuItem(title: "Room setup…", action: #selector(showHub), keyEquivalent: "")
            setup.target = self; roomMenu.addItem(setup)
            roomItem.submenu = roomMenu
        } else {
            _ = add("No headphones found", enabled: false)
            _ = add("Bluetooth settings…", #selector(openBluetoothSettings))
        }
        quickMenu.addItem(.separator())
        _ = add("Open Soundbound", #selector(showHub))
        _ = add("Quit Soundbound", #selector(quitSoundbound))
    }
    @objc private func selectQuickHeadphone(_ sender: NSMenuItem) { quickHeadphoneID = sender.representedObject as? String }
    @objc private func quickDestination(_ sender: NSMenuItem) {
        guard let headphone = quickHeadphone, let host = sender.representedObject as? String else { return }
        if host == hub.deviceID { model.perform(.connect, id: headphone.id) }
        else { hub.requestDeviceMove(headphone, to: host, from: hub.name) }
    }
    @objc private func quickRoom(_ sender: NSMenuItem) {
        guard let headphone = quickHeadphone, let room = sender.representedObject as? String else { return }
        if hub.audioMemberships[headphone.id]?.contains(room) == true { hub.removeAudioDevice(headphone.id, from: room) }
        else { hub.moveAudioDevice(headphone.id, to: room) }
    }
    @objc private func openBluetoothSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!) }
    @objc private func quitSoundbound() { NSApp.terminate(nil) }
    private func showMenu() {
        if quickPopover.isShown { quickPopover.performClose(nil); return }
        guard let button = item.button else { return }
        model.refresh(); mixer.refresh()
        quickPopover.contentViewController = NSHostingController(rootView: QuickControls(store: hub, audio: model, mixer: mixer,
            openApp: { [weak self] in self?.quickPopover.performClose(nil); self?.showHub() },
            quit: { NSApp.terminate(nil) }))
        quickPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func showEventToast(_ message: String) {
        dismissal?.cancel(); toast?.orderOut(nil)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 74),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView:
            Label(message, systemImage: "waveform")
                .font(.system(size: 14)).padding(16).frame(width: 380, height: 74)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)))
        if let frame = (item.button?.window?.screen ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 396, y: frame.maxY - 100))
        }
        panel.orderFrontRegardless(); toast = panel
        let work = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func showToast(_ name: String) {
        dismissal?.cancel()
        toast?.orderOut(nil)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 88), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ToastView(name: name) { [weak self] in
            self?.dismissal?.cancel()
            self?.toast?.orderOut(nil)
            self?.model.reconnect()
            self?.showMenu()
        })
        let screen = item.button?.window?.screen ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 396, y: frame.maxY - 104))
        }
        panel.orderFrontRegardless()
        toast = panel
        let work = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}

if CommandLine.arguments.contains("--diagnostics") {
    let outputs = Audio.outputs()
    print("Soundbound audio diagnostics")
    for output in outputs {
        print("\(output.id == Audio.current ? "*" : " ") \(output.name) [\(output.bluetooth ? "Bluetooth" : "local/other")]")
    }
    if outputs.isEmpty { print("No audio outputs available.") }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
