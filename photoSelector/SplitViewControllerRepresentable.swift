import SwiftUI

#if os(macOS)
import AppKit

struct SplitViewRepresentable<Left: View, Right: View>: NSViewRepresentable {
    var left: Left
    var right: Right
    var minLeft: CGFloat = 400
    var minRight: CGFloat = 200
    var splitPositionKey: String = "MainSplitPosition"

    class Coordinator: NSObject, NSSplitViewDelegate {
        var leftHost: NSHostingController<Left>?
        var rightHost: NSHostingController<Right>?
        var splitView: NSSplitView?
        var hasRestored = false
        var splitPositionKey: String = ""
        private var saveTimer: Timer?
        private var lastUserResizeAt: Date?

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard let splitView = notification.object as? NSSplitView else { return }
            self.splitView = splitView // Ensure reference is kept

            // Restore position on first resize
            if !hasRestored {
                hasRestored = true
                restorePosition(splitView: splitView)
                return
            }

            // Only treat changes during live resize (divider drag / window resize) as user intent.
            if splitView.inLiveResize || splitView.window?.inLiveResize == true {
                lastUserResizeAt = Date()

                // Debounce save operation (short delay to avoid excessive writes during drag)
                saveTimer?.invalidate()
                saveTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    self.savePosition(splitView: splitView)
                }
            }
        }
        
        private func restorePosition(splitView: NSSplitView) {
            if !splitPositionKey.isEmpty,
               let savedPosition = UserDefaults.standard.object(forKey: splitPositionKey) as? CGFloat,
               savedPosition > 0 {
                
                // Check if frame is ready
                if splitView.frame.width > savedPosition {
                    print("[\(splitPositionKey)] Restoring width: \(savedPosition) (Current Frame: \(splitView.frame.width))")
                    splitView.setPosition(savedPosition, ofDividerAt: 0)
                } else {
                    print("[\(splitPositionKey)] Deferred restore. Saved: \(savedPosition) > Current Frame: \(splitView.frame.width)")
                    // Retry after delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self = self else { return }
                        // Re-check constraints
                        if splitView.frame.width > savedPosition {
                            print("[\(self.splitPositionKey)] Retry restoring: \(savedPosition) (Current Frame: \(splitView.frame.width))")
                            splitView.setPosition(savedPosition, ofDividerAt: 0)
                        } else {
                            print("[\(self.splitPositionKey)] Failed to restore. Saved: \(savedPosition) > Current Frame: \(splitView.frame.width)")
                        }
                    }
                }
            } else {
                print("[\(splitPositionKey)] No saved position found")
            }
        }
        
        private func savePosition(splitView: NSSplitView) {
            guard !self.splitPositionKey.isEmpty,
                  let leftView = splitView.arrangedSubviews.first
            else { return }

            // Prevent programmatic layout changes from overwriting persisted values.
            // Allow saving only shortly after a live resize interaction.
            if let last = lastUserResizeAt, Date().timeIntervalSince(last) > 2.0 {
                return
            }

            let position = leftView.frame.width

            // Only save if window is visible and size is reasonable
            if position > 0 && splitView.window?.isVisible == true {
                UserDefaults.standard.set(position, forKey: self.splitPositionKey)
                print("[\(self.splitPositionKey)] Saved width: \(position)")
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.splitPositionKey = splitPositionKey
        return coordinator
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        let leftHC = NSHostingController(rootView: left)
        let rightHC = NSHostingController(rootView: right)

        let leftView = leftHC.view
        let rightView = rightHC.view

        // Set holding priority for resize behavior
        // Default: Left view holds size (.defaultHigh), Right view resizes (.defaultLow)
        // If we want the right panel to keep its size (e.g. fixed sidebar), we should swap priorities.
        // However, standard behavior for sidebar apps is usually left sidebar fixed, main content resizes.
        // For our case (Tree | Grid | RightPanel), we probably want Tree and RightPanel to hold size, Grid to resize.
        // Since we are nesting split views, let's adjust based on typical sidebar behavior.
        
        // Left side (Tree or Grid) should hold priority over Right side (RightPanel or Grid)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        leftView.translatesAutoresizingMaskIntoConstraints = true
        rightView.translatesAutoresizingMaskIntoConstraints = true

        splitView.addArrangedSubview(leftView)
        splitView.addArrangedSubview(rightView)

        // Set delegate for resize behavior
        splitView.delegate = context.coordinator
        context.coordinator.splitView = splitView
        context.coordinator.leftHost = leftHC
        context.coordinator.rightHost = rightHC

        return splitView
    }

    func updateNSView(_ nsView: NSSplitView, context: Context) {
        if let leftHost = context.coordinator.leftHost {
            leftHost.rootView = left
        }
        if let rightHost = context.coordinator.rightHost {
            rightHost.rootView = right
        }
    }

    static func dismantleNSView(_ nsView: NSSplitView, coordinator: Coordinator) {
        // Clean up if needed
    }
}

