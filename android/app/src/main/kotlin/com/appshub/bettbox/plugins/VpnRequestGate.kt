package com.appshub.bettbox.plugins

/**
 * Request-completion gate used by ConfirmedVpnLifecycle.
 * Android effects are confirmed by the VpnPlugin adapter, not by this gate.
 * An adapter may call SUCCEEDED only after its requested effect is confirmed;
 * CLEAN_FAILURE only after failed-start cleanup is confirmed. Timeout or an
 * unconfirmed failure quarantines the gate until exact-token teardown is confirmed.
 */
class VpnRequestGate {
    enum class Completion { SUCCEEDED, CLEAN_FAILURE, UNCERTAIN }
    enum class Notice { SUCCEEDED, CLEAN_FAILURE, UNCERTAIN }
    data class Snapshot(val token: Long, val quarantined: Boolean)
    private data class Pending(val token: Long, val notify: (Notice) -> Unit, var quarantined: Boolean = false, var notified: Boolean = false)
    private var next = 0L
    private var pending: Pending? = null

    /** Returns null while a request or unresolved cleanup is in progress. */
    @Synchronized fun begin(notify: (Notice) -> Unit): Long? {
        if (pending != null) return null
        val token = ++next
        pending = Pending(token, notify)
        return token
    }

    /** No user callback runs under this gate's monitor. */
    fun finish(token: Long, completion: Completion): Boolean {
        val delivery = synchronized(this) {
            val p = pending ?: return false
            if (p.token != token || p.quarantined || p.notified) return false
            p.notified = true
            val notice = when (completion) {
                Completion.SUCCEEDED -> Notice.SUCCEEDED
                Completion.CLEAN_FAILURE -> Notice.CLEAN_FAILURE
                Completion.UNCERTAIN -> Notice.UNCERTAIN
            }
            if (completion == Completion.UNCERTAIN) p.quarantined = true else pending = null
            p.notify to notice
        }
        delivery.first(delivery.second)
        return true
    }

    /** Timeout is uncertainty, not proof of failure or permission to retry. */
    fun timeout(token: Long): Boolean = finish(token, Completion.UNCERTAIN)

    /** Called only after the adapter confirms teardown for this exact request. */
    @Synchronized fun confirmedStopped(token: Long): Boolean {
        val p = pending ?: return false
        if (p.token != token || !p.quarantined) return false
        pending = null
        return true
    }

    @Synchronized fun snapshot(): Snapshot? = pending?.let { Snapshot(it.token, it.quarantined) }
}
