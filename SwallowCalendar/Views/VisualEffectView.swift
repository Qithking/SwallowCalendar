//
//  VisualEffectView.swift
//  SwallowCalendar
//
//  系统级毛玻璃效果 - 根据 macOS 版本自动选择效果

import SwiftUI
import AppKit

/// macOS 毛玻璃效果视图 (仅使用 NSVisualEffectView，兼容所有 macOS 14+)
/// 注意: NSGlassEffectView (macOS 26+) 暂时禁用，等待 GitHub Actions 支持 Swift 6.0+ 编译器
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSView {
        return makeClassicEffectView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let visualView = view as? NSVisualEffectView {
            visualView.material = material
            visualView.blendingMode = blendingMode
        }
    }

    /// 创建传统 Visual Effect View (支持 macOS 14+)
    private func makeClassicEffectView() -> NSView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = false
        view.autoresizingMask = [.width, .height]
        return view
    }
}
