//
//  ContentView.swift
//  photoSelector
//
//  Created by 江藤公二 on 2025/12/01.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO
import Darwin

struct ContentView: View {
    @StateObject private var viewModel = PhotoSorterViewModel()
    @State private var showImagePreview = false
    @FocusState private var isGridFocused: Bool
    @State private var actualGridWidth: CGFloat = 800
    @State private var previewWindow: NSWindow?
    @State private var previewWindowDelegate: PreviewWindowDelegate?
    @State private var selectedThumbnailScreenFrame: NSRect?
    // Bridge state to avoid publishing during view updates
    @State private var localSortMode: DateSortMode = .fileCreation
    @State private var windowID = UUID().uuidString
    @State private var didApplyLayoutDefaults = false
    @State private var initialWindowSize: CGSize?
    @State private var defaultSidebarExifPaneHeight: CGFloat?
    @Environment(\.undoManager) private var undoManager
    
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

    private var discardedPhotoCount: Int {
        viewModel.photos.filter { $0.status == .groupB }.count
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar Area
            HStack {
                MemoryUsageView()

                Spacer()
                
                Button(action: {
                    viewModel.clearAllSelections()
                }) {
                    Label("Clear Selection", systemImage: "xmark.circle")
                }
                .labelStyle(.titleAndIcon)
                .fixedSize()
                .disabled(viewModel.photos.isEmpty)

                Button(action: {
                    viewModel.executeMoves(undoManager: undoManager)
                }) {
                    Label("Move Discarded (没 \(discardedPhotoCount))", systemImage: "trash.fill")
                }
                .font(.headline)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(discardedPhotoCount == 0 || viewModel.isProcessing)
                .tint(.red)
            }
            .padding()
            .background(Material.bar)
            
            // Main Content with Side Panel (use native NSSplitView via representable on macOS)
#if os(macOS)
            // Nested SplitView for 3-pane layout (left sidebar + content)
            SplitViewRepresentable(
                left: FolderPanelsContainer(
                    onOpenFolder: selectFolder,
                    exifPaneHeight: $defaultSidebarExifPaneHeight
                ),
                right: SplitViewRepresentable(
                    left: PhotoGridView(
                        photos: viewModel.currentFolderPhotos,
                        columns: columns,
                        currentFolder: viewModel.currentFolder,
                        thumbnailSize: $viewModel.thumbnailSize,
                        sortMode: $localSortMode,
                        primarySelectedPhotoID: $viewModel.primarySelectedPhotoID,
                        selectedPhotoIDs: $viewModel.selectedPhotoIDs,
                        isGridFocused: _isGridFocused,
                        actualGridWidth: $actualGridWidth,
                        selectedThumbnailScreenFrame: $selectedThumbnailScreenFrame,
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
                        onOpenPreview: { showImagePreview = true },
                        windowID: windowID
                    )
                    .frame(minWidth: 200),
                    minLeft: 400,
                    minRight: 200,
                    splitPositionKey: "\(windowID)_ContentSplitPosition"
                ),
                minLeft: 300,
                minRight: 600,
                splitPositionKey: "\(windowID)_MainSplitPosition"
            )
            .frame(minWidth: 800)
            .onKeyPress(.upArrow) {
                viewModel.moveSelection(direction: .up, columns: actualColumns)
                return .handled
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
                // Space: Toggle preview window
                togglePreviewWindow()
                return .handled
            }
            .onKeyPress(.return) {
                // Enter: Toggle preview window
                togglePreviewWindow()
                return .handled
            }
            .onKeyPress(KeyEquivalent("a"), phases: .down) { press in
                if press.modifiers.contains(.command) {
                    if viewModel.hasSelectableItemsInCurrentContext {
                        viewModel.selectAllCurrentContext(deferred: true)
                        return .handled
                    }
                }
                return .ignored
            }
            .onKeyPress(KeyEquivalent("d"), phases: .down) { press in
                if press.modifiers.contains(.command) {
                    if viewModel.hasSelection {
                        viewModel.clearSelection(deferred: true)
                        return .handled
                    }
                }
                return .ignored
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
        .environmentObject(viewModel)
        .focusedSceneObject(viewModel)
#if os(macOS)
        .background(WindowTitleSetter(title: viewModel.windowTitle))
        .background(WindowInitialSizeSetter(size: initialWindowSize))
        .focusedValue(\.saveWindowLayoutDefaults) {
            WindowLayoutDefaults.saveCurrentLayout(
                windowID: windowID,
                thumbnailSize: viewModel.thumbnailSize,
                sortMode: viewModel.sortMode,
                sidebarExifPaneHeight: defaultSidebarExifPaneHeight,
                windowSize: WindowLayoutDefaults.mainWindowContentSize(from: NSApp.keyWindow)
            )
        }
        .onAppear {
            applySavedLayoutDefaultsIfNeeded()
        }
#endif
    }
    
#if os(macOS)
    private func applySavedLayoutDefaultsIfNeeded() {
        guard !didApplyLayoutDefaults else { return }
        didApplyLayoutDefaults = true
        guard let settings = WindowLayoutDefaults.applyLayout(to: windowID) else { return }
        viewModel.applyWindowLayoutSettings(settings)
        localSortMode = settings.sortMode
        initialWindowSize = settings.windowSize
        defaultSidebarExifPaneHeight = settings.sidebarExifPaneHeight
    }
#endif
    
    func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK {
            if let url = panel.url {
                viewModel.openFolderPane(from: url)
            }
        }
    }

    private func togglePreviewWindow() {
        if let window = previewWindow {
            window.performClose(nil)
            return
        }

        guard viewModel.selectedPhoto != nil else { return }
        showImagePreview = true
    }
    
    func openPreviewWindow(for photo: PhotoItem) {
        let previewView = ImagePreviewWindowView(viewModel: viewModel, onClose: {
            showImagePreview = false
        })
        let hostingController = NSHostingController(rootView: previewView)

        let windowDelegate = PreviewWindowDelegate(
            onClose: {
                showImagePreview = false
                self.previewWindow = nil // Clear reference on close
            },
            mainWindow: NSApp.mainWindow,
            closingTargetFrame: { self.selectedThumbnailScreenFrame }
        )

        if let window = previewWindow {
            window.contentViewController = hostingController
            window.delegate = windowDelegate
            previewWindowDelegate = windowDelegate
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Image Preview"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]

        // Restore saved window size or use default
        let savedSize = PreviewWindowSizeManager.shared.restoreWindowSize()
        window.setContentSize(savedSize)
        window.center()

        window.delegate = windowDelegate
        animatePreviewWindowOpen(window, from: selectedThumbnailScreenFrame)

        previewWindow = window
        previewWindowDelegate = windowDelegate
    }

    private func animatePreviewWindowOpen(_ window: NSWindow, from sourceFrame: NSRect?) {
        let finalFrame = window.frame
        let initialFrame = sourceFrame.map { previewWindowInitialFrame(from: $0, finalFrame: finalFrame) }
            ?? finalFrame.insetBy(dx: finalFrame.width * 0.025, dy: finalFrame.height * 0.025)

        window.alphaValue = sourceFrame == nil ? 0 : 0.25
        window.setFrame(initialFrame, display: false)
        window.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = sourceFrame == nil ? 0.22 : 0.5
            context.timingFunction = sourceFrame == nil
                ? CAMediaTimingFunction(name: .easeOut)
                : CAMediaTimingFunction(controlPoints: 0.42, 0.0, 0.2, 1.0)
            window.animator().alphaValue = 1
            window.animator().setFrame(finalFrame, display: true)
        }
    }

