import Charts
import CoreLocation
import SwiftUI

/// The sensor → gateway LoRa link, as a gateway reports it every 10 s (#309).
///
/// Shown once a full record has arrived, or while a walk-test recording runs. A
/// direct board never sends a record, so it shows this section only if a
/// recording happens to be running. The section describes a different link from
/// the RSSI and Link Params rows above it -- those are this phone's Bluetooth link
/// to the gateway -- and its footer says so.
struct LoRaLinkSection: View {
    let device: SophonDevice
    let recorder: WalkTestRecorder

    var body: some View {
        if let record = device.loraLink {
            Section {
                // The verdict rows share one timeline so they can dim once records
                // stop arriving: a green 100 % about a link nobody is measuring any
                // more reads as a current verdict (#309 review, finding 5).
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let stale = (device.loraRecordAge(asOf: context.date) ?? 0) > SophonDevice.loraRecordStaleAfter
                    LabeledContent("Link quality") {
                        Text((record.linkQuality.map { String(format: "%.1f %%", $0) } ?? "Nothing heard")
                             + (stale ? " (stale)" : ""))
                            .foregroundStyle(stale ? .secondary : Self.qualityColor(record.linkQuality))
                    }
                    LabeledContent("Margin") {
                        Text(marginText(record) + (stale ? " (stale)" : ""))
                            .foregroundStyle(stale ? .secondary : Self.marginColor(record.worstMarginDB))
                    }
                }
                LabeledContent("LoRa RSSI") { Text(rssiText(record)) }
                LabeledContent("LoRa SNR") { Text(snrText(record)) }
                DistanceRow(recorder: recorder)
                LabeledContent("Last packet") {
                    Text(record.heard
                         ? "\(record.lastPacketMillis) ms before the window closed" : "None this window")
                        .foregroundStyle(record.lastPacketMillis > 1000 || !record.heard ? .orange : .primary)
                }
                // Its own timeline: the record's age is the only value here that
                // moves between records, and only a TimelineView may read the
                // clock in a view (reviewer rule 1).
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let age = device.loraRecordAge(asOf: context.date)
                    LabeledContent("Updated") {
                        Text(age.map { SophonDevice.ageText($0) + " ago" } ?? "—")
                            .foregroundStyle((age ?? 0) > SophonDevice.loraRecordStaleAfter ? .orange : .secondary)
                    }
                }
                LabeledContent("Sensor") { Text(record.sensorName ?? "Not locked yet") }
                LabeledContent("Preset") {
                    Text("\(record.presetName) · SF\(record.spreadingFactor) · 500 kHz"
                         + (record.rxBoost ? " · RX boost" : ""))
                }
                LabeledContent("This session") {
                    Text("\(device.loraSessionSamples) samples · \(device.loraSessionMissing) missing · "
                         + "\(device.loraSessionBad) bad")
                        .font(.callout.monospacedDigit())
                }
                if device.loraRecordsMissed > 0 {
                    LabeledContent("Records missed") {
                        Text("\(device.loraRecordsMissed)").foregroundStyle(.orange)
                    }
                }
                if device.loraLinkHistory.count >= 2 {
                    sparklines
                }
                WalkTestControls(recorder: recorder)
            } header: {
                Text("LoRa link")
            } footer: {
                Text("The sensor's radio link to this gateway, measured by the gateway over 10 s windows. "
                     + "Margin is SNR above the level where packets stop decoding; the worst packet's margin "
                     + "is the one to watch, because fades lose packets while the average still looks "
                     + "healthy. The RSSI row above is this phone's Bluetooth link "
                     + "to the gateway, not the LoRa link.")
            }
        } else if recorder.isRecording {
            // A gateway that reconnected sends nothing for up to 10 s, and one
            // that came back without its Wio sends nothing at all. The recording
            // keeps running either way, so its controls must not vanish with the
            // record (#309 review, finding 4).
            Section("LoRa link") {
                LabeledContent("Link") {
                    Text("Waiting for a LoRa record from this board").foregroundStyle(.secondary)
                }
                DistanceRow(recorder: recorder)
                WalkTestControls(recorder: recorder)
            }
        }
    }

    // MARK: Sparklines

    private var sparklines: some View {
        let history = Array(device.loraLinkHistory.enumerated())
        return VStack(alignment: .leading, spacing: 6) {
            Text("Last \(history.count) windows").font(.footnote).foregroundStyle(.secondary)
            Chart(history, id: \.offset) { item in
                if let lq = item.element.linkQuality {
                    LineMark(x: .value("Window", item.offset), y: .value("LQ %", lq))
                        .foregroundStyle(by: .value("Series", "Link quality %"))
                }
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .frame(height: 70)
            Chart(history, id: \.offset) { item in
                if let margin = item.element.marginDB {
                    LineMark(x: .value("Window", item.offset), y: .value("Margin dB", margin))
                        .foregroundStyle(by: .value("Series", "Margin dB"))
                }
            }
            .chartXAxis(.hidden)
            .frame(height: 70)
        }
        .padding(.vertical, 4)
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
        return text
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

    var body: some View {
        if recorder.isRecording {
            LabeledContent("Recording") {
                Text("\(recorder.rowCount) windows").font(.callout.monospacedDigit())
            }
            Button("Drop pin here (at the sensor)") { recorder.dropPin() }
                .disabled(recorder.lastFix == nil)
            Button("Stop recording", role: .destructive) { recorder.stop() }
        } else {
            Button("Start walk-test recording") { recorder.start() }
            if let url = recorder.exportURL {
                ShareLink(item: url) {
                    Label("Share last recording (\(recorder.rowCount) windows)", systemImage: "square.and.arrow.up")
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
