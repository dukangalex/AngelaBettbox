package com.appshub.bettbox.services

/** Builds the intersection of subscription routing and application access control.
 * Both inputs operate on Android UIDs: packages with a shared UID travel together.
 * Explicit but empty results fail instead of becoming Android's default (all apps).
 */
internal object PackageRouting {
    enum class Mode { ALL, ALLOW, DENY }
    data class Selection(val mode: Mode, val packages: List<String>)

    fun resolve(
        include: List<String>, exclude: List<String>, aclEnabled: Boolean,
        aclAllow: Boolean, accept: List<String>, reject: List<String>, ownPackage: String,
        uidOf: (String) -> Int,
    ): Selection {
        fun resolveList(items: List<String>): Map<Int, String> {
            val result = linkedMapOf<Int, String>()
            items.forEach { name ->
                require(name.isNotBlank() && name == name.trim()) { "Invalid package name" }
                result.putIfAbsent(uidOf(name), name)
            }
            return result
        }
        // Resolve every active entry, including entries later excluded by a conflict.
        val inc = resolveList(include)
        val exc = resolveList(exclude)
        val acl = if (!aclEnabled) emptyMap() else if (aclAllow) {
            resolveList(accept + ownPackage)
        } else {
            resolveList(reject.filter { it != ownPackage })
        }
        val hasInclude = include.isNotEmpty()
        val hasAclAllow = aclEnabled && aclAllow
        val denied = exc.keys + if (aclEnabled && !aclAllow) acl.keys else emptySet()
        if (hasInclude || hasAclAllow) {
            val candidates = if (hasInclude) inc else acl
            val allowed = candidates.filterKeys { uid ->
                (!hasAclAllow || acl.containsKey(uid)) && !denied.contains(uid)
            }
            require(allowed.isNotEmpty()) { "Package policies yield an empty allowlist" }
            return Selection(Mode.ALLOW, allowed.values.toList())
        }
        val deniedApps = linkedMapOf<Int, String>().apply {
            putAll(exc)
            if (aclEnabled && !aclAllow) putAll(acl)
        }
        return if (deniedApps.isEmpty()) Selection(Mode.ALL, emptyList())
            else Selection(Mode.DENY, deniedApps.values.toList())
    }
}
