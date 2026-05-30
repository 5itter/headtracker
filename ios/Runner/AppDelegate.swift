import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller : FlutterViewController = window?.rootViewController as! FlutterViewController
        let nativeChannel = FlutterMethodChannel(name: "com.headtracker.app/native",
                                                  binaryMessenger: controller.binaryMessenger)
        
        nativeChannel.setMethodCallHandler({
            (call: FlutterMethodCall, result: @escaping FlutterResult) in
            if call.method == "toggleProximity" {
                if let args = call.arguments as? [String: Any],
                   let enable = args["enable"] as? Bool {
                    
                    // Native Hardware Power Overwrite Routine
                    DispatchQueue.main.async {
                        UIDevice.current.isProximityMonitoringEnabled = enable
                    }
                    result(true)
                } else {
                    result(FlutterError(code: "BAD_ARGS", message: "Arguments malformed", details: nil))
                }
            } else {
                result(FlutterMethodNotImplemented)
            }
        })

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}