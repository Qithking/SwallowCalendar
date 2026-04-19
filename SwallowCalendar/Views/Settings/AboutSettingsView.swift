//
//  AboutSettingsView.swift
//  SwallowCalendar
//

import SwiftUI

struct AboutSettingsView: View {
    @StateObject private var updateChecker = UpdateChecker.shared
    @State private var showUpdateAlert = false
    @State private var showNoUpdateAlert = false
    @State private var showErrorAlert = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            // 应用图标
            Image("AppIcon")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)

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

            // 作者信息
            VStack(spacing: 4) {
                Text("作者: Qithking")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Button {
                    if let url = URL(string: "https://github.com/Qithking") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 12))
                        Text("GitHub: @Qithking | macOS 菜单栏日历")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }

            // 项目链接
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

            Divider()
                .frame(width: 200)

            // 检查更新按钮
            Button {
                checkForUpdates()
            } label: {
                HStack(spacing: 6) {
                    if updateChecker.isChecking {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                    Text("检查更新")
                        .font(.system(size: 13))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(updateChecker.isChecking)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .alert("发现新版本", isPresented: $showUpdateAlert) {
            Button("下载安装包") {
                updateChecker.downloadLatestRelease()
            }
            Button("稍后", role: .cancel) {}
        } message: {
            Text("最新版本: v\(updateChecker.latestVersion)\n当前版本: v\(updateChecker.currentVersionString)")
        }
        .alert("已是最新版本", isPresented: $showNoUpdateAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("当前版本 v\(updateChecker.currentVersionString) 已是最新版本")
        }
        .alert("检查更新失败", isPresented: $showErrorAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(updateChecker.errorMessage ?? "未知错误")
        }
        .onChange(of: updateChecker.updateAvailable) { _, newValue in
            if !updateChecker.isChecking && newValue {
                showUpdateAlert = true
            }
        }
    }

    private func checkForUpdates() {
        Task {
            await updateChecker.checkForUpdates()

            // 检查完成后处理结果
            try? await Task.sleep(nanoseconds: 500_000_000) // 等待状态更新

            if let error = updateChecker.errorMessage {
                showErrorAlert = true
            } else if updateChecker.updateAvailable {
                showUpdateAlert = true
            } else {
                showNoUpdateAlert = true
            }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}
