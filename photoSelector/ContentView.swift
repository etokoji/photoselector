//
//  ContentView.swift
//  photoSelector
//
//  Created by 江藤公二 on 2025/12/01.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var viewModel: PhotoSorterViewModel
    @State private var showImagePreview = false
    @FocusState private var isGridFocused: Bool
    @State private var actualGridWidth: CGFloat = 800
    @State private var previewWindow: NSWindow?
    @State private var previewWindowDelegate: PreviewWindowDelegate?
    // Bridge state to avoid publishing during view updates
    @State private var localSortMode: DateSortMode = .fileCreation
    
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
        let spacing: CGFloat = 10 // spacing configured on GridItem
        let itemWidth = CGFloat(viewModel.thumbnailSize)
        let padding: CGFloat = 32 // Total horizontal padding (16 on each side) from .padding()
        let availableWidth = actualGridWidth - padding

        // Total width consumed by N items: N*itemWidth + (N-1)*spacing
        // Solve for N: N = floor((availableWidth + spacing) / (itemWidth + spacing))
        let raw = (availableWidth + spacing) / (itemWidth + spacing)
        let count = max(1, Int(floor(raw)))
        return count
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
                
                // Sort mode picker (local state bridged to ViewModel)
                Picker("Date", selection: $localSortMode) {
                    Text("File").tag(DateSortMode.fileCreation)
                    Text("EXIF").tag(DateSortMode.exifPreferred)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
                .help("Sort by file creation date (fast) or EXIF date (slow)")
                
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
            // Nested SplitView for 3-pane layout
            SplitViewRepresentable(
                left: FolderTreeView(folderTree: viewModel.folderTree, selectedFolderURL: $viewModel.selectedFolderURL)
                    .frame(minWidth: 150, idealWidth: 250),
                right: SplitViewRepresentable(
                    left: PhotoGridView(
                        photos: viewModel.photos,
                        columns: columns,
                        thumbnailSize: viewModel.thumbnailSize,
                        primarySelectedPhotoID: $viewModel.primarySelectedPhotoID,
                        selectedPhotoIDs: $viewModel.selectedPhotoIDs,
                        isGridFocused: _isGridFocused,
                        actualGridWidth: $actualGridWidth,
                        onSelect: { id, orderedIDs, isCommand, isShift, context in
                            viewModel.applySelectionClick(
                                id: id,
                                orderedIDs: orderedIDs,
                                isCommandPressed: isCommand,
                                isShiftPressed: isShift,
                                context: context
                            )
                        },
                        onSetStatusForSelection: { status in
                            viewModel.setStatusForSelection(status)
                        },
                        isContextActive: viewModel.selectionContext == .grid
                    )
                    .frame(minWidth: 400),
                    right: RightSidePanel(
                        selectedPhoto: viewModel.selectedPhoto,
                        keepPhotos: viewModel.photos.filter { $0.status == .groupA },
                        discardedPhotos: viewModel.photos.filter { $0.status == .groupB },
                        primarySelectedPhotoID: $viewModel.primarySelectedPhotoID,
                        selectedPhotoIDs: $viewModel.selectedPhotoIDs,
                        onSelect: { id, orderedIDs, isCommand, isShift, context in
                            viewModel.applySelectionClick(
                                id: id,
                                orderedIDs: orderedIDs,
                                isCommandPressed: isCommand,
                                isShiftPressed: isShift,
                                context: context
                            )
                        },
                        onSetStatusForSelection: { status in
                            viewModel.setStatusForSelection(status)
                        },
                        activeContext: viewModel.selectionContext,
                        onOpenPreview: { showImagePreview = true }
                    )
                    .frame(minWidth: 200),
                    minLeft: 400,
                    minRight: 200,
                    splitPositionKey: "ContentSplitPosition"
                ),
                minLeft: 150,
                minRight: 600,
                splitPositionKey: "MainSplitPosition"
            )
            .frame(minWidth: 800)
            .onKeyPress(.upArrow) {
                viewModel.moveSelection(direction: .up, columns: actualColumns)
                return .handled
            }
.onChange(of: viewModel.selectedFolderURL) { oldValue, newValue in
                if let url = newValue {
                    DispatchQueue.main.async {
                        viewModel.loadPhotos(from: url)
                    }
                }
            }
.onAppear {
                // Initialize bridge state
                localSortMode = viewModel.sortMode
            }
            .onChange(of: localSortMode) { _, newValue in
                // Propagate user changes to ViewModel on next runloop and only if changed
                if viewModel.sortMode != newValue {
                    DispatchQueue.main.async {
                        viewModel.sortMode = newValue
                    }
                }
            }
            .onChange(of: viewModel.sortMode) { _, newValue in
                // Keep local in sync (no publish from this assignment)
                if localSortMode != newValue {
                    localSortMode = newValue
                }
                // Defer resort to avoid publishing during Picker update cycle
                DispatchQueue.main.async {
                    viewModel.resortPhotos()
                }
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
                                isSelected: viewModel.selectedPhotoIDs.contains(photo.id),
                                isPrimary: viewModel.primarySelectedPhotoID == photo.id,
                                onEnsureSelectedForContextMenu: {
                                    if !viewModel.selectedPhotoIDs.contains(photo.id) {
                                        viewModel.applySelectionClick(
                                            id: photo.id,
                                            orderedIDs: viewModel.photos.map { $0.id },
                                            isCommandPressed: false,
                                            isShiftPressed: false
                                        )
                                    }
                                },
                        onSetStatusForSelection: { status in
                            viewModel.setStatusForSelection(status)
                        },
                        activeContext: viewModel.selectionContext
                    )
                            .onTapGesture {
                                viewModel.applySelectionClick(
                                    id: photo.id,
                                    orderedIDs: viewModel.photos.map { $0.id },
                                    isCommandPressed: false,
                                    isShiftPressed: false
                                )
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
                viewModel.buildFolderTree(from: url)
            }
        }
    }
    
    func openPreviewWindow(for photo: PhotoItem) {
        // Close existing window if any
        if let existingWindow = previewWindow {
            existingWindow.close()
        }
        
        let previewView = ImagePreviewWindowView(viewModel: viewModel, onClose: {
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
        
        // Set up delegate to save window size on changes and handle key events
        let windowDelegate = PreviewWindowDelegate(onClose: {
            showImagePreview = false
            self.previewWindow = nil // Clear reference on close
        }, mainWindow: NSApp.mainWindow)
        window.delegate = windowDelegate
        
        window.makeKeyAndOrderFront(nil)
        
        // Store window reference to prevent deallocation
        previewWindow = window
        previewWindowDelegate = windowDelegate
    }
}

// MARK: - Subviews for ContentView

struct FolderTreeView: View {
    let folderTree: [FileSystemItem]
    @Binding var selectedFolderURL: URL?
    @State private var localSelection: URL?

    var body: some View {
        List(folderTree, children: \.children, selection: $localSelection) { item in
            HStack {
                Image(systemName: item.isFolder ? "folder" : "photo")
                Text(item.name)
            }
            .padding(.vertical, 2)
        }
        .listStyle(SidebarListStyle())
        // Keep local state and view model in sync without publishing during a view update
        .onAppear {
            // Initialize local selection from model
            localSelection = selectedFolderURL
        }
        .onChange(of: localSelection) { _, newValue in
            // Propagate user-driven selection changes to the view model on the next runloop
            guard selectedFolderURL != newValue else { return }
            DispatchQueue.main.async {
                selectedFolderURL = newValue
            }
        }
        .onChange(of: selectedFolderURL) { _, newValue in
            // Reflect programmatic changes into the local selection synchronously (no publish involved)
            if localSelection != newValue {
                localSelection = newValue
            }
        }
    }
}

struct PhotoGridView: View {
    let photos: [PhotoItem]
    let columns: [GridItem]
    let thumbnailSize: Double
    @Binding var primarySelectedPhotoID: UUID?
    @Binding var selectedPhotoIDs: Set<UUID>
    @FocusState var isGridFocused: Bool
    @Binding var actualGridWidth: CGFloat
    let onSelect: (_ id: UUID, _ orderedIDs: [UUID], _ isCommandPressed: Bool, _ isShiftPressed: Bool, _ context: SelectionContext) -> Void
    let onSetStatusForSelection: (_ status: PhotoStatus) -> Void
    var isContextActive: Bool = false
    
    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    gridContent
                    .padding()
                }
                .background(isContextActive ? Color.accentColor.opacity(0.1) : Color.clear)
                .cornerRadius(8)
                .onAppear {
                    actualGridWidth = geometry.size.width
                }
                .onChange(of: geometry.size.width) { oldValue, newValue in
                    actualGridWidth = newValue
                }
                .onChange(of: primarySelectedPhotoID) { oldValue, newValue in
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
        }
    }

    var gridContent: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(photos) { photo in
                itemContent(for: photo)
            }
        }
    }

    func itemContent(for photo: PhotoItem) -> some View {
        PhotoGridItem(
            photo: photo,
            thumbnailSize: thumbnailSize,
            isSelected: selectedPhotoIDs.contains(photo.id),
            isPrimary: primarySelectedPhotoID == photo.id,
            onEnsureSelectedForContextMenu: {
                if !selectedPhotoIDs.contains(photo.id) {
                    onSelect(photo.id, photos.map { $0.id }, false, false, .grid)
                }
            },
            onSetStatusForSelection: { status in
                onSetStatusForSelection(status)
            }
        )
        .id(photo.id)
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            let isCommand = flags.contains(.command)
            let isShift = flags.contains(.shift)
            onSelect(photo.id, photos.map { $0.id }, isCommand, isShift, .grid)
        }
    }
}

