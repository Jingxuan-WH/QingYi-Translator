import AppKit
import Combine
import QingYiCore
import SwiftUI

/// Startup, windows, menu bar item, shortcut dispatch and update checks (the Mac counterpart of App.xaml.cs).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private static let updateCheckInterval: TimeInterval = 12 * 60 * 60
    private static let showNotification = Notification.Name("com.jingxuanwh.QingYiTranslator.show")

    private(set) var settings: AppSettings!
    private(set) var glossary: Glossary!
    private(set) var history: TranslationHistory!
    private(set) var model: MainViewModel!
    private(set) var activeHotkey: HotkeyGesture?
    private(set) var shortcutError: String?
    private(set) var isExiting = false

    private var mainWindow: NSWindow!
    private var settingsWindow: NSWindow?
    private var settingsModel: SettingsViewModel?
    private var glossaryWindow: NSWindow?
    private var glossaryModel: GlossaryViewModel?
    private var glossaryPasteMonitor: Any?
    private var updateWindow: NSWindow?
    private var updateModel: UpdateViewModel?
    private var statusBar: StatusBar?
    private var doubleCopy: DoubleCopyWatcher!
    private var hotkey: GlobalHotkey!
    private var keyMonitor: Any?
    private var updateTimer: Timer?
    private var firstUpdateTimer: Timer?
    private var frameSaveWork: DispatchWorkItem?
    private var subscriptions = Set<AnyCancellable>()
    private var capturing = false
    private var checkingForUpdates = false

    // ---------------- lifecycle ----------------

    func applicationWillFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--wait-pid"), index + 1 < arguments.count, let pid = Int32(arguments[index + 1]) {
            SelfUpdater.waitForExit(pid: pid)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if activateRunningInstance() {
            NSApp.terminate(nil)
            return
        }

        settings = AppSettings.load()
        Loc.shared.apply(settings.uiLanguage)
        ThemeManager.apply(settings.theme)
        buildMainMenu()
        SelfUpdater.cleanUpInBackground()

        glossary = Glossary.load()
        history = TranslationHistory.load()
        model = MainViewModel(settings: settings, history: history, glossary: glossary)
        model.openSettings = { [weak self] in self?.openSettings() }
        model.openGlossary = { [weak self] in self?.openGlossary(from: self?.mainWindow) }
        model.showUpdate = { [weak self] release in self?.showUpdateDialog(release, from: self?.mainWindow) }
        model.hideWindow = { [weak self] in self?.hideMainWindow() }
        model.shortcutDescriptions = { [weak self] in
            guard let self else { return [] }
            var shortcuts: [String] = []
            if settings.doubleCopyEnabled { shortcuts.append("⌘C⌘C") }
            if let hotkey = activeHotkey { shortcuts.append(hotkey.description) }
            return shortcuts
        }
        model.shortcutError = { [weak self] in self?.shortcutError }
        createMainWindow()

        let statusBar = StatusBar()
        statusBar.openRequested = { [weak self] in self?.showMainWindow() }
        statusBar.settingsRequested = { [weak self] in self?.openSettings() }
        statusBar.quitRequested = { [weak self] in self?.exitApp() }
        self.statusBar = statusBar

        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showRequested), name: AppDelegate.showNotification, object: nil)
        Loc.shared.$isEnglish.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.statusBar?.updateTexts()
            self?.buildMainMenu()
            self?.mainWindow.title = L("轻译", "QingYi Translator")
        }.store(in: &subscriptions)
        model.$topmost.receive(on: DispatchQueue.main).sink { [weak self] topmost in
            self?.mainWindow.level = topmost ? .floating : .normal
        }.store(in: &subscriptions)

        doubleCopy = DoubleCopyWatcher { [weak self] before in self?.onDoubleCopy(changeCountBeforeFirstCopy: before) }
        hotkey = GlobalHotkey()
        hotkey.pressed = { [weak self] in self?.onHotkeyPressed() }
        applyShortcutSettings()
        applyLaunchAtLogin()
        installKeyMonitor()

        let arguments = CommandLine.arguments
        if arguments.contains("--updated") {
            let version = AppInfo.versionText
            Log.info("已更新到 \(version)")
            model.showNotice { L("轻译已更新到 \(version)", "Updated to version \(version)") }
        }
        if arguments.contains("--minimized") {
            NSApp.setActivationPolicy(.accessory)
        } else {
            showMainWindow()
            if settings.activePreset.requiresApiKey && settings.apiKey(for: settings.activeProvider).isEmpty {
                DispatchQueue.main.async { self.openSettings() }
            }
        }
        startUpdateChecks()

        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            Task { @MainActor in await Snapshots.run(app: self, into: directory) }
        }
    }

    var mainWindowForSnapshots: NSWindow? { mainWindow }
    var settingsWindowForSnapshots: NSWindow? { settingsWindow }
    var glossaryWindowForSnapshots: NSWindow? { glossaryWindow }
    var updateWindowForSnapshots: NSWindow? { updateWindow }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        // The Accessibility permission may have been granted meanwhile; switch to watching the keys directly.
        if let doubleCopy, settings?.doubleCopyEnabled == true, doubleCopy.mode != DoubleCopyWatcher.preferredMode {
            doubleCopy.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        isExiting = true
        persistState()
        doubleCopy?.stop()
        hotkey?.unregister()
        statusBar?.remove()
    }

    /// A second launch (e.g. double-clicking the app again) asks the running copy to show its window.
    private func activateRunningInstance() -> Bool {
        guard let bundleId = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else { return false }
        DistributedNotificationCenter.default().postNotificationName(AppDelegate.showNotification, object: nil, userInfo: nil, deliverImmediately: true)
        return true
    }

    @objc private func showRequested() {
        showMainWindow()
    }

    // ---------------- main window ----------------

    private func createMainWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = L("轻译", "QingYi Translator")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = settings.topmost ? .floating : .normal
        window.contentView = NSHostingView(rootView: MainView(model: model, window: { [weak window] in window }).environmentObject(Loc.shared))
        if let saved = settings.mainWindowFrame, saved.width >= 200, saved.height >= 150,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)) }) {
            window.setFrame(NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height), display: false)
        } else {
            window.center()
        }
        mainWindow = window
    }

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideMainWindow() {
        if settings.closeToMenuBar {
            saveWindowFrame()
            settings.save()
            mainWindow.orderOut(nil)
            if settingsWindow == nil && glossaryWindow == nil && updateWindow == nil {
                NSApp.setActivationPolicy(.accessory)
            }
            notifyMinimizedToMenuBar()
        } else {
            mainWindow.miniaturize(nil)
        }
    }

    /// Brings the window up after a shortcut. With text, translates it; without, focuses the input box.
    private func showWithText(_ text: String?) {
        showMainWindow()
        model.showWithText(text)
    }

    private func saveWindowFrame() {
        guard let window = mainWindow, window.isVisible || settings.mainWindowFrame != nil else { return }
        let frame = window.frame
        settings.mainWindowFrame = WindowFrame(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height)
    }

    private func notifyMinimizedToMenuBar() {
        guard !settings.menuBarTipShown else { return }
        settings.menuBarTipShown = true
        settings.save()
        Notifications.shared.show(title: L("轻译仍在后台运行", "QingYi Translator is still running"),
                                  body: L("选中文字后按 ⌘C⌘C 即可翻译。点击菜单栏的“译”图标可以打开窗口。",
                                          "Select text and press ⌘C⌘C to translate. Click the “译” icon in the menu bar to open the window."))
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window == mainWindow else { return event }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 36 && flags == [.command] { // ⌘↩
                model.translate(force: true)
                return nil
            }
            if event.keyCode == 53 && flags.isEmpty { // Esc
                if model.isHistoryOpen {
                    model.isHistoryOpen = false
                } else {
                    hideMainWindow()
                }
                return nil
            }
            return event
        }
    }

    // NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender == mainWindow {
            if isExiting {
                return true
            }
            if settings.closeToMenuBar {
                hideMainWindow()
            } else {
                exitApp()
            }
            return false
        }
        if sender == updateWindow, let updateModel, updateModel.isDownloading, !isExiting {
            // Closing during a download (Esc, Cancel or the X button) stops the download first.
            updateModel.cancelDownload()
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window == settingsWindow {
            let saved = settingsModel?.saved == true
            settingsModel?.revertPreview()
            settingsWindow = nil
            settingsModel = nil
            if isExiting {
                return
            }
            if saved {
                settings.save()
                applyLaunchAtLogin()
            }
            applyShortcutSettings() // also re-registers a hotkey suspended while recording
            if saved {
                model.onSettingsChanged()
            }
        } else if window == glossaryWindow {
            if let monitor = glossaryPasteMonitor {
                NSEvent.removeMonitor(monitor)
            }
            glossaryPasteMonitor = nil
            let vm = glossaryModel
            glossaryWindow = nil
            glossaryModel = nil
            if let vm, vm.saved, !isExiting {
                if !glossary.replace(vm.entries) {
                    Dialogs.inform(nil, heading: L("术语表保存失败", "Couldn’t save the glossary"),
                                   message: L("详细信息已写入日志：\(Log.filePath)", "Details were written to the log: \(Log.filePath)"))
                }
                settings.glossaryEnabled = vm.enabled
                settings.save()
                model.onSettingsChanged()
                settingsModel?.refreshGlossaryStatus()
            }
        } else if window == updateWindow {
            updateWindow = nil
            updateModel = nil
        }
        if window != mainWindow, !mainWindow.isVisible, settingsWindow == nil, glossaryWindow == nil, updateWindow == nil, !isExiting {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func windowDidMove(_ notification: Notification) { scheduleFrameSave(notification) }

    func windowDidResize(_ notification: Notification) { scheduleFrameSave(notification) }

    private func scheduleFrameSave(_ notification: Notification) {
        guard (notification.object as? NSWindow) == mainWindow else { return }
        frameSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveWindowFrame()
            self?.settings.save()
        }
        frameSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // ---------------- shortcuts ----------------

    func applyShortcutSettings() {
        shortcutError = nil
        if !settings.doubleCopyEnabled {
            doubleCopy.stop()
        } else {
            doubleCopy.start()
            if !doubleCopy.isRunning {
                shortcutError = L("无法监听 ⌘C⌘C", "Can’t listen for ⌘C⌘C")
            }
        }

        hotkey.unregister()
        activeHotkey = nil
        if settings.hotkeyEnabled {
            if let gesture = HotkeyGesture.parse(settings.hotkey) {
                if hotkey.register(gesture) {
                    activeHotkey = gesture
                } else {
                    shortcutError = L("快捷键 \(gesture) 注册失败，请在设置中更换", "The hotkey \(gesture) could not be registered. Please pick another one in Settings")
                }
            } else {
                shortcutError = L("快捷键设置无效，请在设置中重新设置", "The hotkey setting is invalid. Please set it again in Settings")
            }
        }
        model.refreshSettingsDisplay()
    }

    func suspendHotkey() { hotkey.unregister() }

    func resumeHotkey() {
        if let gesture = activeHotkey {
            hotkey.register(gesture)
        }
    }

    private func applyLaunchAtLogin() {
        if !AppPaths.usesCustomDataDirectory {
            LaunchAtLogin.apply(settings.launchAtLogin)
        }
    }

    private func onDoubleCopy(changeCountBeforeFirstCopy: Int?) {
        // Copying inside our own window (e.g. the translation) should not re-trigger a translation.
        if capturing || NSApp.isActive {
            return
        }
        capturing = true
        Task { @MainActor [weak self] in
            let text = await SelectionReader.readDoubleCopy(changeCountBeforeFirstCopy: changeCountBeforeFirstCopy)
            self?.showWithText(text)
            self?.capturing = false
        }
    }

    private func onHotkeyPressed() {
        guard !capturing, let gesture = activeHotkey else { return }
        if mainWindow.isVisible && mainWindow.isKeyWindow {
            hideMainWindow() // pressing the hotkey again hides the window
            return
        }
        if NSApp.isActive {
            return
        }
        capturing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            var text: String?
            if Accessibility.isTrusted {
                text = await SelectionReader.captureSelection(hotkey: gesture, restoreClipboard: settings.restoreClipboard)
            } else if !settings.accessibilityHintShown {
                settings.accessibilityHintShown = true
                settings.save()
                model.showNotice { L("要用快捷键取词，请在设置中授予辅助功能权限", "To copy the selection with the hotkey, grant the Accessibility permission in Settings") }
            }
            showWithText(text)
            capturing = false
        }
    }

    // ---------------- other windows ----------------

    func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if !mainWindow.isVisible {
            showMainWindow()
        }
        let vm = SettingsViewModel(settings: settings, app: self)
        let window = makeWindow(title: L("设置", "Settings"), size: NSSize(width: 560, height: 680), minSize: NSSize(width: 480, height: 420), over: mainWindow)
        window.contentView = NSHostingView(rootView: SettingsView(model: vm, window: { [weak window] in window }, close: { [weak window] in window?.close() })
            .environmentObject(Loc.shared))
        settingsWindow = window
        settingsModel = vm
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Edits the glossary; it is saved on its own, independent of the settings dialog.
    func openGlossary(from owner: NSWindow?) {
        if let window = glossaryWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        var owner = owner
        if owner == nil || owner?.isVisible == false {
            showMainWindow()
            owner = mainWindow
        }
        let vm = GlossaryViewModel(glossary: glossary, enabled: settings.glossaryEnabled)
        let window = makeWindow(title: L("术语表", "Glossary"), size: NSSize(width: 560, height: 520), minSize: NSSize(width: 480, height: 360), over: owner)
        window.contentView = NSHostingView(rootView: GlossaryView(model: vm, window: { [weak window] in window }, close: { [weak window] in window?.close() })
            .environmentObject(Loc.shared))
        glossaryWindow = window
        glossaryModel = vm
        // ⌘V with several lines on the clipboard adds one term per line instead of filling one cell.
        glossaryPasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, let window, event.window == window, event.keyCode == 9,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command] else { return event }
            return glossaryModel?.pasteFromClipboard(force: false) == true ? nil : event
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showUpdateDialog(_ release: ReleaseInfo, from owner: NSWindow?) {
        if let window = updateWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        var owner = owner
        if owner == nil || owner?.isVisible == false {
            showMainWindow()
            owner = mainWindow
        }
        let vm = UpdateViewModel(release: release, app: self)
        let window = makeWindow(title: L("轻译更新", "QingYi Translator Update"), size: NSSize(width: 480, height: 400), minSize: NSSize(width: 440, height: 320), over: owner)
        window.contentView = NSHostingView(rootView: UpdateView(model: vm, close: { [weak window] in window?.close() }).environmentObject(Loc.shared))
        updateWindow = window
        updateModel = vm
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow(title: String, size: NSSize, minSize: NSSize, over owner: NSWindow?) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.minSize = minSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        if let owner, owner.isVisible {
            let frame = owner.frame
            window.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        } else {
            window.center()
        }
        return window
    }

    // ---------------- exit ----------------

    func exitApp() {
        isExiting = true
        persistState()
        NSApp.terminate(nil)
    }

    /// Saves settings and window placement while the window still exists.
    private func persistState() {
        guard settings != nil else { return }
        saveWindowFrame()
        settings.save()
    }

    // ---------------- updates ----------------

    private func startUpdateChecks() {
        // The first check waits until startup has settled; later ones run every 12 hours while the app stays open.
        firstUpdateTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.checkForUpdatesInBackground(startup: true) }
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkForUpdatesInBackground(startup: false) }
        }
    }

    private func checkForUpdatesInBackground(startup: Bool) async {
        guard settings.autoCheckUpdates, !isExiting, !checkingForUpdates else { return }
        if !startup, let last = settings.lastUpdateCheck, Date().timeIntervalSince(last) < AppDelegate.updateCheckInterval {
            return
        }
        do {
            _ = try await checkForUpdates(userInitiated: false)
        } catch let error as UpdateError {
            Log.info("自动检查更新失败：\(error.message)")
        } catch {
            Log.error("自动检查更新失败", error)
        }
    }

    /// Asks GitHub for the latest release and returns it when it is newer than this version. Automatic checks
    /// ignore a version the user chose to skip. Throws `UpdateError` when the check fails.
    func checkForUpdates(userInitiated: Bool) async throws -> ReleaseInfo? {
        checkingForUpdates = true
        defer { checkingForUpdates = false }
        let release = try await UpdateService.getLatest()
        settings.lastUpdateCheck = Date()
        settings.save()
        guard let release, UpdateService.isNewer(release) else {
            model.showUpdateAvailable(nil)
            return nil
        }
        if !userInitiated && release.tag == settings.skippedUpdateVersion {
            return nil
        }
        model.showUpdateAvailable(release)
        if !userInitiated && !mainWindow.isVisible && settings.notifiedUpdateVersion != release.tag {
            settings.notifiedUpdateVersion = release.tag
            settings.save()
            Notifications.shared.show(title: L("轻译 \(release.versionText) 已发布", "QingYi Translator \(release.versionText) is available"),
                                      body: L("点击这里查看更新内容。", "Click to see what’s new.")) { [weak self] in
                self?.showUpdateDialog(release, from: nil)
            }
        }
        return release
    }

    func skipUpdate(_ release: ReleaseInfo) {
        settings.skippedUpdateVersion = release.tag
        settings.save()
        model.showUpdateAvailable(nil)
    }

    /// Swaps in the downloaded version, starts it and exits. Throws if the files can't be replaced.
    func installUpdate(downloaded: URL) throws {
        persistState()
        try SelfUpdater.install(downloaded: downloaded)
        exitApp()
    }

    // ---------------- menu ----------------

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("关于轻译", "About QingYi Translator"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("设置…", "Settings…"), action: #selector(openSettingsAction), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("隐藏轻译", "Hide QingYi Translator"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: L("隐藏其他", "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: L("全部显示", "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("退出轻译", "Quit QingYi Translator"), action: #selector(quitAction), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: L("编辑", "Edit"))
        edit.addItem(withTitle: L("撤销", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L("重做", "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("剪切", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("拷贝", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("粘贴", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("删除", "Delete"), action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: L("全选", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: L("显示", "View"))
        view.addItem(withTitle: L("翻译历史", "History"), action: #selector(toggleHistoryAction), keyEquivalent: "y")
        let glossaryItem = view.addItem(withTitle: L("术语表…", "Glossary…"), action: #selector(openGlossaryAction), keyEquivalent: "g")
        glossaryItem.keyEquivalentModifierMask = [.command, .shift]
        view.addItem(withTitle: L("整体重新翻译", "Retranslate Everything"), action: #selector(retranslateAction), keyEquivalent: "\r")
        view.addItem(withTitle: L("窗口置顶", "Keep on Top"), action: #selector(togglePinAction), keyEquivalent: "")
        viewItem.submenu = view
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L("窗口", "Window"))
        windowMenu.addItem(withTitle: L("最小化", "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L("缩放", "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: L("关闭", "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: L("显示主窗口", "Show Main Window"), action: #selector(showMainWindowAction), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(retranslateAction) || menuItem.action == #selector(toggleHistoryAction) {
            return mainWindow?.isKeyWindow == true
        }
        if menuItem.action == #selector(togglePinAction) {
            menuItem.state = model?.topmost == true ? .on : .off
        }
        return true
    }

    @objc private func openSettingsAction() { openSettings() }
    @objc private func openGlossaryAction() { openGlossary(from: NSApp.keyWindow) }
    @objc private func toggleHistoryAction() { model.toggleHistory() }
    @objc private func retranslateAction() { model.translate(force: true) }
    @objc private func togglePinAction() { model.togglePin() }
    @objc private func showMainWindowAction() { showMainWindow() }
    @objc private func quitAction() { exitApp() }
}
