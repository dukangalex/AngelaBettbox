package com.appshub.bettbox.plugins

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.appshub.bettbox.GlobalState
import com.appshub.bettbox.RunState
import com.appshub.bettbox.models.VpnOptions
import com.google.gson.Gson
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CopyOnWriteArrayList

class ServicePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel

    companion object {
        private val activeChannels = CopyOnWriteArrayList<MethodChannel>()
        private val mainHandler = Handler(Looper.getMainLooper())
        private val gson = Gson()
        private const val TAG = "ServicePlugin"

        private fun notify(method: String, stillCurrent: () -> Boolean = { true }) {
            mainHandler.post {
                if (!stillCurrent()) return@post
                activeChannels.forEach { ch ->
                    runCatching { ch.invokeMethod(method, null) }
                        .onFailure { Log.e(TAG, "$method notify error: ${it.message}") }
                }
            }
        }

        fun notifyNetworkChanged() = notify("networkChanged")
        fun notifyQuickResponse() = notify("quickResponse")
        fun notifyVpnStartFailed(stillCurrent: () -> Boolean = { true }) = notify("vpnStartFailed", stillCurrent)
        fun notifyRunStateChanged(state: RunState, stillCurrent: () -> Boolean = { true }) {
            mainHandler.post {
                if (!stillCurrent()) return@post
                activeChannels.forEach { ch ->
                    runCatching { ch.invokeMethod("runStateChanged", state.name) }
                        .onFailure { Log.e(TAG, "runStateChanged notify error: ${it.message}") }
                }
            }
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "service").apply {
            setMethodCallHandler(this@ServicePlugin)
        }
        activeChannels.add(channel)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        activeChannels.remove(channel)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startVpn" -> handleStartVpn(call, result)
            "stopVpn" -> {
                VpnPlugin.stopConfirmed { ok -> android.os.Handler(android.os.Looper.getMainLooper()).post { result.success(ok) } }
            }
            "smartStop" -> {
                VpnPlugin.stopConfirmed { ok ->
                    if (ok) GlobalState.isSmartStopped = true
                    android.os.Handler(android.os.Looper.getMainLooper()).post { result.success(ok) }
                }
            }
            "smartResume" -> {
                val data = call.argument<String>("data")
                val options = gson.fromJson(data, VpnOptions::class.java)
                VpnPlugin.startConfirmed(options) { ok -> android.os.Handler(android.os.Looper.getMainLooper()).post { result.success(ok) } }
            }
            "setSmartStopped" -> {
                GlobalState.isSmartStopped = call.argument<Boolean>("value") ?: false
                result.success(true)
            }
            "isSmartStopped" -> result.success(GlobalState.isSmartStopped)
            "getLocalIpAddresses" -> result.success(VpnPlugin.getLocalIpAddresses())
            "getLocalGateways" -> result.success(VpnPlugin.getLocalGateways())
            "getNetworkInfo" -> result.success(VpnPlugin.getNetworkInfo())
            "getCurrentDns" -> result.success(VpnPlugin.getCurrentDns())
            "setQuickResponse" -> {
                VpnPlugin.setQuickResponse(call.argument<Boolean>("enabled") ?: false)
                result.success(true)
            }
            "init" -> {
                GlobalState.getCurrentAppPlugin()?.requestNotificationsPermission()
                GlobalState.initServiceEngine()
                result.success(true)
            }
            "isServiceEngineRunning" -> result.success(GlobalState.isServiceEngineRunning())
            "status" -> result.success(GlobalState.currentRunState == RunState.START)
            "reconnectIpc" -> {
                GlobalState.reconnectIpc()
                result.success(true)
            }
            "destroy" -> {
                GlobalState.destroyServiceEngine()
                result.success(true)
            }
            "updateNotificationSpeed" -> {
                VpnPlugin.handleUpdateNotificationSpeed(
                    call.argument<String>("profileName") ?: "",
                    call.argument<String>("speedInfo") ?: ""
                )
                result.success(true)
            }
            "restoreNotification" -> {
                GlobalState.isSpeedNotificationEnabled = false
                VpnPlugin.restoreNotification()
                result.success(true)
            }
            "setHighPriorityNotification" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                VpnPlugin.setHighPriorityNotification(enabled)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun handleStartVpn(call: MethodCall, result: MethodChannel.Result) {
        val data = call.argument<String>("data")
        if (data.isNullOrBlank() || data == "null") {
            result.error("INVALID_ARGUMENT", "options data is null", null)
            return
        }
        runCatching { gson.fromJson(data, VpnOptions::class.java) }
            .onSuccess { options ->
                VpnPlugin.startConfirmed(options) { ok -> android.os.Handler(android.os.Looper.getMainLooper()).post { result.success(ok) } }
            }
            .onFailure { result.error("PARSE_ERROR", it.message, null) }
    }
}
