//
//  PowerAssertion.swift
//  NoNap
//
//  Gewöhnliche Power-Assertions, die ohne Sonderrechte auskommen.
//
//  Sie ersetzen nicht, was der Helfer tut: Assertions verhindern nur den
//  Leerlauf-Schlaf, beim Zuklappen des Deckels schläft der Mac trotzdem.
//  Sie haben hier zwei andere Aufgaben:
//
//  1. Das Display wachhalten, wenn der Benutzer das möchte (offener Deckel).
//  2. Sichtbarkeit: `pmset -g assertions` zeigt NoNap als Grund an, statt
//     dass der Mac ohne erkennbaren Urheber wach bleibt.
//

import Foundation
import IOKit.pwr_mgt

final class PowerAssertion {

    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private let type: String
    private let reason: String

    /// Verhindert den Leerlauf-Schlaf des Systems.
    static func systemSleep(reason: String) -> PowerAssertion {
        PowerAssertion(type: kIOPMAssertionTypePreventUserIdleSystemSleep, reason: reason)
    }

    /// Verhindert, dass das Display abschaltet.
    static func displaySleep(reason: String) -> PowerAssertion {
        PowerAssertion(type: kIOPMAssertionTypePreventUserIdleDisplaySleep, reason: reason)
    }

    private init(type: String, reason: String) {
        self.type = type
        self.reason = reason
    }

    var isHeld: Bool { assertionID != IOPMAssertionID(0) }

    func acquire() {
        guard !isHeld else { return }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(type as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 reason as CFString,
                                                 &id)
        if result == kIOReturnSuccess {
            assertionID = id
        }
    }

    func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(0)
    }

    deinit {
        if assertionID != IOPMAssertionID(0) {
            IOPMAssertionRelease(assertionID)
        }
    }
}
