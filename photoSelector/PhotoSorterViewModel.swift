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
        
        // Initially select the root folder
        if selectedFolderURL == nil {
            self.selectedFolderURL = rootURL
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
            
            DispatchQueue.main.async {
                self.photos = imageFiles.map { PhotoItem(url: $0) }
                // Select first photo by default
                if let first = self.photos.first?.id {
                    self.primarySelectedPhotoID = first
                    self.selectedPhotoIDs = [first]
                    self.selectionAnchorPhotoID = first
                    self.selectionContext = .grid
                } else {
                    self.primarySelectedPhotoID = nil
                    self.selectedPhotoIDs = []
                    self.selectionAnchorPhotoID = nil
                    self.selectionContext = .grid
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
                clearSelection()
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
        selectionContext = context
        if isShiftPressed {
            let anchor = selectionAnchorPhotoID ?? primarySelectedPhotoID ?? id
            guard let a = orderedIDs.firstIndex(of: anchor),
                  let b = orderedIDs.firstIndex(of: id)
            else {
                // Fallback: just select the clicked item
                selectSingle(id)
                return
            }

            let range = a <= b ? a...b : b...a
            selectedPhotoIDs = Set(orderedIDs[range])
            primarySelectedPhotoID = id
            selectionAnchorPhotoID = anchor
            return
        }

        if isCommandPressed {
            if selectedPhotoIDs.contains(id) {
                selectedPhotoIDs.remove(id)
                if primarySelectedPhotoID == id {
                    primarySelectedPhotoID = selectedPhotoIDs.first
                }
            } else {
                selectedPhotoIDs.insert(id)
                primarySelectedPhotoID = id
            }
            selectionAnchorPhotoID = primarySelectedPhotoID
            return
        }

        // Normal click: single selection
        selectSingle(id)
    }

    /// Clear current selection (does not change photo statuses).
    func clearSelection() {
        primarySelectedPhotoID = nil
        selectedPhotoIDs = []
        selectionAnchorPhotoID = nil
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

    private func selectSingle(_ id: UUID) {
        primarySelectedPhotoID = id
        selectedPhotoIDs = [id]
        selectionAnchorPhotoID = id
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
        let discardFolderURL = currentFolder.appendingPathComponent("没")
        
        // Create "没" folder if it doesn't exist
        if !fileManager.fileExists(atPath: discardFolderURL.path) {
            do {
                try fileManager.createDirectory(at: discardFolderURL, withIntermediateDirectories: true, attributes: nil)
            } catch {
                self.errorMessage = "Failed to create discard folder: \(error.localizedDescription)"
                self.showError = true
                self.isProcessing = false
                return
            }
        }
        
        let itemsToMove = photos.filter { $0.status == .groupB }
        var movedCount = 0
        
        DispatchQueue.global(qos: .userInitiated).async {
            for item in itemsToMove {
                let destinationURL = discardFolderURL.appendingPathComponent(item.url.lastPathComponent)
                do {
                    try fileManager.moveItem(at: item.url, to: destinationURL)
                    movedCount += 1
                    
                    // Update the item in the list to reflect it's gone or moved
                    // For now, we might want to remove it from the list or mark it as moved.
                    // Let's remove it from the list to show progress.
                    DispatchQueue.main.async {
                        if let index = self.photos.firstIndex(where: { $0.id == item.id }) {
                            self.photos.remove(at: index)
                        }
                    }
                } catch {
                    print("Failed to move \(item.filename): \(error.localizedDescription)")
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
