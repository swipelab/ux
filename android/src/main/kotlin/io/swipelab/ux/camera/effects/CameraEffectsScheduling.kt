package io.swipelab.ux.camera.effects

import android.os.Handler
import android.os.Looper

/** Work scheduled for later, cancellable before it runs. */
interface CameraEffectsScheduledWork {
    fun cancel()
}

/**
 * Runs work after a delay. Injected so a test drives the attach deadline
 * without waiting for it.
 */
interface CameraEffectsScheduling {
    fun schedule(delayMillis: Long, body: () -> Unit): CameraEffectsScheduledWork
}

/**
 * Hands work to Flutter's thread. Injected so a test sees which thread a
 * continuation lands on.
 */
interface CameraEffectsDelivering {
    fun deliver(body: () -> Unit)
}

class MainLooperScheduler : CameraEffectsScheduling {
    private val handler = Handler(Looper.getMainLooper())

    override fun schedule(delayMillis: Long, body: () -> Unit): CameraEffectsScheduledWork {
        val work = Work(body)
        handler.postDelayed(work.runnable, delayMillis)
        return work
    }

    private inner class Work(body: () -> Unit) : CameraEffectsScheduledWork {
        val runnable = Runnable(body)

        override fun cancel() {
            handler.removeCallbacks(runnable)
        }
    }
}

class MainLooperDelivery : CameraEffectsDelivering {
    private val handler = Handler(Looper.getMainLooper())

    override fun deliver(body: () -> Unit) {
        handler.post(body)
    }
}
