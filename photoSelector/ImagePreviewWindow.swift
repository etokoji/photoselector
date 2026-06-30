//
//  ImagePreviewWindow.swift
//  photoSelector
//

import SwiftUI
import AppKit
import ImageIO

// MARK: - Image Preview Window View

struct ImagePreviewWindowView: View {
    var viewModel: PhotoSorterViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let photo = viewModel.selectedPhoto {
                ZoomableAsyncImageView(url: photo.url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Bottom bar with filename and date
                HStack(spacing: 8) {
                    Text(photo.filename)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let fileSize = photo.formattedFileSize {
                        Text(fileSize)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if let date = viewModel.displayedDate(for: photo) {
                        Text("(\(formatDate(date)))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
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
                    NSApp.keyWindow?.performClose(nil)
                }) {
                    Image(systemName: "xmark.circle")
                }
                .keyboardShortcut("w", modifiers: .command)
                .help("Close (⌘W, Enter, or Space)")
            }
        }
    }
}

// MARK: - Window Size Management

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
        if width == 0 || height == 0 {
            return NSSize(width: defaultWidth, height: defaultHeight)
        }
        return NSSize(width: width, height: height)
    }
}

// MARK: - Window Delegate

class PreviewWindowDelegate: NSObject, NSWindowDelegate {
    private let closingTargetFrame: () -> NSRect?
    private let onClose: () -> Void
    private var localMonitor: Any?
    private weak var mainWindow: NSWindow?
    private var didInvokeOnClose = false
    private var isAnimatingClose = false
    private var isClosingAfterAnimation = false

    init(
        onClose: @escaping () -> Void,
        mainWindow: NSWindow?,
        closingTargetFrame: @escaping () -> NSRect? = { nil }
    ) {
        self.onClose = onClose
        self.mainWindow = mainWindow
        self.closingTargetFrame = closingTargetFrame
        super.init()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // Monitor keys that should close the preview window even when the image view has focus.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard let window = window else { return event }
            if event.window == window {
                if event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 76 {
                    window.performClose(nil)
                    return nil
                }
            }
            return event
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        invokeOnCloseIfNeeded()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isClosingAfterAnimation else { return true }
        guard !isAnimatingClose else { return false }
        animateClose(sender)
        return false
    }

    func windowDidResize(_ notification: Notification) {
        guard !isAnimatingClose, !isClosingAfterAnimation else { return }
        guard let window = notification.object as? NSWindow else { return }
        PreviewWindowSizeManager.shared.saveWindowSize(window.frame.size)
    }

