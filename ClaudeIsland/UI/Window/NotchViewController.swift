//
//  NotchViewController.swift
//  ClaudeIsland
//
//  Hosts the SwiftUI NotchView in AppKit with click-through support
//

import AppKit
import SwiftUI

/// Custom NSHostingView that only accepts mouse events within the panel bounds.
/// Clicks outside the panel pass through to windows behind.
class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    var hitTestCheck: (NSPoint) -> Bool = { _ in false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true  // Handle first click directly, don't consume it for window activation
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only accept hits within the allowed zones
        guard hitTestCheck(point) else {
            return nil  // Pass through to windows behind
        }
        return super.hitTest(point)
    }
}

class NotchViewController: NSViewController {
    private let viewModel: NotchViewModel
    private var hostingView: PassThroughHostingView<NotchView>!

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        hostingView = PassThroughHostingView(rootView: NotchView(viewModel: viewModel))

        // Calculate whether a point is in a hittable zone based on panel state
        hostingView.hitTestCheck = { [weak self] point in
            guard let self = self else { return false }
            let vm = self.viewModel
            let geometry = vm.geometry

            // Window coordinates: origin at bottom-left, Y increases upward
            // The window is positioned at top of screen, so panel is at top of window
            let windowHeight = geometry.windowHeight

            switch vm.status {
            case .opened:
                let panelSize = vm.openedSize
                // Panel is centered horizontally, anchored to top
                let panelWidth = panelSize.width + 52  // Account for corner radius padding
                let panelHeight = panelSize.height
                let screenWidth = geometry.screenRect.width
                let panelRect = CGRect(
                    x: (screenWidth - panelWidth) / 2,
                    y: windowHeight - panelHeight,
                    width: panelWidth,
                    height: panelHeight
                )
                return panelRect.contains(point)

            case .closed, .popping:
                // Notch zone
                let notchRect = geometry.deviceNotchRect
                let screenWidth = geometry.screenRect.width
                let notchHitRect = CGRect(
                    x: (screenWidth - notchRect.width) / 2 - 10,
                    y: windowHeight - notchRect.height - 5,
                    width: notchRect.width + 20,
                    height: notchRect.height + 10
                )
                if notchHitRect.contains(point) { return true }

                // Wings zone — full width, from top down to notch height + expanded height
                if vm.wingsVisible {
                    let wingsHeight = notchRect.height + vm.wingsExpandedHeight
                    let wingsRect = CGRect(
                        x: 0,
                        y: windowHeight - wingsHeight,
                        width: screenWidth,
                        height: wingsHeight
                    )
                    return wingsRect.contains(point)
                }

                return false
            }
        }

        self.view = hostingView
    }
}
