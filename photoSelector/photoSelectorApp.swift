//
//  photoSelectorApp.swift
//  photoSelector
//
//  Created by 江藤公二 on 2025/12/01.
//

import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var editMenuObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureEditMenu()
        DispatchQueue.main.async { self.configureEditMenu() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.configureEditMenu() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        configureEditMenu()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let alert = NSAlert()
        alert.messageText = "photoSelectorを終了しますか？"
        alert.addButton(withTitle: "終了")
        alert.addButton(withTitle: "キャンセル")
        alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    private func configureEditMenu() {
        guard let editMenu = NSApp.mainMenu?.items.first(where: { $0.title == "Edit" || $0.title == "編集" })?.submenu else {
            return
        }

        if #available(macOS 15.2, *) {
            editMenu.automaticallyInsertsWritingToolsItems = false
        }

        removeUnwantedEditMenuItems(from: editMenu)
        observeEditMenuChanges(editMenu)
    }

    private func observeEditMenuChanges(_ editMenu: NSMenu) {
        if editMenuObserver != nil { return }

        editMenuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didAddItemNotification,
            object: editMenu,
            queue: .main
        ) { [weak self, weak editMenu] _ in
            guard let editMenu else { return }
            self?.removeUnwantedEditMenuItems(from: editMenu)
        }
    }

    private func removeUnwantedEditMenuItems(from editMenu: NSMenu) {
        for index in editMenu.items.indices.reversed() {
            let item = editMenu.items[index]
            if shouldRemoveFromEditMenu(item) {
                editMenu.removeItem(at: index)
            }
        }

        removeExtraSeparators(from: editMenu)
    }

    private func shouldRemoveFromEditMenu(_ item: NSMenuItem) -> Bool {
        if item.isSeparatorItem { return false }

        let title = item.title.lowercased()
        let actionName = item.action.map(NSStringFromSelector)?.lowercased() ?? ""
        let identifier = item.identifier?.rawValue.lowercased() ?? ""
        let searchableText = [title, actionName, identifier].joined(separator: " ")

        return searchableText.contains("作文ツール")
            || searchableText.contains("writing tools")
            || searchableText.contains("writingtools")
            || searchableText.contains("自動入力")
            || searchableText.contains("autofill")
            || searchableText.contains("音声入力")
            || searchableText.contains("dictation")
            || searchableText.contains("絵文字と記号")
            || searchableText.contains("emoji & symbols")
            || searchableText.contains("characterpalette")
    }

    private func removeExtraSeparators(from menu: NSMenu) {
        while menu.items.first?.isSeparatorItem == true {
            menu.removeItem(at: 0)
        }

        while menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.items.count - 1)
        }

        for index in menu.items.indices.dropFirst().reversed() where menu.items[index].isSeparatorItem && menu.items[index - 1].isSeparatorItem {
            menu.removeItem(at: index)
        }
    }
}

private enum AppearanceMode: String {
    case system
    case light
    case dark

    var nsAppearance: NSAppearance? {
        switch self {
        case .system:
            nil
        case .light:
            NSAppearance(named: .aqua)
        case .dark:
            NSAppearance(named: .darkAqua)
        }
    }
}

@main
struct photoSelectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.system.rawValue
    @FocusedValue(\.viewModel) private var viewModel: PhotoSorterViewModel?
    @FocusedValue(\.saveWindowLayoutDefaults) private var saveWindowLayoutDefaults

    init() {
        let tmp = FileManager.default.temporaryDirectory
        if let files = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear { applyAppearanceMode() }
                .onChange(of: appearanceMode) { _, _ in applyAppearanceMode() }
        }
        .commands { appCommands }
    }

    @CommandsBuilder
    private var appCommands: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("photoSelectorについて") {
                showAboutPanel()
            }
        }

        CommandGroup(after: .toolbar) {
            Button("ライトモード") {
                setAppearanceMode(.light)
            }

            Button("ダークモード") {
                setAppearanceMode(.dark)
            }
        }

        CommandGroup(after: .windowArrangement) {
            Button("現在の設定とレイアウトをデフォルトにする") {
                saveWindowLayoutDefaults?()
            }
        }
        CommandMenu("仕分け") {
            Button("採用にする") {
                viewModel?.setStatusForSelection(.groupA)
            }
            .keyboardShortcut("1", modifiers: [.command])
            .disabled(!(viewModel?.hasSelection ?? false))

            Button("没にする") {
                viewModel?.setStatusForSelection(.groupB)
            }
            .keyboardShortcut("2", modifiers: [.command])
            .disabled(!(viewModel?.hasSelection ?? false))

            Divider()

            Button("未分類に戻す") {
                viewModel?.setStatusForSelection(.unknown)
            }
            .keyboardShortcut("0", modifiers: [.command])
            .disabled(!(viewModel?.hasSelection ?? false))

            Divider()

            Button("全選択") {
                viewModel?.selectAllCurrentContext()
            }
            .keyboardShortcut("a", modifiers: [.command])
            .disabled(!(viewModel?.hasSelectableItemsInCurrentContext ?? false))

            Button("選択解除") {
                viewModel?.clearSelection()
            }
            .keyboardShortcut("d", modifiers: [.command])
            .disabled(!(viewModel?.hasSelection ?? false))
        }
    }

    private func setAppearanceMode(_ mode: AppearanceMode) {
        appearanceMode = mode.rawValue
        applyAppearanceMode()
    }

    private func applyAppearanceMode() {
        guard let mode = AppearanceMode(rawValue: appearanceMode) else {
            NSApp.appearance = nil
            return
        }

        NSApp.appearance = mode.nsAppearance
    }

    // Standard About panel has no URL field of its own, so the project link
    // is passed through the credits area as a clickable link.
    private func showAboutPanel() {
        let urlString = "https://github.com/etokoji/photoselector"
        let credits = NSMutableAttributedString(
            string: urlString,
            attributes: [
                .link: URL(string: urlString)!,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            ]
        )
        credits.setAlignment(.center, range: NSRange(location: 0, length: credits.length))

        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits
        ])
    }
}
