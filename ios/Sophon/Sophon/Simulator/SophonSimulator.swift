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
        /// How often iOS drains the transmit queue, and how much it takes each
        /// time. In the saturated regime this is the connection interval and the
        /// notifications-per-event figure -- see SophonPeripheral (#248).
        var readyGapMeanMillis: Double?
        var readyGapMinMillis: Double?
        var readyGapMaxMillis: Double?
        var acceptedPerCycleMean: Double?
        /// CoreMotion inter-arrival, which says whether generation is even or
        /// bursty (#248).
        var sampleGapMeanMillis: Double?
        var sampleGapMinMillis: Double?
        var sampleGapMaxMillis: Double?
        /// Depth of the simulator's own transmit queue, and frames it dropped --
        /// a subset of noBuffer, kept separate here where the cause is
        /// actionable (#255).
        var queueDepth = 0
        var localQueueDrops = 0
        /// What the drain loop actually achieves, not what it requested.
        var drainPeriodMeanMillis: Double?
        var drainPeriodMinMillis: Double?
        var drainPeriodMaxMillis: Double?
        var keepAliveAuthorized = false
        var motionAvailable = true
    }

    private(set) var display = Display()
    private(set) var isRunning = false

    /// Frames waiting to be sent, oldest first.
    ///
    /// The firmware has had one of these all along (`TX_QUEUE_DEPTH 8` in
    /// `main.c`); the simulator forwarded CoreMotion straight to the radio, and
    /// #248 measured what that costs: CoreMotion delivers clumped — 0.2 to
    /// 55.3 ms around a 20 ms mean — so bursts hit iOS's transmit queue and 8.80%
    /// of frames were refused, on a link that sat idle for seconds at a time.
    ///
    /// **Depth matches the firmware's 8** so the two behave alike under
    /// congestion. At ~50 Hz that is ~160 ms of slack, the same order as the
    /// board's ~150 ms.
    private var pendingFrames: [MotionFrame] = []
    private static let txQueueDepth = 8

    /// Interval between sends.
    ///
    /// **The queue alone would not have fixed this.** A literal copy of the
    /// firmware drains in a `while` loop that empties the queue in one go
    /// (`tx_work_handler`), so a burst would pass straight through unchanged.
    /// The board can afford that because DRDY is hardware-timed and even; the
    /// simulator's source is not, so the drain has to be *paced*.
    ///
    /// 18 ms was chosen as ~55 Hz against a ~50 Hz source. **That assumption was
    /// wrong and is why the first attempt failed**: measured, the queue sat
    /// pinned at 7-8 of 8 and every drop was local, meaning the loop was slower
    /// than generation. `Task.sleep` under iOS scheduling does not deliver the
    /// interval it is asked for, and the requested value was never checked
    /// against the achieved one.
    ///
    /// The interval is kept, but the loop no longer depends on hitting it: see
    /// `drainBudget`. The achieved period is now measured rather than assumed.
    private static let drainInterval = Duration.milliseconds(18)

    /// Frames a single tick may send.
    ///
    /// More than one, so the drain keeps up even when the timer runs slow: at an
    /// achieved ~20 ms that is ~100 Hz against a ~50 Hz source, so the queue
    /// empties and stays near zero. Small enough that catching up sends a pair,
    /// not a clump -- CoreMotion's own bursts arrived 0.2 ms apart, which is what
    /// this exists to smooth.
    ///
    /// With the queue near empty most ticks carry 0 or 1 frames anyway, so the
    /// budget only applies while recovering.
    private static let drainBudget = 2

    private var drainTask: Task<Void, Never>?

    /// Achieved period of the drain loop -- what `Task.sleep` actually delivers,
    /// as opposed to what it was asked for. The first attempt at this fix failed
    /// on exactly that difference.
    private(set) var drainPeriodMeanMillis: Double?
    private(set) var drainPeriodMinMillis: Double?
    private(set) var drainPeriodMaxMillis: Double?
    private var lastDrainAt: ContinuousClock.Instant?
    private var drainPeriodTotalMillis: Double = 0
    private var drainPeriodCount = 0

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

        // Owned by the model, like publishTask and for the same reason: a view's
        // .task is cancelled when a NavigationStack pushes over it (#235), and
        // this must keep running whatever is on screen.
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.drainInterval)
                guard let self, !Task.isCancelled else { return }
                self.drainTick()
            }
        }

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
        drainTask?.cancel()
        drainTask = nil
        pendingFrames.removeAll()
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

    /// Inter-arrival of CoreMotion deliveries: mean, shortest, longest, in ms.
    ///
    /// `sensorRateHz` is an average and cannot show clumping — 50 Hz delivered in
    /// bursts of five every 100 ms averages to 50 Hz exactly like an even stream.
    /// That distinction decides what #248 is about: an even stream refused at
    /// 8.8% is a link capacity ceiling, whereas a bursty stream refused at 8.8%
    /// is the transmit queue being unable to absorb a burst the link could
    /// otherwise carry on average.
    ///
    /// Monotonic clock, so a wall-clock adjustment cannot skew it.
    private(set) var sampleGapMeanMillis: Double?
    private(set) var sampleGapMinMillis: Double?
    private(set) var sampleGapMaxMillis: Double?
    private var lastSampleAt: ContinuousClock.Instant?
    private var lastSampleTimestamp: TimeInterval?
    private var sampleGapTotalMillis: Double = 0
    private var sampleGapCount = 0

    private func recordSampleArrival() {
        let now = ContinuousClock.now
        defer { lastSampleAt = now }
        guard let last = lastSampleAt else { return }

        let elapsed = (now - last).components
        let gap = Double(elapsed.seconds) * 1000
            + Double(elapsed.attoseconds) / 1_000_000_000_000_000

        sampleGapTotalMillis += gap
        sampleGapCount += 1
        sampleGapMeanMillis = sampleGapTotalMillis / Double(sampleGapCount)
        sampleGapMinMillis = min(sampleGapMinMillis ?? gap, gap)
        sampleGapMaxMillis = max(sampleGapMaxMillis ?? gap, gap)
    }

    private func onSample(_ sample: MotionSource.Sample) {
        recordSampleArrival()

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

        // Enqueue rather than send. seq has already advanced, so a drop here is
        // a hole the receiver can see -- the same promise main.c makes when
        // k_msgq_put fails, and the reason nothing is ever rewound.
        guard pendingFrames.count < Self.txQueueDepth else {
            peripheral.noteLocalQueueDrop()
            return
        }
        pendingFrames.append(frame)
        lastSampleTimestamp = sample.timestamp
    }

    /// Sends up to `drainBudget` queued frames, and records what the loop is
    /// actually achieving.
    private func drainTick() {
        recordDrainPeriod()

        for _ in 0 ..< Self.drainBudget {
            guard !pendingFrames.isEmpty else { return }
            let frame = pendingFrames.removeFirst()
            if peripheral.notify(frame), let ts = lastSampleTimestamp {
                noteNotified(ts)
            }
        }
    }

    private func recordDrainPeriod() {
        let now = ContinuousClock.now
        defer { lastDrainAt = now }
        guard let last = lastDrainAt else { return }

        let elapsed = (now - last).components
        let period = Double(elapsed.seconds) * 1000
            + Double(elapsed.attoseconds) / 1_000_000_000_000_000

        drainPeriodTotalMillis += period
        drainPeriodCount += 1
        drainPeriodMeanMillis = drainPeriodTotalMillis / Double(drainPeriodCount)
        drainPeriodMinMillis = min(drainPeriodMinMillis ?? period, period)
        drainPeriodMaxMillis = max(drainPeriodMaxMillis ?? period, period)
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
        display.readyGapMeanMillis = peripheral.readyGapMeanMillis
        display.readyGapMinMillis = peripheral.readyGapMinMillis
        display.readyGapMaxMillis = peripheral.readyGapMaxMillis
        display.acceptedPerCycleMean = peripheral.acceptedPerCycleMean
        display.queueDepth = pendingFrames.count
        display.localQueueDrops = peripheral.localQueueDrops
        display.drainPeriodMeanMillis = drainPeriodMeanMillis
        display.drainPeriodMinMillis = drainPeriodMinMillis
        display.drainPeriodMaxMillis = drainPeriodMaxMillis
        display.sampleGapMeanMillis = sampleGapMeanMillis
        display.sampleGapMinMillis = sampleGapMinMillis
        display.sampleGapMaxMillis = sampleGapMaxMillis
        display.keepAliveAuthorized = keepAlive.isAuthorized
        display.motionAvailable = motion.isAvailable
    }

    private func applyIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = isRunning && keepScreenAwake
    }
}
