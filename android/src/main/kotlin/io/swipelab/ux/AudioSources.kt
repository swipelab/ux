package io.swipelab.ux

import android.media.AudioDeviceInfo

/// A hardware input, as `AudioManager` enumerates it.
internal data class AudioInput(val deviceId: Int, val label: String)

/// What a `start` call opens.
internal sealed interface AudioSelection {
    data object DefaultInput : AudioSelection

    data class Microphone(val deviceId: Int) : AudioSelection

    data object Playback : AudioSelection

    data object Unknown : AudioSelection
}

/// The sources `ux/audio_capture` offers Dart, and what a `sourceId` from
/// Dart names. The Apple counterpart is `AudioSourceCatalog.swift`.
///
/// A microphone id carries the `AudioDeviceInfo` id, which the platform
/// reassigns per boot — a stale id names nothing and selects
/// [AudioSelection.Unknown].
internal object AudioSources {
    const val PLAYBACK_ID = "playback"
    const val PLAYBACK_LABEL = "Device playback"

    private const val MICROPHONE_PREFIX = "mic:"

    fun idOf(input: AudioInput): String = "$MICROPHONE_PREFIX${input.deviceId}"

    fun wire(
        inputs: List<AudioInput>,
        playbackReady: Boolean,
    ): List<Map<String, String>> {
        val microphones = inputs.map {
            mapOf("id" to idOf(it), "label" to it.label, "kind" to "microphone")
        }
        if (!playbackReady) return microphones
        return microphones + mapOf(
            "id" to PLAYBACK_ID,
            "label" to PLAYBACK_LABEL,
            "kind" to "playback",
        )
    }

    fun select(
        sourceId: String?,
        inputs: List<AudioInput>,
        playbackReady: Boolean,
    ): AudioSelection {
        if (sourceId == null) return AudioSelection.DefaultInput
        if (sourceId == PLAYBACK_ID) {
            return if (playbackReady) AudioSelection.Playback else AudioSelection.Unknown
        }
        val input = inputs.firstOrNull { idOf(it) == sourceId }
            ?: return AudioSelection.Unknown
        return AudioSelection.Microphone(input.deviceId)
    }

    /// Whether a device of [type] is one a capture can read speech from.
    fun isMicrophone(type: Int): Boolean = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_MIC,
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_USB_ACCESSORY,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_BLE_HEADSET,
        -> true

        else -> false
    }

    /// The name a picker shows: the kind Android types the device as, with
    /// the product name it reports where that adds anything.
    fun label(type: Int, productName: String): String {
        val kind = when (type) {
            AudioDeviceInfo.TYPE_BUILTIN_MIC -> "Built-in microphone"
            AudioDeviceInfo.TYPE_WIRED_HEADSET -> "Wired headset"
            AudioDeviceInfo.TYPE_USB_DEVICE,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_USB_ACCESSORY,
            -> "USB audio"

            AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLE_HEADSET -> "Bluetooth"
            else -> "Microphone"
        }
        val product = productName.trim()
        return if (product.isEmpty() || product == kind) kind else "$kind ($product)"
    }
}
