import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_vlc_player/flutter_vlc_player.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.immersiveSticky,
  ); // <-- Add this line
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const VisionaryDroneApp());
}

class VisionaryDroneApp extends StatelessWidget {
  const VisionaryDroneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Visionary Drone',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const DroneControlScreen(),
    );
  }
}

class DroneControlScreen extends StatefulWidget {
  const DroneControlScreen({super.key});

  @override
  State<DroneControlScreen> createState() => _DroneControlScreenState();
}

class _DroneControlScreenState extends State<DroneControlScreen>
    with SingleTickerProviderStateMixin {
  late VlcPlayerController _vlcController;
  late WebSocketChannel _webSocketChannel;
  String _status = 'Disconnected';
  String _storage = 'Unknown';
  String _wifi = 'Unknown';
  String _battery = 'Unknown';
  Offset? _subjectPosition;
  final double _currentHeight = 0; // Example, update this as needed
  bool _isCommanding = false;
  bool _isVideoInitialized = false;
  bool _isRecording = false;
  bool _toggleValue = false; // <-- Add this line
  bool _showFlightModes = false; // <-- Add this line

  Offset _leftJoystick = Offset.zero;
  Offset _rightJoystick = Offset.zero;
  Timer? _rcTimer;
  late AnimationController _animationController;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    )..repeat(reverse: true);

    try {
      _vlcController = VlcPlayerController.network(
        'udp://@0.0.0.0:11111',
        autoPlay: true,
      );
      _vlcController.addOnInitListener(() {
        setState(() {
          _isVideoInitialized = true;
          _status = 'Video Stream Connected';
        });
      });
      // Remove addOnErrorListener (not available)
    } catch (e) {
      setState(() {
        _isVideoInitialized = false;
        _status = 'VLC Init Error: $e';
      });
    }

    try {
      _webSocketChannel = WebSocketChannel.connect(
        Uri.parse('ws://192.168.10.100:8765'), // Replace with your laptop IP
      );
      _webSocketChannel.stream.listen(
        (message) {
          final data = jsonDecode(message);
          setState(() {
            if (data['state'] != null) {
              String state = data['state'];
              RegExp batteryReg = RegExp(r'bat:(\d+);');
              _battery = batteryReg.firstMatch(state)?.group(1) ?? 'Unknown';
              _status = 'Battery: $_battery%';
            } else {
              _status = 'Received: ${data['status'] ?? message}';
            }
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(_status)));
          });
        },
        onError: (error) {
          setState(() => _status = 'WebSocket Error: $error');
        },
        onDone: () {
          setState(() => _status = 'WebSocket Disconnected');
        },
      );
    } catch (e) {
      setState(() => _status = 'WebSocket Init Error: $e');
    }

    _updateStorage();
    _updateWiFi();
  }

  Future<void> _updateStorage() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final stat = await directory.stat();
      final statvfs = await FileStat.stat(directory.path);
      setState(() {
        _storage = '${(stat.size / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
      });
      // On Android, use the root of external storage for accurate info
      Directory? extDir;
      if (Platform.isAndroid) {
        extDir = await getExternalStorageDirectory();
      }
      final statExt = extDir != null ? await extDir.stat() : null;

      // Use FileSystemEntity.statSync for total/free space (works on Android)
      final statvfsExt = extDir != null
          ? await FileStat.stat(extDir.path)
          : null;

      // Use the FileSystemEntity for the external storage directory
      final statvfsPath = extDir?.path ?? directory.path;
      final statvfsInfo = await FileStat.stat(statvfsPath);

      // Use the statvfsInfo to get total and free space
      final totalSpace = await _getTotalSpace(statvfsPath);
      final freeSpace = await _getFreeSpace(statvfsPath);

      if (totalSpace != null && freeSpace != null) {
        final used = totalSpace - freeSpace;
        setState(() {
          _storage =
              '${(used / 1024 / 1024 / 1024).toStringAsFixed(2)} / ${(totalSpace / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
        });
      } else {
        setState(() => _storage = 'Unknown');
      }
    } catch (e) {
      setState(() => _storage = 'Unknown');
    }
  }

  // Helper functions for Android/Linux
  Future<int?> _getTotalSpace(String path) async {
    try {
      final result = await Process.run('df', [path]);
      if (result.exitCode == 0) {
        final lines = result.stdout.toString().split('\n');
        if (lines.length > 1) {
          final parts = lines[1].split(RegExp(r'\s+'));
          if (parts.length > 1) {
            return int.tryParse(parts[1])! * 1024;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<int?> _getFreeSpace(String path) async {
    try {
      final result = await Process.run('df', [path]);
      if (result.exitCode == 0) {
        final lines = result.stdout.toString().split('\n');
        if (lines.length > 1) {
          final parts = lines[1].split(RegExp(r'\s+'));
          if (parts.length > 3) {
            return int.tryParse(parts[3])! * 1024;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _updateWiFi() async {
    final connectivity = await Connectivity().checkConnectivity();
    setState(
      () => _wifi = connectivity.contains(ConnectivityResult.wifi)
          ? 'Connected'
          : 'Disconnected',
    );
  }

  void _sendCommand(String command, [Map<String, dynamic>? data]) {
    if (_isCommanding) return;
    setState(() => _isCommanding = true);
    final message = {'command': command, if (data != null) ...data};
    try {
      _webSocketChannel.sink.add(jsonEncode(message));
      setState(() => _status = 'Sent: $command');
    } catch (e) {
      setState(() => _status = 'Send Error: $e');
    }
    Future.delayed(const Duration(seconds: 1), () {
      setState(() => _isCommanding = false);
    });
  }

  void _sendRCCommand() {
    final leftX = (_leftJoystick.dx * 100).clamp(-100, 100).toInt();
    final leftY = (_leftJoystick.dy * -100).clamp(-100, 100).toInt();
    final rightX = (_rightJoystick.dx * 100).clamp(-100, 100).toInt();
    final rightY = (_rightJoystick.dy * -100).clamp(-100, 100).toInt();
    _sendCommand('rc', {
      'left_right': leftX,
      'forward_backward': leftY,
      'up_down': rightY,
      'yaw': rightX,
    });
  }

  Future<void> _takePhoto() async {
    final dir = await getApplicationDocumentsDirectory();
    final path =
        '${dir.path}/photo_${DateTime.now().millisecondsSinceEpoch}.png';
    // Note: flutter_vlc_player may not support direct snapshot saving
    setState(() => _status = 'Photo saving not supported; use server-side');
    // Implement server-side snapshot via WebSocket if needed
    _sendCommand('take_photo', {'path': path});
  }

  void _toggleRecording() {
    setState(() {
      _isRecording = !_isRecording;
      _status = _isRecording ? 'Recording Started' : 'Recording Stopped';
      _sendCommand(_isRecording ? 'start_recording' : 'stop_recording');
    });
  }

  Future<void> _openGallery() async {
    final permission = await PhotoManager.requestPermissionExtend();
    if (permission.isAuth) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const GalleryScreen()),
      );
    } else {
      setState(() => _status = 'Gallery permission denied');
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    _vlcController.dispose();
    _webSocketChannel.sink.close();
    _rcTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Center(
            child: _isVideoInitialized
                ? VlcPlayer(
                    controller: _vlcController,
                    aspectRatio: 16 / 9,
                    placeholder: const Center(
                      child: CircularProgressIndicator(),
                    ),
                  )
                : Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ElevatedButton(
                          onPressed: () {
                            setState(() {
                              _vlcController = VlcPlayerController.network(
                                'udp://@0.0.0.0:11111',
                                autoPlay: true,
                              );
                              _vlcController.addOnInitListener(() {
                                setState(() {
                                  _isVideoInitialized = true;
                                  _status = 'Video Stream Connected';
                                });
                              });
                            });
                          },
                          child: const Text('Retry Video'),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _status,
                          style: const TextStyle(color: Colors.redAccent),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
          ),
          // ...existing code...
          // Modern Height Scale Indicator
          Positioned(
            left: 20,
            top: 55,
            bottom: 140,
            child: Container(
              width: 50,
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(60),
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(50),
                    blurRadius: 12,
                    offset: const Offset(2, 2),
                  ),
                ],
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Vertical scale with ticks and numbers
                  Positioned.fill(
                    left: 18,
                    child: CustomPaint(
                      painter: _HeightScalePainter(
                        tickCount:
                            11, // Odd number for symmetry, covers -25 to +25 if majorTickEvery=5
                        majorTickEvery: 5,
                        tickColor: Colors.blueAccent.shade100,
                        majorTickColor: Colors.indigo,
                        currentHeight: _currentHeight,
                      ),
                    ),
                  ),
                  // Modernized Height label at the middle
                  // Small badge for current height at the middle
                  Align(
                    alignment: Alignment.centerRight,
                    child: RotatedBox(
                      quarterTurns: -1,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.indigo.withAlpha(200),
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.indigo.withAlpha(46),
                              blurRadius: 4,
                              offset: const Offset(0, 1),
                            ),
                          ],
                        ),
                        child: Text(
                          '${_currentHeight.toStringAsFixed(1)}m',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Add a colored dot/line at the middle
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      width: 18,
                      height: 6,
                      decoration: BoxDecoration(
                        color: Colors.redAccent,
                        borderRadius: BorderRadius.circular(3),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.redAccent.withOpacity(0.25),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ...existing code...
          // ...existing code...
          Positioned(
            // ...existing code...
            top: 10,
            left: 10,
            right: 10,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Storage (phone icon + text)
                Row(
                  children: [
                    Container(
                      height: 30,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.phone_android,
                            color: Colors.white,
                            size: 18,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _storage,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 18), // <-- Increased space before 'A'
                    // Add 'A' label (left of toggle)
                    const Text(
                      'A',
                      style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(width: 1),
                    SizedBox(
                      width: 80,
                      child: Transform.scale(
                        // Horizontal stretch
                        scaleX: 1.2, // Horizontal stretch
                        scaleY: 1.1, // No vertical stretch
                        child: Switch(
                          value: _toggleValue,
                          // ...inside your Switch's onChanged callback...
                          onChanged: (val) {
                            setState(() {
                              _toggleValue = val;
                            });
                            // Advanced, compact, and more transparent toast/snackbar
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      val
                                          ? Icons.settings_remote
                                          : Icons.autorenew,
                                      color: Colors.white.withAlpha(200),
                                      size: 22,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      val
                                          ? 'Manual Mode Enabled'
                                          : 'Auto Mode Enabled',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 15,
                                        color: Colors.white,
                                        letterSpacing: 0.2,
                                      ),
                                    ),
                                  ],
                                ),
                                backgroundColor:
                                    (val ? Colors.indigo : Colors.blueGrey)
                                        .withAlpha(200), // More transparent
                                duration: const Duration(seconds: 2),
                                behavior: SnackBarBehavior.floating,
                                margin: const EdgeInsets.only(
                                  bottom: 40,
                                  left: 120,
                                  right: 120,
                                ), // Compact and centered
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                elevation: 6,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 18,
                                  vertical: 10,
                                ),
                              ),
                            );
                          },
                          activeColor: Colors.blueGrey,
                          inactiveThumbColor: Colors.grey,
                          inactiveTrackColor: Colors.white24,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ),
                    const Text(
                      'M',
                      style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
                // WiFi and Battery together
                Container(
                  height: 30,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.wifi, color: Colors.white, size: 18),
                      const SizedBox(width: 4),
                      Text(_wifi, style: const TextStyle(color: Colors.white)),
                      const SizedBox(width: 12),
                      const Icon(
                        Icons.battery_full,
                        color: Colors.white,
                        size: 18,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '$_battery%',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ...existing code...

          //     // WiFi (wifi icon + text)
          //     // WiFi and Battery together
          //     Container(
          //       height: 30,
          //       padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          //       decoration: BoxDecoration(
          //         color: Colors.black54,
          //         borderRadius: BorderRadius.circular(8),
          //       ),
          //       child: Row(
          //         children: [
          //           const Icon(Icons.wifi, color: Colors.white, size: 18),
          //           const SizedBox(width: 4),
          //           Text(
          //             _wifi,
          //             style: const TextStyle(color: Colors.white),
          //           ),
          //           const SizedBox(width: 12),
          //           const Icon(Icons.battery_full, color: Colors.white, size: 18),
          //           const SizedBox(width: 4),
          //           Text(
          //             '$_battery%',
          //             style: const TextStyle(color: Colors.white),
          //           ),
          //         ],
          //       ),
          //     ),

          //   ],
          // ),

          // ...existing code...
          if (_isRecording)
            Positioned(
              top: 50,
              right: 15,
              child: Row(
                children: [
                  AnimatedBuilder(
                    animation: _animationController,
                    builder: (context, child) {
                      return Container(
                        width: 15,
                        height: 15,
                        decoration: BoxDecoration(
                          color: Colors.red.withAlpha(
                            (_animationController.value * 255).toInt(),
                          ),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.red.withAlpha(130),
                              blurRadius: 5,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 5),
                  const Text(
                    'REC',
                    style: TextStyle(
                      color: Colors.red,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          // GestureDetector(
          //   onTapDown: (details) {
          //     final size = MediaQuery.of(context).size;
          //     setState(() {
          //       _subjectPosition = details.localPosition;
          //       _sendCommand('select_subject', {
          //         'x': _subjectPosition!.dx / size.width,
          //         'y': _subjectPosition!.dy / size.height,
          //       });
          //     });
          //   },
          //   child: Container(color: Colors.transparent),
          // ),
          if (_subjectPosition != null)
            Positioned(
              left: _subjectPosition!.dx - 10,
              top: _subjectPosition!.dy - 10,
              child: Container(
                width: 20,
                height: 20,
                decoration: const BoxDecoration(
                  color: Color.fromRGBO(255, 0, 0, 0.5),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          Positioned(
            bottom: 30,
            left: 125,
            child: Joystick(
              isLeft: true,
              onChanged: (offset) {
                setState(() => _leftJoystick = offset);
                _rcTimer ??= Timer.periodic(
                  const Duration(milliseconds: 100),
                  (_) => _sendRCCommand(),
                );
              },
              onReleased: () {
                setState(() => _leftJoystick = Offset.zero);
                _rcTimer?.cancel();
                _rcTimer = null;
                _sendCommand('rc', {
                  'left_right': 0,
                  'forward_backward': 0,
                  'up_down': 0,
                  'yaw': 0,
                });
              },
            ),
          ),
          Positioned(
            bottom: 30,
            right: 105,
            child: Joystick(
              isLeft: false,
              onChanged: (offset) {
                setState(() => _rightJoystick = offset);
                _rcTimer ??= Timer.periodic(
                  const Duration(milliseconds: 100),
                  (_) => _sendRCCommand(),
                );
              },
              onReleased: () {
                setState(() => _rightJoystick = Offset.zero);
                _rcTimer?.cancel();
                _rcTimer = null;
                _sendCommand('rc', {
                  'left_right': 0,
                  'forward_backward': 0,
                  'up_down': 0,
                  'yaw': 0,
                });
              },
            ),
          ),
          Positioned(
            bottom: 20,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
              margin: const EdgeInsets.symmetric(horizontal: 335),
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(30),
                borderRadius: BorderRadius.circular(30),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.photo_library,
                      color: Colors.black,
                      size: 32,
                    ),
                    onPressed: _openGallery,
                    tooltip: 'Gallery',
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.camera_alt,
                      color: Colors.black,
                      size: 32,
                    ),
                    onPressed: _takePhoto,
                    tooltip: 'Take Photo',
                  ),
                  // --- Modernized Menu Button ---
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      IconButton(
                        icon: const Icon(
                          Icons.menu,
                          color: Colors.black,
                          size: 32,
                        ),
                        onPressed: () {
                          setState(() {
                            _showFlightModes = !_showFlightModes;
                          });
                        },
                        tooltip: 'Flight Modes',
                      ),
                      if (_showFlightModes)
                        Positioned(
                          top: -170,
                          left: -60,
                          child: Material(
                            color: Colors.transparent,
                            child: Container(
                              width: 210,
                              constraints: const BoxConstraints(maxHeight: 220),
                              padding: const EdgeInsets.symmetric(
                                vertical: 14,
                                horizontal: 16,
                              ),
                              decoration: BoxDecoration(
                                // Use .withAlpha for transparency (e.g. 180/255 ≈ 70% opacity)
                                color: Colors.black.withAlpha(120),
                                borderRadius: BorderRadius.circular(18),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withAlpha(40),
                                    blurRadius: 18,
                                    offset: const Offset(0, 8),
                                  ),
                                ],
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.flight_takeoff,
                                        color: Colors.indigo.shade700,
                                        size: 20,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Flight Modes',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: Colors.indigo.shade700,
                                          fontSize: 16,
                                          letterSpacing: 0.2,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  // Use a ListView for scrollable options if more are added
                                  SizedBox(
                                    height: 120,
                                    child: ListView(
                                      shrinkWrap: true,
                                      physics: const BouncingScrollPhysics(),
                                      children: [
                                        _FlightModeOption(
                                          icon: Icons.person_pin_circle,
                                          label: 'Follow',
                                          color: Colors.indigo,
                                          onTap: _isCommanding
                                              ? null
                                              : () {
                                                  setState(
                                                    () => _showFlightModes =
                                                        false,
                                                  );
                                                  _sendCommand('follow');
                                                },
                                        ),
                                        const SizedBox(height: 10),
                                        _FlightModeOption(
                                          icon: Icons.sync,
                                          label: 'Orbit',
                                          color: Colors.blueGrey,
                                          onTap: _isCommanding
                                              ? null
                                              : () {
                                                  setState(
                                                    () => _showFlightModes =
                                                        false,
                                                  );
                                                  _sendCommand('orbit');
                                                },
                                        ),
                                        // Add more options here as needed, e.g.:
                                        // _FlightModeOption(
                                        //   icon: Icons.alt_route,
                                        //   label: 'Waypoint',
                                        //   color: Colors.deepPurple,
                                        //   onTap: ...,
                                        // ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  IconButton(
                    icon: Icon(
                      _isRecording ? Icons.stop : Icons.videocam,
                      color: Colors.black,
                      size: 32,
                    ),
                    onPressed: _toggleRecording,
                    tooltip: _isRecording
                        ? 'Stop Recording'
                        : 'Start Recording',
                  ),
                ],
              ),
            ),
          ),

          // Positioned(
          //   top: 80,
          //   right: 10,
          //   child: Column(
          //     children: [
          //       ElevatedButton(
          //         onPressed: _isCommanding ? null : () => _sendCommand('follow'),
          //         child: const Text('Follow'),
          //       ),
          //       const SizedBox(height: 10),
          //       ElevatedButton(
          //         onPressed: _isCommanding ? null : () => _sendCommand('orbit'),
          //         child: const Text('Orbit'),
          //       ),
          //       const SizedBox(height: 10),
          //       ElevatedButton(
          //         onPressed: () => _sendCommand('emergency_stop'),
          //         style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
          //         child: const Text('Emergency Stop'),
          //       ),
          //     ],
          //   ),
          // ),
        ],
      ),
    );
  }
}

class Joystick extends StatefulWidget {
  final Function(Offset) onChanged;
  final VoidCallback onReleased;
  final bool isLeft;

  const Joystick({
    super.key,
    required this.onChanged,
    required this.onReleased,
    this.isLeft = true,
  });
  @override
  _JoystickState createState() => _JoystickState();
}

class _JoystickState extends State<Joystick>
    with SingleTickerProviderStateMixin {
  Offset _offset = Offset.zero;
  late AnimationController _controller;
  late Animation<Offset> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
    _animation =
        Tween<Offset>(begin: Offset.zero, end: Offset.zero).animate(_controller)
          ..addListener(() {
            setState(() {
              _offset = _animation.value;
            });
          });
  }

  void _animateToCenter() {
    _animation =
        Tween<Offset>(begin: _offset, end: Offset.zero).animate(_controller)
          ..addListener(() {
            setState(() {
              _offset = _animation.value;
            });
          })
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed) {
              setState(() {
                _offset = Offset.zero; // Ensure knob is exactly centered
              });
            }
          });
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanUpdate: (details) {
        final delta = details.localPosition - const Offset(60, 60);
        final distance = delta.distance;
        final maxRadius = 48.0;
        final normalized = distance > maxRadius
            ? delta * (maxRadius / distance)
            : delta;
        setState(() {
          _offset = normalized / maxRadius;
          widget.onChanged(_offset);
        });
      },
      onPanEnd: (_) {
        _animateToCenter();
        widget.onReleased();
      },
      child: SizedBox(
        width: 150,
        height: 150,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Outer ring
            Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [Colors.blueGrey.shade100, Colors.blueGrey.shade300],
                  center: Alignment.center,
                  radius: 0.95,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.18),
                    blurRadius: 12,
                  ),
                ],
              ),
            ),
            // Progress ring (feedback)
            Positioned.fill(
              child: CustomPaint(
                painter: _JoystickRingPainter(offset: _offset),
              ),
            ),
            // ICONS: Place here for both left and right joystick
            if (widget.isLeft) ...[
              // Up
              Positioned(
                top: 10,
                left: 60,
                child: Icon(
                  Icons.arrow_upward,
                  color: Colors.blueGrey.shade700,
                  size: 28,
                ),
              ),
              // Down
              Positioned(
                bottom: 10,
                left: 60,
                child: Icon(
                  Icons.arrow_downward,
                  color: Colors.blueGrey.shade700,
                  size: 28,
                ),
              ),
              // Rotate Left
              Positioned(
                left: 10,
                top: 60,
                child: Icon(
                  Icons.rotate_left,
                  color: Colors.blueGrey.shade700,
                  size: 28,
                ),
              ),
              // Rotate Right
              Positioned(
                right: 10,
                top: 60,
                child: Icon(
                  Icons.rotate_right,
                  color: Colors.blueGrey.shade700,
                  size: 28,
                ),
              ),
            ] else ...[
              // Up Arrow
              Positioned(
                top: 10,
                left: 60,
                child: Icon(
                  Icons.arrow_upward,
                  color: Colors.blueGrey.shade700,
                  size: 28,
                ),
              ),
              // Down Arrow
              Positioned(
                bottom: 10,
                left: 60,
                child: Icon(
                  Icons.arrow_downward,
                  color: Colors.blueGrey.shade700,
                  size: 28,
                ),
              ),
              // Left Arrow
              Positioned(
                left: 10,
                top: 60,
                child: Icon(
                  Icons.arrow_back,
                  color: Colors.blueGrey.shade700,
                  size: 28,
                ),
              ),
              // Right Arrow
              Positioned(
                right: 10,
                top: 60,
                child: Icon(
                  Icons.arrow_forward,
                  color: Colors.blueGrey.shade700,
                  size: 28,
                ),
              ),
            ],
            // Knob
            Transform.translate(
              offset: _offset * 48,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [Colors.blueAccent, Colors.black],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.blueAccent.withOpacity(0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Center(
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.7),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _JoystickRingPainter extends CustomPainter {
  final Offset offset;
  _JoystickRingPainter({required this.offset});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 8;
    final paint = Paint()
      ..color = Colors.blueAccent.withOpacity(0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8;

    // Draw base ring
    canvas.drawCircle(center, radius, paint);

    // Draw feedback arc
    if (offset.distance > 0.05) {
      final angle = offset.direction;
      final sweep = offset.distance * 3.14;
      final arcPaint = Paint()
        ..shader = SweepGradient(
          colors: [Colors.blueAccent, Colors.lightBlueAccent],
          startAngle: angle - sweep / 2,
          endAngle: angle + sweep / 2,
        ).createShader(Rect.fromCircle(center: center, radius: radius))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        angle - sweep / 2,
        sweep,
        false,
        arcPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _JoystickRingPainter oldDelegate) =>
      oldDelegate.offset != offset;
}

class GalleryScreen extends StatelessWidget {
  const GalleryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Gallery')),
      body: const Center(child: Text('Gallery implementation TBD')),
    );
  }
}

class _HeightScalePainter extends CustomPainter {
  final int tickCount;
  final int majorTickEvery;
  final Color tickColor;
  final Color majorTickColor;
  final double currentHeight;

  _HeightScalePainter({
    required this.tickCount,
    required this.majorTickEvery,
    required this.tickColor,
    required this.majorTickColor,
    required this.currentHeight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double tickLength = 12;
    final double majorTickLength = 26;
    final double tickWidth = 2;
    final double spacing = size.height / (tickCount - 1);
    final int middleIndex = tickCount ~/ 2;

    final textStyle = TextStyle(
      color: majorTickColor,
      fontWeight: FontWeight.w500,
      fontSize: 14,
      shadows: [Shadow(color: Colors.white.withAlpha(150), blurRadius: 2)],
    );

    for (int i = 0; i < tickCount; i++) {
      final isMajor = (i - middleIndex) % majorTickEvery == 0;
      final paint = Paint()
        ..color = isMajor ? majorTickColor : tickColor
        ..strokeWidth = tickWidth
        ..strokeCap = StrokeCap.round;
      final y = i * spacing;
      canvas.drawLine(
        Offset(isMajor ? 0 : 8, y),
        Offset(isMajor ? majorTickLength : tickLength, y),
        paint,
      );

      // Draw label for major ticks
      if (isMajor) {
        int diff = i - middleIndex;
        double labelValue = currentHeight + diff;
        // Snap to nearest 5 for major ticks
        labelValue = currentHeight + (diff ~/ majorTickEvery) * majorTickEvery;
        final textSpan = TextSpan(
          text: labelValue.toStringAsFixed(0),
          style: textStyle,
        );
        final textPainter = TextPainter(
          text: textSpan,
          textDirection: TextDirection.ltr,
        );
        textPainter.layout();
        textPainter.paint(
          canvas,
          Offset(majorTickLength + 6, y - textPainter.height / 2),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class _FlightModeOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _FlightModeOption({
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.5 : 1.0,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          decoration: BoxDecoration(
            color: color.withAlpha(38), // subtle background for each option
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(width: 14),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
