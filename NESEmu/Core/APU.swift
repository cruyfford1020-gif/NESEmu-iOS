import Foundation

/// NES APU: two pulse channels, triangle, noise, and DMC.
/// Clock once per CPU cycle (NTSC 1.789773 MHz).
final class APU {
    private struct Pulse {
        var enabled = false
        var duty: UInt8 = 0
        var dutyStep = 0
        var lengthCounter: UInt8 = 0
        var lengthHalt = false
        var constantVolume = false
        var volume: UInt8 = 0
        var envelopeStart = false
        var envelopeDivider: UInt8 = 0
        var envelopeDecay: UInt8 = 0
        var timerPeriod: UInt16 = 0
        var timerValue: UInt16 = 0
        var sweepEnabled = false
        var sweepPeriod: UInt8 = 0
        var sweepNegate = false
        var sweepShift: UInt8 = 0
        var sweepDivider: UInt8 = 0
        var sweepReload = false
        var isChannel2 = false

        static let dutyTable: [[UInt8]] = [
            [0,1,0,0,0,0,0,0],
            [0,1,1,0,0,0,0,0],
            [0,1,1,1,1,0,0,0],
            [1,0,0,1,1,1,1,1]
        ]

        mutating func clockTimer() {
            if timerValue == 0 {
                timerValue = timerPeriod
                dutyStep = (dutyStep + 1) & 7
            } else {
                timerValue -= 1
            }
        }

        mutating func clockEnvelope() {
            if envelopeStart {
                envelopeStart = false
                envelopeDecay = 15
                envelopeDivider = volume
            } else if envelopeDivider == 0 {
                envelopeDivider = volume
                if envelopeDecay > 0 { envelopeDecay -= 1 }
                else if lengthHalt { envelopeDecay = 15 }
            } else {
                envelopeDivider -= 1
            }
        }

        var targetPeriod: Int {
            let delta = Int(timerPeriod) >> Int(sweepShift)
            if sweepNegate {
                return Int(timerPeriod) - delta - (isChannel2 ? 0 : 1)
            }
            return Int(timerPeriod) + delta
        }

        mutating func clockSweep() {
            if sweepDivider == 0 && sweepEnabled && sweepShift > 0 {
                let target = targetPeriod
                if timerPeriod >= 8 && target >= 0 && target <= 0x7FF {
                    timerPeriod = UInt16(target)
                }
            }
            if sweepDivider == 0 || sweepReload {
                sweepDivider = sweepPeriod
                sweepReload = false
            } else {
                sweepDivider -= 1
            }
        }

        func output() -> UInt8 {
            guard enabled, lengthCounter > 0, timerPeriod >= 8 else { return 0 }
            if !sweepNegate && targetPeriod > 0x7FF { return 0 }
            guard Pulse.dutyTable[Int(duty)][dutyStep] != 0 else { return 0 }
            return constantVolume ? volume : envelopeDecay
        }
    }

    private struct Triangle {
        var enabled = false
        var lengthCounter: UInt8 = 0
        var control = false
        var linearCounter: UInt8 = 0
        var linearReloadValue: UInt8 = 0
        var linearReload = false
        var timerPeriod: UInt16 = 0
        var timerValue: UInt16 = 0
        var step = 0

        static let sequence: [UInt8] = [
            15,14,13,12,11,10,9,8,7,6,5,4,3,2,1,0,
            0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
        ]

        mutating func clockTimer() {
            guard enabled, lengthCounter > 0, linearCounter > 0, timerPeriod >= 2 else { return }
            if timerValue == 0 {
                timerValue = timerPeriod
                step = (step + 1) & 31
            } else {
                timerValue -= 1
            }
        }

        mutating func clockLinear() {
            if linearReload { linearCounter = linearReloadValue }
            else if linearCounter > 0 { linearCounter -= 1 }
            if !control { linearReload = false }
        }

        func output() -> UInt8 {
            guard enabled, lengthCounter > 0, linearCounter > 0, timerPeriod >= 2 else { return 0 }
            return Triangle.sequence[step]
        }
    }

    private struct Noise {
        var enabled = false
        var lengthCounter: UInt8 = 0
        var lengthHalt = false
        var constantVolume = false
        var volume: UInt8 = 0
        var envelopeStart = false
        var envelopeDivider: UInt8 = 0
        var envelopeDecay: UInt8 = 0
        var mode = false
        var timerPeriod: UInt16 = 4
        var timerValue: UInt16 = 0
        var shiftRegister: UInt16 = 1

