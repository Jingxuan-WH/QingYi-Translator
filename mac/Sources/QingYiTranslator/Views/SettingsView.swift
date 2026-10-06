import AppKit
import Combine
import QingYiCore
import SwiftUI

/// Draft of the settings; nothing is written until `save()`. Language and theme preview live.
@MainActor
final class SettingsViewModel: ObservableObject {
    let settings: AppSettings
    unowned let app: AppDelegate

    @Published var uiLanguage: String { didSet { Loc.shared.apply(uiLanguage) } }
    @Published var theme: String { didSet { ThemeManager.apply(theme) } }

    @Published var currentProvider: String {
        didSet { if currentProvider != oldValue { storeProviderFields(oldValue); loadProviderFields(currentProvider) } }
    }
    private var providers: [String: ProviderConfig]
    private var editedKeys: [String: String] = [:]
    @Published var apiKey = ""
    @Published var revealKey = false
    @Published var baseUrl = ""
    @Published var model = ""
    @Published var testResult = ""
    @Published var testResultColor = Palette.textSecondary
    @Published var testing = false

    @Published var doubleCopyEnabled: Bool
    @Published var hotkeyEnabled: Bool { didSet { updateHotkeyStatus() } }
    @Published private(set) var hotkey: HotkeyGesture?
    @Published var hotkeyText = ""
    @Published var hotkeyStatus = ""
    @Published var hotkeyStatusIsError = false
    @Published var accessibilityTrusted = Accessibility.isTrusted

    @Published var extraInstructions: String
    @Published var incrementalTranslation: Bool
    @Published var saveHistory: Bool
    @Published var autoTranslate: Bool
    @Published var restoreClipboard: Bool
    @Published var closeToMenuBar: Bool
    @Published var launchAtLogin: Bool
    @Published var autoCheckUpdates: Bool
    @Published var updateStatus = ""
    @Published var updateStatusColor = Palette.textTertiary
    @Published var checkingUpdates = false
    @Published var glossaryStatus = ""

    private(set) var saved = false
    private var subscriptions = Set<AnyCancellable>()