    private func previewWindowInitialFrame(from sourceFrame: NSRect, finalFrame: NSRect) -> NSRect {
        let minimumSize: CGFloat = 72
        let scale = max(minimumSize / max(sourceFrame.width, sourceFrame.height, 1), 1)
        let width = min(max(sourceFrame.width * scale, minimumSize), finalFrame.width * 0.25)
        let height = min(max(sourceFrame.height * scale, minimumSize), finalFrame.height * 0.25)
        return NSRect(
            x: sourceFrame.midX - width / 2,
            y: sourceFrame.midY - height / 2,
            width: width,
            height: height
        )
    }
}

private struct MemoryUsageView: View {
    @State private var usage = AppMemoryUsage.current

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "memorychip")
                .font(.caption)
            Text(usage.formatted)
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: Capsule())
        .help("Current memory usage")
        .task {
            while !Task.isCancelled {
                usage = AppMemoryUsage.current
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

private struct AppMemoryUsage {
    let residentBytes: UInt64?

    var formatted: String {
        guard let residentBytes else {
            return "RAM --"
        }

        let megabytes = Double(residentBytes) / 1_048_576
        if megabytes >= 1_024 {
            return String(format: "RAM %.1f GB", megabytes / 1_024)
        } else {
            return String(format: "RAM %.0f MB", megabytes)
        }
    }

    static var current: AppMemoryUsage {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundPointer,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else {
            return AppMemoryUsage(residentBytes: nil)
        }

        return AppMemoryUsage(residentBytes: UInt64(info.resident_size))
    }
}

// MARK: - Subviews for ContentView

struct FolderPanelsContainer: View {
    let onOpenFolder: () -> Void
    @Binding var exifPaneHeight: CGFloat?
    @EnvironmentObject private var viewModel: PhotoSorterViewModel
    @State private var folderPaneHeights: [UUID: CGFloat] = [:]

    var body: some View {
        VStack(spacing: 0) {
            folderOpenToolbar
            Divider()
            GeometryReader { geometry in
                let exifHeight = currentExifDisplayHeight(availableHeight: geometry.size.height)
                let folderListHeight = folderPaneListHeight(availableHeight: geometry.size.height, exifHeight: exifHeight)
                VStack(spacing: 0) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(viewModel.folderPanes.enumerated()), id: \.element.id) { index, pane in
                            SidebarResizablePane(
                                title: panelTitle(for: pane),
                                systemImage: "folder",
                                height: heightBinding(for: pane.id, defaultHeight: defaultFolderPaneHeight(folderListHeight: folderListHeight)),
                                isResizeEnabled: index > 0,
                                onResize: {
                                    resizeFolderPane(
                                        pane.id,
                                        by: $0,
                                        availableHeight: geometry.size.height,
                                        exifHeight: exifHeight,
                                        defaultHeight: defaultFolderPaneHeight(folderListHeight: folderListHeight)
                                    )
                                },
                                tools: {
                                    Button {
                                        viewModel.refreshFolderTree(for: pane.kind)
                                    } label: {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.system(size: 11, weight: .semibold))
                                            .frame(width: 14, height: 14)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .help("フォルダツリーを再読み込み")
                                    
                                    if viewModel.shouldShowEjectVolumeButton(for: pane.kind) {
                                        Button {
                                            viewModel.ejectVolumeForFolderPanel(pane.kind)
                                        } label: {
                                            Image(systemName: "eject")
                                                .font(.system(size: 11, weight: .semibold))
                                                .frame(width: 14, height: 14)
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.secondary)
                                        .help("ボリュームを取り外す")
                                    }
                                },
                                onClose: {
                                    folderPaneHeights[pane.id] = nil
                                    viewModel.closeFolderPane(pane.kind)
                                }
                            ) {
                                FolderTreeView(
                                    folderTree: pane.folderTree,
                                    selectedFolderURL: Binding(
                                        get: { viewModel.selectedFolderURL(for: pane.kind) },
                                        set: { newValue in
                                            if let newValue {
                                                viewModel.setSelectedFolderURL(newValue, for: pane.kind)
                                            }
                                        }
                                    ),
                                    panelKind: pane.kind
                                )
                            }
                            Divider()
                        }
                    }
                    .frame(
                        height: folderListHeight,
                        alignment: .top
                    )
                    
                    Divider()
                    
                    SidebarResizablePane(
                        title: "EXIF Info",
                        systemImage: "info.circle",
                        height: exifDisplayHeight(availableHeight: geometry.size.height),
                        isResizeEnabled: !viewModel.folderPanes.isEmpty,
                        onResize: {
                            resizeExifPane(
                                by: $0,
                                availableHeight: geometry.size.height,
                                currentDisplayedHeight: exifHeight
                            )
                        },
                        tools: { EmptyView() },
                        onClose: nil
                    ) {
                        ExifInfoPanel()
                    }
                }
                .onAppear {
                    applyDefaultFolderPaneHeights(folderListHeight: folderListHeight)
                }
                .onChange(of: viewModel.folderPanes.map(\.id)) { oldValue, newValue in
                    guard newValue.count > oldValue.count,
                          let newPaneID = newValue.last
                    else { return }
                    DispatchQueue.main.async {
                        applyDefaultFolderPaneHeights(folderListHeight: folderListHeight)
                        makeRoomForNewFolderPane(
                            newPaneID,
                            availableHeight: geometry.size.height,
                            exifHeight: currentExifDisplayHeight(availableHeight: geometry.size.height)
                        )
                    }
                }
            }
        }
    }
    
    private var folderOpenToolbar: some View {
        HStack(spacing: 6) {
            Button(action: onOpenFolder) {
                Label("Open Folder", systemImage: "folder.badge.plus")
            }
            .help("フォルダーを開く")
            
            Spacer(minLength: 0)
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Material.bar)
    }
    
    private func panelTitle(for pane: FolderPaneState) -> String {
        viewModel.rootFolderDisplayName(for: pane.kind) ?? pane.rootURL.lastPathComponent
    }
    
    private func exifDisplayHeight(availableHeight: CGFloat) -> Binding<CGFloat> {
        Binding(
            get: {
                currentExifDisplayHeight(availableHeight: availableHeight)
            },
            set: { exifPaneHeight = $0 }
        )
    }
    
    private func currentExifDisplayHeight(availableHeight: CGFloat) -> CGFloat {
        let preferredHeight = exifPaneHeight ?? availableHeight / 3
        let maximumHeight = max(sidebarMinimumPaneHeight, availableHeight - sidebarMinimumPaneHeight)
        return min(max(sidebarMinimumPaneHeight, preferredHeight), maximumHeight)
    }
    
    private var folderPanesDisplayedHeight: CGFloat {
        viewModel.folderPanes.reduce(CGFloat(0)) { total, pane in
            let paneHeight = max(folderPaneHeights[pane.id] ?? sidebarDefaultFolderPaneHeight, sidebarMinimumPaneHeight)
            return total + paneHeight + sidebarPaneDividerHeight
        }
    }
    
    private func folderPaneListHeight(availableHeight: CGFloat, exifHeight: CGFloat) -> CGFloat {
        max(0, availableHeight - exifHeight)
    }
    
    private func defaultFolderPaneHeight(folderListHeight: CGFloat) -> CGFloat {
        let paneCount = max(viewModel.folderPanes.count, 1)
        let dividerHeight = CGFloat(paneCount) * sidebarPaneDividerHeight
        let availableHeight = max(0, folderListHeight - dividerHeight)
        return max(sidebarMinimumPaneHeight, availableHeight / CGFloat(paneCount))
    }
    
    private func applyDefaultFolderPaneHeights(folderListHeight: CGFloat) {
        let defaultHeight = defaultFolderPaneHeight(folderListHeight: folderListHeight)
        for pane in viewModel.folderPanes where folderPaneHeights[pane.id] == nil {
            folderPaneHeights[pane.id] = defaultHeight
        }
    }
    
    private func heightBinding(for id: UUID, defaultHeight: CGFloat) -> Binding<CGFloat> {
        Binding(
            get: { folderPaneHeights[id] ?? defaultHeight },
            set: { folderPaneHeights[id] = $0 }
        )
    }
    
    private func resizeFolderPane(
        _ id: UUID,
        by dragDelta: CGFloat,
        availableHeight: CGFloat,
        exifHeight: CGFloat,
        defaultHeight: CGFloat
    ) {
        let currentHeight = folderPaneHeights[id] ?? defaultHeight
        let clampedDelta = clampedFolderPaneDragDelta(
            dragDelta,
            paneID: id,
            currentHeight: currentHeight,
            availableHeight: availableHeight,
            exifHeight: exifHeight
        )
        let actualDelta = adjustedDeltaForPreviousPane(before: .folder(id), proposedDelta: clampedDelta)
        folderPaneHeights[id] = max(sidebarMinimumPaneHeight, currentHeight - actualDelta)
    }
    
    private func clampedFolderPaneDragDelta(
        _ dragDelta: CGFloat,
        paneID: UUID,
        currentHeight: CGFloat,
        availableHeight: CGFloat,
        exifHeight: CGFloat
    ) -> CGFloat {
        let heightClampedDelta = clampedTopBoundaryDelta(dragDelta, currentHeight: currentHeight)
        guard heightClampedDelta > 0 else { return heightClampedDelta }
        
        let folderListHeight = folderPaneListHeight(availableHeight: availableHeight, exifHeight: exifHeight)
        let titleTop = folderPaneTitleTop(for: paneID)
        let maxTitleTop = max(0, folderListHeight - sidebarMinimumPaneHeight)
        let availableDownwardMovement = max(0, maxTitleTop - titleTop)
        return min(heightClampedDelta, availableDownwardMovement)
    }
    
    private func folderPaneTitleTop(for id: UUID) -> CGFloat {
        var top: CGFloat = 0
        for pane in viewModel.folderPanes {
            if pane.id == id {
                return top
            }
            let paneHeight = max(folderPaneHeights[pane.id] ?? sidebarDefaultFolderPaneHeight, sidebarMinimumPaneHeight)
            top += paneHeight + sidebarPaneDividerHeight
        }
        return top
    }
    
    private func makeRoomForNewFolderPane(_ newPaneID: UUID, availableHeight: CGFloat, exifHeight: CGFloat) {
        let folderListHeight = folderPaneListHeight(availableHeight: availableHeight, exifHeight: exifHeight)
        var overflow = folderPanesDisplayedHeight - folderListHeight
        guard overflow > 0 else { return }
        
        let previousPaneIDs = viewModel.folderPanes.map(\.id).filter { $0 != newPaneID }.reversed()
        
        for id in previousPaneIDs {
            guard overflow > 0 else { return }
            
            let currentHeight = folderPaneHeights[id] ?? sidebarDefaultFolderPaneHeight
            let shrink = min(overflow, max(0, currentHeight - sidebarMinimumExpandedPaneHeight))
            guard shrink > 0 else { continue }
            
            folderPaneHeights[id] = currentHeight - shrink
            overflow -= shrink
        }
        
        for id in previousPaneIDs {
            guard overflow > 0 else { return }
            
            let currentHeight = folderPaneHeights[id] ?? sidebarDefaultFolderPaneHeight
            let shrink = min(overflow, max(0, currentHeight - sidebarMinimumPaneHeight))
            guard shrink > 0 else { continue }
            
            folderPaneHeights[id] = currentHeight - shrink
            overflow -= shrink
        }
        
        guard overflow > 0 else { return }
        let newHeight = folderPaneHeights[newPaneID] ?? sidebarDefaultFolderPaneHeight
        folderPaneHeights[newPaneID] = max(sidebarMinimumPaneHeight, newHeight - overflow)
    }
    
    private func resizeExifPane(by dragDelta: CGFloat, availableHeight: CGFloat, currentDisplayedHeight: CGFloat) {
        let clampedDelta = clampedTopBoundaryDelta(dragDelta, currentHeight: currentDisplayedHeight)
        let actualDelta = adjustedDeltaForPreviousPane(before: .exif, proposedDelta: clampedDelta)
        let newExifHeight = max(sidebarMinimumPaneHeight, currentDisplayedHeight - actualDelta)
        exifPaneHeight = newExifHeight
        fitFolderPanes(to: folderPaneListHeight(availableHeight: availableHeight, exifHeight: newExifHeight))
    }
    
    private func clampedTopBoundaryDelta(_ proposedDelta: CGFloat, currentHeight: CGFloat) -> CGFloat {
        guard proposedDelta > 0 else { return proposedDelta }
        let availableShrink = max(0, currentHeight - sidebarMinimumPaneHeight)
        return min(proposedDelta, availableShrink)
    }
    
    private func adjustedDeltaForPreviousPane(before pane: SidebarPaneID, proposedDelta: CGFloat) -> CGFloat {
        guard proposedDelta != 0 else { return 0 }
        guard let previousPane = previousPane(before: pane) else { return proposedDelta }
        
        switch previousPane {
        case .folder(let previousID):
            let previousHeight = folderPaneHeights[previousID] ?? sidebarDefaultFolderPaneHeight
            if proposedDelta > 0 {
                folderPaneHeights[previousID] = previousHeight + proposedDelta
                return proposedDelta
            } else {
                let availableShrink = max(0, previousHeight - sidebarMinimumPaneHeight)
                let actualDelta = -min(-proposedDelta, availableShrink)
                folderPaneHeights[previousID] = previousHeight + actualDelta
                return actualDelta
            }
        case .exif:
            if proposedDelta > 0 {
                exifPaneHeight = currentExifDisplayHeightForAdjustment + proposedDelta
                return proposedDelta
            } else {
                let currentHeight = currentExifDisplayHeightForAdjustment
                let availableShrink = max(0, currentHeight - sidebarMinimumPaneHeight)
                let actualDelta = -min(-proposedDelta, availableShrink)
                exifPaneHeight = currentHeight + actualDelta
                return actualDelta
            }
        }
    }

    private var currentExifDisplayHeightForAdjustment: CGFloat {
        exifPaneHeight ?? sidebarDefaultExifPaneHeight
    }

    private func fitFolderPanes(to folderListHeight: CGFloat) {
        guard !viewModel.folderPanes.isEmpty else { return }

        let targetTotal = max(0, folderListHeight - CGFloat(viewModel.folderPanes.count) * sidebarPaneDividerHeight)
        let currentTotal = viewModel.folderPanes.reduce(CGFloat(0)) { total, pane in
            total + max(folderPaneHeights[pane.id] ?? sidebarMinimumPaneHeight, sidebarMinimumPaneHeight)
        }
        let delta = targetTotal - currentTotal
        guard abs(delta) > 0.5 else { return }

        if delta > 0 {
            growLastExpandedFolderPane(by: delta)
        } else {
            shrinkFolderPanes(by: -delta)
        }
    }

    private func growLastExpandedFolderPane(by delta: CGFloat) {
        guard let pane = viewModel.folderPanes.last else { return }
        let currentHeight = max(folderPaneHeights[pane.id] ?? sidebarMinimumPaneHeight, sidebarMinimumPaneHeight)
        folderPaneHeights[pane.id] = currentHeight + delta
    }

    private func shrinkFolderPanes(by delta: CGFloat) {
        var remaining = delta
        for pane in viewModel.folderPanes.reversed() {
            guard remaining > 0 else { return }
            let currentHeight = max(folderPaneHeights[pane.id] ?? sidebarMinimumPaneHeight, sidebarMinimumPaneHeight)
            let shrink = min(remaining, max(0, currentHeight - sidebarMinimumPaneHeight))
            guard shrink > 0 else { continue }
            folderPaneHeights[pane.id] = currentHeight - shrink
            remaining -= shrink
        }
    }
    
    private func previousPane(before pane: SidebarPaneID) -> SidebarPaneID? {
        switch pane {
        case .folder(let id):
            guard let currentIndex = viewModel.folderPanes.firstIndex(where: { $0.id == id }),
                  currentIndex > 0
            else { return nil }
            return .folder(viewModel.folderPanes[currentIndex - 1].id)
        case .exif:
            guard let lastPane = viewModel.folderPanes.last else { return nil }
            return .folder(lastPane.id)
        }
    }
    
}

