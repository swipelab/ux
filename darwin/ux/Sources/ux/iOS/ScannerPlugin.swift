#if os(iOS)

import AVFoundation
import Flutter
import UIKit

public class ScannerPlugin: NSObject, NativePlugin {
    fileprivate static let eventEmitter = ScannerEventEmitter()

    public func register(with registrar: FlutterPluginRegistrar) {
        let factory = ScannerViewFactory(messenger: registrar.messenger())
        registrar.register(factory, withId: "ux/scanner")

        let events = FlutterEventChannel(
            name: "ux/scanner/events",
            binaryMessenger: registrar.messenger(),
        )
        events.setStreamHandler(ScannerPlugin.eventEmitter)

        let methods = FlutterMethodChannel(
            name: "ux/scanner",
            binaryMessenger: registrar.messenger(),
        )
        methods.setMethodCallHandler { call, result in
            switch call.method {
            case "requestPermission":
                ScannerPlugin.requestPermission(result: result)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private static func requestPermission(result: @escaping FlutterResult) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            result(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { result(granted) }
            }
        default:
            result(false)
        }
    }
}

fileprivate class ScannerEventEmitter: NSObject, FlutterStreamHandler {
    private var sink: FlutterEventSink?

    func onListen(withArguments _: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
        sink = eventSink
        return nil
    }

    func onCancel(withArguments _: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    func send(_ code: String) {
        DispatchQueue.main.async { [weak self] in self?.sink?(code) }
    }
}

fileprivate class ScannerViewFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        return ScannerPlatformView(frame: frame, args: args)
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

fileprivate class ScannerPreviewView: UIView {
    let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession, frame: CGRect) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        super.init(frame: frame)
        backgroundColor = .black
        layer.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        if let connection = previewLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }
}

fileprivate class ScannerPlatformView: NSObject, FlutterPlatformView,
    AVCaptureMetadataOutputObjectsDelegate {
    private let containerView: ScannerPreviewView
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "ux.scanner.session")

    init(frame: CGRect, args: Any?) {
        containerView = ScannerPreviewView(session: session, frame: frame)
        super.init()

        sessionQueue.async { [weak self] in
            self?.configureSession(args: args)
        }
    }

    deinit {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func view() -> UIView {
        return containerView
    }

    private func configureSession(args: Any?) {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return
        }
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            return
        }
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            // QR is the only format we support today; the `formats` arg is
            // accepted for forward-compat but ignored.
            _ = args
            output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            output.metadataObjectTypes = [.qr]
        }
        session.commitConfiguration()
        session.startRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        for obj in metadataObjects {
            guard let readable = obj as? AVMetadataMachineReadableCodeObject else { continue }
            guard let value = readable.stringValue, !value.isEmpty else { continue }
            ScannerPlugin.eventEmitter.send(value)
        }
    }
}

#endif
