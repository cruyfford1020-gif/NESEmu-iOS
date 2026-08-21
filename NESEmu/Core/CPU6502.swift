import Foundation

struct CPUState: Codable {
    let a: UInt8
    let x: UInt8
    let y: UInt8
    let sp: UInt8
    let pc: UInt16
    let status: UInt8
    let cycles: Int
    let totalCycles: UInt64
    let pendingNMI: Bool
    let pendingIRQ: Bool
}

final class CPU6502 {
    // Registers
    var a: UInt8 = 0
    var x: UInt8 = 0
    var y: UInt8 = 0
    var sp: UInt8 = 0xFD
    var pc: UInt16 = 0
    var status: UInt8 = 0x24 // IRQ disable + unused bit set

    // Status flag bits
    struct Flag {
        static let C: UInt8 = 1 << 0
        static let Z: UInt8 = 1 << 1
        static let I: UInt8 = 1 << 2
        static let D: UInt8 = 1 << 3
        static let B: UInt8 = 1 << 4
        static let U: UInt8 = 1 << 5
        static let V: UInt8 = 1 << 6
        static let N: UInt8 = 1 << 7
    }

    unowned let bus: Bus
    var cycles: Int = 0
    var totalCycles: UInt64 = 0
    private var pendingNMI = false
    private var pendingIRQ = false

    init(bus: Bus) {
        self.bus = bus
    }

    func reset() {
        let lo = UInt16(bus.read(0xFFFC))
        let hi = UInt16(bus.read(0xFFFD))
        pc = (hi << 8) | lo
        sp = 0xFD
        status = 0x24
        a = 0; x = 0; y = 0
        cycles = 8
    }

    func makeState() -> CPUState {
        CPUState(a: a, x: x, y: y, sp: sp, pc: pc, status: status,
                 cycles: cycles, totalCycles: totalCycles,
                 pendingNMI: pendingNMI, pendingIRQ: pendingIRQ)
    }

    func restoreState(_ state: CPUState) {
        a = state.a; x = state.x; y = state.y; sp = state.sp
        pc = state.pc; status = state.status; cycles = state.cycles
        totalCycles = state.totalCycles
        pendingNMI = state.pendingNMI
        pendingIRQ = state.pendingIRQ
    }

    func irq() {
        pendingIRQ = true
    }

    func nmi() {
        pendingNMI = true
    }

    private func doIRQ() {
        if status & Flag.I == 0 {
            push16(pc)
            push8((status & ~Flag.B) | Flag.U)
            setFlag(Flag.I, true)
            let lo = UInt16(bus.read(0xFFFE))
            let hi = UInt16(bus.read(0xFFFF))
            pc = (hi << 8) | lo
            cycles = 7
        }
    }

    private func doNMI() {
        push16(pc)
        push8((status & ~Flag.B) | Flag.U)
        setFlag(Flag.I, true)
        let lo = UInt16(bus.read(0xFFFA))
        let hi = UInt16(bus.read(0xFFFB))
        pc = (hi << 8) | lo
        cycles = 8
    }

    private func setFlag(_ flag: UInt8, _ value: Bool) {
        if value { status |= flag } else { status &= ~flag }
    }
    private func getFlag(_ flag: UInt8) -> Bool { status & flag != 0 }

    private func push8(_ v: UInt8) {
        bus.write(0x0100 + UInt16(sp), v)
        sp = sp &- 1
    }
    private func pop8() -> UInt8 {
        sp = sp &+ 1
        return bus.read(0x0100 + UInt16(sp))
    }
    private func push16(_ v: UInt16) {
        push8(UInt8((v >> 8) & 0xFF))
        push8(UInt8(v & 0xFF))
    }
    private func pop16() -> UInt16 {
        let lo = UInt16(pop8())
        let hi = UInt16(pop8())
        return (hi << 8) | lo
    }

    // Runs one instruction, returns cycles consumed
    @discardableResult
    func step() -> Int {
        if cycles > 0 { cycles -= 1; totalCycles += 1; return 1 }

        // Only service interrupts when idle between instructions (matches real 6502 behavior)
        if pendingNMI {
            pendingNMI = false
            doNMI()
            let consumed = cycles
            cycles -= 1
            totalCycles += UInt64(consumed)
            return consumed
        }
        if pendingIRQ {
            pendingIRQ = false
            doIRQ()
            if cycles > 0 {
                let consumed = cycles
                cycles -= 1
                totalCycles += UInt64(consumed)
                return consumed
            }
            // I flag was set; IRQ ignored, fall through to normal fetch
        }

        let opcode = bus.read(pc)
        pc = pc &+ 1
        let instr = opcodeTable[Int(opcode)]
        let (addr, pageCrossed, isAccum) = resolveAddress(instr.mode)
        let extra = execute(instr, addr: addr, isAccum: isAccum)
        cycles = instr.cycles + (pageCrossed && instr.canCrossPage ? 1 : 0) + extra
        totalCycles += UInt64(cycles)
        let consumed = cycles
        cycles -= 1
        return consumed
    }

    enum AddrMode {
        case imp, acc, imm, zp, zpx, zpy, rel, abs, absx, absy, ind, indx, indy
    }

    struct Instr {
        let name: String
        let mode: AddrMode
        let cycles: Int
        let canCrossPage: Bool
        let op: (CPU6502, UInt16, Bool) -> Int
    }

