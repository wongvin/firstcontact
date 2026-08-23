import Foundation
import UIKit
import os

/// Ties the motion source to the peripheral: builds frames, owns `seq` and
/// `t_ms`, and applies the send policy.
///
/// Counterpart to `zephyr/sophon/src/main.c`. The division of labour is the same
/// — this file decides *whether and what* to send, `SophonPeripheral` decides
/// only *how* — which is what keeps the `seq` rules in exactly one place.
@MainActor
@Observable
final class SophonSimulator {
    /// Everything the UI reads, republished as one snapshot.
    ///
    /// Hot state is deliberately kept out of observation. A 52 Hz `@Observable`
    /// write would invalidate SwiftUI 52 times a second on the very main thread
    /// that paces the radio, so the render would compete with the stream and
    /// manufacture exactly the jitter this project exists to measure.
    struct Display: Equatable {
        var name = ""
        var radio: RadioState = .unknown
        var isAdvertising = false
        var subscribers = 0
        var maximumUpdateLength: Int?
        /// What CoreMotion delivers.
        var sensorRateHz: Double?
        /// What the stack accepted. Diverges from `sensorRateHz` exactly when
        /// frames are dropped, which is what makes the drop control legible.
        var notifyRateHz: Double?
        var lastFrame: MotionFrame?
        var stats = TxStats(sent: 0, noConn: 0, noBuffer: 0, other: 0)
        var queueFullRecoveries = 0
        var keepAliveAuthorized = false
        var motionAvailable = true
    }

    private(set) var display = Display()
    private(set) var isRunning = false

    // MARK: Bench controls

    /// Percentage of frames to drop before they reach the radio.
    ///
    /// Not a toy. iOS's transmit queue is generous enough that `updateValue`
    /// essentially never fails at this size and rate, so `noBuffer` would sit at
    /// zero forever and the viewer's attribution would remain untested. This
    /// reproduces the firmware's -ENOMEM path on demand, and makes
    /// `seqGaps == noBuffer` checkable against a known truth for the first time.
    ///
    /// It can only fake "taken but never sent". Genuine air loss — sent and lost
    /// — cannot be synthesised from this side.
    var dropPercent = 0

    /// Emit zeroed axes, standing in for a board whose IMU failed to start, so
    /// the viewer's `isAxesZero` path can be exercised.
    var pretendNoIMU = false

    /// Keep the screen awake while simulating. On by default so the common case
    /// needs no background path at all; turn it off to test that the keep-alive
    /// actually holds under lock.
    var keepScreenAwake = true {
        didSet { applyIdleTimer() }
    }

    let peripheral = SophonPeripheral()
    private let motion = MotionSource()
    private let keepAlive = BackgroundKeepAlive()
    private let log = Logger(subsystem: "com.vwong.Sophon", category: "simulator")

    @ObservationIgnored private var seq: UInt16 = 0
    @ObservationIgnored private var baseTimestamp: TimeInterval?
    @ObservationIgnored private var lastFrame: MotionFrame?
    @ObservationIgnored private var notifyWindowStart: TimeInterval?
    @ObservationIgnored private var notifyWindowCount = 0
    @ObservationIgnored private var notifyRateHz: Double?
    @ObservationIgnored private var publishTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let name = SimulatorIdentity.advertisedName()
        reboot()

        keepAlive.start()
        peripheral.start(localName: name)
        motion.start { [weak self] sample in self?.onSample(sample) }
        applyIdleTimer()

