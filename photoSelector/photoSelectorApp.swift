//
//  photoSelectorApp.swift
//  photoSelector
//
//  Created by 江藤公二 on 2025/12/01.
//

import SwiftUI

@main
struct photoSelectorApp: App {
    @StateObject private var viewModel = PhotoSorterViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
        }
        .commands {
            CommandMenu("仕分け") {
                Button("採用にする") {
                    viewModel.setStatusForSelection(.groupA)
                }
                .keyboardShortcut("1", modifiers: [.command])
                .disabled(!viewModel.hasSelection)

                Button("没にする") {
                    viewModel.setStatusForSelection(.groupB)
                }
                .keyboardShortcut("2", modifiers: [.command])
                .disabled(!viewModel.hasSelection)

                Divider()

                Button("未分類に戻す") {
                    viewModel.setStatusForSelection(.unknown)
                }
                .keyboardShortcut("0", modifiers: [.command])
                .disabled(!viewModel.hasSelection)
                
                Divider()
                
                Button("全選択") {
                    viewModel.selectAllCurrentContext()
                }
                .keyboardShortcut("a", modifiers: [.command])
                .disabled(!viewModel.hasSelectableItemsInCurrentContext)
            }
        }
    }
}