    private func resolveAddress(_ mode: AddrMode) -> (UInt16, Bool, Bool) {
        switch mode {
        case .imp: return (0, false, false)
        case .acc: return (0, false, true)
        case .imm:
            let addr = pc; pc = pc &+ 1
            return (addr, false, false)
        case .zp:
            let addr = UInt16(bus.read(pc)); pc = pc &+ 1
            return (addr, false, false)
        case .zpx:
            let addr = UInt16((bus.read(pc) &+ x)); pc = pc &+ 1
            return (addr, false, false)
        case .zpy:
            let addr = UInt16((bus.read(pc) &+ y)); pc = pc &+ 1
            return (addr, false, false)
        case .rel:
            var offset = UInt16(bus.read(pc)); pc = pc &+ 1
            if offset & 0x80 != 0 { offset |= 0xFF00 }
            let addr = pc &+ offset
            return (addr, (addr & 0xFF00) != (pc & 0xFF00), false)
        case .abs:
            let lo = UInt16(bus.read(pc)); let hi = UInt16(bus.read(pc &+ 1))
            pc = pc &+ 2
            return ((hi << 8) | lo, false, false)
        case .absx:
            let lo = UInt16(bus.read(pc)); let hi = UInt16(bus.read(pc &+ 1))
            pc = pc &+ 2
            let base = (hi << 8) | lo
            let addr = base &+ UInt16(x)
            return (addr, (addr & 0xFF00) != (base & 0xFF00), false)
        case .absy:
            let lo = UInt16(bus.read(pc)); let hi = UInt16(bus.read(pc &+ 1))
            pc = pc &+ 2
            let base = (hi << 8) | lo
            let addr = base &+ UInt16(y)
            return (addr, (addr & 0xFF00) != (base & 0xFF00), false)
        case .ind:
            let lo = UInt16(bus.read(pc)); let hi = UInt16(bus.read(pc &+ 1))
            pc = pc &+ 2
            let ptr = (hi << 8) | lo
            let loAddr = ptr
            let hiAddr = (ptr & 0xFF00) | ((ptr &+ 1) & 0x00FF) // 6502 page-wrap bug
            let lo2 = UInt16(bus.read(loAddr))
            let hi2 = UInt16(bus.read(hiAddr))
            return ((hi2 << 8) | lo2, false, false)
        case .indx:
            let t = bus.read(pc) &+ x; pc = pc &+ 1
            let lo = UInt16(bus.read(UInt16(t)))
            let hi = UInt16(bus.read(UInt16(t &+ 1)))
            return ((hi << 8) | lo, false, false)
        case .indy:
            let t = bus.read(pc); pc = pc &+ 1
            let lo = UInt16(bus.read(UInt16(t)))
            let hi = UInt16(bus.read(UInt16(t &+ 1)))
            let base = (hi << 8) | lo
            let addr = base &+ UInt16(y)
            return (addr, (addr & 0xFF00) != (base & 0xFF00), false)
        }
    }

    private func execute(_ instr: Instr, addr: UInt16, isAccum: Bool) -> Int {
        return instr.op(self, addr, isAccum)
    }

    private func setZN(_ v: UInt8) {
        setFlag(Flag.Z, v == 0)
        setFlag(Flag.N, v & 0x80 != 0)
    }

    // MARK: - Instruction implementations
    private func LDA(_ addr: UInt16, _ acc: Bool) -> Int { a = bus.read(addr); setZN(a); return 0 }
    private func LDX(_ addr: UInt16, _ acc: Bool) -> Int { x = bus.read(addr); setZN(x); return 0 }
    private func LDY(_ addr: UInt16, _ acc: Bool) -> Int { y = bus.read(addr); setZN(y); return 0 }
    private func STA(_ addr: UInt16, _ acc: Bool) -> Int { bus.write(addr, a); return 0 }
    private func STX(_ addr: UInt16, _ acc: Bool) -> Int { bus.write(addr, x); return 0 }
    private func STY(_ addr: UInt16, _ acc: Bool) -> Int { bus.write(addr, y); return 0 }
    private func TAX(_ addr: UInt16, _ acc: Bool) -> Int { x = a; setZN(x); return 0 }
    private func TAY(_ addr: UInt16, _ acc: Bool) -> Int { y = a; setZN(y); return 0 }
    private func TXA(_ addr: UInt16, _ acc: Bool) -> Int { a = x; setZN(a); return 0 }
    private func TYA(_ addr: UInt16, _ acc: Bool) -> Int { a = y; setZN(a); return 0 }
    private func TSX(_ addr: UInt16, _ acc: Bool) -> Int { x = sp; setZN(x); return 0 }
    private func TXS(_ addr: UInt16, _ acc: Bool) -> Int { sp = x; return 0 }
    private func PHA(_ addr: UInt16, _ acc: Bool) -> Int { push8(a); return 0 }
    private func PHP(_ addr: UInt16, _ acc: Bool) -> Int { push8(status | Flag.B | Flag.U); return 0 }
    private func PLA(_ addr: UInt16, _ acc: Bool) -> Int { a = pop8(); setZN(a); return 0 }
    private func PLP(_ addr: UInt16, _ acc: Bool) -> Int { status = (pop8() & ~Flag.B) | Flag.U; return 0 }

