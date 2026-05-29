//
//  ImagePreviewWindow.swift
//  photoSelector
//

import SwiftUI
import AppKit

// MARK: - Image Preview Window View

struct ImagePreviewWindowView: View {
    @ObservedObject var viewModel: PhotoSorterViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
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
    private let onClose: () -> Void
    private var localMonitor: Any?
    private weak var mainWindow: NSWindow?
    private var didInvokeOnClose = false

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
            if event.window == window {
                if event.keyCode == 36 || event.keyCode == 76 {
                    self.invokeOnCloseIfNeeded()
                    window.close()
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

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        PreviewWindowSizeManager.shared.saveWindowSize(window.frame.size)
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
        context.coordinator.observeBoundsChanges()
        context.coordinator.loadImage(from: url)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
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
        private var panStartOrigin: NSPoint?

        init(_ parent: ZoomableAsyncImageView) {
            self.parent = parent
        }

        deinit {
            if let observer = boundsObserver {
                NotificationCenter.default.removeObserver(observer)
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
            self.currentURL = url
            self.didApplyInitialFit = false
            self.userHasAdjustedZoom = false
            DispatchQueue.global().async {
                if let image = NSImage(contentsOf: url) {
                    DispatchQueue.main.async {
                        guard let imageView = self.imageView else { return }
                        imageView.image = image
                        imageView.frame.size = image.size
                        self.applyInitialFitIfNeeded(force: true)
                    }
                }
            }
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
                // X: drag right → origin decreases (non-flipped X same as screen)
                // Y: drag down → translation.y negative (AppKit Y-up) → origin decreases (sees lower content)
                let newOrigin = NSPoint(
                    x: startOrigin.x - translation.x,
                    y: startOrigin.y + translation.y
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

            return min(fitScale, 1.0)
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