        static let periodTable: [UInt16] = [4,8,16,32,64,96,128,160,202,254,380,508,762,1016,2034,4068]

        mutating func clockTimer() {
            if timerValue == 0 {
                timerValue = timerPeriod
                let tap = mode ? 6 : 1
                let feedback = (shiftRegister & 1) ^ ((shiftRegister >> tap) & 1)
                shiftRegister = (shiftRegister >> 1) | (feedback << 14)
            } else {
                timerValue -= 1
            }
        }

        mutating func clockEnvelope() {
            if envelopeStart {
                envelopeStart = false
                envelopeDecay = 15
                envelopeDivider = volume
            } else if envelopeDivider == 0 {
                envelopeDivider = volume
                if envelopeDecay > 0 { envelopeDecay -= 1 }
                else if lengthHalt { envelopeDecay = 15 }
            } else {
                envelopeDivider -= 1
            }
        }

        func output() -> UInt8 {
            guard enabled, lengthCounter > 0, (shiftRegister & 1) == 0 else { return 0 }
            return constantVolume ? volume : envelopeDecay
        }
    }

    private struct DMC {
        static let rateTable: [Int] = [428,380,340,320,286,254,226,214,190,160,142,128,106,85,72,54]

        var irqEnabled = false
        var loop = false
        var rateIndex = 0
        var outputLevel: UInt8 = 0
        var sampleAddress: UInt16 = 0xC000
        var sampleLength = 1

        var currentAddress: UInt16 = 0xC000
        var bytesRemaining = 0
        var sampleBuffer: UInt8?
        var shiftRegister: UInt8 = 0
        var bitsRemaining = 8
        var silence = true
        var timer = 0
        var irqPending = false

        mutating func restart() {
            currentAddress = sampleAddress
            bytesRemaining = sampleLength
        }
    }

    private static let lengthTable: [UInt8] = [
        10,254,20,2,40,4,80,6,160,8,60,10,14,12,26,14,
        12,16,24,18,48,20,96,22,192,24,72,26,16,28,32,30
    ]

    private var pulse1 = Pulse()
    private var pulse2 = Pulse()
    private var triangle = Triangle()
    private var noise = Noise()
    private var dmc = DMC()

    private var frameCounterMode5 = false
    private var frameIRQInhibit = true
    private var frameCycle = 0
    private var apuHalfCycle = false

    var sampleBuffer = RingBuffer(capacity: 1 << 15)
    private let cyclesPerSample = 1_789_773.0 / 44_100.0
    private var sampleAccumulator = 0.0

    /// DMC needs CPU address-space reads and stalls the CPU for 4 cycles per fetch.
    var memoryReader: ((UInt16) -> UInt8)?
    var requestCPUStall: ((Int) -> Void)?

    init() {
        pulse2.isChannel2 = true
    }

    func reset() {
        pulse1 = Pulse()
        pulse2 = Pulse(); pulse2.isChannel2 = true
        triangle = Triangle()
        noise = Noise()
        dmc = DMC()
        frameCounterMode5 = false
        frameIRQInhibit = true
        frameCycle = 0
        apuHalfCycle = false
        sampleAccumulator = 0
        sampleBuffer.clear()
    }

