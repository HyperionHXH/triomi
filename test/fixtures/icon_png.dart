import 'dart:typed_data';
import 'dart:ui' as ui;

Future<Uint8List> iconPng({
  int width = 2,
  int height = 2,
  ui.Color color = const ui.Color(0xffff0000),
}) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(color, ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}