    private func ADC(_ addr: UInt16, _ acc: Bool) -> Int {
        let m = bus.read(addr)
        let carry: UInt16 = getFlag(Flag.C) ? 1 : 0
        let sum = UInt16(a) + UInt16(m) + carry
        setFlag(Flag.C, sum > 0xFF)
        let result = UInt8(sum & 0xFF)
        setFlag(Flag.V, (~(a ^ m) & (a ^ result) & 0x80) != 0)
        a = result
        setZN(a)
        return 0
    }
    private func SBC(_ addr: UInt16, _ acc: Bool) -> Int {
        let m = bus.read(addr) ^ 0xFF
        let carry: UInt16 = getFlag(Flag.C) ? 1 : 0
        let sum = UInt16(a) + UInt16(m) + carry
        setFlag(Flag.C, sum > 0xFF)
        let result = UInt8(sum & 0xFF)
        setFlag(Flag.V, (~(a ^ m) & (a ^ result) & 0x80) != 0)
        a = result
        setZN(a)
        return 0
    }
    private func AND(_ addr: UInt16, _ acc: Bool) -> Int { a &= bus.read(addr); setZN(a); return 0 }
    private func ORA(_ addr: UInt16, _ acc: Bool) -> Int { a |= bus.read(addr); setZN(a); return 0 }
    private func EOR(_ addr: UInt16, _ acc: Bool) -> Int { a ^= bus.read(addr); setZN(a); return 0 }
    private func BIT(_ addr: UInt16, _ acc: Bool) -> Int {
        let m = bus.read(addr)
        setFlag(Flag.Z, (a & m) == 0)
        setFlag(Flag.V, m & 0x40 != 0)
        setFlag(Flag.N, m & 0x80 != 0)
        return 0
    }
    private func CMPGeneric(_ reg: UInt8, _ addr: UInt16) {
        let m = bus.read(addr)
        let result = reg &- m
        setFlag(Flag.C, reg >= m)
        setZN(result)
    }
    private func CMP(_ addr: UInt16, _ acc: Bool) -> Int { CMPGeneric(a, addr); return 0 }
    private func CPX(_ addr: UInt16, _ acc: Bool) -> Int { CMPGeneric(x, addr); return 0 }
    private func CPY(_ addr: UInt16, _ acc: Bool) -> Int { CMPGeneric(y, addr); return 0 }

    private func INC(_ addr: UInt16, _ acc: Bool) -> Int { let v = bus.read(addr) &+ 1; bus.write(addr, v); setZN(v); return 0 }
    private func DEC(_ addr: UInt16, _ acc: Bool) -> Int { let v = bus.read(addr) &- 1; bus.write(addr, v); setZN(v); return 0 }
    private func INX(_ addr: UInt16, _ acc: Bool) -> Int { x = x &+ 1; setZN(x); return 0 }
    private func INY(_ addr: UInt16, _ acc: Bool) -> Int { y = y &+ 1; setZN(y); return 0 }
    private func DEX(_ addr: UInt16, _ acc: Bool) -> Int { x = x &- 1; setZN(x); return 0 }
    private func DEY(_ addr: UInt16, _ acc: Bool) -> Int { y = y &- 1; setZN(y); return 0 }

    private func ASL(_ addr: UInt16, _ acc: Bool) -> Int {
        if acc {
            setFlag(Flag.C, a & 0x80 != 0); a <<= 1; setZN(a)
        } else {
            var v = bus.read(addr)
            setFlag(Flag.C, v & 0x80 != 0); v <<= 1; bus.write(addr, v); setZN(v)
        }
        return 0
    }
    private func LSR(_ addr: UInt16, _ acc: Bool) -> Int {
        if acc {
            setFlag(Flag.C, a & 0x01 != 0); a >>= 1; setZN(a)
        } else {
            var v = bus.read(addr)
            setFlag(Flag.C, v & 0x01 != 0); v >>= 1; bus.write(addr, v); setZN(v)
        }
        return 0
    }
    private func ROL(_ addr: UInt16, _ acc: Bool) -> Int {
        let carryIn: UInt8 = getFlag(Flag.C) ? 1 : 0
        if acc {
            setFlag(Flag.C, a & 0x80 != 0); a = (a << 1) | carryIn; setZN(a)
        } else {
            var v = bus.read(addr)
            setFlag(Flag.C, v & 0x80 != 0); v = (v << 1) | carryIn; bus.write(addr, v); setZN(v)
        }
        return 0
    }
    private func ROR(_ addr: UInt16, _ acc: Bool) -> Int {
        let carryIn: UInt8 = getFlag(Flag.C) ? 0x80 : 0
        if acc {
            setFlag(Flag.C, a & 0x01 != 0); a = (a >> 1) | carryIn; setZN(a)
        } else {
            var v = bus.read(addr)
            setFlag(Flag.C, v & 0x01 != 0); v = (v >> 1) | carryIn; bus.write(addr, v); setZN(v)
        }
        return 0
    }

    private func branch(_ addr: UInt16, cond: Bool) -> Int {
        guard cond else { return 0 }
        pc = addr
        return 1
    }
    private func BCC(_ addr: UInt16, _ acc: Bool) -> Int { branch(addr, cond: !getFlag(Flag.C)) }
    private func BCS(_ addr: UInt16, _ acc: Bool) -> Int { branch(addr, cond: getFlag(Flag.C)) }
    private func BEQ(_ addr: UInt16, _ acc: Bool) -> Int { branch(addr, cond: getFlag(Flag.Z)) }
    private func BNE(_ addr: UInt16, _ acc: Bool) -> Int { branch(addr, cond: !getFlag(Flag.Z)) }
    private func BMI(_ addr: UInt16, _ acc: Bool) -> Int { branch(addr, cond: getFlag(Flag.N)) }
    private func BPL(_ addr: UInt16, _ acc: Bool) -> Int { branch(addr, cond: !getFlag(Flag.N)) }
    private func BVC(_ addr: UInt16, _ acc: Bool) -> Int { branch(addr, cond: !getFlag(Flag.V)) }
    private func BVS(_ addr: UInt16, _ acc: Bool) -> Int { branch(addr, cond: getFlag(Flag.V)) }

