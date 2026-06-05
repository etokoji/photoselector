//
//  PhotoSorterViewModel.swift
//  photoSelector
//
//  Created by Antigravity on 2025/12/01.
//

import SwiftUI
import Combine
import ImageIO
#if os(macOS)
import AppKit
#endif

// MARK: - Thumbnail Generator
class ThumbnailGenerator {
    static let shared = ThumbnailGenerator()
    
    private class CacheKey: NSObject {
        let url: URL
        let size: CGFloat

        init(url: URL, size: CGFloat) {
            self.url = url
            self.size = size
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? CacheKey else { return false }
            return url == other.url && size == other.size
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(url)
            hasher.combine(size)
            return hasher.finalize()
        }
    }
    
    private let cache = NSCache<CacheKey, NSImage>()
    private let queue = DispatchQueue(label: "dev.etokoji.thumbnailgenerator", qos: .userInitiated)

    private init() {}

    func thumbnail(for url: URL, size: CGFloat, completion: @escaping (NSImage?) -> Void) {
        let cacheKey = CacheKey(url: url, size: size)
        if let cachedImage = cache.object(forKey: cacheKey) {
            completion(cachedImage)
            return
        }

        queue.async {
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: size * 2 // Use 2x for Retina displays
            ]

            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let nsImage = NSImage(cgImage: cgImage, size: .zero)
            self.cache.setObject(nsImage, forKey: cacheKey)
            
            DispatchQueue.main.async {
                completion(nsImage)
            }
        }
    }
}


enum SelectionContext {
    case grid
    case keep
    case discard
}

enum DateSortMode: String, CaseIterable, Identifiable {
    case fileCreation = "file"
    case exifPreferred = "exif"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fileCreation: return "File"
        case .exifPreferred: return "EXIF"
        }
    }
}

enum FolderPanelKind: Equatable {
    case primary
    case secondary
}

class PhotoSorterViewModel: ObservableObject {
    @Published var photos: [PhotoItem] = []
    @Published var sortMode: DateSortMode = .fileCreation
    @Published var currentFolder: URL?
    @Published var isProcessing: Bool = false
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var thumbnailSize: Double = 150
    // Selection
    // - primarySelectedPhotoID: the focused item used for preview + keyboard actions
    // - selectedPhotoIDs: supports multi-selection via mouse (cmd/shift)
    @Published var primarySelectedPhotoID: UUID? = nil
    @Published var selectedPhotoIDs: Set<UUID> = []
    private var selectionAnchorPhotoID: UUID? = nil
    @Published var selectionContext: SelectionContext = .grid
    
    // For Folder Tree
    @Published var folderTree: [FileSystemItem] = []
    @Published var selectedFolderURL: URL?
    private var folderTreeRootURL: URL?
    @Published var secondaryFolderTree: [FileSystemItem] = []
    @Published var secondarySelectedFolderURL: URL?
    private var secondaryFolderTreeRootURL: URL?
    @Published var activeFolderPanel: FolderPanelKind?
    @Published var targetedFolderURL: URL?
    @Published var primaryExpandedFolderURLs: Set<URL> = []
    @Published var secondaryExpandedFolderURLs: Set<URL> = []
    
    // Column counts for keyboard navigation
    @Published var groupAColumns: Int = 2
    @Published var groupBColumns: Int = 2
    
    func applyWindowLayoutSettings(_ settings: WindowLayoutSettings) {
        thumbnailSize = settings.thumbnailSize
        sortMode = settings.sortMode
        resortPhotos()
    }
    
    
    // Scan the root folder and build the folder tree
    func buildFolderTree(from rootURL: URL, in panel: FolderPanelKind = .primary, resetSelection: Bool = true) {
        let fileManager = FileManager.default
        var items: [FileSystemItem] = []
        let previousRootURL: URL?
        let otherPanelRootURL: URL?
        switch panel {
        case .primary:
            previousRootURL = folderTreeRootURL?.standardizedFileURL
            otherPanelRootURL = secondaryFolderTreeRootURL?.standardizedFileURL
        case .secondary:
            previousRootURL = secondaryFolderTreeRootURL?.standardizedFileURL
            otherPanelRootURL = folderTreeRootURL?.standardizedFileURL
        }
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .nameKey], options: .skipsHiddenFiles)
            
            for url in contents {
                let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
                let isDirectory = resourceValues.isDirectory ?? false
                let name = resourceValues.name ?? url.lastPathComponent
                
                if isDirectory {
                    let children = buildSubTree(from: url)
                    items.append(FileSystemItem(id: url, name: name, children: children, isFolder: true))
                }
            }
        } catch {
            self.errorMessage = "Failed to scan folder: \(error.localizedDescription)"
            self.showError = true
        }
        
        // Sort children by localized name
        items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Add the root folder itself at the top
        let tree = [FileSystemItem(id: rootURL, name: rootURL.lastPathComponent, children: items, isFolder: true)]
        
        // Initially select the root folder or keep current selection based on flag
        let normalizedRoot = rootURL.standardizedFileURL
        switch panel {
        case .primary:
            folderTreeRootURL = rootURL
            folderTree = tree
            if selectedFolderURL == nil || resetSelection {
                selectedFolderURL = rootURL
            }
            if resetSelection {
                primaryExpandedFolderURLs = [normalizedRoot]
            } else if primaryExpandedFolderURLs.isEmpty {
                primaryExpandedFolderURLs = [normalizedRoot]
            }
        case .secondary:
            secondaryFolderTreeRootURL = rootURL
            secondaryFolderTree = tree
            if secondarySelectedFolderURL == nil || resetSelection {
                secondarySelectedFolderURL = rootURL
            }
            if resetSelection {
                secondaryExpandedFolderURLs = [normalizedRoot]
            } else if secondaryExpandedFolderURLs.isEmpty {
                secondaryExpandedFolderURLs = [normalizedRoot]
            }
        }
        if resetSelection {
            activeFolderPanel = panel
        }
        if resetSelection,
           let previousRootURL,
           previousRootURL != normalizedRoot {
            prunePhotosAfterTopFolderChange(removedRoot: previousRootURL,
                                            preservedRoots: [normalizedRoot, otherPanelRootURL].compactMap { $0 })
        }
        if let selected = selectedFolderURL(for: panel) {
            expandAncestors(of: selected, in: panel)
        }
    }

    func refreshFolderTree(for panel: FolderPanelKind = .primary) {
        switch panel {
        case .primary:
            guard let root = folderTreeRootURL else { return }
            buildFolderTree(from: root, in: .primary, resetSelection: false)
        case .secondary:
            guard let root = secondaryFolderTreeRootURL else { return }
            buildFolderTree(from: root, in: .secondary, resetSelection: false)
        }
    }
    
    func refreshAllFolderTrees() {
        refreshFolderTree(for: .primary)
        refreshFolderTree(for: .secondary)
    }
