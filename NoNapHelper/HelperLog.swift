//
//  HelperLog.swift
//  NoNapHelper
//
//  Protokollierung des Daemons. Sichtbar mit:
//
//      log stream --predicate 'subsystem == "com.johan.NoNap.Helper"' --info
//
//  oder rückblickend:
//
//      log show --last 1h --predicate 'subsystem == "com.johan.NoNap.Helper"' --info
//

import Foundation
import os

enum HelperLog {
    private static let logger = Logger(subsystem: NoNapIDs.helper, category: "helper")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }
}
