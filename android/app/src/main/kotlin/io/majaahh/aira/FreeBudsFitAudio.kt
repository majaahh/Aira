package io.majaahh.aira

import android.annotation.TargetApi
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.net.URI
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.zip.ZipFile

internal class FreeBudsFitAudio(context: Context) {
    private val audioManager = context.getSystemService(AudioManager::class.java)
    private val audioFile = File(context.cacheDir, "freebuds-fit.ogg")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var player: MediaPlayer? = null
    private var playbackResult: MethodChannel.Result? = null

    private fun output(mac: String): AudioDeviceInfo? {
        if (Build.VERSION.SDK_INT < 28) return null
        return audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull {
            (it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                (Build.VERSION.SDK_INT >= 31 && it.type == AudioDeviceInfo.TYPE_BLE_HEADSET)) &&
                it.address.equals(mac, ignoreCase = true)
        }
    }

    fun prepare(mac: String, result: MethodChannel.Result) {
        if (output(mac) == null) {
            result.error("fit_route", "Connect the earbuds for Bluetooth audio before running the fit test", null)
            return
        }
        worker.execute {
            try {
                cacheAudio()
                main.post { result.success(null) }
            } catch (error: Exception) {
                main.post {
                    result.error("fit_audio", "Could not prepare the fit-test audio: ${error.message}", null)
                }
            }
        }
    }

    @TargetApi(28)
    fun play(mac: String, volume: Float, result: MethodChannel.Result) {
        val device = output(mac)
        if (device == null || Build.VERSION.SDK_INT < 28) {
            result.error("fit_route", "FreeBuds playback is unavailable", null)
            return
        }
        stop()
        val media = MediaPlayer()
        player = media
        playbackResult = result
        try {
            media.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            check(media.setPreferredDevice(device)) { "Could not route audio to the earbuds" }
            media.setDataSource(audioFile.absolutePath)
            // Start muted and unmute only after Android confirms the Bluetooth route.
            media.setVolume(0f, 0f)
            var reachedTarget = false
            media.setOnPreparedListener {
                if (player !== it) return@setOnPreparedListener
                it.start()
                if (it.routedDevice?.id == device.id) {
                    reachedTarget = true
                    it.setVolume(volume, volume)
                }
            }
            media.addOnRoutingChangedListener({ route ->
                if (player === media) {
                    if (route.routedDevice?.id == device.id) {
                        reachedTarget = true
                        media.setVolume(volume, volume)
                    } else {
                        media.setVolume(0f, 0f)
                        if (route.routedDevice != null) {
                            finish("Bluetooth audio routed away from the earbuds")
                        }
                    }
                }
            }, main)
            media.setOnCompletionListener {
                if (player === it) {
                    finish(if (reachedTarget) null else "FreeBuds playback route unavailable")
                }
            }
            media.setOnErrorListener { failed, _, _ ->
                if (player === failed) finish("Fit-test audio playback failed")
                true
            }
            media.prepareAsync()
        } catch (error: Exception) {
            finish(error.message ?: "Fit-test audio playback failed")
        }
    }

    private fun finish(error: String?) {
        player?.release()
        player = null
        val result = playbackResult
        playbackResult = null
        if (error == null) result?.success(null)
        else result?.error("fit_audio", error, null)
    }

    fun stop() = finish("Fit-test audio stopped")

    fun close() {
        stop()
        worker.shutdownNow()
    }

    private fun cacheAudio() {
        if (audioFile.exists() && audioFile.length() in 1..MAX_AUDIO_BYTES.toLong() &&
            checksum(audioFile.readBytes()) == AUDIO_HASH) return
        val connection = URI(AUDIO_URL).toURL().openConnection().apply {
            connectTimeout = 10_000
            readTimeout = 15_000
        }
        val archiveFile = File.createTempFile("freebuds-fit-", ".zip", audioFile.parentFile)
        try {
            connection.getInputStream().use { stream ->
                archiveFile.writeBytes(readLimited(stream, MAX_ARCHIVE_BYTES))
            }
            val bytes = ZipFile(archiveFile).use { zip ->
                val entry = checkNotNull(zip.getEntry("000145_01/detect_music.ogg")) {
                    "Fit-test audio is missing"
                }
                zip.getInputStream(entry).use { readLimited(it, MAX_AUDIO_BYTES) }
            }
            check(checksum(bytes) == AUDIO_HASH) { "Unexpected Huawei fit-test audio checksum" }
            audioFile.writeBytes(bytes)
        } finally {
            archiveFile.delete()
        }
    }

    private fun readLimited(stream: InputStream, limit: Int): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val count = stream.read(buffer)
            if (count < 0) return output.toByteArray()
            check(output.size() + count <= limit) { "Unexpected fit-test resource size" }
            output.write(buffer, 0, count)
        }
    }

    private fun checksum(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private companion object {
        const val MAX_ARCHIVE_BYTES = 16 * 1024 * 1024
        const val MAX_AUDIO_BYTES = 2 * 1024 * 1024
        const val AUDIO_URL =
            "https://contentcenter-dre.dbankcdn.cn/pub_1/HW-SmartHome_oem_900_9/" +
                "b0/v3/eu/device/guide/000145/000145_01.zip"
        const val AUDIO_HASH = "dcdb02ba6eb810f19cb6a298fd53c3fa7e22a47076aea86a062ce3c8bbbf9ed3"
    }
}
