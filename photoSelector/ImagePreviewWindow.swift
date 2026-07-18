//
//  ImagePreviewWindow.swift
//  photoSelector
//

import SwiftUI
import AppKit
import ImageIO

// MARK: - Zoom Controller

fileprivate protocol ZoomControlTarget: AnyObject {
    func zoomToFitFromController()
    func zoomToActualSizeFromController()
    func setMagnificationFromController(_ magnification: CGFloat)
}

@Observable
final class ZoomController {
    var magnification: CGFloat = 1.0
    @ObservationIgnored private weak var target: ZoomControlTarget?

    fileprivate func setTarget(_ target: ZoomControlTarget) {
        self.target = target
    }

    fileprivate func clearTarget(_ target: ZoomControlTarget) {
        guard self.target === target else { return }
        self.target = nil
    }

    func zoomToFit() {
        target?.zoomToFitFromController()
    }

    func zoomToActualSize() {
        target?.zoomToActualSizeFromController()
    }

    func setMagnification(_ magnification: CGFloat) {
        target?.setMagnificationFromController(magnification)
    }
}

// MARK: - Image Preview Window View

struct ImagePreviewWindowView: View {
    var viewModel: PhotoSorterViewModel
    let photo: PhotoItem
    let zoomController: ZoomController
    let onClose: () -> Void

    private var zoomText: String {
        let pct = Int((zoomController.magnification * 100).rounded())
        return "\(pct)%"
    }

    var body: some View {
        VStack(spacing: 0) {
            ZoomableAsyncImageView(
                url: photo.url,
                controller: zoomController,
                rotationDegrees: viewModel.previewRotation(for: photo.url)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom bar with filename, date, and zoom controls. Keep this out of
            // SwiftUI toolbar because non-activating panels can trigger AppKit
            // toolbar constraint churn during rapid rootView updates.
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

                Button {
                    viewModel.rotatePreview(for: photo.url, clockwise: false)
                } label: {
                    Image(systemName: "rotate.left")
                }
                .help("左に90°回転")

                Button {
                    viewModel.rotatePreview(for: photo.url, clockwise: true)
                } label: {
                    Image(systemName: "rotate.right")
                }
                .help("右に90°回転")

                Text(zoomText)
                    .monospacedDigit()
                    .font(.subheadline)
                    .frame(minWidth: 52, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { Double(zoomController.magnification) },
                        set: { zoomController.setMagnification(CGFloat($0)) }
                    ),
                    in: 0.1...4.0
                )
                .frame(width: 140)
                .help("表示倍率")

                Button("Fit") {
                    zoomController.zoomToFit()
                }
                .help("ウインドウに合わせる")

                Button("原寸") {
                    zoomController.zoomToActualSize()
                }
                .help("原寸表示 (100%)")
            }
            .padding(8)
            .background(Material.bar)
        }
    }
}

// MARK: - Window Size Management

class PreviewWindowSizeManager {
    static let shared = PreviewWindowSizeManager()

    private let widthKey = "PreviewWindowContentWidth"
    private let heightKey = "PreviewWindowContentHeight"
    private let originXKey = "PreviewWindowOriginX"
    private let originYKey = "PreviewWindowOriginY"
    private let defaultWidth: CGFloat = 800
    private let defaultHeight: CGFloat = 600
    private let minimumWidth: CGFloat = 360
    private let minimumHeight: CGFloat = 240
    private let screenMargin: CGFloat = 80

    func saveWindowSize(_ size: NSSize) {
        guard size.width >= minimumWidth, size.height >= minimumHeight else { return }
        UserDefaults.standard.set(Double(size.width), forKey: widthKey)
        UserDefaults.standard.set(Double(size.height), forKey: heightKey)
    }

    func restoreWindowSize(screen: NSScreen? = NSScreen.main) -> NSSize {
        let width = UserDefaults.standard.double(forKey: widthKey)
        let height = UserDefaults.standard.double(forKey: heightKey)
        let restoredSize = width == 0 || height == 0
            ? NSSize(width: defaultWidth, height: defaultHeight)
            : NSSize(width: width, height: height)

        guard let visibleFrame = screen?.visibleFrame else { return restoredSize }
        return NSSize(
            width: min(max(restoredSize.width, minimumWidth), max(minimumWidth, visibleFrame.width - screenMargin)),
            height: min(max(restoredSize.height, minimumHeight), max(minimumHeight, visibleFrame.height - screenMargin))
        )
    }

