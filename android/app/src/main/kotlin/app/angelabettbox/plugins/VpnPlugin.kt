package app.angelabettbox.plugins

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.IBinder
import android.widget.Toast
import androidx.core.content.getSystemService
import app.angelabettbox.AngelaMihomoApplication
import app.angelabettbox.GlobalState
import app.angelabettbox.RunState
import app.angelabettbox.core.Core
import app.angelabettbox.extensions.awaitResult
import app.angelabettbox.extensions.asSocketAddressText
import app.angelabettbox.extensions.resolveDns
import app.angelabettbox.models.StartForegroundParams
import app.angelabettbox.models.VpnOptions
import app.angelabettbox.modules.SuspendModule
import app.angelabettbox.services.BaseServiceInterface
import app.angelabettbox.services.AngelaMihomoService
import app.angelabettbox.services.AngelaMihomoVpnService
import com.google.gson.Gson
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock as withSuspendLock
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import java.util.Collections
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.withLock

data object VpnPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    @Volatile
    private var bettBoxService: BaseServiceInterface? = null
    @Volatile
    private var options: VpnOptions? = null

    // Lock order: lifecycleMutex -> runLock. Never notify, protect, or call native
    // cleanup while holding runLock. A stop retires the epoch before waiting.
    private val lifecycleMutex = Mutex()
    // Teardown confirmation must outlive Flutter engine detachment. This scope
    // only awaits the exact service's destruction; it never opens the native gate.
    private val teardownScope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    private val activeEpoch = AtomicLong(0)
    private val requestSerial = AtomicLong(0)
    private val bindSerial = AtomicLong(0)
    @Volatile private var vpnTeardownComplete = true

    private fun retireLifecycle(): Long = synchronized(activeEpoch) {
        Core.beginTunTransition().also { activeEpoch.set(it) }
    }
    private fun current(epoch: Long) = activeEpoch.get() == epoch


    @Volatile
    private var isBind = false
    @Volatile private var bindingRegistered = false
    private val isBinding = AtomicBoolean(false)

    private var job = SupervisorJob()
    private var scope = CoroutineScope(Dispatchers.Default + job as kotlin.coroutines.CoroutineContext)
    private var lastStartForegroundParams: StartForegroundParams? = null
    private val uidPageNameMap = ConcurrentHashMap<Int, String>()
    private var suspendModule: SuspendModule? = null

    @Volatile
    private var quickResponseEnabled = false
    private var quickResponseJob: Job? = null
    private var lastNetworkType: Int? = null
    private var lastDns = ""

    val networks: MutableSet<Network> = Collections.newSetFromMap(ConcurrentHashMap())

    private val connectivity by lazy {
        AngelaMihomoApplication.getAppContext().getSystemService<ConnectivityManager>()
    }

    private var bindTimeoutJob: Job? = null
    private val attachedMessengers = Collections.newSetFromMap(ConcurrentHashMap<BinaryMessenger, Boolean>())
    private val channelMap = ConcurrentHashMap<BinaryMessenger, MethodChannel>()
    private val activeChannels = CopyOnWriteArrayList<MethodChannel>()
    private val networkCallbackRegistered = AtomicBoolean(false)

    private data class RetiredBinding(val ticket: Long, val epoch: Long, val done: () -> Unit)
    @Volatile private var retiredBinding: RetiredBinding? = null
    @Volatile private var connectionTicket = 0L
    private var connection: ServiceConnection = makeConnection(0)
    private fun makeConnection(ticket: Long) = object : ServiceConnection {
        override fun onServiceConnected(className: ComponentName, service: IBinder) {
            synchronized(activeEpoch) {
                if (ticket != bindSerial.get()) {
                    val retired = retiredBinding?.takeIf { it.ticket == ticket } ?: return
                    val instance = when (service) {
                        is AngelaMihomoVpnService.LocalBinder -> service.getService()
                        is AngelaMihomoService.LocalBinder -> service.getService()
                        else -> return // Unknown identity is never proof of destruction.
                    }
                    cleanupRetiredBinding(retired, instance, this)
                    return
                }
                bindTimeoutJob?.cancel()
                bindTimeoutJob = null
                isBind = true
                isBinding.set(false)
                bettBoxService = when (service) {
                    is AngelaMihomoVpnService.LocalBinder -> service.getService()
                    is AngelaMihomoService.LocalBinder -> service.getService()
                    else -> { completeStart(requestSerial.get(), false); return }
                }
                // A timeout may have completed this request before the binding
                // arrives. Retain its identity for the coordinator's cleanup,
                // but never revive a terminal start request.
                if (!GlobalState.isCurrentlyStopping() && startReply?.serial == requestSerial.get()) handleStartService()
            }
        }

        override fun onNullBinding(name: ComponentName) {
            if (ticket != bindSerial.get()) return
            // Android supplied no attributable instance. Fail this start now;
            // cleanup stays quarantined if exact destruction cannot be proven.
            completeStart(requestSerial.get(), false)
        }

        override fun onBindingDied(name: ComponentName) {
            if (ticket != bindSerial.get()) return
            completeStart(requestSerial.get(), false)
            onServiceDisconnected(name)
        }

        override fun onServiceDisconnected(arg: ComponentName) {
            if (ticket != bindSerial.get()) return
            isBind = false
            isBinding.set(false)
            bettBoxService = null
            val disconnectedEpoch = retireLifecycle()
            vpnTeardownComplete = false
            completeStart(requestSerial.get(), false)
            if (GlobalState.currentRunState == RunState.START) {
                android.util.Log.w("VpnPlugin", "Service unexpectedly disconnected while running, syncing state")
                GlobalState.updateRunState(RunState.STOP)
                ServicePlugin.notifyVpnStartFailed { current(disconnectedEpoch) }
                ServicePlugin.notifyRunStateChanged(RunState.STOP) { current(disconnectedEpoch) }
            }
        }
    }

    // Keep a timed-out pending bind until its exact instance is known. Unbinding
    // before connection would discard the only destruction identity we can await.
    private fun cleanupRetiredBinding(retired: RetiredBinding, instance: BaseServiceInterface, oldConnection: ServiceConnection) {
        val accepted = synchronized(activeEpoch) {
            if (!current(retired.epoch) || retiredBinding !== retired || bettBoxService != null) false
            else { bettBoxService = instance; retiredBinding = null; true }
        }
        if (!accepted) return
        teardownScope.launch {
            var finished = false
            lifecycleMutex.withSuspendLock {
                if (!current(retired.epoch)) return@withSuspendLock
                instance.stop()
                val context = AngelaMihomoApplication.getAppContext()
                withContext(Dispatchers.Main) {
                    runCatching { context.unbindService(oldConnection) }
                    bindingRegistered = false
                    isBind = false
                    context.stopService(Intent(context, if (instance is AngelaMihomoVpnService)
                        AngelaMihomoVpnService::class.java else AngelaMihomoService::class.java))
                }
                if (awaitServiceTeardown(retired.epoch, instance, retired.done)) {
                    finished = finishConfirmedTeardown(retired.epoch, instance)
                }
            }
            if (finished && current(retired.epoch)) retired.done()
        }
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        val isFirstAttach = attachedMessengers.isEmpty()
        attachedMessengers.add(flutterPluginBinding.binaryMessenger)

        if (job.isCancelled) {
            job = SupervisorJob()
            scope = CoroutineScope(Dispatchers.Default + job as kotlin.coroutines.CoroutineContext)
        }

        val channel = MethodChannel(flutterPluginBinding.binaryMessenger, "vpn")
        channel.setMethodCallHandler(this)
        channelMap[flutterPluginBinding.binaryMessenger] = channel
        activeChannels.add(channel)

        if (isFirstAttach) {
            scope.launch { registerNetworkCallback() }
        }

        scope.launch {
            var dns = when {
                lastDns.isNotBlank() -> lastDns
                else -> getCurrentDns()
            }
            if (dns.isBlank()) {
                delay(1000)
                dns = getCurrentDns()
                if (dns.isNotBlank()) lastDns = dns
            }
            withContext(Dispatchers.Main) {
                runCatching {
                    channel.invokeMethod("dnsChanged", dns)
                }
            }
        }

        if (GlobalState.currentRunState == RunState.START && bettBoxService == null) {
            android.util.Log.d("VpnPlugin", "VPN is running but service connection lost, rebinding...")
            options?.let { bindService() }
        }
    }

    override fun onDetachedFromEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        attachedMessengers.remove(flutterPluginBinding.binaryMessenger)
        channelMap.remove(flutterPluginBinding.binaryMessenger)?.let { channel ->
            channel.setMethodCallHandler(null)
            activeChannels.remove(channel)
        }

        if (attachedMessengers.isEmpty()) {
            unRegisterNetworkCallback()
            job.cancel()
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                try {
                    val data = call.argument<String>("data")
                    if (data == null) {
                        result.error("INVALID_ARGUMENT", "data parameter is required", null)
                        return
                    }
                    val vpnOptions = Gson().fromJson(data, VpnOptions::class.java)
                    startConfirmed(vpnOptions) { ok -> teardownScope.launch(Dispatchers.Main) { result.success(ok) } }
                } catch (e: Exception) {
                    android.util.Log.e("VpnPlugin", "Failed to start VPN: ${e.message}")
                    result.error("PARSE_ERROR", "Failed to parse VpnOptions: ${e.message}", null)
                }
            }

            "stop" -> {
                stopConfirmed { ok -> teardownScope.launch(Dispatchers.Main) { result.success(ok) } }
            }

            "getLocalIpAddresses" -> {
                result.success(getLocalIpAddresses())
            }

            "getLocalGateways" -> {
                result.success(getLocalGateways())
            }

            "getCurrentDns" -> {
                result.success(getCurrentDns())
            }

            "setSmartStopped" -> {
                val value = call.argument<Boolean>("value") ?: false
                GlobalState.isSmartStopped = value
                result.success(true)
            }

            "isSmartStopped" -> {
                result.success(GlobalState.isSmartStopped)
            }

            "smartStop" -> {
                stopConfirmed { ok ->
                    if (ok) GlobalState.isSmartStopped = true
                    teardownScope.launch(Dispatchers.Main) { result.success(ok) }
                }
            }

            "smartResume" -> {
                val data = call.argument<String>("data")
                startConfirmed(Gson().fromJson(data, VpnOptions::class.java)) { ok -> teardownScope.launch(Dispatchers.Main) { result.success(ok) } }
            }
            
            "setQuickResponse" -> {
                quickResponseEnabled = call.argument<Boolean>("enabled") ?: false
                result.success(true)
            }

            "updateNotificationSpeed" -> {
                handleUpdateNotificationSpeed(
                    call.argument<String>("profileName") ?: "",
                    call.argument<String>("speedInfo") ?: ""
                )
                result.success(true)
            }

            "status" -> {
                result.success(GlobalState.currentRunState == RunState.START)
            }

            else -> {
                result.notImplemented()
            }
        }
    }
    
    fun setQuickResponse(enabled: Boolean) {
        quickResponseEnabled = enabled
    }

    private fun getActivePhysicalNetworks(): Set<Network> {
        val current = networks
        if (current.isNotEmpty()) return current

        val cm = connectivity ?: return emptySet()
        val isPhysical: (Network) -> Boolean = { net ->
            cm.getNetworkCapabilities(net)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == false
        }

        val available = cm.allNetworks.filter(isPhysical).toSet()
        if (available.isNotEmpty()) return available

        return cm.activeNetwork?.takeIf(isPhysical)?.let { setOf(it) } ?: emptySet()
    }

    fun getLocalIpAddresses(): List<String> = runCatching {
        getActivePhysicalNetworks().flatMap { network ->
            connectivity?.getLinkProperties(network)
                ?.linkAddresses
                ?.mapNotNull { it.address }
                ?.filter { !it.isLoopbackAddress && it.hostAddress?.contains(":") == false }
                ?.mapNotNull { it.hostAddress }
                ?: emptyList()
        }
    }.getOrElse {
        android.util.Log.e("VpnPlugin", "getLocalIpAddresses error: ${it.message}")
        emptyList()
    }

    fun getLocalGateways(): List<String> = runCatching {
        getActivePhysicalNetworks().flatMap { network ->
            connectivity?.getLinkProperties(network)
                ?.routes
                ?.filter { it.isDefaultRoute() }
                ?.mapNotNull { it.gateway }
                ?.filter {
                    !it.isLoopbackAddress && !it.isAnyLocalAddress &&
                        it.hostAddress?.contains(":") == false
                }
                ?.mapNotNull { it.hostAddress }
                ?: emptyList()
        }
    }.getOrElse {
        android.util.Log.e("VpnPlugin", "getLocalGateways error: ${it.message}")
        emptyList()
    }

    private val physicalTransports = listOf(
        NetworkCapabilities.TRANSPORT_ETHERNET to "Ethernet",
        NetworkCapabilities.TRANSPORT_WIFI to "Wi-Fi",
        NetworkCapabilities.TRANSPORT_CELLULAR to "Cellular",
    )

    private fun getDefaultPhysicalNetwork(): Network? {
        val cm = connectivity ?: return null
        val active = cm.activeNetwork
        val activeCaps = active?.let { cm.getNetworkCapabilities(it) }
        if (active != null && activeCaps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == false) {
            return active
        }
        return getActivePhysicalNetworks().maxByOrNull { network ->
            val caps = cm.getNetworkCapabilities(network) ?: return@maxByOrNull -1
            val index = physicalTransports.indexOfFirst { caps.hasTransport(it.first) }
            var score = if (index < 0) 0 else physicalTransports.size - index
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) score += 4
            if (index >= 0 && activeCaps?.hasTransport(physicalTransports[index].first) == true) score += 8
            score
        }
    }

    fun getNetworkInfo(): Map<String, Any> = runCatching {
        val cm = connectivity
        val network = getDefaultPhysicalNetwork()
        val caps = network?.let { cm?.getNetworkCapabilities(it) }
        val link = network?.let { cm?.getLinkProperties(it) }
        val addresses = link?.linkAddresses
            ?.map { it.address }
            ?.filter { !it.isLoopbackAddress && !it.isLinkLocalAddress }
            .orEmpty()
        val gateway = link?.routes
            ?.filter { it.isDefaultRoute() }
            ?.mapNotNull { it.gateway }
            ?.firstOrNull { it is Inet4Address && !it.isAnyLocalAddress }
        mapOf(
            "type" to (physicalTransports.firstOrNull { caps?.hasTransport(it.first) == true }?.second ?: ""),
            "interface" to (link?.interfaceName ?: ""),
            "ip" to ((addresses.firstOrNull { it is Inet4Address } ?: addresses.firstOrNull())?.hostAddress ?: ""),
            "gateway" to (gateway?.hostAddress ?: ""),
            "dns" to link?.dnsServers?.mapNotNull { it.hostAddress }.orEmpty(),
        )
    }.getOrElse {
        android.util.Log.e("VpnPlugin", "getNetworkInfo error: ${it.message}")
        emptyMap()
    }

    private data class StartReply(val serial: Long, val complete: (Boolean) -> Unit)
    @Volatile private var startReply: StartReply? = null
    private val confirmedLifecycle = ConfirmedVpnLifecycle(
        teardownScope,
        stop = { done -> stopUnconfirmed(force = true, onStopped = done) },
        start = { done ->
            val request = requestSerial.incrementAndGet()
            startReply = StartReply(request, done)
            onUpdateNetwork()
            when (options?.enable) {
                true -> teardownScope.launch(Dispatchers.Main) { handleStartVpn(request) }
                false -> handleStartService()
                null -> completeStart(request, false)
            }
        },
    )

    private fun completeStart(request: Long, success: Boolean) {
        val reply = synchronized(this) {
            startReply?.takeIf { it.serial == request && requestSerial.get() == request }
                ?.also { startReply = null }
        }
        reply?.complete?.invoke(success)
    }

    fun startConfirmed(next: VpnOptions, done: (Boolean) -> Unit) {
        confirmedLifecycle.submit(true, done) {
            options = next
            GlobalState.isSmartStopped = false
            Core.suspended(false)
        }
    }

    fun stopConfirmed(done: (Boolean) -> Unit) = confirmedLifecycle.submit(false, done)

    // Legacy fire-and-forget entrypoints share the coordinator, but their return
    // value is only acceptance. MethodChannel callers use the confirmed APIs.
    fun handleStart(next: VpnOptions): Boolean { startConfirmed(next) {}; return true }
    fun handleStop(force: Boolean = false) { stopConfirmed {} }

    private fun handleStartVpn(request: Long = requestSerial.get()) {
        if (request != requestSerial.get()) return
        val plugin = GlobalState.getCurrentAppPlugin()
        if (plugin == null) { completeStart(request, false); return }
        plugin.requestVpnPermission { granted ->
            if (request == requestSerial.get() && !GlobalState.isCurrentlyStopping()) {
                if (granted) handleStartService() else completeStart(request, false)
            }
        }
    }

    fun requestGc() {
        invokeDart("gc")
    }

    fun onUpdateNetwork() {
        val dns = getCurrentDns()
        if (dns == lastDns) return
        lastDns = dns
        invokeDart("dnsChanged", dns)
    }

    fun notifyScreenStateChanged(isOn: Boolean) {
        invokeDart("screenStateChanged", isOn)
    }

    fun getCurrentDns(): String {
        val dnsSet = when {
            networkDnsMap.isNotEmpty() -> networkDnsMap.values.flatMap { it }
            else -> {
                val cm = connectivity
                val activeNetwork = cm?.activeNetwork
                activeNetwork?.let { cm.resolveDns(it) } ?: emptyList()
            }
        }.toSet()
        return when {
            dnsSet.isNotEmpty() -> dnsSet.joinToString(",")
            else -> getAllNetworksDns()
        }
    }

    private fun getAllNetworksDns(): String {
        return runCatching {
            connectivity?.allNetworks?.flatMap { network ->
                connectivity?.resolveDns(network) ?: emptyList()
            }?.filter { it.isNotBlank() }?.toSet()?.joinToString(",") ?: ""
        }.getOrElse { "" }
    }

    private val networkDnsMap = ConcurrentHashMap<Network, List<String>>()

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            networks.add(network)
            handleNetworkChange()
            invokeDart("networkChanged")
        }

        override fun onLost(network: Network) {
            networks.remove(network)
            networkDnsMap.remove(network)
            onUpdateNetwork()
            handleNetworkChange()
            invokeDart("networkChanged")
        }

        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
            val dnsList = linkProperties.dnsServers.map { it.asSocketAddressText(53) }
            networkDnsMap[network] = dnsList
            onUpdateNetwork()
        }
    }

    private val request = NetworkRequest.Builder().apply {
        addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
        addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
    }.build()

    private fun registerNetworkCallback() {
        if (!networkCallbackRegistered.compareAndSet(false, true)) return
        runCatching {
            networks.clear()
            connectivity?.registerNetworkCallback(request, callback)
        }.onFailure {
            networkCallbackRegistered.set(false)
            android.util.Log.e("VpnPlugin", "Failed to register network callback: ${it.message}")
        }
    }

    private fun unRegisterNetworkCallback() {
        if (!networkCallbackRegistered.compareAndSet(true, false)) return
        runCatching {
            connectivity?.unregisterNetworkCallback(callback)
        }.onFailure {
            android.util.Log.e("VpnPlugin", "Failed to unregister network callback: ${it.message}")
        }.also {
            networks.clear()
            networkDnsMap.clear()
            onUpdateNetwork()
        }
    }
    
    private fun handleNetworkChange() {
        val currentNetworkType = getCurrentNetworkType()
        if (lastNetworkType == null) {
            lastNetworkType = currentNetworkType
            return
        }

        if (currentNetworkType != lastNetworkType) {
            lastNetworkType = currentNetworkType

            ServicePlugin.notifyNetworkChanged()
            invokeDart("networkChanged")

            if (!quickResponseEnabled) return

            quickResponseJob?.cancel()
            quickResponseJob = scope.launch {
                delay(150)
                if (GlobalState.currentRunState == RunState.START) {
                    android.util.Log.d("VpnPlugin", "Quick Response: Network changed, notifying Dart")
                    ServicePlugin.notifyQuickResponse()
                }
            }
        }
    }

    private fun invokeDart(method: String, arguments: Any? = null) {
        if (activeChannels.isEmpty()) return
        scope.launch {
            withContext(Dispatchers.Main) {
                activeChannels.forEach { channel ->
                    runCatching { channel.invokeMethod(method, arguments) }
                        .onFailure {
                            android.util.Log.w("VpnPlugin", "invokeDart($method) failed: ${it.message}")
                        }
                }
            }
        }
    }
    
    private fun getCurrentNetworkType(): Int {
        val activeNetwork = connectivity?.activeNetwork ?: return -1
        val caps = connectivity?.getNetworkCapabilities(activeNetwork) ?: return -1
        return when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> 1
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> 2
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> 3
            else -> 0
        }
    }

    private suspend fun startForeground() {
        val shouldUpdate = GlobalState.runLock.withLock {
            GlobalState.currentRunState == RunState.START || GlobalState.isSmartStopped
        }
        if (!shouldUpdate) return

        try {
            bettBoxService?.startForeground()
        } catch (e: Exception) {
            android.util.Log.e("VpnPlugin", "startForeground error: ${e.message}")
        }
    }

    fun updateNotificationIcon() {
        scope.launch {
            runCatching {
                val context = AngelaMihomoApplication.getAppContext()
                val notificationManager = context.getSystemService(android.app.NotificationManager::class.java)
                notificationManager?.cancel(GlobalState.NOTIFICATION_ID)
                (bettBoxService as? AngelaMihomoService)?.resetNotificationBuilder()
                (bettBoxService as? AngelaMihomoVpnService)?.resetNotificationBuilder()
                bettBoxService?.startForeground()
            }.onFailure {
                android.util.Log.e("VpnPlugin", "updateNotificationIcon error: ${it.message}")
            }
        }
    }

    fun handleUpdateNotificationSpeed(profileName: String, speedInfo: String) {
        if (profileName != GlobalState.currentProfileName ||
            !GlobalState.isSpeedNotificationEnabled
        ) {
            GlobalState.currentProfileName = profileName
            GlobalState.isSpeedNotificationEnabled = true
        }
        updateNotificationSpeed(profileName, speedInfo)
    }

    fun updateNotificationSpeed(profileName: String, speedInfo: String) {
        scope.launch {
            runCatching {
                (bettBoxService as? AngelaMihomoVpnService)?.updateNotificationSpeed(profileName, speedInfo)
            }.onFailure {
                android.util.Log.e("VpnPlugin", "updateNotificationSpeed error: ${it.message}")
            }
        }
    }

    fun restoreNotification() {
        scope.launch {
            runCatching {
                (bettBoxService as? AngelaMihomoVpnService)?.restoreNotification()
            }.onFailure {
                android.util.Log.e("VpnPlugin", "restoreNotification error: ${it.message}")
            }
        }
    }

    fun setHighPriorityNotification(enabled: Boolean) {
        GlobalState.isNotificationHighPriority = enabled
        (bettBoxService as? AngelaMihomoService)?.resetNotificationBuilder()
        (bettBoxService as? AngelaMihomoVpnService)?.resetNotificationBuilder()
        if (GlobalState.currentRunState == RunState.START) {
            scope.launch {
                startForeground()
            }
        }
    }

    fun getStatus(): Boolean {
        return GlobalState.runLock.withLock {
            GlobalState.currentRunState == RunState.START && bettBoxService != null
        }
    }

    private fun handleStartService() {
        val startRequest = requestSerial.get()
        if (GlobalState.isCurrentlyStopping()) {
            android.util.Log.w("VpnPlugin", "VPN is in stopping state, ignore start request")
            return
        }
        if (bettBoxService == null) {
            teardownScope.launch(Dispatchers.Main) {
                synchronized(activeEpoch) {
                    if (startRequest == requestSerial.get() && !GlobalState.isCurrentlyStopping()) bindService()
                }
            }
            return
        }
        
        scope.launch {
            try {
                if (startRequest != requestSerial.get()) return@launch
                if (options?.enable == true) {
                    val prepareIntent = try {
                        android.net.VpnService.prepare(AngelaMihomoApplication.getAppContext())
                    } catch (e: Exception) {
                        null
                    }

                    if (prepareIntent != null) {
                        android.util.Log.w("VpnPlugin", "VPN permission required before start")
                        GlobalState.updateRunState(RunState.STOP)
                        withContext(Dispatchers.Main) {
                            val plugin = GlobalState.getCurrentAppPlugin()
                            if (plugin == null) completeStart(startRequest, false)
                            else plugin.requestVpnPermission { granted ->
                                if (startRequest == requestSerial.get() && !GlobalState.isCurrentlyStopping()) {
                                    if (granted) handleStartService() else completeStart(startRequest, false)
                                }
                            }
                        }
                        return@launch
                    }
                }

                lifecycleMutex.withSuspendLock {
                    if (startRequest != requestSerial.get() || GlobalState.isCurrentlyStopping()) return@withSuspendLock
                    val currentOptions = options ?: return@withSuspendLock
                    val startAllowed = GlobalState.runLock.withLock {
                        if (GlobalState.currentRunState == RunState.START) {
                            scope.launch { startForeground() }
                            completeStart(startRequest, false) // not this request's confirmed start
                            false
                        } else {
                            GlobalState.updateRunState(RunState.PENDING)
                            lastStartForegroundParams = null
                            true
                        }
                    }
                    if (startAllowed && startRequest == requestSerial.get()) {
                        val epoch = retireLifecycle()
                        val started = performStartCore(currentOptions, retry = true, notifyOnFailure = true, epoch = epoch)
                        completeStart(startRequest, started)
                    }
                }
            } catch (e: Exception) {
                android.util.Log.e("VpnPlugin", "Fatal error in start flow: ${e.message}")
                if (startRequest == requestSerial.get()) {
                    completeStart(startRequest, false)
                    val failedEpoch = activeEpoch.get()
                    ServicePlugin.notifyVpnStartFailed { current(failedEpoch) }
                }
            }
        }
    }

    private suspend fun cleanupFailedStart(epoch: Long, service: BaseServiceInterface, notify: Boolean) {
        if (!current(epoch)) return
        GlobalState.updateIsStopping(true)
        Core.stopTunEpoch(epoch) // retire protector and close listener before service destruction
        service.stop()
        val context = AngelaMihomoApplication.getAppContext()
        withContext(Dispatchers.Main) {
            bindSerial.incrementAndGet()
            if (bindingRegistered) runCatching { context.unbindService(connection) }
            bindingRegistered = false
            isBind = false
            isBinding.set(false)
            context.stopService(Intent(context, if (service is AngelaMihomoVpnService)
                AngelaMihomoVpnService::class.java else AngelaMihomoService::class.java))
        }
        val cleaned = awaitServiceTeardown(epoch, service)
        if (!current(epoch)) return
        if (cleaned) finishConfirmedTeardown(epoch, service)
        // On timeout retain the exact service identity for the late waiter.
        // An unconfirmed teardown remains blocked; never silently reopen non-VPN.
        GlobalState.updateRunState(RunState.STOP)
        if (notify) ServicePlugin.notifyVpnStartFailed { current(epoch) }
        ServicePlugin.notifyRunStateChanged(RunState.STOP) { current(epoch) }
    }

    // Called only under lifecycleMutex. A late completion for a retired epoch
    // or a replaced service must not clear the current run's stopping state.
    private fun finishConfirmedTeardown(epoch: Long, service: BaseServiceInterface?): Boolean =
        synchronized(activeEpoch) {
            // retireLifecycle uses the same monitor, so an old waiter cannot
            // clear stopping between a newer epoch's retirement and teardown.
            if (!current(epoch) || bettBoxService !== service) return@synchronized false
            if (service != null && !service.destructionComplete.isCompleted) return@synchronized false
            if (service == null && !vpnTeardownComplete) return@synchronized false
            vpnTeardownComplete = true
            bettBoxService = null
            GlobalState.updateIsStopping(false)
            true
        }

    // Timeout limits the foreground stop wait, not the lifetime of confirmation.
    // The delayed waiter releases lifecycleMutex before waiting and reacquires it
    // to finalize. onDestroy completes the Deferred after resource cleanup.
    private suspend fun awaitServiceTeardown(
        epoch: Long,
        service: BaseServiceInterface?,
        onStopped: (() -> Unit)? = null,
        timeoutMillis: Long = 10_000,
    ): Boolean {
        if (service == null) return vpnTeardownComplete
        if (withTimeoutOrNull(timeoutMillis) { service.destructionComplete.await(); true } == true) return true
        teardownScope.launch {
            service.destructionComplete.await()
            val finished = lifecycleMutex.withSuspendLock {
                finishConfirmedTeardown(epoch, service)
            }
            if (finished && current(epoch)) onStopped?.invoke()
        }
        return false
    }

    // Called after onDestroy resource cleanup. Unexpected destruction retires
    // the gate; expected teardown already owns a closed gate and must keep epoch.
    fun onVpnServiceDestroyed(service: AngelaMihomoVpnService) {
        if (bettBoxService === service && !GlobalState.isCurrentlyStopping()) stopUnconfirmed(force = true)
    }

    private suspend fun performStartCore(
        currentOptions: VpnOptions,
        retry: Boolean,
        notifyOnFailure: Boolean,
        epoch: Long
    ): Boolean {
        if (!current(epoch)) return false
        // Opening non-VPN is legal only after the previous actual VPN service
        // called onDestroy; a timeout/failure deliberately stays fail-closed.
        if (!currentOptions.enable && !vpnTeardownComplete) return false
        val service = bettBoxService ?: return false
        if (currentOptions.enable) vpnTeardownComplete = false
        var fd: Int? = 0
        try {
            fd = service.start(currentOptions)
        } catch (e: Exception) {
            android.util.Log.e("VpnPlugin", "First start attempt failed: ${e.message}")
        }

        if (fd == null || (currentOptions.enable && fd <= 0)) {
            if (retry && current(epoch)) {
                android.util.Log.w("VpnPlugin", "VPN establish failed, retrying...")
                delay(300)
                try {
                    fd = service.start(currentOptions)
                } catch (e: Exception) {
                    android.util.Log.e("VpnPlugin", "Retry start failed: ${e.message}")
                }
            }
        }

        if (fd == null || (currentOptions.enable && fd <= 0)) {
            android.util.Log.e("VpnPlugin", "VPN start failed after all attempts")
            if (!current(epoch)) return false
            cleanupFailedStart(epoch, service, notifyOnFailure)
            return false
        }

        val canStart = current(epoch) && GlobalState.runLock.withLock {
            GlobalState.currentRunState == RunState.PENDING && !GlobalState.isCurrentlyStopping()
        }
        if (!canStart) {
            // establish() returned a detached fd; the core never received it.
            // Close just this pre-handoff case; the listener owns a handed-off fd.
            val unconsumedFd = fd
            if (currentOptions.enable && unconsumedFd != null && unconsumedFd > 0) {
                runCatching { android.os.ParcelFileDescriptor.adoptFd(unconsumedFd).close() }
                    .onFailure { android.util.Log.e("VpnPlugin", "Failed to close unused VPN fd", it) }
            }
            return false
        }

        val coreStarted = app.angelabettbox.core.Core.startTun(
            fd = fd ?: 0,
            epoch = epoch,
            protect = { socket -> (service as? AngelaMihomoVpnService)?.protect(socket) == true },
            resolverProcess = this@VpnPlugin::resolverProcess,
        )
        if (!coreStarted || !current(epoch)) {
            // A newer stop owns service teardown. Old failure never stops it or
            // publishes STOP for a subsequent start. Native accepted the fd.
            if (current(epoch)) {
                cleanupFailedStart(epoch, service, notifyOnFailure)
            }
            return false
        }
        val published = synchronized(activeEpoch) {
            if (!current(epoch) || GlobalState.isCurrentlyStopping()) false
            else {
                GlobalState.runLock.withLock { GlobalState.updateRunState(RunState.START) }
                true
            }
        }
        if (!published) return false
        startForeground()
        if (!current(epoch)) return false
        startStickyService()
        if (currentOptions.dozeSuspend && current(epoch)) {
            suspendModule?.uninstall()
            suspendModule = SuspendModule(AngelaMihomoApplication.getAppContext())
            suspendModule?.install()
        }
        onUpdateNetwork()
        return GlobalState.runLock.withLock { GlobalState.currentRunState == RunState.START }
    }

    private fun startStickyService() {
        GlobalState.runLock.withLock {
            if (GlobalState.currentRunState != RunState.START) return
            if (bettBoxService !is AngelaMihomoVpnService) return
            val context = AngelaMihomoApplication.getAppContext()
            runCatching {
                context.startService(Intent(context, AngelaMihomoVpnService::class.java))
            }.onFailure {
                android.util.Log.w("VpnPlugin", "startService error: ${it.message}")
            }
        }
    }

    private fun protect(fd: Int): Boolean {
        var retries = 0
        while (retries < 5) {
            val success = runCatching {
                (bettBoxService as? AngelaMihomoVpnService)?.protect(fd) == true
            }.getOrDefault(false)
            
            if (success) return true
            
            retries++
            if (retries < 5) {
                Thread.sleep(60)
            }
        }
        android.util.Log.e("VpnPlugin", "protect failed for fd $fd after retries")
        return false
    }

    private fun resolverProcess(
        protocol: Int,
        source: InetSocketAddress,
        target: InetSocketAddress,
        uid: Int,
    ): String = runCatching {
        val nextUid = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            connectivity?.getConnectionOwnerUid(protocol, source, target) ?: -1
        } else {
            uid
        }
        if (nextUid == -1) {
            return@runCatching ""
        }
        uidPageNameMap.getOrPut(nextUid) {
            AngelaMihomoApplication.getAppContext().packageManager?.getPackagesForUid(nextUid)
                ?.firstOrNull() ?: ""
        }
    }.getOrElse {
        android.util.Log.e("VpnPlugin", "resolverProcess error: ${it.message}")
        ""
    }

    private fun stopUnconfirmed(force: Boolean = false, onStopped: (() -> Unit)? = null) {
        synchronized(activeEpoch) {
            val stopRequest = requestSerial.incrementAndGet()
            startReply = null
            val hadBinding = bindingRegistered
            bindSerial.incrementAndGet()
            bindTimeoutJob?.cancel()
            isBinding.set(false)
            val resumeAfterStop = { if (requestSerial.get() == stopRequest) onStopped?.invoke(); Unit }
            val epoch = retireLifecycle() // closes gate before any asynchronous teardown
            val serviceRef = bettBoxService
            val wasBound = isBind || hadBinding
            // A pending binding with no known service identity cannot be declared
            // destroyed merely because stopService/unbindService returned.
            val pendingBind = hadBinding && serviceRef == null
            if (pendingBind) {
                vpnTeardownComplete = false
                retiredBinding = RetiredBinding(connectionTicket, epoch, resumeAfterStop)
            }
            GlobalState.runLock.withLock {
                GlobalState.updateIsStopping(true)
                GlobalState.updateRunState(RunState.STOP)
            }
            ServicePlugin.notifyRunStateChanged(RunState.STOP) { current(epoch) }
            teardownScope.launch {
                var stopped = false
                lifecycleMutex.withSuspendLock {
                    if (!current(epoch)) return@withSuspendLock
                    suspendModule?.uninstall()
                    suspendModule = null
                    Core.stopTunEpoch(epoch)
                    serviceRef?.stop()
                    val context = AngelaMihomoApplication.getAppContext()
                    withContext(Dispatchers.Main) {
                        bindSerial.incrementAndGet()
                        if (wasBound && !pendingBind) {
                            runCatching { context.unbindService(connection) }
                            isBind = false
                            bindingRegistered = false
                        }
                        context.stopService(Intent(context, AngelaMihomoVpnService::class.java))
                        context.stopService(Intent(context, AngelaMihomoService::class.java))
                    }
                    val cleaned = awaitServiceTeardown(epoch, serviceRef, resumeAfterStop)
                    if (!current(epoch)) return@withSuspendLock
                    if (!cleaned) {
                        android.util.Log.e("VpnPlugin", "VPN destruction not confirmed; awaiting late cleanup with gate closed")
                        return@withSuspendLock
                    }
                    stopped = finishConfirmedTeardown(epoch, serviceRef)
                }
                if (stopped && current(epoch)) resumeAfterStop()
            }
        }
    }

    fun handleSmartStop() {
        stopConfirmed { success -> if (success) GlobalState.isSmartStopped = true }
    }

    fun handleSmartResume(next: VpnOptions): Boolean {
        startConfirmed(next) {}
        return true
    }

    private fun bindService() {
        val bindRequest = requestSerial.get()
        if (!isBinding.compareAndSet(false, true)) return

        bindTimeoutJob?.cancel()
        bindTimeoutJob = scope.launch {
            delay(10_000L)
            synchronized(activeEpoch) {
            if (isBinding.compareAndSet(true, false)) {
                // Keep the ticket until stop retires it, so a binding arriving
                // between failure and cleanup cannot lose its service identity.
                completeStart(bindRequest, false)
                android.util.Log.w("VpnPlugin", "bindService timeout (10s), resetting bind state")
                GlobalState.runLock.withLock {
                    if (GlobalState.currentRunState == RunState.PENDING) {
                        GlobalState.updateRunState(RunState.STOP)
                    }
                }
            }
            }
        }

        try {
            if (bindingRegistered) {
                AngelaMihomoApplication.getAppContext().unbindService(connection)
                bindingRegistered = false
                isBind = false
            }
            val intent = Intent(
                AngelaMihomoApplication.getAppContext(),
                if (options?.enable == true) AngelaMihomoVpnService::class.java else AngelaMihomoService::class.java
            )
            connectionTicket = bindSerial.incrementAndGet()
            val nextConnection = makeConnection(connectionTicket)
            connection = nextConnection
            val res = AngelaMihomoApplication.getAppContext().bindService(intent, nextConnection, Context.BIND_AUTO_CREATE)
            bindingRegistered = res
            if (!res) {
                isBinding.set(false)
                bindTimeoutJob?.cancel()
                bindTimeoutJob = null
                completeStart(bindRequest, false)
                android.util.Log.e("VpnPlugin", "bindService returned false (rejected by system)")
            }
        } catch (e: Exception) {
            isBinding.set(false)
            bindTimeoutJob?.cancel()
            bindTimeoutJob = null
            completeStart(bindRequest, false)
            android.util.Log.e("VpnPlugin", "bindService error: ${e.message}")
        }
    }
}