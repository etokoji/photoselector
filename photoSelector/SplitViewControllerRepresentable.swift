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

        func splitViewDidResizeSubviews(_ notification: Notification) {
            // Optional: Handle resize notifications here if needed
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

#endif
