import AudioToolbox
import CoreAudio
import Foundation

/// UID prefix of FreeAudio's own private aggregate devices (never listed as outputs).
let freeAudioAggregatePrefix = "com.freeaudio.agg."

/// Property addresses FreeAudio reads or listens to.
enum CoreAudioAddress {
    static let devices = PropertyAddress(kAudioHardwarePropertyDevices)
    static let defaultOutputDevice = PropertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
    static let defaultSystemOutputDevice = PropertyAddress(kAudioHardwarePropertyDefaultSystemOutputDevice)
    static let processObjectList = PropertyAddress(kAudioHardwarePropertyProcessObjectList)
    static let processIsRunningOutput = PropertyAddress(kAudioProcessPropertyIsRunningOutput)
    /// Served by the HAL (the AudioHardwareService functions are deprecated); covers devices that
    /// only have per-channel volume controls.
    static let virtualMainVolume = PropertyAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
    static let volumeScalarMain = PropertyAddress(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput)
    static let volumeScalarLeft = PropertyAddress(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: 1)
    static let mute = PropertyAddress(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
}

/// Small additions to the macOS 15+ Swift Core Audio object API.
extension AudioHardwareObject {
    /// Whether the property exists and can be written.
    func isSettable(_ address: AudioObjectPropertyAddress) -> Bool {
        hasProperty(address: address) && ((try? isPropertySettable(address: address)) ?? false)
    }

    func float32(_ address: AudioObjectPropertyAddress) -> Float32? {
        guard hasProperty(address: address),
              let data = try? propertyData(address: address),
              data.count >= MemoryLayout<Float32>.size else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) }
    }

    func setFloat32(_ value: Float32, _ address: AudioObjectPropertyAddress) throws {
        try setPropertyData(address: address, data: withUnsafeBytes(of: value) { Data($0) })
    }

    func uint32(_ address: AudioObjectPropertyAddress) -> UInt32? {
        guard hasProperty(address: address),
              let data = try? propertyData(address: address),
              data.count >= MemoryLayout<UInt32>.size else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    func setUInt32(_ value: UInt32, _ address: AudioObjectPropertyAddress) throws {
        try setPropertyData(address: address, data: withUnsafeBytes(of: value) { Data($0) })
    }
}

/// A Core Audio property listener whose handler runs on the main actor. The listener is removed
/// by `cancel()` or when the object is released.
final class PropertyListener: @unchecked Sendable {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private var isActive = true

    /// Returns nil when the object doesn't support the property (or is already gone).
    init?(object objectID: AudioObjectID, address: AudioObjectPropertyAddress, handler: @escaping @MainActor () -> Void) {
        self.objectID = objectID
        self.address = address
        // @Sendable: Core Audio stores the block and calls it on the queue below (main), so the
        // closure must not inherit the caller's isolation (Swift 6 traps on that otherwise).
        block = { @Sendable _, _ in
            MainActor.assumeIsolated { handler() }
        }
        guard AudioObjectAddPropertyListenerBlock(objectID, &self.address, DispatchQueue.main, block) == noErr else {
            isActive = false
            return nil
        }
    }

    func cancel() {
        guard isActive else { return }
        isActive = false
        // Fails harmlessly (kAudioHardwareBadObjectError) when the object is already gone.
        AudioObjectRemovePropertyListenerBlock(objectID, &address, DispatchQueue.main, block)
    }

    deinit { cancel() }
}