    init(settings: AppSettings, app: AppDelegate) {
        self.settings = settings
        self.app = app
        uiLanguage = settings.uiLanguage
        theme = settings.theme
        providers = settings.providerConfigs
        currentProvider = settings.activeProvider
        doubleCopyEnabled = settings.doubleCopyEnabled
        hotkeyEnabled = settings.hotkeyEnabled
        hotkey = HotkeyGesture.parse(settings.hotkey)
        extraInstructions = settings.extraInstructions
        incrementalTranslation = settings.incrementalTranslation
        saveHistory = settings.saveHistory
        autoTranslate = settings.autoTranslate
        restoreClipboard = settings.restoreClipboard
        closeToMenuBar = settings.closeToMenuBar
        launchAtLogin = settings.launchAtLogin
        autoCheckUpdates = settings.autoCheckUpdates
        loadProviderFields(currentProvider)
        hotkeyText = hotkey?.description ?? ""
        updateHotkeyStatus()
        updateStatus = describeLastCheck()
        refreshGlossaryStatus()

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.accessibilityTrusted = Accessibility.isTrusted }
            .store(in: &subscriptions)
        Loc.shared.$isEnglish.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.onInterfaceLanguageChanged() }
            .store(in: &subscriptions)
    }

    var preset: ProviderPreset { ProviderCatalog.get(currentProvider) }

    var currentVersionText: String { L("当前版本 \(AppInfo.versionText)", "Current version \(AppInfo.versionText)") }

    var dataDirectoryText: String { L("设置保存在 \(AppPaths.dataDirectory.path)", "Settings are stored in \(AppPaths.dataDirectory.path)") }

    // ---------------- provider ----------------

    private func loadProviderFields(_ id: String) {
        let preset = ProviderCatalog.get(id)
        let config = providers[id] ?? ProviderConfig.fromPreset(preset)
        providers[id] = config
        apiKey = editedKeys[id] ?? settings.apiKey(for: id)
        baseUrl = config.baseUrl
        model = config.model
        testResult = ""
    }

    private func storeProviderFields(_ id: String) {
        var config = providers[id] ?? ProviderConfig.fromPreset(ProviderCatalog.get(id))
        editedKeys[id] = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        config.baseUrl = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        config.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        providers[id] = config
    }

    var keyHint: String {
        preset.requiresApiKey
            ? L("API Key 保存在 macOS 钥匙串中，不会上传到其他地方。", "Your API key is stored in the macOS Keychain and never uploaded anywhere.")
            : L("本地模型不需要 API Key，可以留空。", "Local models don’t need an API key; leave it empty.")
    }

    var baseUrlHint: String {
        preset.baseUrl.isEmpty
            ? L("填写服务商提供的 OpenAI 兼容接口地址，例如 https://example.com/v1", "Enter the OpenAI-compatible base URL from your provider, e.g. https://example.com/v1")
            : L("默认 \(preset.baseUrl)，一般不需要修改。", "Default: \(preset.baseUrl). Usually there is no need to change it.")
    }

    func openKeyUrl() {
        if let url = preset.keyUrl.flatMap(URL.init(string:)) {
            NSWorkspace.shared.open(url)
        }
    }

    func testConnection() {
        var config = providers[currentProvider] ?? ProviderConfig.fromPreset(preset)
        config.baseUrl = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        config.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = self.preset
        testing = true
        setTestResult(L("正在连接…", "Connecting…"), Palette.textSecondary)
        let started = Date()
        Task { [weak self] in
            var reply = ""
            do {
                _ = try await Timeouts.run(seconds: 30) {
                    try await TranslationClient().translate(preset: preset, config: config, apiKey: key, extraInstructions: "",
                        request: TranslationRequest(text: "Hello, world!", source: Languages.english, target: Languages.simplifiedChinese)) { piece in
                        reply += piece
                    }
                }
                var sample = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                if sample.count > 30 {
                    sample = String(sample.prefix(30)) + "…"
                }
                let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                self?.setTestResult(L("✓ 连接成功（\(seconds) 秒）：\(sample)", "✓ Connected (\(seconds) s): \(sample)"), Palette.success)
            } catch let error as TranslationError {
                self?.setTestResult(error.message, Palette.error)
            } catch is TimeoutError {
                self?.setTestResult(L("连接超时，请检查网络和接口地址。", "Timed out. Please check your network and the base URL."), Palette.error)
            } catch {
                Log.error("测试连接失败", error)
                self?.setTestResult(L("测试失败：\(error.localizedDescription)", "Test failed: \(error.localizedDescription)"), Palette.error)
            }
            self?.testing = false
        }
    }

    private func setTestResult(_ text: String, _ color: Color) {
        testResult = text
        testResultColor = color
    }

    // ---------------- hotkey ----------------

    func hotkeyFocusChanged(_ focused: Bool) {
        if focused {
            app.suspendHotkey()
            setHotkeyStatus(L("请按下新的组合键（Esc 取消，⌫ 清除）", "Press the new key combination (Esc cancels, ⌫ clears)"), isError: false)
        } else {
            app.resumeHotkey()
            hotkeyText = hotkey?.description ?? ""
            updateHotkeyStatus()
        }
    }

    func hotkeyModifiersChanged(_ modifiers: HotkeyModifiers) {
        hotkeyText = modifiers.isEmpty ? (hotkey?.description ?? "") : HotkeyGesture.symbols(for: modifiers) + "…"
    }

    func hotkeyRecorded(_ gesture: HotkeyGesture) {
        hotkeyText = gesture.description
        if !gesture.isValid {
            setHotkeyStatus(L("快捷键需要包含 ⌘、⌥ 或 ⌃ 键", "The hotkey must include ⌘, ⌥ or ⌃"), isError: true)
            return
        }
        hotkey = gesture
        updateHotkeyStatus()
    }

    func hotkeyCleared() {
        hotkey = nil
        hotkeyText = ""
        setHotkeyStatus(L("已清除快捷键", "Hotkey cleared"), isError: false)
    }

    private func updateHotkeyStatus() {
        if hotkey == nil {
            setHotkeyStatus(hotkeyEnabled ? L("尚未设置快捷键，点击上面的输入框后按下组合键", "No hotkey yet. Click the box above and press a key combination") : "",
                            isError: hotkeyEnabled)
        } else {
            setHotkeyStatus(L("选中文字后按下即可翻译；没有选中文字时会直接打开主窗口，再按一次可隐藏。",
                              "Select text and press it to translate. Without a selection it opens the main window; press again to hide it."), isError: false)
        }
    }

    private func setHotkeyStatus(_ text: String, isError: Bool) {
        hotkeyStatus = text
        hotkeyStatusIsError = isError
    }

    // ---------------- glossary ----------------

    func openGlossary(from window: NSWindow?) {
        app.openGlossary(from: window)
    }

    func refreshGlossaryStatus() {
        let count = app.glossary.entries.count
        glossaryStatus = count == 0
            ? L("按你指定的译法翻译专业术语、人名和产品名。", "Make terms, names and product names translate the way you want.")
            : !settings.glossaryEnabled ? L("\(count) 条术语 · 已停用", count == 1 ? "1 term · turned off" : "\(count) terms · turned off")
            : L("\(count) 条术语 · 已启用", count == 1 ? "1 term · on" : "\(count) terms · on")
    }

    // ---------------- updates ----------------

    func checkForUpdates(from window: NSWindow?) {
        checkingUpdates = true
        setUpdateStatus(L("正在检查…", "Checking…"), Palette.textTertiary)
        Task { [weak self] in
            guard let self else { return }
            do {
                if let release = try await app.checkForUpdates(userInitiated: true) {
                    setUpdateStatus(L("发现新版本 \(release.versionText)", "Version \(release.versionText) is available"), Palette.accentText)
                    app.showUpdateDialog(release, from: window)
                } else {
                    setUpdateStatus(L("已是最新版本。", "You’re up to date."), Palette.success)
                }
            } catch let error as UpdateError {
                setUpdateStatus(error.message, Palette.error)
            } catch {
                setUpdateStatus(error.localizedDescription, Palette.error)
            }
            checkingUpdates = false
        }
    }

    private func describeLastCheck() -> String {
        guard let last = settings.lastUpdateCheck else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return L("上次检查：\(formatter.string(from: last))", "Last checked: \(formatter.string(from: last))")
    }

    private func setUpdateStatus(_ text: String, _ color: Color) {
        updateStatus = text
        updateStatusColor = color
    }

    // ---------------- save / cancel ----------------

    /// False when something still needs attention (the hotkey).
    func save() -> Bool {
        if hotkeyEnabled && hotkey == nil {
            setHotkeyStatus(L("请先设置快捷键，或者关闭这个选项", "Set a hotkey first, or turn this option off"), isError: true)
            return false
        }
        storeProviderFields(currentProvider)
        for (id, key) in editedKeys {
            settings.setApiKey(key, for: id)
        }
        settings.providerConfigs = providers
        settings.activeProvider = currentProvider
        settings.doubleCopyEnabled = doubleCopyEnabled
        settings.hotkeyEnabled = hotkeyEnabled
        settings.hotkey = hotkey?.storageString ?? ""
        settings.extraInstructions = extraInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.incrementalTranslation = incrementalTranslation
        settings.saveHistory = saveHistory
        settings.autoTranslate = autoTranslate
        settings.restoreClipboard = restoreClipboard
        settings.closeToMenuBar = closeToMenuBar
        settings.launchAtLogin = launchAtLogin
        settings.autoCheckUpdates = autoCheckUpdates
        settings.uiLanguage = uiLanguage
        settings.theme = theme
        saved = true
        return true
    }

    /// Puts the live-previewed language and theme back.
    func revertPreview() {
        if !saved {
            Loc.shared.apply(settings.uiLanguage)
            ThemeManager.apply(settings.theme)
        }
    }

    private func onInterfaceLanguageChanged() {
        updateHotkeyStatus()
        updateStatus = describeLastCheck()
        refreshGlossaryStatus()
        objectWillChange.send()
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel
    @EnvironmentObject var loc: Loc
    var window: () -> NSWindow?
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    appearance
                    service
                    shortcuts
                    permissions
                    preferences
                    general
                    updates
                    HintText(text: model.dataDirectoryText).padding(.leading, 4).padding(.top, 8)
                }
                .padding(EdgeInsets(top: 2, leading: 24, bottom: 20, trailing: 24))
            }
            HStack {
                Spacer()
                Button(L("取消", "Cancel")) { model.revertPreview(); close() }
                    .buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button(L("保存", "Save")) { if model.save() { close() } }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).padding(.leading, 10)
            }
            .padding(EdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 24))
            .background(Palette.surface)
            .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
        }
        .background(Palette.window)
        .frame(minWidth: 480, minHeight: 420)
    }

    private var appearance: some View {
        Group {
            SectionTitle(text: L("外观", "Appearance"))
            Card(padding: EdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18)) {
                HStack {
                    Text(L("界面语言 / Language", "Language")).font(.system(size: 13))
                    Spacer()
                    Picker("", selection: $model.uiLanguage) {
                        Text(L("跟随系统", "System default")).tag(Loc.systemCode)
                        Text("简体中文").tag(Loc.chineseCode)
                        Text("English").tag(Loc.englishCode)
                    }
                    .labelsHidden().frame(width: 200)
                }
                HStack {
                    Text(L("主题", "Theme")).font(.system(size: 13))
                    Spacer()
                    Picker("", selection: $model.theme) {
                        Text(L("跟随系统", "System default")).tag(AppSettings.themeSystem)
                        Text(L("浅色", "Light")).tag(AppSettings.themeLight)
                        Text(L("深色", "Dark")).tag(AppSettings.themeDark)
                    }
                    .labelsHidden().frame(width: 200)
                }
                .padding(.top, 10)
            }
        }
    }

    private var service: some View {
        Group {
            SectionTitle(text: L("翻译服务", "Translation service"))
            Card {
                FieldLabel(text: L("服务商", "Provider"))
                Picker("", selection: $model.currentProvider) {
                    ForEach(ProviderCatalog.all, id: \.id) { preset in
                        Text(preset.displayName.text).tag(preset.id)
                    }
                }
                .labelsHidden()
                HintText(text: model.preset.hint.text)

                HStack {
                    Text("API Key").font(.system(size: 13))
                    Spacer()
                    if model.preset.keyUrl != nil {
                        Button(L("获取 API Key", "Get an API key")) { model.openKeyUrl() }.buttonStyle(LinkButtonStyle())
                    }
                }
                .padding(.top, 12).padding(.bottom, 6)
                HStack(spacing: 0) {
                    Group {
                        if model.revealKey {
                            TextField("", text: $model.apiKey)
                        } else {
                            SecureField("", text: $model.apiKey)
                        }
                    }
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(Palette.textPrimary)
                    .accessibilityLabel("API Key")
                    IconButton(symbol: model.revealKey ? "eye.slash" : "eye", help: L("显示 / 隐藏", "Show / hide"), size: 26, fontSize: 12) {
                        model.revealKey.toggle()
                    }
                }
                .padding(.leading, 8).padding(.trailing, 2)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Palette.surface))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.inputLine, lineWidth: 1))
                HintText(text: model.keyHint)

                FieldLabel(text: L("接口地址", "Base URL"))
                TextField("", text: $model.baseUrl).formField()
                HintText(text: model.baseUrlHint)

                FieldLabel(text: L("模型", "Model"))
                TextField("", text: $model.model).formField()
                if !model.preset.suggestedModels.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(model.preset.suggestedModels, id: \.self) { name in
                            Button(name) { model.model = name }.buttonStyle(ChipButtonStyle())
                        }
                    }
                    .padding(.top, 8)
                }
                HintText(text: model.preset.modelHint.text)

                HStack(alignment: .center, spacing: 12) {
                    Button(L("测试连接", "Test connection")) { model.testConnection() }
                        .buttonStyle(SecondaryButtonStyle()).disabled(model.testing)
                    Text(model.testResult).font(.system(size: 12)).foregroundColor(model.testResultColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 16)
            }
        }
    }

    private var shortcuts: some View {
        Group {
            SectionTitle(text: L("快捷键", "Shortcuts"))
            Card {
                ToggleRow(title: L("按两次 ⌘C 翻译选中的文字", "Press ⌘C twice to translate the selection"), isOn: $model.doubleCopyEnabled)
                HintText(text: L("与 DeepL 相同：选中文字后按住 ⌘，快速按两下 C。", "Like DeepL: select text, hold ⌘ and quickly press C twice."))
                ToggleRow(title: L("使用快捷键翻译选中的文字", "Use a hotkey to translate the selection"), isOn: $model.hotkeyEnabled).padding(.top, 4)
                HStack(spacing: 12) {
                    Text(L("快捷键", "Hotkey")).font(.system(size: 13))
                    HotkeyRecorder(text: model.hotkeyText, onFocusChange: model.hotkeyFocusChanged, onModifiers: model.hotkeyModifiersChanged,
                                   onGesture: model.hotkeyRecorded, onClear: model.hotkeyCleared)
                        .frame(width: 200, height: 30)
                    Spacer()
                }
                .padding(.top, 10)
                HintText(text: model.hotkeyStatus, color: model.hotkeyStatusIsError ? Palette.error : Palette.textTertiary)
            }
        }
    }

    private var permissions: some View {
        Group {
            SectionTitle(text: L("辅助功能权限", "Accessibility permission"))
            Card(padding: EdgeInsets(top: 12, leading: 18, bottom: 14, trailing: 18)) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Circle().fill(model.accessibilityTrusted ? Palette.success : Palette.warning).frame(width: 7, height: 7)
                            Text(model.accessibilityTrusted ? L("已授权", "Granted") : L("未授权", "Not granted")).font(.system(size: 13))
                        }
                        HintText(text: model.accessibilityTrusted
                            ? L("⌘C⌘C 直接监听按键，快捷键可以取词并恢复剪贴板。", "⌘C⌘C is detected from the keys themselves, and the hotkey can copy the selection and restore the clipboard.")
                            : L("没有权限时 ⌘C⌘C 通过剪贴板识别，照常可用；快捷键取词需要这个权限。在“系统设置 › 隐私与安全性 › 辅助功能”里打开轻译即可。",
                                "Without it, ⌘C⌘C is detected through the clipboard and still works; the hotkey needs it to copy the selection. Turn on QingYi under System Settings › Privacy & Security › Accessibility."))
                    }
                    Spacer()
                    if !model.accessibilityTrusted {
                        Button(L("打开系统设置…", "Open System Settings…")) { Accessibility.request() }.buttonStyle(SecondaryButtonStyle(compact: true))
                    }
                }
            }
        }
    }

    private var preferences: some View {
        Group {
            SectionTitle(text: L("翻译偏好", "Translation preferences"))
            Card {
                FieldLabel(text: L("附加要求（可选）", "Extra instructions (optional)"))
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.extraInstructions)
                        .font(.system(size: 13)).foregroundColor(Palette.textPrimary)
                        .scrollContentBackground(.hidden)
                        .padding(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                        .frame(height: 76)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Palette.surface))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.inputLine, lineWidth: 1))
                    if model.extraInstructions.isEmpty {
                        Text(L("例如：使用学术论文的正式文风；专业术语保留英文原文。", "For example: use the formal style of academic papers; keep technical terms in English."))
                            .font(.system(size: 13)).foregroundColor(Palette.textTertiary)
                            .padding(EdgeInsets(top: 5, leading: 9, bottom: 0, trailing: 10))
                            .allowsHitTesting(false)
                    }
                }
                HintText(text: L("会附加在给模型的翻译指令后面。", "Appended to the translation instructions sent to the model."))
                ToggleRow(title: L("增量翻译：追加内容时只翻译新增部分", "Incremental translation: only translate what you add"), isOn: $model.incrementalTranslation)
                    .padding(.top, 6)
                HintText(text: L("已经译好的完整段落直接复用，并作为上下文发给模型，保持前后术语一致；更快也更省钱。关闭后每次修改都整体重新翻译。",
                                 "Finished paragraphs are reused and sent to the model as context, keeping terms consistent. Faster and cheaper. When off, every edit retranslates everything."))
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(L("术语表", "Glossary")).font(.system(size: 13))
                        HintText(text: model.glossaryStatus)
                    }
                    Spacer()
                    Button(L("编辑术语表…", "Edit glossary…")) { model.openGlossary(from: window()) }.buttonStyle(SecondaryButtonStyle(compact: true))
                }
                .padding(.top, 18)
            }
        }
    }

    private var general: some View {
        Group {
            SectionTitle(text: L("常规", "General"))
            Card {
                ToggleRow(title: L("输入时自动翻译", "Translate as you type"), isOn: $model.autoTranslate)
                ToggleRow(title: L("保存翻译历史（最近 100 条，只存在本机）", "Keep history (last 100, stored only on this Mac)"), isOn: $model.saveHistory)
                ToggleRow(title: L("快捷键取词后恢复剪贴板原来的内容", "Restore the clipboard after the hotkey copies a selection"), isOn: $model.restoreClipboard)
                ToggleRow(title: L("关闭主窗口时保留在菜单栏", "Keep running in the menu bar when the window is closed"), isOn: $model.closeToMenuBar)
                ToggleRow(title: L("登录时自动启动", "Launch at login"), isOn: $model.launchAtLogin).disabled(!LaunchAtLogin.isAvailable)
                if !LaunchAtLogin.isAvailable {
                    HintText(text: L("只有打包成 .app 的版本可以设置登录启动。", "Only the packaged .app can be set to launch at login."))
                }
            }
        }
    }

    private var updates: some View {
        Group {
            SectionTitle(text: L("更新", "Updates"))
            Card {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.currentVersionText).font(.system(size: 13))
                        HintText(text: model.updateStatus, color: model.updateStatusColor)
                    }
                    Spacer()
                    Button(L("检查更新", "Check for updates")) { model.checkForUpdates(from: window()) }
                        .buttonStyle(SecondaryButtonStyle(compact: true)).disabled(model.checkingUpdates)
                }
                .padding(.top, 12)
                ToggleRow(title: L("自动检查新版本", "Check for new versions automatically"), isOn: $model.autoCheckUpdates).padding(.top, 4)
                HintText(text: L("启动时和之后每 12 小时从 GitHub 检查一次。发现新版本时只提示你，确认后才会下载和安装。",
                                 "Checks GitHub at startup and every 12 hours. You’re only notified; nothing is downloaded or installed until you confirm."))
            }
        }
    }
}
