//
//  CalendarPreference.swift
//  SwallowCalendar
//

import Foundation
import SwiftData

@Model
final class CalendarPreference {
    var calendarID: String
    var isEnabled: Bool
    var isImportant: Bool = false

    init(calendarID: String, isEnabled: Bool = false, isImportant: Bool = false) {
        self.calendarID = calendarID
        self.isEnabled = isEnabled
        self.isImportant = isImportant
    }
}
