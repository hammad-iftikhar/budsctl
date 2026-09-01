import Foundation

public enum BudsCtl {
    public static let teamID = "JCXZ7458UT"
    public static let appBundleID = "com.hammadiftikhar.budsctl"
    public static let extensionBundleID = "com.hammadiftikhar.budsctl.controls"
    public static let appGroupID = "JCXZ7458UT.com.hammadiftikhar.budsctl"

    /// Darwin notification the extension posts to nudge the agent. Carries no
    /// payload and coalesces — the App Group defaults write is the real channel.
    public static let requestNotification = "com.hammadiftikhar.budsctl.request"

    /// Firmware this protocol was reverse engineered against.
    public static let knownGoodFirmware = "v0.2.1"
}

public enum ControlKind {
    public static let cycle = "com.hammadiftikhar.budsctl.control.cycle"
}

public enum GaiaUUIDs {
    public static let service = "00001100-D102-11E1-9B23-00025B00A5A5"
    public static let command = "00001101-D102-11E1-9B23-00025B00A5A5"
    public static let response = "00001102-D102-11E1-9B23-00025B00A5A5"
    public static let data = "00001103-D102-11E1-9B23-00025B00A5A5"

    /// Standard battery service. Not used for readings — the GAIA getters are
    /// explicitly per-side — but it widens the "connected devices" lookup in
    /// settings to buds that do not advertise the GAIA service.
    public static let batteryService = "180F"
}
