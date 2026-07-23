import CoreBluetooth

public enum SenseCraftVoiceBleUuids {
    public static let clipAtService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    public static let commandRxCharacteristic = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    public static let responseTxCharacteristic = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    public static let fileDataCharacteristic = CBUUID(string: "6E400004-B5A3-F393-E0A9-E50E24DCCA9E")

    public static let batteryService = CBUUID(string: "0000180F-0000-1000-8000-00805F9B34FB")
    public static let batteryLevelCharacteristic = CBUUID(string: "00002A19-0000-1000-8000-00805F9B34FB")
    public static let deviceInfoService = CBUUID(string: "0000180A-0000-1000-8000-00805F9B34FB")

    public static let smpService = CBUUID(string: "00001530-1212-EFDE-1523-785FEABCD123")
    public static let smpCharacteristic = CBUUID(string: "DA2E7828-FBCE-4E01-AE9E-261174997C48")
}

