import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:arkit_plugin/arkit_plugin.dart';

void main() => runApp(const HeadTrackerApp());

class HeadTrackerApp extends StatelessWidget {
  const HeadTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HeadTracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0A0A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00D4FF),
          surface: Color(0xFF111111),
        ),
      ),
      home: const TrackerScreen(),
    );
  }
}

class TrackerScreen extends StatefulWidget {
  const TrackerScreen({super.key});

  @override
  State<TrackerScreen> createState() => _TrackerScreenState();
}

class _TrackerScreenState extends State<TrackerScreen> {
  ARKitController? _arkitController;
  RawDatagramSocket? _socket;
  InternetAddress? _targetAddress;
  int _targetPort = 4242;

  bool _streaming = false;
  bool _faceDetected = false;

  double _yaw = 0, _pitch = 0, _roll = 0;
  double _x = 0, _y = 0, _z = 0;

  int _fps = 0;
  int _frameCount = 0;
  DateTime _lastFpsCheck = DateTime.now();

  final _ipController = TextEditingController(text: '192.168.1.100');
  final _portController = TextEditingController(text: '4242');

  @override
  void initState() {
    super.initState();
    _initSocket();
  }

  Future<void> _initSocket() async {
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  }

  void _onARKitViewCreated(ARKitController controller) {
    _arkitController = controller;
    _arkitController!.onAddNodeForAnchor = _handleAnchor;
    _arkitController!.onUpdateNodeForAnchor = _handleAnchor;
  }

  void _handleAnchor(ARKitAnchor anchor) {
    if (anchor is! ARKitFaceAnchor) return;

    // Always use the very latest frame — no buffering
    final t = anchor.transform;

    // Extract euler angles from 4x4 rotation matrix (column-major)
    // Using YXZ convention: yaw (Y), pitch (X), roll (Z)
    final r00 = t.entry(0, 0);
    final r01 = t.entry(0, 1);
    final r10 = t.entry(1, 0);
    final r11 = t.entry(1, 1);
    final r20 = t.entry(2, 0);
    final r21 = t.entry(2, 1);
    final r22 = t.entry(2, 2);

    final pitch = asin(-r21.clamp(-1.0, 1.0)) * (180.0 / pi);
    final yaw   = atan2(r20, r22) * (180.0 / pi);
    final roll  = atan2(r01, r11) * (180.0 / pi);

    // Position in cm (ARKit uses meters)
    final x = t.entry(0, 3) * 100.0;
    final y = t.entry(1, 3) * 100.0;
    final z = t.entry(2, 3) * 100.0;

    // FPS counter
    _frameCount++;
    final now = DateTime.now();
    if (now.difference(_lastFpsCheck).inMilliseconds >= 1000) {
      _fps = _frameCount;
      _frameCount = 0;
      _lastFpsCheck = now;
    }

    setState(() {
      _yaw = yaw;
      _pitch = pitch;
      _roll = roll;
      _x = x;
      _y = y;
      _z = z;
      _faceDetected = true;
    });

    // Send UDP immediately — no queue, no wait
    if (_streaming && _socket != null && _targetAddress != null) {
      _sendPose(yaw, pitch, roll, x, y, z);
    }
  }

  void _sendPose(
    double yaw, double pitch, double roll,
    double x, double y, double z,
  ) {
    // OpenTrack UDP format: 6 x float64 little-endian = 48 bytes
    final buf = ByteData(48);
    buf.setFloat64(0,  yaw,   Endian.little);
    buf.setFloat64(8,  pitch, Endian.little);
    buf.setFloat64(16, roll,  Endian.little);
    buf.setFloat64(24, x,     Endian.little);
    buf.setFloat64(32, y,     Endian.little);
    buf.setFloat64(40, z,     Endian.little);
    _socket!.send(buf.buffer.asUint8List(), _targetAddress!, _targetPort);
  }

