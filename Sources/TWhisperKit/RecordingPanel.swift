import AppKit
import SwiftUI

/// A borderless, non-activating HUD panel with a Siri-inspired voice waveform.
/// Never activates T-Whisper and never becomes key/main.
@MainActor
final class RecordingPanel {
    private var panel: NSPanel?

    func show(model: AppModel, on screen: NSScreen?) {
        let panel = panel ?? makePanel()
        self.panel = panel

        let hostingView = NSHostingView(rootView: RecordingHUDView(model: model))
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        panel.setContentSize(hostingView.fittingSize)

        if let targetScreen = screen ?? NSScreen.main {
            let visible = targetScreen.visibleFrame
            let size = panel.frame.size
            let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 40)
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 168),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.worksWhenModal = true
        return panel
    }
}

private struct RecordingHUDView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            if model.phase == .recording {
                SiriWaveform(level: model.recordingLevel)
                    .frame(height: 58)
                    .accessibilityHidden(true)
            } else {
                ProcessingGlyph(symbol: phaseSymbol, color: phaseColor)
                    .frame(height: 58)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 8) {
                Text(statusText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                if model.phase == .recording {
                    Text(elapsedText)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }

            if !captionText.isEmpty {
                Text(captionText)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 340)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.black.opacity(0.82))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.32), radius: 20, y: 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var phaseColor: Color {
        switch model.phase {
        case .recording: return .red
        case .transcribing, .normalizing, .inserting: return .cyan
        case .failed: return .orange
        default: return .secondary
        }
    }

    private var phaseSymbol: String {
        switch model.phase {
        case .transcribing: return "waveform"
        case .normalizing: return "wand.and.stars"
        case .inserting: return "arrow.right.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "circle.fill"
        }
    }

    private var statusText: String {
        switch model.phase {
        case .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .normalizing: return "Processing text…"
        case .inserting: return "Inserting…"
        case .failed: return "Dictation failed"
        default: return " "
        }
    }

    private var recordingModeHint: String {
        switch model.sessionInputKind {
        case .hold: return "Release to stop"
        case .handsFree: return "Press shortcut again to stop"
        }
    }

    private var captionText: String {
        if model.phase == .failed {
            return model.errorMessage ?? "Something went wrong"
        }
        var parts: [String] = []
        if model.phase == .recording { parts.append(recordingModeHint) }
        if model.escapeAvailable { parts.append("Esc to cancel") }
        return parts.joined(separator: " · ")
    }

    private var elapsedText: String {
        let total = Int(model.recordingElapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var accessibilitySummary: String {
        [statusText, model.phase == .recording ? elapsedText : nil, captionText]
            .compactMap { $0 }
            .joined(separator: ". ")
    }
}

private struct SiriWaveform: View {
    let level: Float

    private let barCount = 27

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(barColor(for: index))
                    .frame(width: 5, height: barHeight(for: index))
                    .shadow(color: barColor(for: index).opacity(0.5), radius: 5)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.24, dampingFraction: 0.62), value: level)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let distanceFromCenter = abs(CGFloat(index) - CGFloat(barCount - 1) / 2)
        let envelope = max(0, 1 - distanceFromCenter / (CGFloat(barCount) / 2))
        let variation = 0.76 + 0.24 * abs(sin(Double(index) * 1.73))
        let amplitude = max(CGFloat(level), 0.08)
        return 5 + 48 * envelope * amplitude * variation
    }

    private func barColor(for index: Int) -> Color {
        let progress = Double(index) / Double(barCount - 1)
        return Color(
            hue: 0.56 + 0.30 * progress,
            saturation: 0.82,
            brightness: 1
        )
    }
}

private struct ProcessingGlyph: View {
    let symbol: String
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.16))
                .frame(width: 54, height: 54)
            Circle()
                .stroke(color.opacity(0.42), lineWidth: 1)
                .frame(width: 54, height: 54)
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(color)
        }
    }
}
