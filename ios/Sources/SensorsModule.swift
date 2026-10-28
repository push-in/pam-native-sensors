import CoreMotion
import Foundation
import PamNative

public final class SensorsModule: NativeModule, ClosableNativeModule {
    public init() {}

    private let lock = NSLock()
    private var nextId = 1
    private var watches: [Int: SensorWatch] = [:]

    public func invoke(method: String, payload: Data, completion: @escaping ModuleCompletion) {
        do {
            switch method {
            case "read":
                try read(payload, completion)
            case "watch":
                try start(payload, completion)
            case "next":
                try watch(payload).channel.next(completion)
            case "stop":
                stop(try id(payload))
                completion(.success, Data())
            default:
                throw SensorsModuleError("Unknown sensors method \(method)")
            }
        } catch {
            completion(.failure, Data(error.localizedDescription.utf8))
        }
    }

    private func start(_ payload: Data, _ completion: @escaping ModuleCompletion) throws {
        let values = try WireMap.decode(payload)
        guard case let .integer(kind)? = values["type"] else {
            throw SensorsModuleError("Missing sensor type")
        }
        let intervalMs = min(max(values["intervalMs"]?.integerValue ?? 100, 16), 60_000)
        let manager = CMMotionManager()
        let channel = WatchChannel()
        manager.accelerometerUpdateInterval = Double(intervalMs) / 1_000
        manager.gyroUpdateInterval = Double(intervalMs) / 1_000
        manager.magnetometerUpdateInterval = Double(intervalMs) / 1_000
        manager.deviceMotionUpdateInterval = Double(intervalMs) / 1_000
        let handler: (Double, Double, Double, TimeInterval) -> Void = { x, y, z, timestamp in
            channel.offer((try? WireMap.encode([
                "x": .decimal(x),
                "y": .decimal(y),
                "z": .decimal(z),
                "timestamp": .integer(Int64(timestamp * 1_000)),
            ])) ?? Data())
        }
        switch kind {
        case 1:
            guard manager.isAccelerometerAvailable else { throw SensorsModuleError("Accelerometer is unavailable") }
            manager.startAccelerometerUpdates(to: .main) { value, _ in
                if let value { handler(value.acceleration.x, value.acceleration.y, value.acceleration.z, value.timestamp) }
            }
        case 2:
            guard manager.isGyroAvailable else { throw SensorsModuleError("Gyroscope is unavailable") }
            manager.startGyroUpdates(to: .main) { value, _ in
                if let value { handler(value.rotationRate.x, value.rotationRate.y, value.rotationRate.z, value.timestamp) }
            }
        case 3:
            guard manager.isMagnetometerAvailable else { throw SensorsModuleError("Magnetometer is unavailable") }
            manager.startMagnetometerUpdates(to: .main) { value, _ in
                if let value { handler(value.magneticField.x, value.magneticField.y, value.magneticField.z, value.timestamp) }
            }
        case 4:
            guard manager.isDeviceMotionAvailable else { throw SensorsModuleError("Device motion is unavailable") }
            manager.startDeviceMotionUpdates(to: .main) { value, _ in
                if let value { handler(value.attitude.roll, value.attitude.pitch, value.attitude.yaw, value.timestamp) }
            }
        default:
            throw SensorsModuleError("Unknown sensor type \(kind)")
        }
        lock.lock()
        let id = nextId
        nextId += 1
        watches[id] = SensorWatch(manager: manager, channel: channel)
        lock.unlock()
        completion(.success, try WireMap.encode(["subscription": .integer(Int64(id))]))
    }

    /// One reading through a short-lived watch, released on the first value or after `timeoutMs` (100...10000).
    private func read(_ payload: Data, _ completion: @escaping ModuleCompletion) throws {
        let values = try WireMap.decode(payload)
        let timeoutMs = Int(min(max(values["timeoutMs"]?.integerValue ?? 2_000, 100), 10_000))
        var watchPayload = values
        watchPayload["intervalMs"] = .integer(16)
        watchPayload.removeValue(forKey: "timeoutMs")
        var subscription: Int?
        var startFailure: String?
        try start(try WireMap.encode(watchPayload)) { status, data in
            if status == .success, let decoded = try? WireMap.decode(data), let id = decoded["subscription"]?.integerValue {
                subscription = Int(id)
            } else {
                startFailure = String(decoding: data, as: UTF8.self)
            }
        }
        guard let subscription else { throw SensorsModuleError(startFailure ?? "Could not start sensor") }
        let once = SensorReadOnce(completion)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) { [weak self] in
            if once.finish(.failure, Data("Sensor read timed out".utf8)) { self?.stop(subscription) }
        }
        try watch(try WireMap.encode(["subscription": .integer(Int64(subscription))])).channel.next { [weak self] status, data in
            if once.finish(status, data) { self?.stop(subscription) }
        }
    }

    private func watch(_ payload: Data) throws -> SensorWatch {
        let id = try id(payload)
        lock.lock()
        defer { lock.unlock() }
        guard let watch = watches[id] else { throw SensorsModuleError("Unknown sensor subscription") }
        return watch
    }

    private func id(_ payload: Data) throws -> Int {
        let values = try WireMap.decode(payload)
        guard case let .integer(value)? = values["subscription"] else {
            throw SensorsModuleError("Missing sensor subscription")
        }
        return Int(value)
    }

    private func stop(_ id: Int) {
        lock.lock()
        let watch = watches.removeValue(forKey: id)
        lock.unlock()
        watch?.manager.stopAccelerometerUpdates()
        watch?.manager.stopGyroUpdates()
        watch?.manager.stopMagnetometerUpdates()
        watch?.manager.stopDeviceMotionUpdates()
        watch?.channel.close()
    }

    public func close() {
        lock.lock()
        let ids = Array(watches.keys)
        lock.unlock()
        ids.forEach { stop($0) }
    }
}

private final class SensorReadOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let completion: ModuleCompletion

    init(_ completion: @escaping ModuleCompletion) {
        self.completion = completion
    }

    func finish(_ status: ModuleResultStatus, _ data: Data) -> Bool {
        lock.lock()
        let first = !completed
        completed = true
        lock.unlock()
        if first { completion(status, data) }
        return first
    }
}

private struct SensorWatch {
    let manager: CMMotionManager
    let channel: WatchChannel
}

private struct SensorsModuleError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private extension WireValue {
    var integerValue: Int64? {
        if case let .integer(value) = self { return value }
        return nil
    }
}
