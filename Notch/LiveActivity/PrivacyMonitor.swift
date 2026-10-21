import CoreAudio
import CoreMediaIO
import Foundation

/// Watches whether any app is using a microphone or camera. macOS does not say which app,
/// so the banner names the device kind only.
@MainActor
final class PrivacyMonitor {
    private(set) var microphoneInUse = false
    private(set) var cameraInUse = false
    var onChange: ((_ microphone: Bool, _ camera: Bool) -> Void)?

    private var deviceListListener: AudioListener?
    private var audioListeners: [AudioListener] = []
    private var cameraListeners: [CameraListener] = []

    func start() {
        stop()
        deviceListListener = AudioListener(
            object: AudioObjectID(kAudioObjectSystemObject),
            address: AudioDevices.address(kAudioHardwarePropertyDevices)
        ) { [weak self] in
            self?.rebuildListeners()
            self?.refresh()
        }
        rebuildListeners()
        microphoneInUse = Self.readMicrophone()
        cameraInUse = Self.readCamera()
    }

    func stop() {
        deviceListListener = nil
        audioListeners.removeAll()
        cameraListeners.removeAll()
    }

    private func rebuildListeners() {
        audioListeners = AudioDevices.all.filter(AudioDevices.hasInput).compactMap { device in
            AudioListener(object: device, address: AudioDevices.address(kAudioDevicePropertyDeviceIsRunningSomewhere)) { [weak self] in
                self?.refresh()
            }
        }
        cameraListeners = Self.cameraDevices().compactMap { device in
            CameraListener(device: device) { [weak self] in self?.refresh() }
        }
    }

    private func refresh() {
        let microphone = Self.readMicrophone()
        let camera = Self.readCamera()
        guard microphone != microphoneInUse || camera != cameraInUse else { return }
        let turnedOn = (microphone && !microphoneInUse) || (camera && !cameraInUse)
        microphoneInUse = microphone
        cameraInUse = camera
        if turnedOn {
            onChange?(microphone, camera)
        }
    }

    private static func readMicrophone() -> Bool {
        AudioDevices.all.contains { AudioDevices.hasInput($0) && AudioDevices.isRunningSomewhere($0) }
    }

    private static func readCamera() -> Bool {
        cameraDevices().contains { device in
            var address = CameraListener.runningAddress
            var running: UInt32 = 0
            var used: UInt32 = 0
            let status = CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running)
            return status == 0 && running != 0
        }
    }

    private static func cameraDevices() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return [] }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == 0 else { return [] }
        return devices
    }
}

private final class CameraListener {
    static let runningAddress = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )

    private let device: CMIOObjectID
    private var address = CameraListener.runningAddress
    private let token: ListenerToken

    /// Function-pointer API for the same reason as `AudioListener`.
    init?(device: CMIOObjectID, handler: @escaping () -> Void) {
        self.device = device
        token = ListenerToken(handler)
        guard CMIOObjectAddPropertyListener(device, &address, cameraPropertyChanged, token.clientData) == 0 else { return nil }
    }

    deinit {
        CMIOObjectRemovePropertyListener(device, &address, cameraPropertyChanged, token.clientData)
    }
}

private let cameraPropertyChanged: CMIOObjectPropertyListenerProc = { _, _, _, clientData in
    ListenerToken.fire(clientData)
    return 0
}
