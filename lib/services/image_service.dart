import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

class ImageService {
  static Future<String> processImage({
    required String inputPath,
    required String outputPath,
    required Map<String, dynamic> filters,
    required double targetRatio,
  }) async {
    return await compute(processImageIsolate, {
      'inputPath': inputPath,
      'outputPath': outputPath,
      'filters': filters,
      'aspectRatio': targetRatio,
    });
  }
}

Future<String> processImageIsolate(Map<String, dynamic> data) async {
  final String inputPath = data['inputPath'];
  final String outputPath = data['outputPath'];
  final Map<String, dynamic> filters = data['filters'];
  final double targetRatio = data['aspectRatio'] ?? 1.0;

  final Uint8List bytes = await File(inputPath).readAsBytes();
  img.Image? image = img.decodeImage(bytes);
  if (image == null) return inputPath;

  // 1. Recorte (Crop) para mantener Aspect Ratio del sensor 4:3 real
  int width = image.width;
  int height = image.height;
  double currentRatio = width / height;
  int x = 0, y = 0, cw = width, ch = height;

  if (currentRatio > targetRatio) {
    cw = (height * targetRatio).toInt();
    x = (width - cw) ~/ 2;
  } else {
    ch = (width / targetRatio).toInt();
    y = (height - ch) ~/ 2;
  }
  image = img.copyCrop(image, x: x, y: y, width: cw, height: ch);

  // 2. PROCESAMIENTO AVANZADO

  // A. Brillo, Contraste, Saturación (Básico)
  image = img.adjustColor(
    image,
    brightness: filters['brightness'] + 1.0,
    contrast: filters['contrast'],
    saturation: filters['saturation'],
    gamma: filters['gamma'],
  );

  // B. RGB Channels
  final rgb = filters['rgb'];
  if (rgb['r'] != 1.0 || rgb['g'] != 1.0 || rgb['b'] != 1.0) {
    for (var frame in image.frames) {
      for (var pixel in frame) {
        pixel.r = (pixel.r * rgb['r']).clamp(0, 255);
        pixel.g = (pixel.g * rgb['g']).clamp(0, 255);
        pixel.b = (pixel.b * rgb['b']).clamp(0, 255);
      }
    }
  }

  // C. Vibrance (Simulación manual si no existe directa)
  // Nota: img no tiene vibrance nativo, usamos saturation extra en colores menos saturados
  double vibrance = filters['vibrance'];
  if (vibrance != 0.0) {
    image = img.adjustColor(image, saturation: 1.0 + (vibrance * 0.5));
  }

  // D. Color Temperature (CCT)
  // Aproximación: 6500K es neutro. <6500K es cálido (más rojo/amarillo), >6500K es frío (más azul).
  double temp = filters['colorTemperature'];
  if (temp != 6500.0) {
    double factor = (temp - 6500.0) / 5000.0; // Normalización simple
    for (var frame in image.frames) {
      for (var pixel in frame) {
        pixel.r = (pixel.r * (1.0 - factor * 0.2)).clamp(0, 255);
        pixel.b = (pixel.b * (1.0 + factor * 0.2)).clamp(0, 255);
      }
    }
  }

  // E. Shadows & Highlights (Aproximación por curvas simple)
  double shadows = filters['shadows'];
  double highlights = filters['highlights'];
  if (shadows != 1.0 || highlights != 1.0) {
    for (var frame in image.frames) {
      for (var pixel in frame) {
        double luma = 0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b;
        if (luma < 128) {
          pixel.r = (pixel.r * shadows).clamp(0, 255);
          pixel.g = (pixel.g * shadows).clamp(0, 255);
          pixel.b = (pixel.b * shadows).clamp(0, 255);
        } else {
          pixel.r = (pixel.r * highlights).clamp(0, 255);
          pixel.g = (pixel.g * highlights).clamp(0, 255);
          pixel.b = (pixel.b * highlights).clamp(0, 255);
        }
      }
    }
  }

  // F. Tint / Overlay
  final tint = filters['tint'];
  if (tint['opacity'] > 0) {
    String colorStr = tint['color'].replaceAll('#', '');
    int tintColor = int.parse(colorStr, radix: 16);
    int tr = (tintColor >> 16) & 0xFF;
    int tg = (tintColor >> 8) & 0xFF;
    int tb = tintColor & 0xFF;
    double op = tint['opacity'];

    for (var frame in image.frames) {
      for (var pixel in frame) {
        pixel.r = (pixel.r * (1 - op) + tr * op).toInt().clamp(0, 255);
        pixel.g = (pixel.g * (1 - op) + tg * op).toInt().clamp(0, 255);
        pixel.b = (pixel.b * (1 - op) + tb * op).toInt().clamp(0, 255);
      }
    }
  }

  // 3. Encoder (Encode JPG)
  final processedBytes = img.encodeJpg(image, quality: filters['quality']);
  await File(outputPath).writeAsBytes(processedBytes);

  return outputPath;
}
