package com.cash.cash

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    // Многие телефоны отбрасывают broadcast-пакеты Wi‑Fi для экономии заряда.
    // Пока приложение на экране, держим multicast-lock, чтобы находить компьютер.
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onStart() {
        super.onStart()
        try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("cash-sync").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (e: Exception) {
            multicastLock = null
        }
    }

    override fun onStop() {
        try {
            multicastLock?.release()
        } catch (e: Exception) {
        }
        multicastLock = null
        super.onStop()
    }
}
