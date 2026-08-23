import CoreMotion
import Foundation
import os

/// CoreMotion accelerometer + gyroscope, converted into the frame's wire units.
///
/// Counterpart to `zephyr/sophon/src/imu.c`. Read the two side by side: the unit
/// conversions, the saturation and the sample pacing are all meant to match, and
/// where they cannot, the comment says why.
@MainActor
final class MotionSource {
    /// One sample, already in wire units so the caller does no arithmetic —
    /// exactly like `struct sophon_imu_sample`.
    struct Sample {
        /// CoreMotion's own monotonic clock, seconds since device boot. Used as
        /// the `t_ms` base because it is immune to wall-clock changes, which is
        /// the same property `k_uptime_get_32()` has on the board.
        let timestamp: TimeInterval
        let ax: Int16, ay: Int16, az: Int16   // milli-g
        let gx: Int16, gy: Int16, gz: Int16   // centi-degrees/second
    }

    /// The board is 52 Hz nominal because the LSM6DSL's ODR grid has no 50 Hz
    /// step. Nothing forces that number here — CoreMotion takes an arbitrary
    /// interval — but matching it is the point of a simulator.
    ///
    /// As on the board, this is the rate *requested*, not the rate delivered.
    /// See `measuredRateHz`.
    static let nominalRateHz = 52.0

    /// g → milli-g.
    private static let gToMilliG = 1000.0
    /// rad/s → centi-degrees/second: 100 × 180/π. The same 5729.578 the firmware
    /// applies as 5729578/1e9 against micro-rad/s in `gyro_to_cdps()`.
    private static let radPerSecToCentiDegPerSec = 5729.577951308232

    private let manager = CMMotionManager()
    private let log = Logger(subsystem: "com.vwong.Sophon", category: "motion")

    private var rateWindowStart: TimeInterval?
    private var rateWindowCount = 0
    private(set) var measuredRateHz: Double?

    /// False on the iOS Simulator, which has no motion hardware.
    var isAvailable: Bool { manager.isAccelerometerAvailable && manager.isGyroAvailable }

    /// Starts sampling. `handler` is called once per accelerometer sample, on the
    /// main actor.
    ///
    /// When no hardware exists, falls back to 1 Hz zero-filled samples rather
    /// than going quiet — the same choice `main.c` makes for a missing IMU, and
    /// for the same reason: a link that is up and carrying obviously-empty frames
    /// is diagnosable, and a dead one is not.
    func start(_ handler: @escaping (Sample) -> Void) {
        resetRate()

        guard isAvailable else {
            log.warning("no motion hardware; falling back to 1 Hz zero-filled samples")
            startFallback(handler)
            return
        }

        let interval = 1.0 / Self.nominalRateHz
        manager.accelerometerUpdateInterval = interval
        // Both channels at the same rate, mirroring imu.c's BUILD_ASSERT that
        // the accelerometer and gyroscope ODRs match. There, a mismatch makes the
        // shared data-ready line fire at the faster rate with the slower channel
        // repeating stale values; here it would simply widen the pairing skew
        // below. Same fix either way.
        manager.gyroUpdateInterval = interval

        // Handler-less: this populates `manager.gyroData` for polling without
        // adding a second callback at 52 Hz.
        manager.startGyroUpdates()

        // The accelerometer callback is the pacer, which is the closest analogue
        // available to the board's data-ready interrupt: one frame per sample the
        // sensor actually produced, so `seq` indexes sample periods rather than
        // timer ticks. Driving this from a Timer instead would reintroduce
        // precisely the two-clock resampling that PROTOCOL.md rejects in
        // "Why 52 Hz and not 50".
        manager.startAccelerometerUpdates(to: .main) { [weak self] data, error in
            // Safe because the queue three lines up is .main. assumeIsolated
            // traps if that ever stops being true, which is the behaviour we
            // want from a mistake like that.
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error {
                    self.log.error("accelerometer: \(error.localizedDescription, privacy: .public)")
                    return
                }
                guard let data else { return }
                handler(self.sample(from: data))
            }
        }
    }

    func stop() {
        manager.stopAccelerometerUpdates()
        manager.stopGyroUpdates()
        fallbackTask?.cancel()
        fallbackTask = nil
        resetRate()
    }

    // MARK: - Conversion

    private func sample(from data: CMAccelerometerData) -> Sample {
        note(data.timestamp)

        // The latest gyro reading rather than one captured with this accel
        // sample: CMMotionManager exposes the two as separate streams.
        //
        // The pairing skew this introduces is bounded by one sample period, and
        // it is faithful rather than sloppy — the LSM6DSL ORs two independent
        // ODRs onto one data-ready line, and imu.c's handler reads both channels
        // after a single fetch with exactly the same caveat.
        //
        // Using deviceMotion would synchronise them, at the cost of reporting
        // fused, bias-corrected estimates instead of raw readings. The board
        // sends raw. Match the board.
        let rotation = manager.gyroData?.rotationRate

        return Sample(
            timestamp: data.timestamp,
            ax: MotionFrame.wireValue(data.acceleration.x * Self.gToMilliG),
            ay: MotionFrame.wireValue(data.acceleration.y * Self.gToMilliG),
            az: MotionFrame.wireValue(data.acceleration.z * Self.gToMilliG),
            gx: MotionFrame.wireValue((rotation?.x ?? 0) * Self.radPerSecToCentiDegPerSec),
            gy: MotionFrame.wireValue((rotation?.y ?? 0) * Self.radPerSecToCentiDegPerSec),
            gz: MotionFrame.wireValue((rotation?.z ?? 0) * Self.radPerSecToCentiDegPerSec)
        )
    }

    // MARK: - No-hardware fallback

    private var fallbackTask: Task<Void, Never>?

    private func startFallback(_ handler: @escaping (Sample) -> Void) {
        fallbackTask = Task { [weak self] in
            var elapsed: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                elapsed += 1
                self.note(elapsed)
                handler(Sample(timestamp: elapsed,
                               ax: 0, ay: 0, az: 0, gx: 0, gy: 0, gz: 0))
            }
        }
    }

    // MARK: - Measured rate

    /// Measured over CoreMotion's own timestamps, never the wall clock.
    ///
    /// Worth having for the same reason the board's rate is worth measuring: the
    /// requested interval is a request. iOS rounds it to what the hardware and
    /// the scheduler will actually do, exactly as the LSM6DSL delivers 54.3 Hz
    /// when asked for 52.
    private func note(_ timestamp: TimeInterval) {
        guard let start = rateWindowStart else {
            rateWindowStart = timestamp
            rateWindowCount = 0
            return
        }

        rateWindowCount += 1
        let span = timestamp - start
        guard span >= 1.0 else { return }

        measuredRateHz = Double(rateWindowCount) / span
        rateWindowStart = timestamp
        rateWindowCount = 0
    }

    private func resetRate() {
        rateWindowStart = nil
        rateWindowCount = 0
        measuredRateHz = nil
    }
}
