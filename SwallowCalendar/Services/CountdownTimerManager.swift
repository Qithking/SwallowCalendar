//
//  CountdownTimerManager.swift
//  SwallowCalendar
//
//  单一 GCD Timer + 最小堆管理动态倒计时
//

import Foundation
import Combine

/// 倒计时管理器：使用单一 GCD Timer + 最小堆实现高性能动态倒计时
final class CountdownTimerManager: ObservableObject {
    static let shared = CountdownTimerManager()
    
    /// 刷新触发器，用于通知 UI 更新
    @Published var refreshTrigger: Int = 0
    
    /// 最小堆：存储 (eventID, deadline) 元组
    private var minHeap: MinHeap = MinHeap()
    
    /// 可见事件集合：记录当前屏幕可见的事件 ID
    private var visibleEventIDs: Set<String> = []
    
    /// GCD Timer
    private var timer: DispatchSourceTimer?
    
    /// 当前刷新间隔（秒）
    private var currentInterval: TimeInterval = 0
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// 注册一个需要动态刷新的事件
    /// - Parameters:
    ///   - eventID: 事件 ID
    ///   - deadline: 到期时间
    func register(eventID: String, deadline: Date) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // 添加到最小堆
            self.minHeap.insert(eventID: eventID, deadline: deadline)
            
            // 如果这是第一个需要动态刷新的事件，启动 Timer
            if self.timer == nil {
                self.startTimer()
            }
        }
    }
    
    /// 注销一个事件（当视图消失时调用）
    /// - Parameter eventID: 事件 ID
    func unregister(eventID: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // 从可见集合中移除
            self.visibleEventIDs.remove(eventID)
            
            // 从最小堆中移除
            self.minHeap.remove(eventID: eventID)
            
            // 如果堆为空，停止 Timer
            if self.minHeap.isEmpty {
                self.stopTimer()
            }
        }
    }
    
    /// 标记事件为可见（当视图出现时调用）
    /// - Parameter eventID: 事件 ID
    func markVisible(eventID: String) {
        visibleEventIDs.insert(eventID)
    }
    
    /// 标记事件为不可见（当视图消失时调用）
    /// - Parameter eventID: 事件 ID
    func markInvisible(eventID: String) {
        visibleEventIDs.remove(eventID)
        // 从堆中移除，避免内存泄漏
        minHeap.remove(eventID: eventID)
        
        // 如果堆为空，停止 Timer
        if minHeap.isEmpty {
            stopTimer()
        }
    }
    
    /// 判断事件是否需要刷新（事件在可见集合中）
    /// - Parameter eventID: 事件 ID
    /// - Returns: 是否需要刷新
    func shouldRefresh(eventID: String) -> Bool {
        return visibleEventIDs.contains(eventID)
    }
    
    /// 批量更新最小堆（用于列表刷新时同步）
    /// - Parameter events: 需要动态刷新的事件列表 [(eventID, deadline)]
    func updateHeap(with events: [(eventID: String, deadline: Date)]) {
        // 同步执行，避免时序竞争问题
        // 清空旧堆
        minHeap.removeAll()
        
        // 插入新事件
        for event in events {
            minHeap.insert(eventID: event.eventID, deadline: event.deadline)
        }
        
        // 如果堆不为空且 Timer 未启动，启动 Timer
        if !minHeap.isEmpty && timer == nil {
            startTimer()
        } else if minHeap.isEmpty {
            // 如果堆为空，停止 Timer
            stopTimer()
        }
    }
    
    // MARK: - Private Methods
    
    /// 启动 Timer（由于 CountdownTextView 独立管理定时器，此方法不再实际启动定时器）
    private func startTimer() {
        // 不再需要启动定时器，CountdownTextView 已独立管理倒计时刷新
        currentInterval = 0
    }
    
    /// 停止 Timer
    private func stopTimer() {
        timer?.cancel()
        timer = nil
        currentInterval = 0
    }
    
    /// Timer 触发时的处理
    private func onTimerFired() {
        // 注意：由于 CountdownTextView 现在独立管理自己的定时器，
        // 此处的 refreshTrigger 不再被用于 UI 更新，为节省资源禁用此定时器
    }
    
    /// 根据堆顶事件的剩余时间调整刷新频率
    private func adjustRefreshInterval() {
        guard let topEvent = minHeap.peek() else {
            stopTimer()
            return
        }
        
        let remainingTime = topEvent.deadline.timeIntervalSinceNow
        
        // 如果已过期，从堆中移除
        if remainingTime <= 0 {
            minHeap.removeTop()
            adjustRefreshInterval() // 递归检查下一个
            return
        }
        
        // 智能调整刷新频率
        let newInterval: TimeInterval
        if remainingTime < 3600 {
            // < 1 小时：每秒刷新
            newInterval = 1
        } else if remainingTime < 86400 {
            // 1-24 小时：每 10 秒刷新
            newInterval = 10
        } else {
            // > 24 小时：不需要动态刷新，停止 Timer
            stopTimer()
            return
        }
        
        // 如果间隔发生变化，重新调度 Timer
        if abs(newInterval - currentInterval) > 0.1 {
            currentInterval = newInterval
            timer?.schedule(deadline: .now() + newInterval, repeating: newInterval)
        }
    }
}