private enum SidebarPaneID {
    case folder(UUID)
    case exif
}

private let sidebarPaneHeaderHeight: CGFloat = 28
private let sidebarMinimumPaneHeight: CGFloat = sidebarPaneHeaderHeight
private let sidebarMinimumExpandedPaneHeight: CGFloat = 80
private let sidebarDefaultFolderPaneHeight: CGFloat = 220
private let sidebarDefaultExifPaneHeight: CGFloat = 180
private let sidebarPaneDividerHeight: CGFloat = 1
private let sidebarMinimumResizeDelta: CGFloat = 0.2
private let sidebarPaneCollapseAnimation = Animation.easeOut(duration: 0.16)
private let sidebarPaneTitleBackground = Color.accentColor.opacity(0.12)
private var sidebarTooltipBackgroundColor: Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(calibratedWhite: 0.18, alpha: 0.96)
            : NSColor(calibratedWhite: 0.92, alpha: 0.98)
    })
}

struct SidebarResizablePane<Tools: View, Content: View>: View {
    let title: String
    let systemImage: String
    @Binding var height: CGFloat
    let isResizeEnabled: Bool
    let onResize: (CGFloat) -> Void
    @ViewBuilder let tools: Tools
    let onClose: (() -> Void)?
    @ViewBuilder let content: Content
    @State private var lastDragTranslation: CGFloat = 0
    @State private var isDraggingTitle = false
    @State private var animatesHeightChange = false

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            
            if height > sidebarMinimumPaneHeight {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: max(height, sidebarMinimumPaneHeight))
        .background(Color(nsColor: .controlBackgroundColor))
        .transaction { transaction in
            if !animatesHeightChange {
                transaction.animation = nil
            }
        }
    }
    
    private var titleBar: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
            
            SidebarPaneTitleText(title: title, suppressTooltip: isDraggingTitle)
            
            Spacer(minLength: 0)
            
            tools
            
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("このペインを閉じる")
            }
        }
        .frame(height: sidebarPaneHeaderHeight)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .background(sidebarPaneTitleBackground)
        .onTapGesture(perform: minimizeToTitleBar)
        .gesture(isResizeEnabled ? resizeGesture : nil)
    }
    
    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                isDraggingTitle = true
                let dragDelta = value.translation.height - lastDragTranslation
                guard abs(dragDelta) >= sidebarMinimumResizeDelta else { return }
                lastDragTranslation = value.translation.height
                onResize(dragDelta)
            }
            .onEnded { _ in
                height = max(sidebarMinimumPaneHeight, height)
                lastDragTranslation = 0
                isDraggingTitle = false
            }
    }

    private func minimizeToTitleBar() {
        guard isResizeEnabled else { return }
        let dragDelta = max(0, height - sidebarMinimumPaneHeight)
        guard dragDelta >= sidebarMinimumResizeDelta else { return }
        animatesHeightChange = true
        withAnimation(sidebarPaneCollapseAnimation) {
            onResize(dragDelta)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            animatesHeightChange = false
        }
    }
}

