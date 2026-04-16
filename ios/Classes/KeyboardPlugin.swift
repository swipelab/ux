import Flutter
import UIKit

// MARK: - FFI interface

public typealias WakeCallback = @convention(c) () -> Void

/// Returns the current keyboard height by reading the presentation layer directly.
/// Called by Dart's persistent frame callback — zero latency.
@_cdecl("ux_keyboard_height")
public func ux_keyboard_height() -> Double {
    guard let plugin = KeyboardPlugin.shared else { return 0 }

    // During interactive pan, we track the offset ourselves
    if plugin.isTracking {
        return max(0, Double(plugin.keyboardFullHeight - plugin.interactiveOffset))
    }

    // During dismiss or snap-back animation, read bounds offset from presentation layer
    // (frame is unaffected by bounds.origin, so the normal path would report full height)
    if plugin.isDismissing || plugin.snapBackAnimator != nil {
        guard let kbView = plugin.keyboardView else { return 0 }
        let boundsY = kbView.layer.presentation()?.bounds.origin.y ?? 0
        return max(0, Double(plugin.keyboardFullHeight + Double(boundsY)))
    }

    // Otherwise read the actual keyboard view position
    guard let kbView = plugin.keyboardView else {
        return Double(plugin.keyboardFullHeight)
    }

    let screenHeight = UIScreen.main.bounds.height
    // presentation() gives the interpolated value during CoreAnimation
    if let presentation = kbView.layer.presentation() {
        return max(0, Double(screenHeight - presentation.frame.origin.y))
    }
    return max(0, Double(screenHeight - kbView.frame.origin.y))
}

/// Returns true when interactive dismiss pan is active.
/// Flutter should stop scrolling the message list.
@_cdecl("ux_is_tracking")
public func ux_is_tracking() -> Int32 {
    return (KeyboardPlugin.shared?.isTracking ?? false) ? 1 : 0
}

/// Returns the system-reported keyboard height (from the last notification).
/// Use this as source of truth for "is keyboard open" state.
@_cdecl("ux_system_keyboard_height")
public func ux_system_keyboard_height() -> Double {
    return Double(KeyboardPlugin.shared?.keyboardFullHeight ?? 0)
}

@_cdecl("ux_register_wake_callback")
public func ux_register_wake_callback(_ cb: @escaping WakeCallback) {
    KeyboardPlugin.shared?.wakeCallback = cb
}

@_cdecl("ux_enable_interactive_dismiss")
public func ux_enable_interactive_dismiss(_ trackingInset: Double) {
    KeyboardPlugin.shared?.enableInteractiveDismiss(trackingInset: CGFloat(trackingInset))
}

@_cdecl("ux_disable_interactive_dismiss")
public func ux_disable_interactive_dismiss() {
    KeyboardPlugin.shared?.disableInteractiveDismiss()
}

/// Animation params — Dart replays the same animation internally.
@_cdecl("ux_keyboard_anim_target")
public func ux_keyboard_anim_target() -> Double {
    return Double(KeyboardPlugin.shared?.animTarget ?? 0)
}

@_cdecl("ux_keyboard_anim_duration")
public func ux_keyboard_anim_duration() -> Double {
    return KeyboardPlugin.shared?.animDuration ?? 0
}

/// Incremented each time a new keyboard animation starts.
/// Dart compares against its own copy to detect new animations.
@_cdecl("ux_keyboard_anim_gen")
public func ux_keyboard_anim_gen() -> Int32 {
    return KeyboardPlugin.shared?.animGeneration ?? 0
}

// MARK: - Plugin

public class KeyboardPlugin: NSObject, FlutterPlugin {
    fileprivate static var shared: KeyboardPlugin?

    fileprivate var wakeCallback: WakeCallback?
    private var isObserving = false
    private var gestureEnabled = false
    private var panRecognizer: UIPanGestureRecognizer?

    // Keyboard state
    fileprivate var keyboardView: UIView?
    fileprivate var keyboardFullHeight: CGFloat = 0
    fileprivate var isTracking = false
    fileprivate var isDismissing = false
    fileprivate var interactiveOffset: CGFloat = 0

    // Pan gesture
    private var keyboardOriginY: CGFloat = 0
    fileprivate var snapBackAnimator: UIViewPropertyAnimator?
    private var dismissAnimator: UIViewPropertyAnimator?
    private var trackingInset: CGFloat = 0

