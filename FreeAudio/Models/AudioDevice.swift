import CoreAudio
import Foundation

/// An output device as `DeviceService` lists it. Identified by UID: `AudioObjectID`s change
/// across launches and reconnects.
struct AudioDevice: Identifiable, Equatable, Sendable {
    enum Transport: Sendable {
        case builtIn, usb, bluetooth, hdmi, displayPort, airPlay, thunderbolt, virtual, aggregate, other

        init(_ raw: UInt32) {
            switch raw {
            case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
            case kAudioDeviceTransportTypeUSB: self = .usb
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
            case kAudioDeviceTransportTypeHDMI: self = .hdmi
            case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
            case kAudioDeviceTransportTypeAirPlay: self = .airPlay
            case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
            case kAudioDeviceTransportTypeVirtual: self = .virtual
            case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: self = .aggregate
            default: self = .other
            }
        }
    }

    var id: String { uid }
    let objectID: AudioObjectID
    let uid: String
    let name: String
    let transport: Transport
    /// The device has a settable volume control. Without one (HDMI/DisplayPort monitors),
    /// macOS greys out its volume and FreeAudio will provide software volume (Phase 4).
    let hasHardwareVolume: Bool

    /// SF Symbol for rows and menus.
    var symbolName: String {
        let lowered = name.lowercased()
        switch transport {
        case .builtIn: return lowered.contains("headphone") ? "headphones" : "laptopcomputer"
        case .bluetooth:
            if lowered.contains("airpods max") { return "airpodsmax" }
            if lowered.contains("airpods pro") { return "airpodspro" }
            if lowered.contains("airpods") { return "airpods" }
            if lowered.contains("homepod") { return "homepod.fill" }
            return "headphones"
        case .hdmi, .displayPort, .thunderbolt: return "display"
        case .airPlay: return "airplayaudio"
        case .usb: return "hifispeaker.fill"
        case .virtual, .aggregate: return "waveform"
        case .other: return "speaker.wave.2.fill"
        }
    }
}
