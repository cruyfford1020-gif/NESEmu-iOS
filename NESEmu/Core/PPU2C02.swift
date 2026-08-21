import Foundation

struct PPUState: Codable {
    let nametable: [[UInt8]]
    let palette: [UInt8]
    let oam: [UInt8]
    let ctrl: UInt8
    let mask: UInt8
    let status: UInt8
    let oamAddr: UInt8
    let vramAddr: UInt16
    let tempAddr: UInt16
    let fineX: UInt8
    let addrLatch: Bool
    let dataBuffer: UInt8
    let renderAddr: UInt16
    let scanline: Int
    let cycle: Int
    let frameComplete: Bool
    let nmiOccurred: Bool
}

final class PPU2C02 {
    weak var cart: Cartridge?
    var nametable = [[UInt8]](repeating: [UInt8](repeating: 0, count: 1024), count: 2)
    var palette = [UInt8](repeating: 0, count: 32)
    var oam = [UInt8](repeating: 0, count: 256)

    // Registers
    var ctrl: UInt8 = 0
    var mask: UInt8 = 0
    var status: UInt8 = 0
    var oamAddr: UInt8 = 0
    var vramAddr: UInt16 = 0
    var tempAddr: UInt16 = 0
    var fineX: UInt8 = 0
    var addrLatch: Bool = false
    var dataBuffer: UInt8 = 0
    // Rendering copy of the Loopy VRAM address. The old renderer ignored the
    // scroll registers completely and always drew nametable 0 from (0, 0).
    private var renderAddr: UInt16 = 0

    var scanline: Int = -1
    var cycle: Int = 0
    var frameComplete = false
    var nmiOccurred = false
    var nmiOutput: Bool { ctrl & 0x80 != 0 }

    // 256x240 RGBA framebuffer
    var framebuffer = [UInt8](repeating: 0, count: 256 * 240 * 4)

    static let nesPalette: [(UInt8, UInt8, UInt8)] = {
        // Standard NES palette (64 colors), simplified approximation
        let raw: [[Int]] = [
            [84,84,84],[0,30,116],[8,16,144],[48,0,136],[68,0,100],[92,0,48],[84,4,0],[60,24,0],
            [32,42,0],[8,58,0],[0,64,0],[0,60,0],[0,50,60],[0,0,0],[0,0,0],[0,0,0],
            [152,150,152],[8,76,196],[48,50,236],[92,30,228],[136,20,176],[160,20,100],[152,34,32],[120,60,0],
            [84,90,0],[40,114,0],[8,124,0],[0,118,40],[0,102,120],[0,0,0],[0,0,0],[0,0,0],
            [236,238,236],[76,154,236],[120,124,236],[176,98,236],[228,84,236],[236,88,180],[236,106,100],[212,136,32],
            [160,170,0],[116,196,0],[76,208,32],[56,204,108],[56,180,204],[60,60,60],[0,0,0],[0,0,0],
            [236,238,236],[168,204,236],[188,188,236],[212,178,236],[236,174,236],[236,174,212],[236,180,176],[228,196,144],
            [204,210,120],[180,222,120],[168,226,144],[152,226,180],[160,214,228],[160,162,160],[0,0,0],[0,0,0]
        ]
        return raw.map { (UInt8($0[0]), UInt8($0[1]), UInt8($0[2])) }
    }()

    func reset() {
        ctrl = 0; mask = 0; status = 0; oamAddr = 0
        vramAddr = 0; tempAddr = 0; fineX = 0; addrLatch = false
        renderAddr = 0
        scanline = -1; cycle = 0
    }

    func makeState() -> PPUState {
        PPUState(nametable: nametable, palette: palette, oam: oam,
                 ctrl: ctrl, mask: mask, status: status, oamAddr: oamAddr,
                 vramAddr: vramAddr, tempAddr: tempAddr, fineX: fineX,
                 addrLatch: addrLatch, dataBuffer: dataBuffer,
                 renderAddr: renderAddr, scanline: scanline, cycle: cycle,
                 frameComplete: frameComplete, nmiOccurred: nmiOccurred)
    }

    func restoreState(_ state: PPUState) {
        nametable = state.nametable; palette = state.palette; oam = state.oam
        ctrl = state.ctrl; mask = state.mask; status = state.status
        oamAddr = state.oamAddr; vramAddr = state.vramAddr
        tempAddr = state.tempAddr; fineX = state.fineX
        addrLatch = state.addrLatch; dataBuffer = state.dataBuffer
        renderAddr = state.renderAddr; scanline = state.scanline
        cycle = state.cycle; frameComplete = state.frameComplete
        nmiOccurred = state.nmiOccurred
    }

