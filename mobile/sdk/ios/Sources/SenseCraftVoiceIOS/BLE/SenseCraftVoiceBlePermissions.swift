import Foundation

public enum SenseCraftVoiceBlePermissions {
    public static func ensureGranted() async -> Bool {
        true
    }

    public static func requiredInfoPlistKeys() -> [String] {
        ["NSBluetoothAlwaysUsageDescription"]
    }
}
