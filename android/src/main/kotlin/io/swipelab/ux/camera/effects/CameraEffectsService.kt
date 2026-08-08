package io.swipelab.ux.camera.effects

import java.util.concurrent.locks.ReentrantLock

/**
 * Serves `ux/camera_effects`: one effected track at a time, commands one at a
 * time, and the status the event channel reports.
 *
 * Every Flutter-facing continuation — the status observer and a withheld
 * command completion, which resolves from a callback arriving on the bridge's
 * capture thread — leaves through [delivery], so the plugin above marshals
 * nothing.
 *
 * A `null` [processors] is a host below the capability's floor.
 */
class CameraEffectsService(
    private val processors: CameraEffectProcessorFactory?,
    private val scheduler: CameraEffectsScheduling,
    private val delivery: CameraEffectsDelivering,
) {
    companion object {
        /**
         * The window an attach has to see its first frame, and the window
         * `applying` has — from that frame, or from an accepted same-track
         * switch — to see a composited output.
         */
        const val COMMAND_DEADLINE_MILLIS = 750L
    }

    private val lock = ReentrantLock()
    private var bridge: CameraTrackBridging? = null
    private var attached: Attached? = null
    private var withheld: Withheld? = null
    private var observer: ((CameraEffectStatus) -> Unit)? = null
    private var status = CameraEffectStatus.idle(generation = 0)
    private var lastGeneration = 0
    private var serving = false
    private val queued = ArrayDeque<Pair<Command, CameraEffectsCompletion>>()

    val isBridgeInstalled: Boolean
        get() {
            lock.lock()
            try {
                return bridge != null
            } finally {
                lock.unlock()
            }
        }

    /**
     * A live attachment is detached through the outgoing bridge, which owns
     * its registration, before the new bridge is stored.
     */
    fun install(bridge: CameraTrackBridging) {
        lock.lock()
        val outgoing = this.bridge
        val record = attached
        val handle = record?.handle
        val applying = record?.applyingDeadline
        record?.applyingDeadline = null
        record?.handle = null
        attached = null
        lock.unlock()

        applying?.cancel()
        if (handle != null && outgoing != null) outgoing.detach(handle)
        record?.currentProcessor()?.retire()

        lock.lock()
        this.bridge = bridge
        lock.unlock()
    }

    /**
     * Drops the bridge. A live attachment is detached through it, then the
     * bridge is told to release the rest, and the attachment is reported once
     * as a failure; a withheld reply resolves immediately rather than waiting
     * out its deadline.
     */
    fun uninstall() {
        lock.lock()
        val outgoing = bridge
        bridge = null
        val record = attached
        val handle = record?.handle
        val applying = record?.applyingDeadline
        record?.applyingDeadline = null
        record?.handle = null
        val pending = withheld
        attached = null
        withheld = null
        val observer = this.observer
        val event: CameraEffectStatus? = when {
            pending != null -> CameraEffectStatus.idle(lastGeneration)
            record != null -> CameraEffectStatus.failed(
                record.effect,
                lastGeneration,
                CameraEffectsFailure.integrationUnavailable.code,
            )
            else -> null
        }
        if (event != null) status = event
        lock.unlock()

        pending?.deadline?.cancel()
        applying?.cancel()
        if (outgoing != null && record != null) {
            if (handle != null) outgoing.detach(handle)
            outgoing.teardown()
        }
        record?.currentProcessor()?.retire()
        if (event != null) emit(event, observer)
        if (pending != null) {
            finish(
                CameraEffectsReply.Failure(CameraEffectsFailure.integrationUnavailable),
                pending.completion,
            )
        }
    }

    val currentStatus: CameraEffectStatus
        get() {
            lock.lock()
            try {
                return status
            } finally {
                lock.unlock()
            }
        }

    fun setStatusObserver(observer: ((CameraEffectStatus) -> Unit)?) {
        lock.lock()
        this.observer = observer
        lock.unlock()
    }

    fun reply(request: CameraEffectsRequest, completion: CameraEffectsCompletion) {
        when (request) {
            is CameraEffectsRequest.Available -> {
                lock.lock()
                val capable = bridge != null && processors != null
                lock.unlock()
                delivery.deliver { completion(CameraEffectsReply.Flag(capable)) }
            }

            is CameraEffectsRequest.SetEffect -> serve(
                Command.SetEffect(request.trackId, request.effect, request.generation),
                completion,
            )

            is CameraEffectsRequest.Clear ->
                serve(Command.Clear(request.generation), completion)
        }
    }

    /** Detaches, clears the observer and releases the handle. */
    fun teardown() {
        lock.lock()
        observer = null
        val record = attached
        val handle = record?.handle
        val applying = record?.applyingDeadline
        record?.applyingDeadline = null
        val pending = withheld
        val bridge = this.bridge
        attached = null
        withheld = null
        queued.clear()
        serving = false
        lock.unlock()

        pending?.deadline?.cancel()
        applying?.cancel()
        if (handle != null && bridge != null) bridge.detach(handle)
        record?.currentProcessor()?.retire()
        if (pending != null) {
            delivery.deliver {
                pending.completion(
                    CameraEffectsReply.Failure(CameraEffectsFailure.integrationUnavailable)
                )
            }
        }
    }

    private sealed interface Command {
        data class SetEffect(
            val trackId: String,
            val effect: CameraEffect,
            val generation: Int,
        ) : Command

        data class Clear(val generation: Int) : Command
    }

    private fun serve(command: Command, completion: CameraEffectsCompletion) {
        lock.lock()
        if (serving) {
            queued.addLast(command to completion)
            lock.unlock()
            return
        }
        serving = true
        lock.unlock()
        run(command, completion)
    }

    private fun run(command: Command, completion: CameraEffectsCompletion) {
        when (command) {
            is Command.SetEffect ->
                setEffect(command.trackId, command.effect, command.generation, completion)

            is Command.Clear -> clear(command.generation, completion)
        }
    }

    private fun finish(reply: CameraEffectsReply, completion: CameraEffectsCompletion) {
        delivery.deliver { completion(reply) }
        lock.lock()
        if (queued.isEmpty()) {
            serving = false
            lock.unlock()
            return
        }
        val next = queued.removeFirst()
        lock.unlock()
        run(next.first, next.second)
    }

    private fun setEffect(
        trackId: String,
        effect: CameraEffect,
        generation: Int,
        completion: CameraEffectsCompletion,
    ) {
        lock.lock()
        lastGeneration = generation
        lock.unlock()

        if (processors == null) {
            return finish(
                CameraEffectsReply.Failure(CameraEffectsFailure.unsupported), completion
            )
        }
        val processor: CameraEffectProcessor = try {
            processors.makeProcessor(effect)
        } catch (_: Exception) {
            return finish(
                CameraEffectsReply.Failure(CameraEffectsFailure.initializationFailed),
                completion,
            )
        }

        lock.lock()
        val bridge = this.bridge
        if (bridge == null) {
            lock.unlock()
            return finish(
                CameraEffectsReply.Failure(CameraEffectsFailure.integrationUnavailable),
                completion,
            )
        }
        val observer = this.observer
        val applying = CameraEffectStatus.applying(effect, generation)
        status = applying

        val current = attached
        if (current != null && current.trackId == trackId) {
            current.effect = effect
            current.activated = false
            current.failed = false
            val outgoing = current.adopt(processor)
            armApplyingDeadline(current)
            lock.unlock()
            outgoing.retire()
            emit(applying, observer)
            return finish(CameraEffectsReply.Done, completion)
        }

        val previous = attached
        val previousDeadline = previous?.applyingDeadline
        previous?.applyingDeadline = null
        val record = Attached(trackId, effect, processor)
        attached = record
        val deadline = scheduler.schedule(COMMAND_DEADLINE_MILLIS) {
            deadlineElapsed(record)
        }
        withheld = Withheld(record, deadline, completion)
        lock.unlock()

        emit(applying, observer)
        previousDeadline?.cancel()
        if (previous != null) {
            previous.handle?.let { bridge.detach(it) }
            previous.currentProcessor().retire()
        }

        try {
            val handle = bridge.attach(trackId) { frame ->
                callbackEntered(record)
                val outcome = record.process(frame)
                frameProcessed(record, outcome)
                outcome.frame
            }
            lock.lock()
            if (attached === record) record.handle = handle
            lock.unlock()
        } catch (e: Exception) {
            attachFailed(record, failureFor(e))
        }
    }

    private fun failureFor(e: Exception): CameraEffectsFailure =
        if (e is CameraTrackAttachException && e.unknownTrack) {
            CameraEffectsFailure.trackNotFound
        } else {
            CameraEffectsFailure.initializationFailed
        }

    /** Retracts a command that emitted `applying` and left nothing attached. */
    private fun attachFailed(record: Attached, failure: CameraEffectsFailure) {
        lock.lock()
        val pending = withheld
        if (pending == null || pending.record !== record) {
            lock.unlock()
            return
        }
        withheld = null
        if (attached === record) attached = null
        val idle = CameraEffectStatus.idle(lastGeneration)
        status = idle
        val observer = this.observer
        lock.unlock()

        pending.deadline.cancel()
        record.currentProcessor().retire()
        emit(idle, observer)
        finish(CameraEffectsReply.Failure(failure), pending.completion)
    }

    private fun deadlineElapsed(record: Attached) {
        lock.lock()
        val pending = withheld
        if (pending == null || pending.record !== record) {
            lock.unlock()
            return
        }
        withheld = null
        if (attached === record) attached = null
        val handle = record.handle
        val bridge = this.bridge
        val idle = CameraEffectStatus.idle(lastGeneration)
        status = idle
        val observer = this.observer
        lock.unlock()

        if (handle != null && bridge != null) bridge.detach(handle)
        record.currentProcessor().retire()
        emit(idle, observer)
        finish(
            CameraEffectsReply.Failure(CameraEffectsFailure.trackNotProcessable),
            pending.completion,
        )
    }

    /**
     * The first frame on an attachment: the attach guard is satisfied and
     * the withheld reply resolves, while activation waits for a composited
     * output under the applying deadline armed here.
     */
    private fun callbackEntered(record: Attached) {
        lock.lock()
        if (attached !== record || record.entered) {
            lock.unlock()
            return
        }
        record.entered = true
        var pending = withheld
        if (pending?.record === record) {
            withheld = null
        } else {
            pending = null
        }
        armApplyingDeadline(record)
        lock.unlock()

        pending?.deadline?.cancel()
        if (pending != null) finish(CameraEffectsReply.Done, pending.completion)
    }

    /**
     * Bounds applying→active. The deadline carries the processor whose
     * composite must resolve it, so one armed for a retired processor cannot
     * tear down its successor's command on the same record.
     */
    private fun armApplyingDeadline(record: Attached) {
        record.applyingDeadline?.cancel()
        val processor = record.currentProcessor()
        record.applyingDeadline = scheduler.schedule(COMMAND_DEADLINE_MILLIS) {
            applyingElapsed(record, processor)
        }
    }

    /**
     * The applying deadline expired with no composited output: the processor
     * is detached — so the track stops publishing substitutes — before idle
     * is emitted. No effect was ever active, so no failure code fits.
     */
    private fun applyingElapsed(record: Attached, processor: CameraEffectProcessor) {
        lock.lock()
        if (attached !== record || !record.holds(processor) || record.activated) {
            lock.unlock()
            return
        }
        attached = null
        val handle = record.handle
        record.handle = null
        val bridge = this.bridge
        val idle = CameraEffectStatus.idle(lastGeneration)
        status = idle
        val observer = this.observer
        lock.unlock()

        if (handle != null && bridge != null) bridge.detach(handle)
        processor.retire()
        emit(idle, observer)
    }

    private fun frameProcessed(record: Attached, outcome: CameraFrameOutcome) {
        lock.lock()
        if (attached !== record || !record.holds(outcome.processor)) {
            lock.unlock()
            return
        }
        when (outcome.outcome) {
            is CompositeOutcome.Composited -> {
                if (record.activated) {
                    lock.unlock()
                    return
                }
                record.activated = true
                val deadline = record.applyingDeadline
                record.applyingDeadline = null
                val active = CameraEffectStatus.active(record.effect, lastGeneration)
                status = active
                val observer = this.observer
                lock.unlock()

                deadline?.cancel()
                emit(active, observer)
            }

            is CompositeOutcome.Substituted -> {
                if (!record.activated || record.failed) {
                    lock.unlock()
                    return
                }
                record.failed = true
                val failed = CameraEffectStatus.failed(
                    record.effect,
                    lastGeneration,
                    CameraEffectStatusCode.PROCESSING_FAILED,
                )
                status = failed
                val observer = this.observer
                lock.unlock()

                emit(failed, observer)
            }
        }
    }

    private fun clear(generation: Int, completion: CameraEffectsCompletion) {
        lock.lock()
        lastGeneration = generation
        val record = attached
        val handle = record?.handle
        val applying = record?.applyingDeadline
        record?.applyingDeadline = null
        attached = null
        status = CameraEffectStatus.idle(generation)
        val bridge = this.bridge
        lock.unlock()

        applying?.cancel()
        if (handle != null && bridge != null) bridge.detach(handle)
        record?.currentProcessor()?.retire()
        finish(CameraEffectsReply.Done, completion)
    }

    private fun emit(status: CameraEffectStatus, observer: ((CameraEffectStatus) -> Unit)?) {
        if (observer == null) return
        delivery.deliver { observer(status) }
    }

    private class Withheld(
        val record: Attached,
        val deadline: CameraEffectsScheduledWork,
        val completion: CameraEffectsCompletion,
    )

    /**
     * One track holding one processing callback. `effect`, `entered`,
     * `activated`, `failed`, `handle` and `applyingDeadline` are guarded by
     * the service's lock; the processor by this object's, which is the only
     * lock the capture thread takes.
     */
    private class Attached(
        val trackId: String,
        var effect: CameraEffect,
        processor: CameraEffectProcessor,
    ) {
        var entered = false
        var activated = false
        var failed = false
        var handle: CameraTrackAttachment? = null
        var applyingDeadline: CameraEffectsScheduledWork? = null

        private val processorLock = ReentrantLock()
        private var processor: CameraEffectProcessor = processor

        fun adopt(processor: CameraEffectProcessor): CameraEffectProcessor {
            processorLock.lock()
            val outgoing = this.processor
            this.processor = processor
            processorLock.unlock()
            return outgoing
        }

        fun holds(processor: CameraEffectProcessor): Boolean {
            processorLock.lock()
            try {
                return this.processor === processor
            } finally {
                processorLock.unlock()
            }
        }

        fun currentProcessor(): CameraEffectProcessor {
            processorLock.lock()
            try {
                return processor
            } finally {
                processorLock.unlock()
            }
        }

        fun process(frame: CameraFrame): CameraFrameOutcome {
            processorLock.lock()
            val processor = this.processor
            processorLock.unlock()
            return processor.process(frame)
        }
    }
}

typealias CameraEffectsCompletion = (CameraEffectsReply) -> Unit
