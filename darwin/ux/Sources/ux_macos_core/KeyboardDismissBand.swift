/// Class names and start geometry for iOS interactive IME dismiss.
/// A pan on the chat window starts when the finger has travelled down
/// while the IME is up (stream or composer). A pan on the IME window
/// starts when the touch sits in the composer-plus-keyboard band;
/// that recognizer begins only on downward-dominant velocity so
/// swipe-typing does not track.
public enum KeyboardDismissBand {
    public static func isWindowClass(_ name: String) -> Bool {
        (name.hasPrefix("UI") && name.hasSuffix("RemoteKeyboardWindow"))
            || (name.hasPrefix("UI") && name.hasSuffix("TextEffectsWindow"))
    }

    public static func isHostViewClass(_ name: String) -> Bool {
        (name.hasPrefix("UI") && name.hasSuffix("InputSetHostView"))
            || (name.hasPrefix("UI") && name.hasSuffix("KeyboardItemContainerView"))
    }

    public static func contains(
        y: Double,
        windowHeight: Double,
        keyboardHeight: Double,
        trackingInset: Double
    ) -> Bool {
        guard keyboardHeight > 0 else { return false }
        return y > windowHeight - keyboardHeight - trackingInset
    }

    /// True when the pan is downward-dominant, so swipe-typing and
    /// cursor drags on the IME do not begin dismiss tracking.
    public static func beginsDismiss(velocityX: Double, velocityY: Double) -> Bool {
        velocityY > 0 && velocityY > abs(velocityX)
    }

    public static func isDownwardTravel(_ translationY: Double) -> Bool {
        translationY > 0
    }
}
