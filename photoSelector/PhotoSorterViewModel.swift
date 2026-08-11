//
//  PhotoSorterViewModel.swift
//  photoSelector
//
//  Created by Antigravity on 2025/12/01.
//

import SwiftUI
import Observation
import ImageIO
#if os(macOS)
import AppKit
#endif

// MARK: - Thumbnail Generator
nonisolated private struct ThumbnailRequestKey: Hashable, Sendable {
    let url: URL
    let pixelSize: Int
}

// Bounded LRU for decoded thumbnails, capped by both bitmap bytes and entry count.
// This replaces NSCache because we need two things NSCache cannot give us: a budget
// in real bitmap bytes, since thumbnails vary enough in size that an entry count
// alone bounds nothing; and enumerable keys, so thumbnails belonging to photos that
// left every pane can be dropped. ThumbnailGenerator keeps one instance per size
// class. Not thread-safe on its own; ThumbnailGenerator serialises every call on
// stateQueue.
nonisolated private final class ThumbnailLRUCache {
    private struct Entry {
        let image: NSImage
        let cost: Int
    }

    private let costLimit: Int
    private let countLimit: Int
    private var entries: [ThumbnailRequestKey: Entry] = [:]
    // Oldest first; the tail is the most recently used key.
    private var accessOrder: [ThumbnailRequestKey] = []
    // Lets the preview reuse whatever size was decoded last for a URL without
    // scanning the cache. Dropped rather than repaired when that entry is evicted:
    // it only feeds a placeholder, so a miss just means a normal decode.
    private var latestKeyByURL: [URL: ThumbnailRequestKey] = [:]
    private var totalCost = 0

    init(costLimit: Int, countLimit: Int) {
        self.costLimit = costLimit
        self.countLimit = countLimit
    }

    func image(for key: ThumbnailRequestKey) -> NSImage? {
        guard let entry = entries[key] else { return nil }
        touch(key)
        latestKeyByURL[key.url] = key
        return entry.image
    }

    func latestImage(for url: URL) -> NSImage? {
        guard let key = latestKeyByURL[url], let entry = entries[key] else { return nil }
        touch(key)
        return entry.image
    }

    func insert(_ image: NSImage, cost: Int, for key: ThumbnailRequestKey) {
        let cost = max(cost, 1)
        if let existing = entries.removeValue(forKey: key) {
            totalCost -= existing.cost
            if let index = accessOrder.lastIndex(of: key) {
                accessOrder.remove(at: index)
            }
        }
        entries[key] = Entry(image: image, cost: cost)
        accessOrder.append(key)
        latestKeyByURL[key.url] = key
        totalCost += cost
        evictIfNeeded()
    }

    // Keeps only thumbnails whose photo is still reachable from some pane.
    func retainOnly(urls: Set<URL>) {
        guard !entries.isEmpty else { return }
        var survivors: [ThumbnailRequestKey: Entry] = [:]
        survivors.reserveCapacity(entries.count)
        var survivingCost = 0
        for (key, entry) in entries where urls.contains(key.url) {
            survivors[key] = entry
            survivingCost += entry.cost
        }
        guard survivors.count != entries.count else { return }
        entries = survivors
        accessOrder = accessOrder.filter { survivors[$0] != nil }
        latestKeyByURL = latestKeyByURL.filter { survivors[$0.value] != nil }
        totalCost = survivingCost
    }

    private func touch(_ key: ThumbnailRequestKey) {
        guard let index = accessOrder.lastIndex(of: key), index != accessOrder.count - 1 else { return }
        accessOrder.remove(at: index)
        accessOrder.append(key)
    }

    // Always leaves the just-inserted entry in place, even when a single
    // full-pane thumbnail is larger than the whole budget on its own.
    private func evictIfNeeded() {
        while entries.count > 1, !accessOrder.isEmpty, totalCost > costLimit || entries.count > countLimit {
            let oldest = accessOrder.removeFirst()
            guard let entry = entries.removeValue(forKey: oldest) else { continue }
            totalCost -= entry.cost
            if latestKeyByURL[oldest.url] == oldest {
                latestKeyByURL[oldest.url] = nil
            }
        }
    }
}

class ThumbnailGenerator {
    static let shared = ThumbnailGenerator()

    // Thumbnail loading is shared by the grid and preview window, but the two ask for
    // wildly different sizes: a grid thumbnail is a fraction of a megabyte, a
    // preview-pane one is over ten. In a single LRU the heavy entries evicted the
    // light ones, so a folder's grid was re-read from the card constantly while most
    // of the budget sat in preview thumbnails that were never looked at again.
    // Splitting by size class gives each the capacity it can actually use.
    private let smallCache: ThumbnailLRUCache
    private let largeCache: ThumbnailLRUCache
    private let generationQueue: OperationQueue
    private let stateQueue = DispatchQueue(label: "dev.etokoji.thumbnailgenerator.state")
    private var completionsByKey: [ThumbnailRequestKey: [(NSImage?) -> Void]] = [:]

    // Classification follows the requested size, not the view that asked: a preview
    // pane shrunk below this is genuinely cheap and belongs with the grid thumbnails.
    // At normal window sizes the grid tops out at 800px and the side panes sit at
    // 320px, while the preview pane asks for 1280px or more.
    private static let largeClassThreshold = 512

    private init() {
        generationQueue = OperationQueue()
        generationQueue.name = "dev.etokoji.thumbnailgenerator"
        generationQueue.qualityOfService = .userInitiated
        generationQueue.maxConcurrentOperationCount = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
        smallCache = ThumbnailLRUCache(costLimit: Self.smallClassCostLimit(), countLimit: 8000)
        largeCache = ThumbnailLRUCache(costLimit: Self.largeClassCostLimit, countLimit: Self.largeClassCountLimit)
    }

