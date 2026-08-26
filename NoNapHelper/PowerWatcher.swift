//
//  PowerWatcher.swift
//  NoNapHelper
//
//  Beobachtet Akkustand und Stromversorgung.
//
//  Die Überwachung sitzt bewusst im Helper und nicht in der App: Ein
//  zugeklappter Mac, dessen Schlaf abgeschaltet ist, entlädt sich bis zum
//  Ende — im Rucksack wird er dabei warm. Diese Notbremse muss auch dann
//  greifen, wenn die App abgestürzt ist oder hängt.
//

import Foundation
import IOKit.ps

struct PowerSnapshot: Equatable {
    /// Ladestand in Prozent, `nil` wenn kein Akku vorhanden ist (Desktop-Mac).
    var percentage: Int?
    /// Hängt der Mac am Netzteil?
    var isPluggedIn: Bool
}

final class PowerWatcher {

    /// Wird bei jeder Änderung auf der übergebenen Queue aufgerufen.
    private let onChange: (PowerSnapshot) -> Void
    private let queue: DispatchQueue
    private var runLoopSource: CFRunLoopSource?

    init(queue: DispatchQueue, onChange: @escaping (PowerSnapshot) -> Void) {
        self.queue = queue
        self.onChange = onChange
    }

    // MARK: - Momentaufnahme

    static func snapshot() -> PowerSnapshot {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return PowerSnapshot(percentage: nil, isPluggedIn: true)
        }

        // Der Netzteilzustand steht systemweit fest und ist verlässlicher als
        // das Feld je Stromquelle.
        let providingType = IOPSGetProvidingPowerSourceType(blob)?
            .takeUnretainedValue() as String?
        let plugged = providingType == kIOPSACPowerValue

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }

            guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else {
                continue
            }

            guard let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int,
                  max > 0
            else { continue }

            let percent = Int((Double(current) / Double(max) * 100).rounded())
            return PowerSnapshot(percentage: percent, isPluggedIn: plugged)
        }

        // Kein interner Akku gefunden.
        return PowerSnapshot(percentage: nil, isPluggedIn: plugged)
    }

    // MARK: - Beobachtung

    func start() {
        guard runLoopSource == nil else { return }

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let watcher = Unmanaged<PowerWatcher>.fromOpaque(ctx).takeUnretainedValue()
            watcher.notifyChange()
        }, context)?.takeRetainedValue() else {
            HelperLog.error("Stromversorgung kann nicht überwacht werden")
            return
        }

        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        HelperLog.debug("PowerWatcher gestartet")
    }

    func stop() {
        guard let source = runLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = nil
    }

    private func notifyChange() {
        let snapshot = Self.snapshot()
        queue.async { [onChange] in
            onChange(snapshot)
        }
    }
}
