//
//  WindowLayoutDefaults.swift
//  photoSelector
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

extension Notification.Name {
    static let forcePersistSplitPositions = Notification.Name("ForcePersistSplitPositions")
}

struct WindowLayoutSettings: Equatable {
    var folderPanelsAreVertical: Bool
    var thumbnailSize: Double
    var sortMode: DateSortMode
    var windowWidth: CGFloat?
    var windowHeight: CGFloat?
    
    var windowSize: CGSize? {
        guard let windowWidth, let windowHeight, windowWidth > 0, windowHeight > 0 else { return nil }
        return CGSize(width: windowWidth, height: windowHeight)
    }
}

enum WindowLayoutDefaults {
    static let hasSavedKey = "DefaultLayout_HasSaved"
    private static let prefix = "DefaultLayout"
    
    static let splitSuffixes = [
        "MainSplitPosition",
        "LeftPanelVerticalSplitPosition",
        "ContentSplitPosition",
        "FolderPanelsVerticalSplitPosition",
        "FolderPanelsSplitPosition",
        "KeepDiscardSplitPosition",
        "RightPanelVerticalSplitPosition"
    ]
    
    static func splitKey(windowID: String, suffix: String) -> String {
        "\(windowID)_\(suffix)"
    }
    
    static func defaultSplitKey(suffix: String) -> String {
        "\(prefix)_\(suffix)"
    }
    
    static func suffix(fromSplitKey key: String) -> String? {
        splitSuffixes.first { key.hasSuffix("_\($0)") }
    }
    
    static func resolvedSplitPosition(forKey key: String) -> CGFloat? {
        let defaults = UserDefaults.standard
        if let value = defaults.object(forKey: key) as? CGFloat, value > 0 {
            return value
        }
        guard let suffix = suffix(fromSplitKey: key) else { return nil }
        if let value = defaults.object(forKey: defaultSplitKey(suffix: suffix)) as? CGFloat, value > 0 {
            return value
        }
        return nil
    }
    
    static func saveCurrentLayout(
        windowID: String,
        folderPanelsAreVertical: Bool,
        thumbnailSize: Double,
        sortMode: DateSortMode,
        windowSize: CGSize? = nil
    ) {
        NotificationCenter.default.post(name: .forcePersistSplitPositions, object: nil)
        
        DispatchQueue.main.async {
            persist(windowID: windowID,
                    folderPanelsAreVertical: folderPanelsAreVertical,
                    thumbnailSize: thumbnailSize,
                    sortMode: sortMode,
                    windowSize: windowSize)
        }
    }
    
    private static func persist(
        windowID: String,
        folderPanelsAreVertical: Bool,
        thumbnailSize: Double,
        sortMode: DateSortMode,
        windowSize: CGSize?
    ) {
        let defaults = UserDefaults.standard
        
        for suffix in splitSuffixes {
            let sourceKey = splitKey(windowID: windowID, suffix: suffix)
            if let value = defaults.object(forKey: sourceKey) {
                defaults.set(value, forKey: defaultSplitKey(suffix: suffix))
            }
        }
        
        defaults.set(folderPanelsAreVertical, forKey: "\(prefix)_FolderPanelsAreVertical")
        defaults.set(thumbnailSize, forKey: "\(prefix)_ThumbnailSize")
        defaults.set(sortMode.rawValue, forKey: "\(prefix)_DateSortMode")
        if let windowSize, windowSize.width > 0, windowSize.height > 0 {
            defaults.set(Double(windowSize.width), forKey: "\(prefix)_WindowWidth")
            defaults.set(Double(windowSize.height), forKey: "\(prefix)_WindowHeight")
        }
        defaults.set(true, forKey: hasSavedKey)
    }
    
    static func applyLayout(to windowID: String) -> WindowLayoutSettings? {
        guard UserDefaults.standard.bool(forKey: hasSavedKey) else { return nil }
        
        let defaults = UserDefaults.standard
        
        for suffix in splitSuffixes {
            let defaultKey = defaultSplitKey(suffix: suffix)
            if let value = defaults.object(forKey: defaultKey) {
                defaults.set(value, forKey: splitKey(windowID: windowID, suffix: suffix))
            }
        }
        
        let folderPanelsAreVertical = defaults.bool(forKey: "\(prefix)_FolderPanelsAreVertical")
        let thumbnailSize = defaults.double(forKey: "\(prefix)_ThumbnailSize")
        let sortModeRaw = defaults.string(forKey: "\(prefix)_DateSortMode") ?? DateSortMode.fileCreation.rawValue
        let sortMode = DateSortMode(rawValue: sortModeRaw) ?? .fileCreation
        let windowWidth = defaults.double(forKey: "\(prefix)_WindowWidth")
        let windowHeight = defaults.double(forKey: "\(prefix)_WindowHeight")
        
        return WindowLayoutSettings(
            folderPanelsAreVertical: folderPanelsAreVertical,
            thumbnailSize: thumbnailSize > 0 ? thumbnailSize : 150,
            sortMode: sortMode,
            windowWidth: windowWidth > 0 ? windowWidth : nil,
            windowHeight: windowHeight > 0 ? windowHeight : nil
        )
    }
    
    static var defaultWindowSize: CGSize? {
        guard UserDefaults.standard.bool(forKey: hasSavedKey) else { return nil }
        let width = UserDefaults.standard.double(forKey: "\(prefix)_WindowWidth")
        let height = UserDefaults.standard.double(forKey: "\(prefix)_WindowHeight")
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
    
#if os(macOS)
    static func mainWindowContentSize(from window: NSWindow?) -> CGSize? {
        guard let window else { return nil }
        let size = window.contentLayoutRect.size
        guard size.width > 0, size.height > 0 else { return nil }
        return size
    }
#endif
}

private struct SaveWindowLayoutDefaultsKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var saveWindowLayoutDefaults: (() -> Void)? {
        get { self[SaveWindowLayoutDefaultsKey.self] }
        set { self[SaveWindowLayoutDefaultsKey.self] = newValue }
    }
}