struct PhotoGridItem: View {
    let photo: PhotoItem
    let thumbnailSize: Double
    var isSelected: Bool = false
    var isPrimary: Bool = false
    var onEnsureSelectedForContextMenu: (() -> Void)? = nil
    var onSetStatusForSelection: ((PhotoStatus) -> Void)? = nil
    @State private var thumbnail: NSImage?
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let thumbnail = thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .overlay(ProgressView())
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
                    .stroke(Color.blue, lineWidth: isSelected ? (isPrimary ? 4 : 2) : 0)
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
        .onAppear(perform: loadThumbnail)
        .overlay(RightClickCaptureView {
            onEnsureSelectedForContextMenu?()
        })
        .contextMenu {
            Button("採用にする") {
                handleContextMenuAction(.groupA)
            }
            Button("没にする") {
                handleContextMenuAction(.groupB)
            }
            Divider()
            Button("未分類に戻す") {
                handleContextMenuAction(.unknown)
            }
        }
        .onChange(of: thumbnailSize) { oldValue, newValue in
            loadThumbnail()
        }
    }
    
    private func handleContextMenuAction(_ status: PhotoStatus) {
        DispatchQueue.main.async {
            onEnsureSelectedForContextMenu?()
            onSetStatusForSelection?(status)
        }
    }
    
    private func loadThumbnail() {
        ThumbnailGenerator.shared.thumbnail(for: photo.url, size: thumbnailSize) { image in
            self.thumbnail = image
        }
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
    let keepPhotos: [PhotoItem]
    let discardedPhotos: [PhotoItem]
    @Binding var primarySelectedPhotoID: UUID?
    @Binding var selectedPhotoIDs: Set<UUID>
    let onSelect: (_ id: UUID, _ orderedIDs: [UUID], _ isCommandPressed: Bool, _ isShiftPressed: Bool, _ context: SelectionContext) -> Void
    let onSetStatusForSelection: (_ status: PhotoStatus) -> Void
    var activeContext: SelectionContext = .grid
    let onOpenPreview: () -> Void
    
    var body: some View {
#if os(macOS)
        VerticalSplitViewRepresentable(
            top: SelectedPhotoPreview(photo: selectedPhoto, onOpenPreview: onOpenPreview),
            bottom: SplitViewRepresentable(
                left: GroupASidePanel(
                    photos: keepPhotos,
                    primarySelectedPhotoID: $primarySelectedPhotoID,
                    selectedPhotoIDs: $selectedPhotoIDs,
                    onSelect: onSelect,
                    onSetStatusForSelection: onSetStatusForSelection,
                    isContextActive: activeContext == .keep
                ),
                right: GroupBSidePanel(
                    photos: discardedPhotos,
                    primarySelectedPhotoID: $primarySelectedPhotoID,
                    selectedPhotoIDs: $selectedPhotoIDs,
                    onSelect: onSelect,
                    onSetStatusForSelection: onSetStatusForSelection,
                    isContextActive: activeContext == .discard
                ),
                minLeft: 100,
                minRight: 100,
                splitPositionKey: "KeepDiscardSplitPosition"
            ),
            minTop: 200,
            minBottom: 200,
            splitPositionKey: "RightPanelVerticalSplitPosition"
        )
#else
        VStack(spacing: 0) {
            // Top: Selected Photo Preview
            SelectedPhotoPreview(photo: selectedPhoto, onOpenPreview: onOpenPreview)
                .frame(minHeight: 200, idealHeight: 400)
            
            Divider()
            
            // Bottom: Split Keep and Discard
            HSplitView {
                GroupASidePanel(
                    photos: keepPhotos,
                    primarySelectedPhotoID: $primarySelectedPhotoID,
                    selectedPhotoIDs: $selectedPhotoIDs,
                    onSelect: onSelect,
                    onSetStatusForSelection: onSetStatusForSelection
                )
                GroupBSidePanel(
                    photos: discardedPhotos,
                    primarySelectedPhotoID: $primarySelectedPhotoID,
                    selectedPhotoIDs: $selectedPhotoIDs,
                    onSelect: onSelect,
                    onSetStatusForSelection: onSetStatusForSelection
                )
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
#endif
    }
}

struct SelectedPhotoPreview: View {
    let photo: PhotoItem?
    var onOpenPreview: (() -> Void)? = nil
    @EnvironmentObject private var viewModel: PhotoSorterViewModel
    
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
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        onOpenPreview?()
                    }
                }
                
                // Filename and date at bottom
                VStack(alignment: .leading, spacing: 4) {
                    Divider()
                    HStack(spacing: 8) {
                        Text(photo.filename)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        
                        if let date = viewModel.displayedDate(for: photo) {
                            Text(formatDate(date))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        
                        Spacer()
                        
                        // Status Badge - only show if not unknown, but always reserve space
                        if photo.status != .unknown {
                            HStack(spacing: 4) {
                                Image(systemName: photo.status == .groupA ? "checkmark.circle.fill" : "xmark.circle.fill")
                                Text(photo.status == .groupA ? "採用" : "没")
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(photo.status == .groupA ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                            .foregroundStyle(photo.status == .groupA ? .green : .red)
                            .cornerRadius(4)
                        } else {
                            // Reserve space even when status is unknown
                            HStack(spacing: 4) {
                                Image(systemName: "circle.fill")
                                Text("未分類")
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .opacity(0)
                        }
                    }
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

struct GroupASidePanel: View {
    let photos: [PhotoItem]
    @Binding var primarySelectedPhotoID: UUID?
    @Binding var selectedPhotoIDs: Set<UUID>
    let onSelect: (_ id: UUID, _ orderedIDs: [UUID], _ isCommandPressed: Bool, _ isShiftPressed: Bool, _ context: SelectionContext) -> Void
    let onSetStatusForSelection: (_ status: PhotoStatus) -> Void
    var isContextActive: Bool = false
    
    // Add ViewModel environment object to update column count
    @EnvironmentObject private var viewModel: PhotoSorterViewModel
    
    let columns = [
        GridItem(.adaptive(minimum: 80), spacing: 4)
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                Text("Keep Group (採用)")
                    .font(.headline)
                Spacer()
                Text("\(photos.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.2), in: Capsule())
            }
            .padding()
            .background(Material.bar)
            
            Divider()
            
            // Thumbnail Grid
            if photos.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "photo.stack")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("No keep photos")
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 4) {
                                ForEach(photos) { photo in
                                    GroupAThumbnail(
                                        photo: photo,
                                        isSelected: selectedPhotoIDs.contains(photo.id),
                                        isPrimary: primarySelectedPhotoID == photo.id,
                                        onEnsureSelectedForContextMenu: {
                                            if !selectedPhotoIDs.contains(photo.id) {
                                                onSelect(photo.id, photos.map { $0.id }, false, false, .keep)
                                            }
                                        },
                                        onSetStatusForSelection: { status in
                                            onSetStatusForSelection(status)
                                        }
                                    )
                                    .id(photo.id)
                                    .onTapGesture {
                                        let flags = NSEvent.modifierFlags
                                        let isCommand = flags.contains(.command)
                                        let isShift = flags.contains(.shift)
                                        onSelect(photo.id, photos.map { $0.id }, isCommand, isShift, .keep)
                                    }
                                }
                            }
                            .padding(4)
                        }
                        .onChange(of: geometry.size.width) { _, newValue in
                            let itemWidth: CGFloat = 84 // 80 min + 4 spacing
                            let padding: CGFloat = 8 // approximate padding
                            let availableWidth = newValue - padding
                            let count = max(1, Int(availableWidth / itemWidth))
                            DispatchQueue.main.async {
                                if viewModel.groupAColumns != count {
                                    viewModel.groupAColumns = count
                                }
                            }
                        }
                    .onAppear {
                        let itemWidth: CGFloat = 84
                        let padding: CGFloat = 8
                        let availableWidth = geometry.size.width - padding
                        let count = max(1, Int(availableWidth / itemWidth))
                        DispatchQueue.main.async {
                            if viewModel.groupAColumns != count {
                                viewModel.groupAColumns = count
                            }
                        }
                    }
                        .onChange(of: primarySelectedPhotoID) { _, newValue in
                            if let newValue = newValue, isContextActive {
                                withAnimation {
                                    proxy.scrollTo(newValue, anchor: .center)
                                }
                            }
                        }
                    }
                }
                .background(isContextActive ? Color.accentColor.opacity(0.1) : Color.clear)
                .cornerRadius(8)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct GroupAThumbnail: View {
    let photo: PhotoItem
    var isSelected: Bool = false
    var isPrimary: Bool = false
    var onEnsureSelectedForContextMenu: (() -> Void)? = nil
    var onSetStatusForSelection: ((PhotoStatus) -> Void)? = nil
    @State private var thumbnail: NSImage?
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let thumbnail = thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .overlay(ProgressView())
                }
            }
            .frame(height: 80)
            .frame(maxWidth: .infinity)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.blue, lineWidth: isSelected ? (isPrimary ? 3 : 2) : 0)
                    .padding(-1)
            )
            
            // Status Icon Overlay
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .padding(4)
                .background(.ultraThinMaterial, in: Circle())
                .padding(2)
        }
        .onAppear(perform: loadThumbnail)
        .contextMenu {
            Button("採用にする") {
                handleContextMenuAction(.groupA)
            }
            Button("没にする") {
                handleContextMenuAction(.groupB)
            }
            Divider()
            Button("未分類に戻す") {
                handleContextMenuAction(.unknown)
            }
        }
    }
    
    private func handleContextMenuAction(_ status: PhotoStatus) {
        DispatchQueue.main.async {
            onEnsureSelectedForContextMenu?()
            onSetStatusForSelection?(status)
        }
    }
    
    private func loadThumbnail() {
        ThumbnailGenerator.shared.thumbnail(for: photo.url, size: 160) { image in
            self.thumbnail = image
        }
    }
}

