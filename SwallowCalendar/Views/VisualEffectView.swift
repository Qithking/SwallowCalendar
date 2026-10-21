//
//  VisualEffectView.swift
//  SwallowCalendar
//
//  系统级毛玻璃效果 - 根据 macOS 版本自动选择效果

import SwiftUI

/// macOS 毛玻璃效果视图
/// 根据系统版本自动选择：
/// - macOS 26+: 使用 NSGlassEffectView (新毛玻璃效果)
/// - macOS 15 及以下: 使用 NSVisualEffectView (传统毛玻璃效果)
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            return makeGlassEffectView()
        } else {
            return makeClassicEffectView()
        }
    }
    
    func updateNSView(_ view: NSView, context: Context) {
        if #available(macOS 26.0, *), view is NSGlassEffectView {
            // N-12：glass 分支无 material/blendingMode 对应属性（样式由 style 固定），
            // 参数变化时无可更新项，与 classic 分支的参数回写区分开
        } else if let visualView = view as? NSVisualEffectView {
            // macOS 15 及以下: 更新 Visual Effect View
            visualView.material = material
            visualView.blendingMode = blendingMode
        }
    }
    
    @available(macOS 26.0, *)
    private func makeGlassEffectView() -> NSView {
        let view = NSGlassEffectView()
        view.style = .regular
        view.autoresizingMask = [.width, .height]
        return view
    }
    
    private func makeClassicEffectView() -> NSView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active  // 确保视觉效果始终激活
        view.isEmphasized = false  // 移除强调边框
        view.autoresizingMask = [.width, .height]
        return view
    }
}

#Preview {
    VisualEffectView(
        material: .popover,
        blendingMode: .behindWindow
    )
}
