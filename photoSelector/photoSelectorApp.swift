//
//  photoSelectorApp.swift
//  photoSelector
//
//  Created by 江藤公二 on 2025/12/01.
//

import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let alert = NSAlert()
        alert.messageText = "photoSelectorを終了しますか？"
        alert.addButton(withTitle: "終了")
        alert.addButton(withTitle: "キャンセル")
        alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
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
    @FocusedObject private var viewModel: PhotoSorterViewModel?
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
}
