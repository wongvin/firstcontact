import Charts
import CoreLocation
import SwiftUI

/// The LoRa link to a gateway, as the gateway reports it every 10 s (#309).
///
/// One section whatever the gateway hears (#359), adapted to it: a sensor's
/// motion link shows Link quality and its chart; a transporter's bit-error test
/// shows Bit error rate, its chart and the test's rows (``LoRaBerRows``). The
/// radio rows -- margin, RSSI, SNR, noise, last packet, age -- are shared.
///
/// Shown once a full record has arrived, or while a walk-test recording runs. A
/// direct board never sends a record, so it shows this section only if a
/// recording happens to be running. The section describes a different link from
/// the RSSI and Link Params rows above it -- those are this phone's Bluetooth link
/// to the gateway -- and its footer says so.
struct LoRaLinkSection: View {
    let device: SophonDevice
    let recorder: WalkTestRecorder
    /// A firmware update is running (#357): its restart would cut a recording off.
    var updating = false
    /// Why a recording can't start: a BER walk without a matching image check
    /// (#359). A closure, evaluated by the walk-test rows only: reading the BER
    /// record in the detail view's body redrew the whole screen every window.
    var startBlocked: () -> String? = { nil }
    /// The bit-error test's image check (#359), and what its rows need.
    let imageCheck: ImageCheck
    /// A firmware update is running on any board: SMP is taken (#357).
    var smpBusy = false
    let findDevice: (String) -> SophonDevice?
    let onCheckImages: () -> Void
    /// Asks for the note or a marker. The alert itself hangs off the detail
    /// view, outside its List (see ``View/walkTestPrompt(_:recorder:)``).
    let onPrompt: (WalkTestPrompt) -> Void

