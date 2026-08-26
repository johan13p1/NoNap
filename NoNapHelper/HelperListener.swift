//
//  HelperListener.swift
//  NoNapHelper
//
//  Nimmt XPC-Verbindungen der App entgegen.
//
//  Sicherheitshinweis: Dieser Prozess läuft als root. Ein Mach-Service, den
//  jeder ansprechen darf, wäre eine Rechteausweitung für jedes beliebige
//  Programm auf dem Rechner. Deshalb prüft der Listener über
//  `setConnectionCodeSigningRequirement` die Signatur der Gegenstelle, bevor
//  eine Verbindung überhaupt zustande kommt. Nur eine mit der hinterlegten
//  Team-ID signierte NoNap.app kommt durch.
//

import Foundation

final class HelperListener: NSObject, NSXPCListenerDelegate {

    private let listener: NSXPCListener
    private let manager: SessionManager

    init(manager: SessionManager) {
        self.manager = manager
        self.listener = NSXPCListener(machServiceName: NoNapIDs.helper)
        super.init()
        listener.delegate = self
    }

    func start() {
        // Die Signaturprüfung greift, bevor `listener(_:shouldAcceptNewConnection:)`
        // aufgerufen wird. Verbindungen, die das Requirement nicht erfüllen,
        // werden von XPC selbst abgewiesen.
        listener.setConnectionCodeSigningRequirement(NoNapIDs.appRequirement)
        listener.resume()
        HelperLog.info("Mach-Service \(NoNapIDs.helper) bereit")
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {

        connection.exportedInterface = NSXPCInterface(with: NoNapHelperProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: NoNapClientProtocol.self)

        let service = HelperService(manager: manager)
        connection.exportedObject = service

        // Zustandsänderungen, die nicht von der App ausgelöst wurden
        // (Frist abgelaufen, Akku leer), an die App zurückmelden.
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            HelperLog.debug("Rückkanal nicht erreichbar: \(error.localizedDescription)")
        } as? NoNapClientProtocol

        let observerID = manager.addObserver { data in
            proxy?.helperDidUpdateStatus(data)
        }

        // Der Helper beendet sich bewusst nicht, wenn die letzte App-Verbindung
        // wegfällt: Eine laufende Session soll auch dann bis zu ihrem Ende
        // weiterlaufen, wenn die App abgestürzt ist oder beendet wurde.
        let cleanUp: () -> Void = { [weak manager] in
            manager?.removeObserver(observerID)
        }
        connection.invalidationHandler = cleanUp
        connection.interruptionHandler = cleanUp

        connection.resume()
        HelperLog.debug("Verbindung von PID \(connection.processIdentifier) angenommen")
        return true
    }
}

/// Die Umsetzung der XPC-Schnittstelle. Jede Verbindung bekommt eine eigene
/// Instanz; der Zustand liegt gemeinsam im ``SessionManager``.
final class HelperService: NSObject, NoNapHelperProtocol {

    private let manager: SessionManager

    init(manager: SessionManager) {
        self.manager = manager
    }

    func getVersion(reply: @escaping (String, Int) -> Void) {
        reply(SessionManager.version, kNoNapProtocolVersion)
    }

    func getStatus(reply: @escaping (Data?) -> Void) {
        reply(NoNapCoding.encode(manager.status()))
    }

    func startSession(deadline: Date?,
                      policyData: Data,
                      reply: @escaping (Data?, String?) -> Void) {
        guard let policy = NoNapCoding.decode(SessionPolicy.self, from: policyData) else {
            reply(nil, "Die Einstellungen konnten nicht gelesen werden.")
            return
        }
        do {
            let status = try manager.start(deadline: deadline, policy: policy)
            reply(NoNapCoding.encode(status), nil)
        } catch {
            HelperLog.error("Start fehlgeschlagen: \(error.localizedDescription)")
            reply(nil, error.localizedDescription)
        }
    }

    func extendSession(by seconds: TimeInterval,
                       reply: @escaping (Data?, String?) -> Void) {
        do {
            let status = try manager.extend(by: seconds)
            reply(NoNapCoding.encode(status), nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    func stopSession(reply: @escaping (Data?, String?) -> Void) {
        reply(NoNapCoding.encode(manager.stop()), nil)
    }

    func updatePolicy(_ policyData: Data,
                      reply: @escaping (Data?, String?) -> Void) {
        guard let policy = NoNapCoding.decode(SessionPolicy.self, from: policyData) else {
            reply(nil, "Die Einstellungen konnten nicht gelesen werden.")
            return
        }
        reply(NoNapCoding.encode(manager.updatePolicy(policy)), nil)
    }
}
