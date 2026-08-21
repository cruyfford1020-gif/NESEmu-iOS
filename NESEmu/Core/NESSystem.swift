import Foundation
import CoreGraphics
import AVFoundation

private struct NESState: Codable {
    let busRAM: [UInt8]
    let cpu: CPUState
    let ppu: PPUState
    let cartridge: CartridgeState
    let masterClock: UInt64
}

final class NESSystem: ObservableObject {
    let bus = Bus()
    var cpu: CPU6502!
    let ppu = PPU2C02()
    let apu = APU()
    var cart: Cartridge?
    private var loadedROMData: [UInt8]?
    private var masterClock: UInt64 = 0
    private var oddFrame = false

    @Published var image: CGImage?

    private let audioEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    init() {
        cpu = CPU6502(bus: bus)
        bus.ppu = ppu
        bus.apu = apu
        setupAudio()
    }

    func loadROM(data: [UInt8]) -> Bool {
        guard let cart = Cartridge(data: data) else { return false }
        loadedROMData = data
        self.cart = cart
        bus.cart = cart
        ppu.cart = cart
        cpu.reset()
        ppu.reset()
        masterClock = 0
        oddFrame = false
        return true
    }

    func restartGame() {
        guard let data = loadedROMData else { return }
        bus.ram = [UInt8](repeating: 0, count: 2048)
        bus.controller1 = 0
        bus.controller1Shift = 0
        bus.controller1Strobe = false
        _ = loadROM(data: data)
    }

    func saveState() -> Bool {
        guard let cart else { return false }
        let state = NESState(busRAM: bus.ram, cpu: cpu.makeState(),
                             ppu: ppu.makeState(), cartridge: cart.makeState(),
                             masterClock: masterClock)
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: saveStateURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func loadState() -> Bool {
        guard let data = try? Data(contentsOf: saveStateURL),
              let state = try? JSONDecoder().decode(NESState.self, from: data),
              let cart else { return false }

        bus.ram = state.busRAM
        bus.controller1 = 0
        bus.controller1Shift = 0
        bus.controller1Strobe = false
        cart.restoreState(state.cartridge)
        cpu.restoreState(state.cpu)
        ppu.restoreState(state.ppu)
        masterClock = state.masterClock
        oddFrame = false
        updateImage()
        return true
    }

    private var saveStateURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("captain-tsubasa-2.state")
    }

    // Run one NTSC frame with continuous 3:1 PPU/CPU timing.
    func runFrame() {
        ppu.frameComplete = false
        while !ppu.frameComplete {
            // Real NTSC 2C02 shortens every odd frame by one PPU dot when
            // rendering is enabled. Keeping this skip is important for games
            // such as MMC3 titles whose raster IRQ timing is tied to PPU phase.
            if oddFrame && ppu.scanline == -1 && ppu.cycle == 340 && (ppu.mask & 0x18) != 0 {
                ppu.cycle = 0
                ppu.scanline = 0
                continue
            }

            let nmiFired = ppu.clock()

            masterClock &+= 1
            if masterClock % 3 == 0 {
                cpu.step()
                apu.clockCPUCycle()
            }

            if nmiFired {
                cpu.nmi()
            }
            if let cart = cart, cart.irqPending {
                cpu.irq()
            }
        }

        oddFrame.toggle()
        updateImage()
    }

    func setButton(_ mask: UInt8, pressed: Bool) {
        if pressed {
            bus.controller1 |= mask
        } else {
            bus.controller1 &= ~mask
        }
    }

    private func updateImage() {
        let width = 256, height = 240
        let data = Data(ppu.framebuffer)
        guard let provider = CGDataProvider(data: data as CFData) else { return }
        image = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    // MARK: - Audio
    private func setupAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setPreferredSampleRate(44100)
        // A slightly larger hardware buffer reduces underruns when SwiftUI's
        // 60 Hz timer is delayed for a frame by the system.
        try? session.setPreferredIOBufferDuration(0.020)
        try? session.setActive(true)

        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in ablPointer {
                let bufPtr = UnsafeMutableBufferPointer<Float>(buffer)
                for frame in 0..<Int(frameCount) {
                    // Never repeat/hold an old APU sample on underrun. Holding the
                    // previous value creates audible buzzing and pitch artifacts.
                    bufPtr[frame] = self.apu.sampleBuffer.pop()
                }
            }
            return noErr
        }
        sourceNode = node
        audioEngine.attach(node)
        audioEngine.connect(node, to: audioEngine.mainMixerNode, format: format)
        audioEngine.mainMixerNode.outputVolume = 0.95
        try? audioEngine.start()
    }
}

enum NESButton {
    static let A: UInt8 = 1 << 0
    static let B: UInt8 = 1 << 1
    static let Select: UInt8 = 1 << 2
    static let Start: UInt8 = 1 << 3
    static let Up: UInt8 = 1 << 4
    static let Down: UInt8 = 1 << 5
    static let Left: UInt8 = 1 << 6
    static let Right: UInt8 = 1 << 7
}