    private func animateClose(_ window: NSWindow) {
        isAnimatingClose = true
        let finalFrame = closingTargetFrame().map { closingWindowFinalFrame(to: $0, from: window.frame) }
        let duration = finalFrame == nil ? 0.18 : 0.24

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = finalFrame == nil ? 0 : 0.45
            if let finalFrame {
                window.animator().setFrame(finalFrame, display: true)
            }
        } completionHandler: { [weak self, weak window] in
            guard let self, let window else { return }
            self.isAnimatingClose = false
            self.isClosingAfterAnimation = true
            window.close()
        }
    }

    private func closingWindowFinalFrame(to targetFrame: NSRect, from sourceFrame: NSRect) -> NSRect {
        let minimumSize: CGFloat = 96
        let scale = max(minimumSize / max(targetFrame.width, targetFrame.height, 1), 1)
        let width = min(max(targetFrame.width * scale, minimumSize), sourceFrame.width * 0.35)
        let height = min(max(targetFrame.height * scale, minimumSize), sourceFrame.height * 0.35)
        return NSRect(
            x: targetFrame.midX - width / 2,
            y: targetFrame.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func invokeOnCloseIfNeeded() {
        guard !didInvokeOnClose else { return }
        didInvokeOnClose = true
        onClose()
    }
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

// MARK: - Observing Scroll View

final class ObservingScrollView: NSScrollView {
    var onUserZoom: (() -> Void)?

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        onUserZoom?()
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        if event.phase == .changed || event.momentumPhase == .changed {
            onUserZoom?()
        }
    }
}

// MARK: - Zoomable Image View (NSViewRepresentable)

struct ZoomableAsyncImageView: NSViewRepresentable {
    var url: URL
    var allowFullImageLoad: Bool = true

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ObservingScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .clear

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let clipView = CenteringClipView()
        clipView.documentView = imageView
        clipView.backgroundColor = .clear
        scrollView.contentView = clipView
        clipView.documentView = imageView
        clipView.backgroundColor = .clear
        scrollView.contentView = clipView

        // Double-click to toggle between fit and actual pixels
        let doubleClickGesture = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleClick))
        doubleClickGesture.numberOfClicksRequired = 2
        imageView.addGestureRecognizer(doubleClickGesture)

        // Pan gesture for drag-to-move when zoomed in
        let panGesture = NSPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        imageView.addGestureRecognizer(panGesture)

        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 10.0
        scrollView.contentView.postsBoundsChangedNotifications = true
        let coordinator = context.coordinator
        scrollView.onUserZoom = { [weak coordinator] in
            coordinator?.userAdjustedZoom()
        }

        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView
        context.coordinator.setAllowsFullImageLoad(allowFullImageLoad)
        context.coordinator.observeBoundsChanges()
        context.coordinator.loadImage(from: url)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.setAllowsFullImageLoad(allowFullImageLoad)
        if context.coordinator.currentURL != url {
            context.coordinator.loadImage(from: url)
        } else {
            context.coordinator.applyInitialFitIfNeeded()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject {
        var parent: ZoomableAsyncImageView
        weak var imageView: NSImageView?
        weak var scrollView: NSScrollView?
        var currentURL: URL?
        private var didApplyInitialFit = false
        private var lastAppliedFitScale: CGFloat?
        private var boundsObserver: NSObjectProtocol?
        private var pendingBoundsRefit = false
        private var userHasAdjustedZoom = false
        private let actualPixelScale: CGFloat = 1.0
        private let zoomToggleTolerance: CGFloat = 0.01
        // Preview loading is staged for slow SD cards: show an in-memory grid
        // thumbnail immediately, then a small ImageIO preview, and only start the
        // full image load after the selection has stayed on the same file briefly.
        private let previewPixelSize = 768
        private let fullImageLoadDelay: TimeInterval = 0.75
        private let isFullImageLoadingDisabledForThumbnailPreviewTest = false
        private let previewImageQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "dev.etokoji.preview-thumbnail-loader"
            queue.qualityOfService = .userInitiated
            queue.maxConcurrentOperationCount = 1
            return queue
        }()
        private let fullImageQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "dev.etokoji.preview-full-image-loader"
            queue.qualityOfService = .utility
            queue.maxConcurrentOperationCount = 1
            return queue
        }()
        private var loadGeneration = 0
        private var scheduledFullLoadGeneration: Int?
        private var allowsFullImageLoad = true
        private var allowsCurrentImageUpscaling = false
        private var panStartOrigin: NSPoint?
        private var previewWasSkippedForCurrentLoad = false

        init(_ parent: ZoomableAsyncImageView) {
            self.parent = parent
        }

        deinit {
            previewImageQueue.cancelAllOperations()
            fullImageQueue.cancelAllOperations()
            if let observer = boundsObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func setAllowsFullImageLoad(_ isAllowed: Bool) {
            guard allowsFullImageLoad != isAllowed else { return }
            allowsFullImageLoad = isAllowed

            if isAllowed {
                if let currentURL {
                    // Restart the preview that was skipped during rapid navigation.
                    if previewWasSkippedForCurrentLoad {
                        previewWasSkippedForCurrentLoad = false
                        enqueuePreviewOperation(for: currentURL, generation: loadGeneration)
                    }
                    scheduleFullImageLoad(for: currentURL, generation: loadGeneration)
                }
            } else {
                scheduledFullLoadGeneration = nil
                fullImageQueue.cancelAllOperations()
            }
        }

        func observeBoundsChanges() {
            guard boundsObserver == nil, let contentView = scrollView?.contentView else { return }
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: contentView,
                queue: .main
            ) { [weak self] _ in
                self?.handleBoundsChange()
            }
        }

        func loadImage(from url: URL) {
            let requestURL = url.standardizedFileURL
            currentURL = requestURL
            didApplyInitialFit = false
            userHasAdjustedZoom = false
            loadGeneration += 1
            let generation = loadGeneration
            scheduledFullLoadGeneration = nil
            previewWasSkippedForCurrentLoad = false

            previewImageQueue.cancelAllOperations()
            fullImageQueue.cancelAllOperations()

            // First paint: reuse the thumbnail already decoded for the grid if it
            // exists. This avoids touching the SD card when arrow-key navigation
            // lands on an item whose grid thumbnail is already in memory.
            if let cachedThumbnail = ThumbnailGenerator.shared.cachedThumbnail(for: requestURL) {
                displayLoadedImage(cachedThumbnail, allowsUpscaling: true)
                scheduleFullImageLoad(for: requestURL, generation: generation)
                // During rapid navigation the cached thumbnail is sufficient; skip the
                // SD card read for the preview. setAllowsFullImageLoad(true) will
                // restart it when the key is released.
                if !allowsFullImageLoad {
                    previewWasSkippedForCurrentLoad = true
                    return
                }
            } else {
                imageView?.image = nil
                imageView?.frame.size = .zero
            }

            // Second paint: generate a small preview on its own queue. It can still
            // block on SD card I/O, but it is cheaper than decoding the full image.
            enqueuePreviewOperation(for: requestURL, generation: generation)
        }

        private func enqueuePreviewOperation(for requestURL: URL, generation: Int) {
            var previewOperation: BlockOperation!
            previewOperation = BlockOperation { [weak self, weak previewOperation] in
                guard previewOperation?.isCancelled == false else { return }

                if let previewImage = Self.previewThumbnail(for: requestURL, maxPixelSize: self?.previewPixelSize ?? 768) {
                    DispatchQueue.main.async { [weak self, weak previewOperation] in
                        guard let self,
                              previewOperation?.isCancelled == false,
                              self.currentURL == requestURL,
                              self.loadGeneration == generation
                        else { return }
                        self.displayLoadedImage(previewImage, allowsUpscaling: true)
                        self.scheduleFullImageLoad(for: requestURL, generation: generation)
                    }
                }
            }
            previewImageQueue.addOperation(previewOperation)
        }

        private func displayLoadedImage(_ image: NSImage, allowsUpscaling: Bool) {
            guard let imageView else { return }
            allowsCurrentImageUpscaling = allowsUpscaling
            imageView.image = image
            imageView.frame.size = image.size
            applyInitialFitIfNeeded(force: true)
        }

        private func scheduleFullImageLoad(for url: URL, generation: Int) {
            // Full-image reads are intentionally delayed because NSImage(contentsOf:)
            // cannot be cancelled once the SD card read has started, and it can starve
            // later thumbnail/preview reads during held-arrow navigation.
            guard !isFullImageLoadingDisabledForThumbnailPreviewTest else { return }
            guard allowsFullImageLoad else { return }
            guard scheduledFullLoadGeneration != generation else { return }
            scheduledFullLoadGeneration = generation

            DispatchQueue.main.asyncAfter(deadline: .now() + fullImageLoadDelay) { [weak self] in
                guard let self,
                      self.currentURL == url,
                      self.loadGeneration == generation
                else { return }
                self.enqueueFullImageLoad(for: url, generation: generation)
            }
        }

        private func enqueueFullImageLoad(for url: URL, generation: Int) {
            var fullOperation: BlockOperation!
            fullOperation = BlockOperation { [weak self, weak fullOperation] in
                guard fullOperation?.isCancelled == false else { return }
                guard let fullImage = NSImage(contentsOf: url) else { return }

                DispatchQueue.main.async { [weak self, weak fullOperation] in
                    guard let self,
                          fullOperation?.isCancelled == false,
                          self.currentURL == url,
                          self.loadGeneration == generation
                    else { return }
                    self.displayLoadedImage(fullImage, allowsUpscaling: false)
                }
            }
            fullImageQueue.addOperation(fullOperation)
        }

        private static func previewThumbnail(for url: URL, maxPixelSize: Int) -> NSImage? {
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                return nil
            }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]

            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
                return nil
            }

            return NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
        }

        @objc func handleDoubleClick(gesture: NSClickGestureRecognizer) {
            guard let scrollView = scrollView ?? imageView?.enclosingScrollView else { return }
            let current = scrollView.magnification
            if abs(current - actualPixelScale) < zoomToggleTolerance {
                userHasAdjustedZoom = false
                applyInitialFitIfNeeded(force: true, animated: true)
            } else {
                zoomToActualPixels(in: scrollView, animated: true)
            }
        }

        // Drag-to-pan when zoomed in: image follows the pointer like moving a physical photo.
        @objc func handlePan(_ gesture: NSPanGestureRecognizer) {
            guard let scrollView = scrollView else { return }
            let fitScale = lastAppliedFitScale ?? scrollView.minMagnification
            // Only pan when zoomed beyond fit scale
            guard scrollView.magnification > fitScale * 1.01 else {
                panStartOrigin = nil
                return
            }

            switch gesture.state {
            case .began:
                panStartOrigin = scrollView.contentView.bounds.origin
            case .changed:
                guard let startOrigin = panStartOrigin else { return }
                let translation = gesture.translation(in: scrollView)
                // Divide by magnification to convert screen pixels → document coordinates
                let mag = scrollView.magnification
                let newOrigin = NSPoint(
                    x: startOrigin.x - translation.x / mag,
                    y: startOrigin.y + translation.y / mag
                )
                scrollView.contentView.scroll(to: newOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            case .ended, .cancelled, .failed:
                panStartOrigin = nil
            default:
                break
            }
        }

        func applyInitialFitIfNeeded(force: Bool = false, animated: Bool = false) {
            guard force || (!didApplyInitialFit && !userHasAdjustedZoom) else { return }
            guard let scrollView = scrollView ?? imageView?.enclosingScrollView else { return }
            guard let targetScale = calculateFitScale(for: scrollView) else { return }
#if DEBUG
            debugLog("applyInitialFitIfNeeded(force: \(force), animated: \(animated)) -> \(targetScale)")
#endif
            applyFit(scale: targetScale, in: scrollView, animated: animated)
            didApplyInitialFit = true
        }

        private func handleBoundsChange() {
            guard !pendingBoundsRefit else { return }
            pendingBoundsRefit = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let scrollView = self.scrollView else { return }
                self.pendingBoundsRefit = false
#if DEBUG
                self.debugLog("bounds change detected (content size: \(scrollView.contentView.bounds.size))")
#endif
                self.performBoundsAwareFitIfNeeded(scrollView: scrollView)
            }
        }

        private func performBoundsAwareFitIfNeeded(scrollView: NSScrollView) {
            guard !userHasAdjustedZoom else { return }
            guard let targetScale = calculateFitScale(for: scrollView) else { return }
            scrollView.minMagnification = min(targetScale, 0.05)

            guard let lastFit = lastAppliedFitScale else { return }
            let tolerance: CGFloat = 0.002
            if abs(scrollView.magnification - lastFit) <= tolerance {
#if DEBUG
                debugLog("auto-refit to \(targetScale) (current \(scrollView.magnification))")
#endif
                applyFit(scale: targetScale, in: scrollView, animated: false)
            }
        }

        private func calculateFitScale(for scrollView: NSScrollView) -> CGFloat? {
            guard let imageSize = imageView?.image?.size,
                  imageSize.width > 0,
                  imageSize.height > 0 else { return nil }

            let boundsSize = scrollView.bounds.size
            guard boundsSize.width > 0, boundsSize.height > 0 else { return nil }

            let scaleX = boundsSize.width / imageSize.width
            let scaleY = boundsSize.height / imageSize.height
            let fitScale = min(scaleX, scaleY)
            guard fitScale.isFinite, fitScale > 0 else { return nil }

            return allowsCurrentImageUpscaling ? fitScale : min(fitScale, 1.0)
        }

        private func applyFit(scale: CGFloat, in scrollView: NSScrollView, animated: Bool) {
            let targetScale = max(min(scale, scrollView.maxMagnification), 0.01)
            scrollView.minMagnification = min(targetScale, 0.05)

            if animated {
                NSAnimationContext.runAnimationGroup { _ in
                    scrollView.animator().magnification = targetScale
                }
            } else {
                scrollView.magnification = targetScale
            }
#if DEBUG
            debugLog("applyFit -> \(targetScale), userHasAdjusted = \(userHasAdjustedZoom)")
#endif
            lastAppliedFitScale = targetScale
            userHasAdjustedZoom = false
        }

        func userAdjustedZoom() {
#if DEBUG
            if !userHasAdjustedZoom {
                debugLog("user adjusted zoom (current magnification: \(scrollView?.magnification ?? -1))")
            }
#endif
            userHasAdjustedZoom = true
        }

#if DEBUG
        private func debugLog(_ message: String) {
            print("[ZoomableAsyncImageView] \(message)")
        }
#endif

        private func zoomToActualPixels(in scrollView: NSScrollView, animated: Bool) {
            let clamped = max(min(actualPixelScale, scrollView.maxMagnification), 0.01)
            if animated {
                NSAnimationContext.runAnimationGroup { _ in
                    scrollView.animator().magnification = clamped
                }
            } else {
                scrollView.magnification = clamped
            }
#if DEBUG
            debugLog("zoomToActualPixels -> \(clamped)")
#endif
            userHasAdjustedZoom = true
        }
    }
}