        display.name = name
        publishTask = Task { [weak self] in
            // ~10 Hz. Fast enough that the numbers look live, slow enough that
            // the render is not competing with the sample loop.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                self.publish()
            }
        }

        log.info("simulator started as \(name, privacy: .public)")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        publishTask?.cancel()
        publishTask = nil
        motion.stop()
        peripheral.stop()
        keepAlive.stop()
        UIApplication.shared.isIdleTimerDisabled = false

        publish()
        log.info("simulator stopped")
    }

    /// Restart the simulated board in place: `seq` back to 0, a fresh `t_ms`
    /// base, counters cleared — but the BLE link untouched.
    ///
    /// The link part is the whole point. Toggling out of simulator mode drops the
    /// connection, and the viewer's `resetLinkStats()` runs on the next connect
    /// and zeroes `restartsWithoutDisconnect` before the new `t_ms` is ever compared to the
    /// old one. So mode-toggling cannot exercise restart detection. Only this
    /// can: uptime running backwards on a link that never went away is exactly
    /// the signal `SophonDevice` watches for.
    func reboot() {
        seq = 0
        baseTimestamp = nil
        lastFrame = nil
        notifyWindowStart = nil
        notifyWindowCount = 0
        notifyRateHz = nil
        peripheral.resetCounters()
        log.info("simulated board rebooted")
    }

    // MARK: - Sampling

    private func onSample(_ sample: MotionSource.Sample) {
        // Unconditional, subscribers or not: it keeps the measured sensor rate
        // honest and the t_ms base anchored to the first sample after start.
        // imu.c's fetch is unconditional too, though for a harder reason — there,
        // skipping it strands the data-ready line and kills the stream for good.
        if baseTimestamp == nil { baseTimestamp = sample.timestamp }

        guard peripheral.subscriberCount > 0 else {
            // seq deliberately does not advance while nobody is subscribed: no
            // data was expected, so the jump on the next subscribe is not a
            // dropped frame. PROTOCOL.md, "What seq means".
            return
        }

        seq &+= 1

        let elapsed = Int64(((sample.timestamp - (baseTimestamp ?? sample.timestamp)) * 1000).rounded())
        let frame = MotionFrame(
            seq: seq,
            // truncatingIfNeeded rather than an init that can trap. Wrapping at
            // ~49.7 days is the same wrap the firmware's uint32 has.
            tMillis: UInt32(truncatingIfNeeded: elapsed),
            ax: pretendNoIMU ? 0 : sample.ax,
            ay: pretendNoIMU ? 0 : sample.ay,
            az: pretendNoIMU ? 0 : sample.az,
            gx: pretendNoIMU ? 0 : sample.gx,
            gy: pretendNoIMU ? 0 : sample.gy,
            gz: pretendNoIMU ? 0 : sample.gz
        )
        lastFrame = frame

        // From here seq is committed. Whatever happens next it is never rewound:
        // a sample taken and not delivered is a hole the receiver has to be able
        // to see, and ble.c makes the same promise.
        if dropPercent > 0, Int.random(in: 0 ..< 100) < dropPercent {
            peripheral.noteArtificialDrop()
            return
        }

        if peripheral.notify(frame) { noteNotified(sample.timestamp) }
    }

    private func noteNotified(_ timestamp: TimeInterval) {
        guard let start = notifyWindowStart else {
            notifyWindowStart = timestamp
            notifyWindowCount = 0
            return
        }

        notifyWindowCount += 1
        let span = timestamp - start
        guard span >= 1.0 else { return }

        notifyRateHz = Double(notifyWindowCount) / span
        notifyWindowStart = timestamp
        notifyWindowCount = 0
    }

    // MARK: - Publishing

    private func publish() {
        display.radio = peripheral.radio
        display.isAdvertising = peripheral.isAdvertising
        display.subscribers = peripheral.subscriberCount
        display.maximumUpdateLength = peripheral.maximumUpdateLength
        display.sensorRateHz = motion.measuredRateHz
        display.notifyRateHz = notifyRateHz
        display.lastFrame = lastFrame
        display.stats = peripheral.counters
        display.queueFullRecoveries = peripheral.queueFullRecoveries
        display.keepAliveAuthorized = keepAlive.isAuthorized
        display.motionAvailable = motion.isAvailable
    }

    private func applyIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = isRunning && keepScreenAwake
    }
}
