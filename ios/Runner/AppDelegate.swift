import UIKit
import Flutter
import AVFoundation
import Network
import CoreImage

// =============================================================================
//  CameraStreamer — STRICT 60fps front-camera streamer for SimulatorTrack.
//
//  Captures the iPhone front camera locked to exactly 60fps via AVFoundation
//  (the Flutter `camera` plugin can't lock frame rate — this can), hardware-
//  JPEG-encodes each frame with a Metal-backed CIContext, and streams it to the
//  desktop over TCP using the protocol the PC expects:
//        [4-byte big-endian length][JPEG bytes]   repeated.
//
//  Add this file to ios/Runner/ in Xcode, and wire the MethodChannel from
//  AppDelegate (see AppDelegate_camera_channel.swift). No pubspec/Dart camera
//  plugin is needed for this path — Dart only calls start/stop.
// =============================================================================
final class CameraStreamer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let camQueue = DispatchQueue(label: "simtrack.camera.stream")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false]) // Metal/GPU
    private let rgb = CGColorSpaceCreateDeviceRGB()

    private var connection: NWConnection?
    private var isReady = false
    private var isSending = false          // backpressure: one frame in flight at a time
    private var streaming = false

    private var frameCount = 0
    private var lastFps = Date()

    /// Called ~1x/sec on the main thread with the measured send rate.
    var onFps: ((Int) -> Void)?
    /// Called on the main thread on fatal stop (so Dart can update its UI).
    var onStopped: (() -> Void)?

    // MARK: - Public control

    func start(ip: String, port: UInt16, quality: CGFloat = 0.5) {
        if streaming { stop() }

        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self = self else { return }
            guard granted else { DispatchQueue.main.async { self.onStopped?() }; return }
            self.camQueue.async { self.configureAndRun(ip: ip, port: port, quality: quality) }
        }
    }

    func stop() {
        streaming = false
        camQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }
            self.connection?.cancel()
            self.connection = nil
            self.isReady = false
            self.isSending = false
        }
    }

    // MARK: - Setup

    private var jpegQuality: CGFloat = 0.5

    private func configureAndRun(ip: String, port: UInt16, quality: CGFloat) {
        jpegQuality = quality

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device) else {
            DispatchQueue.main.async { self.onStopped?() }
            return
        }

        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: camQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        // Upright in portrait hold.
        if let conn = output.connection(with: .video), conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
        }

        // ---- LOCK 60fps ----
        // Pick the smallest-resolution format that supports >=60fps so the
        // 60fps is sustainable for encode + network, then pin min == max
        // frame duration to 1/60 so the camera cannot drop below 60.
        lock60fps(device)

        setupConnection(ip: ip, port: port)

        session.startRunning()
        streaming = true
        frameCount = 0
        lastFps = Date()
    }

    private func lock60fps(_ device: AVCaptureDevice) {
        var best: AVCaptureDevice.Format?
        var bestWidth = Int.max
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let w = Int(dims.width)
            for range in format.videoSupportedFrameRateRanges where range.maxFrameRate >= 60.0 {
                if w < bestWidth { bestWidth = w; best = format }
            }
        }
        do {
            try device.lockForConfiguration()
            if let fmt = best { device.activeFormat = fmt }   // a format that can do 60
            let sixty = CMTimeMake(value: 1, timescale: 60)
            device.activeVideoMinFrameDuration = sixty        // floor 60fps
            device.activeVideoMaxFrameDuration = sixty        // ceiling 60fps -> locked
            device.unlockForConfiguration()
        } catch {
            // If the device truly can't do 60 it keeps its default; the PC will
            // show the real rate. Every modern iPhone front camera supports 60.
        }
    }

    private func setupConnection(ip: String, port: UInt16) {
        let host = NWEndpoint.Host(ip)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        let conn = NWConnection(host: host, port: nwPort, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready: self.isReady = true
            case .failed, .cancelled:
                self.isReady = false
                self.streaming = false
                DispatchQueue.main.async { self.onStopped?() }
            default: break
            }
        }
        connection = conn
        conn.start(queue: camQueue)
    }

    // MARK: - Per-frame (runs on camQueue at 60fps)

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard streaming, isReady, !isSending,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ci = CIImage(cvPixelBuffer: pb)
        let opts: [CIImageRepresentationOption: Any] =
            [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): jpegQuality]
        guard let jpeg = ciContext.jpegRepresentation(of: ci, colorSpace: rgb, options: opts) else { return }

        var header = Data(count: 4)
        let len = UInt32(jpeg.count)
        header[0] = UInt8((len >> 24) & 0xff)
        header[1] = UInt8((len >> 16) & 0xff)
        header[2] = UInt8((len >> 8) & 0xff)
        header[3] = UInt8(len & 0xff)

        isSending = true
        // FIX: use self.connection to reference the network property, not the AVCaptureConnection parameter
        self.connection?.send(content: header + jpeg, completion: .contentProcessed { [weak self] _ in
            self?.isSending = false
        })

        frameCount += 1
        let now = Date()
        if now.timeIntervalSince(lastFps) >= 1.0 {
            let fps = frameCount
            frameCount = 0
            lastFps = now
            DispatchQueue.main.async { self.onFps?(fps) }
        }
    }
}

// -----------------------------------------------------------------------------
//  AppDelegate – proximity + camera channels
// -----------------------------------------------------------------------------
@main
@objc class AppDelegate: FlutterAppDelegate {
    
    // MARK: - Proximity state
    private var initialUserBrightness: CGFloat = 0.5

    // MARK: - Camera streamer instance
    private let cameraStreamer = CameraStreamer()

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller : FlutterViewController = window?.rootViewController as! FlutterViewController
        
        // ---------- Proximity channel (existing) ----------
        let nativeChannel = FlutterMethodChannel(name: "com.headtracker.app/native",
                                                  binaryMessenger: controller.binaryMessenger)
        
        nativeChannel.setMethodCallHandler({ [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
            guard let self = self else { return }
            
            if call.method == "toggleProximity" {
                if let args = call.arguments as? [String: Any],
                   let enable = args["enable"] as? Bool {
                    
                    DispatchQueue.main.async {
                        if enable {
                            self.initialUserBrightness = UIScreen.main.brightness
                            UIScreen.main.brightness = 0.0
                        } else {
                            UIScreen.main.brightness = self.initialUserBrightness
                        }
                    }
                    result(true)
                } else {
                    result(FlutterError(code: "BAD_ARGS", message: "Arguments malformed", details: nil))
                }
            } else {
                result(FlutterMethodNotImplemented)
            }
        })

        // ---------- Camera stream channel (new) ----------
        let cameraChannel = FlutterMethodChannel(
            name: "com.headtracker.app/camera",
            binaryMessenger: controller.binaryMessenger)
        
        cameraChannel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { result(false); return }
            switch call.method {
            case "start":
                let args = call.arguments as? [String: Any]
                let ip = args?["ip"] as? String ?? ""
                let port = UInt16(args?["port"] as? Int ?? 4243)
                let quality = CGFloat(args?["quality"] as? Double ?? 0.5)
                self.cameraStreamer.start(ip: ip, port: port, quality: quality)
                result(true)
            case "stop":
                self.cameraStreamer.stop()
                result(true)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        // Push live fps / disconnect events back to Dart
        cameraStreamer.onFps = { fps in
            cameraChannel.invokeMethod("fps", arguments: fps)
        }
        cameraStreamer.onStopped = {
            cameraChannel.invokeMethod("stopped", arguments: nil)
        }

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}