package cn.youzifeile.chirp.data

import android.os.SystemClock

// Protocol and UI fixtures control the time source without depending on public UDP access.
internal fun synchronizedTestClock() = NetworkClock {
    listOf(NetworkTimeSample(System.currentTimeMillis(), SystemClock.elapsedRealtime(), 0))
}
