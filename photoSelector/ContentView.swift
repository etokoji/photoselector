//
//  ContentView.swift
//  photoSelector
//
//  Created by 江藤公二 on 2025/12/01.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var viewModel = PhotoSorterViewModel()
    @State private var showImagePreview = false
    @FocusState private var isGridFocused: Bool
    @State private var actualGridWidth: CGFloat = 800
    
    // Monitor for Option key state
    private var isOptionPressed: Bool {
        NSEvent.modifierFlags.contains(.option)
    }
    
    var columns: [GridItem] {
        [
            GridItem(.adaptive(minimum: viewModel.thumbnailSize, maximum: viewModel.thumbnailSize * 2), spacing: 10)
        ]
    }
    
    // Calculate actual number of columns in the grid based on real width
    var actualColumns: Int {
        let itemWidth = viewModel.thumbnailSize + 10 // thumbnailSize + spacing
        let padding: CGFloat = 32 // Total horizontal padding (16 on each side)
        let availableWidth = actualGridWidth - padding
        return max(1, Int(availableWidth / itemWidth))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar Area
            HStack {
                Button(action: selectFolder) {
                    Label("Open Folder", systemImage: "folder")
                }
                
                Spacer()
                
                // Thumbnail Size Slider
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $viewModel.thumbnailSize, in: 100...400, step: 10)
                        .frame(width: 120)
                    Image(systemName: "photo")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    
                    // Clear All Selections Button (right side of slider)
                    Button(action: {
                        viewModel.clearAllSelections()
                    }) {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .disabled(viewModel.photos.isEmpty)
                }
                
                Spacer()
                
                Text("\(viewModel.photos.count) Photos")
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Button(action: {
                    viewModel.executeMoves()
                }) {
                    Label("Move Discarded (没)", systemImage: "trash")
                }
                .disabled(viewModel.photos.filter { $0.status == .groupB }.isEmpty || viewModel.isProcessing)
                .tint(.red)
            }
            .padding()
            .background(Material.bar)
            
            // Main Content with Side Panel (use native NSSplitView via representable on macOS)
#if os(macOS)
            SplitViewRepresentable(
                left:
                    GeometryReader { geometry in
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVGrid(columns: columns, spacing: 10) {
                                    ForEach(viewModel.photos) { photo in
                                        PhotoGridItem(
                                            photo: photo,
                                            thumbnailSize: viewModel.thumbnailSize,
                                            isSelected: viewModel.selectedPhotoID == photo.id
                                        )
                                        .id(photo.id)
                                        .onTapGesture {
                                            viewModel.selectedPhotoID = photo.id
                                            viewModel.toggleStatus(for: photo)
                                        }
                                    }
                                }
                                .padding()
                            }
                            .onAppear {
                                actualGridWidth = geometry.size.width
                            }
                            .onChange(of: geometry.size.width) { oldValue, newValue in
                                actualGridWidth = newValue
                            }
                            .onChange(of: viewModel.selectedPhotoID) { oldValue, newValue in
                                if let newValue = newValue {
                                    withAnimation {
                                        proxy.scrollTo(newValue, anchor: .center)
                                    }
                                }
                            }
                        }
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .focused($isGridFocused)
                    .onAppear {
                        isGridFocused = true
                    },
                right: RightSidePanel(
                    selectedPhoto: viewModel.selectedPhoto,
                    discardedPhotos: viewModel.photos.filter { $0.status == .groupB }
                ),
                minLeft: 400,
                minRight: 200
            )
            .frame(minWidth: 400)
            .onKeyPress(.upArrow) {
                viewModel.moveSelection(direction: .up, columns: actualColumns)
                return .handled
            }
            .onKeyPress(.downArrow) {
                viewModel.moveSelection(direction: .down, columns: actualColumns)
                return .handled
            }
            .onKeyPress(.leftArrow) {
                viewModel.moveSelection(direction: .left, columns: actualColumns)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                viewModel.moveSelection(direction: .right, columns: actualColumns)
                return .handled
            }
            .onKeyPress(.space) {
                // Space: Toggle status
                viewModel.toggleSelectedPhotoStatus()
                return .handled
            }
            .onKeyPress(.return) {
                // Enter: Show full screen preview
                showImagePreview = true
                return .handled
            }
