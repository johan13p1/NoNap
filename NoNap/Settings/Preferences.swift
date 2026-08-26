//
//  Preferences.swift
//  NoNap
//
//  Alle Einstellungen an einem Ort, gesichert in den UserDefaults.
//
//  Ausnahme ist „Beim Anmelden starten": Das ist kein eigener Wert, sondern
//  wird bei ``LoginItem`` direkt aus dem Zustand des Systems gelesen. Ein
//  gespeicherter Schalter könnte von dem abweichen, was macOS tatsächlich
//  tut — etwa wenn der Benutzer den Eintrag in den Systemeinstellungen
//  abschaltet.
//

import Foundation
import Observation

@Observable
final class Preferences {

    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let defaultDuration = "defaultDurationMinutes"
        static let showCountdown = "showCountdownInMenuBar"
        static let keepDisplayAwake = "keepDisplayAwake"
        static let stopOnLowBattery = "stopOnLowBattery"
        static let batteryThreshold = "batteryThreshold"
        static let stopOnUnplug = "stopOnUnplug"
        static let notifyOnEnd = "notifyOnSessionEnd"
    }

    private init() {
        defaults.register(defaults: [
            Key.defaultDuration: 60,
            Key.showCountdown: true,
            Key.keepDisplayAwake: false,
            Key.stopOnLowBattery: true,
            Key.batteryThreshold: 20,
            Key.stopOnUnplug: false,
            Key.notifyOnEnd: true,
        ])

        defaultDurationMinutes = defaults.integer(forKey: Key.defaultDuration)
        showCountdownInMenuBar = defaults.bool(forKey: Key.showCountdown)
        keepDisplayAwake = defaults.bool(forKey: Key.keepDisplayAwake)
        stopOnLowBattery = defaults.bool(forKey: Key.stopOnLowBattery)
        batteryThreshold = defaults.integer(forKey: Key.batteryThreshold)
        stopOnUnplug = defaults.bool(forKey: Key.stopOnUnplug)
        notifyOnSessionEnd = defaults.bool(forKey: Key.notifyOnEnd)
    }

    /// Dauer, die der Knopf „Session starten" ohne weitere Auswahl verwendet.
    var defaultDurationMinutes: Int {
        didSet { defaults.set(defaultDurationMinutes, forKey: Key.defaultDuration) }
    }

    /// Verbleibende Zeit neben dem Symbol in der Menüleiste anzeigen.
    var showCountdownInMenuBar: Bool {
        didSet { defaults.set(showCountdownInMenuBar, forKey: Key.showCountdown) }
    }

    /// Zusätzlich das Display wachhalten. Bei zugeklapptem Deckel ohne
    /// Wirkung — gedacht für Sitzungen am offenen Gerät.
    var keepDisplayAwake: Bool {
        didSet { defaults.set(keepDisplayAwake, forKey: Key.keepDisplayAwake) }
    }

    var stopOnLowBattery: Bool {
        didSet { defaults.set(stopOnLowBattery, forKey: Key.stopOnLowBattery) }
    }

    var batteryThreshold: Int {
        didSet {
            batteryThreshold = max(5, min(90, batteryThreshold))
            defaults.set(batteryThreshold, forKey: Key.batteryThreshold)
        }
    }

    var stopOnUnplug: Bool {
        didSet { defaults.set(stopOnUnplug, forKey: Key.stopOnUnplug) }
    }

    var notifyOnSessionEnd: Bool {
        didSet { defaults.set(notifyOnSessionEnd, forKey: Key.notifyOnEnd) }
    }

    /// Die Schutzregeln in der Form, in der der Helper sie erwartet.
    var sessionPolicy: SessionPolicy {
        SessionPolicy(stopOnLowBattery: stopOnLowBattery,
                      batteryThreshold: batteryThreshold,
                      stopOnUnplug: stopOnUnplug)
    }
}
