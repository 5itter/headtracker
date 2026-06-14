import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {
    
    // MARK: - Proximity state
    private var initialUserBrightness: CGFloat = 0.5

    // MARK: - Camera streamer instance (ensure CameraStreamer.swift is added to the project)
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