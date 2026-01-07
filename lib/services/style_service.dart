import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart' as xml;

class StyleService {
  static Future<Map<String, dynamic>> loadStyleConfig() async {
    try {
      String xmlString;
      final directory = await getApplicationDocumentsDirectory();
      final customFile = File(p.join(directory.path, 'custom_style.xml'));

      if (await customFile.exists()) {
        xmlString = await customFile.readAsString();
      } else {
        xmlString = await rootBundle.loadString('assets/style.xml');
      }

      final document = xml.XmlDocument.parse(xmlString);
      final config = document.findElements('StyleConfig').first;

      return {
        'brightness': _val(config, 'Brightness', 0.0),
        'contrast': _val(config, 'Contrast', 1.0),
        'saturation': _val(config, 'Saturation', 1.0),
        'vibrance': _val(config, 'Vibrance', 0.0),
        'colorTemperature': _val(config, 'ColorTemperature', 6500.0),
        'hue': _val(config, 'Hue', 0.0),
        'rgb': {
          'r': _val(config.findElements('RGB').first, 'Red', 1.0),
          'g': _val(config.findElements('RGB').first, 'Green', 1.0),
          'b': _val(config.findElements('RGB').first, 'Blue', 1.0),
        },
        'gamma': _val(config, 'Gamma', 1.0),
        'shadows': _val(config, 'Shadows', 1.0),
        'highlights': _val(config, 'Highlights', 1.0),
        'tint': {
          'color': _str(config.findElements('Tint').first, 'Color', '#000000'),
          'opacity': _val(config.findElements('Tint').first, 'Opacity', 0.0),
          'blendMode': _str(
            config.findElements('Tint').first,
            'BlendMode',
            'none',
          ),
        },
        'quality': 90, // Calidad por defecto
      };
    } catch (e) {
      return _defaults();
    }
  }

  static double _val(xml.XmlElement parent, String name, double def) {
    try {
      return double.parse(parent.findElements(name).first.innerText);
    } catch (_) {
      return def;
    }
  }

  static String _str(xml.XmlElement parent, String name, String def) {
    try {
      return parent.findElements(name).first.innerText;
    } catch (_) {
      return def;
    }
  }

  static Map<String, dynamic> _defaults() => {
    'brightness': 0.0,
    'contrast': 1.0,
    'saturation': 1.0,
    'vibrance': 0.0,
    'colorTemperature': 6500.0,
    'hue': 0.0,
    'rgb': {'r': 1.0, 'g': 1.0, 'b': 1.0},
    'gamma': 1.0,
    'shadows': 1.0,
    'highlights': 1.0,
    'tint': {'color': '#000000', 'opacity': 0.0, 'blendMode': 'none'},
    'quality': 90,
  };

  static Future<void> saveCustomStyle(File file) async {
    final directory = await getApplicationDocumentsDirectory();
    final customFile = File(p.join(directory.path, 'custom_style.xml'));
    await customFile.writeAsBytes(await file.readAsBytes());
  }

  static Future<void> resetToDefault() async {
    final directory = await getApplicationDocumentsDirectory();
    final customFile = File(p.join(directory.path, 'custom_style.xml'));
    if (await customFile.exists()) await customFile.delete();
  }
}
