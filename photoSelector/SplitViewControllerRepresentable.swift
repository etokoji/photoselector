import SwiftUI

#if os(macOS)
import AppKit

struct SplitViewRepresentable<Left: View, Right: View>: NSViewRepresentable {
    var left: Left
    var right: Right
    var minLeft: CGFloat = 400
    var minRight: CGFloat = 200

    class Coordinator: NSObject, NSSplitViewDelegate {
        var leftHost: NSHostingController<Left>?
        var rightHost: NSHostingController<Right>?
        var splitView: NSSplitView?
        var hasRestored = false

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard let splitView = notification.object as? NSSplitView else { return }
            
            // Restore position on first resize
            if !hasRestored {
                hasRestored = true
                if let savedPosition = UserDefaults.standard.object(forKey: "MainSplitPosition") as? CGFloat,
                   savedPosition > 0 {
                    DispatchQueue.main.async {
                        splitView.setPosition(savedPosition, ofDividerAt: 0)
                    }
                }
            } else {
                // Save position on subsequent resizes
                if let leftView = splitView.arrangedSubviews.first {
                    let position = leftView.frame.width
                    UserDefaults.standard.set(position, forKey: "MainSplitPosition")
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        let leftHC = NSHostingController(rootView: left)
        let rightHC = NSHostingController(rootView: right)

        let leftView = leftHC.view
        let rightView = rightHC.view

        // Set minimum thickness for resizing constraints
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

    class Coordinator: NSObject, NSSplitViewDelegate {
        var topHost: NSHostingController<Top>?
        var bottomHost: NSHostingController<Bottom>?
        var splitView: NSSplitView?
        var hasRestored = false

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard let splitView = notification.object as? NSSplitView else { return }
            
            // Restore position on first resize
            if !hasRestored {
                hasRestored = true
                if let savedPosition = UserDefaults.standard.object(forKey: "RightPanelSplitPosition") as? CGFloat,
                   savedPosition > 0 {
                    DispatchQueue.main.async {
                        splitView.setPosition(savedPosition, ofDividerAt: 0)
                    }
                }
            } else {
                // Save position on subsequent resizes
                if let topView = splitView.arrangedSubviews.first {
                    let position = topView.frame.height
                    UserDefaults.standard.set(position, forKey: "RightPanelSplitPosition")
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = NSSplitView()
        splitView.isVertical = false // Horizontal divider for top/bottom split
        splitView.dividerStyle = .thin
        
        // Enable automatic position saving
        splitView.autosaveName = NSSplitView.AutosaveName("RightPanelVerticalSplit")

        let topHC = NSHostingController(rootView: top)
        let bottomHC = NSHostingController(rootView: bottom)

        let topView = topHC.view
        let bottomView = bottomHC.view

        // Use translatesAutoresizingMaskIntoConstraints = true for split views
        topView.translatesAutoresizingMaskIntoConstraints = true
        bottomView.translatesAutoresizingMaskIntoConstraints = true

        splitView.addArrangedSubview(topView)
        splitView.addArrangedSubview(bottomView)

        // Set holding priority for resize behavior
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

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
        // NSSplitView automatically restores position when autosaveName is set
    }

    static func dismantleNSView(_ nsView: NSSplitView, coordinator: Coordinator) {
        // Clean up if needed
    }
}

#endif
