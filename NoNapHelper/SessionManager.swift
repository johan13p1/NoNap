//
//  SessionManager.swift
//  NoNapHelper
//
//  Führt den Session-Zustand. Der Helper — nicht die App — ist die maßgebliche
//  Quelle: Er kennt die Deadline, zählt sie herunter und gibt den Schlaf wieder
//  frei. Damit überlebt eine Session einen Neustart der App, und ein Absturz
//  der App lässt keinen Mac zurück, der nie wieder einschläft.
//
//  Sämtlicher Zustand wird ausschließlich auf `queue` berührt.
//

import Foundation

final class SessionManager {

    static let version = "1.0"

    private let queue = DispatchQueue(label: "com.johan.NoNap.Helper.session")

    private var session: PersistedSession?
    private var lastEndReason: SessionEndReason?
    private var deadlineTimer: DispatchSourceTimer?
    private var heartbeatTimer: DispatchSourceTimer?
    private var powerWatcher: PowerWatcher?

    /// Verbundene Apps, die über Zustandsänderungen unterrichtet werden wollen.
    private var observers: [UUID: (Data) -> Void] = [:]

    // MARK: - Start

    /// Gleicht beim Hochfahren des Daemons den gespeicherten Zustand mit der
    /// Wirklichkeit ab. Läuft vor der ersten XPC-Verbindung.
    func startUp() {
        queue.sync {
            let stored = SessionStore.load()
            let actuallyDisabled = SleepControl.isSleepDisabled()

            guard let stored else {
                // Keine Session bekannt. Ist der Schlaf trotzdem abgeschaltet,
                // stammt das aus einem früheren Absturz — aufräumen.
                if actuallyDisabled {
                    HelperLog.info("Kein Session-Eintrag, aber Schlaf ist aus — wird freigegeben")
                    SleepControl.releaseQuietly()
                }
                return
            }

            // Nach einem Neustart gilt die Session als hinfällig. Der Benutzer
            // hat den Mac neu gestartet; ihn stillschweigend wachzuhalten wäre
            // eine Überraschung.
            let bootTime = SessionStore.systemBootTime()
            if abs(bootTime.timeIntervalSince(stored.bootTime)) > 5 {
                HelperLog.info("Neustart erkannt — gespeicherte Session wird verworfen")
                finish(reason: .rebootDetected)
                return
            }

            if let deadline = stored.deadline, deadline <= Date() {
                HelperLog.info("Gespeicherte Session war bereits abgelaufen")
                finish(reason: .expired)
                return
            }

            // Session ist noch gültig: übernehmen und Schlaf sicherstellen.
            session = stored
            HelperLog.info("Session übernommen, Ende: \(stored.deadline.map(String.init(describing:)) ?? "unbegrenzt")")
            do {
                try SleepControl.setSleepDisabled(true)
            } catch {
                HelperLog.error("Schlaf konnte nicht abgeschaltet werden: \(error.localizedDescription)")
                finish(reason: .helperShutdown)
                return
            }
            armTimers()
            startPowerWatcherIfNeeded()
        }
    }

    // MARK: - Steuerung

    func start(deadline: Date?, policy: SessionPolicy) throws -> HelperStatus {
        try queue.sync {
            // Eine bereits laufende Session wird ersetzt, nicht verdoppelt.
            let now = Date()
            if let deadline, deadline <= now {
                throw HelperError.message("Der gewählte Endzeitpunkt liegt in der Vergangenheit.")
            }

            // Schutzregeln vor dem Start prüfen: Bei fast leerem Akku eine
            // Session zu starten, die sofort wieder endet, hilft niemandem.
            let power = PowerWatcher.snapshot()
            if let reason = violatedPolicy(policy, power: power) {
                throw HelperError.message(reason)
            }

            try SleepControl.setSleepDisabled(true)

            let new = PersistedSession(deadline: deadline,
                                       startedAt: session?.startedAt ?? now,
                                       policy: policy,
                                       bootTime: SessionStore.systemBootTime())
            session = new
            lastEndReason = nil
            SessionStore.save(new)
            armTimers()
            startPowerWatcherIfNeeded()

            HelperLog.info("Session gestartet, Ende: \(deadline.map(String.init(describing:)) ?? "unbegrenzt")")
            let status = statusLocked()
            broadcastLocked(status)
            return status
        }
    }

    func extend(by seconds: TimeInterval) throws -> HelperStatus {
        try queue.sync {
            guard var current = session else {
                throw HelperError.message("Es läuft keine Session.")
            }
            guard let deadline = current.deadline else {
                throw HelperError.message("Die Session läuft bereits unbegrenzt.")
            }

            // Ab jetzt verlängern, nicht ab einer eventuell schon
            // verstrichenen Deadline.
            current.deadline = max(deadline, Date()).addingTimeInterval(seconds)
            session = current
            SessionStore.save(current)
            armTimers()

            HelperLog.info("Session verlängert bis \(String(describing: current.deadline!))")
            let status = statusLocked()
            broadcastLocked(status)
            return status
        }
    }

    func stop() -> HelperStatus {
        queue.sync {
            finish(reason: .userStopped)
            let status = statusLocked()
            broadcastLocked(status)
            return status
        }
    }

    func updatePolicy(_ policy: SessionPolicy) -> HelperStatus {
        queue.sync {
            guard var current = session else { return statusLocked() }
            current.policy = policy
            session = current
            SessionStore.save(current)

            // Geänderte Regeln sofort anwenden — die neue Schwelle kann
            // bereits überschritten sein.
            evaluatePolicyLocked(power: PowerWatcher.snapshot())
            let status = statusLocked()
            broadcastLocked(status)
            return status
        }
    }

    func status() -> HelperStatus {
        queue.sync { statusLocked() }
    }

