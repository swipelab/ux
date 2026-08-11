package io.swipelab.ux.camera.effects

import android.content.Context
import android.os.Build
import android.os.PowerManager
import androidx.annotation.RequiresApi

/** The floor a mask producer holds its submission interval to. */
fun interface MaskCadence {
    fun intervalNanos(): Long
}

/**
 * The host's thermal status on [PowerManager]'s ladder, reported as it moves.
 * Injected so a test drives pressure without heat.
 */
interface CameraThermalSource : AutoCloseable {
    fun observe(listener: (Int) -> Unit)
}

/**
 * The mask cadence under thermal pressure. A status at or above
 * [PRESSURE_STATUS] that holds for [SUSTAIN_NANOS] widens the submission
 * interval to [BACKOFF] times the target, and a status below it returns the
 * target. Pressure is timed from when it arrived, so a status that clears and
 * comes back sustains from the new arrival.
 */
class CameraThermalCadence(
    private val clock: CameraEffectsClock = MonotonicClock(),
    private val targetIntervalNanos: Long = PersonMaskProducer.TARGET_SUBMISSION_INTERVAL_NANOS,
) : MaskCadence {
    companion object {
        const val PRESSURE_STATUS = PowerManager.THERMAL_STATUS_LIGHT

        const val SUSTAIN_NANOS = 10_000_000_000L

        const val BACKOFF = 2
    }

    private val lock = Any()

    private var source: CameraThermalSource? = null
    private var pressureSince: Long? = null

    /** Takes the host's status stream, dropping whatever source it held. */
    fun observe(source: CameraThermalSource) {
        val outgoing = synchronized(lock) {
            val previous = this.source
            this.source = source
            previous
        }
        outgoing?.close()
        source.observe(::accept)
    }

    fun stop() {
        val outgoing = synchronized(lock) {
            val previous = source
            source = null
            pressureSince = null
            previous
        }
        outgoing?.close()
    }

    override fun intervalNanos(): Long = synchronized(lock) {
        val since = pressureSince ?: return targetIntervalNanos
        if (clock.nowNanos - since < SUSTAIN_NANOS) {
            targetIntervalNanos
        } else {
            targetIntervalNanos * BACKOFF
        }
    }

    private fun accept(status: Int) = synchronized(lock) {
        when {
            status < PRESSURE_STATUS -> pressureSince = null
            pressureSince == null -> pressureSince = clock.nowNanos
        }
    }
}

/**
 * [PowerManager]'s thermal status. A host below API 29 registers nothing and
 * reports no pressure, so the cadence holds its target there.
 */
class PowerManagerThermalSource(context: Context) : CameraThermalSource {
    private val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager

    private var registered: PowerManager.OnThermalStatusChangedListener? = null

    override fun observe(listener: (Int) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        register(listener)
    }

    override fun close() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        unregister()
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun register(listener: (Int) -> Unit) {
        val changed = PowerManager.OnThermalStatusChangedListener { status -> listener(status) }
        power.addThermalStatusListener(changed)
        registered = changed
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun unregister() {
        val changed = registered ?: return
        registered = null
        power.removeThermalStatusListener(changed)
    }
}
