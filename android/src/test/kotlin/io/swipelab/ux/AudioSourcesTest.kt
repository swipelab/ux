package io.swipelab.ux

import android.media.AudioDeviceInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioSourcesTest {
    private val inputs = listOf(
        AudioInput(3, "Built-in microphone"),
        AudioInput(7, "Bluetooth (Jabra Talk)"),
    )

    @Test
    fun listsMicrophonesInPlatformOrderAheadOfPlayback() {
        assertEquals(
            listOf(
                mapOf(
                    "id" to "mic:3",
                    "label" to "Built-in microphone",
                    "kind" to "microphone",
                ),
                mapOf(
                    "id" to "mic:7",
                    "label" to "Bluetooth (Jabra Talk)",
                    "kind" to "microphone",
                ),
                mapOf(
                    "id" to "playback",
                    "label" to "Device playback",
                    "kind" to "playback",
                ),
            ),
            AudioSources.wire(inputs, playbackReady = true),
        )
    }

    @Test
    fun aHostWithoutPlaybackCaptureListsMicrophonesAlone() {
        assertEquals(
            listOf("mic:3", "mic:7"),
            AudioSources.wire(inputs, playbackReady = false).map { it["id"] },
        )
        assertEquals(
            AudioSelection.Unknown,
            AudioSources.select("playback", inputs, playbackReady = false),
        )
    }

    @Test
    fun noSourceIdSelectsTheDefaultInput() {
        assertEquals(
            AudioSelection.DefaultInput,
            AudioSources.select(null, inputs, playbackReady = true),
        )
    }

    @Test
    fun aMicrophoneIdSelectsThatDevice() {
        assertEquals(
            AudioSelection.Microphone(7),
            AudioSources.select("mic:7", inputs, playbackReady = true),
        )
    }

    @Test
    fun thePlaybackIdSelectsPlayback() {
        assertEquals(
            AudioSelection.Playback,
            AudioSources.select("playback", inputs, playbackReady = true),
        )
    }

    @Test
    fun anIdNamingNothingIsUnknown() {
        assertEquals(
            AudioSelection.Unknown,
            AudioSources.select("mic:99", inputs, playbackReady = true),
        )
        assertEquals(
            AudioSelection.Unknown,
            AudioSources.select("3", inputs, playbackReady = true),
        )
        assertEquals(
            AudioSelection.Unknown,
            AudioSources.select("", inputs, playbackReady = true),
        )
    }

    @Test
    fun onlySpeechInputsAreOffered() {
        assertTrue(AudioSources.isMicrophone(AudioDeviceInfo.TYPE_BUILTIN_MIC))
        assertTrue(AudioSources.isMicrophone(AudioDeviceInfo.TYPE_WIRED_HEADSET))
        assertTrue(AudioSources.isMicrophone(AudioDeviceInfo.TYPE_BLUETOOTH_SCO))
        assertTrue(AudioSources.isMicrophone(AudioDeviceInfo.TYPE_USB_HEADSET))
        assertTrue(AudioSources.isMicrophone(AudioDeviceInfo.TYPE_USB_ACCESSORY))
        assertTrue(AudioSources.isMicrophone(AudioDeviceInfo.TYPE_BLE_HEADSET))
        assertFalse(AudioSources.isMicrophone(AudioDeviceInfo.TYPE_FM_TUNER))
        assertFalse(AudioSources.isMicrophone(AudioDeviceInfo.TYPE_TELEPHONY))
    }

    @Test
    fun aLabelNamesTheKindAndAddsTheProductWhereItDiffers() {
        assertEquals(
            "Built-in microphone",
            AudioSources.label(AudioDeviceInfo.TYPE_BUILTIN_MIC, "  "),
        )
        assertEquals(
            "Bluetooth (Jabra Talk)",
            AudioSources.label(AudioDeviceInfo.TYPE_BLUETOOTH_SCO, "Jabra Talk"),
        )
        assertEquals(
            "Bluetooth (Pixel Buds Pro)",
            AudioSources.label(AudioDeviceInfo.TYPE_BLE_HEADSET, "Pixel Buds Pro"),
        )
        assertEquals(
            "USB audio (Scarlett Solo)",
            AudioSources.label(AudioDeviceInfo.TYPE_USB_DEVICE, "Scarlett Solo"),
        )
        assertEquals(
            "USB audio (Zoom H6)",
            AudioSources.label(AudioDeviceInfo.TYPE_USB_ACCESSORY, "Zoom H6"),
        )
        assertEquals(
            "Microphone",
            AudioSources.label(AudioDeviceInfo.TYPE_FM_TUNER, "Microphone"),
        )
    }
}
