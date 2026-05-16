import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';

void main() => runApp(const UDPTestApp());

class UDPTestApp extends StatelessWidget {
  const UDPTestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UDP Test',
      theme: ThemeData.dark(),
      home: const UDPTestScreen(),
    );
  }
}

class UDPTestScreen extends StatefulWidget {
  const UDPTestScreen({super.key});

  @override
  State<UDPTestScreen> createState() => _UDPTestScreenState();
}

class _UDPTestScreenState extends State<UDPTestScreen> {
  final _ipController = TextEditingController(text: '192.168.8.14');
  final _portController = TextEditingController(text: '4242');
  String _status = 'Ready';
  int _sent = 0;

  Future<void> _sendTest() async {
    final ip = _ipController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 4242;

    try {
      setState(() => _status = 'Creating socket...');

      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);

      setState(() => _status = 'Socket created on port ${socket.port}. Sending...');

      // Send 10 test packets
      for (int i = 0; i < 10; i++) {
        final buf = ByteData(48);
        buf.setFloat64(0,  0.0,          Endian.little); // x
        buf.setFloat64(8,  0.0,          Endian.little); // y
        buf.setFloat64(16, 0.0,          Endian.little); // z
        buf.setFloat64(24, i * 10.0,     Endian.little); // yaw
        buf.setFloat64(32, 5.0,          Endian.little); // pitch
        buf.setFloat64(40, 0.0,          Endian.little); // roll

        final dest = InternetAddress(ip);
        final bytesSent = socket.send(buf.buffer.asUint8List(), dest, port);

        setState(() {
          _sent++;
          _status = 'Sent packet $_sent — $bytesSent bytes to $ip:$port (yaw=${i * 10.0})';
        });

        await Future.delayed(const Duration(milliseconds: 100));
      }

      socket.close();
      setState(() => _status = 'Done. Sent 10 packets. Check PC terminal.');

    } catch (e) {
      setState(() => _status = 'ERROR: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('UDP Test')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            TextField(
              controller: _ipController,
              decoration: const InputDecoration(
                labelText: 'PC IP',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _portController,
              decoration: const InputDecoration(
                labelText: 'Port',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: _sendTest,
                child: const Text('Send 10 Test Packets'),
              ),
            ),
            const SizedBox(height: 32),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey[900],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _status,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Total sent: $_sent',
              style: const TextStyle(fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }
}
