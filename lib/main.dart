
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ADB Manager',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1ED760),
          brightness: Brightness.light,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1ED760),
          brightness: Brightness.dark,
        ),
      ),
      themeMode: ThemeMode.system,
      home: const MagiskHome(),
    );
  }
}

class ModuleEntry {
  final String name;
  final String dir;
  final String? mainScript;
  final String? uninstallScript;

  const ModuleEntry({
    required this.name,
    required this.dir,
    required this.mainScript,
    required this.uninstallScript,
  });
}

class OnlineModule {
  final String name;
  final String description;
  final String zipUrl;

  const OnlineModule({
    required this.name,
    required this.description,
    required this.zipUrl,
  });
}

class MagiskHome extends StatefulWidget {
  const MagiskHome({super.key});

  @override
  State<MagiskHome> createState() => _MagiskHomeState();
}

class _MagiskHomeState extends State<MagiskHome> {
  static const MethodChannel _shizukuChannel = MethodChannel('shizuku');
  static const EventChannel _shizukuLogs = EventChannel('shizuku_logs');

  int _tabIndex = 0;
  bool _shizukuAvailable = false;
  bool _shizukuGranted = false;
  bool _shizukuRationale = false;
  bool _shizukuPreV11 = false;
  bool _shizukuBusy = false;
  String? _shizukuError;
  int? _shizukuUid;

  final List<ModuleEntry> _modules = [];
  final List<String> _logs = [];
  final ValueNotifier<List<String>> _runLogsNotifier =
      ValueNotifier<List<String>>([]);
  StreamSubscription? _logSubscription;
  bool _modulesBusy = false;
  bool _autoRunTriggered = false;
  String? _activeLogLabel;
  BuildContext? _logSheetContext;
  bool _logSheetOpen = false;
  bool _showInstallLogs = false;
  final List<OnlineModule> _onlineModules = [];
  bool _onlineBusy = false;
  String? _onlineError;
  String _onlineQuery = '';

  @override
  void initState() {
    super.initState();
    _logSubscription = _shizukuLogs
        .receiveBroadcastStream()
        .listen(_handleLogEvent, onError: _handleLogError);
    _refreshShizukuStatus();
    _loadModules();
    _loadOnlineModules();
  }

  @override
  void dispose() {
    _logSubscription?.cancel();
    super.dispose();
  }

  void _handleLogEvent(dynamic event) {
    if (!mounted) return;
    final message = event.toString();
    setState(() {
      _logs.add(message);
      if (_logs.length > 2000) {
        _logs.removeRange(0, _logs.length - 2000);
      }
    });
    if (_activeLogLabel != null &&
        message.startsWith('[${_activeLogLabel!}]')) {
      final updated = List<String>.from(_runLogsNotifier.value)..add(message);
      _runLogsNotifier.value = updated;
    }
    if (_activeLogLabel != null &&
        message.contains('[${_activeLogLabel!}] exit=')) {
      Future<void>.delayed(const Duration(seconds: 2)).then((_) {
        _closeRunLogSheet();
        _activeLogLabel = null;
      });
    }
  }

  void _handleLogError(Object error) {
    if (!mounted) return;
    setState(() {
      _logs.add('Error de logs: $error');
    });
  }

  void _appendLog(String message) {
    if (!mounted) return;
    setState(() {
      _logs.add(message);
    });
  }