#if os(macOS)
    var rootFolderURL: URL? {
        folderTreeRootURL?.standardizedFileURL
    }
    
    func rootFolderURL(for panel: FolderPanelKind) -> URL? {
        switch panel {
        case .primary:
            return folderTreeRootURL?.standardizedFileURL
        case .secondary:
            return secondaryFolderTreeRootURL?.standardizedFileURL
        }
    }
    
    func rootFolderDisplayName(for panel: FolderPanelKind) -> String? {
        guard let root = rootFolderURL(for: panel) else { return nil }
        let fm = FileManager.default
        if let values = try? root.resourceValues(forKeys: [.volumeNameKey]),
           let volumeName = values.volumeName,
           !volumeName.isEmpty {
            return volumeName
        }
        let displayName = fm.displayName(atPath: root.path)
        return displayName.isEmpty ? root.lastPathComponent : displayName
    }
    
    var windowTitle: String {
        let primary = rootFolderTitleName(for: .primary).map { "[\($0)]" }
        let secondary = rootFolderTitleName(for: .secondary).map { "[\($0)]" }
        let parts = [primary, secondary].compactMap { $0 }
        if parts.isEmpty {
            return "photoSelector"
        }
        return parts.joined(separator: "-")
    }
    
    private func rootFolderTitleName(for panel: FolderPanelKind) -> String? {
        guard let root = rootFolderURL(for: panel) else { return nil }
        let displayName = FileManager.default.displayName(atPath: root.path)
        return displayName.isEmpty ? root.lastPathComponent : displayName
    }
    
    func selectedFolderURL(for panel: FolderPanelKind) -> URL? {
        switch panel {
        case .primary:
            return selectedFolderURL
        case .secondary:
            return secondarySelectedFolderURL
        }
    }
    
    func setSelectedFolderURL(_ url: URL, for panel: FolderPanelKind) {
        switch panel {
        case .primary:
            selectedFolderURL = url
        case .secondary:
            secondarySelectedFolderURL = url
        }
        activeFolderPanel = panel
        expandAncestors(of: url, in: panel)
    }
    
    func expandedFolderURLs(for panel: FolderPanelKind) -> Set<URL> {
        switch panel {
        case .primary:
            return primaryExpandedFolderURLs
        case .secondary:
            return secondaryExpandedFolderURLs
        }
    }
    
    func isFolderExpanded(_ url: URL, in panel: FolderPanelKind) -> Bool {
        expandedFolderURLs(for: panel).contains(url.standardizedFileURL)
    }
    
    func setFolderExpanded(_ url: URL, expanded: Bool, in panel: FolderPanelKind) {
        let normalized = url.standardizedFileURL
        switch panel {
        case .primary:
            if expanded {
                primaryExpandedFolderURLs.insert(normalized)
            } else {
                primaryExpandedFolderURLs.remove(normalized)
            }
        case .secondary:
            if expanded {
                secondaryExpandedFolderURLs.insert(normalized)
            } else {
                secondaryExpandedFolderURLs.remove(normalized)
            }
        }
    }
    
    func expandAncestors(of url: URL, in panel: FolderPanelKind) {
        guard let root = rootFolderURL(for: panel)?.standardizedFileURL else { return }
        let normalized = url.standardizedFileURL
        var urls = expandedFolderURLs(for: panel)
        urls.insert(root)
        var current = normalized.deletingLastPathComponent().standardizedFileURL
        while current.path.hasPrefix(root.path), current != root {
            urls.insert(current)
            current = current.deletingLastPathComponent().standardizedFileURL
        }
        switch panel {
        case .primary:
            primaryExpandedFolderURLs = urls
        case .secondary:
            secondaryExpandedFolderURLs = urls
        }
    }
    
    func shouldShowEjectVolumeButton(for panel: FolderPanelKind, item: FileSystemItem) -> Bool {
        guard let root = rootFolderURL(for: panel) else { return false }
        guard root == item.id.standardizedFileURL else { return false }
        return Self.ejectableVolumeMountURL(containing: root) != nil
    }
    
    func ejectVolumeForFolderPanel(_ panel: FolderPanelKind) {
        guard let root = rootFolderURL(for: panel) else { return }
        guard let volumeURL = Self.ejectableVolumeMountURL(containing: root) else {
            errorMessage = "このフォルダは取り外し可能なボリューム上にありません。"
            showError = true
            return
        }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volumeURL)
            clearFolderPanelAfterEject(for: panel)
        } catch {
            errorMessage = "ボリュームの取り外しに失敗しました: \(error.localizedDescription)"
            showError = true
        }
    }
    
    private func clearFolderPanelAfterEject(for panel: FolderPanelKind) {
        let wasActive = (activeFolderPanel == panel)
        
        switch panel {
        case .primary:
            folderTree = []
            folderTreeRootURL = nil
            selectedFolderURL = nil
            primaryExpandedFolderURLs = []
        case .secondary:
            secondaryFolderTree = []
            secondaryFolderTreeRootURL = nil
            secondarySelectedFolderURL = nil
            secondaryExpandedFolderURLs = []
        }
        
        guard wasActive else { return }
        
        let other: FolderPanelKind = (panel == .primary) ? .secondary : .primary
        if rootFolderURL(for: other) != nil, let selected = selectedFolderURL(for: other) {
            activeFolderPanel = other
            loadPhotos(from: selected)
        } else {
            activeFolderPanel = nil
            photos = []
            currentFolder = nil
            clearSelection(deferred: false)
        }
    }
    
    private static func ejectableVolumeMountURL(containing folderURL: URL) -> URL? {
        let keys: Set<URLResourceKey> = [.volumeURLKey, .volumeIsRemovableKey, .volumeIsEjectableKey]
        guard let values = try? folderURL.resourceValues(forKeys: keys) else { return nil }
        let ejectable = (values.volumeIsRemovable == true) || (values.volumeIsEjectable == true)
        guard ejectable else { return nil }
        return values.volume?.standardizedFileURL ?? folderURL.standardizedFileURL
    }
