import UIKit
import Flutter
import AVFoundation
import Network

// =============================================================================
//  CameraStreamer — STRICT 60fps front‑camera streamer.
// =============================================================================
final class CameraStreamer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let camQueue = DispatchQueue(label: "simtrack.camera.stream")
    private var connection: NWConnection?
    private var isReady = false
    private var isSending = false
    private var streaming = false

    private var frameCount = 0
    private var lastFps = Date()

    var onFps: ((Int) -> Void)?
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

        if let conn = output.connection(with: .video), conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
        }

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
            if let fmt = best { device.activeFormat = fmt }
            let sixty = CMTimeMake(value: 1, timescale: 60)
            device.activeVideoMinFrameDuration = sixty
            device.activeVideoMaxFrameDuration = sixty
            device.unlockForConfiguration()
        } catch { }
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

    // MARK: - Per‑frame (changed to UIImage encoder)

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from avConnection: AVCaptureConnection) {

        guard streaming, isReady, !isSending,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // --- robust JPEG via UIImage (works every time) ---
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let uiImage = UIImage(cgImage: cgImage)
        guard let jpegData = uiImage.jpegData(compressionQuality: jpegQuality) else { return }

        var header = Data(count: 4)
        let len = UInt32(jpegData.count)
        header[0] = UInt8((len >> 24) & 0xff)
        header[1] = UInt8((len >> 16) & 0xff)
        header[2] = UInt8((len >> 8) & 0xff)
        header[3] = UInt8(len & 0xff)

        isSending = true
        self.connection?.send(content: header + jpegData, completion: .contentProcessed { [weak self] _ in
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

    private var initialUserBrightness: CGFloat = 0.5
    private let cameraStreamer = CameraStreamer()

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller = window?.rootViewController as! FlutterViewController

        // Proximity channel
        let nativeChannel = FlutterMethodChannel(name: "com.headtracker.app/native",
                                                  binaryMessenger: controller.binaryMessenger)
        nativeChannel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { return }
            if call.method == "toggleProximity",
               let args = call.arguments as? [String: Any],
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
                result(FlutterMethodNotImplemented)
            }
        }

        // Camera channel
        let cameraChannel = FlutterMethodChannel(name: "com.headtracker.app/camera",
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