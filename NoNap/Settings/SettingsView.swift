//
//  SettingsView.swift
//  NoNap
//

import ServiceManagement
import SwiftUI

struct SettingsView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("Allgemein", systemImage: "gearshape") }

            ProtectionSettingsView()
                .tabItem { Label("Schutz", systemImage: "battery.50percent") }

            HelperSettingsView()
                .tabItem { Label("Hintergrunddienst", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 460)
        .environment(model)
    }
}

// MARK: - Allgemein

private struct GeneralSettingsView: View {

    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = false
    @State private var loginItemNeedsApproval = false
    @State private var loginItemError: String?

    private let durations = [15, 30, 45, 60, 90, 120, 180, 240, 480]

    var body: some View {
        @Bindable var prefs = model.prefs

        Form {
            Section {
                Toggle("NoNap beim Anmelden starten", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }

                if loginItemNeedsApproval {
                    Label("macOS wartet auf deine Freigabe unter Systemeinstellungen › "
                          + "Allgemein › Anmeldeobjekte.",
                          systemImage: "hand.raised")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Systemeinstellungen öffnen") {
                        LoginItem.openSystemSettings()
                    }
                }

                if let loginItemError {
                    Label(loginItemError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Start")
            } footer: {
                Text("NoNap läuft ohne Fenster nur in der Menüleiste. "
                     + "Eine Session wird beim Start nicht automatisch begonnen.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Anzeige") {
                Toggle("Verbleibende Zeit in der Menüleiste anzeigen",
                       isOn: $prefs.showCountdownInMenuBar)

                Picker("Voreingestellte Dauer", selection: $prefs.defaultDurationMinutes) {
                    ForEach(durations, id: \.self) { minutes in
                        Text(Formatting.duration(minutes: minutes)).tag(minutes)
                    }
                }
            }

            Section {
                Toggle("Display ebenfalls wachhalten", isOn: $prefs.keepDisplayAwake)
                    .onChange(of: prefs.keepDisplayAwake) { _, _ in
                        model.applyDisplayPreferenceChange()
                    }

                Toggle("Mitteilung, wenn eine Session von selbst endet",
                       isOn: $prefs.notifyOnSessionEnd)
            } header: {
                Text("Während einer Session")
            } footer: {
                Text("Bei zugeklapptem Deckel ist das Display ohnehin aus — "
                     + "die Einstellung wirkt nur am offenen Gerät.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        launchAtLogin = LoginItem.isEnabled
        loginItemNeedsApproval = LoginItem.requiresApproval
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginItemError = nil
        do {
            try LoginItem.setEnabled(enabled)
        } catch {
            loginItemError = error.localizedDescription
        }
        // Den tatsächlichen Zustand zurücklesen: Die Registrierung kann
        // abgelehnt worden sein oder auf Freigabe warten.
        refresh()
    }
}

// MARK: - Schutz

private struct ProtectionSettingsView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs

        Form {
            Section {
                Toggle("Session bei niedrigem Akku beenden", isOn: $prefs.stopOnLowBattery)
                    .onChange(of: prefs.stopOnLowBattery) { _, _ in push() }

                if prefs.stopOnLowBattery {
                    Stepper(value: $prefs.batteryThreshold, in: 5...90, step: 5) {
                        HStack {
                            Text("Schwelle")
                            Spacer()
                            Text("\(prefs.batteryThreshold) %")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: prefs.batteryThreshold) { _, _ in push() }
                }

                Toggle("Session beenden, wenn das Netzteil abgezogen wird",
                       isOn: $prefs.stopOnUnplug)
                    .onChange(of: prefs.stopOnUnplug) { _, _ in push() }
            } header: {
                Text("Notbremse")
            } footer: {
                Text("Ein zugeklappter Mac, der nicht schlafen darf, entlädt sich "
                     + "bis zum Ende und wird dabei warm. Diese Grenzen überwacht "
                     + "der Hintergrunddienst selbst — sie greifen auch dann, wenn "
                     + "NoNap abgestürzt oder beendet ist.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func push() {
        Task { await model.applyPolicyChange() }
    }
}

// MARK: - Hintergrunddienst

private struct HelperSettingsView: View {

    @Environment(AppModel.self) private var model
    @State private var isWorking = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Zustand") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(statusText)
                    }
                }

                if model.helperIsReady {
                    LabeledContent("Version", value: model.status.helperVersion.isEmpty
                                   ? "–" : model.status.helperVersion)
                    LabeledContent("Schlaf abgeschaltet",
                                   value: model.status.sleepDisabled ? "ja" : "nein")
                }
            } header: {
                Text("Hintergrunddienst")
            } footer: {
                Text("Der Dienst läuft mit Systemrechten, weil sich das Einschlafen "
                     + "bei geschlossenem Deckel nur über eine geschützte "
                     + "Systemeinstellung abschalten lässt. Er tut nichts anderes, "
                     + "als diese Einstellung zu setzen und nach Ablauf der Session "
                     + "wieder zurückzunehmen.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                switch model.helper.installState {
                case .installed:
                    Button("Hintergrunddienst entfernen", role: .destructive) {
                        isWorking = true
                        Task {
                            await model.helper.uninstall()
                            isWorking = false
                        }
                    }
                    .disabled(isWorking)

                case .requiresApproval:
                    Button("Systemeinstellungen öffnen") {
                        model.helper.openLoginItemSettings()
                    }

                default:
                    Button("Hintergrunddienst einrichten") {
                        model.helper.install()
                    }
                }
            } footer: {
                Text("Der Dienst ist auch unter Systemeinstellungen › Allgemein › "
                     + "Anmeldeobjekte aufgeführt und kann dort abgeschaltet werden.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.helper.refreshInstallState() }
    }

    private var statusText: String {
        switch model.helper.installState {
        case .installed: return "eingerichtet"
        case .requiresApproval: return "wartet auf Freigabe"
        case .notInstalled: return "nicht eingerichtet"
        case .failed(let message): return message
        case .unknown: return "unbekannt"
        }
    }

    private var statusColor: Color {
        switch model.helper.installState {
        case .installed: return .green
        case .requiresApproval: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }
}
