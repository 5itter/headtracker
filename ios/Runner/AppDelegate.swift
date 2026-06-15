import UIKit
import Flutter
import AVFoundation
import Network
import CoreImage
import CoreMedia
import CoreVideo

// =============================================================================
//  CameraStreamer — STRICT 60fps front‑camera streamer.
// =============================================================================
final class CameraStreamer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let camQueue = DispatchQueue(label: "simtrack.camera.stream")
    private let ciContext = CIContext()          // reused across frames (creating one per frame is slow)
    private var connection: NWConnection?
    private var listener: NWListener?            // USB mode: the phone is the server
    private var useUsb = false
    private var isReady = false
    private var isSending = false
    private var streaming = false

    private var frameCount = 0
    private var lastFps = Date()
    private var capturedCount = 0          // frames the camera delivered (alive even if not connected)
    private var lastCapReport = Date()

    var onFps: ((Int) -> Void)?            // frames SENT to the PC per second
    var onStopped: (() -> Void)?
    var onStatus: ((String) -> Void)?      // human-readable status for the app UI

    // MARK: - Public control

    func start(ip: String, port: UInt16, quality: CGFloat = 0.5, usb: Bool = false) {
        if streaming { stop() }
        useUsb = usb
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
            self.listener?.cancel()
            self.listener = nil
            self.isReady = false
            self.isSending = false
        }
    }

    // MARK: - Setup

    private var jpegQuality: CGFloat = 0.5

    private func configureAndRun(ip: String, port: UInt16, quality: CGFloat) {
        jpegQuality = quality

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            DispatchQueue.main.async { self.onStatus?("No front camera"); self.onStopped?() }
            return
        }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) }
        catch {
            DispatchQueue.main.async { self.onStatus?("Camera busy (ARKit still running?)"); self.onStopped?() }
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .inputPriority                 // we drive the format via activeFormat
        session.inputs.forEach { session.removeInput($0) }     // clean slate on re-start
        session.outputs.forEach { session.removeOutput($0) }
        if session.canAddInput(input) { session.addInput(input) }

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: camQueue)
        if session.canAddOutput(output) { session.addOutput(output) }

        // pick + lock a 60fps-capable format INSIDE the configuration (correct order)
        if let fmt = best60Format(device) {
            do {
                try device.lockForConfiguration()
                device.activeFormat = fmt
                let sixty = CMTimeMake(value: 1, timescale: 60)
                device.activeVideoMinFrameDuration = sixty
                device.activeVideoMaxFrameDuration = sixty
                device.unlockForConfiguration()
            } catch { }
        }
        session.commitConfiguration()

        if let conn = output.connection(with: .video), conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
        }

        if useUsb { startServer(port: port) }      // USB: PC dials us via iproxy
        else { setupConnection(ip: ip, port: port) } // Wi-Fi: we dial the PC

        session.startRunning()
        streaming = true
        frameCount = 0; lastFps = Date()
        capturedCount = 0; lastCapReport = Date()
        let onAir = session.isRunning
        DispatchQueue.main.async {
            self.onStatus?(onAir
                ? (self.useUsb ? "Camera on — USB, waiting for PC on 4243"
                               : "Camera on — Wi-Fi, connecting to \(ip)")
                : "Camera failed to start")
        }
    }

    private func best60Format(_ device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var bestWidth = Int.max
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let w = Int(dims.width)
            for range in format.videoSupportedFrameRateRanges where range.maxFrameRate >= 60.0 {
                if w < bestWidth { bestWidth = w; best = format }
            }
        }
        return best
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
            case .ready:
                self.isReady = true
                DispatchQueue.main.async { self.onStatus?("Connected — streaming to PC") }
            case .waiting(let err):
                self.isReady = false
                DispatchQueue.main.async { self.onStatus?("Can't reach PC: \(err) — check IP / desktop netcam / Local Network permission") }
            case .failed(let err):
                self.isReady = false; self.streaming = false
                DispatchQueue.main.async { self.onStatus?("Connection failed: \(err)"); self.onStopped?() }
            case .cancelled:
                self.isReady = false
            default: break
            }
        }
        connection = conn
        conn.start(queue: camQueue)
    }

    // USB mode: listen on `port`; the PC connects through iproxy and we stream
    // frames down the accepted connection.
    private func startServer(port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            DispatchQueue.main.async { self.onStopped?() }
            return
        }
        listener?.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            self.connection?.cancel()
            self.isReady = false
            self.connection = conn
            conn.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.isReady = true
                    DispatchQueue.main.async { self.onStatus?("Connected — streaming to PC (USB)") }
                case .failed, .cancelled:
                    self.isReady = false
                default: break
                }
            }
            conn.start(queue: self.camQueue)
        }
        listener?.start(queue: camQueue)
    }

    // MARK: - Per‑frame (changed to UIImage encoder)

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from avConnection: AVCaptureConnection) {

        guard streaming, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // The camera IS alive if we get here — report captured fps so 0 "sent"
        // fps doesn't look like a dead camera. (Sent fps comes from onFps below.)
        capturedCount += 1
        let capNow = Date()
        if capNow.timeIntervalSince(lastCapReport) >= 1.0 {
            let cfps = capturedCount; capturedCount = 0; lastCapReport = capNow
            let ready = isReady
            DispatchQueue.main.async {
                self.onStatus?(ready ? "Streaming \(cfps)fps to PC" : "Camera live \(cfps)fps — connecting to PC…")
            }
        }

        // Only encode+send once the PC connection is ready, one frame in flight.
        guard isReady, !isSending else { return }

        // --- robust JPEG via UIImage (works every time) ---
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
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
                let usb = (args?["usb"] as? Bool) ?? false
                self.cameraStreamer.start(ip: ip, port: port, quality: quality, usb: usb)
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
        cameraStreamer.onStatus = { msg in
            cameraChannel.invokeMethod("status", arguments: msg)
        }
        cameraStreamer.onStopped = {
            cameraChannel.invokeMethod("stopped", arguments: nil)
        }

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}