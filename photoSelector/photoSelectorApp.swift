//
//  photoSelectorApp.swift
//  photoSelector
//
//  Created by 江藤公二 on 2025/12/01.
//

import SwiftUI

@main
struct photoSelectorApp: App {
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
        }
        .commands { appCommands }
    }
    
    @CommandsBuilder
    private var appCommands: some Commands {
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
}
