import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var nes = NESSystem()
    @State private var timer: Timer?
    @State private var gameStarted = false

    // Exact proportions of the supplied Captain Tsubasa skin image.
    private let skinSize = CGSize(width: 1672, height: 941)

    var body: some View {
        GeometryReader { geo in
            let rect = fittedSkinRect(in: geo.size)

            ZStack {
                Color.black.ignoresSafeArea()

                ZStack(alignment: .topLeading) {
                    // Keep the supplied artwork untouched and at its original aspect ratio.
                    Group {
                        if let path = Bundle.main.path(forResource: "GameBackground", ofType: "png"),
                           let uiImage = UIImage(contentsOfFile: path) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .interpolation(.high)
                        } else {
                            Image("GameBackground")
                                .resizable()
                                .interpolation(.high)
                        }
                    }
                    .frame(width: rect.width, height: rect.height)

                    // Replace only the picture inside the drawn monitor with the live NES output.
                    liveGameScreen(in: rect.size)

                    // Invisible hit zones line up exactly with the controls drawn in the skin.
                    controllerHitZones(in: rect.size)
                }
                .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                .position(x: rect.midX, y: rect.midY)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { autoStart() }
    }

    // MARK: - Exact skin geometry

    private func fittedSkinRect(in available: CGSize) -> CGRect {
        let scale = min(available.width / skinSize.width, available.height / skinSize.height)
        let size = CGSize(width: skinSize.width * scale, height: skinSize.height * scale)
        return CGRect(
            x: (available.width - size.width) / 2,
            y: (available.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func px(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, in size: CGSize) -> CGRect {
        let sx = size.width / skinSize.width
        let sy = size.height / skinSize.height
        return CGRect(x: x * sx, y: y * sy, width: w * sx, height: h * sy)
    }

    @ViewBuilder
    private func liveGameScreen(in size: CGSize) -> some View {
        // Inner black display region of the supplied artwork.
        // Insets preserve the white monitor bezel exactly as drawn in the PNG.
        let r = px(455, 140, 746, 592, in: size)

        ZStack {
            Color.black
            if let img = nes.image {
                Image(decorative: img, scale: 1.0)
                    .resizable()
                    .interpolation(.none)
                    // Fill the monitor opening, matching the screenshot-style skin.
                    .aspectRatio(256.0 / 240.0, contentMode: .fit)
                    .frame(width: r.width, height: r.height)
            }
        }
        .frame(width: r.width, height: r.height)
        .clipped()
        .position(x: r.midX, y: r.midY)
    }

    @ViewBuilder
    private func controllerHitZones(in size: CGSize) -> some View {
        let dpad = px(70, 304, 310, 310, in: size)
        let b = px(1260, 348, 145, 145, in: size)
        let a = px(1402, 348, 145, 145, in: size)
        let select = px(1269, 548, 140, 72, in: size)
        let start = px(1419, 548, 140, 72, in: size)
        let restartBall = px(770, 787, 110, 90, in: size)

        // 8-way joystick. The artwork remains untouched; this view only handles touch.
        JoystickHitArea { mask, pressed in
            nes.setButton(mask, pressed: pressed)
        }
        .frame(width: dpad.width, height: dpad.height)
        .position(x: dpad.midX, y: dpad.midY)

        invisibleNESButton(frame: b, mask: NESButton.B)
        invisibleNESButton(frame: a, mask: NESButton.A)
        invisibleNESButton(frame: select, mask: NESButton.Select)

        // START works normally on tap; a long press also performs restart as a fallback.
        Color.clear
            .contentShape(Rectangle())
            .frame(width: start.width, height: start.height)
            .position(x: start.midX, y: start.midY)
            .simultaneousGesture(pressGesture(NESButton.Start))
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.9)
                    .onEnded { _ in nes.restartGame() }
            )

        // The soccer ball at the bottom of the supplied skin is the RESTART button.
        // This preserves the skin pixel-for-pixel without drawing an extra control.
        Button {
            nes.restartGame()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } label: {
            Color.clear
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .frame(width: restartBall.width, height: restartBall.height)
        .position(x: restartBall.midX, y: restartBall.midY)
        .accessibilityLabel("Restart Game")
    }

    private func invisibleNESButton(frame: CGRect, mask: UInt8) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .simultaneousGesture(pressGesture(mask))
    }

    private func pressGesture(_ mask: UInt8) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in nes.setButton(mask, pressed: true) }
            .onEnded { _ in nes.setButton(mask, pressed: false) }
    }

    // MARK: - Auto-load embedded game

    private func autoStart() {
        guard !gameStarted else { return }
        guard let url = Bundle.main.url(forResource: "game", withExtension: "nes"),
              let data = try? Data(contentsOf: url) else { return }

        if nes.loadROM(data: [UInt8](data)) {
            gameStarted = true
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0988, repeats: true) { _ in
                nes.runFrame()
            }
        }
    }
}

// Invisible 8-way touch surface aligned to the round D-pad already drawn in the skin.
private struct JoystickHitArea: View {
    let onPress: (UInt8, Bool) -> Void
    @State private var activeMask: UInt8 = 0

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            update(point: value.location, size: geo.size)
                        }
                        .onEnded { _ in releaseAll() }
                )
        }
    }

    private func update(point: CGPoint, size: CGSize) {
        let dx = point.x - size.width / 2
        let dy = point.y - size.height / 2
        let radius = min(size.width, size.height) / 2
        let distance = sqrt(dx * dx + dy * dy)

        guard distance > radius * 0.16 else {
            setMask(0)
            return
        }

        let ax = abs(dx)
        let ay = abs(dy)
        let diagonalRatio: CGFloat = 0.42
        var mask: UInt8 = 0

        if ax >= ay * diagonalRatio {
            mask |= dx >= 0 ? NESButton.Right : NESButton.Left
        }
        if ay >= ax * diagonalRatio {
            mask |= dy >= 0 ? NESButton.Down : NESButton.Up
        }

        setMask(mask)
    }

    private func setMask(_ newMask: UInt8) {
        guard newMask != activeMask else { return }
        if activeMask != 0 { onPress(activeMask, false) }
        if newMask != 0 {
            onPress(newMask, true)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        activeMask = newMask
    }

    private func releaseAll() {
        if activeMask != 0 { onPress(activeMask, false) }
        activeMask = 0
    }
}

#Preview {
    ContentView()
}