#endif
    
    private func buildSubTree(from folderURL: URL) -> [FileSystemItem]? {
        let fileManager = FileManager.default
        var children: [FileSystemItem] = []
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey, .nameKey], options: .skipsHiddenFiles)
            
            for url in contents {
                let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
                if let isDirectory = resourceValues.isDirectory, isDirectory {
                    let name = resourceValues.name ?? url.lastPathComponent
                    let subChildren = buildSubTree(from: url)
                    children.append(FileSystemItem(id: url, name: name, children: subChildren, isFolder: true))
                }
            }
        } catch {
            // Silently ignore errors for subfolders, or handle as needed
        }
        
        if !children.isEmpty {
            let sorted = children.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return sorted
        }
        return nil
    }
    
    private func prunePhotosAfterTopFolderChange(removedRoot: URL, preservedRoots: [URL]) {
        func isUnder(_ url: URL, root: URL) -> Bool {
            let normalizedURL = url.standardizedFileURL
            let normalizedRoot = root.standardizedFileURL
            let path = normalizedURL.path
            let rootPath = normalizedRoot.path
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
        
        let previousPrimaryID = primarySelectedPhotoID
        let previousSelectedIDs = selectedPhotoIDs
        
        photos.removeAll { photo in
            guard isUnder(photo.url, root: removedRoot) else { return false }
            return !preservedRoots.contains(where: { isUnder(photo.url, root: $0) })
        }
        
        if let currentFolder,
           isUnder(currentFolder, root: removedRoot),
           !preservedRoots.contains(where: { isUnder(currentFolder, root: $0) }) {
            self.currentFolder = nil
        }
        
        reconcileSelectionAfterPhotoUpdate(previousPrimaryID: previousPrimaryID,
                                           previousSelectedIDs: previousSelectedIDs)
    }
    
    // Load photos from a selected folder
    func loadPhotos(from folderURL: URL) {
        let normalizedFolderURL = folderURL.standardizedFileURL
        let previousCurrentFolder = self.currentFolder?.standardizedFileURL
        self.currentFolder = normalizedFolderURL
        
        let fileManager = FileManager.default
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: normalizedFolderURL,
                                                               includingPropertiesForKeys: [.creationDateKey],
                                                               options: options)
            
            let imageExtensions = ["jpg", "jpeg", "png", "heic", "gif", "tiff"]
            
            let imageFiles = fileURLs.filter { url in
                imageExtensions.contains(url.pathExtension.lowercased())
            }
            
            // Sort URLs first to avoid EXIF unless requested
            let sortedURLs: [URL]
            switch sortMode {
            case .fileCreation:
                sortedURLs = imageFiles.sorted { a, b in
                    let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantFuture
                    let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantFuture
                    return (da, a.standardizedFileURL.path) < (db, b.standardizedFileURL.path)
                }
            case .exifPreferred:
                sortedURLs = imageFiles.sorted { a, b in
                    // Slow path: check EXIF first, fallback to file creation
                    func exifDate(_ url: URL) -> Date? {
                        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
                        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
                           let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                            let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; if let d = f.date(from: s) { return d }
                        }
                        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
                           let s = tiff[kCGImagePropertyTIFFDateTime] as? String {
                            let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; if let d = f.date(from: s) { return d }
                        }
                        return nil
                    }
                    let da = exifDate(a) ?? ((try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantFuture)
                    let db = exifDate(b) ?? ((try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantFuture)
                    return (da, a.standardizedFileURL.path) < (db, b.standardizedFileURL.path)
                }
            }
            
            let items = sortedURLs.map { PhotoItem(url: $0) }
            
            DispatchQueue.main.async {
                let previousPrimaryID = self.primarySelectedPhotoID
                let previousSelectedIDs = self.selectedPhotoIDs
                let existingByURL = Dictionary(uniqueKeysWithValues: self.photos.map { ($0.url.standardizedFileURL, $0) })
                
                let retainedPhotos = self.photos.filter { existing in
                    existing.url.deletingLastPathComponent().standardizedFileURL != normalizedFolderURL
                }
                let updatedFolderPhotos = items.map { item -> PhotoItem in
                    let key = item.url.standardizedFileURL
                    return existingByURL[key] ?? item
                }
                
                self.photos = retainedPhotos + updatedFolderPhotos
                
                let didSwitchFolder = previousCurrentFolder != normalizedFolderURL
                if didSwitchFolder {
                    if let firstPhotoInSelectedFolder = self.currentFolderPhotos.first?.id {
                        self.selectSingle(firstPhotoInSelectedFolder, deferred: false)
                    } else {
                        self.clearSelection(deferred: false)
                    }
                    self.selectionContext = .grid
                } else {
                    self.reconcileSelectionAfterPhotoUpdate(previousPrimaryID: previousPrimaryID,
                                                            previousSelectedIDs: previousSelectedIDs)
                }
            }
        } catch {
            self.errorMessage = "Failed to load photos: \(error.localizedDescription)"
            self.showError = true
        }
    }
    
    private func sortedPhotos(_ photos: [PhotoItem]) -> [PhotoItem] {
        photos.sorted { a, b in
            let da: Date
            let db: Date
            switch sortMode {
            case .fileCreation:
                da = a.fileCreationDate ?? .distantFuture
                db = b.fileCreationDate ?? .distantFuture
            case .exifPreferred:
                da = (a.exifCreationDate ?? a.fileCreationDate) ?? .distantFuture
                db = (b.exifCreationDate ?? b.fileCreationDate) ?? .distantFuture
            }
            return (da, a.url.standardizedFileURL.path) < (db, b.url.standardizedFileURL.path)
        }
    }
    
    private func reconcileSelectionAfterPhotoUpdate(previousPrimaryID: UUID?,
                                                    previousSelectedIDs: Set<UUID>) {
        let contextIDs = selectableIDs(for: selectionContext)
        let validContextIDs = Set(contextIDs)
        var retainedSelection = previousSelectedIDs.intersection(validContextIDs)
        
        if let previousPrimaryID, validContextIDs.contains(previousPrimaryID) {
            if retainedSelection.isEmpty {
                retainedSelection = [previousPrimaryID]
            }
            primarySelectedPhotoID = previousPrimaryID
            selectedPhotoIDs = retainedSelection
            if let anchor = selectionAnchorPhotoID, validContextIDs.contains(anchor) {
                selectionAnchorPhotoID = anchor
            } else {
                selectionAnchorPhotoID = previousPrimaryID
            }
            return
        }
        
        if let fallbackSelection = retainedSelection.first {
            primarySelectedPhotoID = fallbackSelection
            selectedPhotoIDs = retainedSelection
            selectionAnchorPhotoID = fallbackSelection
            return
        }
        
        if let firstContextID = contextIDs.first {
            selectSingle(firstContextID, deferred: false)
        } else {
            clearSelection(deferred: false)
            selectionContext = .grid
        }
    }
    
    // Toggle status or set specific status
    func toggleStatus(for item: PhotoItem) {
        if let index = photos.firstIndex(where: { $0.id == item.id }) {
            let nextStatus: PhotoStatus
            switch photos[index].status {
            case .unknown:
                nextStatus = .groupA
            case .groupA:
                nextStatus = .groupB
            case .groupB:
                nextStatus = .unknown
            }
            setStatus(for: item, status: nextStatus)
        }
    }
    
    func setStatus(for item: PhotoItem, status: PhotoStatus) {
        if let index = photos.firstIndex(where: { $0.id == item.id }) {
            // Check if we need to advance selection before changing status
            // Only if we are in a filtered context (Keep or Discard) and the item will disappear from view
            let isCurrentSelection = (primarySelectedPhotoID == item.id)
            let willDisappear: Bool
            switch selectionContext {
            case .keep:
                willDisappear = (photos[index].status == .groupA && status != .groupA)
            case .discard:
                willDisappear = (photos[index].status == .groupB && status != .groupB)
            case .grid:
                willDisappear = false
            }
            
            if isCurrentSelection && willDisappear {
                // Find next item in current context
                let currentIDs = selectableIDs(for: selectionContext)
                if let currentIndexInContext = currentIDs.firstIndex(of: item.id) {
                    let nextIndex = currentIndexInContext + 1
                    if nextIndex < currentIDs.count {
                        selectSingle(currentIDs[nextIndex])
                    } else {
                        // Was last item, clear selection
                        clearSelection()
                    }
                }
            }
            
            photos[index].status = status
        }
    }

    // MARK: - Bulk status actions (for context menu / menu bar)

    var hasSelection: Bool {
        !selectedPhotoIDs.isEmpty
    }

    var selectionCount: Int {
        selectedPhotoIDs.count
    }

    func setStatusForSelection(_ status: PhotoStatus) {
        guard !selectedPhotoIDs.isEmpty else { return }
        
        // Handle selection advancement for primary item if needed
        // Only if single selection to match simple behavior, or we could just clear selection after bulk move
        // For bulk operations, typically we might want to select the next item after the *range* that was moved.
        // Let's implement simple behavior: if items are removed from current view, select the next available one.
        
        let currentContextIDs = selectableIDs(for: selectionContext)
        // Check if any selected item will disappear from current view
        let disappearingIDs = selectedPhotoIDs.filter { id in
            guard let item = photos.first(where: { $0.id == id }) else { return false }
            switch selectionContext {
            case .keep: return item.status == .groupA && status != .groupA
            case .discard: return item.status == .groupB && status != .groupB
            case .grid: return false
            }
        }
        
        var nextSelectionID: UUID? = nil
        
        if !disappearingIDs.isEmpty {
            // Find the first item in the current context that is NOT in the selection (and thus not moving)
            // starting from the position of the primary selection or the first selected item
            if let anchorID = primarySelectedPhotoID ?? selectedPhotoIDs.first,
               let anchorIndex = currentContextIDs.firstIndex(of: anchorID) {
                
                // Scan forward from anchor
                for i in (anchorIndex + 1)..<currentContextIDs.count {
                    if !selectedPhotoIDs.contains(currentContextIDs[i]) {
                        nextSelectionID = currentContextIDs[i]
                        break
                    }
                }
                
                // If not found forward, try to find one? Or just clear?
                // Request says "select next image". If last, "unselect".
            }
        }

        // Update statuses
        for i in 0..<photos.count {
            if selectedPhotoIDs.contains(photos[i].id) {
                photos[i].status = status
            }
        }
        
        // Apply new selection if needed
        if !disappearingIDs.isEmpty {
            if let nextID = nextSelectionID {
                selectSingle(nextID)
            } else {
                clearSelection(deferred: false)
            }
        }
    }
    
    // Clear all selections (reset to unknown)
    func clearAllSelections() {
        for i in 0..<photos.count {
            photos[i].status = .unknown
        }
    }
    
    // MARK: - Selection (mouse)

    /// Apply selection based on a click in a specific pane order.
    /// - Parameters:
    ///   - id: clicked photo id
    ///   - orderedIDs: the visual order of items in the pane where the click happened
    ///   - isCommandPressed: toggles selection (multi-select)
    ///   - isShiftPressed: selects a range from anchor to clicked id
    func applySelectionClick(id: UUID,
                             orderedIDs: [UUID],
                             isCommandPressed: Bool,
                             isShiftPressed: Bool,
                             context: SelectionContext) {
        if isShiftPressed {
            let anchor = selectionAnchorPhotoID ?? primarySelectedPhotoID ?? id
            guard let a = orderedIDs.firstIndex(of: anchor),
                  let b = orderedIDs.firstIndex(of: id) else {
                // Fallback: just select the clicked item (deferred)
                selectSingle(id, deferred: true)
                return
            }
            let range = a <= b ? a...b : b...a
            // Combine publishes and delay slightly beyond current update cycle
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) {
                self.selectionContext = context
                self.selectedPhotoIDs = Set(orderedIDs[range])
                self.primarySelectedPhotoID = id
                self.selectionAnchorPhotoID = anchor
            }
            return
        }
        if isCommandPressed {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) {
                self.selectionContext = context
                if self.selectedPhotoIDs.contains(id) {
                    self.selectedPhotoIDs.remove(id)
                    if self.primarySelectedPhotoID == id {
                        self.primarySelectedPhotoID = self.selectedPhotoIDs.first
                    }
                } else {
                    self.selectedPhotoIDs.insert(id)
                    self.primarySelectedPhotoID = id
                }
                self.selectionAnchorPhotoID = self.primarySelectedPhotoID
            }
            return
        }

        // Normal click: single selection — group into one deferred block
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) {
            self.selectionContext = context
            self.selectSingle(id, deferred: false)
        }
    }

    /// Clear current selection (does not change photo statuses).
    func clearSelection(deferred: Bool = false) {
        let apply = {
            self.primarySelectedPhotoID = nil
            self.selectedPhotoIDs = []
            self.selectionAnchorPhotoID = nil
        }
        if deferred {
            DispatchQueue.main.async(execute: apply)
        } else {
            apply()
        }
    }

    func selectAll(in context: SelectionContext, deferred: Bool = false) {
        let ids = selectableIDs(for: context)
        guard !ids.isEmpty else { return }
        let apply = {
            self.selectionContext = context
            self.primarySelectedPhotoID = ids.first
            self.selectedPhotoIDs = Set(ids)
            self.selectionAnchorPhotoID = ids.first
        }
        if deferred {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1), execute: apply)
        } else {
            apply()
        }
    }

    func selectAllCurrentContext(deferred: Bool = false) {
        selectAll(in: selectionContext, deferred: deferred)
    }