    func cpuRead(_ reg: UInt16) -> UInt8 {
        switch reg {
        case 2: // PPUSTATUS
            let result = (status & 0xE0) | (dataBuffer & 0x1F)
            status &= ~0x80
            addrLatch = false
            return result
        case 4: // OAMDATA
            return oam[Int(oamAddr)]
        case 7: // PPUDATA
            var result = dataBuffer
            dataBuffer = ppuReadInternal(vramAddr)
            if vramAddr >= 0x3F00 { result = dataBuffer }
            vramAddr = vramAddr &+ (ctrl & 0x04 != 0 ? 32 : 1)
            return result
        default:
            return 0
        }
    }

    func cpuWrite(_ reg: UInt16, _ value: UInt8) {
        switch reg {
        case 0: // PPUCTRL
            ctrl = value
            tempAddr = (tempAddr & 0xF3FF) | (UInt16(value & 0x03) << 10)
        case 1: mask = value // PPUMASK
        case 3: oamAddr = value // OAMADDR
        case 4: oam[Int(oamAddr)] = value; oamAddr = oamAddr &+ 1 // OAMDATA
        case 5: // PPUSCROLL
            if !addrLatch {
                fineX = value & 0x07
                tempAddr = (tempAddr & 0xFFE0) | (UInt16(value) >> 3)
                addrLatch = true
            } else {
                tempAddr = (tempAddr & 0x8FFF) | (UInt16(value & 0x07) << 12)
                tempAddr = (tempAddr & 0xFC1F) | (UInt16(value & 0xF8) << 2)
                addrLatch = false
            }
        case 6: // PPUADDR
            if !addrLatch {
                tempAddr = (tempAddr & 0x00FF) | (UInt16(value & 0x3F) << 8)
                addrLatch = true
            } else {
                tempAddr = (tempAddr & 0xFF00) | UInt16(value)
                vramAddr = tempAddr
                // $2006 second write copies t -> v immediately. Keep the
                // scanline renderer synchronized for MMC3 split-screen games.
                renderAddr = tempAddr
                addrLatch = false
            }
        case 7: // PPUDATA
            ppuWriteInternal(vramAddr, value)
            vramAddr = vramAddr &+ (ctrl & 0x04 != 0 ? 32 : 1)
        default: break
        }
    }

    func oamWrite(_ addr: UInt8, _ value: UInt8) {
        oam[Int(addr)] = value
    }

    private func nametableIndex(_ addr: UInt16) -> (Int, Int) {
        let a = addr & 0x0FFF
        let table = Int(a / 0x0400)
        let offset = Int(a % 0x0400)
        guard let cart = cart else { return (0, offset) }
        let physicalTable: Int
        if cart.mirrorVertical {
            physicalTable = table % 2
        } else {
            physicalTable = table / 2
        }
        return (physicalTable, offset)
    }

    private func ppuReadInternal(_ addr: UInt16) -> UInt8 {
        let a = addr & 0x3FFF
        switch a {
        case 0x0000...0x1FFF:
            return cart?.ppuRead(a) ?? 0
        case 0x2000...0x3EFF:
            let (t, o) = nametableIndex(a)
            return nametable[t][o]
        case 0x3F00...0x3FFF:
            var pa = Int(a & 0x1F)
            if pa == 0x10 || pa == 0x14 || pa == 0x18 || pa == 0x1C { pa -= 0x10 }
            return palette[pa]
        default:
            return 0
        }
    }

    private func ppuWriteInternal(_ addr: UInt16, _ value: UInt8) {
        let a = addr & 0x3FFF
        switch a {
        case 0x0000...0x1FFF:
            cart?.ppuWrite(a, value)
        case 0x2000...0x3EFF:
            let (t, o) = nametableIndex(a)
            nametable[t][o] = value
        case 0x3F00...0x3FFF:
            var pa = Int(a & 0x1F)
            if pa == 0x10 || pa == 0x14 || pa == 0x18 || pa == 0x1C { pa -= 0x10 }
            palette[pa] = value
        default: break
        }
    }

