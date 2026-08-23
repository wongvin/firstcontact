import SwiftUI

/// The peripheral-side screen: what this device is pretending to be, and how
/// well it is pretending.
///
/// Motion is formatted identically to `DeviceDetailView`'s Motion section on
/// purpose. The end-to-end check for the encoder and decoder is holding the two
/// screens side by side and reading the numbers off both, so any divergence in
/// formatting would undermine the one test that covers the whole wire path.
struct SimulatorView: View {
    @Bindable var simulator: SophonSimulator

    private var display: SophonSimulator.Display { simulator.display }

    var body: some View {
        Group {
            if !display.radio.isUsable && !display.isAdvertising {
                RadioUnavailableView(state: display.radio, purpose: "to advertise as a Sophon")
            } else {
                List {
                    identitySection
                    linkSection
                    rateSection
                    motionSection
                    countersSection
                    benchSection
                }
            }
        }
    }

    @ViewBuilder private var identitySection: some View {
        Section {
            LabeledContent("Advertising as") {
                Text(display.name).font(.headline.monospaced())
            }
        } header: {
            Text("Identity")
        } footer: {
            Text("Derived from this install's vendor id, the way a board derives its name from the nRF52840 FICR. Deliberately indistinguishable from real hardware — the viewer needs no special case.")
        }
    }

    @ViewBuilder private var linkSection: some View {
        Section {
            LabeledContent("Advertising", value: display.isAdvertising ? "Yes" : "No")
            LabeledContent("Subscribers", value: "\(display.subscribers)")
            if let maxLength = display.maximumUpdateLength {
                LabeledContent("Max notify", value: "\(maxLength) bytes")
            }
        } header: {
            Text("Link")
        } footer: {
            Text("A real board accepts one connection and negotiates a 23-byte ATT MTU. This will serve several centrals and negotiates far more iPhone-to-iPad, so it is a stand-in for logic and timing, not for radio capacity.")
        }
    }

    @ViewBuilder private var rateSection: some View {
        Section {
            LabeledContent("Nominal", value: String(format: "%.1f Hz", MotionSource.nominalRateHz))
            LabeledContent("Sensor", value: display.sensorRateHz.map { String(format: "%.1f Hz", $0) } ?? "—")
            LabeledContent("Notify", value: display.notifyRateHz.map { String(format: "%.1f Hz", $0) } ?? "—")
        } header: {
            Text("Rate")
        } footer: {
            Text("Nominal is what was requested; sensor is what CoreMotion delivers. They differ, exactly as the board's LSM6DSL delivers ~54 Hz when asked for 52 — which is why t_ms, not the nominal rate, is the timebase. Notify falls below sensor when frames are dropped.")
        }
    }

    @ViewBuilder private var motionSection: some View {
        if let frame = display.lastFrame {
            Section {
                LabeledContent("Accel", value: "\(frame.ax), \(frame.ay), \(frame.az) mg")
                LabeledContent("Gyro", value: "\(frame.gx), \(frame.gy), \(frame.gz) cdps")
                LabeledContent("seq", value: "\(frame.seq)")
                LabeledContent("Uptime", value: "\(frame.tMillis) ms")
            } header: {
                Text("Motion")
            } footer: {
                Text("These should read the same as the viewer's Motion section, value for value. That comparison is the end-to-end check on the frame encoder and decoder.")
            }
        } else {
            Section {
                Text(display.subscribers == 0
                     ? "Waiting for a subscriber — seq does not advance while nobody is listening."
                     : "Waiting for the first sample.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Motion")
            }
        }
    }

    @ViewBuilder private var countersSection: some View {
        Section {
            LabeledContent("Sent", value: "\(display.stats.sent)")
            LabeledContent("TX buffer full", value: "\(display.stats.noBuffer)")
            LabeledContent("No subscriber", value: "\(display.stats.noConn)")
            if display.queueFullRecoveries > 0 {
                LabeledContent("Queue drained", value: "\(display.queueFullRecoveries)")
            }
        } header: {
            Text("Transmit counters")
        } footer: {
            Text("The same four counters a board exposes, readable by the viewer over the stats characteristic. A refused frame is dropped rather than retried, and seq is never rewound — so the hole stays visible.")
        }
    }

    @ViewBuilder private var benchSection: some View {
        Section {
            Button("Reboot the simulated board") { simulator.reboot() }

            Stepper("Drop \(simulator.dropPercent)% of frames",
                    value: $simulator.dropPercent, in: 0 ... 20, step: 1)

            Toggle("Pretend the IMU is missing", isOn: $simulator.pretendNoIMU)
            Toggle("Keep the screen awake", isOn: $simulator.keepScreenAwake)
        } header: {
            Text("Bench")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Reboot resets seq, uptime and the counters without dropping the link — the only way to exercise the viewer's board-restart detection, since switching modes disconnects and clears it first.")
                Text("Dropping frames reproduces the firmware's out-of-buffers path, which iOS is too generous to produce on its own. It can only fake \"taken but never sent\"; genuine loss on the air cannot be synthesised from this side.")
                if !display.motionAvailable {
                    Text("No motion hardware here, so frames carry zeroed axes at 1 Hz — the same fallback a board uses when its IMU will not start.")
                }
                if !display.keepAliveAuthorized {
                    Text("Location permission has not been granted, so streaming will stop when the screen locks. Keep the screen awake, or allow it in Settings.")
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}
