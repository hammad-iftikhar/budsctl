import Foundation
import IOBluetooth
import CoreAudio

/// The classic-Bluetooth half of the radio, which CoreBluetooth cannot see.
///
/// Why this exists: the earbuds advertise their BLE control service only while
/// they are *not* settled into an audio connection. Once they are just playing
/// music they stop advertising entirely — an unfiltered LE scan finds nothing —
/// so a pending `connect` waits for something that never arrives. Dropping the
/// classic link makes them advertise again within a second or two.
///
/// Measured on an Air4 Pro: after the drop, macOS does NOT restore the audio
/// profiles on its own (still gone after 30 s), so `restoreAudio` is not
/// optional politeness — without it the user loses their output device.
///
/// GAIA is also reachable over classic (L2CAP PSM 0xFEFF, service
/// `0000eb04-d102-11e1-9b23-00025b00a5a5`), which would avoid all of this. macOS
/// refuses to open that channel from a third-party process — `kIOReturnError`
/// for both RFCOMM and L2CAP, ad-hoc signed and properly signed with
/// `com.apple.security.device.bluetooth` alike. Do not spend another afternoon
/// on it without new information.
enum ClassicLink {

    /// The paired classic device is matched by name because there is no mapping
    /// from a CoreBluetooth peripheral UUID to a classic Bluetooth address —
    /// they are different namespaces for the same physical earbuds.
    private static func device(named name: String) -> IOBluetoothDevice? {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return nil
        }
        return paired.first { $0.name == name }
    }

    static func isConnected(named name: String) -> Bool {
        device(named: name)?.isConnected() ?? false
    }

    /// Whether these earbuds are the device macOS is currently playing through.
    ///
    /// When they are not, dropping their link costs the user nothing audible,
    /// which is the one case where reconnecting can safely be automatic. There
    /// is deliberately no "is audio playing" check: every CoreAudio running
    /// flag reads `true` permanently for a connected Bluetooth device, whether
    /// or not a sound is playing, so silence cannot be detected.
    static func isCurrentAudioOutput(named name: String) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr
        else { return false }

        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        // `Unmanaged<CFString>?` rather than `CFString`: CoreAudio writes a
        // +1-retained pointer through this buffer, and handing it a variable
        // Swift believes holds a managed object reference is what produces the
        // "may contain an object reference" warning.
        var unmanaged: Unmanaged<CFString>?
        var cfSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &cfSize, &unmanaged) == noErr,
              let deviceName = unmanaged?.takeRetainedValue()
        else { return false }
        return (deviceName as String) == name
    }

    /// Drops the classic link so the earbuds start advertising again. This is
    /// what the Bluetooth menu's "Disconnect" does; nothing is written to the
    /// device and no GAIA command is sent.
    @discardableResult
    static func disconnect(named name: String) -> Bool {
        guard let device = device(named: name), device.isConnected() else { return false }
        return device.closeConnection() == kIOReturnSuccess
    }

    /// Brings the audio profiles back. The ACL link tends to re-establish
    /// itself, but A2DP/HFP do not, so this asks for them explicitly.
    static func restoreAudio(named name: String) {
        guard let device = device(named: name) else { return }
        if !device.isConnected() { _ = device.openConnection() }
        // Logs "is not a hands free device but trying anyways" for buds that
        // present as a headset rather than a handsfree unit. It still brings
        // the profiles back, which is the only thing being asked for here.
        IOBluetoothHandsFreeDevice(device: device, delegate: nil)?.connect()
    }
}