struct GroupBSidePanel: View {
    let photos: [PhotoItem]
    @Binding var primarySelectedPhotoID: UUID?
    @Binding var selectedPhotoIDs: Set<UUID>
    let onSelect: (_ id: UUID, _ orderedIDs: [UUID], _ isCommandPressed: Bool, _ isShiftPressed: Bool, _ context: SelectionContext) -> Void
    let onSetStatusForSelection: (_ status: PhotoStatus) -> Void
    var isContextActive: Bool = false
    
    @EnvironmentObject private var viewModel: PhotoSorterViewModel
    
    let columns = [
        GridItem(.adaptive(minimum: 80), spacing: 4)
    ]
    
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
            
            // Thumbnail Grid
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
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 4) {
                                ForEach(photos) { photo in
                                    GroupBThumbnail(
                                        photo: photo,
                                        isSelected: selectedPhotoIDs.contains(photo.id),
                                        isPrimary: primarySelectedPhotoID == photo.id,
                                        onEnsureSelectedForContextMenu: {
                                            if !selectedPhotoIDs.contains(photo.id) {
                                                onSelect(photo.id, photos.map { $0.id }, false, false, .discard)
                                            }
                                        },
                                        onSetStatusForSelection: { status in
                                            onSetStatusForSelection(status)
                                        }
                                    )
                                    .id(photo.id)
                                    .onTapGesture {
                                        let flags = NSEvent.modifierFlags
                                        let isCommand = flags.contains(.command)
                                        let isShift = flags.contains(.shift)
                                        onSelect(photo.id, photos.map { $0.id }, isCommand, isShift, .discard)
                                    }
                                }
                            }
                            .padding(4)
                        }
                        .onChange(of: geometry.size.width) { _, newValue in
                            let itemWidth: CGFloat = 84 // 80 min + 4 spacing
                            let padding: CGFloat = 8 // approximate padding
                            let availableWidth = newValue - padding
                            let count = max(1, Int(availableWidth / itemWidth))
                            DispatchQueue.main.async {
                                if viewModel.groupBColumns != count {
                                    viewModel.groupBColumns = count
                                }
                            }
                        }
                    .onAppear {
                        let itemWidth: CGFloat = 84
                        let padding: CGFloat = 8
                        let availableWidth = geometry.size.width - padding
                        let count = max(1, Int(availableWidth / itemWidth))
                        DispatchQueue.main.async {
                            if viewModel.groupBColumns != count {
                                viewModel.groupBColumns = count
                            }
                        }
                    }
                        .onChange(of: primarySelectedPhotoID) { _, newValue in
                            if let newValue = newValue, isContextActive {
                                withAnimation {
                                    proxy.scrollTo(newValue, anchor: .center)
                                }
                            }
                        }
                    }
                }
                .background(isContextActive ? Color.accentColor.opacity(0.1) : Color.clear)
                .cornerRadius(8)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct GroupBThumbnail: View {
    let photo: PhotoItem
    var isSelected: Bool = false
    var isPrimary: Bool = false
    var onEnsureSelectedForContextMenu: (() -> Void)? = nil
    var onSetStatusForSelection: ((PhotoStatus) -> Void)? = nil
    @State private var thumbnail: NSImage?
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let thumbnail = thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .overlay(ProgressView())
                }
            }
            .frame(height: 80)
            .frame(maxWidth: .infinity)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.blue, lineWidth: isSelected ? (isPrimary ? 3 : 2) : 0)
                    .padding(-1)
            )
            
            // Status Icon Overlay
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .padding(4)
                .background(.ultraThinMaterial, in: Circle())
                .padding(2)
        }
        .onAppear(perform: loadThumbnail)
        .overlay(RightClickCaptureView {
            onEnsureSelectedForContextMenu?()
        })
        .contextMenu {
            Button("採用にする") {
                handleContextMenuAction(.groupA)
            }
            Button("没にする") {
                handleContextMenuAction(.groupB)
            }
            Divider()
            Button("未分類に戻す") {
                handleContextMenuAction(.unknown)
            }
        }
    }
    
    private func handleContextMenuAction(_ status: PhotoStatus) {
        DispatchQueue.main.async {
            onEnsureSelectedForContextMenu?()
            onSetStatusForSelection?(status)
        }
    }
    
    private func loadThumbnail() {
        ThumbnailGenerator.shared.thumbnail(for: photo.url, size: 160) { image in
            self.thumbnail = image
        }
    }
}

