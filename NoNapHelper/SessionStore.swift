//
//  SessionStore.swift
//  NoNapHelper
//
//  Legt die laufende Session auf der Platte ab, damit der Helper nach einem
//  Absturz oder Neustart weiß, in welchem Zustand er das System hinterlassen
//  hat.
//
//  Das ist kein Komfort, sondern die Absicherung gegen den schlimmsten Fall:
//  `SleepDisabled` überlebt einen Neustart. Ohne diesen Abgleich könnte ein
//  Mac dauerhaft mit abgeschaltetem Schlaf zurückbleiben, ohne dass irgendwo
//  eine Session sichtbar wäre.
//

import Foundation

/// Was der Helper über einen Neustart hinweg festhält.
struct PersistedSession: Codable {
    var deadline: Date?
    var startedAt: Date
    var policy: SessionPolicy
    /// Boot-Zeitpunkt des Systems, in dem die Session gestartet wurde.
    /// Weicht er beim Lesen ab, gab es zwischenzeitlich einen Neustart und die
    /// Session gilt als hinfällig.
    var bootTime: Date
}

enum SessionStore {

    private static let directory = "/Library/Application Support/NoNap"
    private static let fileURL = URL(fileURLWithPath: directory + "/session.json")

    // MARK: - Boot-Zeit

    /// Zeitpunkt des letzten Systemstarts über `sysctl kern.boottime`.
    static func systemBootTime() -> Date {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]

        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0, tv.tv_sec != 0 else {
            // Ohne verlässliche Boot-Zeit lieber ein Wert, der garantiert von
            // jedem gespeicherten abweicht: Die Session wird dann verworfen
            // und der Schlaf freigegeben — die sichere Richtung.
            HelperLog.error("kern.boottime nicht lesbar, Session wird verworfen")
            return Date.distantFuture
        }
        return Date(timeIntervalSince1970: Double(tv.tv_sec))
    }

    // MARK: - Lesen und Schreiben

    static func load() -> PersistedSession? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let session = try? NoNapCoding.decoder.decode(PersistedSession.self, from: data) else {
            HelperLog.error("session.json ist unlesbar und wird verworfen")
            clear()
            return nil
        }
        return session
    }

    static func save(_ session: PersistedSession) {
        do {
            try ensureDirectory()
            let data = try NoNapCoding.encoder.encode(session)
            try data.write(to: fileURL, options: [.atomic])
            // Nur root darf lesen und schreiben.
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: fileURL.path)
        } catch {
            HelperLog.error("session.json konnte nicht geschrieben werden: \(error.localizedDescription)")
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func ensureDirectory() throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: directory) else { return }
        try fm.createDirectory(atPath: directory,
                               withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
    }
}
