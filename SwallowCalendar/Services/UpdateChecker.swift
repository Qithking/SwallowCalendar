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
    @Published var isInstalling = false  // 是否正在安装

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
    
    deinit {
        checkTimer?.invalidate()
        downloadSession?.invalidateAndCancel()
        downloadTask?.cancel()
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
        let fileManager = FileManager.default
        
        // 先验证临时文件是否存在
        guard fileManager.fileExists(atPath: location.path) else {
            Task { @MainActor in
                self.downloadError = "下载文件不存在，请重试"
                self.isDownloading = false
            }
            return
        }
        
        // 立即将文件移动到安全位置（使用 UUID 避免冲突）
        let tempDir = FileManager.default.temporaryDirectory
        let tempFileName = "SwallowCalendar_\(UUID().uuidString).tmp"
        let tempDestURL = tempDir.appendingPathComponent(tempFileName)
        
        do {
            try fileManager.moveItem(at: location, to: tempDestURL)
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
                guard let downloadsFolder = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
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
                if fileManager.fileExists(atPath: destinationUrl.path) {
                    try fileManager.removeItem(at: destinationUrl)
                }

                // 移动文件到下载文件夹
                try fileManager.moveItem(at: tempDestURL, to: destinationUrl)

                self.downloadProgress = 1.0
                self.isDownloading = false
                self.closeDownloadWindow()

                // 下载完成，提示用户是否安装并重启
                self.promptInstallAndRestart(downloadedFileUrl: destinationUrl)
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

    // MARK: - Install & Restart

    /// 下载完成后提示用户是否安装并重启
    private func promptInstallAndRestart(downloadedFileUrl: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "下载完成"
        alert.informativeText = "SwallowCalendar v\(latestVersion) 已下载完成，是否立即安装并重启应用？"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "安装并重启")
        alert.addButton(withTitle: "稍后手动安装")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            installAndRestart(downloadedFileUrl: downloadedFileUrl)
        } else {
            // 稍后手动安装，打开文件所在文件夹
            NSWorkspace.shared.activateFileViewerSelecting([downloadedFileUrl])
        }
    }

    /// 自动安装新版本并重启应用
    private func installAndRestart(downloadedFileUrl: URL) {
        isInstalling = true

        // 在后台线程执行安装操作
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let appBundleURL = try self.extractAppBundle(from: downloadedFileUrl)

                // 切回主线程执行替换和重启
                DispatchQueue.main.async {
                    do {
                        try self.replaceAppBundle(with: appBundleURL)
                        self.isInstalling = false
                        self.restartApplication()
                    } catch {
                        self.isInstalling = false
                        self.showInstallError("替换应用失败: \(error.localizedDescription)\n\n文件已保存到下载文件夹，请手动安装。", fileUrl: downloadedFileUrl)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isInstalling = false
                    self.showInstallError("解压失败: \(error.localizedDescription)\n\n文件已保存到下载文件夹，请手动安装。", fileUrl: downloadedFileUrl)
                }
            }
        }
    }

    /// 显示安装错误，并提供打开文件的选项
    private func showInstallError(_ message: String, fileUrl: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "自动安装失败"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开文件")
        alert.addButton(withTitle: "确定")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(fileUrl)
        }
    }

    /// 从 DMG 或 ZIP 文件中提取 .app 包
    nonisolated private func extractAppBundle(from fileUrl: URL) throws -> URL {
        let fileExtension = fileUrl.pathExtension.lowercased()

        if fileExtension == "dmg" {
            return try extractAppFromDMG(dmgUrl: fileUrl)
        } else if fileExtension == "zip" {
            return try extractAppFromZip(zipUrl: fileUrl)
        } else {
            throw InstallError.unsupportedFormat
        }
    }

    /// 从 DMG 中挂载并提取 .app 包
    nonisolated private func extractAppFromDMG(dmgUrl: URL) throws -> URL {
        let mountPoint = NSTemporaryDirectory() + "SwallowCalendar_Install_\(UUID().uuidString)"

        // 创建挂载点目录
        try FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)

        // 挂载 DMG
        let attachProcess = Process()
        attachProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attachProcess.arguments = ["attach", dmgUrl.path, "-mountpoint", mountPoint, "-nobrowse", "-quiet"]
        let attachPipe = Pipe()
        attachProcess.standardError = attachPipe
        try attachProcess.run()
        attachProcess.waitUntilExit()

        guard attachProcess.terminationStatus == 0 else {
            let errorData = attachPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "未知错误"
            // 尝试清理
            try? FileManager.default.removeItem(atPath: mountPoint)
            throw InstallError.dmgMountFailed(errorMessage)
        }

        // 查找 .app 文件
        let contents = try FileManager.default.contentsOfDirectory(atPath: mountPoint)
        guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
            // 卸载并清理
            detachDMG(at: mountPoint)
            throw InstallError.appNotFoundInArchive
        }

        // 将 .app 复制到临时目录
        let tempAppURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SwallowCalendar_\(UUID().uuidString).app")

        // 如果临时位置已存在同名文件，先删除
        if FileManager.default.fileExists(atPath: tempAppURL.path) {
            try FileManager.default.removeItem(at: tempAppURL)
        }

        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: mountPoint).appendingPathComponent(appName),
            to: tempAppURL
        )

        // 卸载 DMG
        detachDMG(at: mountPoint)

        return tempAppURL
    }

    /// 卸载 DMG
    nonisolated private func detachDMG(at mountPoint: String) {
        let detachProcess = Process()
        detachProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        detachProcess.arguments = ["detach", mountPoint, "-quiet"]
        try? detachProcess.run()
        detachProcess.waitUntilExit()
    }

    /// 从 ZIP 中提取 .app 包
    nonisolated private func extractAppFromZip(zipUrl: URL) throws -> URL {
        let tempDir = NSTemporaryDirectory() + "SwallowCalendar_Install_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)

        // 使用 unzip 命令解压
        let unzipProcess = Process()
        unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzipProcess.arguments = ["-o", "-q", zipUrl.path, "-d", tempDir]
        let unzipPipe = Pipe()
        unzipProcess.standardError = unzipPipe
        try unzipProcess.run()
        unzipProcess.waitUntilExit()

        guard unzipProcess.terminationStatus == 0 else {
            let errorData = unzipPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "未知错误"
            try? FileManager.default.removeItem(atPath: tempDir)
            throw InstallError.zipExtractFailed(errorMessage)
        }

        // 递归查找 .app 文件
        let appURL = try findAppBundle(in: URL(fileURLWithPath: tempDir))

        // 将 .app 复制到临时目录（避免路径嵌套过深）
        let tempAppURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SwallowCalendar_\(UUID().uuidString).app")

        if FileManager.default.fileExists(atPath: tempAppURL.path) {
            try FileManager.default.removeItem(at: tempAppURL)
        }

        try FileManager.default.copyItem(at: appURL, to: tempAppURL)

        // 清理解压临时目录
        try? FileManager.default.removeItem(atPath: tempDir)

        return tempAppURL
    }

    /// 递归查找 .app 包
    nonisolated private func findAppBundle(in directory: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)

        // 优先在当前目录找 .app
        if let appURL = contents.first(where: { $0.pathExtension == "app" }) {
            return appURL
        }

        // 递归搜索子目录
        for item in contents {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                if let found = try? findAppBundle(in: item) {
                    return found
                }
            }
        }

        throw InstallError.appNotFoundInArchive
    }

    /// 替换当前应用包
    nonisolated private func replaceAppBundle(with newAppURL: URL) throws {
        let currentAppURL = Bundle.main.bundleURL

        // 如果新 app 和当前 app 名称不同，先重命名为当前 app 的名称
        let currentAppName = currentAppURL.lastPathComponent
        let newAppName = newAppURL.lastPathComponent

        let finalNewAppURL: URL
        if currentAppName != newAppName {
            finalNewAppURL = newAppURL.deletingLastPathComponent().appendingPathComponent(currentAppName)
            if FileManager.default.fileExists(atPath: finalNewAppURL.path) {
                try FileManager.default.removeItem(at: finalNewAppURL)
            }
            try FileManager.default.moveItem(at: newAppURL, to: finalNewAppURL)
        } else {
            finalNewAppURL = newAppURL
        }

        // 删除旧应用
        try FileManager.default.removeItem(at: currentAppURL)

        // 将新应用移动到原位置
        try FileManager.default.moveItem(at: finalNewAppURL, to: currentAppURL)
    }

    /// 重启应用
    /// - Note: 必须将重启命令放到独立的后台进程中执行，使其在当前应用退出后仍能运行。
    ///         macOS 下通过 Process 启动的子进程不会随父进程退出而被杀死（会被 reparent 到 launchd）。
    private func restartApplication() {
        let appPath = Bundle.main.bundleURL.path

        // 使用 Process 启动后台进程：sleep 1 秒后 open 应用
        // 关键：不等待进程完成，立即退出当前应用，后台进程在1秒后执行 open 启动新版本
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1 && open \"\(appPath)\""]

        do {
            try process.run()
        } catch {
            // Process 启动失败，回退到 AppleScript（后台执行）
            // 使用 & 将命令放到后台，使 do shell script 立即返回
            let escapedPath = appPath.replacingOccurrences(of: "\"", with: "\\\"")
            let script = "do shell script \"(sleep 1; open \\\"\(escapedPath)\\\") > /dev/null 2>&1 &\""
            let appleScript = NSAppleScript(source: script)
            var errorDict: NSDictionary?
            appleScript?.executeAndReturnError(&errorDict)
        }

        // 立即退出当前应用，后台进程将在1秒后重新启动应用
        NSApp.terminate(nil)
    }
}

// MARK: - Install Errors

enum InstallError: LocalizedError {
    case unsupportedFormat
    case dmgMountFailed(String)
    case zipExtractFailed(String)
    case appNotFoundInArchive

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "不支持的安装包格式"
        case .dmgMountFailed(let msg):
            return "DMG 挂载失败: \(msg)"
        case .zipExtractFailed(let msg):
            return "ZIP 解压失败: \(msg)"
        case .appNotFoundInArchive:
            return "在安装包中未找到应用程序"
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
                if updateChecker.isInstalling {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text("正在安装...")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                } else if let error = updateChecker.downloadError {
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

                if updateChecker.isInstalling {
                    // 安装中不显示任何按钮
                    EmptyView()
                } else if updateChecker.downloadError != nil {
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
                } else {
                    Button("取消") {
                        updateChecker.cancelDownload()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
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
