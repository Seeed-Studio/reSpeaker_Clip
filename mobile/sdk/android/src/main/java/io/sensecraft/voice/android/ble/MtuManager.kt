package io.sensecraft.voice.android

import android.bluetooth.BluetoothGatt
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

class MtuManager(private val gatt: BluetoothGatt) {
    private val _mtu = MutableStateFlow(23)
    val mtu = _mtu.asStateFlow()

    fun onMtuChanged(mtu: Int) {
        _mtu.value = mtu.coerceAtLeast(23)
    }

    fun writePayloadSize(withResponse: Boolean = true): Int {
        val max = (_mtu.value - 3).coerceAtLeast(1)
        return if (withResponse) max.coerceAtMost(512) else max
    }

    fun requestHighMtu(desired: Int = 247): Boolean = gatt.requestMtu(desired)
}