struct ImagePreviewWindowView: View {
    @ObservedObject var viewModel: PhotoSorterViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Zoomable image view
            if let photo = viewModel.selectedPhoto {
                ZoomableAsyncImageView(url: photo.url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Bottom bar with filename and date
                HStack(spacing: 8) {
                    Text(photo.filename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    
                    if let date = viewModel.displayedDate(for: photo) {
                        Text("(\(formatDate(date)))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    
                    Spacer()
                }
                .padding(8)
                .background(Material.bar)
            } else {
                VStack {
                    Image(systemName: "photo")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("No photo selected")
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
                .help("Close (⌘W or Enter)")
            }
        }
    }
}

// Helper function to format date
private func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ja_JP")
    formatter.dateFormat = "yyyy年M月d日 H時m分s秒"
    return formatter.string(from: date)
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

// Window delegate to track size changes and handle key events
class PreviewWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    private var localMonitor: Any?
    private weak var mainWindow: NSWindow?
    
    init(onClose: @escaping () -> Void, mainWindow: NSWindow?) {
        self.onClose = onClose
        self.mainWindow = mainWindow
        super.init()
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // Only monitor Enter/Return to close the preview window.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self = self, let window = window else { return event }

            // Only handle events for this window
            if event.window == window {
                if event.keyCode == 36 || event.keyCode == 76 {
                    self.onClose()
                    window.close()
                    return nil
                }
            }
            return event
        }
    }
    
    func windowWillClose(_ notification: Notification) {
        // Clean up event monitor
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }
    
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        PreviewWindowSizeManager.shared.saveWindowSize(window.frame.size)
    }
}

