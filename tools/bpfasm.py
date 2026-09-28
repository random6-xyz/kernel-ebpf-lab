#!/usr/bin/env python3
"""Tiny eBPF assembler for lab reproducers.

Usage: bpfasm.py input.asm -o output.bin [--entry NAME]

Assembly syntax (one instruction per line, ';' or '#' starts a comment, labels
are `name:` on their own line or prefixing an instruction):

    r0 = 42
    r0 = -1
    r1 = r2
    r1 = 0x1000
    r1 += r2 / r1 -= 8 / r1 *= r2 / r1 &= 0xff / r1 |= r2 / r1 ^= 8
    r1 <<= 3 / r1 >>= 3 / r1 s>>= 3 / r1 /= r2 / r1 %= r2
    r1 = -r2
    w1 = w2 / w1 += 1 / w1 = 0xffffffff        (32-bit ALU)
    *(u64 *)(r10 - 8) = r5
    *(u32 *)(r10 - 4) = r5
    *(u16 *)(r1 + 2) = r2
    *(u8 *)(r1 + 1) = r2
    r5 = *(u64 *)(r10 - 8)
    r5 = *(u32 *)(r1 + 0)
    r5 = *(s32 *)(r1 + 0)        (sign-extending load)
    r5 = *(s8 *)(r1 + 0)
    r1 = lddw(0xdeadbeefcafebabe)
    r1 = map_fd(3)               (BPF_PSEUDO_MAP_FD, 64-bit)
    r1 = map_value(3)            (BPF_PSEUDO_MAP_VALUE, 64-bit)
    r1 = addr_space_cast(r1, 0, 1)   (BPF_ADDR_SPACE_CAST)
    lock *(u64 *)(r1 + 0) += r2      (atomic RMW; also |= &= ^=, '= xchg', cmpxchg)
    call 8
    call pc+1                    (helper/kfunc by imm)
    call $sub                   (BPF_PSEUDO_CALL to label 'sub')
    goto label
    if r1 == r2 goto label
    if r1 == 42 goto label
    if r1 > r2 goto label
    if r1 s> r2 goto label   (also s>=, s<, s<=)
    if w1 == w2 goto label   (32-bit JMP32)
    exit
    *(u64 *)(r10 - 8) = 0x1234   (ST with immediate, BPF_ST)
    r0 = 0x7fffffff             (any imm; use lddw for >32-bit)
    ld_abs_u32 r0, [r1 + 4] / ld_ind_u32 r0, [r1 + 4]   (legacy packet access; rare)
    nop                          (jump 0)

Label operands resolve to relative offsets. `--entry` is accepted for
compatibility but unused (raw program starts at instruction 0).
"""
import argparse
import re
import struct
import sys

# classes
LD, LDX, ST, STX, ALU, JMP, JMP32, ALU64 = 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07
# sizes
W, H, B, DW = 0x00, 0x08, 0x10, 0x18
MEM, MEMSX, IMM = 0x60, 0x80, 0x00
# alu ops
ADD, SUB, MUL, DIV, OR, AND, LSH, RSH, NEG, MOD, XOR, MOV, ARSH, END = (
    0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90, 0xA0, 0xB0, 0xC0, 0xD0)
# jmp ops
JA, JEQ, JGT, JGE, JSET, JNE, JSGT, JSGE, CALL, EXIT, JLT, JLE, JSLT, JSLE = (
    0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90, 0xA0, 0xB0, 0xC0, 0xD0)

PSEUDO_CALL = 1
PSEUDO_MAP_FD = 1
PSEUDO_MAP_VALUE = 2

BPF_X = 0x08  # source operand is a register
ATOMIC = 0xc0  # BPF_ATOMIC mode for BPF_STX

