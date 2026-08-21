import SwiftUI
import UIKit

struct DPadView: View {
    let onPress: (UInt8, Bool) -> Void
    @State private var activeDirection: UInt8? = nil

    private let size: CGFloat = 132
    private let armWidth: CGFloat = 44

    var body: some View {
        ZStack {
            CrossShape(armWidth: armWidth)
                .fill(.ultraThinMaterial)
                .frame(width: size, height: size)
                .overlay(
                    CrossShape(armWidth: armWidth)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    CrossShape(armWidth: armWidth)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 10, y: 6)

            directionIndicator(.up)
            directionIndicator(.down)
            directionIndicator(.left)
            directionIndicator(.right)

            Circle()
                .fill(.thinMaterial)
                .frame(width: 22, height: 22)
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    updateDirection(at: value.location)
                }
                .onEnded { _ in
                    clearDirection()
                }
        )
    }

    private enum Dir { case up, down, left, right
        var mask: UInt8 {
            switch self {
            case .up: return NESButton.Up
            case .down: return NESButton.Down
            case .left: return NESButton.Left
            case .right: return NESButton.Right
            }
        }
    }

    @ViewBuilder
    private func directionIndicator(_ dir: Dir) -> some View {
        let isActive = activeDirection == dir.mask
        let arrow: String = {
            switch dir {
            case .up: return "▲"
            case .down: return "▼"
            case .left: return "◀"
            case .right: return "▶"
            }
        }()
        let offset: CGSize = {
            switch dir {
            case .up: return CGSize(width: 0, height: -size/2 + armWidth/2 + 4)
            case .down: return CGSize(width: 0, height: size/2 - armWidth/2 - 4)
            case .left: return CGSize(width: -size/2 + armWidth/2 + 4, height: 0)
            case .right: return CGSize(width: size/2 - armWidth/2 - 4, height: 0)
            }
        }()
        Text(arrow)
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(isActive ? .blue : .white.opacity(0.6))
            .offset(offset)
    }

    private func updateDirection(at point: CGPoint) {
        let center = CGPoint(x: size/2, y: size/2)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let deadzone: CGFloat = 14

        guard abs(dx) > deadzone || abs(dy) > deadzone else {
            clearDirection()
            return
        }

        let newDir: UInt8
        if abs(dx) > abs(dy) {
            newDir = dx > 0 ? NESButton.Right : NESButton.Left
        } else {
            newDir = dy > 0 ? NESButton.Down : NESButton.Up
        }

        if activeDirection != newDir {
            if let old = activeDirection { onPress(old, false) }
            onPress(newDir, true)
            activeDirection = newDir
            UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.9)
        }
    }

    private func clearDirection() {
        if let old = activeDirection { onPress(old, false) }
        activeDirection = nil
    }
}

private struct CrossShape: Shape {
    let armWidth: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        let a = armWidth
        path.addRoundedRect(in: CGRect(x: (w - a)/2, y: 0, width: a, height: h), cornerSize: CGSize(width: 6, height: 6))
        path.addRoundedRect(in: CGRect(x: 0, y: (h - a)/2, width: w, height: a), cornerSize: CGSize(width: 6, height: 6))
        return path
    }
}
