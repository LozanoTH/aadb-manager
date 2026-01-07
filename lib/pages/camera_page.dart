import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:gal/gal.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:open_filex/open_filex.dart';

import '../services/image_service.dart';
import '../services/style_service.dart';

class CameraPage extends StatefulWidget {
  final List<CameraDescription> cameras;
  const CameraPage({super.key, required this.cameras});

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> {
  CameraController? controller;
  bool _isProcessing = false;
  String? _lastProcessedPath;
  double _currentAspectRatio = 3 / 4;

  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _currentZoom = 1.0;
  double _baseZoom = 1.0;

  double _minExposure = 0.0;
  double _maxExposure = 0.0;
  double _currentExposure = 0.0;
  bool _isExposureSliderVisible = false;
  bool _isFocusLocked = false;
  bool _isExposureLocked = false;
  Offset? _focusPoint;

  bool _isVideoMode = false;
  bool _isRecording = false;

  // Estabilización de video
  bool _isStabilizationSupported = false;
  bool _isStabilizationActive = false;
  final double _stabilizationThreshold = 0.7; // 70% del zoom máximo

  @override
  void initState() {
    super.initState();
    if (widget.cameras.isNotEmpty) {
      _initializeCamera(widget.cameras[0]);
    }
  }

  Future<void> _initializeCamera(CameraDescription cameraDescription) async {
    if (controller != null) {
      await controller!.dispose();
      controller = null;
      if (mounted) setState(() {});
    }

    final newController = CameraController(
      cameraDescription,
      ResolutionPreset.max,
      enableAudio: true,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await newController.initialize();
      _minZoom = await newController.getMinZoomLevel();
      _maxZoom = await newController.getMaxZoomLevel();
      _currentZoom = _minZoom;

      _minExposure = await newController.getMinExposureOffset();
      _maxExposure = await newController.getMaxExposureOffset();
      _currentExposure = 0.0;

      if (!mounted) return;
      setState(() {
        controller = newController;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error cámara: $e')));
      }
    }
  }

  Future<void> _takeAndProcessPicture() async {
    if (controller == null || !controller!.value.isInitialized || _isProcessing)
      return;

    setState(() => _isProcessing = true);

    try {
      final XFile rawFile = await controller!.takePicture();
      final filters = await StyleService.loadStyleConfig();

      final directory = await getApplicationDocumentsDirectory();
      final String outputPath = p.join(
        directory.path,
        'IMG_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );

      final processedPath = await ImageService.processImage(
        inputPath: rawFile.path,
        outputPath: outputPath,
        filters: filters,
        targetRatio: _currentAspectRatio,
      );

      setState(() {
        _lastProcessedPath = processedPath;
        _isProcessing = false;
      });
    } catch (e) {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _startVideoRecording() async {
    if (controller == null || !controller!.value.isInitialized || _isRecording)
      return;
    try {
      await controller!.startVideoRecording();
      setState(() => _isRecording = true);
    } catch (e) {
      debugPrint('Error video: $e');
    }
  }

  Future<void> _stopVideoRecording() async {
    if (controller == null || !_isRecording) return;
    try {
      final XFile videoFile = await controller!.stopVideoRecording();
      setState(() {
        _isRecording = false;
        _isProcessing = true;
      });

      await Gal.putVideo(videoFile.path);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('📹 Video guardado en Galería')),
        );
      }
      setState(() => _isProcessing = false);
    } catch (e) {
      debugPrint('Error guardando video: $e');
      setState(() => _isProcessing = false);
    }
  }

  void _toggleCameraMode() {
    if (_isRecording) return;
    setState(() {
      _isVideoMode = !_isVideoMode;
    });
  }

  void _toggleExposureSlider() {
    setState(() {
      _isExposureSliderVisible = !_isExposureSliderVisible;
    });
  }

  void _toggleAspectRatio() {
    setState(() {
      if (_currentAspectRatio == 3 / 4) {
        _currentAspectRatio = 1.0;
      } else {
        _currentAspectRatio = 3 / 4;
      }
    });
  }

  Future<void> _saveToGallery() async {
    if (_lastProcessedPath == null) return;
    setState(() => _isProcessing = true);
    try {
      await Gal.putImage(_lastProcessedPath!);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('✅ Guardado en Galería')));
      }
      setState(() {
        _lastProcessedPath = null;
        _isProcessing = false;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('❌ Error al guardar')));
      }
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _setZoom(double zoom) async {
    if (controller == null || !controller!.value.isInitialized) return;
    final level = zoom.clamp(_minZoom, _maxZoom);
    await controller!.setZoomLevel(level);
    setState(() => _currentZoom = level);

    // Activar estabilización automáticamente en modo video con zoom alto
    if (_isVideoMode && _isStabilizationSupported) {
      final zoomPercentage = (level - _minZoom) / (_maxZoom - _minZoom);
      final shouldStabilize = zoomPercentage >= _stabilizationThreshold;

      if (shouldStabilize != _isStabilizationActive) {
        setState(() => _isStabilizationActive = shouldStabilize);
      }
    }
  }

