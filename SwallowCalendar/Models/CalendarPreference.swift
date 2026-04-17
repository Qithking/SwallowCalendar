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

    init(calendarID: String, isEnabled: Bool = true) {
        self.calendarID = calendarID
        self.isEnabled = isEnabled
    }
}