    // Scanline-accurate renderer: draws one scanline of background + overlays sprites
    // for that scanline, using the CHR bank state as of "now" — this correctly
    // captures mid-frame CHR bank switches (e.g. MMC3 IRQ-driven status bar splits).
    func clock() -> Bool {
        var nmiFired = false
        // Clock MMC3 once per rendered scanline. The previous condition only
        // clocked the counter when BG and sprites selected opposite pattern
        // tables. Captain Tsubasa II also uses splits while those bits match,
        // so its IRQ never fired and the lower half used the wrong CHR bank.
        if cycle == 260 && scanline >= -1 && scanline < 240 && (mask & 0x18) != 0 {
            cart?.clockScanlineIRQ()
        }
        // During pre-render the PPU copies t -> v. Keep a separate rendering
        // address because CPU $2007 accesses must not advance the renderer.
        if cycle == 304 && scanline == -1 && (mask & 0x18) != 0 {
            renderAddr = tempAddr
        }
        if cycle == 256 && scanline >= 0 && scanline < 240 {
            renderScanline(scanline)
            if (mask & 0x18) != 0 { incrementRenderY() }
        }
        // Horizontal bits are reloaded from t at the end of every scanline.
        if cycle == 257 && scanline >= -1 && scanline < 240 && (mask & 0x18) != 0 {
            renderAddr = (renderAddr & 0x7BE0) | (tempAddr & 0x041F)
        }
        if cycle == 1 && scanline == 241 {
            status |= 0x80
            if nmiOutput { nmiFired = true }
        }
        if cycle == 1 && scanline == -1 {
            status &= ~0x80 // clear vblank
            status &= ~0x40 // clear sprite 0 hit
        }
        cycle += 1
        if cycle > 340 {
            cycle = 0
            scanline += 1
            if scanline > 260 {
                scanline = -1
                frameComplete = true
            }
        }
        return nmiFired
    }

    private var lastA12High = false

    /// Tracks the real PPU address bus bit 12 (A12), which is what actual MMC3
    /// hardware uses to clock its scanline IRQ counter — this replaces the earlier
    /// fixed-cycle approximation with edge detection tied to genuine CHR fetches.
    private func trackA12(_ addr: UInt16) {
        let high = (addr & 0x1000) != 0
        if high && !lastA12High {
            cart?.clockScanlineIRQ()
        }
        lastA12High = high
    }

