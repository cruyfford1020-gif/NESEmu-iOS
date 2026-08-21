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
                .fill(.ultraThinMaterial)
                .overlay(Circle().fill(Color.white.opacity(0.06)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                .frame(width: baseSize, height: baseSize)
                .shadow(color: .black.opacity(0.3), radius: 10, y: 6)

            Circle()
                .fill(.thinMaterial)
                .overlay(Circle().fill(Color.blue.opacity(0.35)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                .frame(width: knobSize, height: knobSize)
                .offset(knobOffset)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.7), value: knobOffset)
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
        let distance = min(sqrt(dx*dx + dy*dy), radius)
        let angle = atan2(dy, dx)
        knobOffset = CGSize(width: cos(angle) * distance, height: sin(angle) * distance)

        let deadzone: CGFloat = 12
        guard sqrt(dx*dx + dy*dy) > deadzone else {
            clearDirection()
            return
        }

        // 8-way joystick: allow two NES direction bits at the same time.
        // This is what makes the four corners work (Up+Left, Up+Right,
        // Down+Left, Down+Right) instead of collapsing every drag to a
        // single horizontal/vertical direction.
        let ax = abs(dx)
        let ay = abs(dy)
        let diagonalRatio: CGFloat = 0.42

        var newDir: UInt8 = 0
        if ax >= ay * diagonalRatio {
            newDir |= dx >= 0 ? NESButton.Right : NESButton.Left
        }
        if ay >= ax * diagonalRatio {
            newDir |= dy >= 0 ? NESButton.Down : NESButton.Up
        }

        if activeDirection != newDir {
            if let old = activeDirection { onPress(old, false) }
            onPress(newDir, true)
            activeDirection = newDir
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func clearDirection() {
        if let old = activeDirection { onPress(old, false) }
        activeDirection = nil
    }

    private func reset() {
        clearDirection()
        knobOffset = .zero
    }
}
