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

class PhotoSorterViewModel: ObservableObject {
    @Published var photos: [PhotoItem] = []
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
    
    // Column counts for keyboard navigation
    @Published var groupAColumns: Int = 2
    @Published var groupBColumns: Int = 2
    
    init() {
        // Restore saved thumbnail size or use default
        let savedSize = UserDefaults.standard.double(forKey: "ThumbnailSize")
        self.thumbnailSize = savedSize > 0 ? savedSize : 150
    }
    
    // Scan the root folder and build the folder tree
    func buildFolderTree(from rootURL: URL) {
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
        
        // Add the root folder itself at the top
        self.folderTree = [
            FileSystemItem(id: rootURL, name: rootURL.lastPathComponent, children: items, isFolder: true)
        ]
        
        // Initially select the root folder (defer to avoid publishing during folderTree view updates)
        if selectedFolderURL == nil {
            DispatchQueue.main.async {
                self.selectedFolderURL = rootURL
            }
        }
    }
    
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
        
        return children.isEmpty ? nil : children
    }
    
    // Load photos from a selected folder
    func loadPhotos(from folderURL: URL) {
        self.currentFolder = folderURL
        self.photos = []
        
        let fileManager = FileManager.default
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil, options: options)
            
            let imageExtensions = ["jpg", "jpeg", "png", "heic", "gif", "tiff"]
            
            let imageFiles = fileURLs.filter { url in
                imageExtensions.contains(url.pathExtension.lowercased())
            }
            
            // Construct photo items and sort by creation date ascending
            let items = imageFiles.map { PhotoItem(url: $0) }
                .sorted { a, b in
                    let da = a.creationDate ?? Date.distantFuture
                    let db = b.creationDate ?? Date.distantFuture
                    return da < db
                }
            
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
            // Set context and selection changes together, deferred
            DispatchQueue.main.async {
                self.selectionContext = context
            }
            let anchor = selectionAnchorPhotoID ?? primarySelectedPhotoID ?? id
            guard let a = orderedIDs.firstIndex(of: anchor),
                  let b = orderedIDs.firstIndex(of: id)
            else {
                // Fallback: just select the clicked item
                selectSingle(id, deferred: true)
                return
            }

            let range = a <= b ? a...b : b...a
            DispatchQueue.main.async {
                self.selectedPhotoIDs = Set(orderedIDs[range])
                self.primarySelectedPhotoID = id
                self.selectionAnchorPhotoID = anchor
            }
            return
        }

        if isCommandPressed {
            DispatchQueue.main.async {
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

        // Normal click: single selection
        DispatchQueue.main.async {
            self.selectionContext = context
        }
        selectSingle(id, deferred: true)
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

    func selectAll(in context: SelectionContext) {
        let ids = selectableIDs(for: context)
        guard !ids.isEmpty else { return }
        primarySelectedPhotoID = ids.first
        selectedPhotoIDs = Set(ids)
        selectionAnchorPhotoID = ids.first
        selectionContext = context
    }

    func selectAllCurrentContext() {
        selectAll(in: selectionContext)
    }

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
            DispatchQueue.main.async(execute: apply)
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
            // Should be in the list, but if not found, select first
            selectSingle(contextIDs.first!)
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
            selectSingle(contextIDs[newIndex])
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
    
    // Execute move for Group B items
    func executeMoves() {
        guard let currentFolder = currentFolder else { return }
        
        isProcessing = true
        let fileManager = FileManager.default
        
        // Target folder: sibling of currentFolder, named "<currentFolderName>_没"
        let parentFolder = currentFolder.deletingLastPathComponent()
        let siblingFolderName = currentFolder.lastPathComponent + "_没"
        var discardFolderURL = parentFolder.appendingPathComponent(siblingFolderName)
        
        // Ensure destination exists. If we fail (sandbox, perms), fallback to subfolder "没" inside currentFolder
        func ensureDestination() -> URL? {
            if fileManager.fileExists(atPath: discardFolderURL.path) {
                return discardFolderURL
            }
            do {
                try fileManager.createDirectory(at: discardFolderURL, withIntermediateDirectories: true, attributes: nil)
                return discardFolderURL
            } catch {
                // Fallback
                let fallback = currentFolder.appendingPathComponent("没")
                do {
                    if !fileManager.fileExists(atPath: fallback.path) {
                        try fileManager.createDirectory(at: fallback, withIntermediateDirectories: true, attributes: nil)
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
