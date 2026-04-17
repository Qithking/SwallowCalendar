//
//  AboutSettingsView.swift
//  SwallowCalendar
//

import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            // 应用图标
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            // 应用名称
            Text("SwallowCalendar")
                .font(.system(size: 20, weight: .bold))

            // 版本信息
            VStack(spacing: 4) {
                Text("版本 \(appVersion) (\(appBuild))")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Text("macOS 菜单栏日历应用")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Divider()
                .frame(width: 200)

            // 版权
            Text("© 2026 thking")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}
