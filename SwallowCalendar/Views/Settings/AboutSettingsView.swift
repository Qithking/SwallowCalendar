//
//  AboutSettingsView.swift
//  SwallowCalendar
//

import SwiftUI
import AppKit

struct AboutSettingsView: View {
    @StateObject private var updateChecker = UpdateChecker.shared

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            // 应用图标
            Group {
                if let appIcon = NSImage(named: "AppIcon") {
                    Image(nsImage: appIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)
                } else {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 48))
                        .foregroundColor(.accentColor)
                }
            }

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

            // 作者与项目信息
            VStack(spacing: 4) {               
                HStack(spacing: 16) {
                    Button {
                        if let url = URL(string: "https://github.com/Qithking") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 12))
                            Text("Qithking")
                                .font(.system(size: 12))
                        }
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)

                    Text("|")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    Button {
                        if let url = URL(string: "https://github.com/Qithking/SwallowCalendar") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "link.circle.fill")
                                .font(.system(size: 12))
                            Text("项目地址")
                                .font(.system(size: 12))
                        }
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }

            // 检查更新按钮 - 始终显示
            Button {
                NSApplication.shared.activate(ignoringOtherApps: true);
                checkForUpdates()
            } label: {
                HStack(spacing: 6) {
                    if updateChecker.isChecking {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                    Text(updateChecker.isChecking ? "检查中..." : "检查更新")
                        .font(.system(size: 13))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(updateChecker.isChecking)

            // 新版本信息 - 仅当有新版本时显示
            if updateChecker.updateAvailable {
                VStack(alignment: .center, spacing: 8) {
                    Text("新版本: v\(updateChecker.latestVersion)")
                        .font(.system(size: 12, weight: .medium))

                    if !updateChecker.releaseNotes.isEmpty {
                        ScrollView {
                            Text(updateChecker.releaseNotes)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 100)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 40)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func checkForUpdates() {
        Task {
            await updateChecker.checkForUpdates()

            await MainActor.run {
                if let error = updateChecker.errorMessage {
                    showAlert(title: "检查更新失败", message: error, style: .warning)
                } else if updateChecker.updateAvailable {
                    showUpdateAlert()
                } else {
                    showAlert(title: "已是最新版本", message: "当前版本 v\(appVersion) 已是最新版本", style: .informational)
                }
            }
        }
    }

    private func showUpdateAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "发现新版本"
        alert.informativeText = "最新版本: v\(updateChecker.latestVersion)\n当前版本: v\(appVersion)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "下载安装包")
        alert.addButton(withTitle: "稍后")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            updateChecker.downloadLatestRelease()
        }
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}


