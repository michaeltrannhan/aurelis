import SwiftUI

struct SignalPathNode: Identifiable, Equatable {
    enum Kind: Equatable {
        case app
        case gain
        case eq
        case boost
        case output
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    var isFailed: Bool = false
}

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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AuralisColor.panel.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            if let pulseToken, !reduceMotion {
                AuroraPulseOverlay(token: pulseToken)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        nodes.map { "\($0.title) \($0.detail)" }.joined(separator: ", then ")
    }

    private func nodeView(_ node: SignalPathNode) -> some View {
        VStack(spacing: 3) {
            Text(node.title)
                .font(AuralisTypography.workspaceTitle(13))
                .foregroundStyle(node.isFailed ? AuralisColor.peakRose : .primary)
                .lineLimit(1)
            Text(node.detail)
                .font(AuralisTypography.metric(11))
                .foregroundStyle(node.isFailed ? AuralisColor.peakRose : .secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 72)
        .padding(.horizontal, 6)
        .accessibilityAddTraits(node.isFailed ? .isSelected : [])
    }

    private func connector(failedAfter: Bool) -> some View {
        Rectangle()
            .fill(failedAfter ? AuralisColor.peakRose.opacity(0.55) : AuralisColor.signalCyan.opacity(0.45))
            .frame(height: 2)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
    }
}

private struct AuroraPulseOverlay: View {
    let token: UUID
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            Circle()
                .fill(
                    RadialGradient(
                        colors: [AuralisColor.signalCyan.opacity(0.55), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 18
                    )
                )
                .frame(width: 28, height: 28)
                .offset(x: (geo.size.width - 28) * progress, y: (geo.size.height - 28) / 2)
                .onAppear {
                    progress = 0
                    withAnimation(.easeInOut(duration: 0.85)) {
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
        failedAt: SignalPathNode.Kind? = nil
    ) -> [SignalPathNode] {
        let percent = "\(Int((volume * 100).rounded()))%"
        return [
            SignalPathNode(id: "app", kind: .app, title: appName, detail: "Source", isFailed: failedAt == .app),
            SignalPathNode(
                id: "gain",
                kind: .gain,
                title: isMuted ? "Mute" : percent,
                detail: isMuted ? "Muted" : "Level",
                isFailed: failedAt == .gain
            ),
            SignalPathNode(id: "eq", kind: .eq, title: "EQ", detail: "10-band", isFailed: failedAt == .eq),
            SignalPathNode(
                id: "boost",
                kind: .boost,
                title: boost.label,
                detail: "Boost",
                isFailed: failedAt == .boost
            ),
            SignalPathNode(
                id: "output",
                kind: .output,
                title: outputName,
                detail: "Output",
                isFailed: failedAt == .output
            ),
        ]
    }
}