#if os(macOS)
    func createSubfolder(at parentURL: URL, named name: String, in panel: FolderPanelKind = .primary) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalizedParent = parentURL.standardizedFileURL
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let newURL = normalizedParent.appendingPathComponent(trimmed)
            if fm.fileExists(atPath: newURL.path) {
                DispatchQueue.main.async {
                    self.presentError("同名のフォルダが既に存在します。")
                }
                return
            }
            do {
                try fm.createDirectory(at: newURL, withIntermediateDirectories: false, attributes: nil)
                DispatchQueue.main.async {
                    self.setFolderExpanded(normalizedParent, expanded: true, in: panel)
                    self.setSelectedFolderURL(newURL, for: panel)
                    self.refreshFolderTree(for: panel)
                }
            } catch {
                DispatchQueue.main.async {
                    self.presentError("フォルダを作成できませんでした: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func renameFolder(at folderURL: URL, to newName: String, in panel: FolderPanelKind = .primary) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalizedURL = folderURL.standardizedFileURL
        if let root = rootFolderURL(for: panel), root == normalizedURL {
            presentError("ルートフォルダの名前は変更できません。")
            return
        }
        let destinationURL = normalizedURL.deletingLastPathComponent().appendingPathComponent(trimmed)
        guard destinationURL != normalizedURL else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            if fm.fileExists(atPath: destinationURL.path) {
                DispatchQueue.main.async {
                    self.presentError("同名のフォルダが既に存在します。")
                }
                return
            }
            do {
                try fm.moveItem(at: normalizedURL, to: destinationURL)
                DispatchQueue.main.async {
                    self.remapExpandedFolderURLs(from: normalizedURL, to: destinationURL, in: .primary)
                    self.remapExpandedFolderURLs(from: normalizedURL, to: destinationURL, in: .secondary)
                    if self.selectedFolderURL(for: panel)?.standardizedFileURL == normalizedURL {
                        self.setSelectedFolderURL(destinationURL, for: panel)
                    }
                    if self.currentFolder?.standardizedFileURL == normalizedURL {
                        self.currentFolder = destinationURL
                    }
                    self.refreshAllFolderTrees()
                }
            } catch {
                DispatchQueue.main.async {
                    self.presentError("フォルダ名を変更できませんでした: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func trashFolder(at folderURL: URL, in panel: FolderPanelKind = .primary) {
        let normalizedURL = folderURL.standardizedFileURL
        if let root = rootFolderURL(for: panel), root == normalizedURL {
            presentError("ルートフォルダは削除できません。")
            return
        }
        let parentURL = normalizedURL.deletingLastPathComponent()
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            do {
                if self.shouldMoveToPendingDeletionInsteadOfTrash(normalizedURL) {
                    try self.moveItemToPendingDeletion(normalizedURL, fileManager: fm)
                } else {
                    try fm.trashItem(at: normalizedURL, resultingItemURL: nil)
                }
                DispatchQueue.main.async {
                    self.handleFolderRemoved(normalizedURL, fallbackSelection: parentURL, panel: panel)
                }
            } catch let trashError {
                do {
                    try self.moveItemToPendingDeletion(normalizedURL, fileManager: fm)
                    DispatchQueue.main.async {
                        self.handleFolderRemoved(normalizedURL, fallbackSelection: parentURL, panel: panel)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.presentError("フォルダを削除予定へ移動できませんでした: \(error.localizedDescription)\n元のエラー: \(trashError.localizedDescription)")
                    }
                }
            }
        }
    }
    
    private func pendingDeletionFolder(in parentURL: URL, deleting folderURL: URL) -> URL {
        let defaultURL = parentURL.appendingPathComponent("削除予定", isDirectory: true)
        if defaultURL.standardizedFileURL != folderURL.standardizedFileURL {
            return defaultURL
        }
        return parentURL.appendingPathComponent("削除予定_退避", isDirectory: true)
    }

    private func moveItemToPendingDeletion(_ sourceURL: URL, fileManager fm: FileManager) throws {
        let parentURL = sourceURL.deletingLastPathComponent()
        let pendingDeletionFolder = pendingDeletionFolder(in: parentURL, deleting: sourceURL)
        if !fm.fileExists(atPath: pendingDeletionFolder.path) {
            try fm.createDirectory(at: pendingDeletionFolder, withIntermediateDirectories: false, attributes: nil)
        }
        let baseDestination = pendingDeletionFolder.appendingPathComponent(sourceURL.lastPathComponent)
        let destinationURL = uniqueURL(for: baseDestination, fileManager: fm) { index in
            index == 1 ? " deleted" : " deleted \(index)"
        }
        try fm.moveItem(at: sourceURL, to: destinationURL)
    }
    
    private func handleFolderRemoved(_ removedURL: URL, fallbackSelection: URL, panel: FolderPanelKind) {
        removeExpandedFolderURLs(under: removedURL, in: .primary)
        removeExpandedFolderURLs(under: removedURL, in: .secondary)
        if selectedFolderURL(for: panel)?.standardizedFileURL == removedURL {
            setSelectedFolderURL(fallbackSelection, for: panel)
        }
        if let current = currentFolder?.standardizedFileURL {
            let removedPath = removedURL.path
            if current.path == removedPath || current.path.hasPrefix(removedPath + "/") {
                currentFolder = fallbackSelection
                photos = []
            }
        }
        refreshAllFolderTrees()
    }
    
    private func remapExpandedFolderURLs(from sourceURL: URL, to destinationURL: URL, in panel: FolderPanelKind) {
        switch panel {
        case .primary:
            primaryExpandedFolderURLs = remappedURLSet(primaryExpandedFolderURLs, from: sourceURL, to: destinationURL)
        case .secondary:
            secondaryExpandedFolderURLs = remappedURLSet(secondaryExpandedFolderURLs, from: sourceURL, to: destinationURL)
        }
    }
    
    private func removeExpandedFolderURLs(under removedURL: URL, in panel: FolderPanelKind) {
        let removedPath = removedURL.standardizedFileURL.path
        func filtered(_ urls: Set<URL>) -> Set<URL> {
            Set(urls.filter { url in
                let path = url.standardizedFileURL.path
                return path != removedPath && !path.hasPrefix(removedPath + "/")
            })
        }
        switch panel {
        case .primary:
            primaryExpandedFolderURLs = filtered(primaryExpandedFolderURLs)
        case .secondary:
            secondaryExpandedFolderURLs = filtered(secondaryExpandedFolderURLs)
        }
    }
    
    private func remappedURLSet(_ urls: Set<URL>, from sourceURL: URL, to destinationURL: URL) -> Set<URL> {
        let srcPath = sourceURL.standardizedFileURL.path
        let dstPath = destinationURL.standardizedFileURL.path
        var updated = Set<URL>()
        for url in urls {
            let path = url.standardizedFileURL.path
            if path == srcPath {
                updated.insert(destinationURL.standardizedFileURL)
            } else if path.hasPrefix(srcPath + "/") {
                let relativePath = String(path.dropFirst(srcPath.count))
                updated.insert(URL(fileURLWithPath: dstPath + relativePath).standardizedFileURL)
            } else {
                updated.insert(url.standardizedFileURL)
            }
        }
        return updated
    }
#else
    private func handleFolderRemoved(_ removedURL: URL, fallbackSelection: URL, panel: FolderPanelKind) {
        if selectedFolderURL?.standardizedFileURL == removedURL {
            selectedFolderURL = fallbackSelection
        }
        if let current = currentFolder?.standardizedFileURL {
            let removedPath = removedURL.path
            if current.path == removedPath || current.path.hasPrefix(removedPath + "/") {
                currentFolder = fallbackSelection
                photos = []
            }
        }
        refreshFolderTree()
    }
#endif
#if os(macOS)
    func applyStatus(_ status: PhotoStatus, to urls: [URL]) {
        guard !urls.isEmpty else { return }
        let target = Set(urls.map { $0.standardizedFileURL })
        DispatchQueue.main.async {
            for i in 0..<self.photos.count {
                let photoURL = self.photos[i].url.standardizedFileURL
                if target.contains(photoURL) {
                    self.photos[i].status = status
                }
            }
        }
    }

    func deletePhotos(withIDs ids: Set<UUID>) {
        removePhotosFromList(withIDs: ids, fileOp: { url, fm in
            try fm.removeItem(at: url)
        }, errorLabel: { "完全削除に失敗したファイル:\n\($0)" })
    }

    func trashPhotos(withIDs ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let toDelete = photos.filter { ids.contains($0.id) }
        guard !toDelete.isEmpty else { return }

        let idURLPairs: [(id: UUID, url: URL)] = toDelete.map { ($0.id, $0.url) }
        let (pendingDeletionPairs, trashPairs) = idURLPairs.reduce(into: (pending: [(id: UUID, url: URL)](), trash: [(id: UUID, url: URL)]())) { result, pair in
            if shouldMoveToPendingDeletionInsteadOfTrash(pair.url) {
                result.pending.append(pair)
            } else {
                result.trash.append(pair)
            }
        }

        movePhotosToTrashOrPendingDeletion(trashPairs: trashPairs, pendingDeletionPairs: pendingDeletionPairs)
    }

    private func movePhotosToTrashOrPendingDeletion(trashPairs: [(id: UUID, url: URL)],
                                                    pendingDeletionPairs: [(id: UUID, url: URL)]) {
        let finish: (Set<UUID>, [String], [String]) -> Void = { [weak self] removedIDs, pendingNames, failedNames in
            guard let self else { return }
            DispatchQueue.main.async {
                if !removedIDs.isEmpty {
                    let previousPrimaryID = self.primarySelectedPhotoID
                    let previousSelectedIDs = self.selectedPhotoIDs
                    self.photos.removeAll { removedIDs.contains($0.id) }
                    self.reconcileSelectionAfterPhotoUpdate(previousPrimaryID: previousPrimaryID,
                                                           previousSelectedIDs: previousSelectedIDs)
                }
                if !failedNames.isEmpty {
                    self.presentError("ゴミ箱または削除予定への移動に失敗しました:\n" + failedNames.joined(separator: "\n"))
                } else if !pendingNames.isEmpty {
                    self.presentError("このボリュームではゴミ箱へ移動できない可能性があるため、以下のファイルを「削除予定」フォルダへ移動しました:\n" + pendingNames.joined(separator: "\n"))
                }
            }
        }

        let movePendingThenFinish: (Set<UUID>, [(id: UUID, url: URL)]) -> Void = { [weak self] trashedIDs, pairsForPendingDeletion in
            guard let self else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.movePhotosToPendingDeletion(pairsForPendingDeletion)
                finish(trashedIDs.union(result.movedIDs), result.movedNames, result.failedNames)
            }
        }

        guard !trashPairs.isEmpty else {
            movePendingThenFinish([], pendingDeletionPairs)
            return
        }

        NSWorkspace.shared.recycle(trashPairs.map { $0.url }) { [weak self] trashedItems, _ in
            guard let self else { return }
            let fm = FileManager.default
            let trashMap = Dictionary(uniqueKeysWithValues:
                trashedItems.map { ($0.key.standardizedFileURL, $0.value) })

            var trashedIDs = Set<UUID>()
            var fallbackPairs = pendingDeletionPairs

            for pair in trashPairs {
                if let destination = trashMap[pair.url.standardizedFileURL],
                   fm.fileExists(atPath: destination.path) {
                    trashedIDs.insert(pair.id)
                } else if fm.fileExists(atPath: pair.url.path) {
                    fallbackPairs.append(pair)
                } else {
                    fallbackPairs.append(pair)
                }
            }

            movePendingThenFinish(trashedIDs, fallbackPairs)
        }
    }

    private func shouldMoveToPendingDeletionInsteadOfTrash(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIsRemovableKey, .volumeIsEjectableKey]
        let values = try? url.resourceValues(forKeys: keys)
        if values?.volumeIsRemovable == true || values?.volumeIsEjectable == true {
            return true
        }
        return url.standardizedFileURL.path.hasPrefix("/Volumes/")
    }

    private func movePhotosToPendingDeletion(_ pairs: [(id: UUID, url: URL)]) -> (movedIDs: Set<UUID>, movedNames: [String], failedNames: [String]) {
        let fm = FileManager.default
        var movedIDs = Set<UUID>()
        var movedNames: [String] = []
        var failedNames: [String] = []

        for pair in pairs {
            let sourceURL = pair.url.standardizedFileURL
            do {
                try moveItemToPendingDeletion(sourceURL, fileManager: fm)
                movedIDs.insert(pair.id)
                movedNames.append(sourceURL.lastPathComponent)
            } catch {
                failedNames.append(sourceURL.lastPathComponent)
            }
        }

        return (movedIDs, movedNames, failedNames)
    }

    private func removePhotosFromList(withIDs ids: Set<UUID>,
                                      fileOp: @escaping (URL, FileManager) throws -> Void,
                                      errorLabel: @escaping (String) -> String) {
        guard !ids.isEmpty else { return }
        let toDelete = photos.filter { ids.contains($0.id) }
        guard !toDelete.isEmpty else { return }
        // Map id → url so we can match results back after the file operation
        let idURLPairs: [(id: UUID, url: URL)] = toDelete.map { ($0.id, $0.url) }
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var succeededIDs = Set<UUID>()
            var failedNames: [String] = []
            for pair in idURLPairs {
                do {
                    try fileOp(pair.url, fm)
                    succeededIDs.insert(pair.id)
                } catch {
                    failedNames.append(pair.url.lastPathComponent)
                }
            }
            DispatchQueue.main.async {
                if !succeededIDs.isEmpty {
                    let previousPrimaryID = self.primarySelectedPhotoID
                    let previousSelectedIDs = self.selectedPhotoIDs
                    self.photos.removeAll { succeededIDs.contains($0.id) }
                    self.reconcileSelectionAfterPhotoUpdate(previousPrimaryID: previousPrimaryID,
                                                           previousSelectedIDs: previousSelectedIDs)
                }
                if !failedNames.isEmpty {
                    self.presentError(errorLabel(failedNames.joined(separator: "\n")))
                }
            }
        }
    }
    func copyPhotos(at urls: [URL], to destinationFolder: URL) {
        guard !urls.isEmpty else { return }
        let destination = destinationFolder.standardizedFileURL
        isProcessing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            for url in urls {
                let sourceURL = url.standardizedFileURL
                
                // Prevent recursive folder drops
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: sourceURL.path, isDirectory: &isDir), isDir.boolValue {
                    let destPath = destination.path
                    let sourcePath = sourceURL.path
                    if destPath == sourcePath || destPath.hasPrefix(sourcePath + "/") {
                        DispatchQueue.main.async {
                            self.presentError("フォルダを自分自身またはそのサブフォルダにコピーすることはできません。")
                        }
                        continue
                    }
                }
                
                let baseDestination = destination.appendingPathComponent(sourceURL.lastPathComponent)
                let targetURL = self.uniqueCopyURL(for: baseDestination, fileManager: fm)
                do {
                    try fm.copyItem(at: sourceURL, to: targetURL)
                } catch {
                    DispatchQueue.main.async {
                        self.presentError("ファイルをコピーできませんでした: \(error.localizedDescription)")
                    }
                }
            }
            DispatchQueue.main.async {
                self.isProcessing = false
                if let current = self.currentFolder?.standardizedFileURL, current == destination {
                    self.loadPhotos(from: destination)
                } else {
                    self.refreshAllFolderTrees()
                }
            }
        }
    }
    
    private func uniqueCopyURL(for destination: URL, fileManager: FileManager) -> URL {
        uniqueURL(for: destination, fileManager: fileManager) { index in
            index == 1 ? " copy" : " copy \(index)"
        }
    }
    
    private func uniqueMoveURL(for destination: URL, fileManager: FileManager) -> URL {
        uniqueURL(for: destination, fileManager: fileManager) { index in
            index == 1 ? " move" : " move \(index)"
        }
    }
    
    private func uniqueURL(for destination: URL,
                           fileManager: FileManager,
                           suffixBuilder: (Int) -> String) -> URL {
        if !fileManager.fileExists(atPath: destination.path) {
            return destination
        }
        let directory = destination.deletingLastPathComponent()
        let baseName = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        var index = 1
        while true {
            let suffix = suffixBuilder(index)
            var candidateName = baseName + suffix
            if !ext.isEmpty {
                candidateName += ".\(ext)"
            }
            let candidateURL = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
            index += 1
        }
    }
