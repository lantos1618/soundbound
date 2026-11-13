#if os(iOS)
import CoreML
import Vision
import ARKit

struct RoomObjectDetection: Identifiable {
    let id = UUID()
    let label: String
    let rect: CGRect // Normalized camera image coordinates, top-left origin.
    let confidence: Float
}
final class RoomObjectDetector {
    private let queue = DispatchQueue(label: "app.soundbound.room-object-detection", qos: .userInitiated)
    private var request: VNCoreMLRequest?
    private var busy = false
    init() {
        queue.async {
            let url = Bundle.main.url(forResource: "yolo26n", withExtension: "mlmodelc")
            guard let url else { return }
            let config = MLModelConfiguration(); config.computeUnits = .all
            guard let model = try? MLModel(contentsOf: url, configuration: config),
                  let vision = try? VNCoreMLModel(for: model) else { return }
            let request = VNCoreMLRequest(model: vision)
            request.imageCropAndScaleOption = .scaleFill
            self.request = request
        }
    }
    func detect(_ buffer: CVPixelBuffer, completion: @escaping ([RoomObjectDetection], Bool) -> Void) {
        // Only called on main; drop frames while one inference is running.
        guard !busy else { return }; busy = true
        queue.async {
            var found: [RoomObjectDetection] = []
            let available = self.request != nil
            if let request = self.request {
                try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
                if let output = (request.results?.first as? VNCoreMLFeatureValueObservation)?.featureValue.multiArrayValue,
                   output.shape.map({ $0.intValue }) == [1, 300, 6] {
                    for row in 0..<300 {
                        let value: (Int) -> Double = { output[[0, NSNumber(value: row), NSNumber(value: $0)]].doubleValue }
                        let confidence = value(4), category = Int(value(5))
                        guard confidence >= 0.45, category == 63 || category == 67 else { continue }
                        // This bundled 640px end-to-end export returns pixel xyxy.
                        let scale = 640.0
                        let rect = CGRect(x: value(0) / scale, y: value(1) / scale,
                                          width: (value(2) - value(0)) / scale, height: (value(3) - value(1)) / scale)
                            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                        guard !rect.isNull, rect.width > 0, rect.height > 0 else { continue }
                        found.append(RoomObjectDetection(label: category == 63 ? "Laptop" : "Phone", rect: rect, confidence: Float(confidence)))
                    }
                }
            }
            DispatchQueue.main.async { self.busy = false; completion(Array(found.prefix(8)), available) }
        }
    }
}
#endif
