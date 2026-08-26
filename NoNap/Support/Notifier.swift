//
//  Notifier.swift
//  NoNap
//
//  Mitteilung, wenn eine Session von selbst endet.
//
//  Bewusst zurückhaltend: Es gibt keine Meldung, wenn der Benutzer die Session
//  selbst beendet — nur wenn sie abläuft oder eine Schutzregel greift. Wer den
//  Deckel zumacht, soll hinterher erkennen können, warum der Mac doch
//  eingeschlafen ist.
//

import Foundation
import UserNotifications

enum Notifier {

    /// Fragt die Erlaubnis einmalig beim Programmstart an.
    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
