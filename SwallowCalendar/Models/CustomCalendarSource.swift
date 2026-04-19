//
//  CustomCalendarSource.swift
//  SwallowCalendar
//

import Foundation
import SwiftData

@Model
final class CustomCalendarSource {
    var name: String
    var icsURL: String
    var isEnabled: Bool
    var isImportant: Bool = false

    init(name: String, icsURL: String, isEnabled: Bool = false, isImportant: Bool = false) {
        self.name = name
        self.icsURL = icsURL
        self.isEnabled = isEnabled
        self.isImportant = isImportant
    }
}