// MARK: - MinHeap Implementation

extension CountdownTimerManager {
    /// 最小堆实现：按 deadline 排序
    struct HeapElement {
        let eventID: String
        let deadline: Date
        
        init(eventID: String, deadline: Date) {
            self.eventID = eventID
            self.deadline = deadline
        }
    }
    
    class MinHeap {
        private var elements: [HeapElement] = []
        
        var isEmpty: Bool {
            return elements.isEmpty
        }
        
        /// 清空堆
        func removeAll() {
            elements.removeAll()
        }
        
        /// 插入元素
        func insert(eventID: String, deadline: Date) {
            let element = HeapElement(eventID: eventID, deadline: deadline)
            elements.append(element)
            siftUp(from: elements.count - 1)
        }
        
        /// 移除堆顶元素
        @discardableResult
        func removeTop() -> HeapElement? {
            guard !elements.isEmpty else { return nil }
            
            if elements.count == 1 {
                return elements.removeLast()
            }
            
            let top = elements[0]
            elements[0] = elements.removeLast()
            siftDown(from: 0)
            return top
        }
        
        /// 移除指定 eventID 的元素
        func remove(eventID: String) {
            if let index = elements.firstIndex(where: { $0.eventID == eventID }) {
                if index == elements.count - 1 {
                    elements.removeLast()
                } else {
                    elements[index] = elements.removeLast()
                    siftDown(from: index)
                }
            }
        }
        
        /// 查看堆顶元素（不移除）
        func peek() -> HeapElement? {
            return elements.first
        }
        
        /// 检查是否包含指定 eventID
        func contains(eventID: String) -> Bool {
            return elements.contains { $0.eventID == eventID }
        }
        
        // MARK: - Heap Operations
        
        private func siftUp(from index: Int) {
            var child = index
            var parent = (child - 1) / 2
            
            while child > 0 && elements[child].deadline < elements[parent].deadline {
                elements.swapAt(child, parent)
                child = parent
                parent = (child - 1) / 2
            }
        }
        
        private func siftDown(from index: Int) {
            var parent = index
            let count = elements.count
            
            while true {
                var smallest = parent
                let leftChild = 2 * parent + 1
                let rightChild = 2 * parent + 2
                
                if leftChild < count && elements[leftChild].deadline < elements[smallest].deadline {
                    smallest = leftChild
                }
                
                if rightChild < count && elements[rightChild].deadline < elements[smallest].deadline {
                    smallest = rightChild
                }
                
                if smallest == parent {
                    break
                }
                
                elements.swapAt(parent, smallest)
                parent = smallest
            }
        }
    }
}
