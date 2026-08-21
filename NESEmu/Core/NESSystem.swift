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
    private var highPass: AVAudioUnitEQ?

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
        bus.dmaStallCycles = 0
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
        bus.dmaStallCycles = 0
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
        bus.dmaStallCycles = 0
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

    func runFrame() {
        ppu.frameComplete = false
        ppu.framebuffer = [UInt8](repeating: 0, count: 256 * 240 * 4)

        while !ppu.frameComplete {
            if oddFrame && ppu.scanline == -1 && ppu.cycle == 340 && (ppu.mask & 0x18) != 0 {
                ppu.cycle = 0
                ppu.scanline = 0
                continue
            }

            let nmiFired = ppu.clock()

            masterClock &+= 1
            if masterClock % 3 == 0 {
                if bus.dmaStallCycles > 0 {
                    bus.dmaStallCycles -= 1
                } else {
                    cpu.step()
                }
                apu.clockCPUCycle()
            }

            if nmiFired { cpu.nmi() }
            if let cart = cart, cart.irqPending { cpu.irq() }
        }

        oddFrame.toggle()
        updateImage()
    }

    func setButton(_ mask: UInt8, pressed: Bool) {
        if pressed { bus.controller1 |= mask }
        else { bus.controller1 &= ~mask }
    }

    private func updateImage() {
        let fullWidth = 256, fullHeight = 240
        let data = Data(ppu.framebuffer)
        guard let provider = CGDataProvider(data: data as CFData),
              let full = CGImage(
                width: fullWidth, height: fullHeight,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: fullWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return }

        // Consumer CRTs normally hid the outer NES scanlines in overscan.
        // Captain Tsubasa II deliberately performs palette/VRAM work there,
        // which appears as colored/garbage strips on a modern full-frame display.
        // Present the conventional 256x224 safe picture: 8 lines cropped top/bottom.
        image = full.cropping(to: CGRect(x: 0, y: 8, width: 256, height: 224)) ?? full
    }

    // MARK: - Audio
    private func setupAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setPreferredSampleRate(44100)
        try? session.setPreferredIOBufferDuration(0.020)
        try? session.setActive(true)

        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in ablPointer {
                let bufPtr = UnsafeMutableBufferPointer<Float>(buffer)
                for frame in 0..<Int(frameCount) {
                    bufPtr[frame] = self.apu.sampleBuffer.pop()
                }
            }
            return noErr
        }
        sourceNode = node
        audioEngine.attach(node)

        // The NES DAC output is unipolar and real hardware is AC-coupled.
        // A high-pass stage removes the DC component/clicking that otherwise
        // reaches the iPhone speaker directly from the simplified mixer.
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        eq.bands[0].filterType = .highPass
        eq.bands[0].frequency = 45
        eq.bands[0].bypass = false
        highPass = eq
        audioEngine.attach(eq)
        audioEngine.connect(node, to: eq, format: format)
        audioEngine.connect(eq, to: audioEngine.mainMixerNode, format: format)
        audioEngine.mainMixerNode.outputVolume = 0.85
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
