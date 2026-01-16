//
//  PhotoSorterViewModel.swift
//  photoSelector
//
//  Created by Antigravity on 2025/12/01.
//

import SwiftUI
import Combine
import ImageIO

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

class PhotoSorterViewModel: ObservableObject {
    @Published var photos: [PhotoItem] = []
    @Published var sortMode: DateSortMode {
        didSet {
            UserDefaults.standard.set(sortMode.rawValue, forKey: "DateSortMode")
        }
    }
    @Published var currentFolder: URL?
    @Published var isProcessing: Bool = false
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var thumbnailSize: Double {
        didSet {
            UserDefaults.standard.set(thumbnailSize, forKey: "ThumbnailSize")
        }
    }
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
    
    // Column counts for keyboard navigation
    @Published var groupAColumns: Int = 2
    @Published var groupBColumns: Int = 2
    
    init() {
        // Restore saved thumbnail size or use default
        let savedSize = UserDefaults.standard.double(forKey: "ThumbnailSize")
        self.thumbnailSize = savedSize > 0 ? savedSize : 150
        if let raw = UserDefaults.standard.string(forKey: "DateSortMode"), let m = DateSortMode(rawValue: raw) {
            self.sortMode = m
        } else {
            self.sortMode = .fileCreation // default: EXIFなし
        }
    }
    
    // Scan the root folder and build the folder tree
    func buildFolderTree(from rootURL: URL, resetSelection: Bool = true) {
        folderTreeRootURL = rootURL
        let fileManager = FileManager.default
        var items: [FileSystemItem] = []
        
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
        self.folderTree = [
            FileSystemItem(id: rootURL, name: rootURL.lastPathComponent, children: items, isFolder: true)
        ]
        
        // Initially select the root folder or keep current selection based on flag
        if selectedFolderURL == nil || resetSelection {
            DispatchQueue.main.async {
                self.selectedFolderURL = rootURL
            }
        }
    }

