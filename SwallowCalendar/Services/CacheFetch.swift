//
//  CacheFetch.swift
//  SwallowCalendar
//
//  统一缓存查询入口（审计 M6）：把「查询失败」与「查询为空」显式分开，
//  禁止再用 try? 吞掉 fetch 错误，避免列表/提醒/同步静默失效且无日志。
//

import Foundation
import SwiftData
import os

enum CacheFetch {
    /// 查询失败错误：携带操作名，供上层感知并中止破坏性操作
    struct Failure: LocalizedError {
        let operation: String
        let underlying: Error

        var errorDescription: String? {
            "\(operation) 查询失败：\(underlying.localizedDescription)"
        }
    }

    /// 统一执行体：任何查询失败都记录日志并包装为 Failure 抛出。
    /// 集中在此一处，便于用例直接验证「失败必上报」的机制（审计 M6）
    static func perform<T>(operation: String, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            AppLogger.cache.error("\(operation) 查询失败: \(String(describing: error))")
            throw Failure(operation: operation, underlying: error)
        }
    }

    /// 失败必须上报：写路径/同步路径/删除路径使用，调用方应中止后续破坏性操作
    static func throwing<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        in context: ModelContext,
        operation: String
    ) throws -> [T] {
        try perform(operation: operation) { try context.fetch(descriptor) }
    }

    /// 失败返回 nil（区别于空数组）：读路径使用，调用方须显式区分「失败」与「没有数据」
    static func optional<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        in context: ModelContext,
        operation: String
    ) -> [T]? {
        try? perform(operation: operation) { try context.fetch(descriptor) }
    }

    /// 计数失败降级为 0：仅用于展示型计数，失败必须落日志
    static func countDegradingToZero<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        in context: ModelContext,
        operation: String
    ) -> Int {
        do {
            return try context.fetchCount(descriptor)
        } catch {
            AppLogger.cache.error("\(operation) 计数失败，按 0 展示: \(String(describing: error))")
            return 0
        }
    }

    /// 失败降级为空：仅用于「失败与空的业务后果等价」且可安全继续的读路径。
    /// reason 必填说明降级理由，日志同时记录失败与理由，便于排查
    static func degradeToEmpty<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        in context: ModelContext,
        operation: String,
        reason: String
    ) -> [T] {
        do {
            return try context.fetch(descriptor)
        } catch {
            AppLogger.cache.error("\(operation) 查询失败，降级为空（\(reason)）: \(String(describing: error))")
            return []
        }
    }
}
