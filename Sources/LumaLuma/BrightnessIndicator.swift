import AppKit
import SwiftUI

@MainActor
final class BrightnessIndicator {
    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 192, height: 84),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private var dismiss: Task<Void, Never>?
    private let model = Model()

    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: IndicatorView(model: model))
    }

    func show(label: String, symbol: String, value: Double, percentage: Int? = nil, on screen: NSScreen) {
        dismiss?.cancel()
        model.update(label: label, symbol: symbol, value: value, percentage: percentage)
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.minY + 48
        ))
        panel.orderFrontRegardless()
        dismiss = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(1100))
            } catch {
                return
            }
            self?.hide()
        }
    }

    func hide() {
        dismiss?.cancel()
        dismiss = nil
        panel.orderOut(nil)
    }

    @MainActor
    private final class Model: ObservableObject {
        @Published private(set) var label = ""
        @Published private(set) var symbol = "sun.max"
        @Published private(set) var value = 0.0
        @Published private(set) var percentage: Int?

        func update(label: String, symbol: String, value: Double, percentage: Int?) {
            self.label = label
            self.symbol = symbol
            self.value = value
            self.percentage = percentage
        }
    }

    private struct IndicatorView: View {
        @ObservedObject var model: Model

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Label(model.label, systemImage: model.symbol)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    Text(displayedValue, format: .percent.precision(.fractionLength(0)))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: model.value) {
                    Text(model.label)
                }
                .labelsHidden()
                .controlSize(.small)
            }
            .padding(14)
            .frame(width: 188, height: 78)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))
            .overlay {
                RoundedRectangle(cornerRadius: 17)
                    .strokeBorder(.primary.opacity(0.12))
            }
        }

        private var displayedValue: Double {
            model.percentage.map { Double($0) / 100 } ?? model.value
        }
    }
}
