//
//  LoginItem.swift
//  NoNap
//
//  „Beim Anmelden starten" über SMAppService.
//
//  Der Zustand wird immer frisch beim System erfragt statt gespeichert: Der
//  Benutzer kann den Eintrag jederzeit in den Systemeinstellungen abschalten,
//  und dann soll der Schalter in NoNap das auch zeigen.
//

import Foundation
import ServiceManagement

enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Meldet, ob der Benutzer den Eintrag in den Systemeinstellungen
    /// ausdrücklich blockiert hat. Dann hilft nur der Weg über die
    /// Systemeinstellungen.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status == .enabled else { return }
            try service.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
