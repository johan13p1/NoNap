//
//  AppModel.swift
//  NoNap
//
//  Bindeglied zwischen Oberfläche, Einstellungen und Helfer.
//
//  Der Zustand einer Session gehört dem Helfer. Dieses Modell spiegelt ihn
//  nur und rechnet die Restzeit für die Anzeige aus — deshalb der Ticker:
//  Er lässt die Anzeige laufen, ohne dafür jede Sekunde den Helfer zu fragen.
//

import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class AppModel {

    let helper = HelperConnection()
    let prefs = Preferences.shared

    /// Treibt die Countdown-Anzeige. Wird jede Sekunde neu gesetzt, solange
    /// eine begrenzte Session läuft.
    private(set) var now = Date()

    /// Kurze Rückmeldung in der Oberfläche, etwa warum eine Session endete.
    private(set) var notice: String?

    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private let displayAssertion = PowerAssertion.displaySleep(
        reason: "NoNap hält das Display wach")
    @ObservationIgnored private let systemAssertion = PowerAssertion.systemSleep(
        reason: "NoNap-Session läuft")

    // MARK: - Abgeleiteter Zustand

    var status: HelperStatus { helper.status }
    var isActive: Bool { status.isActive }

    var remaining: TimeInterval? {
        guard status.isActive, let deadline = status.deadline else { return nil }
        _ = now  // Abhängigkeit vom Ticker, damit die Anzeige nachzieht.
        return max(0, deadline.timeIntervalSinceNow)
    }

    /// Text für die Menüleiste, `nil` wenn dort nichts stehen soll.
    var menuBarText: String? {
        guard prefs.showCountdownInMenuBar, status.isActive else { return nil }
        guard let remaining else { return "∞" }
        return Formatting.menuBarCountdown(remaining)
    }

    var helperIsReady: Bool { helper.installState == .installed }

    // MARK: - Aufbau

    func onAppear() {
        helper.refreshInstallState()

        helper.onStatusChange = { [weak self] status in
            self?.handleStatusChange(status)
        }

        if helperIsReady {
            Task {
                await helper.refreshStatus()
                syncTicker()
                syncAssertions()
            }
        }

        // Nach dem Aufwachen kann die Anzeige veraltet sein.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.helperIsReady else { return }
                await self.helper.refreshStatus()
                self.syncTicker()
            }
        }
    }

    // MARK: - Steuerung

    /// Startet eine Session.
    /// - Parameter minutes: Dauer in Minuten, `nil` für unbegrenzt.
    func start(minutes: Int?) async {
        notice = nil
        let deadline = minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
        let ok = await helper.startSession(deadline: deadline, policy: prefs.sessionPolicy)
        if ok {
            syncTicker()
            syncAssertions()
        }
    }

    func stop() async {
        notice = nil
        await helper.stopSession()
        syncTicker()
        syncAssertions()
    }

    func extend(minutes: Int) async {
        await helper.extendSession(by: TimeInterval(minutes * 60))
        syncTicker()
    }

    /// Überträgt geänderte Schutzregeln in eine laufende Session.
    func applyPolicyChange() async {
        await helper.pushPolicy(prefs.sessionPolicy)
    }

    func applyDisplayPreferenceChange() {
        syncAssertions()
    }

    // MARK: - Reaktion auf den Helfer

    private func handleStatusChange(_ status: HelperStatus) {
        syncTicker()
        syncAssertions()

        guard !status.isActive, let reason = status.lastEndReason else { return }

        let text: String?
        switch reason {
        case .expired:
            text = "Session beendet — die Zeit ist abgelaufen."
        case .batteryLow:
            text = "Session beendet — der Akku war zu niedrig."
        case .powerUnplugged:
            text = "Session beendet — das Netzteil wurde abgezogen."
        case .rebootDetected:
            text = "Session beendet — der Mac wurde neu gestartet."
        case .helperShutdown:
            text = "Session beendet — der Helfer wurde angehalten."
        case .userStopped:
            text = nil  // Vom Benutzer ausgelöst, braucht keine Meldung.
        }

        guard let text else { return }
        notice = text
        if prefs.notifyOnSessionEnd {
            Notifier.post(title: "NoNap", body: text)
        }
    }

    func clearNotice() { notice = nil }

    // MARK: - Ticker und Assertions

    private func syncTicker() {
        let needsTicker = status.isActive && status.deadline != nil
        if needsTicker, ticker == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                // Der Timer hängt an RunLoop.main und feuert daher bereits auf
                // dem Main-Actor — kein Umweg über einen weiteren Task nötig.
                MainActor.assumeIsolated {
                    self?.now = Date()
                }
            }
            // `.common` sorgt dafür, dass der Countdown auch weiterläuft,
            // während ein Menü geöffnet ist.
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
            now = Date()
        } else if !needsTicker {
            ticker?.invalidate()
            ticker = nil
        }
    }

    private func syncAssertions() {
        if status.isActive {
            systemAssertion.acquire()
            if prefs.keepDisplayAwake {
                displayAssertion.acquire()
            } else {
                displayAssertion.release()
            }
        } else {
            systemAssertion.release()
            displayAssertion.release()
        }
    }
}
