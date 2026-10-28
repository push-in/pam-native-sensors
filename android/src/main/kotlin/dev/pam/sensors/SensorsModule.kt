package dev.pam.sensors

import dev.pam.nativeapp.modules.ModuleCompletion
import dev.pam.nativeapp.modules.ModuleResultStatus
import dev.pam.nativeapp.modules.NativeModule
import dev.pam.nativeapp.modules.WatchChannel

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.Looper
import dev.pam.nativeapp.protocol.WireMap
import dev.pam.nativeapp.protocol.WireValue
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class SensorsModule(context: Context) : NativeModule, AutoCloseable {
    private val manager = context.getSystemService(SensorManager::class.java)
    private val nextId = AtomicInteger(1)
    private val watches = HashMap<Int, Watch>()
    private val main = Handler(Looper.getMainLooper())
    private val reads = java.util.Collections.synchronizedSet(mutableSetOf<SensorEventListener>())

    override fun invoke(method: String, payload: ByteArray, completion: ModuleCompletion) {
        runCatching {
            when (method) {
                "read" -> read(payload, completion)
                "watch" -> start(payload, completion)
                "next" -> watch(payload).channel.next(completion)
                "stop" -> {
                    stop(id(payload))
                    completion.complete(ModuleResultStatus.SUCCESS, ByteArray(0))
                }
                else -> error("Unknown sensors method $method")
            }
        }.onFailure {
            completion.complete(ModuleResultStatus.FAILURE, (it.message ?: "Sensor observation failed").toByteArray())
        }
    }

    private fun platformType(kind: Int): Int = when (kind) {
        1 -> Sensor.TYPE_ACCELEROMETER
        2 -> Sensor.TYPE_GYROSCOPE
        3 -> Sensor.TYPE_MAGNETIC_FIELD
        4 -> Sensor.TYPE_ROTATION_VECTOR
        else -> error("Unknown sensor type $kind")
    }

    /** One reading, then the listener is released; fails after `timeoutMs` (100..10000). */
    private fun read(payload: ByteArray, completion: ModuleCompletion) {
        val values = WireMap.decode(payload)
        val kind = ((values["type"] as? WireValue.Integer)?.value ?: 0).toInt()
        val timeoutMs = ((values["timeoutMs"] as? WireValue.Integer)?.value ?: 2_000L).coerceIn(100L, 10_000L)
        val sensor = manager.getDefaultSensor(platformType(kind)) ?: error("Requested sensor is unavailable")
        val completed = AtomicBoolean()
        lateinit var listener: SensorEventListener
        val timeout = Runnable {
            if (completed.compareAndSet(false, true)) {
                manager.unregisterListener(listener)
                reads.remove(listener)
                completion.complete(ModuleResultStatus.FAILURE, "Sensor read timed out".toByteArray())
            }
        }
        listener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                if (!completed.compareAndSet(false, true)) return
                manager.unregisterListener(this)
                reads.remove(this)
                main.removeCallbacks(timeout)
                completion.complete(ModuleResultStatus.SUCCESS, encode(event, event.timestamp / 1_000_000L))
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
        }
        reads += listener
        main.post {
            if (!manager.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_UI)) {
                reads.remove(listener)
                if (completed.compareAndSet(false, true)) {
                    completion.complete(ModuleResultStatus.FAILURE, "Could not start sensor".toByteArray())
                }
                return@post
            }
            main.postDelayed(timeout, timeoutMs)
        }
    }

    private fun encode(event: SensorEvent, timestamp: Long): ByteArray = WireMap.encode(mapOf(
        "x" to WireValue.Decimal(event.values.getOrElse(0) { 0f }.toDouble()),
        "y" to WireValue.Decimal(event.values.getOrElse(1) { 0f }.toDouble()),
        "z" to WireValue.Decimal(event.values.getOrElse(2) { 0f }.toDouble()),
        "timestamp" to WireValue.Integer(timestamp),
    ))

    private fun start(payload: ByteArray, completion: ModuleCompletion) {
        val values = WireMap.decode(payload)
        val kind = ((values["type"] as? WireValue.Integer)?.value ?: 0).toInt()
        val intervalMs = ((values["intervalMs"] as? WireValue.Integer)?.value ?: 100)
            .coerceIn(16, 60_000)
        val platform = platformType(kind)
        val sensor = manager.getDefaultSensor(platform) ?: error("Requested sensor is unavailable")
        val id = nextId.getAndIncrement()
        val channel = WatchChannel()
        var lastTimestamp = 0L
        val listener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                val timestamp = event.timestamp / 1_000_000L
                if (timestamp - lastTimestamp < intervalMs) return
                lastTimestamp = timestamp
                channel.offer(encode(event, timestamp))
            }
            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
        }
        require(manager.registerListener(listener, sensor, (intervalMs * 1_000).toInt())) {
            "Could not start sensor observation"
        }
        watches[id] = Watch(listener, channel)
        completion.complete(
            ModuleResultStatus.SUCCESS,
            WireMap.encode(mapOf("subscription" to WireValue.Integer(id.toLong()))),
        )
    }

    private fun watch(payload: ByteArray): Watch =
        watches[id(payload)] ?: error("Unknown sensor subscription")

    private fun id(payload: ByteArray): Int =
        ((WireMap.decode(payload)["subscription"] as? WireValue.Integer)?.value
            ?: error("Missing sensor subscription")).toInt()

    private fun stop(id: Int) {
        watches.remove(id)?.let {
            manager.unregisterListener(it.listener)
            it.channel.close()
        }
    }

    override fun close() {
        watches.keys.toList().forEach(::stop)
        main.removeCallbacksAndMessages(null)
        reads.toList().forEach(manager::unregisterListener)
        reads.clear()
    }

    private data class Watch(
        val listener: SensorEventListener,
        val channel: WatchChannel,
    )
}