private struct SidebarPaneTitleText: View {
    let title: String
    let suppressTooltip: Bool
    @State private var availableWidth: CGFloat = 0
    @State private var hoverTask: Task<Void, Never>?
    @State private var anchorView: NSView?
    @State private var tooltipWindow: NSWindow?
    
    private var intrinsicTitleWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        return (title as NSString).size(withAttributes: [.font: font]).width
    }
    
    private var isTruncated: Bool {
        intrinsicTitleWidth > availableWidth + 1
    }
    
    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: SidebarTitleWidthPreferenceKey.self, value: proxy.size.width)
                        .background(SidebarTitleAnchorView { view in
                            anchorView = view
                        })
                }
            )
            .onPreferenceChange(SidebarTitleWidthPreferenceKey.self) { width in
                availableWidth = width
                if intrinsicTitleWidth <= width + 1 {
                    hideTooltip()
                }
            }
            .onHover(perform: handleHover)
            .onChange(of: suppressTooltip) { _, isSuppressed in
                if isSuppressed {
                    hoverTask?.cancel()
                    hideTooltip()
                }
            }
            .onDisappear {
                hoverTask?.cancel()
                hideTooltip()
            }
    }
    
    private func handleHover(_ isHovered: Bool) {
        hoverTask?.cancel()
        
        guard isHovered, isTruncated, !suppressTooltip else {
            hideTooltip()
            return
        }
        
        hoverTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if isTruncated && !suppressTooltip {
                    showTooltip()
                }
            }
        }
    }
    
    private func showTooltip() {
        guard let anchorView,
              let sourceWindow = anchorView.window
        else { return }
        
        if tooltipWindow == nil {
            let hostingView = NSHostingView(rootView: SidebarFloatingTitleTooltip(title: title))
            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.backgroundColor = .clear
            window.contentView = hostingView
            window.hasShadow = false
            window.isOpaque = false
            window.ignoresMouseEvents = true
            window.level = .floating
            window.collectionBehavior = [.transient, .ignoresCycle]
            tooltipWindow = window
        }
        
        guard let tooltipWindow,
              let hostingView = tooltipWindow.contentView
        else { return }
        
        let fittingSize = hostingView.fittingSize
        let clampedSize = CGSize(width: min(fittingSize.width, 520), height: fittingSize.height)
        let anchorRect = anchorView.convert(anchorView.bounds, to: nil)
        let screenRect = sourceWindow.convertToScreen(anchorRect)
        let visibleFrame = sourceWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let proposedX = screenRect.minX - 10
        let x = min(max(proposedX, visibleFrame.minX + 8), visibleFrame.maxX - clampedSize.width - 8)
        let y = min(
            max(screenRect.midY - clampedSize.height / 2, visibleFrame.minY + 8),
            visibleFrame.maxY - clampedSize.height - 8
        )
        
        tooltipWindow.setFrame(NSRect(origin: CGPoint(x: x, y: y), size: clampedSize), display: true)
        tooltipWindow.orderFront(nil)
    }
    
    private func hideTooltip() {
        tooltipWindow?.orderOut(nil)
    }
}