    /// Wird beim Beenden des Daemons aufgerufen. Gibt den Schlaf frei, behält
    /// die Session aber gespeichert, damit sie beim nächsten Start des Helpers
    /// fortgesetzt werden kann.
    func shutDown() {
        queue.sync {
            guard session != nil else { return }
            HelperLog.info("Helper wird beendet — Schlaf wird freigegeben")
            SleepControl.releaseQuietly()
        }
    }

    // MARK: - Beobachter

    func addObserver(_ handler: @escaping (Data) -> Void) -> UUID {
        queue.sync {
            let id = UUID()
            observers[id] = handler
            return id
        }
    }

    func removeObserver(_ id: UUID) {
        queue.async { self.observers[id] = nil }
    }

    // MARK: - Interna (nur auf `queue`)

    /// Beendet die Session und gibt den Schlaf frei.
    private func finish(reason: SessionEndReason) {
        SleepControl.releaseQuietly()
        SessionStore.clear()
        session = nil
        lastEndReason = reason
        cancelTimers()
        powerWatcher?.stop()
        powerWatcher = nil
        HelperLog.info("Session beendet (\(reason.rawValue))")
    }

    private func statusLocked() -> HelperStatus {
        HelperStatus(isActive: session != nil,
                     deadline: session?.deadline,
                     startedAt: session?.startedAt,
                     sleepDisabled: SleepControl.isSleepDisabled(),
                     lastEndReason: lastEndReason,
                     policy: session?.policy ?? .default,
                     helperVersion: Self.version)
    }

    private func broadcastLocked(_ status: HelperStatus) {
        guard let data = NoNapCoding.encode(status) else { return }
        for handler in observers.values {
            handler(data)
        }
    }

    // MARK: - Timer

    private func armTimers() {
        cancelTimers()
        guard let session else { return }

        if let deadline = session.deadline {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            // `wallDeadline` rechnet in Kalenderzeit — richtig für Fristen,
            // die Stunden entfernt liegen.
            timer.schedule(wallDeadline: .now() + max(0, deadline.timeIntervalSinceNow),
                           leeway: .seconds(1))
            timer.setEventHandler { [weak self] in self?.deadlineReached() }
            timer.resume()
            deadlineTimer = timer
        }

        // Regelmäßige Gegenprobe: fängt eine verpasste Frist ab und korrigiert
        // ein `SleepDisabled`, das jemand von außen verstellt hat.
        let heartbeat = DispatchSource.makeTimerSource(queue: queue)
        heartbeat.schedule(wallDeadline: .now() + 60, repeating: 60, leeway: .seconds(10))
        heartbeat.setEventHandler { [weak self] in self?.heartbeat() }
        heartbeat.resume()
        heartbeatTimer = heartbeat
    }

    private func cancelTimers() {
        deadlineTimer?.cancel()
        deadlineTimer = nil
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    private func deadlineReached() {
        guard let session, let deadline = session.deadline else { return }
        // Gegen die Uhr prüfen, nicht dem Timer vertrauen.
        guard deadline.timeIntervalSinceNow <= 1 else {
            armTimers()
            return
        }
        finish(reason: .expired)
        broadcastLocked(statusLocked())
    }

    private func heartbeat() {
        guard let session else { return }

        if let deadline = session.deadline, deadline <= Date() {
            finish(reason: .expired)
            broadcastLocked(statusLocked())
            return
        }

        // Selbstheilung: Wurde `SleepDisabled` von außen zurückgesetzt
        // (etwa von Hand im Terminal), wieder herstellen.
        if !SleepControl.isSleepDisabled() {
            HelperLog.info("SleepDisabled war zurückgesetzt — wird wieder gesetzt")
            try? SleepControl.setSleepDisabled(true)
        }

        evaluatePolicyLocked(power: PowerWatcher.snapshot())
    }

    // MARK: - Schutzregeln

    private func startPowerWatcherIfNeeded() {
        guard powerWatcher == nil else { return }
        let watcher = PowerWatcher(queue: queue) { [weak self] snapshot in
            self?.evaluatePolicyLocked(power: snapshot)
        }
        powerWatcher = watcher
        // Die Run-Loop-Quelle muss auf der Haupt-Run-Loop registriert werden.
        DispatchQueue.main.async { watcher.start() }
    }

    /// Prüft, ob die Regeln eine laufende Session beenden. Nur auf `queue`.
    private func evaluatePolicyLocked(power: PowerSnapshot) {
        guard let session else { return }
        guard let reason = endReason(for: session.policy, power: power) else { return }

        HelperLog.info("Schutzregel greift: \(reason.rawValue)")
        finish(reason: reason)
        broadcastLocked(statusLocked())
    }

    private func endReason(for policy: SessionPolicy, power: PowerSnapshot) -> SessionEndReason? {
        if policy.stopOnUnplug, !power.isPluggedIn {
            return .powerUnplugged
        }
        if policy.stopOnLowBattery, !power.isPluggedIn,
           let percent = power.percentage, percent < policy.batteryThreshold {
            return .batteryLow
        }
        return nil
    }

    /// Begründung, wenn eine Session unter den aktuellen Bedingungen gar nicht
    /// erst starten kann.
    private func violatedPolicy(_ policy: SessionPolicy, power: PowerSnapshot) -> String? {
        switch endReason(for: policy, power: power) {
        case .powerUnplugged:
            return "Der Mac hängt nicht am Netzteil. "
                + "In den Einstellungen lässt sich das erlauben."
        case .batteryLow:
            let percent = power.percentage.map(String.init) ?? "?"
            return "Der Akku ist bei \(percent) % und damit unter der Schwelle "
                + "von \(policy.batteryThreshold) %."
        default:
            return nil
        }
    }
}

enum HelperError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}