    private func CLC(_ addr: UInt16, _ acc: Bool) -> Int { setFlag(Flag.C, false); return 0 }
    private func SEC(_ addr: UInt16, _ acc: Bool) -> Int { setFlag(Flag.C, true); return 0 }
    private func CLI(_ addr: UInt16, _ acc: Bool) -> Int { setFlag(Flag.I, false); return 0 }
    private func SEI(_ addr: UInt16, _ acc: Bool) -> Int { setFlag(Flag.I, true); return 0 }
    private func CLD(_ addr: UInt16, _ acc: Bool) -> Int { setFlag(Flag.D, false); return 0 }
    private func SED(_ addr: UInt16, _ acc: Bool) -> Int { setFlag(Flag.D, true); return 0 }
    private func CLV(_ addr: UInt16, _ acc: Bool) -> Int { setFlag(Flag.V, false); return 0 }

    private func JMP(_ addr: UInt16, _ acc: Bool) -> Int { pc = addr; return 0 }
    private func JSR(_ addr: UInt16, _ acc: Bool) -> Int { push16(pc &- 1); pc = addr; return 0 }
    private func RTS(_ addr: UInt16, _ acc: Bool) -> Int { pc = pop16() &+ 1; return 0 }
    private func RTI(_ addr: UInt16, _ acc: Bool) -> Int {
        status = (pop8() & ~Flag.B) | Flag.U
        pc = pop16()
        return 0
    }
    private func BRK(_ addr: UInt16, _ acc: Bool) -> Int {
        pc = pc &+ 1
        push16(pc)
        push8(status | Flag.B | Flag.U)
        setFlag(Flag.I, true)
        let lo = UInt16(bus.read(0xFFFE)); let hi = UInt16(bus.read(0xFFFF))
        pc = (hi << 8) | lo
        return 0
    }
    private func NOP(_ addr: UInt16, _ acc: Bool) -> Int { return 0 }

    // MARK: - Undocumented/illegal opcodes (used by many commercial NES games)
    private func LAX(_ addr: UInt16, _ acc: Bool) -> Int {
        a = bus.read(addr); x = a; setZN(a); return 0
    }
    private func SAX(_ addr: UInt16, _ acc: Bool) -> Int {
        bus.write(addr, a & x); return 0
    }
    private func DCP(_ addr: UInt16, _ acc: Bool) -> Int {
        let v = bus.read(addr) &- 1
        bus.write(addr, v)
        let result = a &- v
        setFlag(Flag.C, a >= v)
        setZN(result)
        return 0
    }
    private func ISC(_ addr: UInt16, _ acc: Bool) -> Int {
        let v = bus.read(addr) &+ 1
        bus.write(addr, v)
        let m = v ^ 0xFF
        let carry: UInt16 = getFlag(Flag.C) ? 1 : 0
        let sum = UInt16(a) + UInt16(m) + carry
        setFlag(Flag.C, sum > 0xFF)
        let result = UInt8(sum & 0xFF)
        setFlag(Flag.V, (~(a ^ m) & (a ^ result) & 0x80) != 0)
        a = result
        setZN(a)
        return 0
    }
    private func SLO(_ addr: UInt16, _ acc: Bool) -> Int {
        var v = bus.read(addr)
        setFlag(Flag.C, v & 0x80 != 0)
        v <<= 1
        bus.write(addr, v)
        a |= v
        setZN(a)
        return 0
    }
    private func RLA(_ addr: UInt16, _ acc: Bool) -> Int {
        let carryIn: UInt8 = getFlag(Flag.C) ? 1 : 0
        var v = bus.read(addr)
        setFlag(Flag.C, v & 0x80 != 0)
        v = (v << 1) | carryIn
        bus.write(addr, v)
        a &= v
        setZN(a)
        return 0
    }
    private func SRE(_ addr: UInt16, _ acc: Bool) -> Int {
        var v = bus.read(addr)
        setFlag(Flag.C, v & 0x01 != 0)
        v >>= 1
        bus.write(addr, v)
        a ^= v
        setZN(a)
        return 0
    }
    private func RRA(_ addr: UInt16, _ acc: Bool) -> Int {
        let carryIn: UInt8 = getFlag(Flag.C) ? 0x80 : 0
        var v = bus.read(addr)
        setFlag(Flag.C, v & 0x01 != 0)
        v = (v >> 1) | carryIn
        bus.write(addr, v)
        let m = v
        let carry: UInt16 = getFlag(Flag.C) ? 1 : 0
        let sum = UInt16(a) + UInt16(m) + carry
        setFlag(Flag.C, sum > 0xFF)
        let result = UInt8(sum & 0xFF)
        setFlag(Flag.V, (~(a ^ m) & (a ^ result) & 0x80) != 0)
        a = result
        setZN(a)
        return 0
    }
    private func ANC(_ addr: UInt16, _ acc: Bool) -> Int {
        a &= bus.read(addr)
        setZN(a)
        setFlag(Flag.C, a & 0x80 != 0)
        return 0
    }
    private func ALR(_ addr: UInt16, _ acc: Bool) -> Int {
        a &= bus.read(addr)
        setFlag(Flag.C, a & 0x01 != 0)
        a >>= 1
        setZN(a)
        return 0
    }
    private func ARR(_ addr: UInt16, _ acc: Bool) -> Int {
        a &= bus.read(addr)
        let carryIn: UInt8 = getFlag(Flag.C) ? 0x80 : 0
        a = (a >> 1) | carryIn
        setZN(a)
        setFlag(Flag.C, a & 0x40 != 0)
        setFlag(Flag.V, ((a >> 6) ^ (a >> 5)) & 1 != 0)
        return 0
    }
    private func SBX(_ addr: UInt16, _ acc: Bool) -> Int {
        let m = bus.read(addr)
        let v = a & x
        setFlag(Flag.C, v >= m)
        x = v &- m
        setZN(x)
        return 0
    }