#Preview {
    ContentView()
        .environmentObject(PhotoSorterViewModel())
}

// MARK: - Centering Clip View

// A custom NSClipView that centers its document view if it's smaller than the clip view.
class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        if let documentView = self.documentView {
            if rect.size.width > documentView.frame.size.width {
                rect.origin.x = (documentView.frame.width - rect.width) / 2
            }
            if rect.size.height > documentView.frame.size.height {
                rect.origin.y = (documentView.frame.height - rect.height) / 2
            }
        }
        return rect
    }
}

// Capture right mouse down events to ensure selection before context menu shows
struct RightClickCaptureView: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> RightClickCaptureNSView {
        let view = RightClickCaptureNSView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: RightClickCaptureNSView, context: Context) {
        nsView.onRightClick = onRightClick
    }

    class RightClickCaptureNSView: NSView {
        var onRightClick: (() -> Void)?

        override func rightMouseDown(with event: NSEvent) {
            onRightClick?()
            super.rightMouseDown(with: event)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }
    }
}
// MARK: - Zoomable Image View (NSViewRepresentable)

struct ZoomableAsyncImageView: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .clear

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        
        // Use the custom centering clip view
        let clipView = CenteringClipView()
        clipView.documentView = imageView
        clipView.backgroundColor = .clear
        scrollView.contentView = clipView
        clipView.documentView = imageView
        clipView.backgroundColor = .clear
        
        scrollView.contentView = clipView
        
        // Add gesture for double-click to reset zoom
        let doubleClickGesture = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleClick))
        doubleClickGesture.numberOfClicksRequired = 2
        imageView.addGestureRecognizer(doubleClickGesture)
        
        // Configure magnification
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1.0
        scrollView.maxMagnification = 10.0
        
        context.coordinator.imageView = imageView
        context.coordinator.loadImage(from: url)
        
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if context.coordinator.currentURL != url {
            context.coordinator.loadImage(from: url)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject {
        var parent: ZoomableAsyncImageView
        weak var imageView: NSImageView?
        var currentURL: URL?

        init(_ parent: ZoomableAsyncImageView) {
            self.parent = parent
        }
        
        func loadImage(from url: URL) {
            self.currentURL = url
            DispatchQueue.global().async {
                if let image = NSImage(contentsOf: url) {
                    DispatchQueue.main.async {
                        guard let imageView = self.imageView else { return }
                        imageView.image = image
                        // Set frame size to image size for centering logic to work
                        imageView.frame.size = image.size
                        self.resetZoom()
                    }
                }
            }
        }

        @objc func handleDoubleClick(gesture: NSClickGestureRecognizer) {
            resetZoom()
        }
        
        private func resetZoom() {
            guard let scrollView = imageView?.enclosingScrollView else { return }
            // Use animator to get a smooth zoom-out effect
            scrollView.animator().magnification = 1.0
        }
    }
}
