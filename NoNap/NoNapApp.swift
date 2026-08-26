//
//  NoNapApp.swift
//  NoNap
//
//  Hält den Mac auf Wunsch wach — auch bei zugeklapptem Deckel.
//
//  NoNap besteht aus zwei Teilen:
//
//  • Dieser App in der Menüleiste. Sie zeigt an und steuert, hat aber keine
//    Sonderrechte.
//  • Einem kleinen Hintergrunddienst (NoNapHelper), der als LaunchDaemon
//    läuft. Nur er darf die Systemeinstellung setzen, die das Einschlafen bei
//    geschlossenem Deckel verhindert.
//
//  Die Trennung ist Absicht: Alles, was Systemrechte braucht, steckt in
//  wenigen überschaubaren Dateien, und der Dienst lässt sich jederzeit unter
//  Systemeinstellungen › Allgemein › Anmeldeobjekte abschalten.
//

import AppKit
import SwiftUI

@main
struct NoNapApp: App {

    // Das Modell gehört dem Delegate: Nur so steht es schon fest, wenn
    // `applicationDidFinishLaunching` läuft. Läge es als `@State` in der
    // Scene, wäre es dort noch nicht erreichbar — der Inhalt eines
    // MenuBarExtra wird erst gebaut, wenn das Panel zum ersten Mal aufgeht.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(delegate.model)
        }
    }
}

/// Symbol und optionaler Countdown in der Menüleiste.
private struct MenuBarLabel: View {

    let model: AppModel

    var body: some View {
        // Ein gefülltes Symbol bei laufender Session, ein leeres sonst: Der
        // Zustand muss auf einen Blick erkennbar sein, auch ohne Countdown.
        if let text = model.menuBarText {
            HStack(spacing: 3) {
                Image(systemName: "cup.and.saucer.fill")
                Text(text)
                    .monospacedDigit()
            }
        } else {
            Image(systemName: model.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Reine Menüleisten-App: kein Dock-Symbol, kein Programm-Menü.
        // Doppelt zu `LSUIElement` in der Info.plist, aber unabhängig davon
        // wirksam, falls dieser Schlüssel einmal verloren geht.
        NSApp.setActivationPolicy(.accessory)
        Notifier.requestAuthorizationIfNeeded()
        model.onAppear()
    }

    /// Beim ausdrücklichen Beenden nachfragen, solange eine Session läuft.
    ///
    /// Ohne die App gibt es keine Oberfläche mehr, um die Session zu stoppen —
    /// der Hintergrunddienst würde sie bis zum Ablauf weiterführen. Das kann
    /// gewollt sein, darf aber nicht unbemerkt passieren.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isActive else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Es läuft noch eine Session."
        alert.informativeText = "Der Mac bleibt wach, bis die Session endet. "
            + "Soll sie zusammen mit NoNap beendet werden?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Beenden und Mac freigeben")
        alert.addButton(withTitle: "Session weiterlaufen lassen")
        alert.addButton(withTitle: "Abbrechen")

        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                await model.stop()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater

        case .alertSecondButtonReturn:
            return .terminateNow

        default:
            return .terminateCancel
        }
    }
}
