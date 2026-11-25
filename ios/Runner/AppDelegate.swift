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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "TorBoxStrmLinks") {
      AppLinks.attach(messenger: registrar.messenger())
    }
  }
}

/// `torboxstrm://…` links (QR codes: phone ↔ TV pairing, server code) for the Dart side.
/// Same channel and methods as the Android MainActivity (lib/util/links.dart).
enum AppLinks {
  private static var channel: FlutterMethodChannel?
  /// Links that arrived before Dart asked for them.
  private static var pending: [String] = []
  private static var dartReady = false

  static func attach(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "torboxstrm/intent", binaryMessenger: messenger)
    ch.setMethodCallHandler { call, result in
      switch call.method {
      case "initialLink":
        dartReady = true
        result(pending.isEmpty ? nil : pending.removeFirst())
        // more than one waiting: hand the rest over as live links
        let rest = pending
        pending.removeAll()
        for link in rest { ch.invokeMethod("link", arguments: link) }
      case "isTv":
        result(false)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channel = ch
  }

  static func deliver(_ url: URL) {
    guard url.scheme?.lowercased() == "torboxstrm" else { return }
    let link = url.absoluteString
    if dartReady, let ch = channel {
      ch.invokeMethod("link", arguments: link)
    } else {
      pending.append(link)
    }
  }
}
