import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {
    
    // Class level variable properties to cache historical user settings parameters
    private var initialUserBrightness: CGFloat = 0.5

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller : FlutterViewController = window?.rootViewController as! FlutterViewController
        let nativeChannel = FlutterMethodChannel(name: "com.headtracker.app/native",
                                                  binaryMessenger: controller.binaryMessenger)
        
        nativeChannel.setMethodCallHandler({
            [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
            guard let self = self else { return }
            
            if call.method == "toggleProximity" {
                if let args = call.arguments as? [String: Any],
                   let enable = args["enable"] as? Bool {
                    
                    DispatchQueue.main.async {
                        if enable {
                            // Reads your exact custom brightness setting value instantly before killing screen emitters
                            self.initialUserBrightness = UIScreen.main.brightness
                            UIScreen.main.brightness = 0.0
                        } else {
                            // Automatically restores your precise custom configuration baseline flawlessly on wakeup
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

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}