private struct SidebarTitleWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct SidebarTitleAnchorView: NSViewRepresentable {
    let onResolve: (NSView) -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            onResolve(view)
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView)
        }
    }
}

private struct SidebarFloatingTitleTooltip: View {
    let title: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TooltipArrow()
                .fill(sidebarTooltipBackgroundColor)
                .frame(width: 8, height: 4)
                .padding(.leading, 14)
            
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: .labelColor))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: 520, alignment: .leading)
                .background(sidebarTooltipBackgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(nsColor: .separatorColor))
                )
        }
        .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 2)
        .padding(6)
    }
}

private struct TooltipArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct FolderTreeView: View {
    let folderTree: [FileSystemItem]
    @Binding var selectedFolderURL: URL?
    let panelKind: FolderPanelKind
    @EnvironmentObject private var viewModel: PhotoSorterViewModel
    @State private var localSelection: URL?

    var body: some View {
        treeContent
        // Keep local state and view model in sync without publishing during a view update
        .onAppear {
            // Initialize local selection from model
            localSelection = selectedFolderURL ?? folderTree.first?.id
            if let url = localSelection {
                viewModel.expandAncestors(of: url, in: panelKind)
            }
        }
        .onChange(of: localSelection) { _, newValue in
            // Propagate user-driven selection changes to the view model on the next runloop
            guard let newValue, selectedFolderURL != newValue else { return }
            DispatchQueue.main.async {
                viewModel.setSelectedFolderURL(newValue, for: panelKind)
            }
        }
        .onChange(of: selectedFolderURL) { _, newValue in
            // Reflect programmatic changes into the local selection synchronously (no publish involved)
            if localSelection != newValue {
                localSelection = newValue
            }
            if let newValue {
                viewModel.expandAncestors(of: newValue, in: panelKind)
            }
        }
        .onChange(of: folderTree) { _, _ in
            // Re-apply selection when the whole tree changes, even if the selected URL value did not.
            if let selectedFolderURL {
                localSelection = selectedFolderURL
                viewModel.expandAncestors(of: selectedFolderURL, in: panelKind)
            } else if let root = folderTree.first?.id {
                localSelection = root
            } else if folderTree.isEmpty {
                localSelection = nil
            }
        }
    }
    
    @ViewBuilder
    private var treeContent: some View {
#if os(macOS)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(folderTree) { item in
                    FolderTreeNode(
                        item: item,
                        depth: 0,
                        selectedFolderURL: $selectedFolderURL,
                        panelKind: panelKind,
                        localSelection: $localSelection,
                        onSelect: selectFolder
                    )
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
#else
        List(folderTree, children: \.children) { item in
            HStack {
                Image(systemName: item.isFolder ? "folder" : "photo")
                Text(item.name)
            }
            .padding(.vertical, 2)
        }
        .listStyle(SidebarListStyle())
#endif
    }
    
    private func selectFolder(_ url: URL) {
        localSelection = url
        viewModel.setSelectedFolderURL(url, for: panelKind)
    }
}

#if os(macOS)
private let folderTreeIndent: CGFloat = 16
private let folderTreeChevronWidth: CGFloat = 12

struct FolderTreeNode: View {
    let item: FileSystemItem
    let depth: Int
    @Binding var selectedFolderURL: URL?
    let panelKind: FolderPanelKind
    @Binding var localSelection: URL?
    let onSelect: (URL) -> Void
    @EnvironmentObject private var viewModel: PhotoSorterViewModel
    
    private var hasChildren: Bool {
        guard let children = item.children else { return false }
        return !children.isEmpty
    }
    
    private var isExpanded: Bool {
        viewModel.isFolderExpanded(item.id, in: panelKind)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                disclosureControl
                folderRow
            }
            .padding(.leading, CGFloat(depth) * folderTreeIndent)
            
            if hasChildren && isExpanded {
                ForEach(item.children ?? []) { child in
                    FolderTreeNode(
                        item: child,
                        depth: depth + 1,
                        selectedFolderURL: $selectedFolderURL,
                        panelKind: panelKind,
                        localSelection: $localSelection,
                        onSelect: onSelect
                    )
                }
            }
        }
    }
    
    @ViewBuilder
    private var disclosureControl: some View {
        if hasChildren {
            Button {
                viewModel.setFolderExpanded(item.id, expanded: !isExpanded, in: panelKind)
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: folderTreeChevronWidth, height: 16)
            }
            .buttonStyle(.plain)
        } else {
            Color.clear
                .frame(width: folderTreeChevronWidth, height: 16)
        }
    }
    
    private var folderRow: some View {
        FolderTreeRow(
            item: item,
            isSelected: isSelected(item.id),
            panelKind: panelKind,
            onSelect: { onSelect(item.id) }
        )
    }
    
    private func isSelected(_ url: URL) -> Bool {
        localSelection?.standardizedFileURL == url.standardizedFileURL ||
        selectedFolderURL?.standardizedFileURL == url.standardizedFileURL
    }
}
#endif
#if os(macOS)
extension FolderTreeRow {
    private var isRootFolder: Bool {
        guard let root = viewModel.rootFolderURL(for: panelKind) else { return false }
        return root == item.id.standardizedFileURL
    }
    
    private var canRenameFolder: Bool {
        item.isFolder && !isRootFolder
    }
    
    private var canDeleteFolder: Bool {
        item.isFolder && !isRootFolder
    }
    
    private func ensureSelection() {
        if viewModel.selectedFolderURL(for: panelKind)?.standardizedFileURL != item.id.standardizedFileURL {
            viewModel.setSelectedFolderURL(item.id, for: panelKind)
        }
    }
    
    private func createSubfolder() {
        guard item.isFolder else { return }
        ensureSelection()
        if let name = promptForFolderName(title: "新規フォルダ", message: "\(item.name) にフォルダを作成", defaultValue: "新しいフォルダ") {
            viewModel.createSubfolder(at: item.id, named: name, in: panelKind)
        }
    }
    
    private func renameFolder() {
        guard canRenameFolder else { return }
        ensureSelection()
        if let name = promptForFolderName(title: "フォルダ名を変更", message: "\(item.name) の名前を変更", defaultValue: item.name) {
            viewModel.renameFolder(at: item.id, to: name, in: panelKind)
        }
    }
    
    private func deleteFolder() {
        guard canDeleteFolder else { return }
        ensureSelection()
        if confirmFolderDeletion(name: item.name) {
            viewModel.trashFolder(at: item.id, in: panelKind)
        }
    }
    
    private func promptForFolderName(title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "キャンセル")
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.stringValue = defaultValue
        textField.placeholderString = "フォルダ名"
        alert.accessoryView = textField
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }
    
    private func confirmFolderDeletion(name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "フォルダを削除"
        alert.informativeText = "\"\(name)\" をゴミ箱に移動しますか？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "キャンセル")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private func isOnExternalVolume(_ url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.volumeIsRemovableKey, .volumeIsEjectableKey]) else { return false }
    return (values.volumeIsRemovable == true) || (values.volumeIsEjectable == true)
}

