import AudioToolbox
import CoreAudio
import Foundation

/// Thin reads over the CoreAudio object model.
enum AudioDevices {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static var all: [AudioObjectID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else {
            return []
        }
        return devices
    }

    static var defaultOutput: AudioObjectID? {
        value(of: AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice), as: AudioObjectID.self)
            .flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    static func hasInput(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        (value(of: device, address(kAudioDevicePropertyDeviceIsRunningSomewhere), as: UInt32.self) ?? 0) != 0
    }

    static func name(of device: AudioObjectID) -> String? {
        var address = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    static func isBluetooth(_ device: AudioObjectID) -> Bool {
        let transport = value(of: device, address(kAudioDevicePropertyTransportType), as: UInt32.self)
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// 0…1, or nil for outputs without a main volume control (HDMI, some interfaces).
    static func outputVolume(of device: AudioObjectID) -> Float? {
        value(
            of: device,
            address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput),
            as: Float32.self
        )
    }

    static func isMuted(_ device: AudioObjectID) -> Bool {
        (value(of: device, address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput), as: UInt32.self) ?? 0) != 0
    }

    static func value<T>(of object: AudioObjectID, _ address: AudioObjectPropertyAddress, as type: T.Type) -> T? {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }
}

/// A CoreAudio property listener that removes itself. The handler runs on the main queue.
///
/// Uses the function-pointer API: Swift bridges a closure to a new block on every call, so the
/// block API's remove never matches its add and the listener keeps firing after it is released.
final class AudioListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let token: ListenerToken

    init?(object: AudioObjectID, address: AudioObjectPropertyAddress, handler: @escaping () -> Void) {
        self.object = object
        self.address = address
        token = ListenerToken(handler)
        guard AudioObjectAddPropertyListener(object, &self.address, audioPropertyChanged, token.clientData) == noErr else {
            return nil
        }
    }

    deinit {
        AudioObjectRemovePropertyListener(object, &address, audioPropertyChanged, token.clientData)
    }
}

private let audioPropertyChanged: AudioObjectPropertyListenerProc = { _, _, _, clientData in
    ListenerToken.fire(clientData)
    return noErr
}

/// Carries a listener's handler to the main queue. Callbacks arrive on a framework thread with
/// only this token's number as client data and look the handler up on the main queue, so one
/// that races a removal finds nothing instead of a freed object.
final class ListenerToken {
    private static let lock = NSLock()
    private static var handlers: [UInt: () -> Void] = [:]
    private static var lastID: UInt = 0

    let clientData: UnsafeMutableRawPointer

    init(_ handler: @escaping () -> Void) {
        Self.lock.lock()
        Self.lastID += 1
        let id = Self.lastID
        Self.handlers[id] = handler
        Self.lock.unlock()
        clientData = UnsafeMutableRawPointer(bitPattern: id)!
    }

    deinit {
        Self.lock.lock()
        Self.handlers[UInt(bitPattern: clientData)] = nil
        Self.lock.unlock()
    }

    static func fire(_ clientData: UnsafeMutableRawPointer?) {
        let id = UInt(bitPattern: clientData)
        DispatchQueue.main.async {
            lock.lock()
            let handler = handlers[id]
            lock.unlock()
            handler?()
        }
    }
}
