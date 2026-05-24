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
    let assets: [ReleaseAsset]?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlUrl = "html_url"
        case publishedAt = "published_at"
        case assets
    }
}

struct ReleaseAsset: Decodable {
    let name: String
    let browserDownloadUrl: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
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
    @Published var usingProxy = false  // 是否正在使用代理下载

    private var downloadSession: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var pendingDownloadUrl: URL?
    private var downloadWindow: NSWindow?
    private var hasTriedProxy = false  // 是否已尝试代理

    private let repoOwner = "Qithking"
    private let repoName = "SwallowCalendar"
    private let currentVersion: String
    private var checkTimer: Timer?
    private var checkTimerLastRun: Date?
    private let hasCheckedOnThisLaunchKey = "hasCheckedUpdateOnThisLaunch"

    private override init() {
        self.currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        super.init()
        
        // 使用临时目录配置 session，避免沙盒限制
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        self.downloadSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    func checkOnStartup() {
        // 检查设置是否开启且是本次启动首次检查
        guard AppSettings.shared.checkUpdateOnFirstLaunch else { return }
        
        // 每次启动只检查一次
        let hasCheckedThisLaunch = UserDefaults.standard.bool(forKey: hasCheckedOnThisLaunchKey)
        guard !hasCheckedThisLaunch else { return }
        
        // 标记本次启动已检查
        UserDefaults.standard.set(true, forKey: hasCheckedOnThisLaunchKey)
        
        Task {
            await checkForUpdatesWithNotification()
        }
    }

    func checkForUpdatesWithNotification() async {
        await checkForUpdates()
        
        await MainActor.run {
            if updateAvailable {
                showUpdateNotification()
            }
        }
    }

    private func showUpdateNotification() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "发现新版本"
        alert.informativeText = "最新版本: v\(latestVersion)\n当前版本: v\(currentVersion)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "下载安装包")
        alert.addButton(withTitle: "稍后")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            downloadLatestRelease()
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

            // 优先获取 dmg 文件，其次是 zip 文件
            var directDownloadUrl = release.htmlUrl
            if let dmgAsset = release.assets?.first(where: { $0.name.lowercased().contains(".dmg") }) {
                directDownloadUrl = dmgAsset.browserDownloadUrl
            } else if let zipAsset = release.assets?.first(where: { $0.name.lowercased().contains(".zip") }) {
                directDownloadUrl = zipAsset.browserDownloadUrl
            }

            await MainActor.run {
                self.latestVersion = latestTag
                self.releaseUrl = directDownloadUrl
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

    /// 获取代理下载 URL（添加 gh-proxy.org 前缀）
    private var proxyDownloadUrl: String {
        if releaseUrl.hasPrefix("https://github.com/") {
            return "https://gh-proxy.org/\(releaseUrl)"
        }
        return releaseUrl
    }

    func downloadLatestRelease() {
        guard URL(string: releaseUrl) != nil else {
            downloadError = "无效的下载链接"
            return
        }
        downloadProgress = 0
        downloadError = nil
        usingProxy = true  // 优先使用代理
        hasTriedProxy = false
        isDownloading = true
        showDownloadWindow = true
        showDownloadWindowPanel()
        startDownload()
    }

    private func startDownload() {
        let urlString: String
        if usingProxy {
            urlString = proxyDownloadUrl  // 优先使用代理
        } else {
            urlString = releaseUrl  // 代理失败后才用直连
        }
        
        guard let url = URL(string: urlString) else { return }
        pendingDownloadUrl = url
        downloadTask?.cancel()
        
        // 直连使用较短的超时时间，代理使用正常超时
        let config = URLSessionConfiguration.default
        if usingProxy {
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 300
        } else {
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 60
        }
        downloadSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        
        downloadTask = downloadSession?.downloadTask(with: url)
        downloadTask?.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        showDownloadWindow = false
        downloadProgress = 0
        usingProxy = false
        hasTriedProxy = false
        closeDownloadWindow()
    }

    func retryDownload() {
        downloadError = nil
        usingProxy = true  // 重试时优先使用代理
        hasTriedProxy = false
        isDownloading = true
        startDownload()
    }

    func copyDownloadUrl() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(releaseUrl, forType: .string)
    }

    private func showDownloadWindowPanel() {
        // 关闭已有窗口
        closeDownloadWindow()
        
        let progressView = NSHostingView(rootView: DownloadProgressView(updateChecker: self))
        progressView.frame = NSRect(x: 0, y: 0, width: 420, height: 140)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 140),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "下载更新"
        window.contentView = progressView

        // 在当前前台窗口所在屏幕居中显示
        if let keyWindow = NSApp.keyWindow, let screen = keyWindow.screen {
            let screenFrame = screen.visibleFrame
            let windowX = screenFrame.origin.x + (screenFrame.width - 420) / 2
            let windowY = screenFrame.origin.y + (screenFrame.height - 140) / 2
            window.setFrameOrigin(NSPoint(x: windowX, y: windowY))
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
        // 注意：此方法已在主线程调用（delegateQueue: .main）
        // 必须立即移动临时文件，否则系统会自动清理
        let fm = FileManager.default
        
        // 先验证临时文件是否存在
        guard fm.fileExists(atPath: location.path) else {
            Task { @MainActor in
                self.downloadError = "下载文件不存在，请重试"
                self.isDownloading = false
            }
            return
        }
        
        // 立即将文件移动到安全位置（使用 UUID 避免冲突）
        let tempDir = fm.temporaryDirectory
        let tempFileName = "SwallowCalendar_\(UUID().uuidString).tmp"
        let tempDestURL = tempDir.appendingPathComponent(tempFileName)
        
        do {
            try fm.moveItem(at: location, to: tempDestURL)
        } catch {
            Task { @MainActor in
                self.downloadError = "保存失败: \(error.localizedDescription)"
                self.isDownloading = false
            }
            return
        }
        
        // 现在文件已经在安全位置，可以安全地切换到 async 上下文
        Task { @MainActor in
            do {
                // 获取下载目录
                guard let downloadsFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
                    self.downloadError = "无法访问下载文件夹"
                    self.isDownloading = false
                    return
                }
                
                // 确定文件名
                let urlString = self.releaseUrl.lowercased()
                let fileName: String
                if urlString.contains(".dmg") {
                    fileName = "SwallowCalendar-\(self.latestVersion).dmg"
                } else {
                    fileName = "SwallowCalendar-\(self.latestVersion).zip"
                }
                let destinationUrl = downloadsFolder.appendingPathComponent(fileName)

                // 如果目标文件已存在，先删除
                if FileManager.default.fileExists(atPath: destinationUrl.path) {
                    try FileManager.default.removeItem(at: destinationUrl)
                }

                // 移动文件到下载文件夹
                try FileManager.default.moveItem(at: tempDestURL, to: destinationUrl)

                self.downloadProgress = 1.0
                self.isDownloading = false
                self.closeDownloadWindow()

                // 立即打开下载的文件（.dmg 会自动挂载，.zip 会自动解压）
                NSWorkspace.shared.open(destinationUrl)
            } catch {
                self.downloadError = "保存失败: \(error.localizedDescription)"
                self.isDownloading = false
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            if totalBytesExpectedToWrite > 0 {
                self.downloadProgress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            if let nsError = error as NSError?, nsError.code != NSURLErrorCancelled {
                // 优先使用代理，如果代理失败且还没尝试过直连，则切换到直连重试
                if usingProxy && !hasTriedProxy {
                    hasTriedProxy = true
                    usingProxy = false  // 切换到直连
                    startDownload()
                    return
                }
                
                // 两种方法都失败
                self.downloadError = "下载失败: \(error?.localizedDescription ?? "未知错误")"
                self.isDownloading = false
                self.usingProxy = false
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
    @State private var linkCopied = false
    @State private var errorCopied = false

    var body: some View {
        VStack(spacing: 0) {
            // 上面一行：图标 + 进度条（内嵌百分比）
            HStack(spacing: 16) {
                if let appIcon = NSImage(named: "AppIcon") {
                    Image(nsImage: appIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 40, height: 40)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.accentColor)
                        .frame(width: 40, height: 40)
                }

                ProgressView(value: updateChecker.downloadProgress) {
                    Text("正在下载 SwallowCalendar v\(updateChecker.latestVersion)")
                        .font(.system(size: 13))
                }
                .progressViewStyle(.linear)
                .frame(maxWidth: .infinity)

                Text("\(Int(updateChecker.downloadProgress * 100))%")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            // 下面一行：错误信息/成功提示 + 操作按钮
            HStack {
                if let error = updateChecker.downloadError {
                    HStack(spacing: 4) {
                        ErrorTextView(message: error) {
                            errorCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                errorCopied = false
                            }
                        }
                        if errorCopied {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.green)
                        }
                    }
                } else if updateChecker.downloadProgress >= 1.0 {
                    Text("下载完成")
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                } else {
                    Text("")
                        .font(.system(size: 12))
                }

                Spacer()

                if updateChecker.downloadError != nil {
                    Button("重试") {
                        updateChecker.retryDownload()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        updateChecker.copyDownloadUrl()
                        linkCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            linkCopied = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: linkCopied ? "checkmark" : "doc.on.doc")
                            Text(linkCopied ? "已复制" : "复制链接")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(linkCopied)
                }

                Button("取消") {
                    updateChecker.cancelDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 420, height: 120)
    }
}

// MARK: - Error Text View with Tooltip

struct ErrorTextView: View {
    let message: String
    var onCopied: (() -> Void)?

    var body: some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundColor(.red)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(message)
            .onTapGesture {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
                onCopied?()
            }
    }
}