#else
            HSplitView {
                // Main Grid
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(viewModel.photos) { photo in
                            PhotoGridItem(
                                photo: photo,
                                thumbnailSize: viewModel.thumbnailSize,
                                isSelected: viewModel.selectedPhotoID == photo.id
                            )
                            .onTapGesture {
                                viewModel.selectedPhotoID = photo.id
                                viewModel.toggleStatus(for: photo)
                            }
                        }
                    }
                    .padding()
                }
                .frame(minWidth: 400)

                // Side Panel for Group B
                if isSidePanelVisible {
                    GroupBSidePanel(photos: viewModel.photos.filter { $0.status == .groupB })
                        .frame(minWidth: 200, idealWidth: 300, maxWidth: 400)
                }
            }
#endif
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
        .onChange(of: showImagePreview) { oldValue, newValue in
            if newValue, let selectedPhoto = viewModel.selectedPhoto {
                openPreviewWindow(for: selectedPhoto)
            }
        }
    }
    
    func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder"
        
        if panel.runModal() == .OK {
            if let url = panel.url {
                viewModel.loadPhotos(from: url)
            }
        }
    }
    
    func openPreviewWindow(for photo: PhotoItem) {
        let previewView = ImagePreviewWindowView(photo: photo, onClose: {
            showImagePreview = false
        })
        let hostingController = NSHostingController(rootView: previewView)
        
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Image Preview"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        
        // Restore saved window size or use default
        let savedSize = PreviewWindowSizeManager.shared.restoreWindowSize()
        window.setContentSize(savedSize)
        window.center()
        
        // Set up delegate to save window size on changes
        let windowDelegate = PreviewWindowDelegate()
        window.delegate = windowDelegate
        
        window.makeKeyAndOrderFront(nil)
        
        // Store window reference to prevent deallocation
        previewWindow = window
        previewWindowDelegate = windowDelegate
    }
    
    @State private var previewWindow: NSWindow?
    @State private var previewWindowDelegate: PreviewWindowDelegate?
}

struct PhotoGridItem: View {
    let photo: PhotoItem
    let thumbnailSize: Double
    var isSelected: Bool = false
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AsyncImage(url: photo.url) { phase in
                switch phase {
                case .empty:
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .overlay(ProgressView())
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                case .failure:
                    Rectangle()
                        .fill(Color.red.opacity(0.2))
                        .overlay(Image(systemName: "exclamationmark.triangle"))
                @unknown default:
                    EmptyView()
                }
            }
            .frame(height: thumbnailSize)
            .frame(maxWidth: .infinity)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColor, lineWidth: 4)
            )
            .overlay(
                // Selection highlight
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.blue, lineWidth: isSelected ? 3 : 0)
                    .padding(-2)
            )
            
            // Status Indicator Icon
            if photo.status != .unknown {
                Image(systemName: statusIcon)
                    .font(.title)
                    .foregroundStyle(statusColor)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(4)
            }
        }
        .opacity(photo.status == .groupB ? 0.5 : 1.0)
    }
    
    var borderColor: Color {
        switch photo.status {
        case .groupA: return .green
        case .groupB: return .red
        case .unknown: return .clear
        }
    }
    
    var statusIcon: String {
        switch photo.status {
        case .groupA: return "checkmark.circle.fill"
        case .groupB: return "xmark.circle.fill"
        case .unknown: return ""
        }
    }
    
    var statusColor: Color {
        switch photo.status {
        case .groupA: return .green
        case .groupB: return .red
        case .unknown: return .clear
        }
    }
}

struct RightSidePanel: View {
    let selectedPhoto: PhotoItem?
    let discardedPhotos: [PhotoItem]
    
