import Foundation

final class Bus {
    var ram = [UInt8](repeating: 0, count: 2048)
    weak var ppu: PPU2C02?
    weak var cart: Cartridge?
    var apu: APU?
    var controller1: UInt8 = 0
    var controller1Shift: UInt8 = 0
    var controller1Strobe: Bool = false

    // CPU is halted during OAM DMA while PPU/APU continue running.
    // Real NES hardware takes 513 CPU cycles, or 514 when DMA begins on
    // the opposite CPU phase. We use 513 here; preserving the stall itself
    // is critical for raster timing and audio synchronization.
    var dmaStallCycles: Int = 0

    func read(_ addr: UInt16) -> UInt8 {
        switch addr {
        case 0x0000...0x1FFF:
            return ram[Int(addr & 0x07FF)]
        case 0x2000...0x3FFF:
            return ppu?.cpuRead(addr & 0x0007) ?? 0
        case 0x4015:
            return apu?.readStatus() ?? 0
        case 0x4016:
            let bit = controller1Shift & 1
            controller1Shift >>= 1
            return bit
        case 0x4017:
            return 0
        case 0x4020...0xFFFF:
            return cart?.cpuRead(addr) ?? 0
        default:
            return 0
        }
    }

    func write(_ addr: UInt16, _ value: UInt8) {
        switch addr {
        case 0x0000...0x1FFF:
            ram[Int(addr & 0x07FF)] = value
        case 0x2000...0x3FFF:
            ppu?.cpuWrite(addr & 0x0007, value)
        case 0x4000...0x4013, 0x4015, 0x4017:
            apu?.writeRegister(addr, value)
        case 0x4014:
            // OAM DMA: transfer 256 bytes, then halt the CPU for the hardware
            // DMA window. PPU and APU keep advancing while the CPU is stalled.
            let page = UInt16(value) << 8
            for i in 0..<256 {
                let b = read(page + UInt16(i))
                ppu?.oamWrite(UInt8(i & 0xFF), b)
            }
            dmaStallCycles += 513
        case 0x4016:
            controller1Strobe = value & 1 != 0
            if controller1Strobe { controller1Shift = controller1 }
        case 0x4020...0xFFFF:
            cart?.cpuWrite(addr, value)
        default:
            break
        }
    }
}
