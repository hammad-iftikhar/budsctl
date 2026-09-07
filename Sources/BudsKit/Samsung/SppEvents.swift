import Foundation

public extension SppFrame {

    /// The device events this frame carries. Empty for anything this app does
    /// not handle, which is most of what the buds send.
    ///
    /// Offsets are from spec §2.4. Every one of them except the noise control
    /// mode is assigned unconditionally for all models from Buds+ onward; see
    /// `ExtendedStatusNotes` for the exception and what guards it.
    var events: [DeviceEvent] {
        switch id {
        case .noiseControlsUpdate:
            guard let mode = payload.first.flatMap(ANCMode.init(rawValue:)) else { return [] }
            return [.mode(mode)]

        case .acknowledgement:
            // [0] is the message being acked, [1] the value it was set to.
            guard payload.count >= 2,
                  payload[0] == SppMessageID.noiseControls.rawValue,
                  let mode = ANCMode(rawValue: payload[1])
            else { return [] }
            return [.mode(mode)]

        case .statusUpdated:
            // [0] revision, [1] battery L, [2] battery R, [3] coupled,
            // [4] main connection, [5] placement, [6] case battery,
            // [7] charging bitfield.
            guard payload.count > 2 else { return [] }
            return Self.battery(left: payload[1], right: payload[2])

        case .extendedStatusUpdated:
            // Pushed when the channel opens, and the only source of the mode at
            // connect time.
            //
            // The plausibility gate is deliberate: if the batteries are
            // impossible then the offsets are wrong, and byte 12 is not to be
            // trusted either. Cheaper and more honest than showing a misparse.
            guard payload.count > 12,
                  payload[2] <= 100,
                  payload[3] <= 100
            else { return [] }
            var events = Self.battery(left: payload[2], right: payload[3])
            if let mode = ANCMode(rawValue: payload[12]) { events.append(.mode(mode)) }
            return events

        // Sent, never interpreted on receipt.
        case .noiseControls, .managerInfo, .none:
            return []
        }
    }

    /// Both sides, with out-of-range values reported as unknown.
    ///
    /// A reading above 100 means the bud is not reporting — usually because it
    /// is in the case. Showing nothing is more honest than showing a number,
    /// and matches `GaiaFrame.percent` on the BLE side.
    private static func battery(left: UInt8, right: UInt8) -> [DeviceEvent] {
        [
            .batteryLeft(left <= 100 ? Int(left) : nil),
            .batteryRight(right <= 100 ? Int(right) : nil),
        ]
    }
}

/// Why the mode is read from byte 12 of `EXTENDED_STATUS_UPDATED` despite being
/// the least certain thing in this file.
///
/// It is the only offset here inferred from a model-branching parser rather
/// than a stable layout: it sits after byte 10, whose *interpretation* forks on
/// the device's touch-lock generation. The fork changes how that byte is read,
/// not where later fields sit — but that is a reading of GalaxyBudsClient's
/// source, not a capture from hardware.
///
/// It also cannot be avoided. `NOISE_CONTROLS_UPDATE` fires only on a *change*,
/// so without byte 12 the app would sit on "Reading mode…" until the user
/// changed mode by some other means.
///
/// So it is guarded three ways: the value must be one of the three modes this
/// app models, the message's batteries must be plausible, and
/// `budsctl-cli samsung <mac>` exists to confirm it against real hardware. A
/// failed guard leaves `isResolvingMode` true and the UI reading
/// "Reading mode…" — the behaviour `DeviceController.settleMode` argues for at
/// length: never present an untrusted read as a confident selection.
///
/// ponytail: validated, not verified. If a capture ever contradicts byte 12,
/// fix the offset here — nothing else in the app depends on it.
private enum ExtendedStatusNotes {}
