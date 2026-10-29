//
//  CountdownTimerManager.swift
//  SwallowCalendar
//
//  单一 GCD Timer + 最小堆管理动态倒计时
//

import Foundation
import Combine

/// 倒计时定时器相位对齐工具（fix：菜单栏徽标与列表倒计时不同步跳动）
/// 两侧独立 1s 定时器若从各自启动时刻起跳，节拍相位错开导致数字跳动时刻不一致；
/// 启动时统一对齐到 wall-clock 整秒边界，无论何时启动都落在同一整秒序列
enum CountdownPhaseSync {
    /// 距下一整秒边界的间隔（秒），结果 ∈ (0, 1]
    /// 输入恰为整秒边界时返回 1（对齐到下一整秒，避免 0 延迟调度无效）
    static func intervalToNextSecond(from date: Date = Date()) -> TimeInterval {
        let fraction = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1)
        return 1 - fraction
    }
}

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
    
    /// 可见事件注册表：eventID → 同时显示该事件的视图实例数
    /// fix: panel-countdown-frozen-on-collapse——同一事件可同时显示在
    /// 主界面与桌面面板（CountdownTextView 三处复用），主界面收起的
    /// onDisappear 无条件 unregister，若按 Set 单键注销会误删共享注册，
    /// 导致桌面面板倒计时冻结；按引用计数注销，仅最后一方注销才移除
    private var visibleEventIDs: [String: Int] = [:]
    
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
                    // 引用计数 +1：多处视图同显同一事件时各持一份注册
                    self.visibleEventIDs[eventID, default: 0] += 1

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
                // 引用计数 -1：仍有其他视图显示该事件时保留注册，
                // 仅最后一方注销才移除（防御生命周期不配对的超额注销）
                let count = self.visibleEventIDs[eventID] ?? 0
                guard count > 0 else { return }
                if count > 1 {
                    self.visibleEventIDs[eventID] = count - 1
                    return
                }
                self.visibleEventIDs.removeValue(forKey: eventID)

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
        return visibleEventIDs[eventID] != nil
    }
    
    // MARK: - Private Methods
    
    /// 启动 GCD Timer
    private func startTimer() {
        stopTimer()
        
        let newTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .background))
        // 首次 fire 对齐到下一整秒边界（与菜单栏徽标定时器同相位，两侧倒计时同步跳动）；
        // leeway 收紧到 10ms，避免 fire 晚于整秒太多扩大两侧翻转窗口
        let alignDelay = CountdownPhaseSync.intervalToNextSecond()
        newTimer.schedule(deadline: .now() + alignDelay, repeating: .seconds(1), leeway: .milliseconds(10))
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
    
    /// 根据堆内事件调整刷新频率（badge-realtime-countdown：可见期间固定 1s 实时刷新）
    private func adjustRefreshInterval() {
        guard let topEvent = minHeap.peek() else {
            stopTimer()
            return
        }

        // 已过期事件从堆中移除，递归检查下一个
        if topEvent.deadline.timeIntervalSinceNow <= 0 {
            minHeap.removeTop()
            adjustRefreshInterval() // 递归检查下一个
            return
        }

        // 实时倒计时：只要有可见事件即保持 1s 节奏（不再按剩余时长分档停表）
        let newInterval: TimeInterval = 1

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
