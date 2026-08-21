import Foundation

struct CartridgeState: Codable {
    let chrRAM: [UInt8]
    let prgRAM: [UInt8]
    let mirrorVertical: Bool
    let m1ShiftRegister: UInt8
    let m1Control: UInt8
    let m1ChrBank0: UInt8
    let m1ChrBank1: UInt8
    let m1PrgBank: UInt8
    let m4BankSelect: UInt8
    let m4Registers: [UInt8]
    let m4PrgMode: Bool
    let m4ChrInvert: Bool
    let m4IrqLatch: UInt8
    let m4IrqCounter: UInt8
    let m4IrqEnabled: Bool
    let m4IrqReloadPending: Bool
    let irqPending: Bool
}

final class Cartridge {
    var prgROM: [UInt8] = []
    var chrROM: [UInt8] = []
    var chrRAM: [UInt8] = []
    var prgRAM = [UInt8](repeating: 0, count: 8192)
    var mapperNumber: Int = 0
    var prgBanks: Int = 0
    var chrBanks: Int = 0
    var mirrorVertical: Bool = false
    var usesChrRAM = false

    // MMC1 (Mapper 1) state
    private var m1ShiftRegister: UInt8 = 0x10
    private var m1Control: UInt8 = 0x0C
    private var m1ChrBank0: UInt8 = 0
    private var m1ChrBank1: UInt8 = 0
    private var m1PrgBank: UInt8 = 0

    // MMC3 (Mapper 4) state
    private var m4BankSelect: UInt8 = 0
    private var m4Registers = [UInt8](repeating: 0, count: 8)
    private var m4PrgMode: Bool = false   // bit6 of bank select
    private var m4ChrInvert: Bool = false // bit7 of bank select
    private var m4IrqLatch: UInt8 = 0
    private var m4IrqCounter: UInt8 = 0
    private var m4IrqEnabled: Bool = false
    private var m4IrqReloadPending: Bool = false
    var irqPending: Bool = false

    private var prg8kCount: Int { prgROM.count / 8192 }
    private var chr1kCount: Int { (usesChrRAM ? chrRAM.count : chrROM.count) / 1024 }

    init?(data: [UInt8]) {
        guard data.count > 16,
              data[0] == 0x4E, data[1] == 0x45, data[2] == 0x53, data[3] == 0x1A else {
            return nil
        }
        prgBanks = Int(data[4])
        chrBanks = Int(data[5])
        let flags6 = data[6]
        let flags7 = data[7]
        mirrorVertical = flags6 & 0x01 != 0
        mapperNumber = Int((flags6 >> 4) | (flags7 & 0xF0))

        var offset = 16
        if flags6 & 0x04 != 0 { offset += 512 } // trainer

        let prgSize = prgBanks * 16384
        guard data.count >= offset + prgSize else { return nil }
        prgROM = Array(data[offset..<(offset + prgSize)])
        offset += prgSize

        if chrBanks == 0 {
            usesChrRAM = true
            chrRAM = [UInt8](repeating: 0, count: 8192)
        } else {
            let chrSize = chrBanks * 8192
            guard data.count >= offset + chrSize else { return nil }
            chrROM = Array(data[offset..<(offset + chrSize)])
        }

        if mapperNumber == 4 {
            // Default: last two 8KB banks fixed at the top per MMC3 reset state
            m4Registers = [0, 2, 4, 5, 6, 7, 0, 1]
        }
    }

    func makeState() -> CartridgeState {
        CartridgeState(chrRAM: chrRAM, prgRAM: prgRAM,
                       mirrorVertical: mirrorVertical,
                       m1ShiftRegister: m1ShiftRegister, m1Control: m1Control,
                       m1ChrBank0: m1ChrBank0, m1ChrBank1: m1ChrBank1,
                       m1PrgBank: m1PrgBank, m4BankSelect: m4BankSelect,
                       m4Registers: m4Registers, m4PrgMode: m4PrgMode,
                       m4ChrInvert: m4ChrInvert, m4IrqLatch: m4IrqLatch,
                       m4IrqCounter: m4IrqCounter, m4IrqEnabled: m4IrqEnabled,
                       m4IrqReloadPending: m4IrqReloadPending,
                       irqPending: irqPending)
    }