  Future<void> _refreshShizukuStatus() async {
    if (_shizukuBusy) {
      return;
    }
    setState(() {
      _shizukuBusy = true;
    });
    try {
      final result = await _shizukuChannel.invokeMapMethod<String, dynamic>(
        'checkPermission',
      );
      if (!mounted) return;
      final uidValue = result?['uid'];
      setState(() {
        _shizukuAvailable = result?['available'] == true;
        _shizukuGranted = result?['granted'] == true;
        _shizukuRationale = result?['shouldShowRationale'] == true;
        _shizukuPreV11 = result?['isPreV11'] == true;
        _shizukuUid = uidValue is int ? uidValue : null;
        _shizukuError = result?['error']?.toString();
        _shizukuBusy = false;
      });
      _autoRunModules();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _shizukuError = e.toString();
        _shizukuBusy = false;
      });
    }
  }

  Future<void> _requestShizukuPermission() async {
    if (_shizukuBusy) {
      return;
    }
    setState(() {
      _shizukuBusy = true;
    });
    try {
      await _shizukuChannel.invokeMethod<bool>('requestPermission');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _shizukuError = e.toString();
      });
    }
    if (!mounted) return;
    setState(() {
      _shizukuBusy = false;
    });
    await _refreshShizukuStatus();
  }

  Future<Directory> _modulesRoot() async {
    final baseDir = await getExternalStorageDirectory();
    if (baseDir == null) {
      throw StateError('External storage not available');
    }
    final dir = Directory(p.join(baseDir.path, 'modules'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _loadModules() async {
    if (_modulesBusy) return;
    setState(() {
      _modulesBusy = true;
    });
    try {
      final root = await _modulesRoot();
      final entries = <ModuleEntry>[];
      await for (final entity in root.list(followLinks: false)) {
        if (entity is Directory) {
          final mainPath = await _findScript(entity.path, 'main.sh');
          final uninstallPath =
              await _findScript(entity.path, 'uninstall.sh');
          entries.add(
            ModuleEntry(
              name: p.basename(entity.path),
              dir: entity.path,
              mainScript: mainPath,
              uninstallScript: uninstallPath,
            ),
          );
        }
      }
      if (!mounted) return;
      setState(() {
        _modules
          ..clear()
          ..addAll(entries);
        _modulesBusy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _modulesBusy = false;
      });
      _appendLog('Error al escanear módulos: $e');
    }
  }

  Future<String?> _findScript(String dirPath, String fileName) async {
    final dir = Directory(dirPath);
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File && p.basename(entity.path).toLowerCase() == fileName) {
        return entity.path;
      }
    }
    return null;
  }

  Future<void> _installModuleFromZip() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      if (result == null || result.files.single.path == null) {
        return;
      }

      final zipPath = result.files.single.path!;
      final bytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      final root = await _modulesRoot();
      final moduleName = p.basenameWithoutExtension(zipPath);
      final targetDir = Directory(p.join(root.path, moduleName));
      if (await targetDir.exists()) {
        await targetDir.delete(recursive: true);
      }
      await targetDir.create(recursive: true);

      for (final file in archive) {
        final filename = file.name;
        if (file.isFile) {
          final outFile = File(p.join(targetDir.path, filename));
          await outFile.parent.create(recursive: true);
          await outFile.writeAsBytes(file.content as List<int>);
        } else {
          await Directory(p.join(targetDir.path, filename))
              .create(recursive: true);
        }
      }

      await _loadModules();
      _appendLog('Módulo instalado: $moduleName');
    } catch (e) {
      _appendLog('Error al instalar: $e');
    }
  }

  Future<void> _installModuleFromUrl(OnlineModule module) async {
    try {
      setState(() {
        _onlineBusy = true;
        _onlineError = null;
      });
      final response = await http.get(Uri.parse(module.zipUrl));
      if (response.statusCode != 200) {
        throw StateError('HTTP ${response.statusCode}');
      }
      final archive = ZipDecoder().decodeBytes(response.bodyBytes);
      final root = await _modulesRoot();
      final moduleName = _sanitizeName(module.name);
      final targetDir = Directory(p.join(root.path, moduleName));
      if (await targetDir.exists()) {
        await targetDir.delete(recursive: true);
      }
      await targetDir.create(recursive: true);

      for (final file in archive) {
        final filename = file.name;
        if (file.isFile) {
          final outFile = File(p.join(targetDir.path, filename));
          await outFile.parent.create(recursive: true);
          await outFile.writeAsBytes(file.content as List<int>);
        } else {
          await Directory(p.join(targetDir.path, filename))
              .create(recursive: true);
        }
      }

      await _loadModules();
      _appendLog('Módulo instalado: ${module.name}');
    } catch (e) {
      setState(() {
        _onlineError = 'Error al descargar ${module.name}: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _onlineBusy = false;
        });
      }
    }
  }

  Future<void> _runModuleScript(ModuleEntry module, String? scriptPath) async {
    if (scriptPath == null) {
      _appendLog('No se encontró el script para ${module.name}.');
      return;
    }
    if (!_shizukuGranted || !_shizukuAvailable) {
      _appendLog('Permiso de Shizuku requerido para ${module.name}.');
      return;
    }
    _activeLogLabel = module.name;
    _runLogsNotifier.value = ['Iniciando ${module.name}...'];
    _openRunLogSheet();
    await Future<void>.delayed(const Duration(seconds: 2));
    try {
      await _shizukuChannel.invokeMethod('startScript', {
        'path': scriptPath,
        'workDir': module.dir,
        'label': module.name,
      });
    } catch (e) {
      _appendLog('Error al ejecutar: $e');
      if (mounted) {
        final updated =
            List<String>.from(_runLogsNotifier.value)..add('Error: $e');
        _runLogsNotifier.value = updated;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
      _closeRunLogSheet();
      _activeLogLabel = null;
    }
  }

  Future<void> _uninstallModule(ModuleEntry module) async {
    await _runModuleScript(module, module.uninstallScript);
    try {
      await Directory(module.dir).delete(recursive: true);
      await _loadModules();
      _appendLog('Módulo eliminado: ${module.name}');
    } catch (e) {
      _appendLog('Error al eliminar: $e');
    }
  }

  void _autoRunModules() {
    if (_autoRunTriggered || !_shizukuGranted || !_shizukuAvailable) {
      return;
    }
    _autoRunTriggered = true;
    Future<void>(() async {
      for (final module in _modules) {
        if (module.mainScript != null) {
          await _runModuleScript(module, module.mainScript);
        }
      }
    });
  }

  void _clearLogs() {
    setState(() {
      _logs.clear();
    });
  }

  String _sanitizeName(String name) {
    final cleaned = name.trim().replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return cleaned.isEmpty ? 'module' : cleaned;
  }

  Future<void> _loadOnlineModules() async {
    if (_onlineBusy) return;
    setState(() {
      _onlineBusy = true;
      _onlineError = null;
    });
    try {
      final uri = Uri.parse(
        'https://raw.githubusercontent.com/LozanoTH/modulos-adb-manager/refs/heads/main/modules.json',
      );
      final response = await http.get(uri);
      if (response.statusCode != 200) {
        throw StateError('HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final items = (decoded is List)
          ? decoded
          : (decoded is Map && decoded['modules'] is List)
              ? decoded['modules'] as List
              : <dynamic>[];
      final modules = <OnlineModule>[];
      for (final item in items) {
        if (item is Map) {
          final name = (item['name'] ?? item['title'] ?? '').toString();
          final desc = (item['description'] ?? item['desc'] ?? '')
              .toString();
          final url =
              (item['zip_url'] ?? item['url'] ?? item['zip'] ?? '').toString();
          if (name.isNotEmpty && url.isNotEmpty) {
            modules.add(
              OnlineModule(
                name: name,
                description: desc,
                zipUrl: url,
              ),
            );
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _onlineModules
          ..clear()
          ..addAll(modules);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _onlineError = 'No se pudo cargar: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _onlineBusy = false;
        });
      }
    }
  }

  void _openRunLogSheet() {
    if (_logSheetOpen || !mounted) return;
    _logSheetOpen = true;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        _logSheetContext = sheetContext;
        return _RunLogSheet(logs: _runLogsNotifier);
      },
    ).whenComplete(() {
      _logSheetOpen = false;
      _logSheetContext = null;
    });
  }

  void _closeRunLogSheet() {
    if (!_logSheetOpen || _logSheetContext == null) return;
    Navigator.of(_logSheetContext!).pop();
  }

  void _setTab(int index) {
    if (_tabIndex == index) return;
    setState(() {
      _tabIndex = index;
    });
  }

  Widget _buildHomeView() {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _TopBar(),
                const SizedBox(height: 24),
                Text(
                  'Estado del dispositivo',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                _StatusCard(
                  adbReady:
                      _shizukuAvailable && _shizukuGranted && !_shizukuPreV11,
                  uid: _shizukuUid,
                  modulesCount: _modules.length,
                ),
                const SizedBox(height: 16),
                _ShizukuCard(
                  available: _shizukuAvailable,
                  granted: _shizukuGranted,
                  shouldShowRationale: _shizukuRationale,
                  isPreV11: _shizukuPreV11,
                  busy: _shizukuBusy,
                  error: _shizukuError,
                  onRequest: _requestShizukuPermission,
                  onRefresh: _refreshShizukuStatus,
                ),
                const SizedBox(height: 24),
                Text(
                  'Acciones rápidas',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                _QuickActionRow(
                  onInstall: _installModuleFromZip,
                  onLogs: () => _setTab(1),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildModulesView() {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _TopBar(),
                const SizedBox(height: 24),
                _ModulesHeader(
                  busy: _modulesBusy,
                  onInstall: _installModuleFromZip,
                  onRefresh: _loadModules,
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: _ModulesGrid(
            modules: _modules,
            onRun: _runModuleScript,
            onUninstall: _uninstallModule,
          ),
        ),
        if (_showInstallLogs)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: _LogsPanel(
                logs: _logs,
                onClear: _clearLogs,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildOnlineView() {
    final filteredModules = _onlineQuery.trim().isEmpty
        ? _onlineModules
        : _onlineModules
            .where((m) =>
                m.name.toLowerCase().contains(_onlineQuery.toLowerCase()) ||
                m.description
                    .toLowerCase()
                    .contains(_onlineQuery.toLowerCase()))
            .toList();
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _TopBar(),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Módulos online',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    OutlinedButton(
                      onPressed: _onlineBusy ? null : _loadOnlineModules,
                      child: const Text('Refrescar'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  onChanged: (value) {
                    setState(() {
                      _onlineQuery = value;
                    });
                  },
                  decoration: InputDecoration(
                    hintText: 'Buscar módulos...',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surfaceVariant,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                  ),
                ),
                if (_onlineError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _onlineError!,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: const Color(0xFFFF6B6B)),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (_onlineBusy)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          )
        else if (filteredModules.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(
                  'No hay módulos disponibles.',
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final module = filteredModules[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _OnlineModuleCard(
                      module: module,
                      busy: _onlineBusy,
                      onInstall: () => _installModuleFromUrl(module),
                    ),
                  );
                },
                childCount: filteredModules.length,
              ),
            ),
          ),
      ],
    );
  }
  Widget _buildPlaceholderView(String title, String subtitle) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _TopBar(),
                const SizedBox(height: 24),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  subtitle,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSettingsView() {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _TopBar(),
                const SizedBox(height: 24),
                Text(
                  'Ajustes',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  value: _showInstallLogs,
                  onChanged: (value) {
                    setState(() {
                      _showInstallLogs = value;
                    });
                  },
                  title: const Text('Mostrar logs de instalación'),
                  subtitle: const Text(
                    'Muestra el panel de logs dentro de Módulos.',
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Acerca de',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Creador: Lozano Martinez Deiby Andres',
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(
                              color:
                                  Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'GitHub: `https://github.com/lozanoTH`',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(
                              color:
                                  Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            const _BackgroundGlow(),
            IndexedStack(
              index: _tabIndex,
              children: [
                _buildHomeView(),
                _buildModulesView(),
                _buildOnlineView(),
                _buildSettingsView(),
              ],
            ),
          ],
        ),
      ),
      bottomNavigationBar: _BottomNavBar(
        currentIndex: _tabIndex,
        onTap: _setTab,
      ),
    );
  }
}

class _BackgroundGlow extends StatelessWidget {
  const _BackgroundGlow();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          top: -120,
          left: -40,
          child: Container(
            width: 260,
            height: 260,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  Theme.of(context).colorScheme.primary.withOpacity(0.25),
                  Colors.transparent
                ],
              ),
            ),
          ),
        ),
        Positioned(
          bottom: -140,
          right: -40,
          child: Container(
            width: 320,
            height: 320,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  Theme.of(context).colorScheme.secondary.withOpacity(0.2),
                  Colors.transparent
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceVariant,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: Icon(
            Icons.shield_outlined,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ADB Manager',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'v28.2 (28000) · Stable',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
        const Spacer(),
        IconButton(
          onPressed: () {},
          icon: const Icon(Icons.notifications_none_outlined),
        ),
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  final bool adbReady;
  final int? uid;
  final int modulesCount;

  const _StatusCard({
    required this.adbReady,
    required this.uid,
    required this.modulesCount,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 16,
            offset: const Offset(0, 8),
          )
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.verified_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Estado del servicio',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Conexión ADB/Shizuku e identidad de shell',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              _TogglePill(active: adbReady),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _StatusMetric(label: 'ADB', value: adbReady ? 'OK' : 'NO'),
              _StatusMetric(
                label: 'UID shell',
                value: uid?.toString() ?? '--',
              ),
              _StatusMetric(
                label: 'Módulos',
                value: modulesCount.toString(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ShizukuCard extends StatelessWidget {
  final bool available;
  final bool granted;
  final bool shouldShowRationale;
  final bool isPreV11;
  final bool busy;
  final String? error;
  final VoidCallback onRequest;
  final VoidCallback onRefresh;

  const _ShizukuCard({
    required this.available,
    required this.granted,
    required this.shouldShowRationale,
    required this.isPreV11,
    required this.busy,
    required this.error,
    required this.onRequest,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    String headline;
    String detail;
    Color accent;

    if (isPreV11) {
      headline = 'Shizuku pre-v11';
      detail = 'No compatible con esta versión de Shizuku.';
      accent = const Color(0xFFFF6B6B);
    } else if (!available) {
      headline = 'Shizuku no activo';
      detail = 'Inicia Shizuku y toca Refrescar.';
      accent = const Color(0xFFFFC857);
    } else if (granted) {
      headline = 'Shizuku listo';
      detail = 'Permiso concedido. Acceso a la API disponible.';
      accent = const Color(0xFF1ED760);
    } else {
      headline = 'Permiso requerido';
      detail = shouldShowRationale
          ? 'Permiso denegado antes. Permítelo en Shizuku.'
          : 'Toca Solicitar acceso para conceder el permiso.';
      accent = const Color(0xFF4FC3F7);
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.usb_outlined, color: accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      headline,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      detail,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (error != null && error!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              error!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: (!busy && available && !granted && !isPreV11)
                      ? onRequest
                      : null,
                  child: Text(busy ? 'Solicitando...' : 'Solicitar acceso'),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: busy ? null : onRefresh,
                child: const Text('Refrescar'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ModulesHeader extends StatelessWidget {
  final bool busy;
  final VoidCallback onInstall;
  final VoidCallback onRefresh;

  const _ModulesHeader({
    required this.busy,
    required this.onInstall,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            'Módulos',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        FilledButton.icon(
          onPressed: busy ? null : onInstall,
          icon: const Icon(Icons.download_outlined),
          label: const Text('Instalar ZIP'),
        ),
        const SizedBox(width: 12),
        OutlinedButton(
          onPressed: busy ? null : onRefresh,
          child: const Text('Refrescar'),
        ),
      ],
    );
  }
}

class _ModulesGrid extends StatelessWidget {
  final List<ModuleEntry> modules;
  final Future<void> Function(ModuleEntry module, String? scriptPath) onRun;
  final Future<void> Function(ModuleEntry module) onUninstall;

  const _ModulesGrid({
    required this.modules,
    required this.onRun,
    required this.onUninstall,
  });

  @override
  Widget build(BuildContext context) {
    if (modules.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: Text(
              'Aún no hay módulos instalados.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
        ),
      );
    }

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final module = modules[index];
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _ModuleCard(
              module: module,
              onRun: () => onRun(module, module.mainScript),
              onUninstall: () => onUninstall(module),
            ),
          );
        },
        childCount: modules.length,
      ),
    );
  }
}
class _ModuleCard extends StatelessWidget {
  final ModuleEntry module;
  final VoidCallback onRun;
  final VoidCallback onUninstall;

  const _ModuleCard({
    required this.module,
    required this.onRun,
    required this.onUninstall,
  });

  @override
  Widget build(BuildContext context) {
    final hasMain = module.mainScript != null;
    final hasUninstall = module.uninstallScript != null;
    return SizedBox(
      height: 72,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color:
                    Theme.of(context).colorScheme.primary.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.widgets_outlined,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                module.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: hasMain ? onRun : null,
              icon: const Icon(Icons.play_arrow_rounded),
              tooltip: 'Ejecutar',
            ),
            IconButton(
              onPressed: hasUninstall ? onUninstall : null,
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Desinstalar',
            ),
          ],
        ),
      ),
    );
  }
}

class _LogsPanel extends StatelessWidget {
  final List<String> logs;
  final VoidCallback onClear;

  const _LogsPanel({required this.logs, required this.onClear});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Logs de instalación',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              OutlinedButton(
                onPressed: onClear,
                child: const Text('Limpiar'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            constraints: const BoxConstraints(minHeight: 120, maxHeight: 220),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceVariant,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: SingleChildScrollView(
              reverse: true,
              child: SelectableText(
                logs.isEmpty ? 'Aún no hay logs.' : logs.join('\\n'),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.4,
                  color: Colors.black87,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RunLogSheet extends StatelessWidget {
  final ValueNotifier<List<String>> logs;

  const _RunLogSheet({required this.logs});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.terminal,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Ejecución en curso',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 260),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceVariant,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: ValueListenableBuilder<List<String>>(
                valueListenable: logs,
                builder: (context, value, _) {
                  return SingleChildScrollView(
                    reverse: true,
                    child: SelectableText(
                      value.isEmpty ? 'Esperando salida...' : value.join('\n'),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        height: 1.4,
                        color: Colors.black87,
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Ejecutando...',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _OnlineModuleCard extends StatelessWidget {
  final OnlineModule module;
  final VoidCallback onInstall;
  final bool busy;

  const _OnlineModuleCard({
    required this.module,
    required this.onInstall,
    required this.busy,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            module.name,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          if (module.description.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              module.description,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: busy ? null : onInstall,
              icon: const Icon(Icons.download_outlined),
              label: const Text('Instalar'),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusMetric extends StatelessWidget {
  final String label;
  final String value;

  const _StatusMetric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceVariant,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TogglePill extends StatelessWidget {
  final bool active;

  const _TogglePill({required this.active});

  @override
  Widget build(BuildContext context) {
    final color = active
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.error;
    final bgColor = active
        ? Theme.of(context).colorScheme.primaryContainer
        : Theme.of(context).colorScheme.errorContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color),
      ),
      child: Row(
        children: [
          Icon(Icons.power_settings_new, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            active ? 'Activo' : 'Inactivo',
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color accent;

  const _ActionTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: accent.withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: accent),
          ),
          const Spacer(),
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}

class _QuickActionRow extends StatelessWidget {
  final VoidCallback onInstall;
  final VoidCallback onLogs;

  const _QuickActionRow({
    required this.onInstall,
    required this.onLogs,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _QuickButton(
          label: 'Instalar',
          icon: Icons.download_outlined,
          color: const Color(0xFF1ED760),
          onTap: onInstall,
        ),
        const SizedBox(width: 12),
        _QuickButton(
          label: 'Logs',
          icon: Icons.receipt_long_outlined,
          color: const Color(0xFFFFC857),
          onTap: onLogs,
        ),
      ],
    );
  }
}

class _QuickButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _QuickButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: Column(
            children: [
              Icon(icon, color: color),
              const SizedBox(height: 8),
              Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomNavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const _BottomNavBar({
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _NavItem(
            icon: Icons.dashboard_outlined,
            label: 'Inicio',
            active: currentIndex == 0,
            onTap: () => onTap(0),
          ),
          _NavItem(
            icon: Icons.extension_outlined,
            label: 'Módulos',
            active: currentIndex == 1,
            onTap: () => onTap(1),
          ),
          _NavItem(
            icon: Icons.cloud_download_outlined,
            label: 'Online',
            active: currentIndex == 2,
            onTap: () => onTap(2),
          ),
          _NavItem(
            icon: Icons.settings_outlined,
            label: 'Ajustes',
            active: currentIndex == 3,
            onTap: () => onTap(3),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.label,
    this.active = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = active
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(height: 4),
              Text(
                label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