  Future<void> _toggleStreaming() async {
    if (_streaming) {
      setState(() {
        _streaming = false;
        _faceDetected = false;
      });
      return;
    }

    final ip = _ipController.text.trim();
    final port = int.tryParse(_portController.text.trim());

    if (ip.isEmpty || port == null) {
      _showError('Enter a valid IP and port');
      return;
    }

    try {
      final addresses = await InternetAddress.lookup(ip);
      if (addresses.isEmpty) throw Exception('Could not resolve IP');
      _targetAddress = addresses.first;
      _targetPort = port;
      setState(() => _streaming = true);
    } catch (e) {
      _showError('Could not connect: $e');
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // ARKit view runs hidden — 1px to keep it alive
          SizedBox(
            width: 1,
            height: 1,
            child: ARKitSceneView(
              configuration: ARKitConfiguration.faceTracking,
              onARKitViewCreated: _onARKitViewCreated,
            ),
          ),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Row(
                    children: [
                      const Text(
                        'HeadTracker',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const Spacer(),
                      _StatusDot(streaming: _streaming, faceDetected: _faceDetected),
                      const SizedBox(width: 8),
                      Text(
                        _streaming
                          ? (_faceDetected ? '$_fps fps' : 'No face')
                          : 'Stopped',
                        style: TextStyle(
                          color: _streaming && _faceDetected
                            ? const Color(0xFF00D4FF)
                            : Colors.grey,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 32),

                  // IP + Port
                  _InputField(
                    controller: _ipController,
                    label: 'PC IP Address',
                    hint: '192.168.1.100',
                    enabled: !_streaming,
                  ),
                  const SizedBox(height: 12),
                  _InputField(
                    controller: _portController,
                    label: 'Port',
                    hint: '4242',
                    enabled: !_streaming,
                    keyboardType: TextInputType.number,
                  ),

                  const SizedBox(height: 24),

                  // Start/Stop button
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _toggleStreaming,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _streaming
                          ? const Color(0xFF3A0000)
                          : const Color(0xFF003A4A),
                        foregroundColor: _streaming
                          ? Colors.redAccent
                          : const Color(0xFF00D4FF),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(
                            color: _streaming
                              ? Colors.redAccent
                              : const Color(0xFF00D4FF),
                          ),
                        ),
                        elevation: 0,
                      ),
                      child: Text(
                        _streaming ? 'Stop Tracking' : 'Start Tracking',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Live pose values
                  const Text(
                    'LIVE POSE',
                    style: TextStyle(
                      color: Colors.grey,
                      fontSize: 11,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _PoseGrid(
                    values: {
                      'YAW': _yaw,
                      'PITCH': _pitch,
                      'ROLL': _roll,
                      'X': _x,
                      'Y': _y,
                      'Z': _z,
                    },
                  ),

                  const Spacer(),

                  // Info footer
                  const Text(
                    'Uses front TrueDepth camera. Point phone at your face.',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _arkitController?.dispose();
    _socket?.close();
    super.dispose();
  }
}

// ── Widgets ──────────────────────────────────────────────────────────────────

class _StatusDot extends StatelessWidget {
  final bool streaming;
  final bool faceDetected;

  const _StatusDot({required this.streaming, required this.faceDetected});

  @override
  Widget build(BuildContext context) {
    Color color;
    if (!streaming) color = Colors.grey;
    else if (faceDetected) color = const Color(0xFF00D4FF);
    else color = Colors.orange;

    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: streaming && faceDetected
          ? [BoxShadow(color: color.withOpacity(0.5), blurRadius: 6)]
          : null,
      ),
    );
  }
}

class _InputField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final bool enabled;
  final TextInputType keyboardType;

  const _InputField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.enabled,
    this.keyboardType = TextInputType.text,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      keyboardType: keyboardType,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: const TextStyle(color: Colors.grey),
        hintStyle: const TextStyle(color: Colors.grey),
        filled: true,
        fillColor: const Color(0xFF1A1A1A),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF00D4FF)),
        ),
      ),
    );
  }
}

class _PoseGrid extends StatelessWidget {
  final Map<String, double> values;

  const _PoseGrid({required this.values});

  @override
  Widget build(BuildContext context) {
    final entries = values.entries.toList();
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 2.2,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: entries.map((e) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                e.key,
                style: const TextStyle(
                  color: Colors.grey,
                  fontSize: 10,
                  letterSpacing: 1,
                ),
              ),
              Text(
                e.value.toStringAsFixed(1),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
