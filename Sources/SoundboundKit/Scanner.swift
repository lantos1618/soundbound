#if os(iOS)
import SwiftUI
import AVFoundation
import UIKit

struct ScannerScreen: View {
    let completion: (String?) -> Void
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                CameraScanner(completion: completion, error: { error = $0 })
                VStack {
                    Text("Scan a Soundbound code").font(.title3.weight(.medium)).foregroundStyle(.white).padding(.top, 32)
                    Spacer()
                    RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                        .frame(width: 240, height: 240)
                    Spacer()
                    Text(error ?? "Point your camera at the other device’s code.")
                        .foregroundStyle(.white).multilineTextAlignment(.center).padding(24)
                }.allowsHitTesting(false)
            }.navigationTitle("Scan code").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { completion(nil) } } }
        }
    }
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private struct CameraScanner: UIViewRepresentable {
    let completion: (String?) -> Void
    let error: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion, error: error) }
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.videoGravity = .resizeAspectFill
        view.preview.session = context.coordinator.session
        context.coordinator.start()
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) { coordinator.stop() }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "app.soundbound.camera")
        private let completion: (String?) -> Void
        private let error: (String) -> Void
        private var delivered = false
        private var stopped = false
        init(completion: @escaping (String?) -> Void, error: @escaping (String) -> Void) {
            self.completion = completion; self.error = error
        }
        func start() {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                guard granted else {
                    DispatchQueue.main.async { self.error("Camera access is off. Allow it in Settings, or enter the invite link instead.") }; return
                }
                self.queue.async {
                    guard !self.stopped else { return }
                    guard let device = AVCaptureDevice.default(for: .video),
                          let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) else {
                        DispatchQueue.main.async { self.error("No camera is available. Enter the invite link instead.") }; return
                    }
                    self.session.beginConfiguration()
                    self.session.addInput(input)
                    let output = AVCaptureMetadataOutput()
                    guard self.session.canAddOutput(output) else { self.session.commitConfiguration(); return }
                    self.session.addOutput(output)
                    output.setMetadataObjectsDelegate(self, queue: .main)
                    output.metadataObjectTypes = [.qr]
                    self.session.commitConfiguration()
                    if !self.stopped { self.session.startRunning() }
                }
            }
        }
        func stop() { queue.async { self.stopped = true; self.session.stopRunning() } }
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !delivered, let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            guard value.hasPrefix("soundbound://invite?") else { error("That isn’t a Soundbound code."); return }
            delivered = true; stop(); completion(value)
        }
    }
}
#endif
