import SwiftUI
import UIKit

struct JoystickView: View {
    let onPress: (UInt8, Bool) -> Void

    private let baseSize: CGFloat = 130
    private let knobSize: CGFloat = 56
    private var radius: CGFloat { (baseSize - knobSize) / 2 }

    @State private var knobOffset: CGSize = .zero
    @State private var activeDirection: UInt8? = nil

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.10))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.24), lineWidth: 1))
                .frame(width: baseSize, height: baseSize)

            Circle()
                .fill(Color.white.opacity(0.26))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.38), lineWidth: 1))
                .frame(width: knobSize, height: knobSize)
                .offset(knobOffset)
                .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.72), value: knobOffset)
        }
        .frame(width: baseSize, height: baseSize)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    update(translation: value.translation)
                }
                .onEnded { _ in
                    reset()
                }
        )
    }

    private func update(translation: CGSize) {
        let dx = translation.width
        let dy = translation.height
        let rawDistance = sqrt(dx * dx + dy * dy)
        let distance = min(rawDistance, radius)

        if rawDistance > 0 {
            let scale = distance / rawDistance
            knobOffset = CGSize(width: dx * scale, height: dy * scale)
        } else {
            knobOffset = .zero
        }

        let deadzone: CGFloat = 10
        guard rawDistance > deadzone else {
            clearDirection()
            return
        }

        // True 8-way NES control. The normalized threshold deliberately keeps
        // broad diagonal zones so the stick reliably reaches all four corners.
        let nx = dx / rawDistance
        let ny = dy / rawDistance
        let axisThreshold: CGFloat = 0.38

        var newDir: UInt8 = 0

        if nx >= axisThreshold {
            newDir |= NESButton.Right
        } else if nx <= -axisThreshold {
            newDir |= NESButton.Left
        }

        if ny >= axisThreshold {
            newDir |= NESButton.Down
        } else if ny <= -axisThreshold {
            newDir |= NESButton.Up
        }

        // Safety fallback for a vector that lands between thresholds.
        if newDir == 0 {
            if abs(nx) > abs(ny) {
                newDir = nx >= 0 ? NESButton.Right : NESButton.Left
            } else {
                newDir = ny >= 0 ? NESButton.Down : NESButton.Up
            }
        }

        if activeDirection != newDir {
            if let old = activeDirection {
                onPress(old, false)
            }
            onPress(newDir, true)
            activeDirection = newDir
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func clearDirection() {
        if let old = activeDirection {
            onPress(old, false)
        }
        activeDirection = nil
    }

    private func reset() {
        clearDirection()
        knobOffset = .zero
    }
}
