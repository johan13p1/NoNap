//
//  SleepControl.swift
//  NoNapHelper
//
//  Schaltet den Systemschlaf ab und wieder an.
//
//  Warum `pmset` und nicht IOKit direkt: Das Zuklappen des Deckels lässt sich
//  ausschließlich über die Power-Management-Einstellung `SleepDisabled`
//  verhindern. Normale Power-Assertions (IOPMAssertionCreateWithName,
//  `caffeinate`) unterdrücken nur den Idle-Schlaf — bei geschlossenem Deckel
//  schläft der Mac trotzdem.
//
//  `SleepDisabled` ist über IOKit nur per privater SPI erreichbar
//  (_IOPMSetSystemPowerSetting ist zwar exportiert, aber in keinem öffentlichen
//  Header deklariert). In einem Prozess, der als root läuft, ist ein
//  undokumentiertes Symbol das schlechtere Geschäft: Es kann bei jedem
//  macOS-Update ohne Vorwarnung verschwinden. `/usr/bin/pmset` ist stabil,
//  im Terminal nachprüfbar und ruft intern exakt dieselbe Funktion auf.
//

import Foundation

enum SleepControlError: LocalizedError {
    case toolMissing
    case commandFailed(status: Int32, output: String)
    case verificationFailed(expected: Bool)

    var errorDescription: String? {
        switch self {
        case .toolMissing:
            return "/usr/bin/pmset wurde nicht gefunden."
        case .commandFailed(let status, let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "pmset endete mit Status \(status)"
                + (detail.isEmpty ? "." : ": \(detail)")
        case .verificationFailed(let expected):
            return "SleepDisabled ließ sich nicht auf \(expected ? "1" : "0") setzen."
        }
    }
}

enum SleepControl {

    private static let pmsetPath = "/usr/bin/pmset"

    /// Setzt `SleepDisabled` und prüft anschließend nach, ob die Änderung
    /// tatsächlich angekommen ist. Ohne diese Gegenprobe könnte die App eine
    /// aktive Session anzeigen, während der Mac beim Zuklappen einschläft.
    static func setSleepDisabled(_ disabled: Bool) throws {
        guard FileManager.default.isExecutableFile(atPath: pmsetPath) else {
            throw SleepControlError.toolMissing
        }

        let result = try run(pmsetPath, ["-a", "disablesleep", disabled ? "1" : "0"])
        guard result.status == 0 else {
            throw SleepControlError.commandFailed(status: result.status,
                                                  output: result.output)
        }

        guard isSleepDisabled() == disabled else {
            throw SleepControlError.verificationFailed(expected: disabled)
        }

        HelperLog.info("SleepDisabled = \(disabled ? 1 : 0)")
    }

    /// Liest den tatsächlichen Zustand aus dem Power Management.
    ///
    /// `pmset -g` führt `SleepDisabled` nur auf, wenn es gesetzt ist; fehlt die
    /// Zeile, ist der Schlaf normal aktiv.
    static func isSleepDisabled() -> Bool {
        guard let result = try? run(pmsetPath, ["-g"]), result.status == 0 else {
            return false
        }
        for line in result.output.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count >= 2, parts[0] == "SleepDisabled" {
                return parts[1] == "1"
            }
        }
        return false
    }

    /// Stellt sicher, dass der Schlaf wieder freigegeben ist. Wird beim
    /// Aufräumen verwendet und schluckt Fehler bewusst — ein fehlgeschlagener
    /// Reset darf das Beenden einer Session nicht blockieren, wird aber
    /// protokolliert.
    @discardableResult
    static func releaseQuietly() -> Bool {
        do {
            try setSleepDisabled(false)
            return true
        } catch {
            HelperLog.error("Schlaf konnte nicht freigegeben werden: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Prozessaufruf

    private struct CommandResult {
        let status: Int32
        let output: String
    }

    private static func run(_ path: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        // Vor `waitUntilExit` lesen, damit ein voller Pipe-Puffer nicht
        // zum Deadlock führt.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CommandResult(status: process.terminationStatus,
                             output: String(decoding: data, as: UTF8.self))
    }
}
