package io.swipelab.ux.camera.effects

import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.segmentation.Segmentation
import com.google.mlkit.vision.segmentation.selfie.SelfieSegmenterOptions

/** [PersonSegmenting] over ML Kit's selfie segmentation. */
class MlKitPersonSegmenter : PersonSegmenting {
    override val quality = PersonMaskQuality.STREAM

    /**
     * One client across every inference: it holds the loaded model, and a
     * fresh one loads it again.
     */
    private val client = Segmentation.getClient(
        SelfieSegmenterOptions.Builder()
            .setDetectorMode(SelfieSegmenterOptions.STREAM_MODE)
            .build()
    )

    override fun submit(
        input: PersonMaskInput,
        completion: (Result<PersonMaskPixels>) -> Unit,
    ) {
        val image = InputImage.fromByteBuffer(
            input.nv21,
            input.width,
            input.height,
            0,
            InputImage.IMAGE_FORMAT_NV21,
        )
        completion(
            runCatching {
                val mask = Tasks.await(client.process(image))
                PersonMaskPixels(
                    width = mask.width,
                    height = mask.height,
                    confidence = mask.buffer.asFloatBuffer(),
                )
            }
        )
    }

    fun close() = client.close()
}
