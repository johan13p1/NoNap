//
//  Formatting.swift
//  NoNap
//
//  Zeitangaben für Menüleiste und Oberfläche.
//

import Foundation

enum Formatting {

    /// Kompakte Restzeit für die Menüleiste: „1:23" oder „12:05:30".
    ///
    /// Unter einer Stunde wird Minute:Sekunde gezeigt, darüber
    /// Stunde:Minute — eine sekundengenaue Anzeige über Stunden hinweg wäre
    /// nur Unruhe in der Menüleiste.
    static func menuBarCountdown(_ remaining: TimeInterval) -> String {
        let total = Int(remaining.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 0 {
            return String(format: "%d:%02d", hours, minutes)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Ausführliche Restzeit: „noch 2 Stunden 15 Minuten".
    static func longRemaining(_ remaining: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = remaining < 3600 ? [.minute, .second] : [.hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: max(0, remaining)) ?? "–"
    }

    /// Endzeitpunkt als Uhrzeit: „bis 17:30".
    static func endTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .none
        formatter.timeStyle = .short

        if !Calendar.current.isDateInToday(date) {
            formatter.dateStyle = .short
        }
        return formatter.string(from: date)
    }

    /// Dauer für Knöpfe und Menüs: „30 Min.", „2 Std.", „1 Std. 30 Min."
    static func duration(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60

        switch (hours, rest) {
        case (0, let m):
            return "\(m) Min."
        case (let h, 0):
            return "\(h) Std."
        case (let h, let m):
            return "\(h) Std. \(m) Min."
        }
    }
}