    func restoreState(_ state: CartridgeState) {
        chrRAM = state.chrRAM; prgRAM = state.prgRAM
        mirrorVertical = state.mirrorVertical
        m1ShiftRegister = state.m1ShiftRegister; m1Control = state.m1Control
        m1ChrBank0 = state.m1ChrBank0; m1ChrBank1 = state.m1ChrBank1
        m1PrgBank = state.m1PrgBank; m4BankSelect = state.m4BankSelect
        m4Registers = state.m4Registers; m4PrgMode = state.m4PrgMode
        m4ChrInvert = state.m4ChrInvert; m4IrqLatch = state.m4IrqLatch
        m4IrqCounter = state.m4IrqCounter; m4IrqEnabled = state.m4IrqEnabled
        m4IrqReloadPending = state.m4IrqReloadPending
        irqPending = state.irqPending
    }

    // MARK: - CPU access

    func cpuRead(_ addr: UInt16) -> UInt8 {
        switch mapperNumber {
        case 1: return mmc1CpuRead(addr)
        case 4: return mmc3CpuRead(addr)
        default: return nromCpuRead(addr)
        }
    }

    func cpuWrite(_ addr: UInt16, _ value: UInt8) {
        switch mapperNumber {
        case 1: mmc1CpuWrite(addr, value)
        case 4: mmc3CpuWrite(addr, value)
        default: break // NROM has no writable registers
        }
    }

    func ppuRead(_ addr: UInt16) -> UInt8 {
        switch mapperNumber {
        case 1: return mmc1PpuRead(addr)
        case 4: return mmc3PpuRead(addr)
        default: return nromPpuRead(addr)
        }
    }

    func ppuWrite(_ addr: UInt16, _ value: UInt8) {
        switch mapperNumber {
        case 1: mmc1PpuWrite(addr, value)
        case 4: mmc3PpuWrite(addr, value)
        default: nromPpuWrite(addr, value)
        }
    }

    // Called once per scanline (approximate, at PPU cycle 260) while rendering is enabled
    func clockScanlineIRQ() {
        guard mapperNumber == 4 else { return }
        if m4IrqCounter == 0 || m4IrqReloadPending {
            m4IrqCounter = m4IrqLatch
            m4IrqReloadPending = false
        } else {
            m4IrqCounter -= 1
        }
        if m4IrqCounter == 0 && m4IrqEnabled {
            irqPending = true
        }
    }

    // MARK: - Mapper 0 (NROM)

    private func nromCpuRead(_ addr: UInt16) -> UInt8 {
        guard addr >= 0x8000 else { return 0 }
        let mapped = prgBanks == 1 ? Int(addr - 0x8000) & 0x3FFF : Int(addr - 0x8000)
        guard mapped < prgROM.count else { return 0 }
        return prgROM[mapped]
    }

    private func nromPpuRead(_ addr: UInt16) -> UInt8 {
        if usesChrRAM { return chrRAM[Int(addr) % chrRAM.count] }
        guard !chrROM.isEmpty else { return 0 }
        return chrROM[Int(addr) % chrROM.count]
    }

    private func nromPpuWrite(_ addr: UInt16, _ value: UInt8) {
        if usesChrRAM { chrRAM[Int(addr) % chrRAM.count] = value }
    }

    // MARK: - Mapper 1 (MMC1)

