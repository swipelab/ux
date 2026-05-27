import AppKit
import FlutterMacOS
import UserNotifications

/// `ux/notifications` + `ux/notifications/events`. Generic OS-notification
/// + app-focus surface used by hosts that want native Notification Center
/// entries on macOS. Domain-agnostic — the Dart caller decides when to
/// emit and how to format the payload.
public class NotificationsPlugin: NSObject, NativePlugin, FlutterStreamHandler,
    UNUserNotificationCenterDelegate
{
    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?

    public func register(with registrar: FlutterPluginRegistrar) {
        let methods = FlutterMethodChannel(
            name: "ux/notifications",
            binaryMessenger: registrar.messenger,
        )
        methods.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        methodChannel = methods

        let events = FlutterEventChannel(
            name: "ux/notifications/events",
            binaryMessenger: registrar.messenger,
        )
        events.setStreamHandler(self)
        eventChannel = events

        UNUserNotificationCenter.current().delegate = self
        observeAppActivation()
    }

    // MARK: - FlutterStreamHandler

    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        // Seed the initial focus state so Dart-side starts in a deterministic
        // value rather than the constructor default.
        emit(["type": "focus", "focused": NSApp.isActive])
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    // MARK: - MethodChannel dispatch

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "requestPermission":
            requestPermission(result: result)
        case "show":
            show(args: call.arguments, result: result)
        case "cancelByThread":
            cancelByThread(args: call.arguments, result: result)
        case "cancelAll":
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func requestPermission(result: @escaping FlutterResult) {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { [weak self] granted, error in
            if let error = error {
                NSLog("ux notifications: requestAuthorization error: \(error)")
            }
            DispatchQueue.main.async {
                self?.emit(["type": "authorization", "granted": granted])
                result(granted)
            }
        }
    }

    private func show(args: Any?, result: @escaping FlutterResult) {
        guard let m = args as? [String: Any],
              let id = m["id"] as? String,
              let title = m["title"] as? String,
              let body = m["body"] as? String
        else {
            result(FlutterError(code: "bad_args", message: "show expects id/title/body", details: nil))
            return
        }
        let threadId = m["threadId"] as? String
        let data = m["data"] as? [String: Any] ?? [:]

        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(
                    options: [.alert, .sound, .badge]
                ) { [weak self] granted, _ in
                    DispatchQueue.main.async {
                        self?.emit(["type": "authorization", "granted": granted])
                        if granted {
                            self?.post(id: id, title: title, body: body, threadId: threadId, data: data)
                        }
                        result(nil)
                    }
                }
            case .denied:
                DispatchQueue.main.async {
                    self?.emit(["type": "authorization", "granted": false])
                    result(nil)
                }
            default:
                DispatchQueue.main.async {
                    self?.post(id: id, title: title, body: body, threadId: threadId, data: data)
                    result(nil)
                }
            }
        }
    }

    private func post(
        id: String,
        title: String,
        body: String,
        threadId: String?,
        data: [String: Any]
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let t = threadId { content.threadIdentifier = t }
        content.userInfo = data
        content.sound = .default

        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("ux notifications: add failed: \(error)")
            }
        }
    }

    private func cancelByThread(args: Any?, result: @escaping FlutterResult) {
        guard let m = args as? [String: Any],
              let threadId = m["threadId"] as? String
        else {
            result(FlutterError(code: "bad_args", message: "cancelByThread expects threadId", details: nil))
            return
        }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered
                .filter { $0.request.content.threadIdentifier == threadId }
                .map { $0.request.identifier }
            if !ids.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: ids)
            }
            DispatchQueue.main.async { result(nil) }
        }
    }

    // MARK: - App-activation observers

    private func observeAppActivation() {
        let nc = NotificationCenter.default
        nc.addObserver(
            self,
            selector: #selector(onDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil,
        )
        nc.addObserver(
            self,
            selector: #selector(onDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil,
        )
    }

    @objc private func onDidBecomeActive() {
        emit(["type": "focus", "focused": true])
    }

    @objc private func onDidResignActive() {
        emit(["type": "focus", "focused": false])
    }

    // MARK: - UNUserNotificationCenterDelegate

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void,
    ) {
        // `.alert` is deprecated since macOS 11 and the system only honours
        // it as a banner — entries never reach Notification Center. The
        // 11+ split is `.banner` + `.list`; we need both so the toast
        // shows AND persists in the tray.
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .list, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void,
    ) {
        let data = response.notification.request.content.userInfo
        let payload = stringifiedData(data)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        emit(["type": "tap", "data": payload])
        completionHandler()
    }

    private func stringifiedData(_ raw: [AnyHashable: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in raw {
            out["\(k)"] = "\(v)"
        }
        return out
    }

    // MARK: - Helpers

    private func emit(_ event: [String: Any]) {
        eventSink?(event)
    }
}
