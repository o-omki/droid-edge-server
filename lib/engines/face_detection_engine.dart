import "dart:ui";

import "package:google_mlkit_face_detection/google_mlkit_face_detection.dart";

import "../models/geometry_models.dart";
import "image_payload_processor.dart";

abstract class FaceDetectionEngine {
  Future<List<BoundingBoxRect>> detectFaces(PreparedImagePayload payload);

  Future<void> dispose();
}

class MlKitFaceDetectionEngine implements FaceDetectionEngine {
  FaceDetector? _detector;

  @override
  Future<List<BoundingBoxRect>> detectFaces(
    PreparedImagePayload payload,
  ) async {
    final detector = _detector ??= FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate,
        minFaceSize: 0.08,
      ),
    );

    final inputImage = InputImage.fromFilePath(payload.filePath);
    final faces = await detector.processImage(inputImage);
    return faces.map((face) => _toBoundingBox(face.boundingBox)).toList();
  }

  @override
  Future<void> dispose() async {
    final detector = _detector;
    _detector = null;
    if (detector != null) {
      await detector.close();
    }
  }

  static BoundingBoxRect _toBoundingBox(Rect rect) {
    return BoundingBoxRect(
      left: rect.left,
      top: rect.top,
      right: rect.right,
      bottom: rect.bottom,
    );
  }
}