    // Small class: grid and side-pane thumbnails. This is where capacity pays off —
    // a whole folder's grid fits, so scrolling back never re-reads the card. A
    // thirty-second of RAM, clamped so an 8 GB machine stays modest while a 64 GB one
    // can hold a few thousand thumbnails.
    private static func smallClassCostLimit() -> Int {
        let proposed = ProcessInfo.processInfo.physicalMemory / 32
        let minimum: UInt64 = 128 * 1024 * 1024
        let maximum: UInt64 = 1024 * 1024 * 1024
        return Int(min(max(proposed, minimum), maximum))
    }

    // Large class: preview-pane thumbnails. Only the last few are ever reused, when
    // stepping back a photo or two, so capacity here is close to pure waste. The byte
    // ceiling is a backstop against unusually large entries; the count is the limit
    // that actually operates.
    private static let largeClassCountLimit = 6
    private static let largeClassCostLimit = 128 * 1024 * 1024

    private func cache(for key: ThumbnailRequestKey) -> ThumbnailLRUCache {
        key.pixelSize > Self.largeClassThreshold ? largeCache : smallCache
    }

    func thumbnail(for url: URL, size: CGFloat, completion: @escaping (NSImage?) -> Void) {
        let key = ThumbnailRequestKey(url: url.standardizedFileURL, pixelSize: pixelSize(for: size))
        if let cachedImage = stateQueue.sync(execute: { cache(for: key).image(for: key) }) {
            completion(cachedImage)
            return
        }

        // Coalesce duplicate requests so fast scrolling does not decode the same
        // URL/size multiple times while the first request is still running.
        var shouldStartGeneration = false
        stateQueue.sync {
            if completionsByKey[key] != nil {
                completionsByKey[key]?.append(completion)
            } else {
                completionsByKey[key] = [completion]
                shouldStartGeneration = true
            }
        }

        guard shouldStartGeneration else { return }

        generationQueue.addOperation { [weak self] in
            guard let self else { return }
            let generated = self.generateThumbnail(for: key.url, pixelSize: key.pixelSize)

            let completions = self.stateQueue.sync { () -> [(NSImage?) -> Void] in
                if let generated {
                    self.cache(for: key).insert(generated.image, cost: generated.cost, for: key)
                }
                let completions = self.completionsByKey[key] ?? []
                self.completionsByKey[key] = nil
                return completions
            }

            DispatchQueue.main.async {
                completions.forEach { $0(generated?.image) }
            }
        }
    }

    func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        await withCheckedContinuation { continuation in
            thumbnail(for: url, size: size) { image in
                continuation.resume(returning: image)
            }
        }
    }

    // Small class first: it is the likelier hit and the cheaper image, and every
    // caller wants this only as an instant placeholder until the correctly sized
    // thumbnail arrives. For the preview pane that means a brief soft image rather
    // than an empty frame, which is the intended behaviour.
    func cachedThumbnail(for url: URL) -> NSImage? {
        let key = url.standardizedFileURL
        return stateQueue.sync {
            smallCache.latestImage(for: key) ?? largeCache.latestImage(for: key)
        }
    }

    // Drops thumbnails for photos that are no longer reachable from any pane, so
    // switching folders returns the memory the previous folder's grid was holding.
    func retainThumbnails(for urls: Set<URL>) {
        let normalized = Set(urls.map { $0.standardizedFileURL })
        stateQueue.async {
            self.smallCache.retainOnly(urls: normalized)
            self.largeCache.retainOnly(urls: normalized)
        }
    }

    private func pixelSize(for size: CGFloat) -> Int {
        // Hard ceiling: the enlarged preview window decodes at full resolution, so
        // nothing in the grid or the preview pane ever needs more pixels than this.
        min(2048, max(1, Int(ceil(size * 2))))
    }

    private func generateThumbnail(for url: URL, pixelSize: Int) -> (image: NSImage, cost: Int)? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        return (image, cgImage.bytesPerRow * cgImage.height)
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

enum FolderPanelKind: Hashable {
    case primary
    case secondary
    case dynamic(UUID)
}

struct FolderPaneState: Identifiable, Equatable {
    let id: UUID
    var rootURL: URL
    var folderTree: [FileSystemItem]
    var selectedFolderURL: URL?
    var expandedFolderURLs: Set<URL>
    
    var kind: FolderPanelKind {
        .dynamic(id)
    }
}

@Observable class PhotoSorterViewModel {
    var photos: [PhotoItem] = [] {
        didSet { rebuildPhotoIndexes() }
    }
    var sortMode: DateSortMode = .fileCreation
    var currentFolder: URL? {
        didSet { rebuildPhotoIndexes() }
    }
    var isProcessing: Bool = false
    var errorMessage: String?
    var showError: Bool = false
    var thumbnailSize: Double = 150
    // Selection
    // - primarySelectedPhotoID: the focused item used for preview + keyboard actions
    // - selectedPhotoIDs: supports multi-selection via mouse (cmd/shift)
    var primarySelectedPhotoID: UUID? = nil
    var selectedPhotoIDs: Set<UUID> = []
    var isArrowKeyNavigationActive: Bool = false
    private var selectionAnchorPhotoID: UUID? = nil
    var selectionContext: SelectionContext = .grid
    private var photoByID: [UUID: PhotoItem] = [:]
    private var photoIndexByID: [UUID: Int] = [:]
    private var currentFolderPhotoIDs: [UUID] = []
    private var keepPhotoIDs: [UUID] = []
    private var discardedPhotoIDs: [UUID] = []
    private var currentFolderIndexByID: [UUID: Int] = [:]
    private var keepIndexByID: [UUID: Int] = [:]
    private var discardedIndexByID: [UUID: Int] = [:]
    
    // For Folder Tree
    var folderTree: [FileSystemItem] = []
    var selectedFolderURL: URL?
    private var folderTreeRootURL: URL?
    var secondaryFolderTree: [FileSystemItem] = []
    var secondarySelectedFolderURL: URL?
    private var secondaryFolderTreeRootURL: URL?
    var activeFolderPanel: FolderPanelKind?
    var targetedFolderURL: URL?
    var primaryExpandedFolderURLs: Set<URL> = []
    var secondaryExpandedFolderURLs: Set<URL> = []
    var folderPanes: [FolderPaneState] = []
    
