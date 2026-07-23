import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: "cc.seeed.voice/settings",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "openSystemBluetoothSettings":
        Self.openSystemBluetoothSettings(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Opens system Bluetooth settings when possible; otherwise the Settings app
  /// root. Never opens this app's settings page (users cannot Forget devices there).
  private static func openSystemBluetoothSettings(result: @escaping FlutterResult) {
    let candidates = [
      "App-Prefs:root=Bluetooth",
      "App-Prefs:Bluetooth",
      "prefs:root=Bluetooth",
      "App-Prefs:",
      "prefs:root=",
    ]
    openFirstAvailableUrl(candidates, index: 0, result: result)
  }

  private static func openFirstAvailableUrl(
    _ urls: [String],
    index: Int,
    result: @escaping FlutterResult
  ) {
    guard index < urls.count else {
      result(
        FlutterError(
          code: "unavailable",
          message: "Unable to open system Settings",
          details: nil
        )
      )
      return
    }
    guard let url = URL(string: urls[index]) else {
      openFirstAvailableUrl(urls, index: index + 1, result: result)
      return
    }
    UIApplication.shared.open(url, options: [:]) { success in
      if success {
        result(nil)
      } else {
        openFirstAvailableUrl(urls, index: index + 1, result: result)
      }
    }
  }
}
