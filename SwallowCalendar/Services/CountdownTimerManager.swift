//
//  CountdownTimerManager.swift
//  SwallowCalendar
//
//  单一 GCD Timer + 最小堆管理动态倒计时
//

import Foundation
import Combine

/// 倒计时管理器：使用单一 GCD Timer + 最小堆实现高性能动态倒计时
/// E-12：显式 MainActor 隔离——register/unregister/shouldRefresh 调用方均为
/// 主线程视图，timer 回调已派回主线程；把"约定收敛在主线程"固化为类型系统保证
@MainActor
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
            // 保持 GCD 主队列 FIFO 派发：Task{@MainActor} 无执行顺序保证，快速
            // register→unregister 交替时可能乱序（unregister 先执行会把事件残留
            // 在堆中）；主队列闭包内用 assumeIsolated 满足 MainActor 隔离检查
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    // 如果已存在，先移除旧的（避免重复插入导致内存泄漏）
                    self.minHeap.remove(eventID: eventID)

                    self.minHeap.insert(eventID: eventID, deadline: deadline)
                    self.visibleEventIDs.insert(eventID)

                    if self.timer == nil {
                        self.startTimer()
                    }
                    self.adjustRefreshInterval()
                }
            }
        }
    
    /// 注销一个事件（当视图消失时调用）
    /// - Parameter eventID: 事件 ID
    func unregister(eventID: String) {
        // 与 register 相同：主队列 FIFO 保证先 register 后 unregister 的顺序
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
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
    }
    
    /// 判断事件是否需要刷新（事件在可见集合中）
    /// - Parameter eventID: 事件 ID
    /// - Returns: 是否需要刷新
    func shouldRefresh(eventID: String) -> Bool {
        return visibleEventIDs.contains(eventID)
    }
    
    // MARK: - Private Methods
    
    /// 启动 GCD Timer
    private func startTimer() {
        stopTimer()
        
        let newTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .background))
        newTimer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
        newTimer.setEventHandler { [weak self] in
            // 后台 timer 触发后跳回主线程处理（Task 继承 MainActor 隔离）
            Task { @MainActor [weak self] in
                self?.onTimerFired()
            }
        }
        newTimer.resume()
        timer = newTimer
        currentInterval = 1
    }
    
    /// 停止 Timer
    private func stopTimer() {
        timer?.cancel()
        timer = nil
        currentInterval = 0
    }
    
    /// Timer 触发时的处理
    private func onTimerFired() {
        refreshTrigger += 1
        adjustRefreshInterval()
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
                    // B-4：标准删除算法——替换元素可能需要上浮（比新 parent 小）
                    // 或下沉（比子节点大），各调一次，元素只朝一个方向移动，
                    // 多余方向的调用为空操作。原实现仅 siftDown 导致堆序破坏
                    siftUp(from: index)
                    siftDown(from: index)
                }
            }
        }
        
        /// 查看堆顶元素（不移除）
        func peek() -> HeapElement? {
            return elements.first
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
