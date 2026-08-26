//
//  NoNapShared.swift
//  Geteilt zwischen NoNap (App) und NoNapHelper (privilegierter Daemon).
//
//  Enthält die XPC-Schnittstelle sowie alle Bezeichner, die beide Seiten
//  identisch kennen müssen. Änderungen hier betreffen immer beide Targets.
//

import Foundation

// MARK: - Bezeichner

public enum NoNapIDs {
    /// Bundle-Identifier der Menüleisten-App.
    public static let app = "com.johan.NoNap"

    /// Label des LaunchDaemons und zugleich Name des Mach-Service.
    public static let helper = "com.johan.NoNap.Helper"

    /// Dateiname der LaunchDaemon-Property-List in Contents/Library/LaunchDaemons.
    public static let helperPlist = "com.johan.NoNap.Helper.plist"

    /// Team-ID, gegen die beide Seiten die Signatur der Gegenstelle prüfen.
    public static let teamID = "FZL5999DHB"

    /// Code-Signing-Requirement, das der Helper von der App verlangt.
    public static var appRequirement: String {
        "identifier \"\(app)\" and anchor apple generic "
            + "and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// Code-Signing-Requirement, das die App vom Helper verlangt.
    public static var helperRequirement: String {
        "identifier \"\(helper)\" and anchor apple generic "
            + "and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}

/// Protokollversion. Wird beim Verbinden abgeglichen; weicht sie ab, installiert
/// die App den Helper neu. Bei jeder inkompatiblen Änderung an
/// `NoNapHelperProtocol` hochzählen.
public let kNoNapProtocolVersion = 1

// MARK: - Zustand

/// Warum eine Session beendet wurde. Die App zeigt das dem Benutzer an.
public enum SessionEndReason: String, Codable, Sendable {
    case userStopped
    case expired
    case batteryLow
    case powerUnplugged
    case helperShutdown
    case rebootDetected
}

/// Regeln, unter denen der Helper eine laufende Session von sich aus beendet.
/// Der Helper überwacht das selbst, damit die Schutzabschaltung auch dann
/// greift, wenn die App abgestürzt oder blockiert ist.
public struct SessionPolicy: Codable, Sendable, Equatable {
    /// Session beenden, wenn der Akkustand unter `batteryThreshold` fällt.
    public var stopOnLowBattery: Bool
    /// Schwelle in Prozent (1...99).
    public var batteryThreshold: Int
    /// Session beenden, sobald das Netzteil abgezogen wird.
    public var stopOnUnplug: Bool

    public init(stopOnLowBattery: Bool = true,
                batteryThreshold: Int = 20,
                stopOnUnplug: Bool = false) {
        self.stopOnLowBattery = stopOnLowBattery
        self.batteryThreshold = max(1, min(99, batteryThreshold))
        self.stopOnUnplug = stopOnUnplug
    }

    public static let `default` = SessionPolicy()
}

/// Momentaufnahme des Helper-Zustands. Der Helper ist die maßgebliche Quelle:
/// Er kennt die Deadline, zählt sie herunter und räumt auf — auch ohne App.
public struct HelperStatus: Codable, Sendable, Equatable {
    /// Läuft gerade eine Session?
    public var isActive: Bool
    /// Zeitpunkt, zu dem die Session endet. `nil` bedeutet unbegrenzt.
    public var deadline: Date?
    /// Beginn der laufenden Session.
    public var startedAt: Date?
    /// Ist `SleepDisabled` im Power Management tatsächlich gesetzt?
    /// Weicht das von `isActive` ab, stimmt etwas nicht.
    public var sleepDisabled: Bool
    /// Grund der zuletzt beendeten Session.
    public var lastEndReason: SessionEndReason?
    public var policy: SessionPolicy
    public var helperVersion: String

    public init(isActive: Bool = false,
                deadline: Date? = nil,
                startedAt: Date? = nil,
                sleepDisabled: Bool = false,
                lastEndReason: SessionEndReason? = nil,
                policy: SessionPolicy = .default,
                helperVersion: String = "") {
        self.isActive = isActive
        self.deadline = deadline
        self.startedAt = startedAt
        self.sleepDisabled = sleepDisabled
        self.lastEndReason = lastEndReason
        self.policy = policy
        self.helperVersion = helperVersion
    }

    /// Verbleibende Zeit, oder `nil` bei unbegrenzter bzw. inaktiver Session.
    public var remaining: TimeInterval? {
        guard isActive, let deadline else { return nil }
        return max(0, deadline.timeIntervalSinceNow)
    }
}

// MARK: - XPC-Schnittstelle

/// Was die App beim Helper aufrufen darf.
///
/// Strukturen werden als JSON-`Data` übertragen. Das erspart
/// `NSSecureCoding`-Klassen auf beiden Seiten und hält die Schnittstelle
/// so schmal, dass sie sich leicht prüfen lässt — wichtig, weil die
/// Gegenstelle als root läuft.
@objc public protocol NoNapHelperProtocol {

    /// Version und Protokollversion des Helpers.
    func getVersion(reply: @escaping (String, Int) -> Void)

    /// Aktueller Zustand, JSON-kodierter ``HelperStatus``.
    func getStatus(reply: @escaping (Data?) -> Void)

    /// Startet eine Session.
    /// - Parameters:
    ///   - deadline: Endzeitpunkt, oder `nil` für unbegrenzt.
    ///   - policyData: JSON-kodierte ``SessionPolicy``.
    ///   - reply: Neuer Zustand als JSON, oder Fehlertext.
    func startSession(deadline: Date?,
                      policyData: Data,
                      reply: @escaping (Data?, String?) -> Void)

    /// Verschiebt die Deadline der laufenden Session um `seconds` nach hinten.
    func extendSession(by seconds: TimeInterval,
                       reply: @escaping (Data?, String?) -> Void)

    /// Beendet die Session und gibt den Schlafmodus wieder frei.
    func stopSession(reply: @escaping (Data?, String?) -> Void)

    /// Übernimmt geänderte Schutzregeln in die laufende Session.
    func updatePolicy(_ policyData: Data,
                      reply: @escaping (Data?, String?) -> Void)
}

/// Was der Helper bei der App aufrufen darf: Zustandsänderungen, die nicht
/// von der App ausgelöst wurden — abgelaufene Deadline, leerer Akku,
/// abgezogenes Netzteil.
@objc public protocol NoNapClientProtocol {
    /// JSON-kodierter ``HelperStatus``.
    func helperDidUpdateStatus(_ statusData: Data)
}

// MARK: - Kodierhilfen

public enum NoNapCoding {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func encode<T: Encodable>(_ value: T) -> Data? {
        try? encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
