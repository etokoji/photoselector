//
//  PhotoSorterViewModel.swift
//  photoSelector
//
//  Created by Antigravity on 2025/12/01.
//

import SwiftUI
import Combine

class PhotoSorterViewModel: ObservableObject {
    @Published var photos: [PhotoItem] = []
    @Published var currentFolder: URL?
    @Published var isProcessing: Bool = false
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var thumbnailSize: Double = 150 // Default thumbnail size
    
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