    private func renderScanline(_ py: Int) {
        guard let cart = cart else { return }
        let bgPatternBase: UInt16 = (ctrl & 0x10 != 0) ? 0x1000 : 0x0000
        let showBG = mask & 0x08 != 0
        let showSprites = mask & 0x10 != 0
        let showBGLeft = mask & 0x02 != 0
        let showSpritesLeft = mask & 0x04 != 0
        var bgOpaque = [Bool](repeating: false, count: 256)

        if showBG {
            let startCoarseX = Int(renderAddr & 0x001F)
            let coarseY = Int((renderAddr >> 5) & 0x001F)
            let fineY = Int((renderAddr >> 12) & 0x0007)
            let baseTable = Int((renderAddr >> 10) & 0x0003)

            // 33 tiles are needed when fine X is non-zero.
            for screenTile in 0...32 {
                let totalX = startCoarseX + screenTile
                let tileX = totalX & 31
                let tableX = ((baseTable & 1) ^ ((totalX >> 5) & 1))
                let tableY = (baseTable >> 1) & 1
                let table = tableX | (tableY << 1)
                let ntBase = 0x2000 + table * 0x400
                let ntAddr = UInt16(ntBase + coarseY * 32 + tileX)
                let tileIndex = ppuReadInternal(ntAddr)
                let attrAddr = UInt16(ntBase + 0x3C0 + (coarseY / 4) * 8 + (tileX / 4))
                let attrByte = ppuReadInternal(attrAddr)
                let shift = ((coarseY % 4) / 2) * 4 + ((tileX % 4) / 2) * 2
                let paletteIndex = (attrByte >> shift) & 0x03

                let lo = cart.ppuRead(bgPatternBase + UInt16(tileIndex) * 16 + UInt16(fineY))
                let hi = cart.ppuRead(bgPatternBase + UInt16(tileIndex) * 16 + UInt16(fineY) + 8)
                for col in 0..<8 {
                    let bit = 7 - col
                    let pixelLo = (lo >> bit) & 1
                    let pixelHi = (hi >> bit) & 1
                    let pixel = (pixelHi << 1) | pixelLo
                    let px = screenTile * 8 + col - Int(fineX)
                    guard px >= 0 && px < 256 else { continue }
                    if px < 8 && !showBGLeft {
                        setPixel(px, py, palette[0]); continue
                    }
                    bgOpaque[px] = pixel != 0
                    let colorIndex: UInt8 = pixel == 0 ? palette[0] : palette[Int(paletteIndex) * 4 + Int(pixel)]
                    setPixel(px, py, colorIndex)
                }
            }
        }

        if showSprites {
            let sprite16 = (ctrl & 0x20) != 0
            let spriteHeight = sprite16 ? 16 : 8
            let spritePatternBase8: UInt16 = (ctrl & 0x08 != 0) ? 0x1000 : 0x0000
            var visibleSprites: [Int] = []
            for i in 0..<64 {
                let y = Int(oam[i * 4]) + 1
                if py >= y && py < y + spriteHeight {
                    if visibleSprites.count < 8 { visibleSprites.append(i) }
                    else { status |= 0x20; break }
                }
            }
            // Lower OAM index has priority, so paint in reverse order.
            for i in visibleSprites.reversed() {
                let base = i * 4
                let spriteY = Int(oam[base])
                guard py >= spriteY + 1 && py < spriteY + 1 + spriteHeight else { continue }
                let rawTile = oam[base + 1]
                let attr = oam[base + 2]
                let spriteX = Int(oam[base + 3])
                let flipH = attr & 0x40 != 0
                let flipV = attr & 0x80 != 0
                let paletteIndex = attr & 0x03
                let behindBackground = attr & 0x20 != 0
                var spriteRow = py - spriteY - 1
                if flipV { spriteRow = spriteHeight - 1 - spriteRow }

                let patternBase: UInt16
                let tileIndex: UInt16
                let srcRow: Int
                if sprite16 {
                    patternBase = (rawTile & 0x01) != 0 ? 0x1000 : 0x0000
                    let topTile = UInt16(rawTile & 0xFE)
                    if spriteRow < 8 {
                        tileIndex = topTile
                        srcRow = spriteRow
                    } else {
                        tileIndex = topTile + 1
                        srcRow = spriteRow - 8
                    }
                } else {
                    patternBase = spritePatternBase8
                    tileIndex = UInt16(rawTile)
                    srcRow = spriteRow
                }

                let lo = cart.ppuRead(patternBase + tileIndex * 16 + UInt16(srcRow))
                let hi = cart.ppuRead(patternBase + tileIndex * 16 + UInt16(srcRow) + 8)
                for col in 0..<8 {
                    let srcCol = flipH ? col : 7 - col
                    let pixelLo = (lo >> srcCol) & 1
                    let pixelHi = (hi >> srcCol) & 1
                    let pixel = (pixelHi << 1) | pixelLo
                    if pixel == 0 { continue }
                    let px = spriteX + col
                    guard px >= 0 && px < 256 else { continue }
                    if px < 8 && !showSpritesLeft { continue }
                    if i == 0 && bgOpaque[px] && px < 255 && showBG {
                        status |= 0x40
                    }
                    if behindBackground && bgOpaque[px] { continue }
                    let colorIndex = palette[16 + Int(paletteIndex) * 4 + Int(pixel)]
                    setPixel(px, py, colorIndex)
                }
            }
        }
    }

    /// Hardware-compatible vertical increment of the Loopy v register.
    private func incrementRenderY() {
        if (renderAddr & 0x7000) != 0x7000 {
            renderAddr &+= 0x1000
            return
        }
        renderAddr &= ~0x7000
        var coarseY = (renderAddr & 0x03E0) >> 5
        if coarseY == 29 {
            coarseY = 0
            renderAddr ^= 0x0800
        } else if coarseY == 31 {
            coarseY = 0
        } else {
            coarseY &+= 1
        }
        renderAddr = (renderAddr & ~0x03E0) | (coarseY << 5)
    }

    private func setPixel(_ x: Int, _ y: Int, _ colorIndex: UInt8) {
        let c = PPU2C02.nesPalette[Int(colorIndex & 0x3F)]
        let offset = (y * 256 + x) * 4
        guard offset + 3 < framebuffer.count else { return }
        framebuffer[offset] = c.0
        framebuffer[offset + 1] = c.1
        framebuffer[offset + 2] = c.2
        framebuffer[offset + 3] = 255
    }
}
