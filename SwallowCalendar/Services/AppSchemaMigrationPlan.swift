//
//  AppSchemaMigrationPlan.swift
//  SwallowCalendar
//
//  SwiftData 数据库迁移计划 - 确保模型变更时数据不会丢失
//

import Foundation
import SwiftData

enum AppSchemaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [AppSchemaV1.self, AppSchemaV2.self]
    }
    
    static var stages: [MigrationStage] {
        [migrateV1toV2]
    }
    
    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: AppSchemaV1.self,
        toVersion: AppSchemaV2.self
    )
}

// MARK: - V1 Schema (原始版本)

enum AppSchemaV1: VersionedSchema {
    static var models: [any PersistentModel.Type] {
        [CalendarPreference.self, CustomCalendarSource.self, CachedEvent.self]
    }
    
    static var versionIdentifier: Schema.Version = Schema.Version(1, 0, 0)
    
    @Model
    final class CalendarPreference {
        var calendarID: String
        var isEnabled: Bool
        var isImportant: Bool
        
        init(calendarID: String, isEnabled: Bool, isImportant: Bool) {
            self.calendarID = calendarID
            self.isEnabled = isEnabled
            self.isImportant = isImportant
        }
    }
    
    @Model
    final class CustomCalendarSource {
        var name: String
        var icsURL: String
        var isEnabled: Bool
        var isImportant: Bool
        
        init(name: String, icsURL: String, isEnabled: Bool, isImportant: Bool) {
            self.name = name
            self.icsURL = icsURL
            self.isEnabled = isEnabled
            self.isImportant = isImportant
        }
    }
    
    @Model
    final class CachedEvent {
        @Attribute(.unique) var eventID: String
        var title: String
        var startDate: Date?
        var endDate: Date?
        var isAllDay: Bool
        var calendarID: String
        var calendarTitle: String
        var calendarColorHex: String
        var categoryRaw: String
        var isCompleted: Bool
        var priority: Int
        var lastUpdated: Date
        
        init(
            eventID: String,
            title: String,
            startDate: Date?,
            endDate: Date?,
            isAllDay: Bool,
            calendarID: String,
            calendarTitle: String,
            calendarColorHex: String,
            categoryRaw: String,
            isCompleted: Bool,
            priority: Int,
            lastUpdated: Date
        ) {
            self.eventID = eventID
            self.title = title
            self.startDate = startDate
            self.endDate = endDate
            self.isAllDay = isAllDay
            self.calendarID = calendarID
            self.calendarTitle = calendarTitle
            self.calendarColorHex = calendarColorHex
            self.categoryRaw = categoryRaw
            self.isCompleted = isCompleted
            self.priority = priority
            self.lastUpdated = lastUpdated
        }
    }
}

// MARK: - V2 Schema (当前版本，添加了新字段)

enum AppSchemaV2: VersionedSchema {
    static var models: [any PersistentModel.Type] {
        [CalendarPreference.self, CustomCalendarSource.self, CachedEvent.self]
    }
    
    static var versionIdentifier: Schema.Version = Schema.Version(2, 0, 0)
    
    @Model
    final class CalendarPreference {
        var calendarID: String
        var isEnabled: Bool
        var isImportant: Bool
        
        init(calendarID: String, isEnabled: Bool, isImportant: Bool) {
            self.calendarID = calendarID
            self.isEnabled = isEnabled
            self.isImportant = isImportant
        }
    }
    
    @Model
    final class CustomCalendarSource {
        var name: String
        var icsURL: String
        var isEnabled: Bool
        var isImportant: Bool
        
        init(name: String, icsURL: String, isEnabled: Bool, isImportant: Bool) {
            self.name = name
            self.icsURL = icsURL
            self.isEnabled = isEnabled
            self.isImportant = isImportant
        }
    }
    
    @Model
    final class CachedEvent {
        @Attribute(.unique) var eventID: String
        var title: String
        var startDate: Date?
        var endDate: Date?
        var isAllDay: Bool
        var calendarID: String
        var calendarTitle: String
        var calendarColorHex: String
        var categoryRaw: String
        var isCompleted: Bool
        var priority: Int
        var groupId: String?
        var groupIndex: Int
        var recurrenceTypeRaw: String?
        var isLunar: Bool
        var lastUpdated: Date
        
        init(
            eventID: String,
            title: String,
            startDate: Date?,
            endDate: Date?,
            isAllDay: Bool,
            calendarID: String,
            calendarTitle: String,
            calendarColorHex: String,
            categoryRaw: String,
            isCompleted: Bool,
            priority: Int,
            groupId: String?,
            groupIndex: Int,
            recurrenceTypeRaw: String?,
            isLunar: Bool,
            lastUpdated: Date
        ) {
            self.eventID = eventID
            self.title = title
            self.startDate = startDate
            self.endDate = endDate
            self.isAllDay = isAllDay
            self.calendarID = calendarID
            self.calendarTitle = calendarTitle
            self.calendarColorHex = calendarColorHex
            self.categoryRaw = categoryRaw
            self.isCompleted = isCompleted
            self.priority = priority
            self.groupId = groupId
            self.groupIndex = groupIndex
            self.recurrenceTypeRaw = recurrenceTypeRaw
            self.isLunar = isLunar
            self.lastUpdated = lastUpdated
        }
    }
}
