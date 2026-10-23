import SwiftUI

/// A board's configuration (#329): its role and LoRa parameters, what it runs
/// now and what it will run after a restart, and an editor.
///
/// Shown on any board with the Config characteristic. Nothing here changes what
/// the board is doing until it restarts; the section says which values are
/// running and which are only stored.
struct ConfigSection: View {
    let device: SophonDevice
    /// The over-the-air update (#357), offered on a board older than the held
    /// image and beside the version warning.
    let firmware: FirmwareStore
    let updater: FirmwareUpdater
    let recording: Bool
    let onUpdate: () -> Void
    /// Opens the editor on this snapshot. The sheet itself is attached by the
    /// detail view, outside its List (see ``View/configEditor(item:device:onWrite:)``).
    let onEdit: (EditTarget) -> Void

    /// What the editor opened on, as a snapshot: a reconnect clears and
    /// re-reads `device.config`, which must not blank or reset an open form.
    struct EditTarget: Identifiable {
        let id = UUID()
        let state: ConfigState
    }

    var body: some View {
        if device.offersConfig == true {
            Section {
                if let state = device.config {
                    LabeledContent("Role") { Text(roleText(state)) }
                    LabeledContent("Preset") { Text(Self.presetText(state.active.preset)) }
                    LabeledContent("TX power") { Text("\(state.active.txDbm) dBm") }
                    LabeledContent("Frequency") { Text(state.active.freqLabel) }
                    if device.loraLink != nil || state.active.role == .gateway {
                        LabeledContent("Peer") { Text(state.active.peerLabel) }
                        // Resolved: the board reports the window it runs (#344).
                        LabeledContent("Stats window") { Text("\(state.active.windowSeconds) s") }
                    }
                    if state.restartPending {
                        LabeledContent("After restart") {
                            Text(Self.summary(state.stored)).multilineTextAlignment(.trailing)
                        }
                        .foregroundStyle(.orange)
                    }
                    Button("Edit…") { onEdit(EditTarget(state: state)) }
                        .disabled(!device.state.isConnected || device.configWritePending
                                  || updater.phase(for: device)?.isBusy == true)
                } else if let mismatch = device.configMismatch {
                    // Config version 2 arrived with 2.30.0 (#344).
                    Text(mismatch.message(frame: "Config", firmware: "2.30.0")).foregroundStyle(.orange)
                } else {
                    LabeledContent("Configuration") {
                        Text(device.configReadFailed ? "Couldn't read"
                             : device.state.isConnected ? "Reading…" : "Available while connected")
                            .foregroundStyle(.secondary)
                    }
                }
                FirmwareUpdateRows(device: device, firmware: firmware, updater: updater,
                                   warned: firmwareWarning, recording: recording, onUpdate: onUpdate)
                if device.configWritePending {
                    LabeledContent("Saving") { ProgressView() }
                }
                if let error = device.configWriteError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Configuration")
            } footer: {
                footer
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if let state = device.config {
            if state.guardTripped {
                Text("""
                    This board failed to start several times in a row, so it is ignoring its stored \
                    configuration for this boot and running on defaults. Restore defaults to clear it.
                    """)
                    .foregroundStyle(.red)
            } else if state.stored.role != .auto && !state.roleForced && !state.restartPending {
                Text("""
                    The stored role, \(state.stored.role.label), needs hardware this board no longer has, \
                    so it is running as Auto.
                    """)
            } else if state.active.role == .gateway, let record = device.loraLink, !record.heard {
                Text("""
                    Not hearing a sensor. A LoRa link needs the same preset spreading factor and the same \
                    frequency at both ends.
                    """)
            } else {
                Text("Changes are stored on the board and take effect when it restarts.")
            }
        }
    }

    /// The warning above is the older-firmware one (#346).
    private var firmwareWarning: Bool {
        guard device.config == nil, case .older = device.configMismatch else { return false }
        return true
    }

    private func roleText(_ state: ConfigState) -> String {
        let running = state.active.role.label
        if state.roleForced { return "\(running) (set from the app)" }
        return "\(running) (Auto)"
    }

    /// Preset name with the figures that matter for choosing one, from
    /// LORA-PROTOCOL.md § Presets and § Variants.
    static func presetText(_ id: UInt8) -> String {
        guard Int(id) < presetInfo.count else { return "preset \(id)" }
        let info = presetInfo[Int(id)]
        return "\(info.name) · SF\(info.sf) · \(info.latencyMs) ms"
    }

    struct PresetInfo {
        let name: String
        let sf: Int
        let txDbm: Int
        let latencyMs: Int
    }

    static let presetInfo: [PresetInfo] = [
        PresetInfo(name: "V0", sf: 7, txDbm: 14, latencyMs: 259),
        PresetInfo(name: "V1", sf: 7, txDbm: 14, latencyMs: 240),
        PresetInfo(name: "V3", sf: 7, txDbm: 14, latencyMs: 102),
        PresetInfo(name: "V3b", sf: 7, txDbm: 14, latencyMs: 56),
        PresetInfo(name: "V4", sf: 7, txDbm: 14, latencyMs: 111),
        PresetInfo(name: "V5", sf: 8, txDbm: 14, latencyMs: 284),
        PresetInfo(name: "V5b", sf: 8, txDbm: 14, latencyMs: 151),
        PresetInfo(name: "V6", sf: 7, txDbm: 22, latencyMs: 102),
        PresetInfo(name: "V6b", sf: 8, txDbm: 22, latencyMs: 284),
    ]

    static func summary(_ config: SophonConfig) -> String {
        "\(config.role.label), \(config.presetLabel), TX \(config.txLabel), \(config.freqLabel), "
            + "window \(config.windowLabel)"
    }
}

extension View {
    /// The config editor sheet. Attach it outside any List: a sheet modifier
    /// on a List section is torn down when the List rebuilds that section --
    /// here every second, from the rows' timelines -- and the sheet closes as
    /// soon as it opens. That is what the first tap on Edit… did (#329).
    func configEditor(
        item: Binding<ConfigSection.EditTarget?>,
        device: SophonDevice,
        onWrite: @escaping (ConfigRequest) -> Void
    ) -> some View {
        sheet(item: item) { target in
            ConfigEditor(state: target.state, deviceName: device.displayName, onSave: onWrite)
        }
    }
}

/// The editor: the app's first form (#329).
private struct ConfigEditor: View {
    let state: ConfigState
    let deviceName: String
    let onSave: (ConfigRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var config: SophonConfig
    @State private var txOverride: Bool
    @State private var txDbm: Int
    @State private var freqOverride: Bool
    @State private var freqMHz: Double
    @State private var peerText: String
    @State private var confirmRestart = false
    @State private var confirmDefaults = false

    init(state: ConfigState, deviceName: String, onSave: @escaping (ConfigRequest) -> Void) {
        self.state = state
        self.deviceName = deviceName
        self.onSave = onSave
        var stored = state.stored
        // A stored role the hardware no longer supports matches no picker tag,
        // and saving it would be refused: start from Auto instead.
        if !state.supportedRoles.contains(stored.role) { stored.role = .auto }
        _config = State(initialValue: stored)
        _txOverride = State(initialValue: stored.txDbm != SophonConfig.txDefault)
        _txDbm = State(initialValue: stored.txDbm != SophonConfig.txDefault ? Int(stored.txDbm) : 14)
        _freqOverride = State(initialValue: stored.freqHz != SophonConfig.freqDefault)
        _freqMHz = State(initialValue: stored.freqHz != SophonConfig.freqDefault
                         ? Double(stored.freqHz) / 1e6 : 915.0)
        _peerText = State(initialValue: stored.peerID == 0 ? "" : String(format: "%04X", stored.peerID))
    }

    /// What the form says, as the wire's sentinels.
    private var edited: SophonConfig? {
        var result = config
        result.txDbm = txOverride ? Int8(clamping: txDbm) : SophonConfig.txDefault
        result.freqHz = freqOverride ? UInt32((freqMHz * 1e6).rounded()) : SophonConfig.freqDefault
        let peer = peerText.trimmingCharacters(in: .whitespaces)
        if peer.isEmpty {
            result.peerID = 0
        } else if let id = UInt16(peer, radix: 16) {
            result.peerID = id
        } else {
            return nil
        }
        return result.isValid ? result : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Role", selection: $config.role) {
                        ForEach(state.supportedRoles, id: \.self) { role in
                            Text(role == .auto ? "Auto (\(state.autoRole.label))" : role.label).tag(role)
                        }
                    }
                } header: {
                    Text("Role")
                } footer: {
                    Text(roleFooter)
                }

                Section {
                    Picker("Preset", selection: $config.preset) {
                        Text("Build default").tag(SophonConfig.presetDefault)
                        ForEach(ConfigSection.presetInfo.indices, id: \.self) { index in
                            let info = ConfigSection.presetInfo[index]
                            Text("\(info.name) · SF\(info.sf) · \(info.latencyMs) ms · \(info.txDbm) dBm")
                                .tag(UInt8(index))
                        }
                    }
                    // The gateway's measurement window (#344): 1 s for a drive, where
                    // 10 s smears a record over ~250 m. Only a board with a radio
                    // can be a gateway, so only it is offered the choice.
                    if state.radioPresent {
                        Picker("Stats window", selection: $config.windowSeconds) {
                            Text("Build default (10 s)").tag(SophonConfig.windowDefault)
                            ForEach(Array(SophonConfig.windowRange), id: \.self) { seconds in
                                Text("\(seconds) s").tag(seconds)
                            }
                        }
                    }
                    Toggle("Set frequency", isOn: $freqOverride)
                    if freqOverride {
                        Stepper(value: $freqMHz, in: 902.25...927.75, step: 0.25) {
                            Text(String(format: "%.2f MHz", freqMHz))
                        }
                    }
                    LabeledContent("Peer") {
                        TextField("Any", text: $peerText)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("LoRa")
                } footer: {
                    Text("""
                        Both ends of a link need the same spreading factor and frequency: change the sensor \
                        and the gateway together. Peer is the sensor's XXXX from Sophon-XXXX; leave it empty \
                        to accept the first sensor heard. The stats window is the gateway's: 1 s suits a \
                        drive; each window then holds about 54 samples, so its figures are coarser.
                        """)
                }

                Section {
                    Toggle("Override TX power", isOn: $txOverride)
                    if txOverride {
                        Stepper(value: $txDbm, in: -9...22) { Text("\(txDbm) dBm") }
                    }
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Off uses the preset's own power. Never transmit without an antenna fitted.")
                }

                Section {
                    Button("Save and restart") { confirmRestart = true }
                        .disabled(edited == nil)
                    Button("Save") { save(restart: false) }
                        .disabled(edited == nil)
                    Button("Restore defaults", role: .destructive) { confirmDefaults = true }
                } footer: {
                    if edited == nil {
                        Text("Peer must be up to four hex digits.").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(deviceName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .confirmationDialog("Restart \(deviceName)?", isPresented: $confirmRestart, titleVisibility: .visible) {
                Button("Save and restart") { save(restart: true) }
            } message: {
                Text(restartMessage)
            }
            .confirmationDialog("Restore defaults on \(deviceName)?", isPresented: $confirmDefaults,
                                titleVisibility: .visible) {
                Button("Restore defaults and restart", role: .destructive) {
                    onSave(ConfigRequest(config: .defaults, restart: true, restoreDefaults: true))
                    dismiss()
                }
            } message: {
                Text("""
                    The board forgets its stored configuration and restarts as Auto (\(state.autoRole.label)) \
                    with the build's LoRa settings.\(becomesSensor(.auto) ? " It will then appear under Sensors." : "")
                    """)
            }
        }
    }

    private var roleFooter: String {
        let auto = "Auto picks \(state.autoRole.label.lowercased()) on this board, from its hardware."
        switch config.role {
        case _ where becomesSensor(config.role):
            return auto + " As a sensor it stops advertising to the app, and appears under Sensors."
        case .gateway where state.imuPresent:
            return auto + " As a gateway its own IMU is not used: it relays a sensor's motion."
        default:
            return auto
        }
    }

    private var restartMessage: String {
        guard let edited else { return "" }
        let base = "\(deviceName) restarts as \(ConfigSection.summary(edited))."
        return becomesSensor(edited.role) ? base + " It will then appear under Sensors." : base
    }

    /// Whether this role takes the board into the sensor role from another --
    /// directly, or through Auto on a board with a radio and an IMU.
    private func becomesSensor(_ role: SophonConfig.Role) -> Bool {
        (role == .auto ? state.autoRole : role) == .sensor && state.active.role != .sensor
    }

    private func save(restart: Bool) {
        guard let edited else { return }
        onSave(ConfigRequest(config: edited, restart: restart, restoreDefaults: false))
        dismiss()
    }
}
