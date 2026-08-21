import Foundation

/// Simplified NES APU covering Pulse 1/2, Triangle, and Noise channels (no DMC).
/// Runs at CPU clock rate; call `clockCPUCycle()` once per CPU cycle and read
/// `mixSample()` at the host sample rate (driven externally via a ratio counter).
final class APU {
    // MARK: Registers / channel state
    private struct Pulse {
        var enabled = false
        var duty: UInt8 = 0
        var dutyStep: Int = 0
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
        var isChannel2 = false // affects sweep negate carry behavior

        static let dutyTable: [[UInt8]] = [
            [0,1,0,0,0,0,0,0],
            [0,1,1,0,0,0,0,0],
            [0,1,1,1,1,0,0,0],
            [1,0,0,1,1,1,1,1]
        ]

        mutating func clockTimer() {
            if timerValue == 0 {
                timerValue = timerPeriod
                dutyStep = (dutyStep + 1) % 8
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
            let change = Int(timerPeriod) >> Int(sweepShift)
            if sweepNegate {
                return Int(timerPeriod) - change - (isChannel2 ? 0 : 1)
            } else {
                return Int(timerPeriod) + change
            }
        }

        mutating func clockSweep() {
            if sweepDivider == 0 && sweepEnabled && sweepShift > 0 {
                let t = targetPeriod
                if t >= 0 && t <= 0x7FF {
                    timerPeriod = UInt16(t)
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
            let t = targetPeriod
            if !sweepNegate && t > 0x7FF { return 0 }
            let dutyVal = Pulse.dutyTable[Int(duty)][dutyStep]
            guard dutyVal == 1 else { return 0 }
            return constantVolume ? volume : envelopeDecay
        }
    }

    private struct Triangle {
        var enabled = false
        var lengthCounter: UInt8 = 0
        var lengthHalt = false
        var linearCounter: UInt8 = 0
        var linearReloadValue: UInt8 = 0
        var linearReload = false
        var timerPeriod: UInt16 = 0
        var timerValue: UInt16 = 0
        var step: Int = 0

        static let sequence: [UInt8] = [
            15,14,13,12,11,10,9,8,7,6,5,4,3,2,1,0,
            0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
        ]

        mutating func clockTimer() {
            guard lengthCounter > 0, linearCounter > 0 else { return }
            if timerValue == 0 {
                timerValue = timerPeriod
                step = (step + 1) % 32
            } else {
                timerValue -= 1
            }
        }

        mutating func clockLinear() {
            if linearReload {
                linearCounter = linearReloadValue
            } else if linearCounter > 0 {
                linearCounter -= 1
            }
            if !lengthHalt { linearReload = false }
        }

        func output() -> UInt8 {
            guard enabled, timerPeriod >= 2 else { return 0 }
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
        var timerPeriod: UInt16 = 0
        var timerValue: UInt16 = 0
        var shiftRegister: UInt16 = 1

        static let periodTable: [UInt16] = [4,8,16,32,64,96,128,160,202,254,380,508,762,1016,2034,4068]

        mutating func clockTimer() {
            if timerValue == 0 {
                timerValue = timerPeriod
                let bit1 = mode ? (shiftRegister >> 6) & 1 : (shiftRegister >> 1) & 1
                let feedback = (shiftRegister & 1) ^ bit1
                shiftRegister >>= 1
                shiftRegister |= (feedback << 14)
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

    private var pulse1 = Pulse()
    private var pulse2 = Pulse()
    private var triangle = Triangle()
    private var noise = Noise()

    private static let lengthTable: [UInt8] = [
        10,254,20,2,40,4,80,6,160,8,60,10,14,12,26,14,
        12,16,24,18,48,20,96,22,192,24,72,26,16,28,32,30
    ]

    private var frameCounterMode5 = false
    private var frameIRQInhibit = true
    private var cycleCounter: Int = 0
    private var frameStep = 0

    var sampleBuffer = RingBuffer(capacity: 1 << 15)
    private var cyclesPerSample: Double = 1789773.0 / 44100.0
    private var cycleAccumulator: Double = 0

    init() {
        pulse2.isChannel2 = true
    }

    // MARK: - Register writes ($4000-$4017)
    func writeRegister(_ addr: UInt16, _ value: UInt8) {
        switch addr {
        case 0x4000:
            pulse1.duty = (value >> 6) & 0x03
            pulse1.lengthHalt = (value & 0x20) != 0
            pulse1.constantVolume = (value & 0x10) != 0
            pulse1.volume = value & 0x0F
        case 0x4001:
            pulse1.sweepEnabled = (value & 0x80) != 0
            pulse1.sweepPeriod = (value >> 4) & 0x07
            pulse1.sweepNegate = (value & 0x08) != 0
            pulse1.sweepShift = value & 0x07
            pulse1.sweepReload = true
        case 0x4002:
            pulse1.timerPeriod = (pulse1.timerPeriod & 0x0700) | UInt16(value)
        case 0x4003:
            pulse1.timerPeriod = (pulse1.timerPeriod & 0x00FF) | (UInt16(value & 0x07) << 8)
            if pulse1.enabled { pulse1.lengthCounter = APU.lengthTable[Int(value >> 3)] }
            pulse1.envelopeStart = true
            pulse1.dutyStep = 0
        case 0x4004:
            pulse2.duty = (value >> 6) & 0x03
            pulse2.lengthHalt = (value & 0x20) != 0
            pulse2.constantVolume = (value & 0x10) != 0
            pulse2.volume = value & 0x0F
        case 0x4005:
            pulse2.sweepEnabled = (value & 0x80) != 0
            pulse2.sweepPeriod = (value >> 4) & 0x07
            pulse2.sweepNegate = (value & 0x08) != 0
            pulse2.sweepShift = value & 0x07
            pulse2.sweepReload = true
        case 0x4006:
            pulse2.timerPeriod = (pulse2.timerPeriod & 0x0700) | UInt16(value)
        case 0x4007:
            pulse2.timerPeriod = (pulse2.timerPeriod & 0x00FF) | (UInt16(value & 0x07) << 8)
            if pulse2.enabled { pulse2.lengthCounter = APU.lengthTable[Int(value >> 3)] }
            pulse2.envelopeStart = true
            pulse2.dutyStep = 0
        case 0x4008:
            triangle.lengthHalt = (value & 0x80) != 0
            triangle.linearReloadValue = value & 0x7F
        case 0x400A:
            triangle.timerPeriod = (triangle.timerPeriod & 0x0700) | UInt16(value)
        case 0x400B:
            triangle.timerPeriod = (triangle.timerPeriod & 0x00FF) | (UInt16(value & 0x07) << 8)
            if triangle.enabled { triangle.lengthCounter = APU.lengthTable[Int(value >> 3)] }
            triangle.linearReload = true
        case 0x400C:
            noise.lengthHalt = (value & 0x20) != 0
            noise.constantVolume = (value & 0x10) != 0
            noise.volume = value & 0x0F
        case 0x400E:
            noise.mode = (value & 0x80) != 0
            noise.timerPeriod = Noise.periodTable[Int(value & 0x0F)]
        case 0x400F:
            if noise.enabled { noise.lengthCounter = APU.lengthTable[Int(value >> 3)] }
            noise.envelopeStart = true
        case 0x4015:
            pulse1.enabled = (value & 0x01) != 0
            pulse2.enabled = (value & 0x02) != 0
            triangle.enabled = (value & 0x04) != 0
            noise.enabled = (value & 0x08) != 0
            if !pulse1.enabled { pulse1.lengthCounter = 0 }
            if !pulse2.enabled { pulse2.lengthCounter = 0 }
            if !triangle.enabled { triangle.lengthCounter = 0 }
            if !noise.enabled { noise.lengthCounter = 0 }
        case 0x4017:
            frameCounterMode5 = (value & 0x80) != 0
            frameIRQInhibit = (value & 0x40) != 0
            frameStep = 0
            cycleCounter = 0
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
        return result
    }

    // MARK: - Clocking
    private func clockQuarterFrame() {
        pulse1.clockEnvelope()
        pulse2.clockEnvelope()
        noise.clockEnvelope()
        triangle.clockLinear()
    }

    private func clockHalfFrame() {
        if !pulse1.lengthHalt && pulse1.lengthCounter > 0 { pulse1.lengthCounter -= 1 }
        if !pulse2.lengthHalt && pulse2.lengthCounter > 0 { pulse2.lengthCounter -= 1 }
        if !triangle.lengthHalt && triangle.lengthCounter > 0 { triangle.lengthCounter -= 1 }
        if !noise.lengthHalt && noise.lengthCounter > 0 { noise.lengthCounter -= 1 }
        pulse1.clockSweep()
        pulse2.clockSweep()
    }

    /// Call once per CPU cycle (1.789773 MHz).
    func clockCPUCycle() {
        // Triangle clocks at CPU rate; pulses/noise at half rate (APU cycle)
        triangle.clockTimer()
        cycleCounter += 1

        if cycleCounter % 2 == 0 {
            pulse1.clockTimer()
            pulse2.clockTimer()
            noise.clockTimer()
        }

        // Frame sequencer (~240Hz / ~192Hz steps), approximated using cycle thresholds
        let step = frameCounterMode5 ? frameSequenceMode5(cycleCounter) : frameSequenceMode4(cycleCounter)
        if step != 0 {
            if step == 1 || step == 2 { clockQuarterFrame() }
            if step == 2 { clockHalfFrame() }
            if frameCounterMode5 {
                if step == 3 { clockQuarterFrame() }
                if step == 4 { clockQuarterFrame(); clockHalfFrame() }
            } else {
                if step == 3 { clockQuarterFrame() }
                if step == 4 { clockQuarterFrame(); clockHalfFrame(); cycleCounter = 0 }
            }
        }

        // Sample generation at 44.1kHz
        cycleAccumulator += 1
        if cycleAccumulator >= cyclesPerSample {
            cycleAccumulator -= cyclesPerSample
            sampleBuffer.push(mixSample())
        }
    }

    private func frameSequenceMode4(_ c: Int) -> Int {
        switch c {
        case 3729: return 1
        case 7457: return 2
        case 11186: return 3
        case 14915: return 4
        default: return 0
        }
    }

    private func frameSequenceMode5(_ c: Int) -> Int {
        switch c {
        case 3729: return 1
        case 7457: return 2
        case 11186: return 3
        case 18641: return 4
        default: return 0
        }
    }

    private func mixSample() -> Float {
        let p1 = Float(pulse1.output())
        let p2 = Float(pulse2.output())
        let t = Float(triangle.output())
        let n = Float(noise.output())

        let pulseOut: Float = (p1 + p2) == 0 ? 0 : 95.88 / ((8128 / (p1 + p2)) + 100)
        let tndDenom = (t / 8227) + (n / 12241)
        let tndOut: Float = tndDenom == 0 ? 0 : 159.79 / ((1 / tndDenom) + 100)
        return min(0.95, max(-0.95, (pulseOut + tndOut) * 0.92))
    }
}

/// Thread-safe single-producer/single-consumer ring buffer for audio samples.
final class RingBuffer {
    private var buffer: [Float]
    private var writeIndex = 0
    private var readIndex = 0
    private let capacity: Int
    private let lock = NSLock()
    private var lastOutput: Float = 0

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [Float](repeating: 0, count: capacity)
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
        let v = buffer[readIndex % capacity]
        readIndex += 1
        lastOutput = v
        return v
    }

    func popOrHold() -> Float {
        lock.lock()
        defer { lock.unlock() }
        guard readIndex < writeIndex else {
            lastOutput *= 0.997
            return lastOutput
        }
        let raw = buffer[readIndex % capacity]
        readIndex += 1
        lastOutput += (raw - lastOutput) * 0.72
        return lastOutput
    }

    var available: Int {
        lock.lock()
        defer { lock.unlock() }
        return writeIndex - readIndex
    }
}
