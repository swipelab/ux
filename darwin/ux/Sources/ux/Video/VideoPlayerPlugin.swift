import AVFoundation
import Foundation
#if canImport(UIKit)
import Flutter
#else
import FlutterMacOS
#endif

/// `ux/video` + `ux/video/events` registrar. Routes channel calls to
/// per-handle [UxVideoPlayerInstance]s. Mirrors `CameraPlugin`'s shape.
public class UxVideoPlayerPlugin: NSObject, NativePlugin, FlutterStreamHandler {
    private weak var textureRegistry: FlutterTextureRegistry?
    private var instances: [Int: UxVideoPlayerInstance] = [:]
    private var nextHandle: Int = 1
    private var eventSink: FlutterEventSink?

    public func register(with registrar: FlutterPluginRegistrar) {
        textureRegistry = registrar.uxTextures

        let methods = FlutterMethodChannel(
            name: "ux/video",
            binaryMessenger: registrar.uxMessenger,
        )
        methods.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }

        let events = FlutterEventChannel(
            name: "ux/video/events",
            binaryMessenger: registrar.uxMessenger,
        )
        events.setStreamHandler(self)
    }

    // MARK: - FlutterStreamHandler

    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink,
    ) -> FlutterError? {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    // MARK: - Dispatch

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "create":
            create(args: call.arguments, result: result)
        case "initialize":
            withInstance(call.arguments, result: result) { instance in
                instance.prepare { prepared in
                    DispatchQueue.main.async {
                        switch prepared {
                        case let .ready(size, durationMs, rotationQuarterTurns):
                            result(
                                [
                                    "size": [
                                        "width": Double(size.width),
                                        "height": Double(size.height),
                                    ] as [String: Any],
                                    "durationMs": durationMs,
                                    "rotationQuarterTurns": rotationQuarterTurns,
                                ] as [String: Any]
                            )
                        case let .failed(error):
                            result(
                                FlutterError(
                                    code: "decode_failed",
                                    message: error.localizedDescription,
                                    details: nil,
                                )
                            )
                        case .disposed:
                            result(
                                FlutterError(
                                    code: "disposed",
                                    message: "player disposed before it was ready",
                                    details: nil,
                                )
                            )
                        }
                    }
                }
            }
        case "dispose":
            withInstance(call.arguments, result: result) { instance in
                self.instances.removeValue(forKey: instance.handle)
                instance.dispose()
                result(nil)
            }
        case "play":
            withInstance(call.arguments, result: result) { instance in
                instance.play()
                result(nil)
            }
        case "pause":
            withInstance(call.arguments, result: result) { instance in
                instance.pause()
                result(nil)
            }
        case "seekTo":
            guard let args = call.arguments as? [String: Any],
                  let pos = (args["positionMs"] as? NSNumber)?.int64Value
            else {
                result(badArgs("seekTo"))
                return
            }
            withInstance(args, result: result) { instance in
                instance.seekTo(positionMs: pos)
                result(nil)
            }
        case "setLooping":
            guard let args = call.arguments as? [String: Any],
                  let loop = args["loop"] as? Bool
            else {
                result(badArgs("setLooping"))
                return
            }
            withInstance(args, result: result) { instance in
                instance.setLooping(loop)
                result(nil)
            }
        case "setVolume":
            guard let args = call.arguments as? [String: Any],
                  let volume = (args["volume"] as? NSNumber)?.floatValue
            else {
                result(badArgs("setVolume"))
                return
            }
            withInstance(args, result: result) { instance in
                instance.setVolume(volume)
                result(nil)
            }
        case "setPlaybackSpeed":
            guard let args = call.arguments as? [String: Any],
                  let rate = (args["rate"] as? NSNumber)?.floatValue
            else {
                result(badArgs("setPlaybackSpeed"))
                return
            }
            withInstance(args, result: result) { instance in
                instance.setPlaybackSpeed(rate)
                result(nil)
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func create(args: Any?, result: @escaping FlutterResult) {
        guard let dict = args as? [String: Any],
              let uri = dict["uri"] as? String,
              let registry = textureRegistry
        else {
            result(badArgs("create"))
            return
        }
        guard let url = URL(string: uri) else {
            result(badArgs("create uri"))
            return
        }
        let handle = nextHandle
        nextHandle += 1
        let instance = UxVideoPlayerInstance(handle: handle, registry: registry)
        instance.onEvent = { [weak self] payload in
            DispatchQueue.main.async {
                self?.eventSink?(payload)
            }
        }
        instance.setSource(url: url)
        instances[handle] = instance
        result(
            [
                "handle": handle,
                "textureId": instance.textureId,
            ] as [String: Any]
        )
    }

    private func withInstance(
        _ args: Any?,
        result: @escaping FlutterResult,
        body: (UxVideoPlayerInstance) -> Void,
    ) {
        guard let dict = args as? [String: Any],
              let handle = (dict["handle"] as? NSNumber)?.intValue
        else {
            result(badArgs("missing handle"))
            return
        }
        guard let instance = instances[handle] else {
            result(
                FlutterError(
                    code: "disposed",
                    message: "no player for handle \(handle)",
                    details: nil,
                )
            )
            return
        }
        body(instance)
    }

    private func badArgs(_ method: String) -> FlutterError {
        FlutterError(code: "bad_args", message: method, details: nil)
    }
}
