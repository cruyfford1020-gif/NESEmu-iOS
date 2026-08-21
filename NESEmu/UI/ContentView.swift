import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var nes = NESSystem()
    @State private var timer: Timer?
    @State private var gameStarted = false
    @State private var notice: String?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Plain black background: no controller skin/background artwork.
                Color.black.ignoresSafeArea()

                gameScreen
                    .frame(maxWidth: geo.size.width * 0.62,
                           maxHeight: geo.size.height * 0.82)

                // LOAD fixed at top-left, SAVE fixed at top-right.
                VStack {
                    HStack {
                        actionButton("LOAD", systemImage: "arrow.down.circle.fill") {
                            showResult(nes.loadState(), success: "Game loaded", failure: "No save found")
                        }

                        Spacer()

                        actionButton("SAVE", systemImage: "arrow.up.circle.fill") {
                            showResult(nes.saveState(), success: "Game saved", failure: "Save failed")
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.top, 10)

                // Game controls stay at the bottom edges.
                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        JoystickView { mask, pressed in
                            nes.setButton(mask, pressed: pressed)
                        }

                        Spacer()

                        VStack(spacing: 12) {
                            HStack(spacing: 18) {
                                gameButton("B", color: .red, mask: NESButton.B)
                                gameButton("A", color: .blue, mask: NESButton.A)
                            }
                            HStack(spacing: 12) {
                                smallGameButton("SELECT", mask: NESButton.Select)
                                smallGameButton("START", mask: NESButton.Start)
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 18)
                }

                // RESTART fixed at the bottom center.
                VStack {
                    Spacer()
                    Button {
                        nes.restartGame()
                        showResult(true, success: "Game restarted", failure: "")
                    } label: {
                        Label("RESTART", systemImage: "arrow.clockwise")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .padding(.horizontal, 18)
                            .frame(height: 44)
                            .background(Color.red.opacity(0.92), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 22)
                }

                if let notice {
                    Text(notice)
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Color.black.opacity(0.82), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.3)))
                        .foregroundStyle(.white)
                        .transition(.opacity)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { autoStart() }
        .onDisappear { timer?.invalidate() }
    }

    private var gameScreen: some View {
        ZStack {
            Color.black
            if let img = nes.image {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(256.0 / 240.0, contentMode: .fit)
            }
        }
        .aspectRatio(256.0 / 240.0, contentMode: .fit)
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(Color.black.opacity(0.68), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.45), lineWidth: 1))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func gameButton(_ title: String, color: Color, mask: UInt8) -> some View {
        Text(title)
            .font(.system(size: 30, weight: .black, design: .rounded))
            .frame(width: 76, height: 76)
            .background(color.opacity(0.9), in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.65), lineWidth: 3))
            .foregroundStyle(.white)
            .contentShape(Circle())
            .gesture(pressGesture(mask))
    }

    private func smallGameButton(_ title: String, mask: UInt8) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .frame(width: 70, height: 30)
            .background(Color.black.opacity(0.68), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.4)))
            .foregroundStyle(.white)
            .contentShape(Capsule())
            .gesture(pressGesture(mask))
    }

    private func pressGesture(_ mask: UInt8) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in nes.setButton(mask, pressed: true) }
            .onEnded { _ in nes.setButton(mask, pressed: false) }
    }

    private func showResult(_ ok: Bool, success: String, failure: String) {
        UIImpactFeedbackGenerator(style: ok ? .medium : .rigid).impactOccurred()
        withAnimation { notice = ok ? success : failure }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            withAnimation { notice = nil }
        }
    }

    private func autoStart() {
        guard !gameStarted,
              let url = Bundle.main.url(forResource: "game", withExtension: "nes"),
              let data = try? Data(contentsOf: url),
              nes.loadROM(data: [UInt8](data)) else { return }

        gameStarted = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0988, repeats: true) { _ in
            nes.runFrame()
        }
    }
}

#Preview { ContentView() }
