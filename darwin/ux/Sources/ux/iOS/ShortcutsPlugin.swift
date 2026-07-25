#if os(iOS)

import Flutter
import Foundation
import Intents

/// `ux/shortcuts` on iOS: SiriKit donations that make the caller's
/// conversations eligible for the share sheet's suggestion row.
///
/// There is no set to replace the way Android's dynamic shortcuts are — the
/// system keeps every donation and ranks it. So each target is donated as its
/// own `INSendMessageIntent`, tagged with the caller's id as the interaction
/// identifier (a re-donation replaces that conversation rather than stacking a
/// second one behind it) and with this plugin's group identifier, which is what
/// `clear` deletes by.
///
/// `conversationIdentifier` is the caller's id, and it is what the app's share
/// extension reads back off `NSExtensionContext.intent` to know which
/// conversation the user picked. The `category` the Android arm needs has no
/// meaning here and is ignored.
public class ShortcutsPlugin: NSObject, NativePlugin {
    private static let groupIdentifier = "ux.shortcuts.donations"

    private var channel: FlutterMethodChannel?

    public func register(with registrar: FlutterPluginRegistrar) {
        let c = FlutterMethodChannel(name: "ux/shortcuts", binaryMessenger: registrar.messenger())
        c.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        channel = c
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "donate": handleDonate(call, result: result)
        case "clear":  handleClear(result: result)
        default:       result(FlutterMethodNotImplemented)
        }
    }

    private func handleDonate(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard #available(iOS 14.0, *) else { return result(nil) }
        guard let args = call.arguments as? [String: Any],
              let targets = args["targets"] as? [[String: Any]] else {
            return result(FlutterError(code: "bad_args", message: "targets is required", details: nil))
        }
        // Suggestions rank by how recently the conversation was donated, so the
        // caller's order is expressed by donating the tail first.
        for target in targets.reversed() {
            guard let id = target["id"] as? String,
                  let label = target["label"] as? String else { continue }
            let icon = image(atPath: target["iconPath"] as? String)
            interaction(id: id, label: label, icon: icon).donate(completion: nil)
        }
        result(nil)
    }

    private func handleClear(result: @escaping FlutterResult) {
        INInteraction.delete(with: [ShortcutsPlugin.groupIdentifier], completion: nil)
        result(nil)
    }

    @available(iOS 14.0, *)
    private func interaction(id: String, label: String, icon: INImage?) -> INInteraction {
        let recipient = INPerson(
            personHandle: INPersonHandle(value: id, type: .unknown),
            nameComponents: nil,
            displayName: label,
            image: icon,
            contactIdentifier: nil,
            customIdentifier: id
        )
        let intent = INSendMessageIntent(
            recipients: [recipient],
            outgoingMessageType: .outgoingMessageText,
            content: nil,
            speakableGroupName: INSpeakableString(spokenPhrase: label),
            conversationIdentifier: id,
            serviceName: nil,
            sender: nil,
            attachments: nil
        )
        if let icon {
            intent.setImage(icon, forParameterNamed: \.speakableGroupName)
        }
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        interaction.identifier = id
        interaction.groupIdentifier = ShortcutsPlugin.groupIdentifier
        return interaction
    }

    /// The avatar the caller already has on disk. A missing file leaves the
    /// suggestion with the app icon, which is what iOS falls back to.
    private func image(atPath path: String?) -> INImage? {
        guard let path, let data = FileManager.default.contents(atPath: path) else { return nil }
        return INImage(imageData: data)
    }
}

#endif
