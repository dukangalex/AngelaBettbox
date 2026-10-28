package com.appshub.bettbox.services

fun main() {
    val ids = mapOf("one" to 100, "alias" to 100, "two" to 200, "three" to 300, "self" to 999)
    fun uid(n:String) = ids[n] ?: error("not installed: $n")
    fun run(i:List<String> = emptyList(), e:List<String> = emptyList(), enabled:Boolean = false,
            allow:Boolean = false, a:List<String> = emptyList(), r:List<String> = emptyList()) =
        PackageRouting.resolve(i,e,enabled,allow,a,r,"self",::uid)
    fun expectFail(f: () -> Any) { check(runCatching(f).isFailure) }
    check(run().mode == PackageRouting.Mode.ALL)
    check(run(i=listOf("one","two")).packages == listOf("one","two"))
    check(run(e=listOf("one"), enabled=true, r=listOf("two")).packages == listOf("one","two"))
    check(run(i=listOf("one","two"), e=listOf("alias")).packages == listOf("two"))
    check(run(i=listOf("one","two"), enabled=true, allow=true, a=listOf("alias","three")).packages == listOf("one"))
    check(run(i=listOf("one","two"), enabled=true, r=listOf("alias")).packages == listOf("two"))
    check(run(enabled=true,allow=true,a=listOf("one")).packages == listOf("one","self"))
    check(run(enabled=true,r=listOf("self","one")).packages == listOf("one"))
    expectFail { run(i=listOf("one"),e=listOf("alias")) }
    expectFail { run(i=listOf("missing")) }
    expectFail { run(e=listOf("missing")) }
    expectFail { run(i=listOf(" ")) }
    expectFail { run(i=listOf("one"),enabled=true,allow=true,a=listOf("two")) }
    expectFail { run(i=listOf("one"),e=listOf("missing")) }
    check(run(i=listOf("one")).packages != run(i=listOf("two")).packages)
    println("15 package-routing assertions passed; includes shared UID, invalid packages, conflicts, and fresh resolution")
}
