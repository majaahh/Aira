package io.majaahh.aira

import android.Manifest
import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHeadset
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothSocket
import android.bluetooth.BluetoothStatusCodes
import android.companion.AssociationInfo
import android.companion.AssociationRequest
import android.companion.BluetoothDeviceFilter
import android.companion.CompanionDeviceManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.IntentSender
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Display
import android.view.Surface
import android.view.SurfaceHolder
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterSurfaceView
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.*
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val fitAudio by lazy { FreeBudsFitAudio(applicationContext) }
    private val PERMISSION_REQUEST_CODE = 444
    private val bluetoothAssociationRequestCode = 445
    private var permissionResultCallback: MethodChannel.Result? = null
    private var bluetoothAssociationResult: MethodChannel.Result? = null

    private var scanResultCallback: MethodChannel.Result? = null
    private val discoveredDevices = mutableListOf<Map<String, String>>()
    private val bluetoothReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val action = intent.action
            if (BluetoothDevice.ACTION_FOUND == action) {
                val device: BluetoothDevice? = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                if (device != null) {
                    val name = if (ActivityCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED || Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                        device.name
                    } else null
                    val mac = device.address
                    if (mac != null) {
                        val devMap = mapOf("name" to (name ?: "Huawei FreeBuds"), "mac" to mac)
                        if (!discoveredDevices.any { it["mac"] == mac }) {
                            discoveredDevices.add(devMap)
                        }
                    }
                }
            } else if (BluetoothAdapter.ACTION_DISCOVERY_FINISHED == action) {
                sendScanResult()
            }
        }
    }

    private var connectionReceiverRegistered = false
    private val connectionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            sendEvent("bluetooth_changed", null)
        }
    }

    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private var socket: BluetoothSocket? = null
    private var outStream: OutputStream? = null
    private var inStream: InputStream? = null
    private var eventSink: EventChannel.EventSink? = null
    private var isConnected = false

    private fun preferredAnimationMode(display: Display): Display.Mode? {
        val currentMode = display.mode
        return display.supportedModes
            .filter {
                it.physicalWidth == currentMode.physicalWidth &&
                    it.physicalHeight == currentMode.physicalHeight &&
                    it.refreshRate > 60.01f
            }
            .maxByOrNull { it.refreshRate }
    }

    override fun onFlutterSurfaceViewCreated(flutterSurfaceView: FlutterSurfaceView) {
        super.onFlutterSurfaceViewCreated(flutterSurfaceView)

        flutterSurfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) = Unit

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return

                val display = flutterSurfaceView.display ?: return
                val surface = holder.surface
                if (!surface.isValid) return

                // Let Android choose a seamless refresh-rate change for Flutter's render surface.
                val refreshRate = preferredAnimationMode(display)?.refreshRate ?: 0f
                surface.setFrameRate(refreshRate, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
            }

            override fun surfaceDestroyed(holder: SurfaceHolder) = Unit
        })
    }

    override fun onResume() {
        super.onResume()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) return

        @Suppress("DEPRECATION")
        val mode = preferredAnimationMode(windowManager.defaultDisplay) ?: return
        val attributes = window.attributes
        if (attributes.preferredDisplayModeId != mode.modeId) {
            attributes.preferredDisplayModeId = mode.modeId
            window.attributes = attributes
        }
    }

    private fun systemColorRoles(): Map<String, Int> {
        if (Build.VERSION.SDK_INT < 34) return emptyMap()

        val roles = listOf(
            "primary", "on_primary", "primary_container", "on_primary_container",
            "secondary", "on_secondary", "secondary_container", "on_secondary_container",
            "tertiary", "on_tertiary", "tertiary_container", "on_tertiary_container",
            "error", "on_error", "error_container", "on_error_container",
            "outline", "outline_variant", "surface", "on_surface", "on_surface_variant",
            "surface_dim", "surface_bright", "surface_container_lowest", "surface_container_low",
            "surface_container", "surface_container_high", "surface_container_highest",
            "shadow", "scrim", "surface_tint",
        )
        val fixedRoles = listOf("primary", "secondary", "tertiary").flatMap {
            listOf("${it}_fixed", "${it}_fixed_dim", "on_${it}_fixed", "on_${it}_fixed_variant")
        }
        val names = roles.flatMap { listOf("${it}_light", "${it}_dark") } + fixedRoles
        return buildMap {
            for (name in names) {
                val id = resources.getIdentifier("system_$name", "color", "android")
                if (id != 0) put(name, resources.getColor(id, null))
            }
        }
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: io.flutter.embedding.engine.FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.majaahh.aira/system_colors").setMethodCallHandler { call, result ->
            if (call.method == "getColorRoles") {
                result.success(systemColorRoles())
            } else {
                result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.majaahh.aira/bluetooth").setMethodCallHandler { call, result ->
            when (call.method) {
                "checkPermissions" -> {
                    result.success(hasRequiredPermissions())
                }
                "requestPermissions" -> {
                    requestRequiredPermissions(result)
                }
                "checkConnectPermission" -> {
                    result.success(hasConnectPermission())
                }
                "requestConnectPermission" -> {
                    if (hasConnectPermission()) {
                        result.success(true)
                    } else {
                        requestBluetoothPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), result)
                    }
                }
                "getConnectedDevices" -> {
                    getConnectedDevices(result)
                }
                "getPairedDevices" -> {
                    getPairedDevices(result)
                }
                "startScan" -> {
                    startScan(result)
                }
                "connect" -> {
                    val mac = call.argument<String>("mac") ?: ""
                    connect(mac, result)
                }
                "disconnect" -> {
                    disconnect(result)
                }
                "prepareBluetoothDisconnect" -> {
                    prepareBluetoothDisconnect(call.argument<String>("mac"), result)
                }
                "disconnectBluetooth" -> {
                    result.success(disconnectBluetooth(call.argument<String>("mac")))
                }
                "write" -> {
                    val bytes = call.argument<ByteArray>("bytes") ?: byteArrayOf()
                    write(bytes, result)
                }
                "prepareFitAudio" -> {
                    fitAudio.prepare(call.argument<String>("mac").orEmpty(), result)
                }
                "playFitAudio" -> {
                    val mac = call.argument<String>("mac").orEmpty()
                    val volume = call.argument<Double>("volume")?.toFloat()?.coerceIn(0f, 1f) ?: 0f
                    fitAudio.play(mac, volume, result)
                }
                "stopFitAudio" -> {
                    fitAudio.stop()
                    result.success(null)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        if (!connectionReceiverRegistered) {
            val filter = IntentFilter().apply {
                addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
                addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
                addAction(BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED)
                addAction(BluetoothHeadset.ACTION_CONNECTION_STATE_CHANGED)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(connectionReceiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                registerReceiver(connectionReceiver, filter)
            }
            connectionReceiverRegistered = true
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "io.majaahh.aira/bluetooth_events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            }
        )
    }

    private fun hasConnectPermission(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH) ==
                PackageManager.PERMISSION_GRANTED
        }

    private fun hasRequiredPermissions(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH) == PackageManager.PERMISSION_GRANTED &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_ADMIN) == PackageManager.PERMISSION_GRANTED &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requestRequiredPermissions(result: MethodChannel.Result) {
        if (hasRequiredPermissions()) {
            result.success(true)
            return
        }
        val permissions = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            arrayOf(
                Manifest.permission.BLUETOOTH,
                Manifest.permission.BLUETOOTH_ADMIN,
                Manifest.permission.ACCESS_FINE_LOCATION
            )
        }
        requestBluetoothPermissions(permissions, result)
    }

    private fun requestBluetoothPermissions(permissions: Array<String>, result: MethodChannel.Result) {
        if (permissionResultCallback != null) {
            result.success(false)
            return
        }
        permissionResultCallback = result
        ActivityCompat.requestPermissions(this, permissions, PERMISSION_REQUEST_CODE)
    }

    private fun getConnectedDevices(result: MethodChannel.Result) {
        if (!hasConnectPermission()) {
            result.success(null)
            return
        }
        val adapter = getSystemService(BluetoothManager::class.java)?.adapter
        if (adapter == null || !adapter.isEnabled) {
            result.success(emptyList<Map<String, String>>())
            return
        }

        val handler = Handler(Looper.getMainLooper())
        val pending = mutableSetOf(BluetoothProfile.A2DP, BluetoothProfile.HEADSET)
        val connected = linkedMapOf<String, Map<String, String>>()
        var finished = false
        val timeout = Runnable {
            finished = true
            result.success(connected.values.toList().ifEmpty { null })
        }
        fun finishProfile(profile: Int) {
            pending.remove(profile)
            if (pending.isEmpty() && !finished) {
                finished = true
                handler.removeCallbacks(timeout)
                result.success(connected.values.toList())
            }
        }
        val listener = object : BluetoothProfile.ServiceListener {
            override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
                try {
                    if (!finished) {
                        for (device in proxy.connectedDevices) {
                            connected[device.address] = mapOf(
                                "mac" to device.address,
                                "name" to device.name.orEmpty()
                            )
                        }
                    }
                } catch (_: SecurityException) {
                    // Permission can be revoked after requesting the proxy.
                } finally {
                    adapter.closeProfileProxy(profile, proxy)
                    finishProfile(profile)
                }
            }

            override fun onServiceDisconnected(profile: Int) = finishProfile(profile)
        }
        handler.postDelayed(timeout, 2500)
        for (profile in pending.toList()) {
            val requested = try {
                adapter.getProfileProxy(this, listener, profile)
            } catch (_: SecurityException) {
                false
            }
            if (!requested) finishProfile(profile)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSION_REQUEST_CODE) {
            val allGranted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            permissionResultCallback?.success(allGranted)
            permissionResultCallback = null
        }
    }

    private fun getPairedDevices(result: MethodChannel.Result) {
        val adapter = BluetoothAdapter.getDefaultAdapter()
        if (adapter == null) {
            result.error("BLUETOOTH_UNAVAILABLE", "Bluetooth is not supported on this device", null)
            return
        }
        if (!hasRequiredPermissions()) {
            result.error("PERMISSION_DENIED", "Bluetooth permissions not granted", null)
            return
        }

        try {
            val bondedDevices = adapter.bondedDevices
            val deviceList = mutableListOf<Map<String, String>>()
            for (device in bondedDevices) {
                val name = if (ActivityCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED || Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                    device.name
                } else null
                val mac = device.address
                if (mac != null) {
                    deviceList.add(mapOf("name" to (name ?: "Huawei FreeBuds"), "mac" to mac))
                }
            }
            result.success(deviceList)
        } catch (e: Exception) {
            result.error("PAIRED_QUERY_FAILED", e.message, null)
        }
    }

    private fun startScan(result: MethodChannel.Result) {
        val adapter = BluetoothAdapter.getDefaultAdapter()
        if (adapter == null) {
            result.error("BLUETOOTH_UNAVAILABLE", "Bluetooth is not supported on this device", null)
            return
        }
        if (!hasRequiredPermissions()) {
            result.error("PERMISSION_DENIED", "Bluetooth permissions not granted", null)
            return
        }

        scanResultCallback = result
        discoveredDevices.clear()

        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_FOUND)
            addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
        }
        registerReceiver(bluetoothReceiver, filter)

        try {
            adapter.startDiscovery()
            // Force stop after 4 seconds if not finished
            Handler(Looper.getMainLooper()).postDelayed({
                if (adapter.isDiscovering) {
                    adapter.cancelDiscovery()
                }
            }, 4000)
        } catch (e: Exception) {
            sendScanResult()
        }
    }

    private fun sendScanResult() {
        try {
            unregisterReceiver(bluetoothReceiver)
        } catch (e: Exception) {}

        scanResultCallback?.success(discoveredDevices)
        scanResultCallback = null
    }

    private fun connect(mac: String, result: MethodChannel.Result) {
        val adapter = BluetoothAdapter.getDefaultAdapter()
        if (adapter == null) {
            result.error("BLUETOOTH_UNAVAILABLE", "Bluetooth is not supported on this device", null)
            return
        }
        val device = adapter.getRemoteDevice(mac)
        if (device == null) {
            result.error("DEVICE_NOT_FOUND", "Device with MAC address $mac not found", null)
            return
        }

        executor.execute {
            try {
                sendEvent("status", "connecting")
                // Connecting only needs Bluetooth Connect permission. Cancelling a scan also needs Scan.
                try {
                    adapter.cancelDiscovery()
                } catch (_: SecurityException) {
                }

                // FreeBuds exposes its control channel on RFCOMM port 16.
                var connected = false
                try {
                    val m = device.javaClass.getMethod("createInsecureRfcommSocket", Int::class.javaPrimitiveType)
                    val s = m.invoke(device, 16) as BluetoothSocket
                    s.connect()
                    socket = s
                    connected = true
                } catch (e: Exception) {
                    // Fallback to the standard SPP UUID.
                    val fallbackUuids = listOf(
                        UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
                    )
                    var lastErr: Exception? = null
                    for (uuid in fallbackUuids) {
                        try {
                            val s = device.createInsecureRfcommSocketToServiceRecord(uuid)
                            s.connect()
                            socket = s
                            connected = true
                            break
                        } catch (e2: Exception) {
                            lastErr = e2
                        }
                    }
                    if (!connected && lastErr != null) {
                        throw lastErr
                    }
                }

                if (connected) {
                    outStream = socket!!.outputStream
                    inStream = socket!!.inputStream
                    isConnected = true

                    Handler(Looper.getMainLooper()).post {
                        result.success(true)
                    }

                    sendEvent("status", "connected")
                    Thread { listenForData() }.start()
                } else {
                    throw IOException("Could not connect to device")
                }
            } catch (e: Exception) {
                android.util.Log.e("Aira-Native", "connect failed with exception: ${e.message}", e)
                disconnectInternal()
                Handler(Looper.getMainLooper()).post {
                    result.error("CONNECTION_FAILED", e.message, null)
                }
                sendEvent("status", "failed")
            }
        }
    }

    private fun listenForData() {
        val buffer = ByteArray(1024)
        while (isConnected) {
            try {
                val bytesRead = inStream?.read(buffer) ?: -1
                if (bytesRead > 0) {
                    val data = buffer.copyOfRange(0, bytesRead)
                    val intList = data.map { it.toInt() and 0xFF }
                    Handler(Looper.getMainLooper()).post {
                        sendEvent("data", intList)
                    }
                } else if (bytesRead == -1) {
                    throw IOException("End of stream reached")
                }
            } catch (e: Exception) {
                android.util.Log.e("Aira-Native", "listenForData error or socket disconnected: ${e.message}", e)
                if (isConnected) {
                    disconnectInternal()
                    sendEvent("status", "disconnected")
                }
                break
            }
        }
    }

    private fun write(bytes: ByteArray, result: MethodChannel.Result) {
        if (!isConnected || outStream == null) {
            result.error("NOT_CONNECTED", "No device connected", null)
            return
        }
        executor.execute {
            try {
                outStream?.write(bytes)
                outStream?.flush()
                Handler(Looper.getMainLooper()).post {
                    result.success(true)
                }
            } catch (e: Exception) {
                android.util.Log.e("Aira-Native", "write failed with exception: ${e.message}", e)
                Handler(Looper.getMainLooper()).post {
                    result.error("WRITE_FAILED", e.message, null)
                }
            }
        }
    }

    private fun bluetoothDisconnectMethod(): java.lang.reflect.Method? {
        // The public API was added in 37. Flutter currently compiles against 36.
        if (Build.VERSION.SDK_INT < 37) return null
        return try {
            BluetoothDevice::class.java.getMethod("disconnect")
        } catch (_: NoSuchMethodException) {
            null
        }
    }

    private fun prepareBluetoothDisconnect(mac: String?, result: MethodChannel.Result) {
        if (mac == null || !BluetoothAdapter.checkBluetoothAddress(mac) ||
            bluetoothDisconnectMethod() == null || bluetoothAssociationResult != null) {
            result.success(false)
            return
        }

        val manager = getSystemService(CompanionDeviceManager::class.java)
        if (manager == null) {
            result.success(false)
            return
        }

        fun finish(associated: Boolean) {
            if (bluetoothAssociationResult === result) {
                bluetoothAssociationResult = null
                result.success(associated)
            }
        }

        bluetoothAssociationResult = result
        try {
            if (manager.myAssociations.any { it.deviceMacAddress.toString().equals(mac, true) }) {
                finish(true)
                return
            }

            val request = AssociationRequest.Builder()
                .addDeviceFilter(BluetoothDeviceFilter.Builder().setAddress(mac).build())
                .setSingleDevice(true)
                .build()
            manager.associate(request, mainExecutor, object : CompanionDeviceManager.Callback() {
                override fun onAssociationPending(intentSender: IntentSender) {
                    if (bluetoothAssociationResult !== result) return
                    try {
                        startIntentSenderForResult(
                            intentSender, bluetoothAssociationRequestCode, null, 0, 0, 0
                        )
                    } catch (_: IntentSender.SendIntentException) {
                        finish(false)
                    }
                }

                override fun onAssociationCreated(associationInfo: AssociationInfo) {
                    finish(associationInfo.deviceMacAddress.toString().equals(mac, true))
                }

                override fun onFailure(error: CharSequence?) {
                    finish(false)
                }
            })
        } catch (_: RuntimeException) {
            finish(false)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == bluetoothAssociationRequestCode && resultCode != RESULT_OK) {
            bluetoothAssociationResult?.success(false)
            bluetoothAssociationResult = null
        }
    }

    private fun disconnectBluetooth(mac: String?): Boolean {
        val method = bluetoothDisconnectMethod() ?: return false
        val adapter = getSystemService(BluetoothManager::class.java)?.adapter ?: return false
        if (mac == null || !BluetoothAdapter.checkBluetoothAddress(mac)) return false
        return try {
            method.invoke(adapter.getRemoteDevice(mac)) == BluetoothStatusCodes.SUCCESS
        } catch (e: Exception) {
            android.util.Log.w("Aira-Native", "Bluetooth disconnect failed", e)
            false
        }
    }

    private fun disconnect(result: MethodChannel.Result) {
        disconnectInternal()
        result.success(true)
        sendEvent("status", "disconnected")
    }

    private fun disconnectInternal() {
        isConnected = false
        Handler(Looper.getMainLooper()).post { fitAudio.stop() }
        try { inStream?.close() } catch (e: Exception) {}
        inStream = null
        try { outStream?.close() } catch (e: Exception) {}
        outStream = null
        try { socket?.close() } catch (e: Exception) {}
        socket = null
    }

    private fun sendEvent(event: String, value: Any?) {
        Handler(Looper.getMainLooper()).post {
            eventSink?.success(mapOf("event" to event, "value" to value))
        }
    }
    override fun onDestroy() {
        fitAudio.close()
        bluetoothAssociationResult?.success(false)
        bluetoothAssociationResult = null
        if (connectionReceiverRegistered) {
            try { unregisterReceiver(connectionReceiver) } catch (e: Exception) {}
            connectionReceiverRegistered = false
        }
        super.onDestroy()
    }
}