    private func mmc1CpuRead(_ addr: UInt16) -> UInt8 {
        switch addr {
        case 0x6000...0x7FFF:
            return prgRAM[Int(addr - 0x6000)]
        case 0x8000...0xFFFF:
            let bank16Count = max(prgROM.count / 16384, 1)
            let prgMode = (m1Control >> 2) & 0x03
            var bankIndex: Int
            var offsetBase: UInt16
            if prgMode <= 1 {
                // 32KB mode: bank number ignores low bit
                let bank32 = Int(m1PrgBank & 0x0E) >> 1
                let base = bank32 * 32768
                let off = Int(addr - 0x8000)
                let idx = base + off
                return idx < prgROM.count ? prgROM[idx] : 0
            } else if prgMode == 2 {
                // fix first bank at 0x8000, switch 0xC000
                if addr < 0xC000 {
                    bankIndex = 0
                    offsetBase = 0x8000
                } else {
                    bankIndex = Int(m1PrgBank & 0x0F)
                    offsetBase = 0xC000
                }
            } else {
                // mode 3: switch 0x8000, fix last bank at 0xC000
                if addr < 0xC000 {
                    bankIndex = Int(m1PrgBank & 0x0F)
                    offsetBase = 0x8000
                } else {
                    bankIndex = bank16Count - 1
                    offsetBase = 0xC000
                }
            }
            bankIndex = bankIndex % bank16Count
            let idx = bankIndex * 16384 + Int(addr - offsetBase)
            return idx < prgROM.count ? prgROM[idx] : 0
        default:
            return 0
        }
    }

    private func mmc1CpuWrite(_ addr: UInt16, _ value: UInt8) {
        guard addr >= 0x8000 else {
            if addr >= 0x6000 && addr <= 0x7FFF {
                prgRAM[Int(addr - 0x6000)] = value
            }
            return
        }
        if value & 0x80 != 0 {
            // Reset
            m1ShiftRegister = 0x10
            m1Control |= 0x0C
            return
        }
        let completeWrite = (m1ShiftRegister & 0x01) != 0
        m1ShiftRegister = (m1ShiftRegister >> 1) | ((value & 0x01) << 4)
        if completeWrite {
            let result = m1ShiftRegister
            m1ShiftRegister = 0x10
            switch addr {
            case 0x8000...0x9FFF:
                m1Control = result
                mirrorVertical = (result & 0x03) == 2
            case 0xA000...0xBFFF:
                m1ChrBank0 = result
            case 0xC000...0xDFFF:
                m1ChrBank1 = result
            case 0xE000...0xFFFF:
                m1PrgBank = result
            default:
                break
            }
        }
    }

    private func mmc1PpuRead(_ addr: UInt16) -> UInt8 {
        let idx = mmc1ChrIndex(addr)
        if usesChrRAM {
            return idx < chrRAM.count ? chrRAM[idx] : 0
        }
        return idx < chrROM.count ? chrROM[idx] : 0
    }

    private func mmc1PpuWrite(_ addr: UInt16, _ value: UInt8) {
        guard usesChrRAM else { return }
        let idx = mmc1ChrIndex(addr)
        if idx < chrRAM.count { chrRAM[idx] = value }
    }

    private func mmc1ChrIndex(_ addr: UInt16) -> Int {
        let chrMode4K = (m1Control & 0x10) != 0
        let a = Int(addr) & 0x1FFF
        if chrMode4K {
            if a < 0x1000 {
                return Int(m1ChrBank0) * 4096 + a
            } else {
                return Int(m1ChrBank1) * 4096 + (a - 0x1000)
            }
        } else {
            let bank8 = Int(m1ChrBank0 & 0xFE) >> 1
            return bank8 * 8192 + a
        }
    }

    // MARK: - Mapper 4 (MMC3)

    private func mmc3CpuRead(_ addr: UInt16) -> UInt8 {
        switch addr {
        case 0x6000...0x7FFF:
            return prgRAM[Int(addr - 0x6000)]
        case 0x8000...0xFFFF:
            let bankCount = prg8kCount
            guard bankCount > 0 else { return 0 }
            let slot = Int((addr - 0x8000) / 0x2000) // 0..3
            let offsetInBank = Int(addr) % 0x2000
            let secondLast = bankCount - 2
            let last = bankCount - 1
            var bankIndex: Int
            if !m4PrgMode {
                // 8000-9FFF = R6, A000-BFFF = R7, C000-DFFF = fixed second-last, E000-FFFF = fixed last
                switch slot {
                case 0: bankIndex = Int(m4Registers[6])
                case 1: bankIndex = Int(m4Registers[7])
                case 2: bankIndex = secondLast
                default: bankIndex = last
                }
            } else {
                // 8000-9FFF = fixed second-last, A000-BFFF = R7, C000-DFFF = R6, E000-FFFF = fixed last
                switch slot {
                case 0: bankIndex = secondLast
                case 1: bankIndex = Int(m4Registers[7])
                case 2: bankIndex = Int(m4Registers[6])
                default: bankIndex = last
                }
            }
            bankIndex = bankIndex % bankCount
            let addrInROM = bankIndex * 8192 + offsetInBank
            guard addrInROM < prgROM.count else { return 0 }
            return prgROM[addrInROM]
        default:
            return 0
        }
    }

