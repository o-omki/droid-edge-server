import "package:equatable/equatable.dart";

class BoundingBoxRect extends Equatable {
  const BoundingBoxRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => (right - left).clamp(0, double.infinity);

  double get height => (bottom - top).clamp(0, double.infinity);

  Map<String, dynamic> toJson() {
    return {
      "left": left.round(),
      "top": top.round(),
      "right": right.round(),
      "bottom": bottom.round(),
      "width": width.round(),
      "height": height.round(),
    };
  }

  @override
  List<Object?> get props => [left, top, right, bottom];
}

class CornerPoint extends Equatable {
  const CornerPoint({
    required this.x,
    required this.y,
  });

  final int x;
  final int y;

  Map<String, dynamic> toJson() {
    return {
      "x": x,
      "y": y,
    };
  }

  @override
  List<Object?> get props => [x, y];
}

