import AppKit
import QingYiCore
import SwiftUI

@MainActor
final class UpdateViewModel: ObservableObject {
    let release: ReleaseInfo
    unowned let app: AppDelegate

    @Published private(set) var busy = false
    @Published private(set) var progress = 0.0
    @Published private(set) var progressText = ""
    @Published private(set) var error: String?

    private var download: Task<Void, Never>?

    init(release: ReleaseInfo, app: AppDelegate) {
        self.release = release
        self.app = app
    }

    var isDownloading: Bool { download != nil }

    var heading: String { L("轻译 \(release.versionText) 已发布", "QingYi Translator \(release.versionText) is available") }

    var subtitle: String {
        let current = AppInfo.versionText
        if let at = release.publishedAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let date = formatter.string(from: at)
            return L("当前版本 \(current) · 发布于 \(date)", "You have \(current) · released \(date)")
        }
        return L("当前版本 \(current)", "You have \(current)")
    }

    var notes: String { UpdateViewModel.formatNotes(release.notes) }

    /// Release notes are Markdown; show them as tidy plain text.
    static func formatNotes(_ markdown: String) -> String {
        if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L("（这个版本没有更新说明）", "(No release notes)")
        }
        var lines: [String] = []
        let linkPattern = try! NSRegularExpression(pattern: #"!?\[([^\]]*)\]\([^)]*\)"#)
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                line = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                line = "• " + line.dropFirst(2)
            }
            line = linkPattern.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "$1")
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "`", with: "")
            if line.isEmpty && (lines.isEmpty || lines[lines.count - 1].isEmpty) {
                continue // no leading or repeated blank lines
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func install(close: @escaping () -> Void) {
        error = nil
        if !SelfUpdater.canUpdateInPlace() {
            error = L("无法在当前位置自动更新（应用所在的文件夹不可写入，或者这不是打包的版本）。请点“在网页中查看”下载新版本，替换原来的应用。",
                      "Can’t update automatically here (the app’s folder isn’t writable, or this isn’t a packaged build). Click “View on GitHub”, download the new version and replace the app.")
            return
        }
        busy = true
        progress = 0
        progressText = L("正在连接…", "Connecting…")
        let release = self.release
        download = Task { [weak self] in
            do {
                let path = SelfUpdater.downloadPath
                try await UpdateService.download(release, to: path) { fraction in
                    Task { @MainActor [weak self] in
                        self?.progress = fraction
                        self?.progressText = L("正在下载… \(Int(fraction * 100))%", "Downloading… \(Int(fraction * 100))%")
                    }
                }
                guard let self else { return }
                progressText = L("下载完成，正在重启轻译…", "Downloaded. Restarting…")
                download = nil
                try app.installUpdate(downloaded: path) // exits the app when it succeeds
            } catch is CancellationError {
                self?.finish()
            } catch let error as UpdateError {
                self?.error = error.message
                self?.finish()
            } catch {
                Log.error("安装更新失败", error)
                self?.error = L("更新失败：\(error.localizedDescription)", "Update failed: \(error.localizedDescription)")
                self?.finish()
            }
        }
    }

    private func finish() {
        download = nil
        busy = false
        progressText = ""
    }

    func cancelDownload() {
        download?.cancel()
    }

    func skip(close: () -> Void) {
        app.skipUpdate(release)
        close()
    }

    func openPage() {
        if let url = URL(string: release.pageUrl) {
            NSWorkspace.shared.open(url)
        }
    }
}

struct UpdateView: View {
    @ObservedObject var model: UpdateViewModel
    @EnvironmentObject var loc: Loc
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.heading).font(.system(size: 16, weight: .semibold)).foregroundColor(Palette.textPrimary)
            Text(model.subtitle).font(.system(size: 12)).foregroundColor(Palette.textSecondary).padding(.top, 4)
            ScrollView {
                Text(model.notes).font(.system(size: 13)).foregroundColor(Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.output))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 1))
            .padding(.top, 12)
            if model.busy {
                ProgressView(value: model.progress).progressViewStyle(.linear).padding(.top, 12)
                Text(model.progressText).font(.system(size: 12)).foregroundColor(Palette.textSecondary).padding(.top, 4)
            }
            if let error = model.error {
                Text(error).font(.system(size: 12)).foregroundColor(Palette.error).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            }
            HStack {
                Button(L("在网页中查看", "View on GitHub")) { model.openPage() }.buttonStyle(LinkButtonStyle())
                Spacer()
                Button(L("跳过此版本", "Skip this version")) { model.skip(close: close) }.buttonStyle(SecondaryButtonStyle()).disabled(model.busy)
                Button(model.busy ? L("取消", "Cancel") : L("以后再说", "Later")) {
                    if model.busy { model.cancelDownload() } else { close() }
                }
                .buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction).padding(.leading, 8)
                Button(L("立即更新", "Update now")) { model.install(close: close) }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(model.busy).padding(.leading, 8)
            }
            .padding(.top, 14)
        }
        .padding(20)
        .background(Palette.surface)
        .frame(minWidth: 440, minHeight: 320)
    }
}
