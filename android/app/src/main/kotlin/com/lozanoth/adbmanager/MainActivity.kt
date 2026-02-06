package com.lozanoth.adbmanager

import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import moe.shizuku.server.IRemoteProcess
import moe.shizuku.server.IShizukuService
import rikka.shizuku.Shizuku
import rikka.shizuku.ShizukuRemoteProcess
import java.io.BufferedReader
import java.io.InputStreamReader
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private val channelName = "shizuku"
    private val logChannelName = "shizuku_logs"
    private val requestCode = 1001
    private val mainHandler = Handler(Looper.getMainLooper())

    private var pendingResult: MethodChannel.Result? = null
    private var binderReady = false
    private var logSink: EventChannel.EventSink? = null
    private var activeProcess: Process? = null

    private val binderReceivedListener =
        Shizuku.OnBinderReceivedListener { binderReady = true }

    private val binderDeadListener =
        Shizuku.OnBinderDeadListener { binderReady = false }

    private val permissionResultListener =
        Shizuku.OnRequestPermissionResultListener { code, grantResult ->
            if (code != requestCode) return@OnRequestPermissionResultListener
            val granted = grantResult == PackageManager.PERMISSION_GRANTED
            pendingResult?.success(granted)
            pendingResult = null
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binderReady = Shizuku.pingBinder()
        Shizuku.addBinderReceivedListener(binderReceivedListener)
        Shizuku.addBinderDeadListener(binderDeadListener)
        Shizuku.addRequestPermissionResultListener(permissionResultListener)
    }

    override fun onDestroy() {
        Shizuku.removeBinderReceivedListener(binderReceivedListener)
        Shizuku.removeBinderDeadListener(binderDeadListener)
        Shizuku.removeRequestPermissionResultListener(permissionResultListener)
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkPermission" -> result.success(checkPermissionStatus())
                    "requestPermission" -> requestPermission(result)
                    "startScript" -> startScript(call, result)
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, logChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    logSink = events
                }

                override fun onCancel(arguments: Any?) {
                    logSink = null
                }
            })
    }

    private fun checkPermissionStatus(): Map<String, Any?> {
        val status = mutableMapOf<String, Any?>()
        status["available"] = binderReady
        status["isPreV11"] = Shizuku.isPreV11()
        status["uid"] = try {
            Shizuku.getUid()
        } catch (e: Throwable) {
            null
        }
        if (!binderReady || Shizuku.isPreV11()) {
            status["granted"] = false
            status["shouldShowRationale"] = false
            return status
        }
        return try {
            val granted =
                Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
            val rationale = !granted && Shizuku.shouldShowRequestPermissionRationale()
            status["granted"] = granted
            status["shouldShowRationale"] = rationale
            status
        } catch (e: Throwable) {
            status["error"] = e.message
            status["granted"] = false
            status["shouldShowRationale"] = false
            status
        }
    }

    private fun requestPermission(result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("busy", "Permission request in progress", null)
            return
        }
        if (Shizuku.isPreV11()) {
            result.success(false)
            return
        }
        if (!binderReady) {
            result.success(false)
            return
        }
        val granted = try {
            Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
        } catch (e: Throwable) {
            false
        }
        if (granted) {
            result.success(true)
            return
        }
        pendingResult = result
        Shizuku.requestPermission(requestCode)
    }

    private fun startScript(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val workDir = call.argument<String>("workDir")
        val label = call.argument<String>("label") ?: "module"

        if (path.isNullOrBlank()) {
            result.error("invalid", "path is required", null)
            return
        }
        if (!binderReady || Shizuku.isPreV11()) {
            result.error("shizuku", "Shizuku not available", null)
            return
        }
        val granted = try {
            Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
        } catch (e: Throwable) {
            false
        }
        if (!granted) {
            result.error("permission", "Shizuku permission not granted", null)
            return
        }
        if (activeProcess != null) {
            result.error("busy", "Another process is running", null)
            return
        }

        val quotedPath = shellQuote(path)
        val command = "sh $quotedPath"

        try {
            val process = createRemoteProcess(command, workDir)
            activeProcess = process
            pumpLogs(process.inputStream, label, false)
            pumpLogs(process.errorStream, label, true)
            thread {
                val code = process.waitFor()
                sendLog("[$label] exit=$code")
                activeProcess = null
            }
            result.success(true)
        } catch (e: Throwable) {
            activeProcess = null
            result.error("start", e.message, null)
        }
    }

    private fun createRemoteProcess(command: String, workDir: String?): Process {
        val binder = Shizuku.getBinder()
        val service = IShizukuService.Stub.asInterface(binder)
            ?: throw IllegalStateException("Shizuku service unavailable")
        val remote = service.newProcess(arrayOf("sh", "-c", command), null, workDir)
        val ctor = ShizukuRemoteProcess::class.java
            .getDeclaredConstructor(IRemoteProcess::class.java)
        ctor.isAccessible = true
        return ctor.newInstance(remote)
    }

    private fun pumpLogs(stream: java.io.InputStream, label: String, isError: Boolean) {
        thread {
            BufferedReader(InputStreamReader(stream)).use { reader ->
                var line: String? = reader.readLine()
                while (line != null) {
                    val prefix = if (isError) "ERR" else "OUT"
                    sendLog("[$label][$prefix] $line")
                    line = reader.readLine()
                }
            }
        }
    }

    private fun sendLog(message: String) {
        mainHandler.post {
            logSink?.success(message)
        }
    }

    private fun shellQuote(value: String): String {
        val escaped = value.replace("'", "'\\''")
        return "'$escaped'"
    }
}