struct VerticalSplitViewRepresentable<Top: View, Bottom: View>: NSViewRepresentable {
    var top: Top
    var bottom: Bottom
    var minTop: CGFloat = 150
    var minBottom: CGFloat = 150
    var splitPositionKey: String = "RightPanelVerticalSplitPosition"

    class Coordinator: NSObject, NSSplitViewDelegate {
        var topHost: NSHostingController<Top>?
        var bottomHost: NSHostingController<Bottom>?
        var splitView: NSSplitView?
        var hasRestored = false
        var splitPositionKey: String = ""
        private var saveTimer: Timer?
        private var lastUserResizeAt: Date?

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard let splitView = notification.object as? NSSplitView else { return }
            self.splitView = splitView // Ensure reference is kept

            // Restore position on first resize
            if !hasRestored {
                hasRestored = true
                restorePosition(splitView: splitView)
                return
            }

            if splitView.inLiveResize || splitView.window?.inLiveResize == true {
                lastUserResizeAt = Date()

                // Debounce save operation (short delay to avoid excessive writes during drag)
                saveTimer?.invalidate()
                saveTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    self.savePosition(splitView: splitView)
                }
            }
        }
        
        private func restorePosition(splitView: NSSplitView) {
            if !splitPositionKey.isEmpty,
               let savedPosition = UserDefaults.standard.object(forKey: splitPositionKey) as? CGFloat,
               savedPosition > 0 {
                
                // Check if frame is ready
                if splitView.frame.height > savedPosition {
                    print("[\(splitPositionKey)] Restoring height: \(savedPosition) (Current Frame: \(splitView.frame.height))")
                    splitView.setPosition(savedPosition, ofDividerAt: 0)
                } else {
                    print("[\(splitPositionKey)] Deferred restore. Saved: \(savedPosition) > Current Frame: \(splitView.frame.height)")
                    // Retry after delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self = self else { return }
                        // Re-check constraints
                        if splitView.frame.height > savedPosition {
                            print("[\(self.splitPositionKey)] Retry restoring: \(savedPosition) (Current Frame: \(splitView.frame.height))")
                            splitView.setPosition(savedPosition, ofDividerAt: 0)
                        } else {
                            print("[\(self.splitPositionKey)] Failed to restore. Saved: \(savedPosition) > Current Frame: \(splitView.frame.height)")
                        }
                    }
                }
            } else {
                print("[\(splitPositionKey)] No saved position found")
            }
        }
        
        private func savePosition(splitView: NSSplitView) {
            guard !self.splitPositionKey.isEmpty,
                  let topView = splitView.arrangedSubviews.first
            else { return }

            if let last = lastUserResizeAt, Date().timeIntervalSince(last) > 2.0 {
                return
            }

            let position = topView.frame.height

            // Only save if window is visible and size is reasonable
            if position > 0 && splitView.window?.isVisible == true {
                UserDefaults.standard.set(position, forKey: self.splitPositionKey)
                print("[\(self.splitPositionKey)] Saved height: \(position)")
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.splitPositionKey = splitPositionKey
        return coordinator
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = NSSplitView()
        splitView.isVertical = false // Horizontal divider for top/bottom split
        splitView.dividerStyle = .thin

        let topHC = NSHostingController(rootView: top)
        let bottomHC = NSHostingController(rootView: bottom)

        let topView = topHC.view
        let bottomView = bottomHC.view

        // Set holding priority for resize behavior
        // Give the top view a higher priority to hold its size (it won't shrink/grow easily)
        // This means when window resizes, the bottom view will take the change.
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        topView.translatesAutoresizingMaskIntoConstraints = true
        bottomView.translatesAutoresizingMaskIntoConstraints = true

        splitView.addArrangedSubview(topView)
        splitView.addArrangedSubview(bottomView)

        // Set delegate for resize behavior
        splitView.delegate = context.coordinator
        context.coordinator.splitView = splitView
        context.coordinator.topHost = topHC
        context.coordinator.bottomHost = bottomHC

        return splitView
    }

    func updateNSView(_ nsView: NSSplitView, context: Context) {
        if let topHost = context.coordinator.topHost {
            topHost.rootView = top
        }
        if let bottomHost = context.coordinator.bottomHost {
            bottomHost.rootView = bottom
        }
    }

    static func dismantleNSView(_ nsView: NSSplitView, coordinator: Coordinator) {
        // Clean up if needed
    }
}

#endif