    func saveWindowPosition(_ origin: NSPoint) {
        guard origin.x.isFinite, origin.y.isFinite else { return }
        UserDefaults.standard.set(Double(origin.x), forKey: originXKey)
        UserDefaults.standard.set(Double(origin.y), forKey: originYKey)
    }

    func restoreWindowOrigin(for frame: NSRect, screen: NSScreen? = NSScreen.main) -> NSPoint? {
        guard UserDefaults.standard.object(forKey: originXKey) != nil,
              UserDefaults.standard.object(forKey: originYKey) != nil else {
            return nil
        }

        let restoredOrigin = NSPoint(
            x: UserDefaults.standard.double(forKey: originXKey),
            y: UserDefaults.standard.double(forKey: originYKey)
        )
        let restoredFrame = NSRect(origin: restoredOrigin, size: frame.size)
        guard let visibleFrame = screen?.visibleFrame else { return restoredOrigin }
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - restoredFrame.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - restoredFrame.height)

        return NSPoint(
            x: min(max(restoredFrame.minX, visibleFrame.minX), maxX),
            y: min(max(restoredFrame.minY, visibleFrame.minY), maxY)
        )
    }
}

// MARK: - Preview Panel

final class ResizablePreviewPanel: NSPanel {
    private let resizeCursorInset: CGFloat = 5
    private var isShowingResizeCursor = false
    private var magnifyMonitor: Any?

