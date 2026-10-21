//
//  MinHeapTests.swift
//  SwallowCalendarTests
//
//  B-4/AC-1：MinHeap 任意位置删除（remove）后堆不变量验证
//

import XCTest
@testable import SwallowCalendar

class MinHeapTests: XCTestCase {

    /// 确定性伪随机数（SplitMix64），保证测试结果可重复
    private var rngState: UInt64 = 0x2026_1021

    private func nextRandom() -> UInt64 {
        rngState &+= 0x9E3779B97F4A7C15
        var z = rngState
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    // B-4/AC-1：随机 1000 次插入/删除，每次操作后 peek 必须恒等于剩余元素最小值
    func testRandomInsertRemovePeekAlwaysMinimum() {
        let heap = CountdownTimerManager.MinHeap()
        // 参照字典：eventID -> deadline，与堆内容同步维护用于对照
        var reference: [String: Date] = [:]
        let base = Date(timeIntervalSince1970: 0)
        var counter = 0

        for _ in 0..<1000 {
            // 堆较小时偏向插入，保证样本量；否则插入/删除各半
            let shouldInsert = reference.count < 10 || nextRandom() % 2 == 0

            if shouldInsert {
                let id = "event-\(counter)"
                counter += 1
                let deadline = base.addingTimeInterval(TimeInterval(nextRandom() % 100_000))
                heap.insert(eventID: id, deadline: deadline)
                reference[id] = deadline
            } else if let victim = reference.keys.first {
                heap.remove(eventID: victim)
                reference.removeValue(forKey: victim)
            }

            // 堆顶必须恒等于参照集合的最小 deadline
            if let minRef = reference.values.min() {
                XCTAssertEqual(heap.peek()?.deadline, minRef)
            } else {
                XCTAssertTrue(heap.isEmpty)
                XCTAssertNil(heap.peek())
            }
        }

        // 收尾：依次弹出应得到与参照集合一致的升序序列
        var popped: [TimeInterval] = []
        while let top = heap.removeTop() {
            popped.append(top.deadline.timeIntervalSince1970)
        }
        XCTAssertEqual(popped, reference.values.map { $0.timeIntervalSince1970 }.sorted())
    }

    // B-4 具体场景：任意位置删除后替换元素需上浮（原实现仅 siftDown 破坏堆序）
    func testRemoveTriggersSiftUp() {
        let heap = CountdownTimerManager.MinHeap()
        // 插入后数组布局 [60, 540, 180, 600, 660, 720, 480]（有效最小堆），
        // remove(d11)（index 4，值 660）后末尾 480 顶替其位，
        // parent 540 > 480 需上浮——仅 siftDown 无法恢复
        let items: [(String, TimeInterval)] = [
            ("d1", 60), ("d9", 540), ("d3", 180), ("d10", 600),
            ("d11", 660), ("d12", 720), ("d8", 480),
        ]
        for (id, sec) in items {
            heap.insert(eventID: id, deadline: Date(timeIntervalSince1970: sec))
        }
        heap.remove(eventID: "d11")

        // 完整弹出必须严格升序——d11(660) 不在序列、d8(480) 在序列，
        // 即删除生效且堆序任何残留破坏都会在此暴露
        var popped: [TimeInterval] = []
        while let top = heap.removeTop() {
            popped.append(top.deadline.timeIntervalSince1970)
        }
        XCTAssertEqual(popped, [60, 180, 480, 540, 600, 720])
    }

    // 边界：删除堆顶、末尾元素、不存在的 id
    func testRemoveBoundaries() {
        let heap = CountdownTimerManager.MinHeap()
        heap.insert(eventID: "a", deadline: Date(timeIntervalSince1970: 10))
        heap.insert(eventID: "b", deadline: Date(timeIntervalSince1970: 20))
        heap.insert(eventID: "c", deadline: Date(timeIntervalSince1970: 30))

        heap.remove(eventID: "missing") // 不存在的 id，无副作用
        XCTAssertEqual(heap.peek()?.eventID, "a")

        heap.remove(eventID: "a") // 删除堆顶
        XCTAssertEqual(heap.peek()?.eventID, "b")

        heap.remove(eventID: "c") // 删除末尾元素
        XCTAssertEqual(heap.peek()?.eventID, "b")

        heap.remove(eventID: "b")
        XCTAssertTrue(heap.isEmpty)
        XCTAssertNil(heap.removeTop())
    }
}