    // Column counts for keyboard navigation
    var groupAColumns: Int = 2
    var groupBColumns: Int = 2

    // Per-image display rotation in clockwise degrees (0/90/180/270).
    // Shared by the preview pane and the enlarged preview window; not written to the file.
    var previewRotations: [URL: Int] = [:]

    func previewRotation(for url: URL) -> Int {
        previewRotations[url.standardizedFileURL] ?? 0
    }

    func rotatePreview(for url: URL, clockwise: Bool) {
        let key = url.standardizedFileURL
        let current = previewRotations[key] ?? 0
        let next = (((current + (clockwise ? 90 : -90)) % 360) + 360) % 360
        previewRotations[key] = next == 0 ? nil : next
    }

    private func rebuildPhotoIndexes() {
        photoByID = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        photoIndexByID = Dictionary(uniqueKeysWithValues: photos.enumerated().map { ($0.element.id, $0.offset) })
        keepPhotoIDs = photos.compactMap { $0.status == .groupA ? $0.id : nil }
        discardedPhotoIDs = photos.compactMap { $0.status == .groupB ? $0.id : nil }
        keepIndexByID = Dictionary(uniqueKeysWithValues: keepPhotoIDs.enumerated().map { ($0.element, $0.offset) })
        discardedIndexByID = Dictionary(uniqueKeysWithValues: discardedPhotoIDs.enumerated().map { ($0.element, $0.offset) })

        if let currentFolder {
            let normalizedPath = currentFolder.standardizedFileURL.path.lowercased()
            currentFolderPhotoIDs = photos.compactMap { photo in
                photo.url.deletingLastPathComponent().path.lowercased() == normalizedPath ? photo.id : nil
            }
            currentFolderIndexByID = Dictionary(uniqueKeysWithValues: currentFolderPhotoIDs.enumerated().map { ($0.element, $0.offset) })
        } else {
            currentFolderPhotoIDs = []
            currentFolderIndexByID = [:]
        }

        pruneThumbnailCache()
    }