ALU_OPS = {
    '+=': ADD, 'add': ADD, '-=': SUB, 'sub': SUB, '*=': MUL, 'mul': MUL,
    '/=': DIV, 'div': DIV, '|=': OR, 'or': OR, '&=': AND, 'and': AND,
    '<<=': LSH, 'lsh': LSH, '>>=': RSH, 'rsh': RSH, 's>>=': ARSH, 'arsh': ARSH,
    '%=': MOD, 'mod': MOD, '^=': XOR, 'xor': XOR, '=': MOV, 'mov': MOV,
}
JMP_OPS = {
    '==': JEQ, '!=': JNE, '>': JGT, '>=': JGE, '<': JLT, '<=': JLE,
    's>': JSGT, 's>=': JSGE, 's<': JSLT, 's<=': JSLE, '&': JSET,
}
SIZES = {'u64': DW, 'u32': W, 'u16': H, 'u8': B, 's64': DW, 's32': W, 's16': H, 's8': B}
BPF_ADDR_SPACE_CAST = 1


class AsmError(Exception):
    pass


def parse_reg(tok):
    m = re.fullmatch(r'([rw])(\d+)', tok.strip())
    if not m:
        raise AsmError(f'bad register: {tok}')
    n = int(m.group(2))
    if not 0 <= n <= 10:
        raise AsmError(f'bad register number: {tok}')
    return m.group(1), n


def parse_imm(tok):
    tok = tok.strip()
    neg = tok.startswith('-')
    if neg:
        tok = tok[1:]
    val = int(tok, 0)
    if neg:
        val = -val
    if not -0x80000000 <= val <= 0xFFFFFFFF:
        raise AsmError(f'immediate out of 32-bit range: {tok}')
    return val


class Insn:
    __slots__ = ('code', 'dst', 'src', 'off', 'imm', 'line', 'wide')

    def __init__(self, code, dst, src, off, imm, line, wide=False):
        self.code, self.dst, self.src, self.off, self.imm = code, dst, src, off, imm
        self.line, self.wide = line, wide

    def __repr__(self):
        return f'<{self.code:#04x} d{self.dst} s{self.src} off{self.off} imm{self.imm}>'


class Assembler:
    def __init__(self):
        self.insns = []
        self.labels = {}
        self.fixups = []  # (index, kind, target, extra)

    def emit(self, insn):
        self.insns.append(insn)
        return len(self.insns) - 1

    def resolve_labels(self):
        for idx, kind, target, extra in self.fixups:
            if target not in self.labels:
                raise AsmError(f'undefined label: {target}')
            insn = self.insns[idx] if kind != 'call_label' else self.insns[idx]
            tgt = self.labels[target]
            if kind == 'jmp':
                insn.off = tgt - idx - 1
                insn.imm = 0
            elif kind == 'call_label':
                insn.imm = tgt - idx - 1
            elif kind == 'subprog_off':
                # 64-bit offset stored in two instructions (ldimm64 low/high)
                delta = tgt - idx - 1
                self.insns[idx].imm = delta & 0xFFFFFFFF
                self.insns[idx + 1].imm = (delta >> 32) & 0xFFFFFFFF
            else:
                raise AsmError(f'unknown fixup {kind}')