@MainActor
private struct FolderDropDelegate: DropDelegate {
    let item: FileSystemItem
    let viewModel: PhotoSorterViewModel
    let undoManager: UndoManager?
    
    func validateDrop(info: DropInfo) -> Bool {
        item.isFolder
    }
    
    func dropEntered(info: DropInfo) {
        if item.isFolder {
            viewModel.targetedFolderURL = item.id
        }
    }
    
    func dropExited(info: DropInfo) {
        if viewModel.targetedFolderURL == item.id {
            viewModel.targetedFolderURL = nil
        }
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard item.isFolder else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: (isCopyGesture || isOnExternalVolume(item.id)) ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard item.isFolder else { return false }
        if viewModel.targetedFolderURL == item.id {
            viewModel.targetedFolderURL = nil
        }
        let destination = item.id
        Task {
            let urls = await loadURLs(from: info)
            guard !urls.isEmpty else { return }
            let copy = isCopyGesture || isOnExternalVolume(destination) || urls.contains(where: { isOnExternalVolume($0) })
            if copy {
                viewModel.copyPhotos(at: urls, to: destination, undoManager: undoManager)
            } else {
                viewModel.movePhotos(at: urls, to: destination, undoManager: undoManager)
            }
        }
        return true
    }
    
    private var isCopyGesture: Bool {
        NSEvent.modifierFlags.contains(.option)
    }
    
    private func loadURLs(from info: DropInfo) async -> [URL] {
        var results: [URL] = []
        let payloadProviders = info.itemProviders(for: [PhotoDragPayload.contentType])
        for provider in payloadProviders {
            if let payload = await loadTransferable(PhotoDragPayload.self, from: provider) {
                results.append(contentsOf: payload.urls)
            }
        }
        if results.isEmpty {
            for provider in info.itemProviders(for: [.fileURL]) {
                if let url = await loadTransferable(URL.self, from: provider) {
                    results.append(url)
                }
            }
        }
        return results
    }
    
    private func loadTransferable<T: Transferable>(_ type: T.Type, from provider: NSItemProvider) async -> T? {
        await withCheckedContinuation { continuation in
            _ = provider.loadTransferable(type: type) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure:
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
@MainActor
private struct PhotoGridDropDelegate: DropDelegate {
    let viewModel: PhotoSorterViewModel
    let undoManager: UndoManager?
    
    func validateDrop(info: DropInfo) -> Bool {
        viewModel.currentFolder != nil
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let currentFolder = viewModel.currentFolder else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: (isCopyGesture || isOnExternalVolume(currentFolder)) ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let currentFolder = viewModel.currentFolder else { return false }
        Task {
            let urls = await loadURLs(from: info)
            guard !urls.isEmpty else { return }
            let copy = isCopyGesture || isOnExternalVolume(currentFolder) || urls.contains(where: { isOnExternalVolume($0) })
            if copy {
                viewModel.copyPhotos(at: urls, to: currentFolder, undoManager: undoManager)
            } else {
                viewModel.movePhotos(at: urls, to: currentFolder, undoManager: undoManager)
            }
        }
        return true
    }
    
    private var isCopyGesture: Bool {
        NSEvent.modifierFlags.contains(.option)
    }
    
    private func loadURLs(from info: DropInfo) async -> [URL] {
        var urls: [URL] = []
        for provider in info.itemProviders(for: [PhotoDragPayload.contentType]) {
            if let payload = await loadTransferable(PhotoDragPayload.self, from: provider) {
                urls.append(contentsOf: payload.urls)
            }
        }
        if urls.isEmpty {
            for provider in info.itemProviders(for: [.fileURL]) {
                if let url = await loadTransferable(URL.self, from: provider) {
                    urls.append(url)
                }
            }
        }
        return urls
    }
    
    private func loadTransferable<T: Transferable>(_ type: T.Type,
                                                   from provider: NSItemProvider) async -> T? {
        await withCheckedContinuation { continuation in
            _ = provider.loadTransferable(type: type) { result in
                continuation.resume(returning: try? result.get())
            }
        }
    }
}
#endif

struct PhotoGridView: View {
    let photos: [PhotoItem]
    let columns: [GridItem]
    let currentFolder: URL?
    @Binding var thumbnailSize: Double
    @Binding var sortMode: DateSortMode
    @Binding var primarySelectedPhotoID: UUID?
    @Binding var selectedPhotoIDs: Set<UUID>
    @FocusState var isGridFocused: Bool
    @Binding var actualGridWidth: CGFloat
    @Binding var selectedThumbnailScreenFrame: NSRect?
    let onSelect: (_ id: UUID, _ orderedIDs: [UUID], _ isCommandPressed: Bool, _ isShiftPressed: Bool, _ context: SelectionContext) -> Void
    let onSetStatusForSelection: (_ status: PhotoStatus) -> Void
    var isContextActive: Bool = false
    @EnvironmentObject private var viewModel: PhotoSorterViewModel
    @Environment(\.undoManager) private var undoManager
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                gridHeader

                Divider()

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
#if os(macOS)
                    .onDrop(of: [PhotoDragPayload.contentType, .fileURL],
                            delegate: PhotoGridDropDelegate(viewModel: viewModel,
                                                            undoManager: undoManager))
#endif
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

    private var gridHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("サムネールサイズ")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Slider(value: $thumbnailSize, in: 100...400, step: 10)
                        .frame(width: 160)
                        .accessibilityLabel("サムネールサイズ")
                }

                HStack(spacing: 8) {
                    Text("ソート方法")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("ソート方法", selection: $sortMode) {
                        Text("ファイル日付順").tag(DateSortMode.fileCreation)
                        Text("EXIF日付順").tag(DateSortMode.exifPreferred)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 150)
                    .help("表示順の基準を選択")
                }
            }

            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(currentFolder?.path ?? "フォルダ未選択")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(currentFolder?.path ?? "フォルダ未選択")
                }

                Spacer(minLength: 12)

                Text("\(photos.count) Photos")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Material.bar)
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
        .background {
            if primarySelectedPhotoID == photo.id {
                ScreenFrameReporter { frame in
                    selectedThumbnailScreenFrame = frame
                }
            }
        }
    }
}

private struct ScreenFrameReporter: NSViewRepresentable {
    let onChange: (NSRect?) -> Void

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ReportingView, context: Context) {
        nsView.onChange = onChange
        nsView.reportFrame()
    }

    final class ReportingView: NSView {
        var onChange: ((NSRect?) -> Void)?
        private var boundsObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateBoundsObserver()
            reportFrame()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            updateBoundsObserver()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            reportFrame()
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }

        private func updateBoundsObserver() {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
                self.boundsObserver = nil
            }

            guard let clipView = enclosingScrollView?.contentView else { return }
            clipView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                self?.reportFrame()
            }
        }

        func reportFrame() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let window else {
                    onChange?(nil)
                    return
                }

                let windowFrame = convert(bounds, to: nil)
                onChange?(window.convertToScreen(windowFrame))
            }
        }
    }
}

