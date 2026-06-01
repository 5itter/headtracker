import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:arkit_plugin/arkit_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  RawDatagramSocket? _udpSocket;
  ServerSocket? _tcpServer;
  Socket? _tcpClientSocket;

  InternetAddress? _targetAddress;
  int _targetPort = 4242;

  bool _streaming = false;
  bool _faceDetected = false;
  bool _showCamera = false;
  bool _nodeBound = false;
  bool _screenBlackoutMode = false;
  bool _isUsbMode = false;

  static const _faceMeshNodeName = 'face_mesh';

  double _yaw = 0, _pitch = 0, _roll = 0;
  double _x = 0, _y = 0, _z = 0;

  int _fps = 0;
  int _frameCount = 0;
  int _packetsSent = 0;

  DateTime _lastFpsCheck = DateTime.now();
  DateTime _lastUiUpdate = DateTime.now();

  final _ipController = TextEditingController(text: '192.168.1.100');
  final _portController = TextEditingController(text: '4242');

  final ByteData _packetBuffer = ByteData(48);
  late Uint8List _packetUint8ListView;

  @override
  void initState() {
    super.initState();
    _packetUint8ListView = _packetBuffer.buffer.asUint8List();
    _loadSavedSettings();
  }

  Future<void> _loadSavedSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final savedIp = prefs.getString('saved_ip');
    final savedPort = prefs.getString('saved_port');

    if (savedIp != null && savedIp.isNotEmpty) {
      _ipController.text = savedIp;
    }
    if (savedPort != null && savedPort.isNotEmpty) {
      _portController.text = savedPort;
    }
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_ip', _ipController.text.trim());
    await prefs.setString('saved_port', _portController.text.trim());
  }

  void _onARKitViewCreated(ARKitController controller) {
    _arkitController = controller;
    _arkitController!.onAddNodeForAnchor = _handleAnchor;
    _arkitController!.onUpdateNodeForAnchor = _handleAnchor;
  }

  void _handleAnchor(ARKitAnchor anchor) {
    if (anchor is! ARKitFaceAnchor) return;

    // 1. EXTRACT TRACKING COORDINATES
    final t = anchor.transform;
    final r20 = t.entry(2, 0);
    final r21 = t.entry(2, 1);
    final r22 = t.entry(2, 2);
    final r01 = t.entry(0, 1);
    final r11 = t.entry(1, 1);

    final pitch = asin(-r21.clamp(-1.0, 1.0)) * (180.0 / pi);
    final yaw = atan2(r20, r22) * (180.0 / pi);
    final roll = atan2(r01, r11) * (180.0 / pi);

    final x = t.entry(0, 3) * 100.0;
    final y = t.entry(1, 3) * 100.0;
    final z = t.entry(2, 3) * 100.0;

    // 2. IMMEDIATE HOT PATH STREAM ROUTER
    if (_streaming) {
      _packetBuffer.setFloat64(0, x, Endian.little);
      _packetBuffer.setFloat64(8, y, Endian.little);
      _packetBuffer.setFloat64(16, z, Endian.little);
      _packetBuffer.setFloat64(24, yaw, Endian.little);
      _packetBuffer.setFloat64(32, pitch, Endian.little);
      _packetBuffer.setFloat64(40, roll, Endian.little);

      if (_isUsbMode) {
        if (_tcpClientSocket != null) {
          _tcpClientSocket!.add(_packetUint8ListView);
          _packetsSent++;
        }
      } else {
        if (_udpSocket != null && _targetAddress != null) {
          _udpSocket!.send(_packetUint8ListView, _targetAddress!, _targetPort);
          _packetsSent++;
        }
      }
    }

    if (_screenBlackoutMode) return;

    // 3. PERFORMANCE LOGGING EVALUATION
    _frameCount++;
    final now = DateTime.now();
    if (now.difference(_lastFpsCheck).inMilliseconds >= 1000) {
      _fps = _frameCount;
      _frameCount = 0;
      _lastFpsCheck = now;
    }

    // 4. LOW-OVERHEAD GEOMETRY SYNCHRONIZATION
    _updateFaceMesh(anchor);

    // 5. VISUAL LAYOUT ENGINE THROTTLE
    final bool shouldUpdateUiLayout =
        _showCamera || (now.difference(_lastUiUpdate).inMilliseconds >= 100);

    if (shouldUpdateUiLayout) {
      _lastUiUpdate = now;
      setState(() {
        _yaw = yaw;
        _pitch = pitch;
        _roll = roll;
        _x = x;
        _y = y;
        _z = z;
        _faceDetected = true;
      });
    } else if (!_faceDetected) {
      setState(() => _faceDetected = true);
    }
  }

  void _updateFaceMesh(ARKitFaceAnchor anchor) {
    if (_arkitController == null || _nodeBound) return;

    final material = ARKitMaterial(
      fillMode: ARKitFillMode.lines,
      diffuse: ARKitMaterialProperty.color(const Color(0x8800D4FF)),
    );
    anchor.geometry.materials.value = [material];

    final node = ARKitNode(name: _faceMeshNodeName, geometry: anchor.geometry);
    _arkitController!.add(node, parentNodeName: anchor.nodeName);
    _nodeBound = true;
  }

  Future<void> _toggleStreaming() async {
    if (_streaming) {
      _udpSocket?.close();
      _udpSocket = null;
      _tcpClientSocket?.close();
      _tcpClientSocket = null;
      _tcpServer?.close();
      _tcpServer = null;

      setState(() {
        _streaming = false;
        _faceDetected = false;
        _packetsSent = 0;
        _screenBlackoutMode = false;
        _nodeBound = false;
      });
      return;
    }

    final port = int.tryParse(_portController.text.trim());
    if (port == null) {
      _showError('Enter a valid port number');
      return;
    }

    await _saveSettings();

    if (_isUsbMode) {
      try {
        _targetPort = port;
        _tcpServer = await ServerSocket.bind(InternetAddress.anyIPv4, port);
        setState(() => _streaming = true);

        _tcpServer!.listen((Socket client) {
          _tcpClientSocket = client;
          _tcpClientSocket!.setOption(SocketOption.tcpNoDelay, true);
          setState(() => _faceDetected = true);
        }, onError: (err) {
          _showError('USB Stream Error: $err');
        });
      } catch (e) {
        _showError('Failed to initialize USB Server: $e');
      }
    } else {
      final ip = _ipController.text.trim();
      if (ip.isEmpty) {
        _showError('Enter a valid target IP address');
        return;
      }
      try {
        _targetAddress = InternetAddress(ip);
        _targetPort = port;
        _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        setState(() => _streaming = true);
      } catch (e) {
        _showError('Failed to open Wi-Fi Socket: $e');
      }
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool cameraIsRequired = _streaming || _showCamera;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _screenBlackoutMode
          ? SystemUiOverlayStyle.light.copyWith(statusBarColor: Colors.black)
          : SystemUiOverlayStyle.light
              .copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        backgroundColor: const Color(0xFF0A0A0A),
        body: Stack(
          children: [
            // FIXED RESENTION MATRIX: Viewport structure remains identical to protect blue anchors
            if (cameraIsRequired)
              Positioned.fill(
                child: ARKitSceneView(
                  configuration: ARKitConfiguration.faceTracking,
                  onARKitViewCreated: _onARKitViewCreated,
                  showStatistics: false,
                ),
              )
            else
              const SizedBox.shrink(),

            // Mask layer blocks tracking feed artifacts completely during dashboard paths
            if (!_showCamera)
              Positioned.fill(
                child: Container(color: const Color(0xFF0A0A0A)),
              ),

            // Main Core User Interface Container
            SafeArea(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Clean Header Row (Hidden completely during canvas views)
                    if (!_showCamera)
                      Row(
                        children: [
                          const Text(
                            'HeadTracker',
                            style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: Colors.white),
                          ),
                          const Spacer(),
                          _StatusDot(
                              streaming: _streaming,
                              faceDetected: _faceDetected),
                          const SizedBox(width: 8),
                          Text(
                            _streaming
                                ? (_faceDetected
                                    ? '$_fps FPS'
                                    : (_isUsbMode ? 'Wired Idle' : 'No Face'))
                                : 'Stopped',
                            style: TextStyle(
                                color: _streaming && _faceDetected
                                    ? const Color(0xFF00D4FF)
                                    : Colors.grey,
                                fontSize: 13,
                                fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),

                    const SizedBox(height: 20),

                    // Interactive Configurations Tree (Hidden completely during previews)
                    if (!_showCamera) ...[
                      if (!_streaming)
                        Row(
                          children: [
                            Expanded(
                              child: ChoiceChip(
                                label: const Center(child: Text('Wi-Fi')),
                                selected: !_isUsbMode,
                                onSelected: (val) =>
                                    setState(() => _isUsbMode = false),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: ChoiceChip(
                                label: const Center(child: Text('USB')),
                                selected: _isUsbMode,
                                onSelected: (val) =>
                                    setState(() => _isUsbMode = true),
                              ),
                            ),
                          ],
                        ),
                      const SizedBox(height: 20),
                      const Text('LIVE POSE',
                          style: TextStyle(
                              color: Colors.grey,
                              fontSize: 11,
                              letterSpacing: 1.5)),
                      const SizedBox(height: 12),
                      _PoseGrid(values: {
                        'YAW': _yaw,
                        'PITCH': _pitch,
                        'ROLL': _roll,
                        'X': _x,
                        'Y': _y,
                        'Z': _z
                      }),
                      const SizedBox(height: 24),
                      if (!_isUsbMode) ...[
                        _InputField(
                            controller: _ipController,
                            label: 'PC IP Address',
                            hint: '192.168.1.100',
                            enabled: !_streaming),
                        const SizedBox(height: 12),
                      ],
                      _InputField(
                          controller: _portController,
                          label: 'Port Mapping Node',
                          hint: '4242',
                          enabled: !_streaming,
                          keyboardType: TextInputType.number),
                    ],

                    const Spacer(),

                    // Primary Operational Control Hub (Hidden during fullscreen preview)
                    if (!_showCamera) ...[
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
                                      : const Color(0xFF00D4FF)),
                            ),
                            elevation: 0,
                          ),
                          child: Text(
                            _streaming ? 'Stop Tracking' : 'Start Tracking',
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],

                    // FIXED ACCESS HUB: Repositioned secondary row cleanly docked beneath tracking toggle
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 44,
                            child: OutlinedButton.icon(
                              onPressed: () =>
                                  setState(() => _showCamera = !_showCamera),
                              icon: Icon(
                                  _showCamera
                                      ? Icons.dashboard
                                      : Icons.videocam,
                                  size: 16),
                              label: Text(
                                  _showCamera ? 'Hide Canvas' : 'Preview',
                                  style: const TextStyle(
                                      fontSize: 13)), // Clean label
                              style: OutlinedButton.styleFrom(
                                foregroundColor: _showCamera
                                    ? const Color(0xFF00D4FF)
                                    : Colors.grey,
                                side: BorderSide(
                                    color: _showCamera
                                        ? const Color(0xFF00D4FF)
                                        : Colors.grey.withValues(alpha: 0.3)),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8)),
                              ),
                            ),
                          ),
                        ),
                        if (_streaming && !_showCamera) ...[
                          const SizedBox(width: 10),
                          Expanded(
                            child: SizedBox(
                              height: 44,
                              child: OutlinedButton.icon(
                                onPressed: () {
                                  setState(() => _screenBlackoutMode = true);
                                  SystemChrome.setEnabledSystemUIMode(
                                      SystemUiMode.manual,
                                      overlays: []);
                                  const MethodChannel(
                                          'com.headtracker.app/native')
                                      .invokeMethod(
                                          'toggleProximity', {'enable': true});
                                },
                                icon: const Icon(Icons.power_settings_new,
                                    size: 16),
                                label: const Text('Display Off',
                                    style: TextStyle(fontSize: 13)),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.grey,
                                  side: BorderSide(
                                      color:
                                          Colors.grey.withValues(alpha: 0.3)),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8)),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),

                    if (!_showCamera) ...[
                      const SizedBox(height: 14),
                      Center(
                        child: Text(
                          'Packets sent: $_packetsSent',
                          style: TextStyle(
                              color: _packetsSent > 0
                                  ? const Color(0xFF00D4FF)
                                  : Colors.grey,
                              fontSize: 13,
                              fontFamily: 'monospace'),
                        ),
                      ),
                      const SizedBox(height: 6),
                    ],
                  ],
                ),
              ),
            ),

            // NATIVE ECLIPSE BLACKOUT OVERLAY
            if (_screenBlackoutMode)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: () {
                    setState(() => _screenBlackoutMode = false);
                    SystemChrome.setEnabledSystemUIMode(
                        SystemUiMode.edgeToEdge);
                    const MethodChannel('com.headtracker.app/native')
                        .invokeMethod('toggleProximity', {'enable': false});
                  },
                  child: Container(
                    color: Colors.black,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _arkitController?.dispose();
    _udpSocket?.close();
    _tcpClientSocket?.close();
    _tcpServer?.close();
    super.dispose();
  }
}

class _StatusDot extends StatelessWidget {
  final bool streaming;
  final bool faceDetected;
  const _StatusDot({required this.streaming, required this.faceDetected});
  @override
  Widget build(BuildContext context) {
    Color color = !streaming
        ? Colors.grey
        : (faceDetected ? const Color(0xFF00D4FF) : Colors.orange);
    return Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle));
  }
}

class _InputField extends StatelessWidget {
  final TextEditingController controller;
  final String label, hint;
  final bool enabled;
  final TextInputType keyboardType;
  const _InputField(
      {required this.controller,
      required this.label,
      required this.hint,
      required this.enabled,
      this.keyboardType = TextInputType.text});
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
            borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF00D4FF))),
      ),
    );
  }
}

class _PoseGrid extends StatelessWidget {
  final Map<String, double> values;
  const _PoseGrid({required this.values});
  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 2.2,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: values.entries
          .map((e) => Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                    color: const Color(0xFF1A1A1A),
                    borderRadius: BorderRadius.circular(8)),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(e.key,
                          style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 10,
                              letterSpacing: 1)),
                      Text(e.value.toStringAsFixed(1),
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w500)),
                    ]),
              ))
          .toList(),
    );
  }
}