    init(contentViewController: NSViewController) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        self.contentViewController = contentViewController
        acceptsMouseMovedEvents = true
        // NSApplication drops magnify gesture events addressed to a non-key
        // nonactivating panel before they reach the window, so deliver them manually.
        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            guard let self, event.window === self else { return event }
            self.sendEvent(event)
            return nil
        }
    }

    deinit {
        if let monitor = magnifyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        updateResizeCursor(at: event.locationInWindow)
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        resetResizeCursorIfNeeded()
        super.mouseExited(with: event)
    }

    private func updateResizeCursor(at windowLocation: NSPoint) {
        guard styleMask.contains(.resizable) else {
            resetResizeCursorIfNeeded()
            return
        }

        let bounds = NSRect(origin: .zero, size: frame.size)
        let location = windowLocation
        guard bounds.contains(location) else {
            resetResizeCursorIfNeeded()
            return
        }

        let nearLeft = location.x <= bounds.minX + resizeCursorInset
        let nearRight = location.x >= bounds.maxX - resizeCursorInset
        let nearBottom = location.y <= bounds.minY + resizeCursorInset
        let nearTop = location.y >= bounds.maxY - resizeCursorInset

        guard nearLeft || nearRight || nearBottom || nearTop else {
            resetResizeCursorIfNeeded()
            return
        }

        resizeCursor(
            nearLeft: nearLeft,
            nearRight: nearRight,
            nearBottom: nearBottom,
            nearTop: nearTop
        ).set()
        isShowingResizeCursor = true
    }

    private func resetResizeCursorIfNeeded() {
        guard isShowingResizeCursor else { return }
        NSCursor.arrow.set()
        isShowingResizeCursor = false
    }

    private func resizeCursor(
        nearLeft: Bool,
        nearRight: Bool,
        nearBottom: Bool,
        nearTop: Bool
    ) -> NSCursor {
        let position: NSCursor.FrameResizePosition
        switch (nearLeft, nearRight, nearBottom, nearTop) {
        case (true, _, true, _): position = .bottomLeft
        case (true, _, _, true): position = .topLeft
        case (_, true, true, _): position = .bottomRight
        case (_, true, _, true): position = .topRight
        case (true, _, _, _): position = .left
        case (_, true, _, _): position = .right
        case (_, _, true, _): position = .bottom
        default: position = .top
        }
        return NSCursor.frameResize(position: position, directions: .all)
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
    private var isOpeningAnimation = false

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
        guard !isOpeningAnimation, !isAnimatingClose, !isClosingAfterAnimation else { return }
        guard let window = notification.object as? NSWindow else { return }
        PreviewWindowSizeManager.shared.saveWindowSize(window.contentLayoutRect.size)
        PreviewWindowSizeManager.shared.saveWindowPosition(window.frame.origin)
    }

    func windowDidMove(_ notification: Notification) {
        guard !isOpeningAnimation, !isAnimatingClose, !isClosingAfterAnimation else { return }
        guard let window = notification.object as? NSWindow else { return }
        PreviewWindowSizeManager.shared.saveWindowPosition(window.frame.origin)
    }

    func beginOpeningAnimation() {
        isOpeningAnimation = true
    }

    func finishOpeningAnimation(for window: NSWindow) {
        isOpeningAnimation = false
        PreviewWindowSizeManager.shared.saveWindowSize(window.contentLayoutRect.size)
        PreviewWindowSizeManager.shared.saveWindowPosition(window.frame.origin)
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
    var onMagnify: ((CGFloat) -> Void)?

    override func magnify(with event: NSEvent) {
        onMagnify?(event.magnification)
    }

    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY

        if abs(dx) > 0.5 && abs(dy) > 0.5 {
            // Both axes have movement: apply them together to enable diagonal scrolling.
            // NSScrollView's default scrollWheel locks to the dominant axis at gesture start.
            // Constrain to the document bounds; scroll(to:) alone would let the image
            // leave the viewport entirely.
            let origin = contentView.bounds.origin
            let proposed = NSRect(
                origin: NSPoint(x: origin.x - dx, y: origin.y + dy),
                size: contentView.bounds.size
            )
            contentView.scroll(to: contentView.constrainBoundsRect(proposed).origin)
            reflectScrolledClipView(contentView)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

final class ZoomingImageView: NSImageView {
    var onMagnify: ((CGFloat) -> Void)?

    override func magnify(with event: NSEvent) {
        onMagnify?(event.magnification)
    }
}

// MARK: - Zoomable Image View (NSViewRepresentable)

struct ZoomableAsyncImageView: NSViewRepresentable {
    var url: URL
    var allowFullImageLoad: Bool = true
    var controller: ZoomController? = nil
    var rotationDegrees: Int = 0

    func makeNSView(context: Context) -> NSScrollView {
#if DEBUG
        print("[ZoomableAsyncImageView] makeNSView url=\(url.standardizedFileURL.path)")
#endif
        let scrollView = ObservingScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .clear

        let imageView = ZoomingImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = true

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
        panGesture.delegate = context.coordinator
        imageView.addGestureRecognizer(panGesture)

        scrollView.allowsMagnification = false
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 10.0
        scrollView.contentView.postsBoundsChangedNotifications = true
        let coordinator = context.coordinator
        scrollView.onMagnify = { [weak coordinator] magnificationDelta in
            coordinator?.magnify(by: magnificationDelta)
        }
        imageView.onMagnify = { [weak coordinator] magnificationDelta in
            coordinator?.magnify(by: magnificationDelta)
        }

        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView
        context.coordinator.setAllowsFullImageLoad(allowFullImageLoad)
        context.coordinator.syncWithController()
        context.coordinator.observeBoundsChanges()
        context.coordinator.loadImage(from: url)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
#if DEBUG
        print("[ZoomableAsyncImageView] updateNSView url=\(url.standardizedFileURL.path) current=\(context.coordinator.currentURL?.path ?? "nil")")
#endif
        context.coordinator.parent = self
        context.coordinator.syncWithController()
        context.coordinator.setAllowsFullImageLoad(allowFullImageLoad)
        if context.coordinator.currentURL != url.standardizedFileURL {
            context.coordinator.loadImage(from: url)
        } else {
            context.coordinator.setRotation(rotationDegrees)
            context.coordinator.applyInitialFitIfNeeded()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSGestureRecognizerDelegate, ZoomControlTarget {
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
        // The enlarged preview is used for inspecting one selected photo at a time,
        // so it decodes the full image immediately and resets each new image to 100%.
        private var loadGeneration = 0
        private var allowsFullImageLoad = true
        private var allowsCurrentImageUpscaling = false
        private var panStartOrigin: NSPoint?
        private var persistedMagnification: CGFloat? = nil
        private var originalImageSize: NSSize = .zero
        private var currentScale: CGFloat = 1.0
        private var needsInitialFit = false
        // Unrotated source image; rotation renders a rotated copy so scroll/zoom
        // logic keeps working against the displayed (possibly swapped) dimensions.
        private var baseImage: NSImage?
        private var appliedRotationDegrees = 0

        init(_ parent: ZoomableAsyncImageView) {
            self.parent = parent
        }

        func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool {
            true
        }

        deinit {
            parent.controller?.clearTarget(self)
            if let observer = boundsObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func setAllowsFullImageLoad(_ isAllowed: Bool) {
            guard allowsFullImageLoad != isAllowed else { return }
            allowsFullImageLoad = isAllowed
        }

        func setRotation(_ degrees: Int) {
            let normalized = Self.normalizedDegrees(degrees)
            guard normalized != appliedRotationDegrees else { return }
            appliedRotationDegrees = normalized
            guard let baseImage, let imageView else { return }

            let displayImage = Self.rotatedImage(baseImage, degrees: normalized)
            originalImageSize = displayImage.size
            imageView.image = displayImage
            imageView.frame = NSRect(origin: .zero, size: displayImage.size)
#if DEBUG
            debugLog("setRotation -> \(normalized)° displaySize=\(displayImage.size)")
#endif
            // Rotation swaps the aspect ratio, so refit the whole image into the viewport.
            userHasAdjustedZoom = false
            applyInitialFitIfNeeded(force: true, clearPersisted: true, center: true)
        }

        private static func normalizedDegrees(_ degrees: Int) -> Int {
            ((degrees % 360) + 360) % 360
        }

        private static func rotatedImage(_ image: NSImage, degrees: Int) -> NSImage {
            let normalized = normalizedDegrees(degrees)
            guard normalized != 0,
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let rotated = rotatedCGImage(cgImage, degrees: normalized) else {
                return image
            }
            return NSImage(cgImage: rotated, size: NSSize(width: rotated.width, height: rotated.height))
        }

        private static func rotatedCGImage(_ cgImage: CGImage, degrees: Int) -> CGImage? {
            let quarterTurn = degrees % 180 != 0
            let width = quarterTurn ? cgImage.height : cgImage.width
            let height = quarterTurn ? cgImage.width : cgImage.height
            let colorSpace: CGColorSpace
            if let sourceSpace = cgImage.colorSpace, sourceSpace.model == .rgb {
                colorSpace = sourceSpace
            } else {
                colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            }
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }

            context.interpolationQuality = .high
            context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
            // Stored degrees are clockwise; CGContext rotation is counterclockwise-positive.
            context.rotate(by: -CGFloat(degrees) * .pi / 180)
            context.draw(cgImage, in: CGRect(
                x: -CGFloat(cgImage.width) / 2,
                y: -CGFloat(cgImage.height) / 2,
                width: CGFloat(cgImage.width),
                height: CGFloat(cgImage.height)
            ))
            return context.makeImage()
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
            persistedMagnification = nil
            currentScale = actualPixelScale
            lastAppliedFitScale = nil
            needsInitialFit = true
            baseImage = nil

#if DEBUG
            debugLog("loadImage generation=\(generation) url=\(requestURL.path)")
#endif
            loadFullImageImmediately(from: requestURL, generation: generation)
        }

        private func displayLoadedImage(_ image: NSImage, allowsUpscaling: Bool) {
            guard let imageView else {
#if DEBUG
                debugLog("displayLoadedImage skipped: imageView is nil")
#endif
                return
            }
            allowsCurrentImageUpscaling = allowsUpscaling
            baseImage = image
            appliedRotationDegrees = Self.normalizedDegrees(parent.rotationDegrees)
            let displayImage = Self.rotatedImage(image, degrees: appliedRotationDegrees)
            originalImageSize = displayImage.size
            imageView.image = displayImage
            imageView.frame = NSRect(origin: .zero, size: displayImage.size)
            didApplyInitialFit = false
            userHasAdjustedZoom = false
            if let scrollView {
                scrollView.documentView = imageView
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
#if DEBUG
            debugLog("displayLoadedImage size=\(image.size) isValid=\(image.isValid) allowsUpscaling=\(allowsUpscaling) frame=\(imageView.frame)")
#endif
            applyPendingInitialFit()
            DispatchQueue.main.async { [weak self] in
                self?.applyPendingInitialFit()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                self?.applyPendingInitialFit()
            }
        }

        private func loadFullImageImmediately(from url: URL, generation: Int) {
            guard allowsFullImageLoad else {
#if DEBUG
                debugLog("loadFullImageImmediately skipped: allowsFullImageLoad=false generation=\(generation)")
#endif
                return
            }

#if DEBUG
            let fileExists = FileManager.default.fileExists(atPath: url.path)
            debugLog("full load start generation=\(generation) exists=\(fileExists) url=\(url.path)")
#endif
            guard let decoded = Self.decodedFullImage(from: url) else {
#if DEBUG
                debugLog("full load failed: ImageIO returned nil generation=\(generation)")
#endif
                return
            }
#if DEBUG
            debugLog("full load decoded generation=\(generation) size=\(decoded.size) pixels=\(decoded.cgImage.width)x\(decoded.cgImage.height)")
#endif

            guard currentURL == url else {
#if DEBUG
                debugLog("full load ignored: currentURL changed generation=\(generation) current=\(currentURL?.lastPathComponent ?? "nil") loaded=\(url.lastPathComponent)")
#endif
                return
            }
            guard loadGeneration == generation else {
#if DEBUG
                debugLog("full load ignored: generation changed loaded=\(generation) current=\(loadGeneration)")
#endif
                return
            }

            let fullImage = NSImage(cgImage: decoded.cgImage, size: decoded.size)
            displayLoadedImage(fullImage, allowsUpscaling: false)
        }

        private static func decodedFullImage(from url: URL) -> (cgImage: CGImage, size: NSSize)? {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
                return nil
            }

            // Decode through the thumbnail API at full resolution with transform
            // enabled so the EXIF orientation is baked into the pixels;
            // CGImageSourceCreateImageAtIndex returns the raw (unrotated) pixels.
            var maxPixelSize = 0
            if let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
                let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
                let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
                maxPixelSize = max(width, height)
            }
            if maxPixelSize > 0 {
                let thumbnailOptions = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                ] as CFDictionary
                if let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions) {
                    return (
                        cgImage: cgImage,
                        size: NSSize(width: cgImage.width, height: cgImage.height)
                    )
                }
            }

            let imageOptions = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, imageOptions) else {
                return nil
            }

            return (
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
        }

        @objc func handleDoubleClick(gesture: NSClickGestureRecognizer) {
            guard let scrollView = scrollView ?? imageView?.enclosingScrollView else { return }
            let current = currentScale
            if abs(current - actualPixelScale) < zoomToggleTolerance {
                userHasAdjustedZoom = false
                applyInitialFitIfNeeded(force: true, clearPersisted: true, animated: true, center: true)
            } else {
                zoomToActualPixels(in: scrollView, animated: true, center: true)
            }
        }

        // Drag-to-pan when zoomed in: image follows the pointer like moving a physical photo.
        @objc func handlePan(_ gesture: NSPanGestureRecognizer) {
            guard let scrollView = scrollView else { return }
            let fitScale = lastAppliedFitScale ?? scrollView.minMagnification
            // Only pan when zoomed beyond fit scale
            guard currentScale > fitScale * 1.01 else {
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
                let mag = currentScale
                let newOrigin = NSPoint(
                    x: startOrigin.x - translation.x / mag,
                    y: startOrigin.y + translation.y / mag
                )
                let clipView = scrollView.contentView
                let proposed = NSRect(origin: newOrigin, size: clipView.bounds.size)
                clipView.scroll(to: clipView.constrainBoundsRect(proposed).origin)
                scrollView.reflectScrolledClipView(clipView)
            case .ended, .cancelled, .failed:
                panStartOrigin = nil
            default:
                break
            }
        }

        @objc func handleMagnification(_ gesture: NSMagnificationGestureRecognizer) {
            guard gesture.state == .began || gesture.state == .changed else { return }
            let delta = gesture.magnification
            guard abs(delta) > 0.0001 else { return }
            magnify(by: delta)
            gesture.magnification = 0
        }

        func applyInitialFitIfNeeded(force: Bool = false, clearPersisted: Bool = false, animated: Bool = false, center: Bool = false) {
            if clearPersisted { persistedMagnification = nil }
            guard force || (!didApplyInitialFit && !userHasAdjustedZoom) else { return }
            guard let scrollView = scrollView ?? imageView?.enclosingScrollView else { return }

            // Restore the zoom level the user previously set instead of fitting
            if let mag = persistedMagnification {
                let clamped = max(min(mag, scrollView.maxMagnification), 0.01)
                applyScale(clamped, in: scrollView, animated: false, center: center)
                didApplyInitialFit = true
                userHasAdjustedZoom = true
#if DEBUG
                debugLog("applyInitialFitIfNeeded: restored persisted magnification \(clamped)")
#endif
                return
            }

            guard let targetScale = calculateFitScale(for: scrollView) else { return }
#if DEBUG
            debugLog("applyInitialFitIfNeeded(force: \(force), animated: \(animated)) -> \(targetScale)")
#endif
            applyFit(scale: targetScale, in: scrollView, animated: animated, center: center)
            didApplyInitialFit = true
            needsInitialFit = false
        }

        private func applyPendingInitialFit() {
            guard needsInitialFit, !userHasAdjustedZoom else { return }
            applyInitialFitIfNeeded(force: true, clearPersisted: true, center: true)
        }

        func applyActualSizeIfNeeded(force: Bool = false, animated: Bool = false, center: Bool = false) {
            guard force || !didApplyInitialFit else { return }
            guard let scrollView = scrollView ?? imageView?.enclosingScrollView else {
#if DEBUG
                debugLog("applyActualSizeIfNeeded skipped: scrollView is nil")
#endif
                return
            }

            zoomToActualPixels(in: scrollView, animated: animated, center: center)
            didApplyInitialFit = true
            lastAppliedFitScale = nil
            reportCurrentZoom()
#if DEBUG
            debugLog("applyActualSizeIfNeeded bounds=\(scrollView.bounds) contentBounds=\(scrollView.contentView.bounds) documentFrame=\(scrollView.documentView?.frame ?? .zero)")
#endif
        }

        func syncWithController() {
            guard let controller = parent.controller else { return }
            controller.setTarget(self)
            reportCurrentZoom()
        }

        func zoomToFitFromController() {
            applyInitialFitIfNeeded(force: true, clearPersisted: true, animated: false, center: true)
            reportCurrentZoom()
        }

        func zoomToActualSizeFromController() {
            guard let scrollView = scrollView else { return }
            zoomToActualPixels(in: scrollView, animated: false, center: true)
            reportCurrentZoom()
        }

        func setMagnificationFromController(_ magnification: CGFloat) {
            guard let scrollView = scrollView else { return }
            applyScale(magnification, in: scrollView, animated: false, center: false)
            userHasAdjustedZoom = true
            persistedMagnification = currentScale
        }

        private func reportCurrentZoom() {
            parent.controller?.magnification = currentScale
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
                if self.needsInitialFit || (!self.didApplyInitialFit && !self.userHasAdjustedZoom) {
                    self.applyPendingInitialFit()
                } else {
                    self.performBoundsAwareFitIfNeeded(scrollView: scrollView)
                }
                self.reportCurrentZoom()
            }
        }

        private func performBoundsAwareFitIfNeeded(scrollView: NSScrollView) {
            guard !userHasAdjustedZoom else { return }
            guard let targetScale = calculateFitScale(for: scrollView) else { return }
            scrollView.minMagnification = min(targetScale, 0.05)

            guard let lastFit = lastAppliedFitScale else { return }
            let tolerance: CGFloat = 0.002
            if abs(currentScale - lastFit) <= tolerance {
#if DEBUG
                debugLog("auto-refit to \(targetScale) (current \(currentScale))")
#endif
                applyFit(scale: targetScale, in: scrollView, animated: false, center: true)
            }
        }

        private func calculateFitScale(for scrollView: NSScrollView) -> CGFloat? {
            guard let imageSize = imageView?.image?.size,
                  imageSize.width > 0,
                  imageSize.height > 0 else { return nil }

            let boundsSize = scrollView.contentView.bounds.size
            guard boundsSize.width > 0, boundsSize.height > 0 else { return nil }

            let scaleX = boundsSize.width / imageSize.width
            let scaleY = boundsSize.height / imageSize.height
            let fitScale = min(scaleX, scaleY)
            guard fitScale.isFinite, fitScale > 0 else { return nil }

            return fitScale
        }

        private func applyFit(scale: CGFloat, in scrollView: NSScrollView, animated: Bool, center: Bool = false) {
            let targetScale = max(min(scale, scrollView.maxMagnification), 0.01)
            scrollView.minMagnification = min(targetScale, 0.05)
            applyScale(targetScale, in: scrollView, animated: animated, center: center)
#if DEBUG
            debugLog("applyFit -> \(targetScale), userHasAdjusted = \(userHasAdjustedZoom)")
#endif
            lastAppliedFitScale = targetScale
            userHasAdjustedZoom = false
            reportCurrentZoom()
        }

        func magnify(by delta: CGFloat) {
            guard let scrollView else { return }
            let targetScale = currentScale * max(0.1, 1 + delta)
            applyScale(targetScale, in: scrollView, animated: false, center: false)
#if DEBUG
            if !userHasAdjustedZoom {
                debugLog("user adjusted zoom (current magnification: \(currentScale))")
            }
#endif
            userHasAdjustedZoom = true
            persistedMagnification = currentScale
        }

#if DEBUG
        private func debugLog(_ message: String) {
            print("[ZoomableAsyncImageView] \(message)")
        }
#endif

        private func zoomToActualPixels(in scrollView: NSScrollView, animated: Bool, center: Bool = false) {
            let clamped = max(min(actualPixelScale, scrollView.maxMagnification), 0.01)
            applyScale(clamped, in: scrollView, animated: animated, center: center)
#if DEBUG
            debugLog("zoomToActualPixels -> \(clamped)")
#endif
            userHasAdjustedZoom = true
            persistedMagnification = clamped
            reportCurrentZoom()
        }

        private func applyScale(_ scale: CGFloat, in scrollView: NSScrollView, animated: Bool, center: Bool = false) {
            guard let imageView, originalImageSize.width > 0, originalImageSize.height > 0 else { return }
            let clamped = max(min(scale, scrollView.maxMagnification), scrollView.minMagnification)
            let oldScale = max(currentScale, 0.0001)
            let oldCenter = NSPoint(
                x: scrollView.contentView.bounds.midX,
                y: scrollView.contentView.bounds.midY
            )
            let newSize = NSSize(
                width: originalImageSize.width * clamped,
                height: originalImageSize.height * clamped
            )
            let newFrame = NSRect(origin: .zero, size: newSize)

            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    imageView.animator().frame = newFrame
                }
            } else {
                imageView.frame = newFrame
            }

            currentScale = clamped
            let newCenter = center
                ? NSPoint(x: newSize.width / 2, y: newSize.height / 2)
                : NSPoint(
                    x: oldCenter.x / oldScale * clamped,
                    y: oldCenter.y / oldScale * clamped
                )
            let newOrigin = NSPoint(
                x: newCenter.x - scrollView.contentView.bounds.width / 2,
                y: newCenter.y - scrollView.contentView.bounds.height / 2
            )
            scrollView.contentView.scroll(to: constrainedOrigin(newOrigin, documentSize: newSize, viewportSize: scrollView.contentView.bounds.size))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            reportCurrentZoom()
        }

        private func constrainedOrigin(_ origin: NSPoint, documentSize: NSSize, viewportSize: NSSize) -> NSPoint {
            NSPoint(
                x: documentSize.width <= viewportSize.width
                    ? (documentSize.width - viewportSize.width) / 2
                    : min(max(origin.x, 0), documentSize.width - viewportSize.width),
                y: documentSize.height <= viewportSize.height
                    ? (documentSize.height - viewportSize.height) / 2
                    : min(max(origin.y, 0), documentSize.height - viewportSize.height)
            )
        }
    }
}
