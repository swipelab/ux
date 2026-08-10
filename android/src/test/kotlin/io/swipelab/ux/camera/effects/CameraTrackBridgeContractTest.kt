package io.swipelab.ux.camera.effects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** Real processors whose deterministic resources and pools the test can count. */
private class CountingProcessorFactory : CameraEffectProcessorFactory {
    val segmenters = mutableListOf<ScriptedSegmenter>()
    val executors = mutableListOf<ManualExecutor>()
    val pools = mutableListOf<ScriptedBufferPools>()
    val inputPools = mutableListOf<PersonMaskInputPool>()

    override fun makeProcessor(effect: CameraEffect): CameraEffectProcessor {
        val segmenter = ScriptedSegmenter().also { segmenters.add(it) }
        val executor = ManualExecutor().also { executors.add(it) }
        val outputs = ScriptedBufferPools().also { pools.add(it) }
        val inputs = PersonMaskInputPool(
            PersonMaskProducer.INPUT_WIDTH,
            PersonMaskProducer.INPUT_HEIGHT,
            PersonMaskProducer.INPUT_BUFFER_COUNT,
        ).also { inputPools.add(it) }
        return CompositingEffectProcessor(
            CameraEffectCompositor(effect, outputs),
            PersonMaskProducer(segmenter, inputs, TestClock(), executor),
        )
    }
}

class CameraTrackBridgeContractTest {
    private lateinit var bridge: CountingTrackBridge
    private lateinit var factory: CountingProcessorFactory
    private lateinit var service: CameraEffectsService

    @Before
    fun setUp() {
        bridge = CountingTrackBridge()
        factory = CountingProcessorFactory()
        service = CameraEffectsService(
            factory, FakeScheduler(), ImmediateDelivery(), CameraCompositeLog(exposes = false),
        )
        service.install(bridge)
    }

    private fun setEffect(effect: CameraEffect = CameraEffect.BLUR, generation: Int = 1) =
        service.reply(CameraEffectsRequest.SetEffect("t1", effect, generation)) {}

    private fun clear(generation: Int) =
        service.reply(CameraEffectsRequest.Clear(generation)) {}

    @Test
    fun theCoreClosesEveryInputOnceAndTheHostClosesEveryPublicationOnce() {
        setEffect()

        repeat(6) { bridge.deliver() }

        assertEquals(6, bridge.processingCalls)
        assertEquals(6, bridge.inputsConstructed)
        assertEquals(6, bridge.readbacks)
        assertEquals(6, bridge.inputPlaneReleases)
        assertEquals(6, bridge.publicationsReceived)
        assertEquals(0, bridge.publicationsClosed)

        bridge.releasePublications()

        assertEquals(6, bridge.publicationsClosed)
        clear(generation = 2)
        val pool = factory.pools.single().pools.single()
        assertEquals(pool.taken, pool.recycled)
        assertEquals(0, pool.exhausted)
    }

    @Test
    fun theBypassPathBuildsNoFrameAndNeverCallsProcessing() {
        setEffect()
        val unrepresentable = CountingTrackBridge.HostFrame(representable = false)

        bridge.deliver(unrepresentable)

        assertTrue(unrepresentable.publishedUnchanged)
        assertEquals(0, bridge.processingCalls)
        assertEquals(0, bridge.inputsConstructed)
        assertEquals(0, bridge.readbacks)
        assertEquals(0, bridge.publicationsReceived)
        assertTrue(factory.pools.single().pools.isEmpty())
    }

    @Test
    fun cyclesBalanceEveryClaimAndLeaveNoBufferOutstanding() {
        val cycles = 50

        repeat(cycles) { cycle ->
            setEffect(
                effect = if (cycle % 2 == 0) CameraEffect.BLUR else CameraEffect.DIM,
                generation = cycle * 2 + 1,
            )
            bridge.deliver()
            factory.executors.last().runNext()
            bridge.deliver()
            bridge.releasePublications()
            clear(generation = cycle * 2 + 2)
        }

        assertEquals(cycles, factory.segmenters.size)
        for (segmenter in factory.segmenters) assertEquals(1, segmenter.closes)
        for (executor in factory.executors) assertEquals(1, executor.closes)
        for (inputs in factory.inputPools) {
            assertEquals(inputs.taken, inputs.recycled)
            assertEquals(0, inputs.exhausted)
        }
        for (outputs in factory.pools) {
            val pool = outputs.pools.single()
            assertEquals(pool.taken, pool.recycled)
            assertEquals(0, pool.exhausted)
        }
        assertEquals(cycles * 2, bridge.publicationsReceived)
        assertEquals(cycles * 2, bridge.publicationsClosed)
        assertEquals(bridge.readbacks, bridge.inputPlaneReleases)
        assertEquals(0, bridge.outstandingPublications)
        assertEquals(0, bridge.liveRegistrations)
    }

    @Test
    fun attachTakesNoClaimAndTeardownClosesEveryDeterministicResource() {
        setEffect()

        assertEquals(1, bridge.liveRegistrations)
        assertEquals(0, bridge.readbacks)
        assertTrue(factory.pools.single().pools.isEmpty())

        service.teardown()

        assertEquals(1, factory.segmenters.single().closes)
        assertEquals(1, factory.executors.single().closes)
        assertEquals(0, factory.inputPools.single().taken)
        assertEquals(0, bridge.liveRegistrations)
    }
}
