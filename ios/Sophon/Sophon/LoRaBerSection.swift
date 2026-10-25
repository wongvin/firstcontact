import SwiftUI

/// The bit-error test's rows (#359): a transporter sends its own firmware over
/// LoRa with the CRC off, and the gateway compares every bit with its own copy.
///
/// Rows, not a section: they sit inside the LoRa link section when the gateway
/// hears a transporter, which replaces Link quality with Bit error rate there
/// (``LoRaLinkSection``). The radio rows (RSSI, SNR, margin, noise, Updated) are
/// the link section's own, shared by both kinds of peer. The per-window figures
/// are the latest window's, like LQ; "This session" adds them up, which is the
/// long-run BER at a finer grain than one window allows.
struct LoRaBerRows: View {
    let device: SophonDevice
    let imageCheck: ImageCheck
    /// A firmware update is running on any board: SMP is taken (#357).
    let updating: Bool
    /// The hub's entry for a board by name, for the transporter's firmware.
    let findDevice: (String) -> SophonDevice?
    let onCheckImages: () -> Void

    private var ber: LoRaBerState { device.loraBer }

    /// The last image check, only if it still describes the transporter heard
    /// now, on the firmware both boards run now (#359 review, findings 1-2).
    private func currentCheck(_ record: LoRaBerRecord) -> ImageCheck.Outcome? {
        ImageCheck.current(ber.imageCheck, gateway: device, transporterName: record.transporterName,
                           transporter: record.transporterName.flatMap(findDevice))
    }

    var body: some View {
        if let record = ber.record {
            LabeledContent("Transporter") {
                Text(record.transporterName.map { record.transporterUnverified ? "\($0) (unconfirmed)" : $0 }
                     ?? "None heard yet")
            }
            imagesRow(record)
            LabeledContent("Damaged packets") {
                Text(countText(Int(record.damaged), of: Int(record.packets), percent: record.damagedPercent))
            }
            LabeledContent("Lost packets") { Text(lostText(record)) }
            LabeledContent("Headers") {
                Text("\(record.repaired)\(saturated(record.repaired)) repaired · "
                     + "\(record.unresolved)\(saturated(record.unresolved)) unresolved")
                    .foregroundStyle(record.unresolved > 0 ? .orange : .primary)
            }
            LabeledContent("This session") {
                Text(sessionText).font(.callout.monospacedDigit())
            }
        } else if let mismatch = ber.mismatch {
            Text(mismatch.message(frame: "LoRa BER", firmware: "2.33.0")).foregroundStyle(.orange)
        }
    }

    // MARK: Images

    @ViewBuilder private func imagesRow(_ record: LoRaBerRecord) -> some View {
        LabeledContent("Images") {
            Text(imagesText(record)).foregroundStyle(imagesColor(record))
        }
        if record.canCompare {
            Button(imageCheck.checkingID == device.id ? "Checking images…" : "Check images",
                   action: onCheckImages)
                .disabled(imageCheck.isBusy || updating || record.transporterName == nil)
        }
    }

    /// The check's own answer wins: it compared the hashes. The gateway's
    /// mismatch-suspected flag shows only with no current check, or against
    /// a Match it now contradicts (#359 bench test).
    private func imagesText(_ record: LoRaBerRecord) -> String {
        if !record.canCompare { return "This gateway can't read its own image (a UF2 build)" }
        let suspected = "Mismatch suspected: nearly every packet failed its check"
        guard let outcome = currentCheck(record) else {
            return record.mismatchSuspected ? suspected : "Not checked"
        }
        let when = outcome.at.formatted(date: .omitted, time: .shortened)
        switch outcome.result {
        case .match:
            return record.mismatchSuspected
                ? suspected + ", though the check at \(when) matched. Check again."
                : "Match, \(outcome.transporter), checked \(when)"
        case .mismatch: return "Mismatch: flash the same image to both boards (checked \(when))"
        case .transporterUnreachable(let why): return "\(outcome.transporter) not reachable: \(why)"
        case .gatewayUnreadable(let why): return "This gateway's image couldn't be read: \(why)"
        }
    }

    private func imagesColor(_ record: LoRaBerRecord) -> Color {
        if !record.canCompare { return .orange }
        switch currentCheck(record)?.result {
        case .match: return record.mismatchSuspected ? .orange : .green
        case .mismatch: return .red
        case .transporterUnreachable, .gatewayUnreadable: return .orange
        case nil: return record.mismatchSuspected ? .orange : .secondary
        }
    }

    // MARK: Formatting

    /// The headline the LoRa link section shows in place of Link quality.
    static func berText(_ record: LoRaBerRecord) -> String {
        guard let percent = record.berPercent else {
            return record.heard ? "Nothing compared" : "Nothing heard"
        }
        return String(format: "%.4f %%", percent)
            + " (\(record.bitErrors) of \(record.bitsCompared.formatted()) bits)"
    }

    /// Zero is clean; anything under 0.1 % is a link that mostly gets through.
    /// Heard but nothing compared is the image-mismatch signature, not an
    /// absence (#359 review, finding 4).
    static func berColor(_ record: LoRaBerRecord) -> Color {
        guard let percent = record.berPercent else { return record.heard ? .orange : .secondary }
        if percent == 0 { return .green }
        if percent < 0.1 { return .orange }
        return .red
    }

    private func countText(_ part: Int, of whole: Int, percent: Double?) -> String {
        guard let percent else { return "—" }
        return "\(part) of \(whole) (" + String(format: "%.1f %%", percent) + ")"
    }

    private func lostText(_ record: LoRaBerRecord) -> String {
        guard let percent = record.lostPercent else { return "—" }
        return "\(record.lost) (" + String(format: "%.1f %%", percent) + ")"
    }

    private var sessionText: String {
        let rate = ber.sessionBerPercent.map { String(format: "%.4f %%", $0) } ?? "—"
        return "BER \(rate) · \(ber.sessionBits.formatted()) bits · \(ber.sessionDamaged) damaged · "
            + "\(ber.sessionLost) lost"
    }

    private func saturated(_ count: UInt8) -> String {
        count == LoRaBerRecord.countCeiling ? "+" : ""
    }
}