struct DragPreviewThumbnail: View {
    let thumbnail: NSImage?
    let count: Int
    let size: CGFloat
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.2))
                        .overlay(Image(systemName: "photo"))
                }
            }
            .frame(width: size, height: size)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.85), lineWidth: 2)
            )
            .shadow(radius: 6, y: 3)
            
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .frame(minWidth: 28, minHeight: 28)
                    .background(Color.accentColor, in: Capsule())
                    .overlay(Capsule().stroke(Color.white, lineWidth: 2))
                    .offset(x: 10, y: -10)
            }
        }
        .padding(10)
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
    @State private var showDeleteConfirmation = false
    @EnvironmentObject private var viewModel: PhotoSorterViewModel
    
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
            Divider()
            Button("削除", role: .destructive) {
                DispatchQueue.main.async {
                    onEnsureSelectedForContextMenu?()
                    showDeleteConfirmation = true
                }
            }
        }
        .alert("ファイルを削除", isPresented: $showDeleteConfirmation) {
            Button("完全削除", role: .destructive) {
                viewModel.deletePhotos(withIDs: viewModel.selectedPhotoIDs)
            }
            Button("ゴミ箱/削除予定へ移動") {
                viewModel.trashPhotos(withIDs: viewModel.selectedPhotoIDs)
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            let count = viewModel.selectedPhotoIDs.count
            if count <= 1 {
                Text("選択した写真を削除します。")
            } else {
                Text("選択した\(count)枚の写真を削除します。")
            }
        }
#if os(macOS)
        .draggable(PhotoDragPayload(urls: viewModel.urlsForDrag(startingAt: photo))) {
            DragPreviewThumbnail(
                thumbnail: thumbnail,
                count: viewModel.urlsForDrag(startingAt: photo).count,
                size: min(CGFloat(thumbnailSize), 160)
            )
        }
#endif
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
    let windowID: String

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
                splitPositionKey: "\(windowID)_KeepDiscardSplitPosition"
            ),
            minTop: 200,
            minBottom: 200,
            splitPositionKey: "\(windowID)_RightPanelVerticalSplitPosition"
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

#if os(macOS)
// MARK: - EXIF Info Panel (Folder sidebar)

struct ExifInfoPanel: View {
    @EnvironmentObject private var viewModel: PhotoSorterViewModel
    @State private var entries: [(String, String)] = []
    @State private var isLoading = false
    @State private var lastURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                VStack { Spacer(); ProgressView(); Spacer() }
                    .frame(maxWidth: .infinity)
            } else if entries.isEmpty {
                VStack(spacing: 6) {
                    Text("No EXIF available")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(entries.enumerated()), id: \.0) { _, pair in
                            HStack(alignment: .top, spacing: 6) {
                                Text(pair.0)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 120, alignment: .trailing)
                                Text(pair.1)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                Spacer()
                            }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { loadIfNeeded() }
        .onChange(of: viewModel.primarySelectedPhotoID) { _, _ in
            loadIfNeeded()
        }
    }

    private func loadIfNeeded() {
        guard let url = viewModel.selectedPhoto?.url else {
            entries = []
            lastURL = nil
            return
        }
        if lastURL == url { return }
        lastURL = url
        if let cached = ExifMetadataProvider.shared.cachedEntries(for: url) {
            entries = cached
            return
        }
        isLoading = true
        ExifMetadataProvider.shared.loadEntries(for: url) { result in
            self.entries = result
            self.isLoading = false
        }
    }
}

private final class ExifMetadataProvider {
    static let shared = ExifMetadataProvider()
    private let cache = NSCache<NSURL, NSArray>()
    private init() {}

    func cachedEntries(for url: URL) -> [(String, String)]? {
        guard let raw = cache.object(forKey: url as NSURL) else { return nil }
        var result: [(String, String)] = []
        for case let pair as [String] in raw where pair.count == 2 {
            result.append((pair[0], pair[1]))
        }
        return result
    }

    func loadEntries(for url: URL, completion: @escaping ([(String, String)]) -> Void) {
        if let cached = cachedEntries(for: url) {
            completion(cached)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let entries = self.extractEntries(from: url)
            let array = entries.map { [$0.0, $0.1] } as NSArray
            self.cache.setObject(array, forKey: url as NSURL)
            DispatchQueue.main.async {
                completion(entries)
            }
        }
    }

    private func extractEntries(from url: URL) -> [(String, String)] {
        var list: [(String, String)] = []

        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                append("Make", value: tiff[kCGImagePropertyTIFFMake], to: &list)
                append("Model", value: tiff[kCGImagePropertyTIFFModel], to: &list)
                append("Software", value: tiff[kCGImagePropertyTIFFSoftware], to: &list)
            }
            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                append("DateTimeOriginal", value: exif[kCGImagePropertyExifDateTimeOriginal], to: &list)
                append("CreateDate", value: exif[kCGImagePropertyExifDateTimeDigitized], to: &list)
                if let et = exif[kCGImagePropertyExifExposureTime] as? Double {
                    list.append(("ExposureTime", Self.exposureTimeString(et)))
                }
                append("FNumber", value: exif[kCGImagePropertyExifFNumber], to: &list)
                append("ISO", value: exif[kCGImagePropertyExifISOSpeedRatings], to: &list)
                append("FocalLength", value: exif[kCGImagePropertyExifFocalLength], to: &list)
                append("LensModel", value: exif[kCGImagePropertyExifLensModel], to: &list)
            }
            append("Orientation", value: props[kCGImagePropertyOrientation], to: &list)
            append("ColorModel", value: props[kCGImagePropertyColorModel], to: &list)
            append("PixelWidth", value: props[kCGImagePropertyPixelWidth], to: &list)
            append("PixelHeight", value: props[kCGImagePropertyPixelHeight], to: &list)
            append("DPIWidth", value: props[kCGImagePropertyDPIWidth], to: &list)
            append("DPIHeight", value: props[kCGImagePropertyDPIHeight], to: &list)
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            if let created = attrs[.creationDate] as? Date {
                list.append(("FileCreationDate", dateFormatter.string(from: created)))
            }
            if let modified = attrs[.modificationDate] as? Date {
                list.append(("FileModificationDate", dateFormatter.string(from: modified)))
            }
        }

        return list
    }

    private func append(_ label: String, value: Any?, to list: inout [(String, String)]) {
        guard let stringValue = Self.string(from: value) else { return }
        list.append((label, stringValue))
    }

    private static func exposureTimeString(_ seconds: Double) -> String {
        if seconds >= 1 {
            return String(format: seconds.truncatingRemainder(dividingBy: 1) == 0 ? "%.0fs" : "%.1fs", seconds)
        }
        let denominator = Int((1.0 / seconds).rounded())
        return "1/\(denominator)"
    }

    private static func string(from value: Any?) -> String? {
        guard let value else { return nil }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let arr = value as? [Any] {
            return arr.map { String(describing: $0) }.joined(separator: ", ")
        }
        return String(describing: value)
    }

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy年M月d日 H時m分s秒"
        return formatter
    }()
}

struct FolderTreeRow: View {
    let item: FileSystemItem
    let isSelected: Bool
    let panelKind: FolderPanelKind
    let onSelect: () -> Void
    @EnvironmentObject private var viewModel: PhotoSorterViewModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: item.isFolder ? "folder" : "photo")
                .frame(width: 16, alignment: .center)
            Text(item.name)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isActiveSelection ? Color.white : Color.primary)
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(backgroundColor)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .listRowBackground(backgroundColor)
        .onTapGesture(perform: onSelect)
        .onDrop(of: [PhotoDragPayload.contentType, .fileURL],
                delegate: FolderDropDelegate(item: item,
                                             viewModel: viewModel,
                                             undoManager: undoManager))
