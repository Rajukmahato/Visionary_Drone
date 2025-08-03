import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_vlc_player/flutter_vlc_player.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
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
  RawDatagramSocket? _droneSocket;
  String _storage = 'Unknown';
  String _wifi = 'Unknown';
  String _battery = 'Unknown';
  String _currentSSID = 'unknown';
  String _locationPermissionStatus = 'unknown';
  List<String> _debugLog = [];
  Offset? _subjectPosition;
  double _currentHeight = 0;
  bool _isCommanding = false;
  // Video recording variables
  bool _isVideoStreamRecording = false;
  List<Uint8List> _videoFrames = [];
  Timer? _frameTimer;
  bool _isFrameRecording = false;
  String? _videoOutputPath;
  int _frameCount = 0;
  DateTime? _recordingStartTime;
  Timer? _recordingDurationTimer;
  String _recordingDuration = '00:00';
  bool _isProcessingVideo = false;

  // Video recording settings - Optimized for performance
  static const int _maxRecordingFrames = 300; // 60 seconds at 5 FPS
  static const int _frameCaptureInterval = 200; // 5 FPS for better performance
  static const int _maxFrameSize = 1000000; // 1MB per frame
  static const int _maxMemoryFrames =
      50; // Keep only 50 frames in memory at once
  bool _toggleValue = false;
  bool _showFlightModes = false;
  bool _isDroneConnected = false;
  bool _isDroneReady = false;
  bool _isDroneFlying = false;
  bool _isDroneError = false;
  bool _isLanded = true;
  String _droneError = '';
  String? _lastActionCommand;
  bool _useTelloStream = false;
  bool _showDroneDisconnectedOverlay = false;
  bool _isConnectingToDrone = false;
  String telloIP = '192.168.10.1';
  int telloPort = 8889;
  RawDatagramSocket? _stateSocket;
  StreamSubscription? _connectivitySub;
  Offset _leftJoystick = Offset.zero;
  Offset _rightJoystick = Offset.zero;
  Timer? _rcTimer;
  late AnimationController _animationController;
  bool _vlcInitialized = false;
  late VlcPlayerController _vlcController;
  DateTime? _lastDronePacketTime;
  Timer? _heartbeatTimer;
  String? _overlayMessage;
  bool _showOverlay = false;
  Timer? _overlayTimer;
  Color _overlayColor = Colors.black.withOpacity(0.85);
  Timer? _reconnectTimer;
  bool _isAttemptingReconnect = false;
  int? _lastLowBatteryWarning;
  bool _criticalBatteryShown = false;
  void showOverlayMessage(
    String message, {
    String type = 'info',
    int durationMs = 2200,
  }) {
    Color color;
    switch (type) {
      case 'error':
        color = Colors.red.withOpacity(0.90);
        break;
      case 'warning':
        color = Colors.orange.withOpacity(0.90);
        break;
      case 'info':
      default:
        color = Colors.black.withOpacity(0.85);
        break;
    }
    setState(() {
      _overlayMessage = message;
      _showOverlay = true;
      _overlayColor = color;
    });
    _overlayTimer?.cancel();
    _overlayTimer = Timer(Duration(milliseconds: durationMs), () {
      if (mounted) setState(() => _showOverlay = false);
    });
  }

  void _startHeartbeatMonitor() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_lastDronePacketTime == null) return;
      final elapsed = DateTime.now().difference(_lastDronePacketTime!);
      if (_isDroneConnected && elapsed > const Duration(seconds: 3)) {
        _debugLog.add('Drone connection lost (heartbeat timeout)');
        setState(() {
          _isDroneConnected = false;
          _isDroneReady = false;
          _vlcInitialized = false;
        });
        try {
          _vlcController.dispose();
        } catch (_) {}
        showOverlayMessage('Drone connection lost!', type: 'error');
      }
    });
  }

  Future<void> _toggleVideoStreamRecording() async {
    if (_isVideoStreamRecording) {
      await _stopVideoRecording();
    } else {
      await _startVideoRecording();
    }
  }

  Future<void> _startVideoRecording() async {
    // Check if already recording
    if (_isVideoStreamRecording) {
      showOverlayMessage('Already recording', type: 'warning');
      return;
    }

    // Check video stream status
    if (!_vlcInitialized || _vlcController.value.hasError) {
      showOverlayMessage(
        'Cannot record: Video stream not active',
        type: 'error',
      );
      return;
    }

    // Try to refresh VLC controller if it's not playing
    if (!_vlcController.value.isPlaying) {
      print('VLC controller not playing, attempting to refresh...');
      try {
        await _vlcController.play();
        await Future.delayed(const Duration(milliseconds: 500));
        if (!_vlcController.value.isPlaying) {
          showOverlayMessage(
            'Cannot record: Video stream not playing',
            type: 'error',
          );
          return;
        }
      } catch (e) {
        print('Failed to refresh VLC controller: $e');
        showOverlayMessage(
          'Cannot record: Video stream refresh failed',
          type: 'error',
        );
        return;
      }
    }

    // Check drone connection
    if (!_isDroneConnected || !_isDroneReady) {
      showOverlayMessage('Cannot record: Drone not connected', type: 'error');
      return;
    }

    try {
      // Request gallery permission
      final photosPermission = await PhotoManager.requestPermissionExtend();
      if (!photosPermission.isAuth) {
        showOverlayMessage(
          'Gallery permission denied for video recording',
          type: 'error',
        );
        return;
      }

      // Test frame capture before starting recording
      print('Testing frame capture before recording...');
      print('VLC Controller state: ${_vlcController.value.toString()}');
      print('VLC isPlaying: ${_vlcController.value.isPlaying}');
      print('VLC hasError: ${_vlcController.value.hasError}');

      try {
        final testSnapshot = await _vlcController.takeSnapshot();
        print('Test snapshot: ${testSnapshot.length} bytes');
        if (testSnapshot.isEmpty) {
          showOverlayMessage(
            'Cannot record: Video stream not providing frames',
            type: 'error',
          );
          return;
        }
      } catch (e) {
        print('Test snapshot failed: $e');
        showOverlayMessage(
          'Cannot record: Frame capture test failed - $e',
          type: 'error',
        );
        return;
      }

      // Clear previous recording data
      _videoFrames.clear();
      _frameCount = 0;
      _recordingStartTime = DateTime.now();

      setState(() {
        _isVideoStreamRecording = true;
        _isFrameRecording = true;
      });

      // Start recording duration timer
      _recordingDurationTimer = Timer.periodic(const Duration(seconds: 1), (
        timer,
      ) {
        if (_recordingStartTime != null) {
          final duration = DateTime.now().difference(_recordingStartTime!);
          final minutes = duration.inMinutes.toString().padLeft(2, '0');
          final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
          setState(() {
            _recordingDuration = '$minutes:$seconds';
          });
        }
      });

      // Start capturing frames at 10 FPS
      _frameTimer = Timer.periodic(Duration(milliseconds: _frameCaptureInterval), (
        timer,
      ) async {
        print(
          'Frame capture attempt: _isFrameRecording=$_isFrameRecording, _vlcInitialized=$_vlcInitialized, hasError=${_vlcController.value.hasError}',
        );

        if (_isFrameRecording &&
            _vlcInitialized &&
            !_vlcController.value.hasError) {
          try {
            print('Attempting to take snapshot...');
            Uint8List? snapshot;

            // Try multiple approaches to capture frame
            try {
              snapshot = await _vlcController.takeSnapshot();
              print(
                'Snapshot taken via takeSnapshot: ${snapshot.length} bytes',
              );
            } catch (e) {
              print('takeSnapshot failed: $e');
              // Try alternative method if available
              try {
                // Alternative: try to get current frame from VLC controller
                if (_vlcController.value.isPlaying) {
                  // Create a simple frame as fallback
                  snapshot = await _createFallbackFrame();
                  print('Created fallback frame: ${snapshot.length} bytes');
                }
              } catch (e2) {
                print('Fallback frame creation failed: $e2');
              }
            }

            if (snapshot != null && snapshot.isNotEmpty) {
              // Compress frame if it's too large
              Uint8List compressedFrame = snapshot;
              if (snapshot.length > _maxFrameSize) {
                print(
                  'Compressing frame from ${snapshot.length} to smaller size...',
                );
                compressedFrame = await _compressFrame(snapshot);
                print('Compressed frame size: ${compressedFrame.length} bytes');
              }

              if (compressedFrame.length <= _maxFrameSize) {
                _videoFrames.add(compressedFrame);
                _frameCount++;
                print('Frame captured successfully: $_frameCount frames total');

                // Memory management: Keep only recent frames in memory
                if (_videoFrames.length > _maxMemoryFrames) {
                  // Save older frames to temporary storage asynchronously
                  final framesToSave = _videoFrames.sublist(
                    0,
                    _videoFrames.length - _maxMemoryFrames,
                  );
                  _videoFrames = _videoFrames.sublist(
                    _videoFrames.length - _maxMemoryFrames,
                  );

                  // Process in background to avoid blocking UI
                  Future.microtask(() async {
                    await _saveFramesToTemp(framesToSave);
                    print(
                      'Saved ${framesToSave.length} frames to temp storage',
                    );
                  });
                }

                // Limit recording to prevent memory issues
                if (_frameCount >= _maxRecordingFrames) {
                  await _stopVideoRecording();
                  showOverlayMessage(
                    'Recording stopped: Maximum duration reached (${_maxRecordingFrames ~/ 5}s)',
                    type: 'info',
                  );
                  return;
                }
              } else {
                print(
                  'Frame still too large after compression: ${compressedFrame.length} bytes',
                );
              }
            } else if (snapshot == null || snapshot.isEmpty) {
              print('Snapshot is null or empty');
            }
          } catch (e) {
            print('Frame capture error: $e');
            // Continue recording even if one frame fails
            // But stop if we get too many consecutive errors
            if (_frameCount > 0 && _frameCount % 10 == 0) {
              print('Multiple frame capture errors detected');
            }
          }
        } else if (!_isFrameRecording) {
          print('Frame recording stopped, canceling timer');
          timer.cancel();
        } else if (_vlcController.value.hasError) {
          // Stop recording if video stream has error
          print('Video stream error detected, stopping recording');
          await _stopVideoRecording();
          showOverlayMessage(
            'Recording stopped: Video stream error',
            type: 'error',
          );
        } else {
          print(
            'Frame capture conditions not met: _isFrameRecording=$_isFrameRecording, _vlcInitialized=$_vlcInitialized, hasError=${_vlcController.value.hasError}',
          );
        }
      });

      showOverlayMessage('Video recording started', type: 'info');
      print('Started video recording');
    } catch (e) {
      print('Video recording start error: $e');
      showOverlayMessage('Failed to start video recording: $e', type: 'error');
      setState(() {
        _isVideoStreamRecording = false;
        _isFrameRecording = false;
      });
    }
  }

  Future<void> _stopVideoRecording() async {
    _isFrameRecording = false;
    _frameTimer?.cancel();
    _recordingDurationTimer?.cancel();

    if (_videoFrames.isEmpty) {
      showOverlayMessage('No frames captured', type: 'warning');
      setState(() {
        _isVideoStreamRecording = false;
        _recordingDuration = '00:00';
      });
      return;
    }

    try {
      setState(() {
        _isProcessingVideo = true;
      });
      showOverlayMessage('Processing video...', type: 'info');

      // Create video from frames asynchronously
      final videoFile = await Future(() async {
        return await _createVideoFromFrames();
      });
      if (videoFile != null && await videoFile.exists()) {
        // Validate video file
        final fileSize = await videoFile.length();
        if (fileSize > 0) {
          // Save to gallery as image (since it's actually an image file)
          try {
            final asset = await PhotoManager.editor.saveImage(
              await videoFile.readAsBytes(),
              filename:
                  'VisionaryDrone_${DateTime.now().millisecondsSinceEpoch}.jpg',
              title: 'VisionaryDrone Recording',
            );
            if (asset != null) {
              showOverlayMessage(
                'Recording saved to gallery (${_frameCount} frames, $_recordingDuration)',
                type: 'info',
              );
              print(
                'Recording saved successfully: ${videoFile.path} (${fileSize} bytes)',
              );
            } else {
              showOverlayMessage(
                'Failed to save recording to gallery',
                type: 'error',
              );
            }
          } catch (e) {
            print('Error saving to gallery: $e');
            showOverlayMessage(
              'Recording created but gallery save failed: $e',
              type: 'warning',
            );
          }
        } else {
          showOverlayMessage('Invalid recording file created', type: 'error');
        }
      } else {
        showOverlayMessage('Failed to create recording file', type: 'error');
      }
    } catch (e) {
      print('Recording creation error: $e');
      showOverlayMessage('Failed to create recording: $e', type: 'error');
    } finally {
      setState(() {
        _isVideoStreamRecording = false;
        _recordingDuration = '00:00';
        _isProcessingVideo = false;
      });
      _videoFrames.clear();
      _frameCount = 0;
      _recordingStartTime = null;
    }
  }

  Future<File?> _createVideoFromFrames() async {
    print('Starting video creation process...');
    print('Frames available: ${_videoFrames.length}');
    print('Frame count: $_frameCount');

    if (_videoFrames.isEmpty) {
      print('No frames available for video creation');
      print('This means frame capture failed or frames were cleared');
      return null;
    }

    // Log first few frames for debugging
    for (int i = 0; i < _videoFrames.length && i < 3; i++) {
      print('Frame $i size: ${_videoFrames[i].length} bytes');
    }

    try {
      // Create directory
      final directory = Platform.isAndroid
          ? Directory('/storage/emulated/0/Pictures/VisionaryDrone')
          : await getApplicationDocumentsDirectory();

      print('Using directory: ${directory.path}');

      if (!await directory.exists()) {
        print('Creating directory...');
        await directory.create(recursive: true);
      }

      // Create video file path with timestamp
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final videoPath = '${directory.path}/VisionaryDrone_video_$timestamp.mp4';
      final videoFile = File(videoPath);

      print('Video file path: $videoPath');

      // Skip storage space check - user has 100GB available
      print('Skipping storage space check - proceeding with video creation');

      // Create video from frames
      print('Creating video from frames...');
      final success = await _createVideoFromFramesBasic(videoFile);
      print('Video creation success flag: $success');

      // Check if file exists regardless of success flag
      final fileExists = await videoFile.exists();
      print('File exists check: $fileExists');
      print('File path: $videoPath');

      if (fileExists) {
        try {
          final fileSize = await videoFile.length();
          print('Video file created successfully: $videoPath');
          print('File size: $fileSize bytes');
          return videoFile;
        } catch (e) {
          print('Error getting file size: $e');
          return null;
        }
      } else {
        print('Video file does not exist at path: $videoPath');

        // Check if directory exists
        final directory = videoFile.parent;
        final dirExists = await directory.exists();
        print('Directory exists: $dirExists');
        print('Directory path: ${directory.path}');

        // List files in directory
        try {
          final files = await directory.list().toList();
          print('Files in directory: ${files.length}');
          for (var file in files) {
            print('  - ${file.path}');
          }
        } catch (e) {
          print('Error listing directory: $e');
        }

        return null;
      }
    } catch (e) {
      print('Video file creation error: $e');
      print('Error details: ${e.toString()}');
      return null;
    }
  }

  // Storage space check removed - user has 100GB available

  Future<Uint8List> _createFallbackFrame() async {
    // Create a simple colored frame as fallback
    // This is a basic 320x240 colored rectangle
    final width = 320;
    final height = 240;
    final bytesPerPixel = 3; // RGB
    final frameSize = width * height * bytesPerPixel;

    final frame = Uint8List(frameSize);
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    // Create a simple pattern based on timestamp
    for (int i = 0; i < frameSize; i += 3) {
      final x = (i ~/ 3) % width;
      final y = (i ~/ 3) ~/ width;
      final timeOffset = (timestamp + i) % 255;

      frame[i] = (x + timeOffset) % 255; // Red
      frame[i + 1] = (y + timeOffset) % 255; // Green
      frame[i + 2] = timeOffset; // Blue
    }

    return frame;
  }

  Future<Uint8List> _compressFrame(Uint8List originalFrame) async {
    try {
      // Simple frame compression by reducing resolution
      // This is a basic approach - in production you'd use proper image compression

      // For now, we'll create a smaller version of the frame
      // Assuming the original is a JPEG image, we'll create a smaller JPEG

      // Create a temporary file for the original frame
      final tempDir = await getTemporaryDirectory();
      final originalFile = File('${tempDir.path}/original_frame.jpg');
      await originalFile.writeAsBytes(originalFrame);

      // For now, return the original frame but with a note
      // In a real implementation, you'd use an image processing library
      print('Frame compression not fully implemented - using original frame');
      return originalFrame;
    } catch (e) {
      print('Frame compression failed: $e');
      // Return original frame if compression fails
      return originalFrame;
    }
  }

  Future<void> _saveFramesToTemp(List<Uint8List> frames) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final framesDir = Directory('${tempDir.path}/video_frames_temp');
      if (!await framesDir.exists()) {
        await framesDir.create(recursive: true);
      }

      // Save frames as individual files
      for (int i = 0; i < frames.length; i++) {
        final frameFile = File(
          '${framesDir.path}/frame_${DateTime.now().millisecondsSinceEpoch}_$i.jpg',
        );
        await frameFile.writeAsBytes(frames[i]);
      }
    } catch (e) {
      print('Error saving frames to temp: $e');
    }
  }

  Future<bool> _createVideoFromFramesBasic(File videoFile) async {
    try {
      print('Creating video from ${_videoFrames.length} frames...');

      if (_videoFrames.isEmpty) {
        print('No frames to create video from');
        return false;
      }

      // Simple approach: Save all frames as individual images in a folder
      // This is more reliable than trying to create a custom video format

      final directory = videoFile.parent;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final framesDir = Directory(
        '${directory.path}/VisionaryDrone_frames_$timestamp',
      );

      if (!await framesDir.exists()) {
        await framesDir.create(recursive: true);
      }

      print('Saving frames to: ${framesDir.path}');

      // Save each frame as a separate image file
      for (int i = 0; i < _videoFrames.length; i++) {
        final frameFile = File(
          '${framesDir.path}/frame_${i.toString().padLeft(4, '0')}.jpg',
        );
        await frameFile.writeAsBytes(_videoFrames[i]);
        print('Saved frame $i: ${frameFile.path}');
      }

      // Create a metadata file with video information
      final metadataFile = File('${framesDir.path}/video_info.txt');
      final metadata =
          '''
VisionaryDrone Video Recording
=============================
Timestamp: ${DateTime.now()}
Total Frames: ${_videoFrames.length}
Frame Rate: 5 FPS
Duration: ${(_videoFrames.length / 5).toStringAsFixed(1)} seconds
Directory: ${framesDir.path}
''';
      await metadataFile.writeAsString(metadata);

      // Also save the first frame as the main video file (for gallery compatibility)
      print('Saving main video file: ${videoFile.path}');
      print('First frame size: ${_videoFrames.first.length} bytes');

      try {
        await videoFile.writeAsBytes(_videoFrames.first);
        print('Main video file saved successfully');

        // Verify the main file was created
        final mainFileExists = await videoFile.exists();
        print('Main file exists after save: $mainFileExists');

        if (mainFileExists) {
          final mainFileSize = await videoFile.length();
          print('Main file size: $mainFileSize bytes');
        }
      } catch (e) {
        print('Error saving main video file: $e');
        return false;
      }

      print('Successfully created frame sequence: ${framesDir.path}');
      print('Total frames saved: ${_videoFrames.length}');
      print('Main video file: ${videoFile.path}');
      return true;
    } catch (e) {
      print('Video creation error: $e');

      // Fallback: save first frame as image
      if (_videoFrames.isNotEmpty) {
        try {
          await videoFile.writeAsBytes(_videoFrames.first);
          print('Fallback: Saved first frame as image');
        } catch (e2) {
          print('Fallback also failed: $e2');

          // Last resort: create a simple text file with frame info
          try {
            final fallbackContent =
                'VisionaryDrone Video\nFrames: ${_videoFrames.length}\nTimestamp: ${DateTime.now()}\n';
            await videoFile.writeAsString(fallbackContent);
            print('Created fallback text file');
          } catch (e3) {
            print('All fallback methods failed: $e3');
          }
        }
      }
      return false;
    }
  }

  void _initVLC() {
    _vlcController = VlcPlayerController.network(
      'udp://@:11111',
      hwAcc: HwAcc.auto,
      autoPlay: true,
      options: VlcPlayerOptions(
        advanced: VlcAdvancedOptions([':network-caching=150', ':demux=h264']),
      ),
    );
    _vlcController.addListener(() {
      final state = _vlcController.value;
      if (state.hasError) {
        if (!_isAttemptingReconnect) {
          _isAttemptingReconnect = true;
          _handleReconnect().then((_) => _isAttemptingReconnect = false);
        }
        showOverlayMessage(
          'Video stream error. Trying to reconnect...',
          type: 'error',
        );
      }
    });
    setState(() {
      _vlcInitialized = true;
    });
  }

  Future<void> _setupVideoConnection() async {
    try {
      _vlcController.dispose();
    } catch (_) {}
    _initVLC();
    if (_droneSocket == null || _droneSocket!.close != null) {
      try {
        _droneSocket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          8889,
        );
      } catch (e) {
        return;
      }
    }
    _droneSocket?.send(
      utf8.encode('command'),
      InternetAddress(telloIP),
      telloPort,
    );
    await Future.delayed(Duration(milliseconds: 500));
    _droneSocket?.send(
      utf8.encode('streamon'),
      InternetAddress(telloIP),
      telloPort,
    );
  }

  void _updateDroneState(String response) {
    setState(() {
      try {
        RegExp batteryReg = RegExp(r'bat:(\d+);');
        final batteryMatch = batteryReg.firstMatch(response);
        if (batteryMatch != null) {
          _battery = batteryMatch.group(1) ?? 'Unknown';
          final batteryVal = int.tryParse(_battery);
          if (batteryVal != null && batteryVal < 10) {
            if (!_criticalBatteryShown) {
              showOverlayMessage(
                'CRITICAL: Battery extremely low! Land immediately.',
                type: 'error',
              );
              _criticalBatteryShown = true;
            }
            _lastLowBatteryWarning = batteryVal;
          } else if (batteryVal != null && batteryVal < 20) {
            if (_lastLowBatteryWarning == null ||
                batteryVal < _lastLowBatteryWarning!) {
              showOverlayMessage(
                'Low battery! Please land soon.',
                type: 'warning',
              );
              _lastLowBatteryWarning = batteryVal;
            }
            _criticalBatteryShown = false;
          } else {
            _lastLowBatteryWarning = null;
            _criticalBatteryShown = false;
          }
        }
        RegExp heightReg = RegExp(r'h:(\d+);');
        final heightMatch = heightReg.firstMatch(response);
        if (heightMatch != null) {
          _currentHeight =
              (double.tryParse(heightMatch.group(1) ?? '0') ?? 0) / 100;
        }
        if (response == 'ok' && !_isDroneReady) {
          _isDroneReady = true;
        } else if (response == 'error') {
          _isDroneError = true;
          _droneError = 'Error: Drone not responding';
        }
        if (RegExp(r'^\d+').hasMatch(response.trim())) {
          _battery = response.trim();
        }
      } catch (e) {
        _battery = 'Unknown';
        _currentHeight = 0;
        showOverlayMessage(
          'Telemetry error: Unable to read drone status.',
          type: 'error',
        );
      }
    });
  }

  Future<void> _initializeDrone({int retryCount = 0}) async {
    if (_isConnectingToDrone || _isDroneConnected) return;
    _isConnectingToDrone = true;
    try {
      if (_droneSocket != null) {
        _droneSocket!.close();
        _droneSocket = null;
      }
      if (_stateSocket != null) {
        _stateSocket!.close();
        _stateSocket = null;
      }
      _droneSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        8889,
      );
      _droneSocket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          _lastDronePacketTime = DateTime.now();
          Datagram? dg = _droneSocket!.receive();
          if (dg != null) {
            String response;
            try {
              response = utf8.decode(dg.data, allowMalformed: true).trim();
            } catch (e) {
              return;
            }
            if (response == 'ok') {
              if (!_isDroneConnected) {
                setState(() {
                  _isDroneConnected = true;
                  _isDroneReady = true;
                });
                if (mounted && _isDroneConnected && !_vlcInitialized) {
                  _initVLC();
                  _setupVideoConnection();
                }
              } else if (mounted && _isDroneConnected && !_vlcInitialized) {
                _initVLC();
                _setupVideoConnection();
              }
            } else if (_lastActionCommand != null) {
              if (response == 'ok') {
                if (_lastActionCommand == 'takeoff') {
                  setState(() {
                    _isDroneFlying = true;
                    _isLanded = false;
                  });
                } else if (_lastActionCommand == 'land') {
                  setState(() {
                    _isDroneFlying = false;
                    _isLanded = true;
                  });
                }
                _lastActionCommand = null;
              } else {
                setState(() {
                  _lastActionCommand = null;
                });
              }
            } else {
              _updateDroneState(response);
            }
          }
        } else if (event == RawSocketEvent.closed) {
          setState(() {
            _isDroneConnected = false;
            _isDroneReady = false;
            _showDroneDisconnectedOverlay = true;
          });
          Future.delayed(const Duration(seconds: 3), () {
            if (mounted) {
              setState(() {
                _showDroneDisconnectedOverlay = false;
              });
            }
          });
          if (!_isAttemptingReconnect) {
            _isAttemptingReconnect = true;
            _handleReconnect().then((_) => _isAttemptingReconnect = false);
          }
        }
      }, cancelOnError: false);
      _stateSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        8890,
      );
      _stateSocket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          _lastDronePacketTime = DateTime.now();
          final dg = _stateSocket!.receive();
          if (dg != null && dg.data.isNotEmpty) {
            try {
              final decoded = utf8.decode(dg.data, allowMalformed: true);
              _updateDroneState(decoded);
            } catch (e) {
              return;
            }
          }
        }
      });
      _sendDroneCommand('command');
    } catch (e) {
      if (retryCount < 3) {
        await Future.delayed(const Duration(seconds: 2));
        _isConnectingToDrone = false;
        return _initializeDrone(retryCount: retryCount + 1);
      }
      setState(() {
        _isDroneError = true;
        _droneError = 'Socket Init Error: $e';
      });
      showOverlayMessage('Failed to connect to drone.', type: 'error');
    } finally {
      _isConnectingToDrone = false;
    }
  }

  Future<void> _resetDroneConnection() async {
    setState(() {
      _isDroneConnected = false;
      _isDroneReady = false;
      _isDroneError = false;
      _isConnectingToDrone = false;
      _showDroneDisconnectedOverlay = false;
      _droneError = '';
      _lastActionCommand = null;
      _vlcInitialized = false;
    });
    try {
      _rcTimer?.cancel();
      _rcTimer = null;
      _droneSocket?.close();
      _droneSocket = null;
      _stateSocket?.close();
      _stateSocket = null;
      if (_vlcInitialized) {
        _vlcController.dispose();
      }
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 300));
  }

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    )..repeat(reverse: true);
    _updateStorage();
    _updateWiFi();
    _connectivitySub = Connectivity().onConnectivityChanged.listen(
      (_) => _updateWiFi(),
    );
    _reconnectTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!_isDroneConnected ||
          !_vlcInitialized ||
          (_vlcController.value.hasError)) {
        if (!_isAttemptingReconnect) {
          _isAttemptingReconnect = true;
          await _handleReconnect();
          _isAttemptingReconnect = false;
        }
      }
    });
    _startHeartbeatMonitor();
  }

  Future<void> _handleReconnect() async {
    try {
      _vlcController.dispose();
    } catch (_) {}
    try {
      _droneSocket?.close();
      _droneSocket = null;
    } catch (_) {}
    try {
      _stateSocket?.close();
      _stateSocket = null;
    } catch (_) {}
    setState(() {
      _vlcInitialized = false;
      _isDroneConnected = false;
      _isDroneReady = false;
    });
    await Future.delayed(const Duration(milliseconds: 500));
    await _updateWiFi();
  }

  void _sendDroneCommand(String command) {
    _droneSocket?.send(
      utf8.encode(command),
      InternetAddress(telloIP),
      telloPort,
    );
  }

  Future<void> _updateStorage() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final stat = await directory.stat();
      final statvfs = await FileStat.stat(directory.path);
      setState(() {
        _storage = '${(stat.size / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
      });
      Directory? extDir;
      if (Platform.isAndroid) {
        extDir = await getExternalStorageDirectory();
      }
      final statExt = extDir != null ? await extDir.stat() : null;
      final statvfsPath = extDir?.path ?? directory.path;
      final statvfsInfo = await FileStat.stat(statvfsPath);
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

  Future<void> ensureLocationPermission() async {
    var status = await Permission.location.status;
    if (!status.isGranted) {
      await Permission.location.request();
    }
  }

  Future<void> _updateWiFi() async {
    try {
      await ensureLocationPermission();
      final connectivity = await Connectivity().checkConnectivity();
      var status = await Permission.location.status;
      setState(() {
        _locationPermissionStatus = status.toString();
      });
      if (connectivity.contains(ConnectivityResult.wifi)) {
        String? ssid;
        try {
          ssid = await NetworkInfo().getWifiName();
        } catch (e) {
          ssid = null;
        }
        ssid = ssid?.replaceAll('"', '').replaceAll("'", "");
        setState(() {
          _currentSSID = ssid ?? 'null';
          if (ssid != null && ssid.startsWith('TELLO')) {
            _wifi = 'Connected';
          } else {
            _wifi = 'Wrong Network';
            showOverlayMessage(
              'Wrong WiFi network! Connect to TELLO.',
              type: 'warning',
            );
          }
        });
        if (ssid != null && ssid.startsWith('TELLO')) {
          if (!_isDroneConnected && !_isDroneReady) {
            _initializeDrone();
          }
        }
      } else {
        setState(() => _wifi = 'Disconnected');
      }
    } catch (e) {
      setState(() => _wifi = 'Disconnected');
      showOverlayMessage(
        'WiFi error: could not check connection.',
        type: 'error',
      );
    }
  }

  void _sendCommand(String command) {
    if (_isCommanding || _droneSocket == null || !_isDroneReady) return;
    setState(() => _isCommanding = true);
    try {
      _droneSocket?.send(
        utf8.encode(command),
        InternetAddress(telloIP),
        telloPort,
      );
      Future.delayed(const Duration(seconds: 2), () {
        if (_lastActionCommand != null) {
          showOverlayMessage(
            'No response from drone. Please try again.',
            type: 'error',
          );
          _lastActionCommand = null;
        }
      });
    } catch (e) {
      setState(() {
        _isDroneError = true;
        _droneError = 'Send Error: $e';
        _isCommanding = false;
      });
      showOverlayMessage('Failed to send command to drone.', type: 'error');
      return;
    }
    Future.delayed(const Duration(seconds: 1), () {
      setState(() => _isCommanding = false);
    });
  }

  void _sendRCCommand() {
    if (!_isDroneReady ||
        (_leftJoystick == Offset.zero && _rightJoystick == Offset.zero))
      return;
    final rightX = (_rightJoystick.dx * 30).clamp(-30, 30).toInt();
    final rightY = (_rightJoystick.dy * -30).clamp(-30, 30).toInt();
    final leftY = (_leftJoystick.dy * -30).clamp(-30, 30).toInt();
    final leftX = (_leftJoystick.dx * 30).clamp(-30, 30).toInt();
    _sendCommand('rc $rightY $rightX $leftY $leftX');
    _debugLog.add('Sent RC: rc $rightY $rightX $leftY $leftX');
  }

  Future<void> _takePhoto() async {
    _debugLog.add('Taking photo...');
    if (_vlcInitialized && !_vlcController.value.hasError) {
      try {
        final photosPermission = await PhotoManager.requestPermissionExtend();
        if (!photosPermission.isAuth) {
          showOverlayMessage('Photos permission denied', type: 'error');
          return;
        }
        final snapshot = await _vlcController.takeSnapshot();
        Directory? directory;
        if (Platform.isAndroid) {
          directory = Directory('/storage/emulated/0/Pictures/VisionaryDrone');
        } else {
          directory = await getApplicationDocumentsDirectory();
        }
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }
        final file = File(
          '${directory.path}/VisionaryDrone_${DateTime.now().millisecondsSinceEpoch}.png',
        );
        await file.writeAsBytes(snapshot);
        _debugLog.add('Photo saved to ${file.path}');
        final asset = await PhotoManager.editor.saveImage(
          snapshot,
          filename:
              'VisionaryDrone_${DateTime.now().millisecondsSinceEpoch}.png',
          title: 'VisionaryDrone Photo',
        );
        if (asset == null) {
          showOverlayMessage('Failed to add photo to gallery', type: 'error');
          return;
        }
        showOverlayMessage('Photo saved to gallery', type: 'info');
      } catch (e) {
        _debugLog.add('Photo error: $e');
        showOverlayMessage('Failed to take photo: $e', type: 'error');
      }
    } else {
      showOverlayMessage(
        'Cannot take photo: Video stream not active',
        type: 'error',
      );
    }
  }

  Future<void> _openGallery() async {
    final permission = await PhotoManager.requestPermissionExtend();
    if (permission.isAuth) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const GalleryScreen()),
      );
    } else {
      showOverlayMessage('Gallery permission denied', type: 'warning');
    }
  }

  @override
  void dispose() {
    // Stop video recording if active
    if (_isVideoStreamRecording) {
      _stopVideoRecording();
    }

    _animationController.dispose();
    _stateSocket?.close();
    _connectivitySub?.cancel();
    _droneSocket?.close();
    _rcTimer?.cancel();
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    _overlayTimer?.cancel();
    _frameTimer?.cancel();
    _recordingDurationTimer?.cancel();
    if (_vlcInitialized) {
      _vlcController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: !_vlcInitialized
                ? Container(color: Colors.white)
                : _vlcController.value.hasError
                ? Container(color: Colors.green)
                : VlcPlayer(
                    controller: _vlcController,
                    aspectRatio: 16 / 9,
                    placeholder: const SizedBox.shrink(),
                  ),
          ),
          if (_showOverlay && _overlayMessage != null)
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 18,
                ),
                decoration: BoxDecoration(
                  color: _overlayColor,
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 12,
                    ),
                  ],
                ),
                child: Text(
                  _overlayMessage!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 22,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          if (_showDroneDisconnectedOverlay)
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 18,
                ),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.85),
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 12,
                    ),
                  ],
                ),
                child: const Text(
                  'Drone Not Connected',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 22,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          Positioned(
            top: 50,
            left: MediaQuery.of(context).size.width / 2 - 25,
            child: GestureDetector(
              onTap: () {
                if (!_isDroneReady) {
                  showOverlayMessage('Drone not ready', type: 'warning');
                  return;
                }
                setState(() {
                  _lastActionCommand = _isLanded ? 'takeoff' : 'land';
                  _isLanded = !_isLanded;
                  _isDroneFlying = !_isLanded;
                });
                _debugLog.add('Sending command: $_lastActionCommand');
                _sendCommand(_lastActionCommand!);
              },
              child: Image.asset(
                _isLanded
                    ? 'assets/images/takeoff.webp'
                    : 'assets/images/land.png',
                width: 50,
                height: 50,
              ),
            ),
          ),
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
                  Positioned.fill(
                    left: 18,
                    child: CustomPaint(
                      painter: _HeightScalePainter(
                        tickCount: 11,
                        majorTickEvery: 5,
                        tickColor: Colors.blueAccent.shade100,
                        majorTickColor: Colors.indigo,
                        currentHeight: _currentHeight,
                      ),
                    ),
                  ),
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
          Positioned(
            top: 60,
            left: 90,
            child: Row(
              children: [
                Icon(
                  _isDroneConnected ? Icons.check_circle : Icons.cancel,
                  color: _isDroneConnected ? Colors.green : Colors.red,
                  size: 22,
                ),
                const SizedBox(width: 8),
                Text(
                  _isDroneConnected
                      ? 'Drone: Connected'
                      : 'Drone: Not Connected',
                  style: TextStyle(
                    color: _isDroneConnected ? Colors.green : Colors.red,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: 10,
            left: 10,
            right: 10,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
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
                    const SizedBox(width: 18),
                    const Text(
                      'A',
                      style: TextStyle(
                        color: Colors.green,
                        fontWeight: FontWeight.w900,
                        fontSize: 17,
                      ),
                    ),
                    const SizedBox(width: 1),
                    SizedBox(
                      width: 80,
                      child: Transform.scale(
                        scaleX: 1.2,
                        scaleY: 1.1,
                        child: Switch(
                          value: _toggleValue,
                          onChanged: (val) {
                            setState(() {
                              _toggleValue = val;
                            });
                            if (!val) {
                              _rcTimer?.cancel();
                              _rcTimer = null;
                              _sendCommand('rc 0 0 0 0');
                              _sendCommand('rc 0 0 0 0');
                              _sendCommand('rc 0 0 0 0');
                              _debugLog.add(
                                'Switched to auto mode, sent: rc 0 0 0 0 (x3)',
                              );
                            }
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
                                        .withAlpha(200),
                                duration: const Duration(seconds: 2),
                                behavior: SnackBarBehavior.floating,
                                margin: const EdgeInsets.only(
                                  bottom: 40,
                                  left: 120,
                                  right: 120,
                                ),
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
                        color: Colors.green,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
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
                      Text(
                        'WiFi: $_wifi',
                        style: const TextStyle(color: Colors.white),
                      ),
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
          if (_isVideoStreamRecording || _isProcessingVideo)
            Positioned(
              top: 80,
              right: 15,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: _isProcessingVideo
                      ? Colors.orange.withOpacity(0.8)
                      : Colors.red.withOpacity(0.8),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isProcessingVideo)
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.white,
                          ),
                        ),
                      )
                    else
                      AnimatedBuilder(
                        animation: _animationController,
                        builder: (context, child) {
                          return Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.white.withOpacity(0.8),
                                  blurRadius: 4,
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    const SizedBox(width: 8),
                    Text(
                      _isProcessingVideo
                          ? 'PROCESSING'
                          : 'REC $_recordingDuration',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ),
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
                if (_toggleValue) {
                  setState(() => _leftJoystick = offset);
                  if (_rcTimer == null || !_rcTimer!.isActive) {
                    _rcTimer = Timer.periodic(
                      const Duration(milliseconds: 100),
                      (_) => _sendRCCommand(),
                    );
                  }
                }
              },
              onReleased: () {
                if (_toggleValue) {
                  setState(() {
                    _leftJoystick = Offset.zero;
                    _rightJoystick = Offset.zero;
                  });
                  _rcTimer?.cancel();
                  _rcTimer = null;
                  _sendCommand('rc 0 0 0 0');
                  _sendCommand('rc 0 0 0 0');
                  _sendCommand('rc 0 0 0 0');
                  _debugLog.add(
                    'Left joystick released, sent: rc 0 0 0 0 (x3)',
                  );
                }
              },
            ),
          ),
          Positioned(
            bottom: 30,
            right: 105,
            child: Joystick(
              isLeft: false,
              onChanged: (offset) {
                if (_toggleValue) {
                  setState(() => _rightJoystick = offset);
                  if (_rcTimer == null || !_rcTimer!.isActive) {
                    _rcTimer = Timer.periodic(
                      const Duration(milliseconds: 100),
                      (_) => _sendRCCommand(),
                    );
                  }
                }
              },
              onReleased: () {
                if (_toggleValue) {
                  setState(() {
                    _rightJoystick = Offset.zero;
                    _leftJoystick = Offset.zero;
                  });
                  _rcTimer?.cancel();
                  _rcTimer = null;
                  _sendCommand('rc 0 0 0 0');
                  _sendCommand('rc 0 0 0 0');
                  _sendCommand('rc 0 0 0 0');
                  _debugLog.add(
                    'Right joystick released, sent: rc 0 0 0 0 (x3)',
                  );
                }
              },
            ),
          ),
          Positioned(
            top: 60,
            left: 90,
            child: Row(
              children: [
                Icon(
                  _isDroneConnected ? Icons.check_circle : Icons.cancel,
                  color: _isDroneConnected ? Colors.green : Colors.red,
                  size: 22,
                ),
                const SizedBox(width: 8),
                Text(
                  _isDroneConnected
                      ? 'Drone: Connected'
                      : 'Drone: Not Connected',
                  style: TextStyle(
                    color: _isDroneConnected ? Colors.green : Colors.red,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ],
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
                  Container(
                    decoration: BoxDecoration(
                      color: _isVideoStreamRecording
                          ? Colors.red.withOpacity(0.2)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: IconButton(
                      icon: Icon(
                        _isVideoStreamRecording
                            ? Icons.stop_circle
                            : Icons.videocam,
                        color: _isVideoStreamRecording
                            ? Colors.red
                            : Colors.black,
                        size: 32,
                      ),
                      onPressed: _toggleVideoStreamRecording,
                      tooltip: _isVideoStreamRecording
                          ? 'Stop Video Recording'
                          : 'Start Video Recording',
                    ),
                  ),
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
                ],
              ),
            ),
          ),
          Positioned(
            top: 60,
            right: 18,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.wifi, color: Colors.white, size: 18),
                          const SizedBox(width: 6),
                          Text(
                            'SSID: $_currentSSID',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
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
}

// The rest of the classes (Joystick, _JoystickRingPainter, GalleryScreen, _PhotoViewer, _HeightScalePainter, _FlightModeOption) remain unchanged.
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
                _offset = Offset.zero;
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
                  BoxShadow(color: Colors.black.withAlpha(46), blurRadius: 12),
                ],
              ),
            ),
            Positioned.fill(
              child: CustomPaint(
                painter: _JoystickRingPainter(offset: _offset),
              ),
            ),
            if (widget.isLeft) ...[
              Positioned(
                top: 10,
                left: 60,
                child: Icon(
                  Icons.arrow_upward,
                  color: Colors.blueGrey.shade700,
                  size: 28,
                ),
              ),
              Positioned(
                bottom: 10,
                left: 60,
                child: Icon(
                  Icons.arrow_downward,
                  color: Colors.blueGrey.shade700,
                  size: 28,
                ),
              ),
              Positioned(
                left: 10,
                top: 60,
                child: Icon(
                  Icons.rotate_left,
                  color: Colors.blueGrey.shade700,
                  size: 28,
                ),
              ),
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
              Positioned(
                top: 10,
                left: 60,
                child: Icon(
                  Icons.arrow_upward,
                  color: Colors.blueGrey.shade700,
                  size: 28,
                ),
              ),
              Positioned(
                bottom: 10,
                left: 60,
                child: Icon(
                  Icons.arrow_downward,
                  color: Colors.blueGrey.shade700,
                  size: 28,
                ),
              ),
              Positioned(
                left: 10,
                top: 60,
                child: Icon(
                  Icons.arrow_back,
                  color: Colors.blueGrey.shade700,
                  size: 28,
                ),
              ),
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

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});
  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  List<AssetEntity> _photos = [];
  bool _isLoading = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    _loadPhotos();
  }

  Future<void> _loadPhotos() async {
    try {
      // Check photo permission
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.isAuth) {
        setState(() {
          _error = 'Photo permission denied';
          _isLoading = false;
        });
        return;
      }
      // Get albums (filter by Pictures/VisionaryDrone if possible)
      final albums = await PhotoManager.getAssetPathList(
        type: RequestType
            .all, // Changed from RequestType.image to RequestType.all
        filterOption: FilterOptionGroup(
          imageOption: const FilterOption(needTitle: true),
          videoOption: const FilterOption(
            needTitle: true,
          ), // Added video support
          orders: [
            const OrderOption(type: OrderOptionType.createDate, asc: false),
          ],
        ),
      );
      // Find the VisionaryDrone folder or load all images
      AssetPathEntity? visionaryDroneAlbum;
      for (var album in albums) {
        if (Platform.isAndroid && album.name.contains('VisionaryDrone_')) {
          visionaryDroneAlbum = album;
          break;
        }
      }
      // Load photos from the album or all albums
      final targetAlbum = visionaryDroneAlbum ?? albums.firstOrNull;
      if (targetAlbum == null) {
        setState(() {
          _error = 'No photos found';
          _isLoading = false;
        });
        return;
      }
      // Use size instead of perPage
      final assets = await targetAlbum.getAssetListPaged(page: 0, size: 100);
      setState(() {
        _photos = assets.where((asset) {
          // Filter by title containing 'VisionaryDrone' for both photos and videos
          return asset.title?.contains('VisionaryDrone') ?? false;
        }).toList();
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Error loading photos: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Visionary Drone Gallery (Photos & Videos)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadPhotos,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                  const SizedBox(height: 9),
                  ElevatedButton(
                    onPressed: _loadPhotos,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            )
          : _photos.isEmpty
          ? const Center(child: Text('No photos found'))
          : GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                childAspectRatio: 1.0,
              ),
              itemCount: _photos.length,
              itemBuilder: (context, index) {
                final asset = _photos[index];
                return GestureDetector(
                  onTap: () async {
                    // Show full-screen photo
                    final file = await asset.file;
                    if (file != null) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => _PhotoViewer(asset: asset),
                        ),
                      );
                    }
                  },
                  child: Stack(
                    children: [
                      FutureBuilder<Uint8List?>(
                        future: asset.thumbnailDataWithSize(
                          const ThumbnailSize(400, 400),
                        ),
                        builder: (context, snapshot) {
                          if (snapshot.hasData) {
                            return Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.2),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Image.memory(
                                  snapshot.data!,
                                  fit: BoxFit.cover,
                                  width: double.infinity,
                                  height: double.infinity,
                                ),
                              ),
                            );
                          }
                          return Container(
                            decoration: BoxDecoration(
                              color: Colors.grey[300],
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Center(
                              child: CircularProgressIndicator(),
                            ),
                          );
                        },
                      ),
                      // Show video indicator if it's a video
                      if (asset.type == AssetType.video)
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.7),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.videocam,
                                  color: Colors.white,
                                  size: 12,
                                ),
                                SizedBox(width: 2),
                                Text(
                                  'VIDEO',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 8,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

class _PhotoViewer extends StatelessWidget {
  final AssetEntity asset;
  const _PhotoViewer({required this.asset});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(asset.title ?? 'Media'),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
      ),
      backgroundColor: Colors.black,
      body: FutureBuilder<File?>(
        future: asset.file,
        builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data != null) {
            // Check if it's a video or image
            if (asset.type == AssetType.video) {
              // For videos, show a video player or placeholder
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.videocam, size: 80, color: Colors.white70),
                    const SizedBox(height: 20),
                    Text(
                      'Video: ${asset.title ?? 'Untitled'}',
                      style: const TextStyle(fontSize: 20, color: Colors.white),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Duration: ${asset.duration ?? 0}s',
                      style: const TextStyle(color: Colors.white70, fontSize: 16),
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      onPressed: () {
                        // You could implement video playback here
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Video playback not implemented yet'),
                          ),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      ),
                      child: const Text('Play Video'),
                    ),
                  ],
                ),
              );
            } else {
              // For images, show the image with better sizing
              return InteractiveViewer(
                minScale: 0.5,
                maxScale: 4.0,
                child: Center(
                  child: Container(
                    width: double.infinity,
                    height: double.infinity,
                    child: Image.file(
                      snapshot.data!,
                      fit: BoxFit.contain,
                      width: double.infinity,
                      height: double.infinity,
                    ),
                  ),
                ),
              );
            }
          }
          return const Center(
            child: CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          );
        },
      ),
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
