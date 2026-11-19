import "dart:math" as math;
import "dart:ui";

import "package:google_mlkit_face_detection/google_mlkit_face_detection.dart";

import "../models/geometry_models.dart";
import "image_payload_processor.dart";

class DetectedFaceRegion {
  const DetectedFaceRegion({
    required this.boundingBox,
    this.cornerPoints = const [],
  });

  final BoundingBoxRect boundingBox;
  final List<CornerPoint> cornerPoints;
}

abstract class FaceDetectionEngine {
  Future<List<BoundingBoxRect>> detectFaces(PreparedImagePayload payload);

  Future<List<DetectedFaceRegion>> detectOrientedFaces(
    PreparedImagePayload payload,
  ) async {
    final boxes = await detectFaces(payload);
    return boxes.map((box) => DetectedFaceRegion(boundingBox: box)).toList();
  }

  Future<void> dispose();
}

class MlKitFaceDetectionEngine implements FaceDetectionEngine {
  FaceDetector? _detector;

  @override
  Future<List<BoundingBoxRect>> detectFaces(
    PreparedImagePayload payload,
  ) async {
    final faces = await _processFaces(payload);
    return faces.map((face) => _toBoundingBox(face.boundingBox)).toList();
  }

  @override
  Future<List<DetectedFaceRegion>> detectOrientedFaces(
    PreparedImagePayload payload,
  ) async {
    final faces = await _processFaces(payload);
    return faces.map((face) {
      final box = _toBoundingBox(face.boundingBox);
      final angleDeg = face.headEulerAngleZ;
      final corners = angleDeg != null && angleDeg.abs() >= 1.0
          ? orientedCornersFromAngle(box, angleDeg)
          : const <CornerPoint>[];
      return DetectedFaceRegion(
        boundingBox: box,
        cornerPoints: corners,
      );
    }).toList();
  }

  Future<List<Face>> _processFaces(PreparedImagePayload payload) async {
    final detector = _detector ??= FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate,
        minFaceSize: 0.08,
      ),
    );

    final inputImage = InputImage.fromFilePath(payload.filePath);
    return detector.processImage(inputImage);
  }

  @override
  Future<void> dispose() async {
    final detector = _detector;
    _detector = null;
    if (detector != null) {
      await detector.close();
    }
  }

  /// Derives an oriented 4-point quad `[topLeft, topRight, bottomRight,
  /// bottomLeft]` from an axis-aligned [box] and ML Kit's [headEulerAngleZ]
  /// (degrees, positive = counter-clockwise).
  static List<CornerPoint> orientedCornersFromAngle(
    BoundingBoxRect box,
    double headEulerAngleZDeg,
  ) {
    final theta = headEulerAngleZDeg * math.pi / 180.0;
    final cosT = math.cos(theta);
    final sinT = math.sin(theta);

    // Reading/horizontal axis u = (cosT, -sinT) and downward axis v = (sinT, cosT)
    // in image pixel coordinates (+x right, +y down) for CCW rotation theta.
    final ux = cosT;
    final uy = -sinT;
    final vx = sinT;
    final vy = cosT;

    final aabbW = box.width;
    final aabbH = box.height;
    final absCos = cosT.abs();
    final absSin = sinT.abs();
    final denom = cosT * cosT - sinT * sinT;

    double w;
    double h;
    if (denom.abs() > 0.25) {
      w = (aabbW * absCos - aabbH * absSin) / denom;
      h = (aabbH * absCos - aabbW * absSin) / denom;
      w = w.clamp(aabbW * 0.55, aabbW);
      h = h.clamp(aabbH * 0.55, aabbH);
    } else {
      final side = math.min(aabbW, aabbH) / math.sqrt2;
      w = side;
      h = side;
    }

    final cx = (box.left + box.right) / 2.0;
    final cy = (box.top + box.bottom) / 2.0;
    final hw = w / 2.0;
    final hh = h / 2.0;

    return [
      CornerPoint(
        x: (cx - hw * ux - hh * vx).round(),
        y: (cy - hw * uy - hh * vy).round(),
      ),
      CornerPoint(
        x: (cx + hw * ux - hh * vx).round(),
        y: (cy + hw * uy - hh * vy).round(),
      ),
      CornerPoint(
        x: (cx + hw * ux + hh * vx).round(),
        y: (cy + hw * uy + hh * vy).round(),
      ),
      CornerPoint(
        x: (cx - hw * ux + hh * vx).round(),
        y: (cy - hw * uy + hh * vy).round(),
      ),
    ];
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
