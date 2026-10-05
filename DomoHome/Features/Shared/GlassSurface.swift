import SwiftUI

extension View {
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat, tint: Color = .cyan, glow: Double = 0) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                .glassEdge(cornerRadius: cornerRadius, tint: tint, glow: glow)
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .glassEdge(cornerRadius: cornerRadius, tint: tint, glow: glow)
        }
    }

    private func glassEdge(cornerRadius: CGFloat, tint: Color, glow: Double) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [tint.opacity(glow * 0.12), .clear],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 280
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.2), tint.opacity(0.16 + glow * 0.12), tint.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
                .allowsHitTesting(false)
        }
        .shadow(color: tint.opacity(glow * 0.08), radius: 14, y: 4)
    }

    @ViewBuilder
    func glassActionStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}