    // Animation params — passed to Dart so it can replay the same animation
    fileprivate var animTarget: CGFloat = 0
    fileprivate var animDuration: Double = 0
    fileprivate var animGeneration: Int32 = 0

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = KeyboardPlugin()
        KeyboardPlugin.shared = instance

        instance.startObserving()
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        result(FlutterMethodNotImplemented)
    }

    /// Wake Dart so it reads the height on its next frame
    private func wake() {
        wakeCallback?()
    }

    // MARK: - Keyboard Notifications

    private func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChange),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
    }

    @objc private func keyboardWillChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        let endFrame = (userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
        let screenHeight = UIScreen.main.bounds.height
        let height = max(0, screenHeight - endFrame.origin.y)

        // If the keyboard is closing while we're tracking (e.g. resignFirstResponder
        // fired from a completed dismiss during a new pan), stop tracking and process
        // the close — otherwise Dart never learns the keyboard went away.
        if isTracking {
            if height == 0 {
                isTracking = false
            } else {
                return
            }
        }

        // Pass animation params to Dart so it can replay the same animation
        let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        animTarget = height
        animDuration = duration
        animGeneration &+= 1

        if height > 0 {
            // Cancel any in-flight dismiss so it doesn't resignFirstResponder
            // after the user has already re-focused.
            if let anim = dismissAnimator {
                anim.stopAnimation(true)
                dismissAnimator = nil
            }
            // Always reset bounds — the dismiss animation (or its completion)
            // may have shifted the keyboard view offscreen.
            isDismissing = false
            keyboardView?.layer.bounds.origin = .zero
            keyboardFullHeight = height
        } else {
            keyboardFullHeight = 0
            isDismissing = false
            // Reset bounds when system confirms keyboard is gone
            keyboardView?.layer.bounds.origin = .zero
        }

        if keyboardView == nil {
            discoverKeyboardView()
        }

        // Wake Dart so it starts the animation
        wake()
    }

    @objc private func keyboardWillShow(_ notification: Notification) {
        discoverKeyboardView()
    }

    // MARK: - Keyboard View Discovery

    private func discoverKeyboardView() {
        keyboardView = nil

        // Private API — same as Telegram (UIKitRuntimeUtils/UIViewController+Navigation.m)
        if let windowClass = NSClassFromString("UIRemoteKeyboardWindow") as? NSObject.Type {
            let sel = NSSelectorFromString("remoteKeyboardWindowForScreen:create:")
            if windowClass.responds(to: sel) {
                if let window = windowClass.perform(sel, with: UIScreen.main, with: false)?.takeUnretainedValue() as? UIWindow {
                    if let found = findKeyboardHostView(in: window) {
                        keyboardView = found
                        return
                    }
                }
            }
        }

        // Fallback: walk visible windows
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                let name = NSStringFromClass(type(of: window))
                let isKB = (name.hasPrefix("UI") && name.hasSuffix("RemoteKeyboardWindow")) ||
                           (name.hasPrefix("UI") && name.hasSuffix("TextEffectsWindow"))
                guard isKB else { continue }
                if let found = findKeyboardHostView(in: window) {
                    keyboardView = found
                    return
                }
            }
        }
    }

    private func findKeyboardHostView(in view: UIView) -> UIView? {
        let name = NSStringFromClass(type(of: view))
        if (name.hasPrefix("UI") && name.hasSuffix("InputSetHostView")) ||
           (name.hasPrefix("UI") && name.hasSuffix("KeyboardItemContainerView")) {
            return view
        }
        for subview in view.subviews {
            if let found = findKeyboardHostView(in: subview) {
                return found
            }
        }
        return nil
    }

    // MARK: - Interactive Dismiss

    fileprivate func enableInteractiveDismiss(trackingInset: CGFloat = 0) {
        self.trackingInset = trackingInset
        guard panRecognizer == nil else {
            gestureEnabled = true
            return
        }
        gestureEnabled = true

        DispatchQueue.main.async { [weak self] in
            self?.setupPanGesture()
        }
    }

    fileprivate func disableInteractiveDismiss() {
        gestureEnabled = false
        if let recognizer = panRecognizer {
            recognizer.view?.removeGestureRecognizer(recognizer)
            panRecognizer = nil
        }
    }

    private func setupPanGesture() {
        var targetView: UIView?

        if let window = UIApplication.shared.delegate?.window ?? nil {
            targetView = window.rootViewController?.view ?? window
        } else {
            for scene in UIApplication.shared.connectedScenes {
                if let ws = scene as? UIWindowScene {
                    for window in ws.windows where window.isKeyWindow {
                        targetView = window.rootViewController?.view ?? window
                        break
                    }
                }
            }
        }

        guard let view = targetView else { return }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.delegate = self
        view.addGestureRecognizer(pan)
        panRecognizer = pan
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard gestureEnabled, let view = gesture.view else { return }

        let location = gesture.location(in: view)
        let screenHeight = UIScreen.main.bounds.height

        switch gesture.state {
        case .began:
            break

        case .changed:
            if !isTracking {
                // Don't start tracking during a dismiss — the keyboard is going away.
                guard dismissAnimator == nil, !isDismissing else { return }
                // Use system keyboard height as source of truth
                guard keyboardFullHeight > 0, keyboardView != nil else { return }

                let keyboardTop = screenHeight - keyboardFullHeight - trackingInset
                guard location.y > keyboardTop else { return }

                snapBackAnimator?.stopAnimation(true)
                snapBackAnimator = nil

                isTracking = true
                interactiveOffset = 0
                keyboardOriginY = location.y

                // Wake Dart so it knows tracking started (for scroll stop)
                wake()
            }

            interactiveOffset = max(0, location.y - keyboardOriginY)

            // Move the keyboard view — same as Telegram's KeyboardManager
            if let kbView = keyboardView {
                kbView.layer.bounds = CGRect(
                    origin: CGPoint(x: 0, y: -interactiveOffset),
                    size: kbView.layer.bounds.size
                )
            }

            // Wake Dart to read the new height
            wake()

        case .ended, .cancelled:
            guard isTracking else { return }
            isTracking = false

            let velocity = gesture.velocity(in: view).y
            let dismissThreshold = keyboardFullHeight * 0.4

            if velocity > 100 || interactiveOffset > dismissThreshold {
                dismissKeyboard()
            } else {
                snapBack()
            }
            interactiveOffset = 0

            // Wake Dart so it knows tracking ended
            wake()

        default:
            break
        }
    }

    private func dismissKeyboard() {
        isDismissing = true
        let fullHeight = keyboardFullHeight

        // Tell Dart to start close animation immediately
        animTarget = 0
        animDuration = 0.25
        animGeneration &+= 1

        // Snapshot the generation so the completion can detect if the keyboard
        // was reopened between now and when the animator finishes.
        let genAtDismiss = animGeneration

        let animator = UIViewPropertyAnimator(duration: 0.25, dampingRatio: 0.9) { [weak self] in
            guard let kbView = self?.keyboardView else { return }
            kbView.layer.bounds = CGRect(
                origin: CGPoint(x: 0, y: -fullHeight),
                size: kbView.layer.bounds.size
            )
        }
        animator.addCompletion { [weak self] _ in
            self?.dismissAnimator = nil
            self?.isDismissing = false
            // Only resign if no new keyboard event arrived since the dismiss started.
            // Otherwise we'd kill a keyboard the user just re-opened.
            guard self?.animGeneration == genAtDismiss else { return }
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        dismissAnimator = animator
        animator.startAnimation()
    }

    private func snapBack() {
        guard let kbView = keyboardView else { return }

        let animator = UIViewPropertyAnimator(duration: 0.25, dampingRatio: 0.9) {
            kbView.layer.bounds = CGRect(
                origin: .zero,
                size: kbView.layer.bounds.size
            )
        }
        snapBackAnimator = animator
        animator.addCompletion { [weak self] _ in
            self?.snapBackAnimator = nil
        }
        animator.startAnimation()
    }

    // MARK: - Warmup

    private static func warmup() {
        let field = UITextField(frame: .zero)
        let window = UIWindow(frame: .zero)
        window.addSubview(field)
        field.becomeFirstResponder()
        field.resignFirstResponder()
        window.isHidden = true
    }
}

// MARK: - UIGestureRecognizerDelegate

extension KeyboardPlugin: UIGestureRecognizerDelegate {
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        return true
    }
}
