import Foundation
import AVFAudio
import CoreAudio

// A bounded hardware experiment, separate from Soundbound's normal controls.
// It requests playback arbitration once, records the actual default output,
// and leaves arbitration. --with-audio plays a one-second quiet test tone.
// Neither mode changes Bluetooth settings.
func currentOutput() -> [String: Any] {
    var property = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var device: AudioDeviceID = 0
    var size = UInt32(MemoryLayout.size(ofValue: device))
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device)
    guard status == noErr else { return ["readError": status] }
    property.mSelector = kAudioObjectPropertyName
    var name: CFString = "" as CFString
    size = UInt32(MemoryLayout.size(ofValue: name))
    let nameStatus = withUnsafeMutablePointer(to: &name) {
        AudioObjectGetPropertyData(device, &property, 0, nil, &size, $0)
    }
    property.mSelector = kAudioDevicePropertyTransportType
    var transport: UInt32 = 0
    size = UInt32(MemoryLayout.size(ofValue: transport))
    let transportStatus = AudioObjectGetPropertyData(device, &property, 0, nil, &size, &transport)
    return ["id": device, "name": nameStatus == noErr ? name as String : "Unknown",
            "bluetooth": transportStatus == noErr && (transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE)]
}

let started = Date()
let withAudio = CommandLine.arguments.contains("--with-audio")
let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
var tone: AVAudioPCMBuffer?
if withAudio {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
    buffer.frameLength = buffer.frameCapacity
    for frame in 0..<Int(buffer.frameLength) {
        let t = Double(frame) / 48_000
        let fade = min(1, min(t / 0.05, (1 - t) / 0.05))
        let sample = Float(sin(t * 2 * .pi * 220) * 0.008 * max(0, fade))
        buffer.floatChannelData![0][frame] = sample
        buffer.floatChannelData![1][frame] = sample
    }
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    tone = buffer
}
var report: [String: Any] = ["started": ISO8601DateFormatter().string(from: started),
                             "before": currentOutput(), "category": "playback", "playsAudio": withAudio]
var finished = false
let arbiter = AVAudioRoutingArbiter.shared
print("Requesting AirPods ownership with Apple's playback arbitration API…")
arbiter.begin(category: .playback) { changed, error in
    DispatchQueue.main.async {
        report["callbackSeconds"] = Date().timeIntervalSince(started)
        report["systemReportedDeviceChanged"] = changed
        report["afterCallback"] = currentOutput()
        if let error {
            let nsError = error as NSError
            report["error"] = ["domain": nsError.domain, "code": nsError.code, "description": nsError.localizedDescription]
        }
        if let tone {
            do {
                try engine.start()
                player.scheduleBuffer(tone)
                player.play()
                report["audioStarted"] = true
            } catch {
                report["audioError"] = error.localizedDescription
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            report["afterSettling"] = currentOutput()
            finished = true
        }
    }
}
let deadline = Date().addingTimeInterval(15)
while !finished && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
}
if !finished { report["timedOut"] = true }
if withAudio {
    player.stop()
    engine.stop()
}
arbiter.leave()
report["leftArbitration"] = true
if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
   let json = String(data: data, encoding: .utf8) {
    print(json)
    if let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) {
        try data.write(to: URL(fileURLWithPath: path))
    }
}
