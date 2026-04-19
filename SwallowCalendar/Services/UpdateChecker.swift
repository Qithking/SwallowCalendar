//
//  UpdateChecker.swift
//  SwallowCalendar
//

import Foundation
import AppKit
import Combine
import SwiftUI

struct ReleaseInfo: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlUrl: String
    let publishedAt: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlUrl = "html_url"
        case publishedAt = "published_at"
    }
}

@MainActor
final class UpdateChecker: NSObject, ObservableObject, URLSessionDownloadDelegate, NSWindowDelegate {
    static let shared = UpdateChecker()

    @Published var isChecking = false
    @Published var updateAvailable = false
    @Published var latestVersion: String = ""
    @Published var releaseUrl: String = ""
    @Published var releaseNotes: String = ""
    @Published var errorMessage: String?

    // 下载相关
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadError: String?
    @Published var showDownloadWindow = false

    private var downloadSession: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var pendingDownloadUrl: URL?
    private var downloadWindow: NSWindow?

    private let repoOwner = "Qithking"
    private let repoName = "SwallowCalendar"
    private let currentVersion: String
    private var checkTimer: Timer?
    private var checkTimerLastRun: Date?

    private override init() {
        self.currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        super.init()
        self.downloadSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    func checkOnStartup() {
        Task {
            await checkForUpdates()
        }
    }

    func startPeriodicCheck() {
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkForUpdates()
            }
        }
    }

    var currentVersionString: String {
        currentVersion
    }

    func checkForUpdates() async {
        isChecking = true
        errorMessage = nil
        updateAvailable = false

        defer { isChecking = false }

        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else {
            errorMessage = "无效的 URL"
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                errorMessage = "无效的响应"
                return
            }

            if httpResponse.statusCode == 404 {
                errorMessage = "未找到发布信息"
                return
            }

            guard httpResponse.statusCode == 200 else {
                errorMessage = "请求失败: \(httpResponse.statusCode)"
                return
            }

            let decoder = JSONDecoder()
            let release = try decoder.decode(ReleaseInfo.self, from: data)

            let latestTag = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName

            await MainActor.run {
                self.latestVersion = latestTag
                self.releaseUrl = release.htmlUrl
                self.releaseNotes = release.body ?? ""
                self.updateAvailable = self.isNewerVersion(latestTag)
            }

        } catch {
            await MainActor.run {
                self.errorMessage = "检查更新失败: \(error.localizedDescription)"
            }
        }
    }

    private func isNewerVersion(_ latest: String) -> Bool {
        let current = currentVersion
        let latestNormalized = latest.trimmingCharacters(in: .whitespaces)

        let currentParts = current.split(separator: ".").compactMap { Int($0) }
        let latestParts = latestNormalized.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(currentParts.count, latestParts.count) {
            let currentPart = i < currentParts.count ? currentParts[i] : 0
            let latestPart = i < latestParts.count ? latestParts[i] : 0

            if latestPart > currentPart {
                return true
            } else if currentPart > latestPart {
                return false
            }
        }

        return false
    }

    func openReleasePage() {
        guard let url = URL(string: releaseUrl) else { return }
        NSWorkspace.shared.open(url)
    }

    func downloadLatestRelease() {
        guard let url = URL(string: releaseUrl) else {
            downloadError = "无效的下载链接"
            return
        }
        pendingDownloadUrl = url
        downloadProgress = 0
        downloadError = nil
        isDownloading = true
        showDownloadWindow = true
        showDownloadWindowPanel()
        downloadTask = downloadSession?.downloadTask(with: url)
        downloadTask?.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        showDownloadWindow = false
        downloadProgress = 0
        closeDownloadWindow()
    }

    func retryDownload() {
        downloadLatestRelease()
    }

    func copyDownloadUrl() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(releaseUrl, forType: .string)
    }

    private func showDownloadWindowPanel() {
        let progressView = NSHostingView(rootView: DownloadProgressView(updateChecker: self))
        progressView.frame = NSRect(x: 0, y: 0, width: 360, height: 120)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "下载更新"
        window.contentView = progressView

        // 在当前前台窗口所在屏幕居中显示
        if let keyWindow = NSApp.keyWindow, let screen = keyWindow.screen {
            window.setFrameOrigin(screen.frame.origin)
            window.center()
        } else {
            window.center()
        }

        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        downloadWindow = window
    }

    private func closeDownloadWindow() {
        downloadWindow?.close()
        downloadWindow = nil
    }

    // MARK: - URLSessionDownloadDelegate

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        Task { @MainActor in
            guard downloadTask.originalRequest?.url != nil else { return }

            do {
                let fileManager = FileManager.default
                let downloadsFolder = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                let fileName = "SwallowCalendar-\(latestVersion).zip"
                let destinationUrl = downloadsFolder.appendingPathComponent(fileName)

                if fileManager.fileExists(atPath: destinationUrl.path) {
                    try fileManager.removeItem(at: destinationUrl)
                }

                try fileManager.moveItem(at: location, to: destinationUrl)

                downloadProgress = 1.0
                isDownloading = false

                // 延迟关闭窗口，让用户看到完成状态
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                closeDownloadWindow()

                // 打开下载文件夹
                NSWorkspace.shared.selectFile(destinationUrl.path, inFileViewerRootedAtPath: downloadsFolder.path)
            } catch {
                downloadError = "保存文件失败: \(error.localizedDescription)"
                isDownloading = false
                closeDownloadWindow()
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            if totalBytesExpectedToWrite > 0 {
                downloadProgress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            if let error = error {
                downloadError = "下载失败: \(error.localizedDescription)"
                isDownloading = false
                // 不关闭窗口，保留错误信息让用户选择重试或复制链接
            }
        }
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            if isDownloading {
                cancelDownload()
            }
        }
    }
}

// MARK: - Download Progress View

struct DownloadProgressView: View {
    @ObservedObject var updateChecker: UpdateChecker

    var body: some View {
        VStack(spacing: 12) {
            // 第一行：图标 + 标题
            HStack(spacing: 12) {
                Image("AppIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)

                Text("正在下载 SwallowCalendar v\(updateChecker.latestVersion)")
                    .font(.system(size: 13, weight: .medium))

                Spacer()
            }

            // 第二行：进度条 + 百分比
            HStack(spacing: 12) {
                ProgressView(value: updateChecker.downloadProgress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: .infinity)

                Text("\(Int(updateChecker.downloadProgress * 100))%")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }

            // 第三行：错误信息（如果有）
            if let error = updateChecker.downloadError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 第四行：按钮组（靠右）
            HStack {
                Spacer()

                if updateChecker.downloadError != nil {
                    Button("重试") {
                        updateChecker.downloadLatestRelease()
                    }
                    .buttonStyle(.bordered)

                    Button("复制链接") {
                        updateChecker.copyDownloadUrl()
                    }
                    .buttonStyle(.bordered)

                    Button("取消") {
                        updateChecker.cancelDownload()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("取消") {
                        updateChecker.cancelDownload()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .frame(width: 360, height: 120)
    }
}
