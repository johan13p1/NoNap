//
//  MenuContentView.swift
//  NoNap
//
//  Das Panel, das beim Klick auf das Menüleisten-Symbol aufklappt.
//

import SwiftUI

struct MenuContentView: View {

    @Environment(AppModel.self) private var model
    @State private var customMinutes = 90
    @State private var showCustom = false

    private let quickDurations = [30, 60, 120, 240]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if model.helperIsReady {
                Divider()
                if model.isActive {
                    activeControls
                } else {
                    startControls
                }
            } else {
                Divider()
                HelperSetupView()
            }

            if let notice = model.notice {
                noticeBanner(notice)
            }

            if let error = model.helper.lastError {
                errorBanner(error)
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 280)
    }

    // MARK: - Kopf

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.system(size: 20))
                .foregroundStyle(model.isActive ? Color.accentColor : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.isActive ? "Bleibt wach" : "Schläft normal")
                    .font(.headline)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var subtitle: String {
        guard model.isActive else {
            return "Keine Session aktiv"
        }
        if let remaining = model.remaining, let deadline = model.status.deadline {
            return "noch \(Formatting.longRemaining(remaining)) · bis \(Formatting.endTime(deadline))"
        }
        return "Unbegrenzt — bis du sie beendest"
    }

    // MARK: - Start

    private var startControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session starten")
                .font(.subheadline.weight(.medium))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(quickDurations, id: \.self) { minutes in
                    Button {
                        Task { await model.start(minutes: minutes) }
                    } label: {
                        Text(Formatting.duration(minutes: minutes))
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                }
            }

            if showCustom {
                customDurationRow
            } else {
                Button("Eigene Dauer …") { showCustom = true }
                    .buttonStyle(.link)
                    .font(.callout)
            }

            Button {
                Task { await model.start(minutes: nil) }
            } label: {
                Label("Unbegrenzt", systemImage: "infinity")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }

    private var customDurationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Eigene Dauer")
                    .font(.callout)
                Spacer()
                Text(Formatting.duration(minutes: customMinutes))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Slider(value: Binding(
                    get: { Double(customMinutes) },
                    set: { customMinutes = Int(($0 / 15).rounded()) * 15 }
                ), in: 15...720)

                Button("Start") {
                    Task { await model.start(minutes: customMinutes) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Laufende Session

    private var activeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let remaining = model.remaining {
                ProgressView(value: progressValue) {
                    Text(Formatting.menuBarCountdown(remaining))
                        .font(.title2.monospacedDigit())
                }
                .progressViewStyle(.linear)
            }

            HStack(spacing: 6) {
                Button {
                    Task { await model.extend(minutes: 15) }
                } label: {
                    Label("15 Min.", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.status.deadline == nil)

                Button {
                    Task { await model.extend(minutes: 60) }
                } label: {
                    Label("1 Std.", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.status.deadline == nil)
            }
            .controlSize(.large)

            Button(role: .destructive) {
                Task { await model.stop() }
            } label: {
                Label("Session beenden", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            // Warnung, falls der Helfer meldet, dass der Schlaf entgegen der
            // Erwartung nicht abgeschaltet ist.
            if !model.status.sleepDisabled {
                Label("Der Schlaf ist trotz laufender Session nicht abgeschaltet.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var progressValue: Double {
        guard let deadline = model.status.deadline,
              let start = model.status.startedAt else { return 0 }
        let total = deadline.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        let done = Date().timeIntervalSince(start)
        return min(1, max(0, done / total))
    }

    // MARK: - Hinweise

    private func noticeBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                model.clearNotice()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                model.helper.lastError = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Fuß

    private var footer: some View {
        HStack {
            SettingsLink {
                Label("Einstellungen", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            // Ohne diesen Schritt öffnet sich das Fenster hinter anderen
            // Programmen: Eine Menüleisten-App ist normalerweise nicht aktiv.
            .simultaneousGesture(TapGesture().onEnded {
                NSApp.activate(ignoringOtherApps: true)
            })

            Spacer()

            Button("Beenden") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

/// Einrichtung des Helfers, solange er noch nicht installiert ist.
private struct HelperSetupView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.helper.installState {
            case .requiresApproval:
                Label("Freigabe nötig", systemImage: "hand.raised.fill")
                    .font(.subheadline.weight(.medium))
                Text("Der Hintergrunddienst wartet auf deine Freigabe unter "
                     + "Systemeinstellungen › Allgemein › Anmeldeobjekte.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Systemeinstellungen öffnen") {
                    model.helper.openLoginItemSettings()
                }
                .controlSize(.large)
                .frame(maxWidth: .infinity)

            case .failed(let message):
                Label("Einrichtung fehlgeschlagen", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Erneut versuchen") { model.helper.install() }
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

            default:
                Label("Einrichtung nötig", systemImage: "wrench.and.screwdriver.fill")
                    .font(.subheadline.weight(.medium))
                Text("Damit der Mac bei zugeklapptem Deckel wach bleibt, braucht "
                     + "NoNap einen kleinen Hintergrunddienst. macOS fragt dafür "
                     + "einmalig nach deinem Passwort.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Hintergrunddienst einrichten") { model.helper.install() }
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
