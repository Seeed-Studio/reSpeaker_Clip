package io.sensecraft.voice.android

import java.util.UUID

object SenseCraftVoiceBleUuids {
    val clipAtService: UUID = UUID.fromString("6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    val commandRxCharacteristic: UUID = UUID.fromString("6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    val responseTxCharacteristic: UUID = UUID.fromString("6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    val fileDataCharacteristic: UUID = UUID.fromString("6E400004-B5A3-F393-E0A9-E50E24DCCA9E")

    val batteryService: UUID = UUID.fromString("0000180F-0000-1000-8000-00805F9B34FB")
    val batteryLevelCharacteristic: UUID = UUID.fromString("00002A19-0000-1000-8000-00805F9B34FB")
    val deviceInfoService: UUID = UUID.fromString("0000180A-0000-1000-8000-00805F9B34FB")

    val smpService: UUID = UUID.fromString("00001530-1212-EFDE-1523-785FEABCD123")
    val smpCharacteristic: UUID = UUID.fromString("DA2E7828-FBCE-4E01-AE9E-261174997C48")

    val cccd: UUID = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB")
}

