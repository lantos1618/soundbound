# Bundled model

RoomObjectDetector uses Ultralytics YOLO26 nano, the official INT8 Core ML detection asset from:
https://github.com/ultralytics/yolo-ios-app/releases/download/v8.3.0/yolo26n.mlpackage.zip

The model metadata identifies Ultralytics, version 8.4.104, with AGPL-3.0 licensing. The license text is included in Sources/SoundboundKit/Resources/YOLO-LICENSE.txt. Upstream source: https://github.com/ultralytics/ultralytics.

The compiled model is approximately 2.7 MB. Inference stays on-device. Only COCO laptop and cell-phone detections are displayed; COCO has no speaker class. A user selects a real room output before confirming its position. Detections are suggestions, not paired-device identity or acoustic calibration.