#if os(macOS)
        .onDragIf(!isRootFolder) {
            NSItemProvider(object: item.id.standardizedFileURL as NSURL)
        }
        .contextMenu {
            Button("Finderで開く") {
                openInFinder()
            }
            .disabled(!item.isFolder)
            
            Divider()
            
            Button("新規フォルダ") {
                createSubfolder()
            }
            .disabled(!item.isFolder)
            
            Button("フォルダ名を変更") {
                renameFolder()
            }
            .disabled(!canRenameFolder)
            
            Divider()
            
            Button("フォルダを削除") {
                deleteFolder()
            }
            .disabled(!canDeleteFolder)
        }
#endif
    }

    private var isTargeted: Bool {
        viewModel.targetedFolderURL?.standardizedFileURL == item.id.standardizedFileURL
    }

    private var backgroundColor: Color {
        if isTargeted {
            return Color.accentColor.opacity(0.2)
        } else if isActiveSelection {
            return Color.accentColor
        } else {
            return .clear
        }
    }
    
    private var isActiveSelection: Bool {
        isSelected && viewModel.activeFolderPanel == panelKind
    }
    
    private func openInFinder() {
        guard item.isFolder else { return }
        NSWorkspace.shared.open(item.id)
    }
}

struct PhotoDragPayload: Codable, Transferable {
    let urls: [URL]

    static let contentType = UTType(exportedAs: "dev.etokoji.photoSelector.photodrag")

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)
    }
}
#endif

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
                    PreviewImageView(url: photo.url, displaySize: geometry.size)
                        .frame(width: geometry.size.width, height: geometry.size.height)
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

                        if let fileSize = photo.formattedFileSize {
                            Text(fileSize)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        if let date = viewModel.displayedDate(for: photo) {
                            Text(formatDate(date))
                                .font(.caption)
                                .foregroundStyle(.secondary)
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

private struct PreviewImageView: View {
    let url: URL
    let displaySize: CGSize
    @State private var image: NSImage?
    @State private var isLoading = false
    @State private var didFail = false

    private var thumbnailSize: CGFloat {
        let maxDimension = max(displaySize.width, displaySize.height)
        guard maxDimension.isFinite, maxDimension > 0 else { return 640 }
        return max(160, ceil(maxDimension / 64) * 64)
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if didFail {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Failed to load")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
            }

            if isLoading {
                ProgressView()
            }
        }
        .task(id: PreviewImageRequest(url: url, size: thumbnailSize)) {
            await loadImage()
        }
    }

    @MainActor
    private func loadImage() async {
        didFail = false
        isLoading = true

        let loadedImage = await ThumbnailGenerator.shared.thumbnail(for: url, size: thumbnailSize)

        guard !Task.isCancelled else { return }
        image = loadedImage
        didFail = loadedImage == nil
        isLoading = false
    }

    private struct PreviewImageRequest: Hashable {
        let url: URL
        let size: CGFloat
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
#if os(macOS)
        .dropDestination(for: PhotoDragPayload.self) { payloads, _ in
            let urls = payloads.flatMap { $0.urls }
            guard !urls.isEmpty else { return false }
            viewModel.applyStatus(.groupA, to: urls)
            return true
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            viewModel.applyStatus(.groupA, to: urls)
            return true
        }
#endif
    }
}

struct GroupAThumbnail: View {
    let photo: PhotoItem
    var isSelected: Bool = false
    var isPrimary: Bool = false
    var onEnsureSelectedForContextMenu: (() -> Void)? = nil
    var onSetStatusForSelection: ((PhotoStatus) -> Void)? = nil
    @State private var thumbnail: NSImage?
    @EnvironmentObject private var viewModel: PhotoSorterViewModel
    
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
#if os(macOS)
        .draggable(PhotoDragPayload(urls: viewModel.urlsForDrag(startingAt: photo))) {
            DragPreviewThumbnail(
                thumbnail: thumbnail,
                count: viewModel.urlsForDrag(startingAt: photo).count,
                size: 96
            )
        }
#endif
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
#if os(macOS)
        .dropDestination(for: PhotoDragPayload.self) { payloads, _ in
            let urls = payloads.flatMap { $0.urls }
            guard !urls.isEmpty else { return false }
            viewModel.applyStatus(.groupB, to: urls)
            return true
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            viewModel.applyStatus(.groupB, to: urls)
            return true
        }
#endif
    }
}

struct GroupBThumbnail: View {
    let photo: PhotoItem
    var isSelected: Bool = false
    var isPrimary: Bool = false
    var onEnsureSelectedForContextMenu: (() -> Void)? = nil
    var onSetStatusForSelection: ((PhotoStatus) -> Void)? = nil
    @State private var thumbnail: NSImage?
    @EnvironmentObject private var viewModel: PhotoSorterViewModel
    
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
#if os(macOS)
        .draggable(PhotoDragPayload(urls: viewModel.urlsForDrag(startingAt: photo))) {
            DragPreviewThumbnail(
                thumbnail: thumbnail,
                count: viewModel.urlsForDrag(startingAt: photo).count,
                size: 96
            )
        }
#endif
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


// Helper function to format date
func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ja_JP")
    formatter.dateFormat = "yyyy年M月d日 H時m分s秒"
    return formatter.string(from: date)
}


#Preview {
    ContentView()
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

// MARK: - View Extensions
#if os(macOS)
private struct WindowTitleSetter: NSViewRepresentable {
    let title: String
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        updateTitle(for: view)
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        updateTitle(for: nsView)
    }
    
    private func updateTitle(for view: NSView) {
        DispatchQueue.main.async {
            view.window?.title = title
        }
    }
}

private struct WindowInitialSizeSetter: NSViewRepresentable {
    let size: CGSize?
    
    func makeNSView(context: Context) -> WindowSizeAnchorView {
        let view = WindowSizeAnchorView()
        view.targetSize = size
        return view
    }
    
    func updateNSView(_ nsView: WindowSizeAnchorView, context: Context) {
        nsView.targetSize = size
        nsView.applySizeIfNeeded()
        DispatchQueue.main.async {
            nsView.applySizeIfNeeded()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            nsView.applySizeIfNeeded()
        }
    }
}

private final class WindowSizeAnchorView: NSView {
    var targetSize: CGSize?
    var didApply = false
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applySizeIfNeeded()
        DispatchQueue.main.async {
            self.applySizeIfNeeded()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.applySizeIfNeeded()
        }
    }
    
    func applySizeIfNeeded() {
        guard !didApply,
              let window,
              let targetSize,
              targetSize.width > 0,
              targetSize.height > 0
        else { return }
        
        window.setContentSize(targetSize)
        let appliedSize = window.contentLayoutRect.size
        if abs(appliedSize.width - targetSize.width) <= 2,
           abs(appliedSize.height - targetSize.height) <= 2 {
            didApply = true
        }
    }
}
#endif

extension View {
    @ViewBuilder
    func draggableIf<T: Transferable>(_ condition: Bool, _ payload: @escaping @autoclosure () -> T) -> some View {
        if condition {
            self.draggable(payload())
        } else {
            self
        }
    }
    
    @ViewBuilder
    func onDragIf(_ condition: Bool, _ data: @escaping () -> NSItemProvider) -> some View {
        if condition {
            self.onDrag(data)
        } else {
            self
        }
    }
}