    private func mmc3CpuWrite(_ addr: UInt16, _ value: UInt8) {
        switch addr {
        case 0x6000...0x7FFF:
            prgRAM[Int(addr - 0x6000)] = value
        case 0x8000...0x9FFF:
            if addr & 1 == 0 {
                m4BankSelect = value
                m4PrgMode = (value & 0x40) != 0
                m4ChrInvert = (value & 0x80) != 0
            } else {
                let reg = Int(m4BankSelect & 0x07)
                m4Registers[reg] = value
            }
        case 0xA000...0xBFFF:
            if addr & 1 == 0 {
                mirrorVertical = (value & 0x01) == 0
            }
            // odd: PRG RAM protect - not enforced (not needed for compatibility)
        case 0xC000...0xDFFF:
            if addr & 1 == 0 {
                m4IrqLatch = value
            } else {
                // Per NESdev spec: writing $C001 clears the counter immediately,
                // then it's reloaded from the latch at the next A12 rising edge.
                m4IrqCounter = 0
                m4IrqReloadPending = true
            }
        case 0xE000...0xFFFF:
            if addr & 1 == 0 {
                m4IrqEnabled = false
                irqPending = false
            } else {
                m4IrqEnabled = true
            }
        default:
            break
        }
    }

    private func mmc3PpuRead(_ addr: UInt16) -> UInt8 {
        let bankIndex = mmc3ChrBankIndex(for: addr)
        let offsetInBank = Int(addr) % 1024
        let idx = bankIndex * 1024 + offsetInBank
        if usesChrRAM {
            guard idx < chrRAM.count else { return 0 }
            return chrRAM[idx]
        } else {
            guard idx < chrROM.count else { return 0 }
            return chrROM[idx]
        }
    }

    private func mmc3PpuWrite(_ addr: UInt16, _ value: UInt8) {
        guard usesChrRAM else { return }
        let bankIndex = mmc3ChrBankIndex(for: addr)
        let offsetInBank = Int(addr) % 1024
        let idx = bankIndex * 1024 + offsetInBank
        guard idx < chrRAM.count else { return }
        chrRAM[idx] = value
    }

    private func mmc3ChrBankIndex(for addr: UInt16) -> Int {
        // Two 2KB regions (R0,R1) and four 1KB regions (R2-R5), order flips with chrInvert
        let a = Int(addr) & 0x1FFF
        let region = a / 0x0400 // 0..7 (1KB regions)
        var reg2k0 = Int(m4Registers[0] & 0xFE) // 2KB bank uses even value, spans 2 x 1KB
        var reg2k1 = Int(m4Registers[1] & 0xFE)
        let reg1k = [Int(m4Registers[2]), Int(m4Registers[3]), Int(m4Registers[4]), Int(m4Registers[5])]

        var bank: Int
        if !m4ChrInvert {
            switch region {
            case 0: bank = reg2k0
            case 1: bank = reg2k0 + 1
            case 2: bank = reg2k1
            case 3: bank = reg2k1 + 1
            default: bank = reg1k[region - 4]
            }
        } else {
            switch region {
            case 0: bank = reg1k[0]
            case 1: bank = reg1k[1]
            case 2: bank = reg1k[2]
            case 3: bank = reg1k[3]
            case 4: bank = reg2k0
            case 5: bank = reg2k0 + 1
            case 6: bank = reg2k1
            default: bank = reg2k1 + 1
            }
        }
        let count = max(chr1kCount, 1)
        return bank % count
    }
}