    var body: some View {
#if os(macOS)
        VerticalSplitViewRepresentable(
            top: SelectedPhotoPreview(photo: selectedPhoto),
            bottom: GroupBSidePanel(photos: discardedPhotos),
            minTop: 150,
            minBottom: 150
        )
#else
        VStack(spacing: 0) {
            // Top: Selected Photo Preview
            SelectedPhotoPreview(photo: selectedPhoto)
                .frame(minHeight: 200, idealHeight: 400)
            
            Divider()
            
            // Bottom: Discard List
            GroupBSidePanel(photos: discardedPhotos)
        }
        .background(Color(nsColor: .controlBackgroundColor))
#endif
    }
}

struct SelectedPhotoPreview: View {
    let photo: PhotoItem?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "eye")
                    .foregroundStyle(.blue)
                Text("Preview")
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(Material.bar)
            
            Divider()
            
            // Preview Content
            if let photo = photo {
                GeometryReader { geometry in
                    AsyncImage(url: photo.url) { phase in
                        switch phase {
                        case .empty:
                            Rectangle()
                                .fill(Color.gray.opacity(0.2))
                                .overlay(ProgressView())
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                        case .failure:
                            VStack {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                                Text("Failed to load")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                
                // Filename at bottom
                VStack(alignment: .leading, spacing: 4) {
                    Divider()
                    Text(photo.filename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            } else {
                VStack {
                    Spacer()
                    Image(systemName: "photo")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("No photo selected")
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct GroupBSidePanel: View {
    let photos: [PhotoItem]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
                Text("Discard Group (没)")
                    .font(.headline)
                Spacer()
                Text("\(photos.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.2), in: Capsule())
            }
            .padding()
            .background(Material.bar)
            
            Divider()
            
            // Thumbnail List
            if photos.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("No discarded photos")
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(photos) { photo in
                            GroupBThumbnail(photo: photo)
                        }
                    }
                    .padding()
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct GroupBThumbnail: View {
    let photo: PhotoItem
    
    var body: some View {
        HStack(spacing: 8) {
            AsyncImage(url: photo.url) { phase in
                switch phase {
                case .empty:
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .overlay(ProgressView())
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    Rectangle()
                        .fill(Color.red.opacity(0.2))
                        .overlay(Image(systemName: "exclamationmark.triangle"))
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(photo.filename)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            
            Spacer()
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(8)
    }
}

struct ImagePreviewWindowView: View {
    let photo: PhotoItem
    let onClose: () -> Void
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Image content that resizes with window
                AsyncImage(url: photo.url) { phase in
                    switch phase {
                    case .empty:
                        ZStack {
                            Color.black.opacity(0.1)
                            ProgressView()
                        }
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geometry.size.width, height: geometry.size.height - 40)
                    case .failure:
                        VStack {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("Failed to load image")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Bottom bar with filename
                HStack {
                    Text(photo.filename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(8)
                .background(Material.bar)
            }
        }
        .onKeyPress(.escape) {
            onClose()
            NSApp.keyWindow?.close()
            return .handled
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    onClose()
                    NSApp.keyWindow?.close()
                }) {
                    Image(systemName: "xmark.circle")
                }
                .keyboardShortcut("w", modifiers: .command)
                .help("Close (⌘W or Esc)")
            }
        }
    }
}

// Window size management for preview window
class PreviewWindowSizeManager {
    static let shared = PreviewWindowSizeManager()
    
    private let widthKey = "PreviewWindowWidth"
    private let heightKey = "PreviewWindowHeight"
    private let defaultWidth: CGFloat = 800
    private let defaultHeight: CGFloat = 600
    
    func saveWindowSize(_ size: NSSize) {
        UserDefaults.standard.set(Double(size.width), forKey: widthKey)
        UserDefaults.standard.set(Double(size.height), forKey: heightKey)
    }
    
    func restoreWindowSize() -> NSSize {
        let width = UserDefaults.standard.double(forKey: widthKey)
        let height = UserDefaults.standard.double(forKey: heightKey)
        
        // If no saved size, return default
        if width == 0 || height == 0 {
            return NSSize(width: defaultWidth, height: defaultHeight)
        }
        
        return NSSize(width: width, height: height)
    }
}

// Window delegate to track size changes
class PreviewWindowDelegate: NSObject, NSWindowDelegate {
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        PreviewWindowSizeManager.shared.saveWindowSize(window.frame.size)
    }
}

#Preview {
    ContentView()
}
