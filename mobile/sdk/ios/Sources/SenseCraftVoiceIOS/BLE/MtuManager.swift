import CoreBluetooth

public final class MtuManager {
    private unowned let peripheral: CBPeripheral

    public init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
    }

    public var writeWithResponseLimit: Int {
        max(1, peripheral.maximumWriteValueLength(for: .withResponse))
    }

    public var writeWithoutResponseLimit: Int {
        max(1, peripheral.maximumWriteValueLength(for: .withoutResponse))
    }
}