    func writeRegister(_ addr: UInt16, _ value: UInt8) {
        switch addr {
        case 0x4000:
            pulse1.duty = (value >> 6) & 3
            pulse1.lengthHalt = value & 0x20 != 0
            pulse1.constantVolume = value & 0x10 != 0
            pulse1.volume = value & 0x0F
        case 0x4001:
            pulse1.sweepEnabled = value & 0x80 != 0
            pulse1.sweepPeriod = (value >> 4) & 7
            pulse1.sweepNegate = value & 0x08 != 0
            pulse1.sweepShift = value & 7
            pulse1.sweepReload = true
        case 0x4002:
            pulse1.timerPeriod = (pulse1.timerPeriod & 0x0700) | UInt16(value)
        case 0x4003:
            pulse1.timerPeriod = (pulse1.timerPeriod & 0x00FF) | (UInt16(value & 7) << 8)
            if pulse1.enabled { pulse1.lengthCounter = APU.lengthTable[Int(value >> 3)] }
            pulse1.envelopeStart = true
            pulse1.dutyStep = 0

        case 0x4004:
            pulse2.duty = (value >> 6) & 3
            pulse2.lengthHalt = value & 0x20 != 0
            pulse2.constantVolume = value & 0x10 != 0
            pulse2.volume = value & 0x0F
        case 0x4005:
            pulse2.sweepEnabled = value & 0x80 != 0
            pulse2.sweepPeriod = (value >> 4) & 7
            pulse2.sweepNegate = value & 0x08 != 0
            pulse2.sweepShift = value & 7
            pulse2.sweepReload = true
        case 0x4006:
            pulse2.timerPeriod = (pulse2.timerPeriod & 0x0700) | UInt16(value)
        case 0x4007:
            pulse2.timerPeriod = (pulse2.timerPeriod & 0x00FF) | (UInt16(value & 7) << 8)
            if pulse2.enabled { pulse2.lengthCounter = APU.lengthTable[Int(value >> 3)] }
            pulse2.envelopeStart = true
            pulse2.dutyStep = 0

        case 0x4008:
            triangle.control = value & 0x80 != 0
            triangle.linearReloadValue = value & 0x7F
        case 0x400A:
            triangle.timerPeriod = (triangle.timerPeriod & 0x0700) | UInt16(value)
        case 0x400B:
            triangle.timerPeriod = (triangle.timerPeriod & 0x00FF) | (UInt16(value & 7) << 8)
            if triangle.enabled { triangle.lengthCounter = APU.lengthTable[Int(value >> 3)] }
            triangle.linearReload = true

        case 0x400C:
            noise.lengthHalt = value & 0x20 != 0
            noise.constantVolume = value & 0x10 != 0
            noise.volume = value & 0x0F
        case 0x400E:
            noise.mode = value & 0x80 != 0
            noise.timerPeriod = Noise.periodTable[Int(value & 0x0F)]
        case 0x400F:
            if noise.enabled { noise.lengthCounter = APU.lengthTable[Int(value >> 3)] }
            noise.envelopeStart = true

        case 0x4010:
            dmc.irqEnabled = value & 0x80 != 0
            if !dmc.irqEnabled { dmc.irqPending = false }
            dmc.loop = value & 0x40 != 0
            dmc.rateIndex = Int(value & 0x0F)
        case 0x4011:
            dmc.outputLevel = value & 0x7F
        case 0x4012:
            dmc.sampleAddress = 0xC000 | (UInt16(value) << 6)
        case 0x4013:
            dmc.sampleLength = Int(value) * 16 + 1

        case 0x4015:
            pulse1.enabled = value & 0x01 != 0
            pulse2.enabled = value & 0x02 != 0
            triangle.enabled = value & 0x04 != 0
            noise.enabled = value & 0x08 != 0
            if !pulse1.enabled { pulse1.lengthCounter = 0 }
            if !pulse2.enabled { pulse2.lengthCounter = 0 }
            if !triangle.enabled { triangle.lengthCounter = 0 }
            if !noise.enabled { noise.lengthCounter = 0 }
            if value & 0x10 == 0 {
                dmc.bytesRemaining = 0
            } else if dmc.bytesRemaining == 0 {
                dmc.restart()
            }
            dmc.irqPending = false

        case 0x4017:
            frameCounterMode5 = value & 0x80 != 0
            frameIRQInhibit = value & 0x40 != 0
            frameCycle = 0
            if frameCounterMode5 {
                clockQuarterFrame()
                clockHalfFrame()
            }
        default:
            break
        }
    }

    func readStatus() -> UInt8 {
        var result: UInt8 = 0
        if pulse1.lengthCounter > 0 { result |= 0x01 }
        if pulse2.lengthCounter > 0 { result |= 0x02 }
        if triangle.lengthCounter > 0 { result |= 0x04 }
        if noise.lengthCounter > 0 { result |= 0x08 }
        if dmc.bytesRemaining > 0 { result |= 0x10 }
        if dmc.irqPending { result |= 0x80 }
        return result
    }

    private func clockQuarterFrame() {
        pulse1.clockEnvelope()
        pulse2.clockEnvelope()
        noise.clockEnvelope()
        triangle.clockLinear()
    }

    private func clockHalfFrame() {
        if !pulse1.lengthHalt && pulse1.lengthCounter > 0 { pulse1.lengthCounter -= 1 }
        if !pulse2.lengthHalt && pulse2.lengthCounter > 0 { pulse2.lengthCounter -= 1 }
        if !triangle.control && triangle.lengthCounter > 0 { triangle.lengthCounter -= 1 }
        if !noise.lengthHalt && noise.lengthCounter > 0 { noise.lengthCounter -= 1 }
        pulse1.clockSweep()
        pulse2.clockSweep()
    }

