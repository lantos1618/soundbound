import AppKit
import SwiftUI
import SoundboundKit

struct DesktopHubView: View {
    @ObservedObject var store: HubStore
    @ObservedObject var audio: SoundModel
    var body: some View {
        SoundboundRootView(store: store, localAudioDevices: audio.localAudioDevices, audioMessage: audio.message,
            onAudioAction: { audio.perform($0, id: $1) }, onAudioVolume: { audio.setVolume($0, level: $1) })
    }
}

struct DeviceIcon: View {
    var phone = false
    var body: some View {
        Image(systemName: phone ? "iphone" : "laptopcomputer")
            .resizable().scaledToFit()
            .frame(width: phone ? 18 : 34, height: phone ? 30 : 25)
            .frame(width: 44, height: 44)
            .accessibilityLabel(phone ? "iPhone" : "Mac")
    }
}

struct SetupStep: View {
    let number: Int
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .foregroundStyle(.secondary)
                .frame(width: 13, alignment: .trailing)
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SetupDevice: View {
    let phone: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                DeviceIcon(phone: phone)
                Text(phone ? "On your iPhone" : "On your Mac")
                    .font(.system(size: 14, weight: .medium))
            }
            if phone {
                SetupStep(number: 1, text: "Open Settings on your iPhone.")
                SetupStep(number: 2, text: "Tap your AirPods near the top.")
                SetupStep(number: 3, text: "Tap ‘Connect to This iPhone’, then choose ‘When Last Connected to This iPhone’.")
            } else {
                SetupStep(number: 1, text: "Click ‘Open Mac settings’ below.")
                SetupStep(number: 2, text: "Click the info button ⓘ beside your AirPods.")
                SetupStep(number: 3, text: "Find ‘Connect to This Mac’ and choose ‘When Last Connected to This Mac’.")
            }
        }
    }
}

struct PossessionButton: View {
    let phone: Bool
    let title: String
    let detail: String
    var selected = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                DeviceIcon(phone: phone)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .medium))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .medium)) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(selected ? 0.07 : 0.03))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct MenuView: View {
    @ObservedObject var model: SoundModel
    var maximumHeight: CGFloat = 560
    var onHeightChange: (CGFloat) -> Void = { _ in }
    @AppStorage("manualSetupAcknowledged") private var setupAcknowledged = false
    @State private var showSetup = false
    private var height: CGFloat { min(showSetup ? 560 : 470, maximumHeight) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("soundbound").font(.system(size: 19, weight: .medium, design: .rounded))
                Spacer()
                if showSetup {
                    Button("Done") { showSetup = false }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                } else {
                    Text("SOUND STAYS HERE").font(.system(size: 8, weight: .medium)).tracking(1.1).foregroundStyle(.secondary)
                }
            }
            if showSetup {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Setup").font(.system(size: 17, weight: .medium))
                        Text("Choose your headphones")
                            .font(.system(size: 12, weight: .medium))
                        if model.paired.isEmpty {
                            ForEach(model.outputs.filter { $0.bluetooth }) { output in
                                Button { model.track(output) } label: {
                                    HStack {
                                        Text(output.name)
                                        Spacer()
                                        if model.targetOutput?.uid == output.uid { Image(systemName: "checkmark") }
                                    }
                                }.disabled(model.busy)
                            }
                            if !model.hasHeadphones {
                                Text("Connect your AirPods in Bluetooth settings first, then reopen this menu.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        } else {
                            ForEach(model.paired, id: \.addressString) { device in
                                Button { model.track(device) } label: {
                                    HStack {
                                        Text(device.name ?? "Headphones")
                                        Spacer()
                                        if model.isTracked(device) { Image(systemName: "checkmark") }
                                    }.padding(.vertical, 4)
                                }.buttonStyle(.plain).disabled(model.busy)
                            }
                        }
                        Divider()
                        Text("Stop surprise switches")
                            .font(.system(size: 15, weight: .medium))
                        Text("Do this once on both devices. Put your AirPods in your ears and connect them to the device you’re setting up.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        SetupDevice(phone: false)
                        Button("Open Mac settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
                        }
                        SetupDevice(phone: true)
                        Text("If you see ‘Audio & Routing’, open it to find the setting.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Button(setupAcknowledged ? "Settings marked as done ✓" : "I’ve changed both settings") {
                            setupAcknowledged = true
                        }
                        Divider()
                        Toggle("Tell me when headphones leave this Mac", isOn: $model.quietPrompts)
                            .font(.system(size: 12)).toggleStyle(.switch).controlSize(.mini)
                        Text("Soundbound can connect and release headphones on this Mac. To connect them to iPhone, open Control Center on your phone, tap AirPlay, then choose your AirPods.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.headphoneName).font(.system(size: 18, weight: .medium)).lineLimit(1)
                    HStack(spacing: 6) {
                        Circle().fill(model.hasVerifiedSound ? Color.green : Color.secondary).frame(width: 5, height: 5)
                        Text(model.ownershipDescription).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                VStack(spacing: 8) {
                    PossessionButton(phone: false, title: "Use on this Mac", detail: model.hasVerifiedSound ? "Sound test passed" : "Request connection · then verify", selected: model.hasVerifiedSound) {
                        model.useOnMac()
                    }
                    PossessionButton(phone: true, title: "Release for iPhone", detail: "Disconnect from this Mac") {
                        model.releaseForPhone()
                    }
                }.disabled(model.busy || !model.hasHeadphones)
                if model.connectionCheck.phase == .awaitingAnswer {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Did you hear it through your AirPods?").font(.system(size: 12, weight: .medium))
                        HStack {
                            Button("Yes, in my AirPods") { model.confirmSound(heard: true) }
                            Button("No") { model.confirmSound(heard: false) }
                        }.font(.system(size: 11))
                    }
                } else {
                    Button("Test connection") { model.testSound() }
                        .font(.system(size: 12)).disabled(model.busy || !model.hasHeadphones)
                        .help("Plays a short sound through the selected headphones. Confirm you heard it before a checkmark appears.")
                }
                if let message = model.message {
                    Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.busy { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                HStack {
                    Button("Setup") { showSetup = true }
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .frame(width: 340, height: height)
        .onChange(of: showSetup) { _ in onHeightChange(height) }
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = SoundModel()
    private let hub = HubStore()
    private var hubWindow: NSWindow?
    private var item: NSStatusItem!
    private let popover = NSPopover()
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
        item.button?.target = self
        item.button?.action = #selector(showHub)
        popover.behavior = .transient
        popover.animates = false
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
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Soundbound"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: DesktopHubView(store: hub, audio: model))
            window.center()
            hubWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        hubWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleMenu() {
        if popover.isShown { popover.performClose(nil) }
        else { showMenu() }
    }

    private func showMenu() {
        model.refresh()
        guard let button = item.button,
              let screen = button.window?.screen ?? NSScreen.main else { return }
        // Constrain the hosted content before asking AppKit to position it.
        // The old unconstrained content could exceed the usable screen height.
        let maximumHeight = min(CGFloat(560), screen.visibleFrame.height - 48)
        let height = min(CGFloat(470), maximumHeight)
        let controller = NSHostingController(rootView: MenuView(model: model, maximumHeight: maximumHeight) { [weak self] height in
            self?.popover.contentSize = NSSize(width: 340, height: height)
        })
        controller.preferredContentSize = NSSize(width: 340, height: height)
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 340, height: height)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
            if self?.popover.isShown != true { self?.showMenu() }
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
