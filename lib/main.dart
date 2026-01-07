import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:open_camara/pages/camera_page.dart';

List<CameraDescription> _cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    _cameras = await availableCameras();
  } catch (e) {
    debugPrint('Error buscando cámaras: $e');
  }
  runApp(
    MaterialApp(
      title: 'Open Cámara',
      debugShowCheckedModeBanner: false,
      home: CameraPage(cameras: _cameras),
    ),
  );
}
