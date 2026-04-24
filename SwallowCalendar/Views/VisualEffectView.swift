//
//  VisualEffectView.swift
//  SwallowCalendar
//
//  系统级毛玻璃效果

import SwiftUI

/// macOS 旧版本的毛玻璃效果视图
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active  // 确保视觉效果始终激活
        view.isEmphasized = false  // 移除强调边框
        
        // 设置圆角，确保覆盖窗口四角
        view.wantsLayer = true
        view.layer?.cornerRadius = Popup.totalCornerRadius
        view.layer?.masksToBounds = true
        
        return view
    }
    
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        // 更新圆角
        view.layer?.cornerRadius = Popup.totalCornerRadius
    }
}

// MARK: - Future Enhancement
// GlassEffectView 将在 macOS 26.0 SDK 可用时启用
// 目前暂时禁用以避免 GitHub Actions 编译错误
/*
@available(macOS 26.0, *)
struct GlassEffectView: NSViewRepresentable {
    let glassEffectView = NSGlassEffectView()
    
    var style: NSGlassEffectView.Style = .regular
    
    func makeNSView(context: Context) -> NSGlassEffectView {
        return glassEffectView
    }
    
    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        glassEffectView.style = style
    }
}
*/

#Preview {
    VisualEffectView(
        material: .popover,
        blendingMode: .behindWindow
    )
}
