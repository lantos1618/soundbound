import AppKit
import SwiftUI
import SoundboundKit

struct QuickControls: View {
    @ObservedObject var store: HubStore
    @ObservedObject var audio: SoundModel
    @ObservedObject var mixer: AppMixer
    var openApp: () -> Void
    var quit: () -> Void
    @State private var selectedHeadphones = ""
    private var headphones: [LocalAudioDevice] { audio.localAudioDevices.filter { $0.connection == .bluetooth && $0.hasOutput } }
    private var headphone: LocalAudioDevice? { headphones.first { $0.id == selectedHeadphones } ?? headphones.first }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Soundbound").font(.headline)
                Spacer()
                Button(action: openApp) { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Open Soundbound")
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Headphones").font(.subheadline.weight(.semibold))
                        if let headphone {
                            if headphones.count > 1 {
                                Picker("Headphones", selection: $selectedHeadphones) {
                                    ForEach(headphones) { Text($0.name).tag($0.id) }
                                }.labelsHidden()
                            } else { Label(headphone.name, systemImage: "headphones") }
                            if let room = store.activeRoom {
                                Text("Active room: \(room.name)").font(.caption).foregroundStyle(.secondary)
                                Button("Leave room to choose a device") { store.setActiveRoom(nil) }
                            } else {
                                Button { audio.perform(.connect, id: headphone.id) } label: {
                                    HStack { Label(store.name, systemImage: "laptopcomputer"); Spacer(); if headphone.selectedOutput { Image(systemName: "checkmark") } }
                                }.buttonStyle(.plain).padding(.vertical, 4)
                                ForEach(store.friends) { peer in
                                    Button { store.requestDeviceMove(headphone, to: peer.id, from: store.name) } label: {
                                        HStack { Label(peer.card.name, systemImage: peer.card.kind == "mac" ? "laptopcomputer" : "iphone"); Spacer(); Image(systemName: "arrow.right") }
                                    }.buttonStyle(.plain).padding(.vertical, 4)
                                        .disabled(!store.nearby.contains { $0.id == peer.id })
                                }
                            }
                            if let level = headphone.volume {
                                HardwareVolumeRow(device: headphone, initialLevel: level, audio: audio)
                            }
                        } else {
                            Text("Connect headphones to choose where to use them.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Applications").font(.subheadline.weight(.semibold)); Spacer()
                            Button("Reset") { mixer.reset() }.font(.caption).buttonStyle(.plain)
                        }
                        if !mixer.supported { Text("Requires macOS 14.2 or later.").font(.caption).foregroundStyle(.secondary) }
                        else if mixer.apps.isEmpty { Text("Play audio in an app to adjust its volume.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(mixer.apps) { app in ApplicationVolumeRow(app: app, mixer: mixer) }
                        if let error = mixer.error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                        Text("App volumes apply on this Mac.").font(.caption2).foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Active room").font(.subheadline.weight(.semibold))
                        Button { store.setActiveRoom(nil) } label: {
                            HStack { Text("None — use headphones directly"); Spacer(); if store.activeRoom == nil { Image(systemName: "checkmark") } }
                        }.buttonStyle(.plain).padding(.vertical, 4)
                        ForEach(store.rooms) { room in
                            Toggle(room.name, isOn: Binding(get: { store.activeRoomID == room.id }, set: { store.setActiveRoom($0 ? room.id : nil) }))
                                .toggleStyle(.switch).controlSize(.small)
                        }
                    }
                }.padding(16)
            }.frame(maxHeight: 500)
            Divider()
            HStack {
                Button("Open Soundbound", action: openApp).buttonStyle(.plain)
                Spacer()
                Button("Quit", action: quit).buttonStyle(.plain)
            }.font(.caption).padding(16)
        }.frame(width: 360).background(.regularMaterial)
    }
}
private struct ApplicationVolumeRow: View {
    let app: MixerApp
    @ObservedObject var mixer: AppMixer
    @State private var level = 1.0
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 20, height: 20) }
                Text(app.name).lineLimit(1)
                Spacer()
                Text("\(Int(level * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $level, in: 0...1).onChange(of: level) { mixer.setLevel($0, app: app) }
                .accessibilityLabel("Volume for " + app.name)
        }
        .onAppear { level = mixer.levels[app.id] ?? 1 }
        .onChange(of: mixer.levels[app.id]) { level = $0 ?? 1 }
    }
}
private struct HardwareVolumeRow: View {
    let device: LocalAudioDevice
    let initialLevel: Double
    @ObservedObject var audio: SoundModel
    @State private var level = 0.5
    var body: some View {
        HStack {
            Image(systemName: "speaker.wave.1").foregroundStyle(.secondary)
            Slider(value: $level, in: 0...1).onChange(of: level) { audio.setVolume(device.id, level: $0) }
            Text("\(Int(level * 100))%").font(.caption).monospacedDigit().frame(width: 32)
        }.onAppear { level = initialLevel }
    }
}