    func clockCPUCycle() {
        triangle.clockTimer()

        apuHalfCycle.toggle()
        if apuHalfCycle {
            pulse1.clockTimer()
            pulse2.clockTimer()
            noise.clockTimer()
        }

        clockDMC()

        frameCycle += 1
        if frameCounterMode5 {
            switch frameCycle {
            case 3729: clockQuarterFrame()
            case 7457: clockQuarterFrame(); clockHalfFrame()
            case 11186: clockQuarterFrame()
            case 18641:
                clockQuarterFrame(); clockHalfFrame()
                frameCycle = 0
            default: break
            }
        } else {
            switch frameCycle {
            case 3729: clockQuarterFrame()
            case 7457: clockQuarterFrame(); clockHalfFrame()
            case 11186: clockQuarterFrame()
            case 14915:
                clockQuarterFrame(); clockHalfFrame()
                frameCycle = 0
            default: break
            }
        }

        sampleAccumulator += 1
        if sampleAccumulator >= cyclesPerSample {
            sampleAccumulator -= cyclesPerSample
            sampleBuffer.push(mixSample())
        }
    }

    private func clockDMC() {
        if dmc.sampleBuffer == nil && dmc.bytesRemaining > 0, let reader = memoryReader {
            requestCPUStall?(4)
            dmc.sampleBuffer = reader(dmc.currentAddress)
            dmc.currentAddress = dmc.currentAddress == 0xFFFF ? 0x8000 : dmc.currentAddress &+ 1
            dmc.bytesRemaining -= 1
            if dmc.bytesRemaining == 0 {
                if dmc.loop { dmc.restart() }
                else if dmc.irqEnabled { dmc.irqPending = true }
            }
        }

        if dmc.timer <= 0 {
            dmc.timer = DMC.rateTable[dmc.rateIndex]

            if !dmc.silence {
                if dmc.shiftRegister & 1 != 0 {
                    if dmc.outputLevel <= 125 { dmc.outputLevel += 2 }
                } else if dmc.outputLevel >= 2 {
                    dmc.outputLevel -= 2
                }
            }

            dmc.shiftRegister >>= 1
            dmc.bitsRemaining -= 1
            if dmc.bitsRemaining == 0 {
                dmc.bitsRemaining = 8
                if let sample = dmc.sampleBuffer {
                    dmc.shiftRegister = sample
                    dmc.sampleBuffer = nil
                    dmc.silence = false
                } else {
                    dmc.silence = true
                }
            }
        } else {
            dmc.timer -= 1
        }
    }

    private func mixSample() -> Float {
        let p1 = Float(pulse1.output())
        let p2 = Float(pulse2.output())
        let t = Float(triangle.output())
        let n = Float(noise.output())
        let d = Float(dmc.outputLevel)

        let pulseSum = p1 + p2
        let pulseOut: Float = pulseSum == 0 ? 0 : 95.88 / ((8128 / pulseSum) + 100)
        let tndInput = (t / 8227) + (n / 12241) + (d / 22638)
        let tndOut: Float = tndInput == 0 ? 0 : 159.79 / ((1 / tndInput) + 100)
        return min(0.98, (pulseOut + tndOut) * 0.90)
    }
}

final class RingBuffer {
    private var buffer: [Float]
    private var writeIndex = 0
    private var readIndex = 0
    private let capacity: Int
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [Float](repeating: 0, count: capacity)
    }

    func clear() {
        lock.lock()
        writeIndex = 0
        readIndex = 0
        buffer = [Float](repeating: 0, count: capacity)
        lock.unlock()
    }

    func push(_ value: Float) {
        lock.lock()
        buffer[writeIndex % capacity] = value
        writeIndex += 1
        if writeIndex - readIndex > capacity {
            readIndex = writeIndex - capacity
        }
        lock.unlock()
    }

    func pop() -> Float {
        lock.lock()
        defer { lock.unlock() }
        guard readIndex < writeIndex else { return 0 }
        let value = buffer[readIndex % capacity]
        readIndex += 1
        return value
    }

    var available: Int {
        lock.lock()
        defer { lock.unlock() }
        return writeIndex - readIndex
    }
}
