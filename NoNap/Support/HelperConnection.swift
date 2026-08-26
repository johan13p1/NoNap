//
//  HelperConnection.swift
//  NoNap
//
//  Installation des privilegierten Helfers und die XPC-Verbindung zu ihm.
//
//  Der Helfer wird über SMAppService registriert. macOS fragt dabei nach einem
//  Administrator-Passwort und legt den Dienst danach unter
//  Systemeinstellungen › Allgemein › Anmeldeobjekte offen — dort kann der
//  Benutzer ihn jederzeit wieder abschalten.
//

import Foundation
import Observation
import ServiceManagement

/// Nimmt die Rückmeldungen des Helfers entgegen (abgelaufene Frist, leerer
/// Akku). Bewusst `nonisolated`: XPC ruft auf einem beliebigen Thread auf.
private final class ClientEndpoint: NSObject, NoNapClientProtocol {

    private let onUpdate: @Sendable (HelperStatus) -> Void

    init(onUpdate: @escaping @Sendable (HelperStatus) -> Void) {
        self.onUpdate = onUpdate
    }

    func helperDidUpdateStatus(_ statusData: Data) {
        guard let status = NoNapCoding.decode(HelperStatus.self, from: statusData) else { return }
        onUpdate(status)
    }
}

@Observable
@MainActor
final class HelperConnection {

    enum InstallState: Equatable {
        case unknown
        case notInstalled
        case requiresApproval
        case installed
        case failed(String)
    }

    private(set) var installState: InstallState = .unknown

    /// Letzter bekannter Zustand des Helfers.
    private(set) var status: HelperStatus = HelperStatus()

    /// Wird gesetzt, wenn ein Aufruf schiefging. Die Oberfläche zeigt das an.
    var lastError: String?

    /// Meldet Zustandsänderungen, die vom Helfer ausgingen.
    var onStatusChange: ((HelperStatus) -> Void)?

    @ObservationIgnored
    private var connection: NSXPCConnection?

    private var service: SMAppService {
        SMAppService.daemon(plistName: NoNapIDs.helperPlist)
    }

    // MARK: - Installation

    func refreshInstallState() {
        switch service.status {
        case .enabled:
            installState = .installed
        case .requiresApproval:
            installState = .requiresApproval
        case .notRegistered:
            installState = .notInstalled
        case .notFound:
            installState = .failed("Die Helfer-Datei fehlt im Programmpaket.")
        @unknown default:
            installState = .unknown
        }
    }

    /// Registriert den Helfer. macOS verlangt dabei Administratorrechte.
    func install() {
        do {
            try service.register()
            refreshInstallState()
            if installState == .installed {
                connectAndRefresh()
            }
        } catch let error as NSError {
            // Fehler 1 heißt hier „Vorgang nicht erlaubt": Der Dienst ist
            // registriert, wartet aber noch auf die Freigabe des Benutzers.
            if error.code == 1 {
                installState = .requiresApproval
            } else {
                installState = .failed(error.localizedDescription)
                lastError = "Der Helfer ließ sich nicht einrichten: \(error.localizedDescription)"
            }
        }
    }

    /// Entfernt den Helfer wieder. Eine laufende Session wird vorher beendet,
    /// damit kein Mac zurückbleibt, der nicht mehr einschläft.
    func uninstall() async {
        if status.isActive {
            _ = await stopSession()
        }
        disconnect()
        do {
            try await service.unregister()
        } catch {
            lastError = "Der Helfer ließ sich nicht entfernen: \(error.localizedDescription)"
        }
        refreshInstallState()
        status = HelperStatus()
    }

