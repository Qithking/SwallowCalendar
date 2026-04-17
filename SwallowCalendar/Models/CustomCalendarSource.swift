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

    init(name: String, icsURL: String, isEnabled: Bool = true) {
        self.name = name
        self.icsURL = icsURL
        self.isEnabled = isEnabled
    }
}