    // photos keeps entries from every folder visited this session so the keep and
    // discard panes stay populated across folder switches. Only the three pane
    // lists are actually displayable, so anything outside them — a previous
    // folder's unsorted grid, above all — is holding thumbnails for nothing.
    private func pruneThumbnailCache() {
        var retained = Set<URL>()
        retained.reserveCapacity(currentFolderPhotoIDs.count + keepPhotoIDs.count + discardedPhotoIDs.count)
        for ids in [currentFolderPhotoIDs, keepPhotoIDs, discardedPhotoIDs] {
            for id in ids {
                guard let photo = photoByID[id] else { continue }
                retained.insert(photo.url.standardizedFileURL)
            }
        }
        ThumbnailGenerator.shared.retainThumbnails(for: retained)
    }
    
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
        case .dynamic(let id):
            previousRootURL = folderPanes.first(where: { $0.id == id })?.rootURL.standardizedFileURL
            otherPanelRootURL = nil
        }
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .nameKey], options: [])

            for url in contents {
                let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
                let isDirectory = resourceValues.isDirectory ?? false
                let name = resourceValues.name ?? url.lastPathComponent

                // Skip dot-prefix system/hidden folders (e.g. .Spotlight-V100), but allow
                // device folders like PRIVATE that have the invisible flag set without a dot prefix
                if isDirectory && !name.hasPrefix(".") {
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
        case .dynamic(let id):
            if let index = folderPanes.firstIndex(where: { $0.id == id }) {
                folderPanes[index].rootURL = rootURL
                folderPanes[index].folderTree = tree
                if folderPanes[index].selectedFolderURL == nil || resetSelection {
                    folderPanes[index].selectedFolderURL = rootURL
                }
                if resetSelection || folderPanes[index].expandedFolderURLs.isEmpty {
                    folderPanes[index].expandedFolderURLs = [normalizedRoot]
                }
            } else {
                folderPanes.append(FolderPaneState(
                    id: id,
                    rootURL: rootURL,
                    folderTree: tree,
                    selectedFolderURL: rootURL,
                    expandedFolderURLs: [normalizedRoot]
                ))
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
        case .dynamic(let id):
            guard let root = folderPanes.first(where: { $0.id == id })?.rootURL else { return }
            buildFolderTree(from: root, in: .dynamic(id), resetSelection: false)
        }
    }
    
    func refreshAllFolderTrees() {
        refreshFolderTree(for: .primary)
        refreshFolderTree(for: .secondary)
        let dynamicPanels = folderPanes.map { $0.kind }
        for panel in dynamicPanels {
            refreshFolderTree(for: panel)
        }
    }
#if os(macOS)
    func openFolderPane(from rootURL: URL) {
        let id = UUID()
        buildFolderTree(from: rootURL, in: .dynamic(id))
        loadPhotos(from: rootURL)
    }
    
    func closeFolderPane(_ panel: FolderPanelKind) {
        guard case .dynamic(let id) = panel else { return }
        let wasActive = activeFolderPanel == panel
        folderPanes.removeAll { $0.id == id }
        guard wasActive else { return }
        if let firstPane = folderPanes.first, let selected = firstPane.selectedFolderURL {
            activeFolderPanel = firstPane.kind
            loadPhotos(from: selected)
        } else {
            activeFolderPanel = nil
            photos = []
            currentFolder = nil
            clearSelection(deferred: false)
        }
    }
    
    var rootFolderURL: URL? {
        folderTreeRootURL?.standardizedFileURL
    }
    
    func rootFolderURL(for panel: FolderPanelKind) -> URL? {
        switch panel {
        case .primary:
            return folderTreeRootURL?.standardizedFileURL
        case .secondary:
            return secondaryFolderTreeRootURL?.standardizedFileURL
        case .dynamic(let id):
            return folderPanes.first(where: { $0.id == id })?.rootURL.standardizedFileURL
        }
    }
    
    func rootFolderDisplayName(for panel: FolderPanelKind) -> String? {
        guard let root = rootFolderURL(for: panel) else { return nil }
        let fm = FileManager.default
        let folderName = {
            let displayName = fm.displayName(atPath: root.path)
            return displayName.isEmpty ? root.lastPathComponent : displayName
        }()
        
        if let values = try? root.resourceValues(forKeys: [.volumeNameKey]),
           let volumeName = values.volumeName,
           !volumeName.isEmpty {
            return "\(volumeName): \(folderName)"
        }
        return folderName
    }
    
    var windowTitle: String {
        let dynamic = folderPanes.compactMap { rootFolderTitleName(for: $0.kind).map { "[\($0)]" } }
        let primary = rootFolderTitleName(for: .primary).map { "[\($0)]" }
        let secondary = rootFolderTitleName(for: .secondary).map { "[\($0)]" }
        let parts = dynamic + [primary, secondary].compactMap { $0 }
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
        case .dynamic(let id):
            return folderPanes.first(where: { $0.id == id })?.selectedFolderURL
        }
    }
    
    func setSelectedFolderURL(_ url: URL, for panel: FolderPanelKind) {
        switch panel {
        case .primary:
            selectedFolderURL = url
        case .secondary:
            secondarySelectedFolderURL = url
        case .dynamic(let id):
            guard let index = folderPanes.firstIndex(where: { $0.id == id }) else { return }
            folderPanes[index].selectedFolderURL = url
        }
        activeFolderPanel = panel
        expandAncestors(of: url, in: panel)
        loadPhotos(from: url)
    }
    
    func expandedFolderURLs(for panel: FolderPanelKind) -> Set<URL> {
        switch panel {
        case .primary:
            return primaryExpandedFolderURLs
        case .secondary:
            return secondaryExpandedFolderURLs
        case .dynamic(let id):
            return folderPanes.first(where: { $0.id == id })?.expandedFolderURLs ?? []
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
        case .dynamic(let id):
            guard let index = folderPanes.firstIndex(where: { $0.id == id }) else { return }
            if expanded {
                folderPanes[index].expandedFolderURLs.insert(normalized)
            } else {
                folderPanes[index].expandedFolderURLs.remove(normalized)
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
        case .dynamic(let id):
            guard let index = folderPanes.firstIndex(where: { $0.id == id }) else { return }
            folderPanes[index].expandedFolderURLs = urls
        }
    }
    
    func folderTree(for panel: FolderPanelKind) -> [FileSystemItem] {
        switch panel {
        case .primary:
            return folderTree
        case .secondary:
            return secondaryFolderTree
        case .dynamic(let id):
            return folderPanes.first(where: { $0.id == id })?.folderTree ?? []
        }
    }

    // Flatten the tree in display order, descending only into expanded folders
    private func visibleFolderURLs(in panel: FolderPanelKind) -> [URL] {
        var result: [URL] = []
        func walk(_ items: [FileSystemItem]) {
            for item in items {
                result.append(item.id)
                if let children = item.children, !children.isEmpty, isFolderExpanded(item.id, in: panel) {
                    walk(children)
                }
            }
        }
        walk(folderTree(for: panel))
        return result
    }

    private func folderNavigationPanel() -> FolderPanelKind? {
        if let active = activeFolderPanel {
            return active
        } else if let firstPane = folderPanes.first {
            return firstPane.kind
        } else if !folderTree.isEmpty {
            return .primary
        } else if !secondaryFolderTree.isEmpty {
            return .secondary
        }
        return nil
    }

    private func findFolderItem(_ url: URL, in items: [FileSystemItem]) -> FileSystemItem? {
        let normalized = url.standardizedFileURL
        for item in items {
            if item.id.standardizedFileURL == normalized {
                return item
            }
            if let children = item.children, let found = findFolderItem(url, in: children) {
                return found
            }
        }
        return nil
    }

    func expandSelectedFolder() {
        guard let panel = folderNavigationPanel(),
              let selected = selectedFolderURL(for: panel),
              let item = findFolderItem(selected, in: folderTree(for: panel)),
              let children = item.children, !children.isEmpty else { return }
        setFolderExpanded(selected, expanded: true, in: panel)
    }

    func collapseSelectedFolder() {
        guard let panel = folderNavigationPanel(),
              let selected = selectedFolderURL(for: panel),
              let item = findFolderItem(selected, in: folderTree(for: panel)),
              let children = item.children, !children.isEmpty,
              isFolderExpanded(selected, in: panel) else { return }
        setFolderExpanded(selected, expanded: false, in: panel)
    }

    func moveFolderSelection(up: Bool) {
        guard let panel = folderNavigationPanel() else { return }

        let visible = visibleFolderURLs(in: panel)
        guard !visible.isEmpty else { return }

        guard let selected = selectedFolderURL(for: panel)?.standardizedFileURL,
              let index = visible.firstIndex(where: { $0.standardizedFileURL == selected }) else {
            setSelectedFolderURL(visible[0], for: panel)
            return
        }

        let newIndex = up ? index - 1 : index + 1
        guard visible.indices.contains(newIndex) else { return }
        setSelectedFolderURL(visible[newIndex], for: panel)
    }

    func shouldShowEjectVolumeButton(for panel: FolderPanelKind, item: FileSystemItem) -> Bool {
        guard let root = rootFolderURL(for: panel) else { return false }
        guard root == item.id.standardizedFileURL else { return false }
        return Self.ejectableVolumeMountURL(containing: root) != nil
    }
    
    func shouldShowEjectVolumeButton(for panel: FolderPanelKind) -> Bool {
        guard let root = rootFolderURL(for: panel) else { return false }
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
        case .dynamic(let id):
            folderPanes.removeAll { $0.id == id }
        }
        
        guard wasActive else { return }
        
        if let firstPane = folderPanes.first, let selected = firstPane.selectedFolderURL {
            activeFolderPanel = firstPane.kind
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
            let contents = try fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey, .nameKey], options: [])

            for url in contents {
                let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
                if let isDirectory = resourceValues.isDirectory, isDirectory {
                    let name = resourceValues.name ?? url.lastPathComponent
                    guard !name.hasPrefix(".") else { continue }
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
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: normalizedFolderURL,
                                                               includingPropertiesForKeys: [.creationDateKey],
                                                               options: [])

            let imageExtensions = ["jpg", "jpeg", "png", "heic", "gif", "tiff"]

            let imageFiles = fileURLs.filter { url in
                !url.lastPathComponent.hasPrefix(".") &&
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
            let normalizedFolderPath = normalizedFolderURL.path.lowercased()

            DispatchQueue.main.async {
                let previousPrimaryID = self.primarySelectedPhotoID
                let previousSelectedIDs = self.selectedPhotoIDs
                let existingByURL = Dictionary(self.photos.map { ($0.url.standardizedFileURL, $0) }, uniquingKeysWith: { _, last in last })

                let retainedPhotos = self.photos.filter { existing in
                    existing.url.deletingLastPathComponent().path.lowercased() != normalizedFolderPath
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
        if let index = photoIndexByID[item.id] {
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
        if let index = photoIndexByID[item.id] {
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
                    self.remapExpandedFolderURLsInAllPanes(from: normalizedURL, to: destinationURL)
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
        removeExpandedFolderURLsInAllPanes(under: removedURL)
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
        case .dynamic(let id):
            guard let index = folderPanes.firstIndex(where: { $0.id == id }) else { return }
            folderPanes[index].expandedFolderURLs = remappedURLSet(folderPanes[index].expandedFolderURLs, from: sourceURL, to: destinationURL)
        }
    }
    
    private func remapExpandedFolderURLsInAllPanes(from sourceURL: URL, to destinationURL: URL) {
        remapExpandedFolderURLs(from: sourceURL, to: destinationURL, in: .primary)
        remapExpandedFolderURLs(from: sourceURL, to: destinationURL, in: .secondary)
        for id in folderPanes.map(\.id) {
            remapExpandedFolderURLs(from: sourceURL, to: destinationURL, in: .dynamic(id))
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
        case .dynamic(let id):
            guard let index = folderPanes.firstIndex(where: { $0.id == id }) else { return }
            folderPanes[index].expandedFolderURLs = filtered(folderPanes[index].expandedFolderURLs)
        }
    }
    
    private func removeExpandedFolderURLsInAllPanes(under removedURL: URL) {
        removeExpandedFolderURLs(under: removedURL, in: .primary)
        removeExpandedFolderURLs(under: removedURL, in: .secondary)
        for id in folderPanes.map(\.id) {
            removeExpandedFolderURLs(under: removedURL, in: .dynamic(id))
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

        NSWorkspace.shared.recycle(trashPairs.map { $0.url }) { trashedItems, _ in
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
    func copyPhotos(at urls: [URL], to destinationFolder: URL, undoManager: UndoManager? = nil) {
        guard !urls.isEmpty else { return }
        let destination = destinationFolder.standardizedFileURL
        isProcessing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var copiedRecords: [FileOperationRecord] = []
            var repeatedResolution: FileConflictResolution?
            
            for url in urls {
                let sourceURL = url.standardizedFileURL
                
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
                
                var targetURL = destination.appendingPathComponent(sourceURL.lastPathComponent).standardizedFileURL
                var replacedBackup: URL?
                
                do {
                    if fm.fileExists(atPath: targetURL.path) {
                        let resolved = try self.resolveDestinationConflict(
                            sourceURL: sourceURL,
                            destinationURL: targetURL,
                            operationName: "コピー",
                            repeatedResolution: &repeatedResolution,
                            fileManager: fm
                        )
                        guard !resolved.shouldStop else { break }
                        guard let resolvedDestination = resolved.destinationURL else { continue }
                        targetURL = resolvedDestination
                        replacedBackup = resolved.replacedBackup
                    }
                    try fm.copyItem(at: sourceURL, to: targetURL)
                    copiedRecords.append(FileOperationRecord(source: sourceURL,
                                                            destination: targetURL.standardizedFileURL,
                                                            replacedBackup: replacedBackup))
                } catch {
                    self.restoreReplacementBackupIfNeeded(replacedBackup,
                                                          to: targetURL,
                                                          fileManager: fm)
                    DispatchQueue.main.async {
                        self.presentError("ファイルをコピーできませんでした: \(error.localizedDescription)")
                    }
                }
            }
            DispatchQueue.main.async {
                self.isProcessing = false
                guard !copiedRecords.isEmpty else { return }
                self.registerCopyUndo(copiedRecords, undoManager: undoManager)
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
        currentFolderPhotoIDs.compactMap { photoByID[$0] }
    }

    private func selectableIDs(for context: SelectionContext) -> [UUID] {
        switch context {
        case .grid:
            return currentFolderPhotoIDs
        case .keep:
            return keepPhotoIDs
        case .discard:
            return discardedPhotoIDs
        }
    }

    private func selectableIndex(of id: UUID, in context: SelectionContext) -> Int? {
        switch context {
        case .grid:
            return currentFolderIndexByID[id]
        case .keep:
            return keepIndexByID[id]
        case .discard:
            return discardedIndexByID[id]
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
        guard let currentIndex = selectableIndex(of: currentID, in: selectionContext) else {
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

    // Pre-warm the thumbnail cache for items ahead in the navigation direction so that
    // items outside the visible LazyVGrid area are ready when the user arrives.
    func prefetchAdjacentThumbnails(direction: NavigationDirection, columns: Int) {
        let lookahead = 4
        let contextIDs = selectableIDs(for: selectionContext)
        guard let currentID = primarySelectedPhotoID,
              let currentIndex = selectableIndex(of: currentID, in: selectionContext) else { return }

        let effectiveColumns: Int
        switch selectionContext {
        case .grid: effectiveColumns = max(1, columns)
        case .keep: effectiveColumns = max(1, groupAColumns)
        case .discard: effectiveColumns = max(1, groupBColumns)
        }

        let stride: Int
        switch direction {
        case .left: stride = -1
        case .right: stride = 1
        case .up: stride = -effectiveColumns
        case .down: stride = effectiveColumns
        }

        let size = CGFloat(thumbnailSize)
        for i in 1...lookahead {
            let nextIndex = currentIndex + stride * i
            guard nextIndex >= 0, nextIndex < contextIDs.count else { break }
            guard let photo = photoByID[contextIDs[nextIndex]] else { continue }
            ThumbnailGenerator.shared.thumbnail(for: photo.url, size: size) { _ in }
        }
    }

    func toggleSelectedPhotoStatus(deferred: Bool = false) {
        let apply = {
            guard let selectedID = self.primarySelectedPhotoID,
                  let photo = self.photoByID[selectedID] else {
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
        return photoByID[selectedID]
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
    private enum FileConflictResolution {
        case replace
        case coexist
        case cancel
    }
    
    private struct FileConflictPromptResult {
        let resolution: FileConflictResolution
        let appliesToRemaining: Bool
    }
    
    private struct FileOperationRecord {
        let source: URL
        let destination: URL
        let replacedBackup: URL?
    }
    
    private final class ButtonActionHandler: NSObject {
        static let shared = ButtonActionHandler()
        var handlers: [NSButton: () -> Void] = [:]
        
        @objc func handleButton(_ sender: NSButton) {
            handlers[sender]?()
            handlers[sender] = nil
        }
    }
    
    func urlsForDrag(startingAt photo: PhotoItem) -> [URL] {
        var selected = selectedPhotoIDs
        if !selected.contains(photo.id) {
            selected = [photo.id]
        }
        let urls = photos.filter { selected.contains($0.id) }.map { $0.url }
        return urls.isEmpty ? [photo.url] : urls
    }

    func movePhotos(at urls: [URL], to destinationFolder: URL, undoManager: UndoManager? = nil) {
        guard !urls.isEmpty else { return }
        let destinationFolder = destinationFolder.standardizedFileURL
        isProcessing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            var movedFolders: [(from: URL, to: URL)] = []
            var movedPhotoSourceURLs: Set<URL> = []
            var movedRecords: [FileOperationRecord] = []
            var repeatedResolution: FileConflictResolution?
            
            for url in urls {
                let sourceURL = url.standardizedFileURL
                var destinationURL = destinationFolder.appendingPathComponent(sourceURL.lastPathComponent).standardizedFileURL
                if sourceURL == destinationURL {
                    continue
                }
                
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
                
                var replacedBackup: URL?
                do {
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        let resolved = try self.resolveDestinationConflict(
                            sourceURL: sourceURL,
                            destinationURL: destinationURL,
                            operationName: "移動",
                            repeatedResolution: &repeatedResolution,
                            fileManager: fileManager
                        )
                        guard !resolved.shouldStop else { break }
                        guard let resolvedDestination = resolved.destinationURL else { continue }
                        destinationURL = resolvedDestination
                        replacedBackup = resolved.replacedBackup
                    }
                    try fileManager.moveItem(at: sourceURL, to: destinationURL)
                    movedRecords.append(FileOperationRecord(source: sourceURL,
                                                           destination: destinationURL.standardizedFileURL,
                                                           replacedBackup: replacedBackup))
                    if isDir.boolValue {
                        movedFolders.append((from: sourceURL, to: destinationURL))
                    } else {
                        movedPhotoSourceURLs.insert(sourceURL)
                    }
                } catch {
                    self.restoreReplacementBackupIfNeeded(replacedBackup,
                                                          to: destinationURL,
                                                          fileManager: fileManager)
                    DispatchQueue.main.async {
                        self.presentError("Failed to move \(sourceURL.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
            DispatchQueue.main.async {
                self.isProcessing = false
                guard !movedRecords.isEmpty else { return }
                self.registerMoveUndo(movedRecords, undoManager: undoManager)

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
    
    private func resolveDestinationConflict(sourceURL: URL,
                                            destinationURL: URL,
                                            operationName: String,
                                            repeatedResolution: inout FileConflictResolution?,
                                            fileManager: FileManager) throws -> (destinationURL: URL?, replacedBackup: URL?, shouldStop: Bool) {
        let resolution: FileConflictResolution
        if let repeatedResolution {
            resolution = repeatedResolution
        } else {
            let promptResult = promptForFileConflict(sourceURL: sourceURL,
                                                     destinationURL: destinationURL,
                                                     operationName: operationName)
            resolution = promptResult.resolution
            if promptResult.appliesToRemaining {
                repeatedResolution = resolution
            }
        }
        
        switch resolution {
        case .replace:
            let backupURL = try backupExistingItem(at: destinationURL, fileManager: fileManager)
            return (destinationURL, backupURL, false)
        case .coexist:
            return (uniqueNumberedURL(for: destinationURL, fileManager: fileManager), nil, false)
        case .cancel:
            return (nil, nil, repeatedResolution == .cancel)
        }
    }
    
    private func promptForFileConflict(sourceURL: URL,
                                       destinationURL: URL,
                                       operationName: String) -> FileConflictPromptResult {
        var result = FileConflictPromptResult(resolution: .cancel, appliesToRemaining: false)
        DispatchQueue.main.sync {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 188),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            panel.title = "同名の項目があります"
            panel.isReleasedWhenClosed = false
            panel.level = .modalPanel
            
            let contentView = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
            panel.contentView = contentView
            
            let iconView = NSImageView(image: NSImage(named: NSImage.cautionName) ?? NSImage())
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.imageScaling = .scaleProportionallyDown
            contentView.addSubview(iconView)
            
            let titleLabel = NSTextField(labelWithString: "同名の項目があります")
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            contentView.addSubview(titleLabel)
            
            let messageLabel = NSTextField(wrappingLabelWithString: "\"\(sourceURL.lastPathComponent)\" の\(operationName)先に同名の項目があります。")
            messageLabel.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(messageLabel)
            
            let appliesToRemainingButton = NSButton(checkboxWithTitle: "以降の競合にも同じ処理を適用", target: nil, action: nil)
            appliesToRemainingButton.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(appliesToRemainingButton)
            
            let buttonStack = NSStackView()
            buttonStack.translatesAutoresizingMaskIntoConstraints = false
            buttonStack.orientation = .horizontal
            buttonStack.alignment = .centerY
            buttonStack.spacing = 8
            contentView.addSubview(buttonStack)
            
            var selectedResolution: FileConflictResolution = .cancel
            func addButton(title: String, resolution: FileConflictResolution, keyEquivalent: String = "") {
                let button = NSButton(title: title, target: nil, action: nil)
                button.bezelStyle = .rounded
                button.keyEquivalent = keyEquivalent
                button.setButtonType(.momentaryPushIn)
                button.target = ButtonActionHandler.shared
                button.action = #selector(ButtonActionHandler.shared.handleButton(_:))
                button.identifier = NSUserInterfaceItemIdentifier(title)
                ButtonActionHandler.shared.handlers[button] = {
                    selectedResolution = resolution
                    NSApp.stopModal()
                }
                buttonStack.addArrangedSubview(button)
            }
            
            addButton(title: "両方とも残す", resolution: .coexist)
            addButton(title: "中止", resolution: .cancel, keyEquivalent: "\u{1b}")
            addButton(title: "置き換える", resolution: .replace)
            
            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
                iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
                iconView.widthAnchor.constraint(equalToConstant: 42),
                iconView.heightAnchor.constraint(equalToConstant: 42),
                
                titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 16),
                titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
                titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
                
                messageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                messageLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
                messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
                
                appliesToRemainingButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                appliesToRemainingButton.trailingAnchor.constraint(lessThanOrEqualTo: titleLabel.trailingAnchor),
                appliesToRemainingButton.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 16),
                
                buttonStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
                buttonStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18)
            ])
            
            if let window = NSApp.keyWindow {
                window.beginSheet(panel)
            }
            NSApp.runModal(for: panel)
            panel.sheetParent?.endSheet(panel)
            panel.close()
            
            result = FileConflictPromptResult(
                resolution: selectedResolution,
                appliesToRemaining: appliesToRemainingButton.state == .on
            )
        }
        return result
    }
    
    private func backupExistingItem(at url: URL, fileManager: FileManager) throws -> URL {
        let backupFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photoSelectorReplacementBackups", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        let backupURL = backupFolder.appendingPathComponent(url.lastPathComponent)
        try fileManager.moveItem(at: url, to: backupURL)
        return backupURL.standardizedFileURL
    }
    
    private func restoreReplacementBackupIfNeeded(_ backupURL: URL?, to destinationURL: URL, fileManager: FileManager) {
        guard let backupURL,
              fileManager.fileExists(atPath: backupURL.path),
              !fileManager.fileExists(atPath: destinationURL.path)
        else { return }
        try? fileManager.moveItem(at: backupURL, to: destinationURL)
    }
    
    private func uniqueNumberedURL(for destination: URL, fileManager: FileManager) -> URL {
        uniqueURL(for: destination, fileManager: fileManager) { index in
            "_\(index)"
        }
    }

    private func registerCopyUndo(_ records: [FileOperationRecord], undoManager: UndoManager?) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            target.undoCopy(records, undoManager: undoManager)
        }
        undoManager.setActionName("コピー")
    }
    
    private func undoCopy(_ records: [FileOperationRecord], undoManager: UndoManager) {
        isProcessing = true
        let fileManager = FileManager.default
        var undoneRecords: [FileOperationRecord] = []
        var failedNames: [String] = []
        
        for record in records {
            do {
                if fileManager.fileExists(atPath: record.destination.path) {
                    try fileManager.removeItem(at: record.destination)
                }
                if let replacedBackup = record.replacedBackup,
                   fileManager.fileExists(atPath: replacedBackup.path) {
                    try fileManager.moveItem(at: replacedBackup, to: record.destination)
                }
                undoneRecords.append(record)
            } catch {
                failedNames.append(record.destination.lastPathComponent)
            }
        }
        
        isProcessing = false
        if !undoneRecords.isEmpty {
            undoManager.registerUndo(withTarget: self) { target in
                target.redoCopy(undoneRecords, undoManager: undoManager)
            }
            undoManager.setActionName("コピー")
        }
        refreshAfterFileChanges()
        if !failedNames.isEmpty {
            presentError("コピーの取り消しに失敗しました:\n" + failedNames.joined(separator: "\n"))
        }
    }
    
    private func redoCopy(_ records: [FileOperationRecord], undoManager: UndoManager) {
        isProcessing = true
        let fileManager = FileManager.default
        var copiedRecords: [FileOperationRecord] = []
        var failedNames: [String] = []
        
        for record in records {
            var replacedBackup: URL?
            do {
                guard fileManager.fileExists(atPath: record.source.path) else {
                    failedNames.append(record.source.lastPathComponent)
                    continue
                }
                if fileManager.fileExists(atPath: record.destination.path) {
                    replacedBackup = try backupExistingItem(at: record.destination, fileManager: fileManager)
                }
                try fileManager.copyItem(at: record.source, to: record.destination)
                copiedRecords.append(FileOperationRecord(source: record.source,
                                                        destination: record.destination,
                                                        replacedBackup: replacedBackup))
            } catch {
                restoreReplacementBackupIfNeeded(replacedBackup,
                                                 to: record.destination,
                                                 fileManager: fileManager)
                failedNames.append(record.destination.lastPathComponent)
            }
        }
        
        isProcessing = false
        if !copiedRecords.isEmpty {
            registerCopyUndo(copiedRecords, undoManager: undoManager)
        }
        refreshAfterFileChanges()
        if !failedNames.isEmpty {
            presentError("コピーのやり直しに失敗しました:\n" + failedNames.joined(separator: "\n"))
        }
    }
    
    private func registerMoveUndo(_ records: [FileOperationRecord], undoManager: UndoManager?) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            target.undoMove(records, undoManager: undoManager)
        }
        undoManager.setActionName("移動")
    }
    
    private func undoMove(_ records: [FileOperationRecord], undoManager: UndoManager) {
        isProcessing = true
        let fileManager = FileManager.default
        var undoneRecords: [FileOperationRecord] = []
        var failedNames: [String] = []
        
        for record in records {
            do {
                guard fileManager.fileExists(atPath: record.destination.path) else {
                    failedNames.append(record.destination.lastPathComponent)
                    continue
                }
                if fileManager.fileExists(atPath: record.source.path) {
                    failedNames.append(record.source.lastPathComponent)
                    continue
                }
                try fileManager.moveItem(at: record.destination, to: record.source)
                if let replacedBackup = record.replacedBackup,
                   fileManager.fileExists(atPath: replacedBackup.path) {
                    try fileManager.moveItem(at: replacedBackup, to: record.destination)
                }
                undoneRecords.append(record)
            } catch {
                failedNames.append(record.destination.lastPathComponent)
            }
        }
        
        isProcessing = false
        for record in undoneRecords {
            updateStoredURLsAfterMove(from: record.destination, to: record.source)
        }
        if !undoneRecords.isEmpty {
            undoManager.registerUndo(withTarget: self) { target in
                target.redoMove(undoneRecords, undoManager: undoManager)
            }
            undoManager.setActionName("移動")
        }
        refreshAfterFileChanges()
        if !failedNames.isEmpty {
            presentError("移動の取り消しに失敗しました:\n" + failedNames.joined(separator: "\n"))
        }
    }
    
    private func redoMove(_ records: [FileOperationRecord], undoManager: UndoManager) {
        isProcessing = true
        let fileManager = FileManager.default
        var movedRecords: [FileOperationRecord] = []
        var failedNames: [String] = []
        
        for record in records {
            var replacedBackup: URL?
            do {
                guard fileManager.fileExists(atPath: record.source.path) else {
                    failedNames.append(record.source.lastPathComponent)
                    continue
                }
                if fileManager.fileExists(atPath: record.destination.path) {
                    replacedBackup = try backupExistingItem(at: record.destination, fileManager: fileManager)
                }
                try fileManager.moveItem(at: record.source, to: record.destination)
                movedRecords.append(FileOperationRecord(source: record.source,
                                                       destination: record.destination,
                                                       replacedBackup: replacedBackup))
            } catch {
                restoreReplacementBackupIfNeeded(replacedBackup,
                                                 to: record.destination,
                                                 fileManager: fileManager)
                failedNames.append(record.source.lastPathComponent)
            }
        }
        
        isProcessing = false
        for record in movedRecords {
            updateStoredURLsAfterMove(from: record.source, to: record.destination)
        }
        if !movedRecords.isEmpty {
            registerMoveUndo(movedRecords, undoManager: undoManager)
        }
        refreshAfterFileChanges()
        if !failedNames.isEmpty {
            presentError("移動のやり直しに失敗しました:\n" + failedNames.joined(separator: "\n"))
        }
    }
    
    private func refreshAfterFileChanges() {
        if let current = currentFolder {
            loadPhotos(from: current)
        }
        refreshAllFolderTrees()
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
        
        let newCurrent = currentFolder.map { updatedURL($0) }
        
        if let currentSelection = selectedFolderURL {
            selectedFolderURL = updatedURL(currentSelection)
        }
        if let currentSelection = secondarySelectedFolderURL {
            secondarySelectedFolderURL = updatedURL(currentSelection)
        }
        for index in folderPanes.indices {
            folderPanes[index].rootURL = updatedURL(folderPanes[index].rootURL)
            if let currentSelection = folderPanes[index].selectedFolderURL {
                folderPanes[index].selectedFolderURL = updatedURL(currentSelection)
            }
        }
        
        if let newCurrent = newCurrent {
            currentFolder = newCurrent
        }
        
        remapExpandedFolderURLsInAllPanes(from: sourceURL, to: destinationURL)
    }
#endif
    
    // Execute move for Group B items
    func executeMoves(undoManager: UndoManager? = nil) {
        let itemsToMove = photos.filter { $0.status == .groupB }
        guard !itemsToMove.isEmpty else { return }
        
        isProcessing = true
        
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            var destinationCache: [URL: URL] = [:]
            var movedIDs: Set<UUID> = []
            var movedRecords: [FileOperationRecord] = []
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
                    let sourceURL = item.url.standardizedFileURL
                    try fileManager.moveItem(at: sourceURL, to: destinationURL)
                    movedIDs.insert(item.id)
                    movedRecords.append(FileOperationRecord(source: sourceURL,
                                                            destination: destinationURL.standardizedFileURL,
                                                            replacedBackup: nil))
                } catch {
                    if firstErrorMessage == nil {
                        firstErrorMessage = "Failed to move \(item.filename): \(error.localizedDescription)"
                    }
                }
            }
            
            DispatchQueue.main.async {
                let previousPrimaryID = self.primarySelectedPhotoID
                let previousSelectedIDs = self.selectedPhotoIDs
                if !movedRecords.isEmpty {
                    self.registerMoveUndo(movedRecords, undoManager: undoManager)
                }
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