    // MARK: - Opcode table (official opcodes)
    lazy var opcodeTable: [Instr] = {
        var t = [Instr](repeating: Instr(name: "NOP", mode: .imp, cycles: 2, canCrossPage: false, op: { c,a,acc in c.NOP(a,acc) }), count: 256)
        func set(_ op: Int, _ name: String, _ mode: AddrMode, _ cyc: Int, _ page: Bool = false, _ fn: @escaping (CPU6502, UInt16, Bool) -> Int) {
            t[op] = Instr(name: name, mode: mode, cycles: cyc, canCrossPage: page, op: fn)
        }
        // Load/Store
        set(0xA9,"LDA",.imm,2){c,a,ac in c.LDA(a,ac)}; set(0xA5,"LDA",.zp,3){c,a,ac in c.LDA(a,ac)}
        set(0xB5,"LDA",.zpx,4){c,a,ac in c.LDA(a,ac)}; set(0xAD,"LDA",.abs,4){c,a,ac in c.LDA(a,ac)}
        set(0xBD,"LDA",.absx,4,true){c,a,ac in c.LDA(a,ac)}; set(0xB9,"LDA",.absy,4,true){c,a,ac in c.LDA(a,ac)}
        set(0xA1,"LDA",.indx,6){c,a,ac in c.LDA(a,ac)}; set(0xB1,"LDA",.indy,5,true){c,a,ac in c.LDA(a,ac)}
        set(0xA2,"LDX",.imm,2){c,a,ac in c.LDX(a,ac)}; set(0xA6,"LDX",.zp,3){c,a,ac in c.LDX(a,ac)}
        set(0xB6,"LDX",.zpy,4){c,a,ac in c.LDX(a,ac)}; set(0xAE,"LDX",.abs,4){c,a,ac in c.LDX(a,ac)}
        set(0xBE,"LDX",.absy,4,true){c,a,ac in c.LDX(a,ac)}
        set(0xA0,"LDY",.imm,2){c,a,ac in c.LDY(a,ac)}; set(0xA4,"LDY",.zp,3){c,a,ac in c.LDY(a,ac)}
        set(0xB4,"LDY",.zpx,4){c,a,ac in c.LDY(a,ac)}; set(0xAC,"LDY",.abs,4){c,a,ac in c.LDY(a,ac)}
        set(0xBC,"LDY",.absx,4,true){c,a,ac in c.LDY(a,ac)}
        set(0x85,"STA",.zp,3){c,a,ac in c.STA(a,ac)}; set(0x95,"STA",.zpx,4){c,a,ac in c.STA(a,ac)}
        set(0x8D,"STA",.abs,4){c,a,ac in c.STA(a,ac)}; set(0x9D,"STA",.absx,5){c,a,ac in c.STA(a,ac)}
        set(0x99,"STA",.absy,5){c,a,ac in c.STA(a,ac)}; set(0x81,"STA",.indx,6){c,a,ac in c.STA(a,ac)}
        set(0x91,"STA",.indy,6){c,a,ac in c.STA(a,ac)}
        set(0x86,"STX",.zp,3){c,a,ac in c.STX(a,ac)}; set(0x96,"STX",.zpy,4){c,a,ac in c.STX(a,ac)}
        set(0x8E,"STX",.abs,4){c,a,ac in c.STX(a,ac)}
        set(0x84,"STY",.zp,3){c,a,ac in c.STY(a,ac)}; set(0x94,"STY",.zpx,4){c,a,ac in c.STY(a,ac)}
        set(0x8C,"STY",.abs,4){c,a,ac in c.STY(a,ac)}
        // Transfers / stack
        set(0xAA,"TAX",.imp,2){c,a,ac in c.TAX(a,ac)}; set(0xA8,"TAY",.imp,2){c,a,ac in c.TAY(a,ac)}
        set(0x8A,"TXA",.imp,2){c,a,ac in c.TXA(a,ac)}; set(0x98,"TYA",.imp,2){c,a,ac in c.TYA(a,ac)}
        set(0xBA,"TSX",.imp,2){c,a,ac in c.TSX(a,ac)}; set(0x9A,"TXS",.imp,2){c,a,ac in c.TXS(a,ac)}
        set(0x48,"PHA",.imp,3){c,a,ac in c.PHA(a,ac)}; set(0x08,"PHP",.imp,3){c,a,ac in c.PHP(a,ac)}
        set(0x68,"PLA",.imp,4){c,a,ac in c.PLA(a,ac)}; set(0x28,"PLP",.imp,4){c,a,ac in c.PLP(a,ac)}
        // ALU
        set(0x69,"ADC",.imm,2){c,a,ac in c.ADC(a,ac)}; set(0x65,"ADC",.zp,3){c,a,ac in c.ADC(a,ac)}
        set(0x75,"ADC",.zpx,4){c,a,ac in c.ADC(a,ac)}; set(0x6D,"ADC",.abs,4){c,a,ac in c.ADC(a,ac)}
        set(0x7D,"ADC",.absx,4,true){c,a,ac in c.ADC(a,ac)}; set(0x79,"ADC",.absy,4,true){c,a,ac in c.ADC(a,ac)}
        set(0x61,"ADC",.indx,6){c,a,ac in c.ADC(a,ac)}; set(0x71,"ADC",.indy,5,true){c,a,ac in c.ADC(a,ac)}
        set(0xE9,"SBC",.imm,2){c,a,ac in c.SBC(a,ac)}; set(0xE5,"SBC",.zp,3){c,a,ac in c.SBC(a,ac)}
        set(0xF5,"SBC",.zpx,4){c,a,ac in c.SBC(a,ac)}; set(0xED,"SBC",.abs,4){c,a,ac in c.SBC(a,ac)}
        set(0xFD,"SBC",.absx,4,true){c,a,ac in c.SBC(a,ac)}; set(0xF9,"SBC",.absy,4,true){c,a,ac in c.SBC(a,ac)}
        set(0xE1,"SBC",.indx,6){c,a,ac in c.SBC(a,ac)}; set(0xF1,"SBC",.indy,5,true){c,a,ac in c.SBC(a,ac)}
        set(0x29,"AND",.imm,2){c,a,ac in c.AND(a,ac)}; set(0x25,"AND",.zp,3){c,a,ac in c.AND(a,ac)}
        set(0x35,"AND",.zpx,4){c,a,ac in c.AND(a,ac)}; set(0x2D,"AND",.abs,4){c,a,ac in c.AND(a,ac)}
        set(0x3D,"AND",.absx,4,true){c,a,ac in c.AND(a,ac)}; set(0x39,"AND",.absy,4,true){c,a,ac in c.AND(a,ac)}
        set(0x21,"AND",.indx,6){c,a,ac in c.AND(a,ac)}; set(0x31,"AND",.indy,5,true){c,a,ac in c.AND(a,ac)}
        set(0x09,"ORA",.imm,2){c,a,ac in c.ORA(a,ac)}; set(0x05,"ORA",.zp,3){c,a,ac in c.ORA(a,ac)}
        set(0x15,"ORA",.zpx,4){c,a,ac in c.ORA(a,ac)}; set(0x0D,"ORA",.abs,4){c,a,ac in c.ORA(a,ac)}
        set(0x1D,"ORA",.absx,4,true){c,a,ac in c.ORA(a,ac)}; set(0x19,"ORA",.absy,4,true){c,a,ac in c.ORA(a,ac)}
        set(0x01,"ORA",.indx,6){c,a,ac in c.ORA(a,ac)}; set(0x11,"ORA",.indy,5,true){c,a,ac in c.ORA(a,ac)}
        set(0x49,"EOR",.imm,2){c,a,ac in c.EOR(a,ac)}; set(0x45,"EOR",.zp,3){c,a,ac in c.EOR(a,ac)}
        set(0x55,"EOR",.zpx,4){c,a,ac in c.EOR(a,ac)}; set(0x4D,"EOR",.abs,4){c,a,ac in c.EOR(a,ac)}
        set(0x5D,"EOR",.absx,4,true){c,a,ac in c.EOR(a,ac)}; set(0x59,"EOR",.absy,4,true){c,a,ac in c.EOR(a,ac)}
        set(0x41,"EOR",.indx,6){c,a,ac in c.EOR(a,ac)}; set(0x51,"EOR",.indy,5,true){c,a,ac in c.EOR(a,ac)}
        set(0x24,"BIT",.zp,3){c,a,ac in c.BIT(a,ac)}; set(0x2C,"BIT",.abs,4){c,a,ac in c.BIT(a,ac)}
        set(0xC9,"CMP",.imm,2){c,a,ac in c.CMP(a,ac)}; set(0xC5,"CMP",.zp,3){c,a,ac in c.CMP(a,ac)}
        set(0xD5,"CMP",.zpx,4){c,a,ac in c.CMP(a,ac)}; set(0xCD,"CMP",.abs,4){c,a,ac in c.CMP(a,ac)}
        set(0xDD,"CMP",.absx,4,true){c,a,ac in c.CMP(a,ac)}; set(0xD9,"CMP",.absy,4,true){c,a,ac in c.CMP(a,ac)}
        set(0xC1,"CMP",.indx,6){c,a,ac in c.CMP(a,ac)}; set(0xD1,"CMP",.indy,5,true){c,a,ac in c.CMP(a,ac)}
        set(0xE0,"CPX",.imm,2){c,a,ac in c.CPX(a,ac)}; set(0xE4,"CPX",.zp,3){c,a,ac in c.CPX(a,ac)}
        set(0xEC,"CPX",.abs,4){c,a,ac in c.CPX(a,ac)}
        set(0xC0,"CPY",.imm,2){c,a,ac in c.CPY(a,ac)}; set(0xC4,"CPY",.zp,3){c,a,ac in c.CPY(a,ac)}
        set(0xCC,"CPY",.abs,4){c,a,ac in c.CPY(a,ac)}
        // Inc/Dec
        set(0xE6,"INC",.zp,5){c,a,ac in c.INC(a,ac)}; set(0xF6,"INC",.zpx,6){c,a,ac in c.INC(a,ac)}
        set(0xEE,"INC",.abs,6){c,a,ac in c.INC(a,ac)}; set(0xFE,"INC",.absx,7){c,a,ac in c.INC(a,ac)}
        set(0xC6,"DEC",.zp,5){c,a,ac in c.DEC(a,ac)}; set(0xD6,"DEC",.zpx,6){c,a,ac in c.DEC(a,ac)}
        set(0xCE,"DEC",.abs,6){c,a,ac in c.DEC(a,ac)}; set(0xDE,"DEC",.absx,7){c,a,ac in c.DEC(a,ac)}
        set(0xE8,"INX",.imp,2){c,a,ac in c.INX(a,ac)}; set(0xC8,"INY",.imp,2){c,a,ac in c.INY(a,ac)}
        set(0xCA,"DEX",.imp,2){c,a,ac in c.DEX(a,ac)}; set(0x88,"DEY",.imp,2){c,a,ac in c.DEY(a,ac)}
        // Shifts
        set(0x0A,"ASL",.acc,2){c,a,ac in c.ASL(a,ac)}; set(0x06,"ASL",.zp,5){c,a,ac in c.ASL(a,ac)}
        set(0x16,"ASL",.zpx,6){c,a,ac in c.ASL(a,ac)}; set(0x0E,"ASL",.abs,6){c,a,ac in c.ASL(a,ac)}
        set(0x1E,"ASL",.absx,7){c,a,ac in c.ASL(a,ac)}
        set(0x4A,"LSR",.acc,2){c,a,ac in c.LSR(a,ac)}; set(0x46,"LSR",.zp,5){c,a,ac in c.LSR(a,ac)}
        set(0x56,"LSR",.zpx,6){c,a,ac in c.LSR(a,ac)}; set(0x4E,"LSR",.abs,6){c,a,ac in c.LSR(a,ac)}
        set(0x5E,"LSR",.absx,7){c,a,ac in c.LSR(a,ac)}
        set(0x2A,"ROL",.acc,2){c,a,ac in c.ROL(a,ac)}; set(0x26,"ROL",.zp,5){c,a,ac in c.ROL(a,ac)}
        set(0x36,"ROL",.zpx,6){c,a,ac in c.ROL(a,ac)}; set(0x2E,"ROL",.abs,6){c,a,ac in c.ROL(a,ac)}
        set(0x3E,"ROL",.absx,7){c,a,ac in c.ROL(a,ac)}
        set(0x6A,"ROR",.acc,2){c,a,ac in c.ROR(a,ac)}; set(0x66,"ROR",.zp,5){c,a,ac in c.ROR(a,ac)}
        set(0x76,"ROR",.zpx,6){c,a,ac in c.ROR(a,ac)}; set(0x6E,"ROR",.abs,6){c,a,ac in c.ROR(a,ac)}
        set(0x7E,"ROR",.absx,7){c,a,ac in c.ROR(a,ac)}
        // Branches
        set(0x90,"BCC",.rel,2){c,a,ac in c.BCC(a,ac)}; set(0xB0,"BCS",.rel,2){c,a,ac in c.BCS(a,ac)}
        set(0xF0,"BEQ",.rel,2){c,a,ac in c.BEQ(a,ac)}; set(0xD0,"BNE",.rel,2){c,a,ac in c.BNE(a,ac)}
        set(0x30,"BMI",.rel,2){c,a,ac in c.BMI(a,ac)}; set(0x10,"BPL",.rel,2){c,a,ac in c.BPL(a,ac)}
        set(0x50,"BVC",.rel,2){c,a,ac in c.BVC(a,ac)}; set(0x70,"BVS",.rel,2){c,a,ac in c.BVS(a,ac)}
        // Flags
        set(0x18,"CLC",.imp,2){c,a,ac in c.CLC(a,ac)}; set(0x38,"SEC",.imp,2){c,a,ac in c.SEC(a,ac)}
        set(0x58,"CLI",.imp,2){c,a,ac in c.CLI(a,ac)}; set(0x78,"SEI",.imp,2){c,a,ac in c.SEI(a,ac)}
        set(0xD8,"CLD",.imp,2){c,a,ac in c.CLD(a,ac)}; set(0xF8,"SED",.imp,2){c,a,ac in c.SED(a,ac)}
        set(0xB8,"CLV",.imp,2){c,a,ac in c.CLV(a,ac)}
        // Jumps
        set(0x4C,"JMP",.abs,3){c,a,ac in c.JMP(a,ac)}; set(0x6C,"JMP",.ind,5){c,a,ac in c.JMP(a,ac)}
        set(0x20,"JSR",.abs,6){c,a,ac in c.JSR(a,ac)}; set(0x60,"RTS",.imp,6){c,a,ac in c.RTS(a,ac)}
        set(0x40,"RTI",.imp,6){c,a,ac in c.RTI(a,ac)}; set(0x00,"BRK",.imp,7){c,a,ac in c.BRK(a,ac)}
        set(0xEA,"NOP",.imp,2){c,a,ac in c.NOP(a,ac)}
        // Undocumented/illegal opcodes actually used by real cartridges
        set(0xA7,"LAX",.zp,3){c,a,ac in c.LAX(a,ac)}; set(0xB7,"LAX",.zpy,4){c,a,ac in c.LAX(a,ac)}
        set(0xAF,"LAX",.abs,4){c,a,ac in c.LAX(a,ac)}; set(0xBF,"LAX",.absy,4,true){c,a,ac in c.LAX(a,ac)}
        set(0xA3,"LAX",.indx,6){c,a,ac in c.LAX(a,ac)}; set(0xB3,"LAX",.indy,5,true){c,a,ac in c.LAX(a,ac)}
        set(0x87,"SAX",.zp,3){c,a,ac in c.SAX(a,ac)}; set(0x97,"SAX",.zpy,4){c,a,ac in c.SAX(a,ac)}
        set(0x8F,"SAX",.abs,4){c,a,ac in c.SAX(a,ac)}; set(0x83,"SAX",.indx,6){c,a,ac in c.SAX(a,ac)}
        set(0xC7,"DCP",.zp,5){c,a,ac in c.DCP(a,ac)}; set(0xD7,"DCP",.zpx,6){c,a,ac in c.DCP(a,ac)}
        set(0xCF,"DCP",.abs,6){c,a,ac in c.DCP(a,ac)}; set(0xDF,"DCP",.absx,7){c,a,ac in c.DCP(a,ac)}
        set(0xDB,"DCP",.absy,7){c,a,ac in c.DCP(a,ac)}; set(0xC3,"DCP",.indx,8){c,a,ac in c.DCP(a,ac)}
        set(0xD3,"DCP",.indy,8){c,a,ac in c.DCP(a,ac)}
        set(0xE7,"ISC",.zp,5){c,a,ac in c.ISC(a,ac)}; set(0xF7,"ISC",.zpx,6){c,a,ac in c.ISC(a,ac)}
        set(0xEF,"ISC",.abs,6){c,a,ac in c.ISC(a,ac)}; set(0xFF,"ISC",.absx,7){c,a,ac in c.ISC(a,ac)}
        set(0xFB,"ISC",.absy,7){c,a,ac in c.ISC(a,ac)}; set(0xE3,"ISC",.indx,8){c,a,ac in c.ISC(a,ac)}
        set(0xF3,"ISC",.indy,8){c,a,ac in c.ISC(a,ac)}
        set(0x07,"SLO",.zp,5){c,a,ac in c.SLO(a,ac)}; set(0x17,"SLO",.zpx,6){c,a,ac in c.SLO(a,ac)}
        set(0x0F,"SLO",.abs,6){c,a,ac in c.SLO(a,ac)}; set(0x1F,"SLO",.absx,7){c,a,ac in c.SLO(a,ac)}
        set(0x1B,"SLO",.absy,7){c,a,ac in c.SLO(a,ac)}; set(0x03,"SLO",.indx,8){c,a,ac in c.SLO(a,ac)}
        set(0x13,"SLO",.indy,8){c,a,ac in c.SLO(a,ac)}
        set(0x27,"RLA",.zp,5){c,a,ac in c.RLA(a,ac)}; set(0x37,"RLA",.zpx,6){c,a,ac in c.RLA(a,ac)}
        set(0x2F,"RLA",.abs,6){c,a,ac in c.RLA(a,ac)}; set(0x3F,"RLA",.absx,7){c,a,ac in c.RLA(a,ac)}
        set(0x3B,"RLA",.absy,7){c,a,ac in c.RLA(a,ac)}; set(0x23,"RLA",.indx,8){c,a,ac in c.RLA(a,ac)}
        set(0x33,"RLA",.indy,8){c,a,ac in c.RLA(a,ac)}
        set(0x47,"SRE",.zp,5){c,a,ac in c.SRE(a,ac)}; set(0x57,"SRE",.zpx,6){c,a,ac in c.SRE(a,ac)}
        set(0x4F,"SRE",.abs,6){c,a,ac in c.SRE(a,ac)}; set(0x5F,"SRE",.absx,7){c,a,ac in c.SRE(a,ac)}
        set(0x5B,"SRE",.absy,7){c,a,ac in c.SRE(a,ac)}; set(0x43,"SRE",.indx,8){c,a,ac in c.SRE(a,ac)}
        set(0x53,"SRE",.indy,8){c,a,ac in c.SRE(a,ac)}
        set(0x67,"RRA",.zp,5){c,a,ac in c.RRA(a,ac)}; set(0x77,"RRA",.zpx,6){c,a,ac in c.RRA(a,ac)}
        set(0x6F,"RRA",.abs,6){c,a,ac in c.RRA(a,ac)}; set(0x7F,"RRA",.absx,7){c,a,ac in c.RRA(a,ac)}
        set(0x7B,"RRA",.absy,7){c,a,ac in c.RRA(a,ac)}; set(0x63,"RRA",.indx,8){c,a,ac in c.RRA(a,ac)}
        set(0x73,"RRA",.indy,8){c,a,ac in c.RRA(a,ac)}
        set(0x0B,"ANC",.imm,2){c,a,ac in c.ANC(a,ac)}; set(0x2B,"ANC",.imm,2){c,a,ac in c.ANC(a,ac)}
        set(0x4B,"ALR",.imm,2){c,a,ac in c.ALR(a,ac)}
        set(0x6B,"ARR",.imm,2){c,a,ac in c.ARR(a,ac)}
        set(0xCB,"SBX",.imm,2){c,a,ac in c.SBX(a,ac)}
        // Common NOP variants (with harmless dummy reads)
        for op in [0x1A,0x3A,0x5A,0x7A,0xDA,0xFA] { set(op,"NOP",.imp,2){c,a,ac in c.NOP(a,ac)} }
        for op in [0x04,0x44,0x64] { set(op,"NOP",.zp,3){c,a,ac in c.NOP(a,ac)} }
        for op in [0x14,0x34,0x54,0x74,0xD4,0xF4] { set(op,"NOP",.zpx,4){c,a,ac in c.NOP(a,ac)} }
        set(0x80,"NOP",.imm,2){c,a,ac in c.NOP(a,ac)}
        set(0x0C,"NOP",.abs,4){c,a,ac in c.NOP(a,ac)}
        for op in [0x1C,0x3C,0x5C,0x7C,0xDC,0xFC] { set(op,"NOP",.absx,4,true){c,a,ac in c.NOP(a,ac)} }
        return t
    }()
}