    func refreshFolderTree() {
        guard let root = folderTreeRootURL else { return }
        buildFolderTree(from: root, resetSelection: false)
    }
#if os(macOS)
    var rootFolderURL: URL? {
        folderTreeRootURL?.standardizedFileURL
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
    
    // Load photos from a selected folder
    func loadPhotos(from folderURL: URL) {
        self.currentFolder = folderURL
        self.photos = []
        
        let fileManager = FileManager.default
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.creationDateKey], options: options)
            
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
                    return da < db
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
                    return da < db
                }
            }
            
            let items = sortedURLs.map { PhotoItem(url: $0) }
            
            DispatchQueue.main.async {
                self.photos = items
                // Defer selection and context to the next runloop tick to avoid publishing during initial view updates
                if let first = self.photos.first?.id {
                    DispatchQueue.main.async {
                        self.selectSingle(first, deferred: false)
                        self.selectionContext = .grid
                    }
                } else {
                    self.clearSelection(deferred: true)
                    DispatchQueue.main.async {
                        self.selectionContext = .grid
                    }
                }
            }
        } catch {
            self.errorMessage = "Failed to load photos: \(error.localizedDescription)"
            self.showError = true
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
    func createSubfolder(at parentURL: URL, named name: String) {
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
                    self.selectedFolderURL = newURL
                    self.refreshFolderTree()
                }
            } catch {
                DispatchQueue.main.async {
                    self.presentError("フォルダを作成できませんでした: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func renameFolder(at folderURL: URL, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalizedURL = folderURL.standardizedFileURL
        if let root = rootFolderURL, root == normalizedURL {
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
                    if self.selectedFolderURL?.standardizedFileURL == normalizedURL {
                        self.selectedFolderURL = destinationURL
                    }
                    if self.currentFolder?.standardizedFileURL == normalizedURL {
                        self.currentFolder = destinationURL
                    }
                    self.refreshFolderTree()
                }
            } catch {
                DispatchQueue.main.async {
                    self.presentError("フォルダ名を変更できませんでした: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func trashFolder(at folderURL: URL) {
        let normalizedURL = folderURL.standardizedFileURL
        if let root = rootFolderURL, root == normalizedURL {
            presentError("ルートフォルダは削除できません。")
            return
        }
        let parentURL = normalizedURL.deletingLastPathComponent()
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            do {
                try fm.trashItem(at: normalizedURL, resultingItemURL: nil)
                DispatchQueue.main.async {
                    if self.selectedFolderURL?.standardizedFileURL == normalizedURL {
                        self.selectedFolderURL = parentURL
                    }
                    if let current = self.currentFolder?.standardizedFileURL {
                        let deletedPath = normalizedURL.path
                        if current.path == deletedPath || current.path.hasPrefix(deletedPath + "/") {
                        self.currentFolder = parentURL
                        self.photos = []
                        }
                    }
                    self.refreshFolderTree()
                }
            } catch {
                DispatchQueue.main.async {
                    self.presentError("フォルダを削除できませんでした: \(error.localizedDescription)")
                }
            }
        }
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
#endif

    var hasSelectableItemsInCurrentContext: Bool {
        !selectableIDs(for: selectionContext).isEmpty
    }

    private func selectableIDs(for context: SelectionContext) -> [UUID] {
        switch context {
        case .grid:
            return photos.map { $0.id }
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
        case .up:
            // Calculate approximate row movement
            let effectiveColumns: Int
            switch selectionContext {
            case .grid: effectiveColumns = columns
            case .keep: effectiveColumns = groupAColumns
            case .discard: effectiveColumns = groupBColumns
            }
            newIndex = max(0, currentIndex - effectiveColumns)
        case .down:
            let effectiveColumns: Int
            switch selectionContext {
            case .grid: effectiveColumns = columns
            case .keep: effectiveColumns = groupAColumns
            case .discard: effectiveColumns = groupBColumns
            }
            newIndex = min(contextIDs.count - 1, currentIndex + effectiveColumns)
        }
        
        if newIndex != currentIndex && newIndex >= 0 && newIndex < contextIDs.count {
            // Defer selection change to avoid publishing during SwiftUI's key handling update cycle
            selectSingle(contextIDs[newIndex], deferred: true)
        }
    }
    
    func toggleSelectedPhotoStatus() {
        guard let selectedID = primarySelectedPhotoID,
              let photo = photos.first(where: { $0.id == selectedID }) else {
            return
        }
        toggleStatus(for: photo)
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
        let comparator: (PhotoItem, PhotoItem) -> Bool = { a, b in
            let da: Date
            let db: Date
            switch self.sortMode {
            case .fileCreation:
                da = a.fileCreationDate ?? .distantFuture
                db = b.fileCreationDate ?? .distantFuture
            case .exifPreferred:
                da = (a.exifCreationDate ?? a.fileCreationDate) ?? .distantFuture
                db = (b.exifCreationDate ?? b.fileCreationDate) ?? .distantFuture
            }
            return da < db
        }
        DispatchQueue.main.async {
            self.photos.sort(by: comparator)
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
        isProcessing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            for url in urls {
                let destinationURL = destinationFolder.appendingPathComponent(url.lastPathComponent)
                do {
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        try fileManager.removeItem(at: destinationURL)
                    }
                    try fileManager.moveItem(at: url, to: destinationURL)
                } catch {
                    DispatchQueue.main.async {
                        self.errorMessage = "Failed to move \(url.lastPathComponent): \(error.localizedDescription)"
                        self.showError = true
                    }
                }
            }
            DispatchQueue.main.async {
                self.isProcessing = false
                if let current = self.currentFolder {
                    self.loadPhotos(from: current)
                }
                self.refreshFolderTree()
            }
        }
    }
#endif
    
    // Execute move for Group B items
    func executeMoves() {
        guard let currentFolder = currentFolder else { return }
        
        isProcessing = true
        let fileManager = FileManager.default
        
        // Target folder: sibling of currentFolder, named "<currentFolderName>_没"
        let parentFolder = currentFolder.deletingLastPathComponent()
        let siblingFolderName = currentFolder.lastPathComponent + "_没"
        let discardFolderURL = parentFolder.appendingPathComponent(siblingFolderName)
        var didCreateDiscardFolder = false
        
        // Ensure destination exists. If we fail (sandbox, perms), fallback to subfolder "没" inside currentFolder
        func ensureDestination() -> URL? {
            if fileManager.fileExists(atPath: discardFolderURL.path) {
                return discardFolderURL
            }
            do {
                try fileManager.createDirectory(at: discardFolderURL, withIntermediateDirectories: true, attributes: nil)
                didCreateDiscardFolder = true
                return discardFolderURL
            } catch {
                // Fallback
                let fallback = currentFolder.appendingPathComponent("没")
                do {
                    if !fileManager.fileExists(atPath: fallback.path) {
                        try fileManager.createDirectory(at: fallback, withIntermediateDirectories: true, attributes: nil)
                        didCreateDiscardFolder = true
                    }
                    DispatchQueue.main.async {
                        print("[Move] Could not create sibling discard folder (\(discardFolderURL.path)). Falling back to \(fallback.path). Error: \(error.localizedDescription)")
                    }
                    return fallback
                } catch {
                    DispatchQueue.main.async {
                        self.errorMessage = "Failed to create discard folder: \(error.localizedDescription)"
                        self.showError = true
                        self.isProcessing = false
                    }
                    return nil
                }
            }
        }
        
        guard let destinationRoot = ensureDestination() else { return }

        if didCreateDiscardFolder {
            DispatchQueue.main.async {
                self.refreshFolderTree()
            }
        }
        
        let itemsToMove = photos.filter { $0.status == .groupB }
        
        DispatchQueue.global(qos: .userInitiated).async {
            for item in itemsToMove {
                let destinationURL = destinationRoot.appendingPathComponent(item.url.lastPathComponent)
                do {
                    try fileManager.moveItem(at: item.url, to: destinationURL)
                    
                    DispatchQueue.main.async {
                        if let index = self.photos.firstIndex(where: { $0.id == item.id }) {
                            self.photos.remove(at: index)
                        }
                    }
                } catch {
                    print("[Move] Failed to move \(item.filename): \(error.localizedDescription)")
                }
            }
            
            DispatchQueue.main.async {
                self.isProcessing = false
            }
        }
    }
}

enum NavigationDirection {
    case left, right, up, down
}
