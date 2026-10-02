import SwiftUI

struct SignalPathNode: Identifiable, Equatable {
    enum Kind: Equatable {
        case app
        case processEQ
        case gain
        case outputEQ
        case output
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    var isActive = false
    var isFailed = false
}

/// A compact, literal map of the selected app's render order. Accent color
/// communicates stage at a glance, while the stage names keep it usable when
/// color differentiation is unavailable.
struct SignalPathView: View {
    let nodes: [SignalPathNode]
    var pulseToken: UUID?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                nodeView(node)
                if index < nodes.count - 1 {
                    connector(failedAfter: node.isFailed)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(AuralisColor.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(AuralisColor.hairline)
        )
        .overlay {
            if let pulseToken, !reduceMotion {
                ConfirmedSignalPulse(token: pulseToken)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            nodes.map { "\($0.title), \($0.detail)" }.joined(separator: ", then ")
        )
    }

    private func nodeView(_ node: SignalPathNode) -> some View {
        let accent = accent(for: node.kind)
        return VStack(spacing: 2) {
            Text(node.title)
                .font(AuralisTypography.workspaceTitle(12))
                .foregroundStyle(node.isFailed ? Color.red : accent)
                .lineLimit(1)
            Text(node.detail)
                .font(AuralisTypography.metric(9))
                .foregroundStyle(node.isFailed ? Color.red : Color.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(minWidth: 64, maxWidth: .infinity)
        .background(
            node.isActive ? accent.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(node.isActive ? accent.opacity(0.5) : Color.clear)
        )
        .accessibilityAddTraits(node.isActive ? .isSelected : [])
    }

    private func connector(failedAfter: Bool) -> some View {
        FlowConnector(failedAfter: failedAfter, isFlowing: nodes.contains(where: \.isActive))
    }

    private func accent(for kind: SignalPathNode.Kind) -> Color {
        switch kind {
        case .processEQ: AuralisColor.stageAccent(.process)
        case .outputEQ: AuralisColor.stageAccent(.output)
        case .app, .gain, .output: .primary
        }
    }
}

/// Hairline between stages. While any stage is selected, a short cyan dash
/// drifts left-to-right — the only ambient motion in the workbench, disabled
/// entirely under Reduce Motion.
private struct FlowConnector: View {
    let failedAfter: Bool
    let isFlowing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dashPhase: CGFloat = 0

    /// Dash + gap sum, so shifting the phase by one cycle loops seamlessly.
    private static let flowCycle: CGFloat = 8

    var body: some View {
        HStack(spacing: 2) {
            ZStack {
                Rectangle()
                    .fill(failedAfter ? Color.red : AuralisColor.hairline)
                    .frame(height: 1)
                if isFlowing, !failedAfter, !reduceMotion {
                    FlowDash()
                        .stroke(
                            AuralisColor.signalCyan.opacity(0.7),
                            style: StrokeStyle(
                                lineWidth: 1.5,
                                lineCap: .round,
                                dash: [2, 6],
                                dashPhase: dashPhase
                            )
                        )
                        .frame(height: 3)
                        .onAppear {
                            dashPhase = 0
                            DispatchQueue.main.async {
                                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                                    dashPhase = -Self.flowCycle
                                }
                            }
                        }
                        .onDisappear { dashPhase = 0 }
                }
            }
            .frame(maxWidth: .infinity)
            Image(systemName: "chevron.right")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(failedAfter ? Color.red : Color.secondary)
        }
        .frame(minWidth: 18, maxWidth: 34)
        .accessibilityHidden(true)
    }
}

/// A single horizontal line, so dash-phase animation travels along one path.
private struct FlowDash: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = rect.midY
        path.move(to: CGPoint(x: rect.minX, y: midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: midY))
        return path
    }
}

private struct ConfirmedSignalPulse: View {
    let token: UUID
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(AuralisColor.signalCyan)
                .frame(width: 12, height: 2)
                .offset(
                    x: max(proxy.size.width - 12, 0) * progress,
                    y: proxy.size.height - 3
                )
                .onAppear {
                    progress = 0
                    withAnimation(.easeInOut(duration: 0.7)) {
                        progress = 1
                    }
                }
                .id(token)
        }
    }
}

enum SignalPathBuilder {
    static func nodes(
        appName: String,
        volume: Double,
        isMuted: Bool,
        boost: BoostLevel,
        outputName: String,
        activeStage: EQStage? = nil,
        failedAt: SignalPathNode.Kind? = nil
    ) -> [SignalPathNode] {
        nodes(
            appName: appName,
            volume: volume,
            isMuted: isMuted,
            boost: boost,
            outputNames: [outputName],
            activeStage: activeStage,
            failedAt: failedAt
        )
    }

    static func nodes(
        appName: String,
        volume: Double,
        isMuted: Bool,
        boost: BoostLevel,
        outputNames: [String],
        activeStage: EQStage? = nil,
        failedAt: SignalPathNode.Kind? = nil
    ) -> [SignalPathNode] {
        let normalizedOutputs = outputNames.isEmpty ? ["Output"] : outputNames
        let outputCount = normalizedOutputs.count
        let outputTitle = outputCount == 1
            ? shortName(normalizedOutputs[0])
            : "\(outputCount) outputs"
        let outputDetail = outputCount == 1
            ? "Destination"
            : normalizedOutputs.map(shortName).joined(separator: " + ")
        let gainTitle = isMuted
            ? "Mute"
            : "\(Int((volume * 100).rounded()))%"
        let gainDetail = boost == .x1 ? "App gain" : "\(boost.label) boost"

        return [
            SignalPathNode(
                id: "app",
                kind: .app,
                title: shortName(appName),
                detail: "Source",
                isFailed: failedAt == .app
            ),
            SignalPathNode(
                id: "process-eq",
                kind: .processEQ,
                title: "Process EQ",
                detail: "Per app",
                isActive: activeStage == .process,
                isFailed: failedAt == .processEQ
            ),
            SignalPathNode(
                id: "gain",
                kind: .gain,
                title: gainTitle,
                detail: gainDetail,
                isFailed: failedAt == .gain
            ),
            SignalPathNode(
                id: "output-eq",
                kind: .outputEQ,
                title: outputCount == 1 ? "Output EQ" : "Output EQ ×\(outputCount)",
                detail: "Per device",
                isActive: activeStage == .output,
                isFailed: failedAt == .outputEQ
            ),
            SignalPathNode(
                id: "output",
                kind: .output,
                title: outputTitle,
                detail: outputDetail,
                isFailed: failedAt == .output
            ),
        ]
    }

    private static func shortName(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > 22 else { return value }
        return String(value.prefix(20)) + "…"
    }
}