def asm_line(line, asm: Assembler, lineno):
    s = line.split(';')[0].split('#')[0].strip()
    if not s:
        return
    # label
    while True:
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$', s)
        if not m:
            break
        name, rest = m.group(1), m.group(2)
        if name in asm.labels:
            raise AsmError(f'duplicate label {name}')
        asm.labels[name] = len(asm.insns)
        s = rest.strip()
        if not s:
            return
    s = s.rstrip(',')

    # nop
    if s == 'nop':
        asm.emit(Insn(JMP | JA, 0, 0, 0, 0, lineno))
        return
    # exit
    if s == 'exit':
        asm.emit(Insn(JMP | EXIT, 0, 0, 0, 0, lineno))
        return

    # goto label
    m = re.fullmatch(r'goto\s+([A-Za-z_][A-Za-z0-9_]*)', s)
    if m:
        idx = asm.emit(Insn(JMP | JA, 0, 0, 0, 0, lineno))
        asm.fixups.append((idx, 'jmp', m.group(1), None))
        return

    # kfunc call: call kfunc(<btf id>)
    m = re.fullmatch(r'call\s+kfunc\((-?(?:0x[0-9a-fA-F]+|\d+))\)', s)
    if m:
        asm.emit(Insn(JMP | CALL, 0, 2, 0, int(m.group(1), 0), lineno))
        return

    # call
    m = re.fullmatch(r'call\s+\$?([A-Za-z_][A-Za-z0-9_]*|\d+|pc\s*[+-]\s*\d+)', s)
    if m:
        arg = m.group(1).strip()
        if arg.startswith('pc'):
            delta = parse_imm(arg[2:].strip())
            asm.emit(Insn(JMP | CALL, 0, 0, 0, delta, lineno))
        elif re.fullmatch(r'\d+', arg):
            asm.emit(Insn(JMP | CALL, 0, 0, 0, int(arg), lineno))
        else:
            idx = asm.emit(Insn(JMP | CALL, 0, PSEUDO_CALL, 0, 0, lineno))
            asm.fixups.append((idx, 'call_label', arg, None))
        return

    # conditional jump: if <a> <op> <b> goto label
    m = re.fullmatch(r'if\s+([rw]\d+)\s*(s>|s>=|s<|s<=|==|!=|>=|<=|>|<|&)\s*'
                     r'([rw]\d+|-?(?:0x[0-9a-fA-F]+|\d+))\s+goto\s+([A-Za-z_][A-Za-z0-9_]*)', s)
    if m:
        lhs, op, rhs, label = m.group(1), m.group(2), m.group(3), m.group(4)
        lcls, lnum = parse_reg(lhs)
        cls = JMP32 if lcls == 'w' else JMP
        opc = JMP_OPS[op]
        if op == '&' and re.fullmatch(r'-?[0-9x]+', rhs):
            pass
        if re.fullmatch(r'[rw]\d+', rhs):
            rcls, rnum = parse_reg(rhs)
            if rcls != lcls:
                raise AsmError(f'mixed register widths in comparison: {s}')
            idx = asm.emit(Insn(cls | opc | BPF_X, lnum, rnum, 0, 0, lineno))
        else:
            idx = asm.emit(Insn(cls | opc | 0x00, lnum, 0, 0, parse_imm(rhs), lineno))
        asm.fixups.append((idx, 'jmp', label, None))
        return

    # lddw / map
    m = re.fullmatch(r'(r\d+)\s*=\s*lddw\((0x[0-9a-fA-F]+|-?\d+)\)', s)
    if m:
        dst = parse_reg(m.group(1))[1]
        val = int(m.group(2), 0)
        if val < 0:
            val &= 0xFFFFFFFFFFFFFFFF
        asm.emit(Insn(LD | IMM | DW, dst, 0, 0, val & 0xFFFFFFFF, lineno, wide=True))
        asm.emit(Insn(0, 0, 0, 0, (val >> 32) & 0xFFFFFFFF, lineno, wide=True))
        return
    m = re.fullmatch(r'(r\d+)\s*=\s*(map_fd|map_value)\((\d+)\)', s)
    if m:
        dst = parse_reg(m.group(1))[1]
        kind = m.group(2)
        fd = int(m.group(3))
        src = PSEUDO_MAP_FD if kind == 'map_fd' else PSEUDO_MAP_VALUE
        asm.emit(Insn(LD | IMM | DW, dst, src, 0, fd, lineno, wide=True))
        asm.emit(Insn(0, 0, 0, 0, 0, lineno, wide=True))
        return

    # memory store: *(size *)(reg +- off) = reg|imm
    m = re.fullmatch(r'\*\((u\d+)\s*\*\)\(([rw]\d+)\s*([+-])\s*(\d+)\)\s*=\s*'
                     r'([rw]\d+|-?(?:0x[0-9a-fA-F]+|\d+))', s)
    if m:
        size, base, sign, offs, val = m.group(1), m.group(2), m.group(3), m.group(4), m.group(5)
        size_code = SIZES[size]
        _bcls, bnum = parse_reg(base)
        off = int(offs) * (-1 if sign == '-' else 1)
        if re.fullmatch(r'[rw]\d+', val):
            vcls, vnum = parse_reg(val)
            asm.emit(Insn(STX | MEM | size_code, bnum, vnum, off, 0, lineno))
        else:
            if size_code == DW:
                raise AsmError(f'ST immediate with u64 not allowed (verifier rejects): {s}')
            asm.emit(Insn(ST | MEM | size_code, bnum, 0, off, parse_imm(val), lineno))
        return

    # memory load: reg = *(size *)(reg +- off)
    m = re.fullmatch(r'([rw]\d+)\s*=\s*\*\(([us]\d+)\s*\*\)\(([rw]\d+)\s*([+-])\s*(\d+)\)', s)
    if m:
        dst, size, base, sign, offs = m.groups()
        dcls, dnum = parse_reg(dst)
        size_code = SIZES[size]
        cls = MEMSX if size.startswith('s') else MEM
        _bcls, bnum = parse_reg(base)
        off = int(offs) * (-1 if sign == '-' else 1)
        asm.emit(Insn(LDX | cls | size_code, dnum, bnum, off, 0, lineno))
        return

    # addr_space_cast: rD = addr_space_cast(rS, dst_as, src_as)
    m = re.fullmatch(r'([rw]\d+)\s*=\s*addr_space_cast\(([rw]\d+)\s*,\s*(\d+)\s*,\s*(\d+)\)', s)
    if m:
        dst, src, dst_as, src_as = m.groups()
        _dcls, dnum = parse_reg(dst)
        _scls, snum = parse_reg(src)
        if dst_as == '0' and src_as == '1':
            imm = 1
        elif dst_as == '1' and src_as == '0':
            imm = 1 << 16
        else:
            raise AsmError(f'unsupported addr_space_cast: {s}')
        asm.emit(Insn(ALU64 | MOV | BPF_X, dnum, snum, 1, imm, lineno))
        return

    # atomic RMW: lock *(u64 *)(rD + off) op= rS   (op: += |= &= ^=, xchg, cmpxchg)
    m = re.fullmatch(r'lock\s*\*\((u\d+)\s*\*\)\(([rw]\d+)\s*([+-])\s*(\d+)\)\s*'
                     r'(\+=|\|=|&=|\^=|=\s*xchg|cmpxchg)\s*([rw]\d+)', s)
    if m:
        size, base, sign, offs, op, val = m.groups()
        size_code = SIZES[size]
        _bcls, bnum = parse_reg(base)
        _vcls, vnum = parse_reg(val)
        off = int(offs) * (-1 if sign == '-' else 1)
        opmap = {'+=': 0x00, '|=': 0x40, '&=': 0x50, '^=': 0xa0}
        if op in opmap:
            imm = opmap[op]
        elif op.strip().startswith('='):
            imm = 0xe1           # BPF_XCHG  = 0xe0 | BPF_FETCH (bpf.h:51)
        else:
            imm = 0xf1            # BPF_CMPXCHG = 0xf0 | BPF_FETCH (bpf.h:52)
        asm.emit(Insn(STX | ATOMIC | size_code, bnum, vnum, off, imm, lineno))
        return

    # atomic load-acquire: rD = load_acquire(u16 *)(rS + off)
    m = re.fullmatch(r'([rw]\d+)\s*=\s*load_acquire\((u\d+)\s*\*\)\(([rw]\d+)\s*([+-])\s*(\d+)\)', s)
    if m:
        dst, size, base, sign, offs = m.groups()
        size_code = SIZES[size]
        _dcls, dnum = parse_reg(dst)
        _bcls, bnum = parse_reg(base)
        off = int(offs) * (-1 if sign == '-' else 1)
        asm.emit(Insn(STX | ATOMIC | size_code, dnum, bnum, off, 0x100, lineno))
        return

    # atomic store-release: store_release(u16 *)(rD + off) = rS
    m = re.fullmatch(r'store_release\((u\d+)\s*\*\)\(([rw]\d+)\s*([+-])\s*(\d+)\)\s*=\s*([rw]\d+)', s)
    if m:
        size, base, sign, offs, val = m.groups()
        size_code = SIZES[size]
        _bcls, bnum = parse_reg(base)
        _vcls, vnum = parse_reg(val)
        off = int(offs) * (-1 if sign == '-' else 1)
        asm.emit(Insn(STX | ATOMIC | size_code, bnum, vnum, off, 0x110, lineno))
        return

    # reg alu: r1 op= r2 | r1 op= imm (also w regs)
    m = re.fullmatch(r'([rw]\d+)\s*(<<=|>>=|s>>=|s>=|s<=|\+=|-=|\*=|/=|%=|&=|\|=|\^=)\s*'
                     r'([rw]\d+|-?(?:0x[0-9a-fA-F]+|\d+))', s)
    if m:
        dst, op, rhs = m.groups()
        dcls, dnum = parse_reg(dst)
        alu_cls = ALU if dcls == 'w' else ALU64
        opc = ALU_OPS[op]
        if re.fullmatch(r'[rw]\d+', rhs):
            rcls, rnum = parse_reg(rhs)
            if rcls != dcls:
                raise AsmError(f'mixed register widths: {s}')
            asm.emit(Insn(alu_cls | opc | BPF_X, dnum, rnum, 0, 0, lineno))
        else:
            asm.emit(Insn(alu_cls | opc | IMM, dnum, 0, 0, parse_imm(rhs), lineno))
        return

    # reg = -reg
    m = re.fullmatch(r'([rw]\d+)\s*=\s*-\s*([rw]\d+)', s)
    if m:
        dst, src = m.groups()
        dcls, dnum = parse_reg(dst)
        _rcls, rnum = parse_reg(src)
        asm.emit(Insn((ALU if dcls == 'w' else ALU64) | NEG, dnum, 0, 0, 0, lineno))
        return

    # reg = reg | reg = imm
    m = re.fullmatch(r'([rw]\d+)\s*=\s*([rw]\d+|-?(?:0x[0-9a-fA-F]+|\d+))', s)
    if m:
        dst, rhs = m.groups()
        dcls, dnum = parse_reg(dst)
        alu_cls = ALU if dcls == 'w' else ALU64
        if re.fullmatch(r'[rw]\d+', rhs):
            rcls, rnum = parse_reg(rhs)
            if rcls != dcls:
                raise AsmError(f'mixed register widths: {s}')
            asm.emit(Insn(alu_cls | MOV | BPF_X, dnum, rnum, 0, 0, lineno))
        else:
            asm.emit(Insn(alu_cls | MOV | IMM, dnum, 0, 0, parse_imm(rhs), lineno))
        return

    raise AsmError(f'cannot parse: {line.rstrip()}')