#endif

    var hasSelectableItemsInCurrentContext: Bool {
        !selectableIDs(for: selectionContext).isEmpty
    }
    
    var currentFolderPhotos: [PhotoItem] {
        guard let currentFolder else { return [] }
        let normalizedCurrentFolder = currentFolder.standardizedFileURL
        return photos.filter { photo in
            photo.url.deletingLastPathComponent().standardizedFileURL == normalizedCurrentFolder
        }
    }

    private func selectableIDs(for context: SelectionContext) -> [UUID] {
        switch context {
        case .grid:
            return currentFolderPhotos.map { $0.id }
        case .keep:
            return photos.filter { $0.status == .groupA }.map { $0.id }
        case .discard:
            return photos.filter { $0.status == .groupB }.map { $0.id }
        }
    }

    private func selectSingle(_ id: UUID, deferred: Bool = false) {
        let apply = {
            self.primarySelectedPhotoID = id
            self.selectedPhotoIDs = [id]
            self.selectionAnchorPhotoID = id
        }
        if deferred {
            // Ensure we are safely past the current update cycle
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1), execute: apply)
        } else {
            apply()
        }
    }

    // MARK: - Keyboard navigation methods
    func moveSelection(direction: NavigationDirection, columns: Int) {
        guard !photos.isEmpty else { return }
        
        // Use current selection context for navigation
        let contextIDs = selectableIDs(for: selectionContext)
        guard !contextIDs.isEmpty else { return }
        
        let currentID = primarySelectedPhotoID ?? contextIDs.first!
        guard let currentIndex = contextIDs.firstIndex(of: currentID) else {
            // Should be in the list, but if not found, select first (deferred to avoid view-update publish)
            selectSingle(contextIDs.first!, deferred: true)
            return
        }
        
        var newIndex = currentIndex
        
        switch direction {
        case .left:
            newIndex = max(0, currentIndex - 1)
        case .right:
            newIndex = min(contextIDs.count - 1, currentIndex + 1)
        case .up, .down:
            let effectiveColumns: Int
            switch selectionContext {
            case .grid: effectiveColumns = max(1, columns)
            case .keep: effectiveColumns = max(1, groupAColumns)
            case .discard: effectiveColumns = max(1, groupBColumns)
            }
            let column = currentIndex % effectiveColumns
            let row = currentIndex / effectiveColumns
            if direction == .up {
                if row > 0 {
                    newIndex = (row - 1) * effectiveColumns + column
                }
            } else {
                let targetIndex = (row + 1) * effectiveColumns + column
                if targetIndex < contextIDs.count {
                    newIndex = targetIndex
                }
            }
        }
        
        if newIndex != currentIndex && newIndex >= 0 && newIndex < contextIDs.count {
            // Defer selection change to avoid publishing during SwiftUI's key handling update cycle
            selectSingle(contextIDs[newIndex], deferred: true)
        }
    }
    
    func toggleSelectedPhotoStatus(deferred: Bool = false) {
        let apply = {
            guard let selectedID = self.primarySelectedPhotoID,
                  let photo = self.photos.first(where: { $0.id == selectedID }) else {
                return
            }
            self.toggleStatus(for: photo)
        }
        if deferred {
            DispatchQueue.main.async(execute: apply)
        } else {
            apply()
        }
    }
    
    var selectedPhoto: PhotoItem? {
        guard let selectedID = primarySelectedPhotoID else { return nil }
        return photos.first(where: { $0.id == selectedID })
    }
    
    // Date for UI display based on setting
    func displayedDate(for photo: PhotoItem) -> Date? {
        switch sortMode {
        case .fileCreation:
            return photo.fileCreationDate
        case .exifPreferred:
            return photo.exifCreationDate ?? photo.fileCreationDate
        }
    }
    
    // Resort current photos according to sortMode
    func resortPhotos() {
        DispatchQueue.main.async {
            self.photos = self.sortedPhotos(self.photos)
        }
    }
    
    private func presentError(_ message: String) {
        self.errorMessage = message
        self.showError = true
    }

