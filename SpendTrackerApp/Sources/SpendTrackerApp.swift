import AppKit
import Combine
import SwiftUI

@main
struct SpendTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let store = SpendingStore()

    private var flashIntensity: CGFloat = 0
    private var lastTotal: Double = -1
    private var cancellables = Set<AnyCancellable>()

    private static let neon = NSColor(calibratedRed: 0.18, green: 1.0, blue: 0.34, alpha: 1.0)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.target = self
            btn.action = #selector(togglePopover(_:))
            btn.imagePosition = .imageOnly
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentSize = NSSize(width: 380, height: 440)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView().environmentObject(store)
        )

        store.$state
            .combineLatest(store.$isStale)
            .receive(on: RunLoop.main)
            .sink { [weak self] state, isStale in
                guard let self else { return }
                // Headline = v2 yesterday total + today_estimate when available;
                // falls back to v1 proxy total when registry isn't installed.
                let total = state.headlineUSD
                if self.lastTotal >= 0, abs(total - self.lastTotal) > 1e-9 {
                    self.flashIntensity = 1.0
                }
                self.flashIntensity = max(0, self.flashIntensity - 0.25)
                self.lastTotal = total
                self.statusItem.button?.image = self.renderIcon(total: total, stale: isStale)
            }
            .store(in: &cancellables)
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let btn = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
        }
    }

    private func renderIcon(total: Double, stale: Bool) -> NSImage {
        let neon = AppDelegate.neon
        let dim  = NSColor.secondaryLabelColor
        let main: NSColor = stale ? dim : neon

        let glow: CGFloat = stale ? 0 : (0.65 + 0.35 * flashIntensity)

        let totalStr = String(format: "$%.2f", total)
        let costFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)

        let costShadow = NSShadow()
        costShadow.shadowColor = stale ? .clear : neon.withAlphaComponent(min(1.0, glow * 0.9))
        costShadow.shadowBlurRadius = 3 + 4 * glow
        costShadow.shadowOffset = .zero
        let costAttrs: [NSAttributedString.Key: Any] = [
            .font: costFont,
            .foregroundColor: main,
            .shadow: costShadow,
        ]
        let costSize = (totalStr as NSString).size(withAttributes: costAttrs)

        let circleD: CGFloat = 18
        let gap: CGFloat = 5
        let leftPad: CGFloat = 6
        let rightPad: CGFloat = 7
        let totalW = leftPad + circleD + gap + ceil(costSize.width) + rightPad
        let totalH: CGFloat = 22

        let img = NSImage(size: NSSize(width: totalW, height: totalH))
        img.lockFocus()
        defer { img.unlockFocus() }

        let circleRect = NSRect(x: leftPad, y: (totalH - circleD) / 2, width: circleD, height: circleD)

        let circleShadow = NSShadow()
        circleShadow.shadowColor = stale ? .clear : neon.withAlphaComponent(min(1.0, glow))
        circleShadow.shadowBlurRadius = 5 + 5 * glow
        circleShadow.shadowOffset = .zero
        circleShadow.set()
        main.setFill()
        NSBezierPath(ovalIn: circleRect).fill()

        let clearShadow = NSShadow()
        clearShadow.shadowColor = .clear
        clearShadow.set()

        let dollar = "$" as NSString
        let dollarFont = NSFont.systemFont(ofSize: 13, weight: .black)
        let dollarAttrs: [NSAttributedString.Key: Any] = [
            .font: dollarFont,
            .foregroundColor: NSColor.black.withAlphaComponent(0.92),
        ]
        let dSize = dollar.size(withAttributes: dollarAttrs)
        let dPoint = NSPoint(
            x: circleRect.midX - dSize.width / 2,
            y: circleRect.midY - dSize.height / 2 + 0.5
        )
        dollar.draw(at: dPoint, withAttributes: dollarAttrs)

        let costPoint = NSPoint(
            x: leftPad + circleD + gap,
            y: (totalH - costSize.height) / 2
        )
        (totalStr as NSString).draw(at: costPoint, withAttributes: costAttrs)

        img.isTemplate = false
        return img
    }
}