def assemble(text):
    asm = Assembler()
    for n, line in enumerate(text.splitlines(), 1):
        try:
            asm_line(line, asm, n)
        except AsmError as e:
            raise AsmError(f'line {n}: {e}') from None
    asm.resolve_labels()
    out = bytearray()
    for insn in asm.insns:
        out += struct.pack('<BBhI', insn.code, (insn.src << 4) | (insn.dst & 0xF),
                           insn.off, insn.imm & 0xFFFFFFFF)
    return bytes(out), asm


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('input')
    ap.add_argument('-o', '--output', default=None)
    ap.add_argument('--entry', default=None)
    ap.add_argument('--listing', action='store_true')
    args = ap.parse_args()

    text = open(args.input, encoding='utf-8').read()
    try:
        blob, asm = assemble(text)
    except AsmError as e:
        print(f'error: {e}', file=sys.stderr)
        return 1
    out_path = args.output or (args.input.rsplit('.', 1)[0] + '.bin')
    with open(out_path, 'wb') as f:
        f.write(blob)
    if args.listing:
        for i, insn in enumerate(asm.insns):
            print(f'{i:4d}: {insn}')
        print('labels:', asm.labels)
    print(f'{out_path}: {len(blob)} bytes, {len(asm.insns)} insns')
    return 0


if __name__ == '__main__':
    sys.exit(main())