  Future<void> _setExposure(double value) async {
    if (controller == null || !controller!.value.isInitialized) return;
    await controller!.setExposureOffset(value);
    setState(() => _currentExposure = value);
  }

  Future<void> _toggleFocusLock() async {
    if (controller == null || !controller!.value.isInitialized) return;
    if (_isFocusLocked) {
      await controller!.setFocusMode(FocusMode.auto);
    } else {
      await controller!.setFocusMode(FocusMode.locked);
    }
    setState(() => _isFocusLocked = !_isFocusLocked);
  }

  Future<void> _toggleExposureLock() async {
    if (controller == null || !controller!.value.isInitialized) return;
    if (_isExposureLocked) {
      await controller!.setExposureMode(ExposureMode.auto);
    } else {
      await controller!.setExposureMode(ExposureMode.locked);
    }
    setState(() => _isExposureLocked = !_isExposureLocked);
  }

  Future<void> _handleTapFocus(
    TapUpDetails details,
    BoxConstraints constraints,
  ) async {
    if (controller == null || !controller!.value.isInitialized) return;

    final Offset offset = Offset(
      details.localPosition.dx / constraints.maxWidth,
      details.localPosition.dy / constraints.maxHeight,
    );

    setState(() => _focusPoint = details.localPosition);

    await controller!.setFocusPoint(offset);
    await controller!.setExposurePoint(offset);

    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _focusPoint = null);
    });
  }

  Future<void> _pickCustomStyle() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xml'],
      );

      if (result != null) {
        File file = File(result.files.single.path!);
        await StyleService.saveCustomStyle(file);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('🎨 Estilo personalizado cargado correctamente'),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('❌ Error al cargar estilo: $e')));
      }
    }
  }

  Future<void> _resetStyle() async {
    await StyleService.resetToDefault();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('🔄 Estilo restaurado por defecto')),
      );
    }
  }

  Widget _animatedVisibility({
    required bool visible,
    required Widget child,
    Duration duration = const Duration(milliseconds: 300),
  }) {
    return AnimatedOpacity(
      opacity: visible ? 1.0 : 0.0,
      duration: duration,
      curve: Curves.easeOut,
      child: IgnorePointer(ignoring: !visible, child: child),
    );
  }

  Future<void> _shareImage() async {
    if (_lastProcessedPath == null) return;
    try {
      await Share.shareXFiles([XFile(_lastProcessedPath!)]);
    } catch (e) {
      debugPrint('Error sharing: $e');
    }
  }

  Future<void> _editImage() async {
    if (_lastProcessedPath == null) return;
    try {
      await OpenFilex.open(_lastProcessedPath!);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error abriendo editor: $e')));
      }
    }
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (controller == null || !controller!.value.isInitialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: _lastProcessedPath == null
                ? Center(
                    key: const ValueKey('camera'),
                    child: AspectRatio(
                      aspectRatio: _currentAspectRatio,
                      child: ClipRect(
                        child: FittedBox(
                          fit: BoxFit.cover,
                          child: SizedBox(
                            width: controller!.value.previewSize!.height,
                            height: controller!.value.previewSize!.width,
                            child: LayoutBuilder(
                              builder: (context, constraints) =>
                                  GestureDetector(
                                    onTapUp: (details) =>
                                        _handleTapFocus(details, constraints),
                                    onScaleStart: (_) =>
                                        _baseZoom = _currentZoom,
                                    onScaleUpdate: (details) =>
                                        _setZoom(_baseZoom * details.scale),
                                    child: Stack(
                                      children: [
                                        CameraPreview(controller!),
                                        if (_focusPoint != null)
                                          Positioned(
                                            left: _focusPoint!.dx - 25,
                                            top: _focusPoint!.dy - 25,
                                            child: Container(
                                              height: 50,
                                              width: 50,
                                              decoration: BoxDecoration(
                                                border: Border.all(
                                                  color: Colors.yellow,
                                                  width: 2,
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                : Center(
                    key: const ValueKey('image'),
                    child: AspectRatio(
                      aspectRatio: _currentAspectRatio,
                      child: Image.file(
                        File(_lastProcessedPath!),
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
          ),

          // Top Toolbar
          Positioned(
            top: 50,
            left: 0,
            right: 0,
            child: _animatedVisibility(
              visible: _lastProcessedPath == null,
              child: Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(30),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Container(
                      width: MediaQuery.of(context).size.width * 0.9,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.2),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          // Columna Izquierda (Herramientas)
                          Expanded(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.start,
                              children: [
                                _pillBtn(
                                  _currentAspectRatio == 1.0 ? '1:1' : '3:4',
                                  _toggleAspectRatio,
                                  active: true,
                                ),
                                _iconBtn(
                                  Icons.palette_outlined,
                                  _pickCustomStyle,
                                  color: Colors.transparent,
                                ),
                                _iconBtn(
                                  Icons.tune_rounded,
                                  _toggleExposureSlider,
                                  color: _isExposureSliderVisible
                                      ? Colors.orange.withOpacity(0.7)
                                      : Colors.transparent,
                                ),
                                _iconBtn(
                                  Icons.refresh_rounded,
                                  _resetStyle,
                                  color: Colors.transparent,
                                ),
                              ],
                            ),
                          ),

                          // Columna Central (Modo - Siempre Centrado)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            decoration: const BoxDecoration(
                              border: Border.symmetric(
                                vertical: BorderSide(
                                  color: Colors.white10,
                                  width: 1,
                                ),
                              ),
                            ),
                            child: _pillBtn(
                              _isVideoMode ? 'VIDEO' : 'FOTO',
                              _toggleCameraMode,
                              active: true,
                            ),
                          ),

                          // Columna Derecha (Locks + Flip Camera + Gallery)
                          Expanded(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                _iconBtn(
                                  Icons.flip_camera_android_rounded,
                                  () {
                                    if (_isRecording || _isProcessing) return;
                                    final lens =
                                        controller!.description.lensDirection;
                                    final other = widget.cameras.firstWhere(
                                      (c) => c.lensDirection != lens,
                                    );
                                    _initializeCamera(other);
                                  },
                                  color: Colors.white.withOpacity(0.1),
                                ),
                                _iconBtn(
                                  _isFocusLocked
                                      ? Icons.gps_fixed
                                      : Icons.gps_not_fixed,
                                  _toggleFocusLock,
                                  color: _isFocusLocked
                                      ? Colors.orange.withOpacity(0.7)
                                      : Colors.transparent,
                                ),
                                _iconBtn(
                                  _isExposureLocked
                                      ? Icons.lock
                                      : Icons.lock_open,
                                  _toggleExposureLock,
                                  color: _isExposureLocked
                                      ? Colors.orange.withOpacity(0.7)
                                      : Colors.transparent,
                                ),
                                _iconBtn(
                                  Icons.photo_library_rounded,
                                  () async {
                                    try {
                                      await Gal.open();
                                    } catch (e) {
                                      if (mounted) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'No se pudo abrir la galería',
                                            ),
                                            duration: Duration(seconds: 2),
                                          ),
                                        );
                                      }
                                    }
                                  },
                                  color: Colors.white.withOpacity(0.1),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Controls UI (Sliders)
          if (_maxExposure > _minExposure && _isExposureSliderVisible)
            Positioned(
              right: 16,
              top: 140,
              bottom: 140,
              child: _animatedVisibility(
                visible: _lastProcessedPath == null,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(25),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                    child: Container(
                      width: 40,
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(25),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.15),
                          width: 1,
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              color: Colors.yellow.withOpacity(0.15),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.wb_sunny_rounded,
                              color: Colors.yellow,
                              size: 12,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 3,
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 5,
                                ),
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 10,
                                ),
                                activeTrackColor: Colors.yellow.withOpacity(
                                  0.8,
                                ),
                                inactiveTrackColor: Colors.white.withOpacity(
                                  0.2,
                                ),
                                thumbColor: Colors.yellow,
                              ),
                              child: RotatedBox(
                                quarterTurns: 3,
                                child: Slider(
                                  value: _currentExposure,
                                  min: _minExposure,
                                  max: _maxExposure,
                                  onChanged: (val) => _setExposure(val),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.3),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              _currentExposure > 0
                                  ? '+${_currentExposure.toStringAsFixed(1)}'
                                  : _currentExposure.toStringAsFixed(1),
                              style: const TextStyle(
                                color: Colors.yellow,
                                fontSize: 9,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

          if (_maxZoom > _minZoom)
            Positioned(
              bottom: 160,
              left: 60,
              right: 60,
              child: _animatedVisibility(
                visible: _lastProcessedPath == null,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 12,
                    ),
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: _currentZoom,
                    min: _minZoom,
                    max: _maxZoom,
                    onChanged: (val) => _setZoom(val),
                  ),
                ),
              ),
            ),

          // Bottom Toolbar (Review & Capture)
          Positioned(
            bottom: 50,
            left: 0,
            right: 0,
            child: Stack(
              alignment: Alignment.center,
              children: [
                _animatedVisibility(
                  visible: _lastProcessedPath != null,
                  child: Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(30),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                        child: Container(
                          width: MediaQuery.of(context).size.width * 0.8,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(30),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.2),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              _iconBtn(
                                Icons.delete_outline_rounded,
                                () => setState(() => _lastProcessedPath = null),
                                color: Colors.transparent,
                                size: 28,
                                padding: const EdgeInsets.all(8),
                              ),
                              _iconBtn(
                                Icons.edit_outlined,
                                _editImage,
                                color: Colors.transparent,
                                size: 28,
                                padding: const EdgeInsets.all(8),
                              ),
                              _iconBtn(
                                Icons.share_outlined,
                                _shareImage,
                                color: Colors.transparent,
                                size: 28,
                                padding: const EdgeInsets.all(8),
                              ),
                              _iconBtn(
                                Icons.save_alt_rounded,
                                _saveToGallery,
                                color: Colors.transparent,
                                size: 28,
                                padding: const EdgeInsets.all(8),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                _animatedVisibility(
                  visible: _lastProcessedPath == null,
                  child: Row(
                    children: [
                      const Expanded(child: SizedBox()),
                      GestureDetector(
                        onTap: () {
                          if (_isProcessing) return;
                          if (_isVideoMode) {
                            _isRecording
                                ? _stopVideoRecording()
                                : _startVideoRecording();
                          } else {
                            _takeAndProcessPicture();
                          }
                        },
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            if (_isProcessing)
                              SizedBox(
                                height: 92,
                                width: 92,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white.withOpacity(0.5),
                                ),
                              ),
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              height: 80,
                              width: 80,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: _isProcessing
                                      ? Colors.white.withOpacity(0.2)
                                      : Colors.white,
                                  width: 2,
                                ),
                              ),
                              padding: const EdgeInsets.all(8),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                decoration: BoxDecoration(
                                  color: _isProcessing
                                      ? Colors.white24
                                      : (_isRecording
                                            ? Colors.redAccent
                                            : Colors.white),
                                  borderRadius: BorderRadius.circular(
                                    _isRecording ? 8 : 40,
                                  ),
                                ),
                                child: _isVideoMode
                                    ? Icon(
                                        _isRecording
                                            ? Icons.stop_rounded
                                            : Icons.videocam_rounded,
                                        size: 28,
                                        color: _isRecording
                                            ? Colors.white
                                            : Colors.black,
                                      )
                                    : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Expanded(child: SizedBox()),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pillBtn(String text, VoidCallback onTap, {bool active = false}) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? Colors.white : Colors.white.withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: active ? Colors.black : Colors.white70,
            fontWeight: FontWeight.w600,
            fontSize: 11,
          ),
        ),
      ),
    );
  }

  Widget _iconBtn(
    IconData icon,
    VoidCallback onTap, {
    Color color = Colors.transparent,
    double size = 14,
    EdgeInsets padding = const EdgeInsets.all(5),
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.zero,
        padding: padding,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white, size: size),
      ),
    );
  }
}
