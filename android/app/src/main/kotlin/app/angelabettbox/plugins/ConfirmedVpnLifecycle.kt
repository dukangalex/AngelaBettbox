package app.angelabettbox.plugins

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

/** Serialises real transitions, never treats dispatch as acknowledgement.
 * A timed-out cleanup quarantines subsequent requests until its exact callback.
 * The driver must retire in-flight work synchronously when stop is dispatched.
 */
class ConfirmedVpnLifecycle(
    private val scope: CoroutineScope,
    private val stop: (completed: () -> Unit) -> Unit,
    private val start: (completed: (Boolean) -> Unit) -> Unit,
    private val stopTimeoutMs: Long = 15_000,
    private val startTimeoutMs: Long = 45_000,
) {
    private val serial = Mutex()
    private val gate = VpnRequestGate()

    fun submit(startRequested: Boolean, result: (Boolean) -> Unit, prepare: () -> Unit = {}) {
        scope.launch {
            serial.withLock {
                val token = gate.begin { result(it == VpnRequestGate.Notice.SUCCEEDED) }
                if (token == null) { result(false); return@withLock }
                val stopGeneration = AtomicLong(0)
                val stopped = AtomicBoolean(false)
                fun uncertain() {
                    gate.timeout(token)
                    if (stopped.get()) gate.confirmedStopped(token)
                }
                suspend fun stopConfirmed(): Boolean {
                    val generation = stopGeneration.incrementAndGet()
                    stopped.set(false)
                    val done = CompletableDeferred<Unit>()
                    stop {
                        if (generation == stopGeneration.get()) {
                            stopped.set(true)
                            done.complete(Unit)
                            // Only this request's exact cleanup releases quarantine.
                            gate.confirmedStopped(token)
                        }
                    }
                    return withTimeoutOrNull(stopTimeoutMs) { done.await(); true } == true
                }
                try {
                    // A new Builder is mandatory for changed Android application lists.
                    if (!stopConfirmed()) {
                        uncertain()
                        return@withLock
                    }
                    if (!startRequested) {
                        gate.finish(token, VpnRequestGate.Completion.SUCCEEDED)
                        return@withLock
                    }
                    prepare()
                    val done = CompletableDeferred<Boolean>()
                    start { done.complete(it) }
                    val started = withTimeoutOrNull(startTimeoutMs) { done.await() }
                    if (started == true) {
                        gate.finish(token, VpnRequestGate.Completion.SUCCEEDED)
                    } else {
                        // Timeout/failed start always retires work and proves teardown
                        // before permitting the next transition, including late success.
                        val cleaned = stopConfirmed()
                        if (cleaned) gate.finish(token, VpnRequestGate.Completion.CLEAN_FAILURE)
                        else uncertain()
                    }
                } catch (_: Exception) {
                    // Never reinterpret an exception as proof of disconnection.
                    val cleaned = runCatching { stopConfirmed() }.getOrDefault(false)
                    if (cleaned) gate.finish(token, VpnRequestGate.Completion.CLEAN_FAILURE)
                    else uncertain()
                }
            }
        }
    }
}
