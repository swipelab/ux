import CoreMotion
import Flutter
import UIKit

@_cdecl("ux_device_orientation")
public func ux_device_orientation() -> Int32 {
    return SensorPlugin.shared?.currentIndex ?? 0
}

public class SensorPlugin: NSObject, NativePlugin {
    fileprivate static var shared: SensorPlugin?
    fileprivate var currentIndex: Int32 = 0

    private let motion = CMMotionManager()

    public func register(with registrar: FlutterPluginRegistrar) {
        SensorPlugin.shared = self
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 10.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self = self, let g = data?.gravity else { return }
            if abs(g.z) > 0.8 { return }
            let next: Int32
            if abs(g.x) > abs(g.y) {
                next = g.x < 0 ? 1 : 3
            } else {
                next = g.y < 0 ? 0 : 2
            }
            if next != self.currentIndex {
                self.currentIndex = next
            }
        }
    }
}
