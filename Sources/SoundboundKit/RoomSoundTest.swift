import Foundation
import Combine

/// Short, explicit in-memory microphone check. Nothing is written to disk.
public final class RoomSoundTest: ObservableObject {
    @Published public private(set) var status = ""
    @Published public private(set) var busy = false
    @Published public private(set) var hasRecording = false
    private let io = MeshAudioIO()
    private let lock = NSLock()
    private var clip = Data()
    private var generation = UUID()
    private var timer: DispatchSourceTimer?

    public func record() {
        guard !busy else { return }
        busy = true; status = "Requesting microphone access…"
        let attempt = UUID(); generation = attempt
        MeshAudioIO.microphonePermission { [weak self] allowed in
            guard let self, self.generation == attempt else { return }
            guard allowed else { self.busy = false; self.status = AudioMeshError.microphone.localizedDescription; return }
            self.lock.lock(); self.clip.removeAll(); self.lock.unlock()
            self.hasRecording = false
            do {
                try self.io.startCapture { [weak self] data in
                    guard let self else { return }
                    self.lock.lock(); defer { self.lock.unlock() }
                    if self.clip.count + data.count <= 144_000 { self.clip.append(data) }
                }
                self.status = "Recording for three seconds…"
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, self.generation == attempt else { return }
                    self.io.stop(); self.busy = false
                    self.lock.lock(); let recorded = !self.clip.isEmpty; self.lock.unlock()
                    self.hasRecording = recorded
                    self.status = recorded ? "Recording ready. It stays in memory until this panel closes." : "No microphone audio arrived."
                }
            } catch { self.busy = false; self.status = error.localizedDescription; self.io.stop() }
        }
    }
    public func play() {
        guard !busy, hasRecording else { return }
        lock.lock(); let data = clip; lock.unlock()
        do { try io.startPlayback() } catch { status = error.localizedDescription; return }
        busy = true; status = "Playing on this device…"
        var offset = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        self.timer = timer
        timer.schedule(deadline: .now(), repeating: 0.02)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if offset >= data.count { self.stop(); self.status = "Playback finished"; return }
            self.io.play(Data(data[offset..<min(offset + 960, data.count)]))
            offset += 960
        }
        timer.resume()
    }
    public func stop() {
        generation = UUID(); timer?.cancel(); timer = nil; io.stop(); busy = false
    }
    public func clear() {
        stop(); lock.lock(); clip.removeAll(); lock.unlock(); hasRecording = false
    }
}
