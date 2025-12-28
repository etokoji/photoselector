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
    @Published var selectedPhotoID: UUID? = nil // Currently selected photo for keyboard navigation
    
    // For Folder Tree
    @Published var folderTree: [FileSystemItem] = []
    @Published var selectedFolderURL: URL?
    
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
                self.selectedPhotoID = self.photos.first?.id
            }
        } catch {
            self.errorMessage = "Failed to load photos: \(error.localizedDescription)"
            self.showError = true
        }
    }
    
    // Toggle status or set specific status
    func toggleStatus(for item: PhotoItem) {
        if let index = photos.firstIndex(where: { $0.id == item.id }) {
            switch photos[index].status {
            case .unknown:
                photos[index].status = .groupA
            case .groupA:
                photos[index].status = .groupB
            case .groupB:
                photos[index].status = .unknown
            }
        }
    }
    
    func setStatus(for item: PhotoItem, status: PhotoStatus) {
        if let index = photos.firstIndex(where: { $0.id == item.id }) {
            photos[index].status = status
        }
    }
    
    // Clear all selections (reset to unknown)
    func clearAllSelections() {
        for i in 0..<photos.count {
            photos[i].status = .unknown
        }
    }
    
    // Keyboard navigation methods
    func moveSelection(direction: NavigationDirection, columns: Int) {
        guard !photos.isEmpty else { return }
        
        // If no selection, select first photo
        guard let currentID = selectedPhotoID,
              let currentIndex = photos.firstIndex(where: { $0.id == currentID }) else {
            selectedPhotoID = photos.first?.id
            return
        }
        
        var newIndex = currentIndex
        
        switch direction {
        case .left:
            newIndex = max(0, currentIndex - 1)
        case .right:
            newIndex = min(photos.count - 1, currentIndex + 1)
        case .up:
            newIndex = max(0, currentIndex - columns)
        case .down:
            newIndex = min(photos.count - 1, currentIndex + columns)
        }
        
        if newIndex != currentIndex && newIndex >= 0 && newIndex < photos.count {
            selectedPhotoID = photos[newIndex].id
        }
    }
    
    func toggleSelectedPhotoStatus() {
        guard let selectedID = selectedPhotoID,
              let photo = photos.first(where: { $0.id == selectedID }) else {
            return
        }
        toggleStatus(for: photo)
    }
    
    var selectedPhoto: PhotoItem? {
        guard let selectedID = selectedPhotoID else { return nil }
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
