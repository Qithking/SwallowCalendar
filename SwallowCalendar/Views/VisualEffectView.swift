//
//  VisualEffectView.swift
//  SwallowCalendar
//
//  参考 Maccy 项目实现的系统级毛玻璃效果

import SwiftUI

/// macOS 旧版本的毛玻璃效果视图
struct VisualEffectView: NSViewRepresentable {
    let visualEffectView = NSVisualEffectView()
    
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        return visualEffectView
    }
    
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
    }
}

/// macOS 26.0+ 的玻璃效果视图
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

#Preview {
    VisualEffectView(
        material: .popover,
        blendingMode: .behindWindow
    )
}
