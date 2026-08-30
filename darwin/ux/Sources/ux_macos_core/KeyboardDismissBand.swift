/// Class names and the composer-plus-keyboard band for iOS interactive
/// IME dismiss. A touch starts tracking when it sits in that band of
/// the window that owns the pan.
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
}
