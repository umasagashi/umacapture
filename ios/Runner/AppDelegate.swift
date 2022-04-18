import UIKit
import Flutter
import ReplayKit

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
    private let CHANNEL = "dev.flutter.umasagashi_app/capturing_channel"
    private let app = AppWrapper()
    
    private func startCapture() -> Void {
        NSLog("swift-startCapture")
        guard !RPScreenRecorder.shared().isRecording else {return}
        RPScreenRecorder.shared().isMicrophoneEnabled = false
        RPScreenRecorder.shared().startCapture(handler: { (buffer, bufferType, error) in
            if let error = error {
                print(error)
            }
            NSLog("handler - ¥(bufferType)")
        }, completionHandler: {
            if let error = $0 {
                print(error)
            }
        })
    }
    
    private func stopCapture() -> Void {
        NSLog("swift-stopCapture")
        guard RPScreenRecorder.shared().isRecording else {return}
        RPScreenRecorder.shared().stopCapture { (error) in
            if let error = error {
                print(error)
            }
        }
    }
    
    private func setConfig(config: String) -> Void {
        NSLog("swift-setConfig: " + config)
        app.setConfig(config)
    }
    
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        NSLog("swift-application")
        let controller : FlutterViewController = window?.rootViewController as! FlutterViewController
        let batteryChannel = FlutterMethodChannel(name: CHANNEL, binaryMessenger: controller.binaryMessenger)
        batteryChannel.setMethodCallHandler({
            (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
            switch call.method {
            case "startCapture": self.startCapture()
            case "stopCapture": self.stopCapture()
            case "setConfig": self.setConfig(config: call.arguments as! String)
            default: result(FlutterMethodNotImplemented)
            }
        })
        
        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}