    func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Verbindung

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: NoNapIDs.helper,
                                         options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: NoNapHelperProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: NoNapClientProtocol.self)

        // Gegenprobe in die andere Richtung: Die App spricht nur mit einem
        // Helfer, der mit derselben Team-ID signiert ist.
        connection.setCodeSigningRequirement(NoNapIDs.helperRequirement)

        connection.exportedObject = ClientEndpoint { [weak self] status in
            guard let self else { return }
            Task { @MainActor in
                self.apply(status)
            }
        }

        // Fällt die Verbindung weg, wird beim nächsten Aufruf eine neue
        // aufgebaut. Der Helfer läuft unabhängig davon weiter.
        let dropConnection: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.connection = nil }
        }
        connection.invalidationHandler = dropConnection
        connection.interruptionHandler = dropConnection

        connection.resume()
        return connection
    }

    private func activeConnection() -> NSXPCConnection {
        if let connection { return connection }
        let fresh = makeConnection()
        connection = fresh
        return fresh
    }

    func disconnect() {
        connection?.invalidate()
        connection = nil
    }

    private func apply(_ status: HelperStatus) {
        self.status = status
        onStatusChange?(status)
    }

    /// Holt einen Proxy und behandelt Verbindungsfehler an einer Stelle.
    private func proxy(
        _ body: @escaping (NoNapHelperProtocol, @escaping (String?) -> Void) -> Void
    ) async -> String? {
        await withCheckedContinuation { continuation in
            let guarded = ContinuationGuard(continuation)

            let remote = activeConnection().remoteObjectProxyWithErrorHandler { error in
                guarded.resume(with: "Der Helfer antwortet nicht: \(error.localizedDescription)")
            }

            guard let helper = remote as? NoNapHelperProtocol else {
                guarded.resume(with: "Der Helfer ist nicht erreichbar.")
                return
            }

            body(helper) { errorText in
                guarded.resume(with: errorText)
            }
        }
    }

    // MARK: - Aufrufe

    func connectAndRefresh() {
        Task { await refreshStatus() }
    }

    @discardableResult
    func refreshStatus() async -> Bool {
        let error = await proxy { helper, done in
            helper.getStatus { data in
                Task { @MainActor in
                    if let status = NoNapCoding.decode(HelperStatus.self, from: data) {
                        self.apply(status)
                        done(nil)
                    } else {
                        done("Der Helfer lieferte keinen lesbaren Zustand.")
                    }
                }
            }
        }
        if let error {
            lastError = error
            return false
        }
        return true
    }

    /// Startet eine Session.
    /// - Parameter deadline: Endzeitpunkt, `nil` für unbegrenzt.
    @discardableResult
    func startSession(deadline: Date?, policy: SessionPolicy) async -> Bool {
        guard let policyData = NoNapCoding.encode(policy) else { return false }

        let error = await proxy { helper, done in
            helper.startSession(deadline: deadline, policyData: policyData) { data, errorText in
                Task { @MainActor in
                    if let status = NoNapCoding.decode(HelperStatus.self, from: data) {
                        self.apply(status)
                    }
                    done(errorText)
                }
            }
        }
        lastError = error
        return error == nil
    }

    @discardableResult
    func extendSession(by seconds: TimeInterval) async -> Bool {
        let error = await proxy { helper, done in
            helper.extendSession(by: seconds) { data, errorText in
                Task { @MainActor in
                    if let status = NoNapCoding.decode(HelperStatus.self, from: data) {
                        self.apply(status)
                    }
                    done(errorText)
                }
            }
        }
        lastError = error
        return error == nil
    }

    @discardableResult
    func stopSession() async -> Bool {
        let error = await proxy { helper, done in
            helper.stopSession { data, errorText in
                Task { @MainActor in
                    if let status = NoNapCoding.decode(HelperStatus.self, from: data) {
                        self.apply(status)
                    }
                    done(errorText)
                }
            }
        }
        lastError = error
        return error == nil
    }

    /// Reicht geänderte Schutzregeln an eine laufende Session weiter.
    func pushPolicy(_ policy: SessionPolicy) async {
        guard status.isActive, let data = NoNapCoding.encode(policy) else { return }
        _ = await proxy { helper, done in
            helper.updatePolicy(data) { statusData, errorText in
                Task { @MainActor in
                    if let status = NoNapCoding.decode(HelperStatus.self, from: statusData) {
                        self.apply(status)
                    }
                    done(errorText)
                }
            }
        }
    }
}

/// Stellt sicher, dass eine Continuation genau einmal fortgesetzt wird.
///
/// Bei XPC kann entweder der Antwortblock oder der Fehlerbehandler zum Zuge
/// kommen. Käme beides, würde ein doppeltes `resume` das Programm beenden.
private final class ContinuationGuard: @unchecked Sendable {
    private var continuation: CheckedContinuation<String?, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func resume(with value: String?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
