package io.swipelab.ux.camera

import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry

/// One per [CameraInstance]. CameraX's `ProcessCameraProvider.bindToLifecycle`
/// requires a [LifecycleOwner]; we don't want to tie the camera session
/// to the host `Activity`'s lifecycle (we manage start/stop ourselves
/// to mirror the iOS `CameraSession.start/stop` semantics), so each
/// instance owns its own and we drive STARTED ↔ DESTROYED.
class CustomLifecycleOwner : LifecycleOwner {
    private val registry = LifecycleRegistry(this).apply {
        currentState = Lifecycle.State.INITIALIZED
    }

    override val lifecycle: Lifecycle get() = registry

    /// Move to STARTED — CameraX begins streaming bound use-cases.
    /// Called on Activity onResume / explicit camera start.
    fun start() {
        if (registry.currentState != Lifecycle.State.DESTROYED) {
            registry.currentState = Lifecycle.State.STARTED
        }
    }

    /// Move back to CREATED — CameraX stops streaming but keeps bindings
    /// (cheap restart).
    fun stop() {
        if (registry.currentState != Lifecycle.State.DESTROYED &&
            registry.currentState.isAtLeast(Lifecycle.State.CREATED)) {
            registry.currentState = Lifecycle.State.CREATED
        }
    }

    /// Terminal — unbinds everything CameraX bound against us. Idempotent.
    fun destroy() {
        if (registry.currentState != Lifecycle.State.DESTROYED) {
            registry.currentState = Lifecycle.State.DESTROYED
        }
    }
}