    var body: some View {
        if let record = device.loraLink {
            let peer = device.loraPeer
            let testing = peer == .transporter || peer == .both
            Section {
                // The verdict rows share one timeline so they can dim once records
                // stop arriving: a green 100 % about a link nobody is measuring any
                // more reads as a current verdict (#309 review, finding 5).
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let stale = (device.loraRecordAge(asOf: context.date) ?? 0) > device.loraRecordStaleAfter
                    // A transporter's packets carry its image, not samples, so
                    // LQ has nothing to count: its headline is the bit error
                    // rate instead (#359).
                    if peer != .transporter {
                        LabeledContent("Link quality") {
                            Text((record.linkQuality.map { String(format: "%.1f %%", $0) } ?? "Nothing heard")
                                 + (stale ? " (stale)" : ""))
                                .foregroundStyle(stale ? .secondary : Self.qualityColor(record.linkQuality))
                        }
                    }
                    if testing, let ber = device.loraBer.record {
                        // Its own record's age: a missed BER notify mustn't pass
                        // the last window's figure off as current (review, finding 5).
                        let berStale = (device.loraBer.recordAge(asOf: context.date) ?? 0)
                            > device.loraRecordStaleAfter
                        LabeledContent("Bit error rate") {
                            Text(LoRaBerRows.berText(ber) + (berStale ? " (stale)" : ""))
                                .foregroundStyle(berStale ? .secondary : LoRaBerRows.berColor(ber))
                        }
                    }
                    LabeledContent("Margin") {
                        Text(marginText(record) + (stale ? " (stale)" : ""))
                            .foregroundStyle(stale ? .secondary : Self.marginColor(record.worstMarginDB))
                    }
                }
                if peer == .both {
                    Text("""
                        Hearing a sensor and a transporter on one channel. They collide, and both sets of \
                        figures suffer: give each its own frequency.
                        """)
                        .font(.footnote).foregroundStyle(.orange)
                }
                LabeledContent("LoRa RSSI") { Text(rssiText(record)) }
                LabeledContent("LoRa SNR") { Text(snrText(record)) }
                LabeledContent("Noise floor") {
                    Text(noiseText(record)).foregroundStyle(record.noiseMin == nil ? .secondary : .primary)
                }
                DistanceRow(recorder: recorder)
                LabeledContent("Last packet") {
                    Text(!record.heard ? "None this window"
                         : record.lastPacketMillis.map { "\($0) ms before the window closed" } ?? "25.5 s or more")
                        .foregroundStyle((record.lastPacketMillis ?? .max) > 1000 || !record.heard ? .orange : .primary)
                }
                // Its own timeline: the record's age is the only value here that
                // moves between records, and only a TimelineView may read the
                // clock in a view (reviewer rule 1).
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let age = device.loraRecordAge(asOf: context.date)
                    LabeledContent("Updated") {
                        Text(age.map { SophonDevice.ageText($0) + " ago" } ?? "—")
                            .foregroundStyle((age ?? 0) > device.loraRecordStaleAfter ? .orange : .secondary)
                    }
                }
                LabeledContent("Preset") {
                    Text("\(record.presetName) · SF\(record.spreadingFactor) · 500 kHz"
                         + (record.rxBoost ? " · RX boost" : ""))
                }
                if peer != .transporter {
                    LabeledContent("Sensor") { Text(record.sensorName ?? "Not locked yet") }
                    LabeledContent("This session") {
                        Text("\(device.loraSessionSamples) samples · \(device.loraSessionMissing) missing · "
                             + "\(device.loraSessionBad)\(device.loraSessionBadSaturated ? "+" : "") bad")
                            .font(.callout.monospacedDigit())
                    }
                }
                if testing || device.loraBer.mismatch != nil {
                    LoRaBerRows(device: device, imageCheck: imageCheck, updating: smpBusy,
                                findDevice: findDevice, onCheckImages: onCheckImages)
                }
                if device.loraRecordsMissed > 0 {
                    LabeledContent("Records missed") {
                        Text("\(device.loraRecordsMissed)").foregroundStyle(.orange)
                    }
                }
                if device.loraLinkHistory.count >= 2 {
                    sparklines(peer)
                }
                WalkTestControls(recorder: recorder, updating: updating, startBlocked: startBlocked,
                                 fixedEnd: peer == .transporter ? "transporter" : "sensor", onPrompt: onPrompt)
            } header: {
                Text("LoRa link")
            } footer: {
                Text(footer(peer, windowSeconds: record.windowSeconds))
            }
        } else if let mismatch = device.loraLinkMismatch {
            // Records arrive but this app can't read them (#346): say why, and
            // which side to update, rather than looking like a quiet link.
            Section("LoRa link") {
                Text(mismatch.message(frame: "LoRa Link", firmware: "2.29.0"))
                    .foregroundStyle(.orange)
                if recorder.isRecording {
                    DistanceRow(recorder: recorder)
                    WalkTestControls(recorder: recorder, updating: updating, startBlocked: startBlocked,
                                     onPrompt: onPrompt)
                }
            }
        } else if recorder.isRecording {
            // A gateway that reconnected sends nothing for up to 10 s, and one
            // that came back without its Wio sends nothing at all. The recording
            // keeps running either way, so its controls must not vanish with the
            // record (#309 review, finding 4).
            Section("LoRa link") {
                LabeledContent("Link") {
                    // A sensor or transporter never sends one: the recording runs
                    // against its gateway (#359 review, finding 6).
                    Text(device.sendsOverLoRa ? "Recording on the gateway, where this board's link is measured"
                                              : "Waiting for a LoRa record from this board")
                        .foregroundStyle(.secondary)
                }
                DistanceRow(recorder: recorder)
                WalkTestControls(recorder: recorder, updating: updating, startBlocked: startBlocked,
                                 onPrompt: onPrompt)
            }
        }
    }

    private func footer(_ peer: LoRaPeer, windowSeconds: UInt8) -> String {
        let margin = "Margin is SNR above the level where packets stop decoding; the worst packet's margin "
            + "is the one to watch, because fades lose packets while the average still looks healthy. "
            + "The RSSI row above is this phone's Bluetooth link to the gateway, not the LoRa link."
        switch peer {
        case .transporter, .both:
            return "A transporter sends its own firmware with the LoRa CRC off, and this gateway compares "
                + "every bit with its own copy, over \(windowSeconds) s windows. Damaged packets arrived with "
                + "a bit wrong; lost ones never arrived. Both boards must run the same image: check it "
                + "before a walk. " + margin
        case .sensor, .none:
            return "The sensor's radio link to this gateway, measured by the gateway over "
                + "\(windowSeconds) s windows. " + margin
        }
    }

    // MARK: Sparklines

    /// The headline's chart over the last windows, then the margin's. A
    /// transporter's link charts its bit error rate (#359), a sensor's its LQ.
    private func sparklines(_ peer: LoRaPeer) -> some View {
        let history = Array(device.loraLinkHistory.enumerated())
        let berHistory = Array(device.loraBer.history.enumerated())
        // A fixed 30-window axis ending at the latest window, the same for every
        // chart: a short history fills from the right instead of stretching, and
        // the charts stay aligned window for window.
        // x is windows before the latest, 0 at the right: the window counter is
        // 16 bits and wraps, which a raw number would draw as a line across the
        // chart (final review, finding 2). A point outside the 30 -- a BER record
        // a window ahead of its Link record -- is left out.
        let latest = device.loraLink?.window ?? 0
        let span = SophonDevice.loraLinkHistoryCount
        let windows = (1 - span)...0
        func xValue(_ window: UInt16) -> Int? {
            let back = Int(latest &- window)
            return back < span ? -back : nil
        }
        // A fixed scale from 0 to 0.3 %, rising (to a rounded value) only when a
        // window exceeds it. With Charts' automatic scale a clean link (every
        // window 0 %) has no range, and so no gridlines or labels at all.
        let worstBer = berHistory.compactMap { $0.element.berPercent }.max() ?? 0
        let berMarks = Self.berAxisMarks(worst: worstBer)
        let berTop = berMarks.last ?? Self.berAxisDefault
        return VStack(alignment: .leading, spacing: 6) {
            Text("Last \(span) windows").font(.footnote).foregroundStyle(.secondary)
            if peer != .transporter {
                Chart(history, id: \.offset) { item in
                    if let lq = item.element.linkQuality, let back = xValue(item.element.window) {
                        LineMark(x: .value("Window", back), y: .value("LQ %", lq))
                            .foregroundStyle(by: .value("Series", "Link quality %"))
                        PointMark(x: .value("Window", back), y: .value("LQ %", lq))
                            .symbolSize(12)
                            .foregroundStyle(by: .value("Series", "Link quality %"))
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxis { Self.trailingAxis(values: [0, 50, 100]) }
                .chartXScale(domain: windows)
                .chartXAxis(.hidden)
                .frame(height: 70)
            }
            if peer == .transporter || peer == .both, berHistory.count >= 2 {
                Chart(berHistory, id: \.offset) { item in
                    if let ber = item.element.berPercent, let back = xValue(item.element.window) {
                        LineMark(x: .value("Window", back), y: .value("BER %", ber))
                            .foregroundStyle(by: .value("Series", "Bit error rate %"))
                        PointMark(x: .value("Window", back), y: .value("BER %", ber))
                            .symbolSize(12)
                            .foregroundStyle(by: .value("Series", "Bit error rate %"))
                    }
                }
                // Gridlines with the rate on the right: BER spans decades, so the
                // figure has to be readable off the chart, not just its shape.
                .chartYScale(domain: 0...berTop)
                .chartYAxis { Self.trailingAxis(values: berMarks) }
                .chartXScale(domain: windows)
                .chartXAxis(.hidden)
                .frame(height: 70)
            }
            Chart(history, id: \.offset) { item in
                if let margin = item.element.marginDB, let back = xValue(item.element.window) {
                    LineMark(x: .value("Window", back), y: .value("Margin dB", margin))
                        .foregroundStyle(by: .value("Series", "Margin dB"))
                    PointMark(x: .value("Window", back), y: .value("Margin dB", margin))
                        .symbolSize(12)
                        .foregroundStyle(by: .value("Series", "Margin dB"))
                }
            }
            .chartYAxis { Self.trailingAxis(values: .automatic(desiredCount: 3)) }
            .chartXScale(domain: windows)
            .chartXAxis(.hidden)
            .frame(height: 70)
        }
        .padding(.vertical, 4)
    }

    /// The y-axis every chart here uses: gridlines, values on the right in a
    /// fixed-width column. Equal label widths give equal plot widths, so the
    /// stacked charts line up window for window.
    static func trailingAxis(values: [Double]) -> some AxisContent {
        AxisMarks(position: .trailing, values: values) { value in
            AxisGridLine()
            AxisValueLabel(horizontalSpacing: 2) {
                if let number = value.as(Double.self) {
                    Text(number.formatted(.number.precision(.significantDigits(1...3))))
                        .frame(width: axisLabelWidth, alignment: .leading)
                }
            }
        }
    }

    static func trailingAxis(values: AxisMarkValues) -> some AxisContent {
        AxisMarks(position: .trailing, values: values) { value in
            AxisGridLine()
            AxisValueLabel(horizontalSpacing: 2) {
                if let number = value.as(Double.self) {
                    Text(number.formatted(.number.precision(.significantDigits(1...3))))
                        .frame(width: axisLabelWidth, alignment: .leading)
                }
            }
        }
    }

    /// Wide enough for "0.15" or "-12" at the caption size Charts uses.
    static let axisLabelWidth: CGFloat = 24

    /// The BER chart's default top, in percent, marked every 0.1 %.
    static let berAxisDefault = 0.3

    /// The BER axis's gridlines: 0, 0.1, 0.2, 0.3 % by default; above that,
    /// about three steps of a round size (1, 2 or 5 x 10^n) that reach the worst.
    static func berAxisMarks(worst: Double) -> [Double] {
        let step = worst <= berAxisDefault ? 0.1 : niceCeiling(worst / 3)
        let top = worst <= berAxisDefault ? berAxisDefault : (worst / step).rounded(.up) * step
        return stride(from: 0, through: top + step / 2, by: step).map { ($0 / step).rounded() * step }
    }

    /// 1, 2 or 5 times a power of ten, at or above `value`; at least 0.01 %.
    static func niceCeiling(_ value: Double) -> Double {
        let floor = max(value, 0.01)
        let magnitude = pow(10, (log10(floor)).rounded(.down))
        for step in [1.0, 2.0, 5.0, 10.0] where step * magnitude >= floor * 0.999_999 {
            return step * magnitude
        }
        return 10 * magnitude
    }

    // MARK: Formatting

    private func marginText(_ link: LoRaLinkRecord) -> String {
        guard let margin = link.marginDB,
              let limit = LoRaLinkRecord.snrLimit(spreadingFactor: link.spreadingFactor) else {
            return "—"
        }
        let worst = link.worstMarginDB.map { String(format: " · worst %+.1f", $0) } ?? ""
        return String(format: "%+.1f dB avg", margin) + worst
            + String(format: " (floor %.1f dB at SF%d)", limit, link.spreadingFactor)
    }

    private func rssiText(_ link: LoRaLinkRecord) -> String {
        guard link.heard else { return "—" }
        var text = "\(link.rssiAvg) dBm (min \(link.rssiMin))"
        if let sensitivity = link.sensitivityDBm {
            text += " · \(Int(link.rssiAvg) - sensitivity) dB above sensitivity"
        }
        // Signal against the measured noise (#336), independent of LoRa's own SNR.
        // Gated on the minimum, like the Noise floor row, so the two agree.
        if link.noiseMin != nil, let noise = link.noiseMedian {
            text += " · \(Int(link.rssiAvg) - Int(noise)) dB above noise"
        }
        return text
    }

    /// The receiver's own noise, sampled between packets (#336): the minimum is
    /// the clean floor, the median shows interference that lasts.
    private func noiseText(_ link: LoRaLinkRecord) -> String {
        // Older firmware, or no sample this window: either way, nothing to show.
        guard let floor = link.noiseMin else { return "Not measured" }
        return "\(floor) dBm" + (link.noiseMedian.map { " (median \($0))" } ?? "")
    }

    private func snrText(_ link: LoRaLinkRecord) -> String {
        guard link.heard else { return "—" }
        return String(format: "%+d dB (min %+d)", Int(link.snrAvg), Int(link.snrMin))
    }

    static func qualityColor(_ lq: Double?) -> Color {
        guard let lq else { return .red } // nothing heard is the worst result
        if lq >= 99 { return .green }
        if lq >= 90 { return .orange }
        return .red
    }

    /// Coloured by the WORST packet's margin, not the average: packets are lost
    /// when a fade takes the SNR below the floor, which a healthy-looking
    /// average hides (first hardware walk, #309).
    static func marginColor(_ worstMargin: Double?) -> Color {
        guard let worstMargin else { return .secondary }
        if worstMargin >= 3 { return .green }
        if worstMargin >= 0 { return .orange }
        return .red
    }
}

/// The walk-test recorder's rows, as their own view so that only they observe
/// the location stream: a fix arrives about once a second, while the LoRa rows
/// and charts change once per 10 s (#309 review, finding 3).
private struct WalkTestControls: View {
    let recorder: WalkTestRecorder
    let updating: Bool
    let startBlocked: () -> String?
    /// The fixed end the pin marks: the sensor, or a transporter in a BER walk.
    var fixedEnd = "sensor"
    let onPrompt: (WalkTestPrompt) -> Void

    var body: some View {
        if recorder.isRecording {
            LabeledContent("Recording") {
                Text("\(recorder.rowCount) windows" + (recorder.part > 1 ? " · part \(recorder.part)" : ""))
                    .font(.callout.monospacedDigit())
            }
            Button("Add marker…") { onPrompt(.marker) }
            Button("Drop pin here (at the \(fixedEnd))") { recorder.dropPin() }
                .disabled(recorder.lastFix == nil)
            Button("Stop recording", role: .destructive) { recorder.stop() }
        } else {
            let blocked = startBlocked()
            Button("Start walk-test recording") { onPrompt(.note) }
                .disabled(updating || blocked != nil)
            if let blocked {
                Text(blocked).font(.footnote).foregroundStyle(.orange)
            }
            if !recorder.exportURLs.isEmpty {
                ShareLink(items: recorder.exportURLs) {
                    Label(shareLabel, systemImage: "square.and.arrow.up")
                }
            }
        }
        if recorder.writeFailed {
            Text("The recording could not be written to storage.")
                .font(.footnote)
                .foregroundStyle(.red)
        }
        if recorder.isLocationDenied {
            Text("Location access is off, so recordings have no positions. Turn it on in Settings › Sophon.")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private var shareLabel: String {
        let files = recorder.exportURLs.count
        return "Share last recording (\(recorder.rowCount) windows" + (files > 1 ? ", \(files) files)" : ")")
    }
}

/// What the walker types at Start (the setup note, into the preamble) or while
/// recording (a marker, as an event row) -- #335.
enum WalkTestPrompt: Identifiable {
    case note
    case marker

    var id: Self { self }
}

extension View {
    /// The walk-test text prompts. Attach outside any List, for the reason
    /// ``View/configEditor(item:device:onWrite:)`` gives: a presentation hung off a
    /// List row is torn down when the List rebuilds it, here every second.
    func walkTestPrompt(_ prompt: Binding<WalkTestPrompt?>, recorder: WalkTestRecorder) -> some View {
        modifier(WalkTestPromptModifier(prompt: prompt, recorder: recorder))
    }
}

private struct WalkTestPromptModifier: ViewModifier {
    @Binding var prompt: WalkTestPrompt?
    let recorder: WalkTestRecorder
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert(prompt == .marker ? "Add marker" : "Start walk-test recording",
                   isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }),
                   presenting: prompt) { kind in
                TextField(kind == .note ? "e.g. receiver in a pocket, 6 dBi both ends" : "e.g. antenna in hand",
                          text: $text)
                Button("Cancel", role: .cancel) {}
                Button(kind == .note ? "Start" : "Add") {
                    switch kind {
                    case .note: recorder.start(note: text)
                    case .marker: recorder.addMarker(text)
                    }
                }
            } message: { kind in
                Text(kind == .note
                     ? "Describe the setup: antennas, where the receiver is carried. Optional. With peer Any, "
                        + "the gateway is set to its sensor for the walk: it restarts once now and once at Stop."
                     : "What changed? It is logged at this moment.")
            }
            .onChange(of: prompt) { _, new in
                if new != nil { text = "" }
            }
    }
}

/// Distance from the pin -- or from the recording's start position if no pin was
/// dropped -- to the latest fix. Its own view, like ``WalkTestControls``, so the
/// ~1 Hz location stream redraws this row alone. Location runs only while a
/// walk-test recording does, so outside one there is no distance to show.
private struct DistanceRow: View {
    let recorder: WalkTestRecorder

    var body: some View {
        LabeledContent(recorder.pinIsAutomatic ? "Distance from start" : "Distance from pin") {
            Text(text)
                .font(.callout.monospacedDigit())
                .foregroundStyle(recorder.distanceFromPin == nil ? .secondary : .primary)
        }
    }

    private var text: String {
        guard recorder.isRecording else { return "Start a walk-test recording to measure" }
        guard let distance = recorder.distanceFromPin, let fix = recorder.lastFix else {
            return "Waiting for a location fix"
        }
        return String(format: "%.0f m (±%.0f m)", distance, fix.horizontalAccuracy)
    }
}