#if os(macOS)
    func urlsForDrag(startingAt photo: PhotoItem) -> [URL] {
        var selected = selectedPhotoIDs
        if !selected.contains(photo.id) {
            selected = [photo.id]
        }
        let urls = photos.filter { selected.contains($0.id) }.map { $0.url }
        return urls.isEmpty ? [photo.url] : urls
    }

    func movePhotos(at urls: [URL], to destinationFolder: URL) {
        guard !urls.isEmpty else { return }
        let destinationFolder = destinationFolder.standardizedFileURL
        isProcessing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            var movedFolders: [(from: URL, to: URL)] = []
            var movedPhotoSourceURLs: Set<URL> = []
            for url in urls {
                let sourceURL = url.standardizedFileURL
                var destinationURL = destinationFolder.appendingPathComponent(sourceURL.lastPathComponent)
                if sourceURL == destinationURL {
                    continue
                }
                
                // Prevent recursive folder drops
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDir), isDir.boolValue {
                    let destPath = destinationFolder.standardizedFileURL.path
                    let sourcePath = sourceURL.path
                    if destPath == sourcePath || destPath.hasPrefix(sourcePath + "/") {
                        DispatchQueue.main.async {
                            self.presentError("フォルダを自分自身またはそのサブフォルダに移動することはできません。")
                        }
                        continue
                    }
                }
                
                do {
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        destinationURL = self.uniqueMoveURL(for: destinationURL, fileManager: fileManager)
                    }
                    try fileManager.moveItem(at: sourceURL, to: destinationURL)
                    if isDir.boolValue {
                        movedFolders.append((from: sourceURL, to: destinationURL))
                    } else {
                        movedPhotoSourceURLs.insert(sourceURL)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.presentError("Failed to move \(sourceURL.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
            DispatchQueue.main.async {
                self.isProcessing = false
                
                let previousPrimaryID = self.primarySelectedPhotoID
                let previousSelectedIDs = self.selectedPhotoIDs
                if !movedPhotoSourceURLs.isEmpty {
                    self.photos.removeAll { photo in
                        movedPhotoSourceURLs.contains(photo.url.standardizedFileURL)
                    }
                    if self.currentFolder == nil {
                        self.reconcileSelectionAfterPhotoUpdate(previousPrimaryID: previousPrimaryID,
                                                                previousSelectedIDs: previousSelectedIDs)
                    }
                }
                
                // Update selected/current folder URLs if any directories were moved
                for mapping in movedFolders {
                    self.updateStoredURLsAfterMove(from: mapping.from, to: mapping.to)
                }
                
                if let current = self.currentFolder {
                    self.loadPhotos(from: current)
                }
                self.refreshAllFolderTrees()
            }
        }
    }
    
    private func isURL(_ url: URL, under rootURL: URL?) -> Bool {
        guard let root = rootURL?.standardizedFileURL else { return false }
        let path = url.standardizedFileURL.path
        let rootPath = root.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private func updateStoredURLsAfterMove(from sourceURL: URL, to destinationURL: URL) {
        let srcPath = sourceURL.standardizedFileURL.path
        let dstPath = destinationURL.standardizedFileURL.path
        
        func updatedURL(_ url: URL) -> URL {
            let path = url.standardizedFileURL.path
            if path == srcPath {
                return destinationURL
            } else if path.hasPrefix(srcPath + "/") {
                let relativePath = String(path.dropFirst(srcPath.count))
                let newPath = dstPath + relativePath
                return URL(fileURLWithPath: newPath)
            }
            return url
        }
        
        let newPrimarySelected = selectedFolderURL.map { updatedURL($0) }
        let newSecondarySelected = secondarySelectedFolderURL.map { updatedURL($0) }
        let newCurrent = currentFolder.map { updatedURL($0) }
        
        let primaryAffected = selectedFolderURL != nil && newPrimarySelected != selectedFolderURL
        let secondaryAffected = secondarySelectedFolderURL != nil && newSecondarySelected != secondarySelectedFolderURL
        
        let isPrimarySource = isURL(sourceURL, under: folderTreeRootURL)
        let isSecondarySource = isURL(sourceURL, under: secondaryFolderTreeRootURL)
        let isPrimaryDest = isURL(destinationURL, under: folderTreeRootURL)
        let isSecondaryDest = isURL(destinationURL, under: secondaryFolderTreeRootURL)
        
        if primaryAffected && isPrimarySource && isSecondaryDest {
            // Dragged selected folder from primary to secondary
            secondarySelectedFolderURL = newPrimarySelected
            selectedFolderURL = folderTreeRootURL
            activeFolderPanel = .secondary
        } else if secondaryAffected && isSecondarySource && isPrimaryDest {
            // Dragged selected folder from secondary to primary
            selectedFolderURL = newSecondarySelected
            secondarySelectedFolderURL = secondaryFolderTreeRootURL
            activeFolderPanel = .primary
        } else {
            // Move within the same panel, or non-selected folder moved
            if let newPrimary = newPrimarySelected {
                selectedFolderURL = newPrimary
            }
            if let newSecondary = newSecondarySelected {
                secondarySelectedFolderURL = newSecondary
            }
        }
        
        if let newCurrent = newCurrent {
            currentFolder = newCurrent
        }
        
        remapExpandedFolderURLs(from: sourceURL, to: destinationURL, in: .primary)
        remapExpandedFolderURLs(from: sourceURL, to: destinationURL, in: .secondary)
    }
#endif
    
    // Execute move for Group B items
    func executeMoves() {
        let itemsToMove = photos.filter { $0.status == .groupB }
        guard !itemsToMove.isEmpty else { return }
        
        isProcessing = true
        let fileManager = FileManager.default
        
        DispatchQueue.global(qos: .userInitiated).async {
            var destinationCache: [URL: URL] = [:]
            var movedIDs: Set<UUID> = []
            var didCreateDiscardFolder = false
            var firstErrorMessage: String?
            
            func ensureDestination(for sourceFolder: URL) -> URL? {
                let normalizedSourceFolder = sourceFolder.standardizedFileURL
                if let cached = destinationCache[normalizedSourceFolder] {
                    return cached
                }
                
                let parentFolder = normalizedSourceFolder.deletingLastPathComponent()
                let siblingFolderName = normalizedSourceFolder.lastPathComponent + "_没"
                let discardFolderURL = parentFolder.appendingPathComponent(siblingFolderName)
                
                if fileManager.fileExists(atPath: discardFolderURL.path) {
                    destinationCache[normalizedSourceFolder] = discardFolderURL
                    return discardFolderURL
                }
                
                do {
                    try fileManager.createDirectory(at: discardFolderURL, withIntermediateDirectories: true, attributes: nil)
                    didCreateDiscardFolder = true
                    destinationCache[normalizedSourceFolder] = discardFolderURL
                    return discardFolderURL
                } catch {
                    let fallback = normalizedSourceFolder.appendingPathComponent("没")
                    do {
                        if !fileManager.fileExists(atPath: fallback.path) {
                            try fileManager.createDirectory(at: fallback, withIntermediateDirectories: true, attributes: nil)
                            didCreateDiscardFolder = true
                        }
                        destinationCache[normalizedSourceFolder] = fallback
                        return fallback
                    } catch {
                        if firstErrorMessage == nil {
                            firstErrorMessage = "Failed to create discard folder for \(normalizedSourceFolder.lastPathComponent): \(error.localizedDescription)"
                        }
                        return nil
                    }
                }
            }
            
            for item in itemsToMove {
                let sourceFolder = item.url.deletingLastPathComponent()
                guard let destinationRoot = ensureDestination(for: sourceFolder) else { continue }
                
                var destinationURL = destinationRoot.appendingPathComponent(item.url.lastPathComponent)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    destinationURL = self.uniqueMoveURL(for: destinationURL, fileManager: fileManager)
                }
                
                do {
                    try fileManager.moveItem(at: item.url, to: destinationURL)
                    movedIDs.insert(item.id)
                } catch {
                    if firstErrorMessage == nil {
                        firstErrorMessage = "Failed to move \(item.filename): \(error.localizedDescription)"
                    }
                }
            }
            
            DispatchQueue.main.async {
                let previousPrimaryID = self.primarySelectedPhotoID
                let previousSelectedIDs = self.selectedPhotoIDs
                if !movedIDs.isEmpty {
                    self.photos.removeAll { movedIDs.contains($0.id) }
                    self.reconcileSelectionAfterPhotoUpdate(previousPrimaryID: previousPrimaryID,
                                                            previousSelectedIDs: previousSelectedIDs)
                }
                if didCreateDiscardFolder {
                    self.refreshAllFolderTrees()
                }
                if let firstErrorMessage {
                    self.errorMessage = firstErrorMessage
                    self.showError = true
                }
                self.isProcessing = false
            }
        }
    }
}

enum NavigationDirection {
    case left, right, up, down
}
