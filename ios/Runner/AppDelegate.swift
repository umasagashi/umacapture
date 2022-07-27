import UIKit
import Flutter
import ReplayKit

@UIApplicationMain
class AppDelegate: FlutterAppDelegate {
    private let METHOD_CHANNEL = "dev.flutter.umasagashi/capturing_channel"
    private let BROADCAST_EXTENSION = "com.umasagashi.umacapture.Capturer"
    private let APP_GROUP = "group.com.umasagashi"

    private let api = NativeApiBridge()

    private var appDirectory: String?
    private var picker: RPSystemBroadcastPickerView? = nil

    private func copySharedContainer(path: String) -> Void {
        let fileManager = FileManager.default
        if let root = fileManager.containerURL(forSecurityApplicationGroupIdentifier: APP_GROUP) {
            let source = root.appendingPathComponent(path)
            let dest = URL(fileURLWithPath: appDirectory!).appendingPathComponent(path)
            NSLog("src: \(source.path)")
            NSLog("dst: \(dest)")
            NSLog("remove")
            try? fileManager.removeItem(at: dest)
//            try? fileManager.createDirectory(atPath: dest.path, withIntermediateDirectories: true)
            NSLog("copy")
            try? fileManager.copyItem(atPath: source.path, toPath: dest.path)
            NSLog("finished")
        }
    }

    private func showBroadcastDialog() -> Void {
        if self.picker == nil {
            // No need to show picker itself, since I only require the picker's button.
            let picker = RPSystemBroadcastPickerView(frame: CGRect())
            picker.preferredExtension = BROADCAST_EXTENSION
            picker.showsMicrophoneButton = false
            self.picker = picker
        }

        guard let button = self.picker?.subviews.first as? UIButton else {
            return
        }

        button.sendActions(for: .touchUpInside)
    }

    private func startCapture() -> Void {
        NSLog("AppDelegate: startCapture")
        showBroadcastDialog()
    }

    private func stopCapture() -> Void {
        NSLog("AppDelegate: stopCapture")
        copySharedContainer(path: "images")
    }

    private func setConfig(_ config: String) -> Void {
        NSLog("AppDelegate: setConfig")
        api.setConfig(config)

        if let d = config.data(using: String.Encoding.utf8) {
            if let items = try? JSONSerialization.jsonObject(with: d) as? Dictionary<String, Any> {
                let directory = (items["chara_detail"] as! Dictionary<String, Any>)["scraping_dir"] as! String;
                NSLog("directory: \(directory)")
                appDirectory = directory
            }
        }

        let userDefaults = UserDefaults(suiteName: APP_GROUP)
        userDefaults?.set(config, forKey: "config")
        userDefaults?.synchronize()

        copySharedContainer(path: "images")
    }

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        api.initializeNative();

        GeneratedPluginRegistrant.register(with: self)

        let controller = window?.rootViewController as! FlutterViewController
        let channel = FlutterMethodChannel(name: METHOD_CHANNEL, binaryMessenger: controller.binaryMessenger)
        channel.setMethodCallHandler({
            (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
            switch call.method {
            case "startCapture": self.startCapture()
            case "stopCapture": self.stopCapture()
            case "setConfig": self.setConfig(call.arguments as! String)
            default: result(FlutterMethodNotImplemented)
            }
        })

        api.setNotifyCallback({ (message: String?) in
            DispatchQueue.main.async {
                channel.invokeMethod("notify", arguments: message)
            }
        });


        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}
