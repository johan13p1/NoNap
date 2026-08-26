//
//  main.swift
//  NoNapHelper
//
//  Einstiegspunkt des privilegierten Daemons.
//
//  Wird von launchd als root gestartet — beim Anmelden über `RunAtLoad`, damit
//  nach einem Neustart auf jeden Fall jemand nachsieht, ob `SleepDisabled`
//  noch zu Recht gesetzt ist.
//

import Foundation

let manager = SessionManager()

// Erst aufräumen, dann Verbindungen annehmen: Der Abgleich mit dem
// tatsächlichen Zustand des Power Managements muss passiert sein, bevor die
// App einen Status abfragen kann.
manager.startUp()

let listener = HelperListener(manager: manager)
listener.start()

// launchd beendet Daemons mit SIGTERM. Den Schlaf dabei freizugeben ist
// wichtig: Sonst bliebe ein Mac zurück, der nicht mehr einschläft, während
// niemand mehr da ist, der ihn wieder freigeben könnte.
signal(SIGTERM, SIG_IGN)
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminationSource.setEventHandler {
    HelperLog.info("SIGTERM empfangen")
    manager.shutDown()
    exit(0)
}
terminationSource.resume()

// `RunLoop.main.run()` statt `dispatchMain()`: Die Überwachung der
// Stromversorgung hängt als CFRunLoopSource an der Haupt-Run-Loop, und die
// läuft unter `dispatchMain()` nicht.
RunLoop.main.run()
