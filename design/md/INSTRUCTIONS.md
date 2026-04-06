# INSTRUCTIONS.md - RISC-V Instruction Encoding Reference

## RV32I Base Integer Instructions

### R-Type: Register-Register Operations
```
Format: func7 [6:0] | rs2 [4:0] | rs1 [4:0] | func3 [2:0] | rd [4:0] | opcode [6:0]

ADD:  func7=0000000, func3=000
SUB:  func7=0100000, func3=000
AND:  func7=0000000, func3=111
OR:   func7=0000000, func3=110
XOR:  func7=0000000, func3=100
SLL:  func7=0000000, func3=001
SRL:  func7=0000000, func3=101
SRA:  func7=0100000, func3=101
SLT:  func7=0000000, func3=010
SLTU: func7=0000000, func3=011
```

### I-Type: Immediate & Load Instructions
```
Format: imm[11:0] | rs1 [4:0] | func3 [2:0] | rd [4:0] | opcode [6:0]

ADDI:  func3=000
ANDI:  func3=111
ORI:   func3=110
XORI:  func3=100
SLLI:  func3=001
SRLI:  func3=101
SRAI:  func3=101

LB:    func3=000
LH:    func3=001
LW:    func3=010
LBU:   func3=100
LHU:   func3=101
```

### S-Type: Store Instructions
```
Format: imm[11:5] | rs2 [4:0] | rs1 [4:0] | func3 [2:0] | imm[4:0] | opcode [6:0]

SB:    func3=000
SH:    func3=001
SW:    func3=010
```

### B-Type: Branch Instructions
```
Format: imm[12|10:5] | rs2 [4:0] | rs1 [4:0] | func3 [2:0] | imm[4:1|11] | opcode [6:0]

BEQ:   func3=000
BNE:   func3=001
BLT:   func3=100
BGE:   func3=101
BLTU:  func3=110
BGEU:  func3=111
```

### U-Type: Upper Immediate
```
Format: imm[31:12] | rd [4:0] | opcode [6:0]

LUI:   opcode=0110111
AUIPC: opcode=0010111
```

### J-Type: Jump
```
Format: imm[20|10:1|11|19:12] | rd [4:0] | opcode [6:0]

JAL:   opcode=1101111
JALR:  (I-type) opcode=1100111
```

---

## RV32M - Multiply/Divide Extension

### M-Type: Multiply/Divide
```
Format: func7 [6:0] | rs2 [4:0] | rs1 [4:0] | func3 [2:0] | rd [4:0] | opcode [6:0]

All M-extension instructions: opcode=0110011, func7=0000001

MUL:    func3=000  (result = (rs1 × rs2)[31:0])
MULH:   func3=001  (result = (rs1 × rs2)[63:32] signed)
MULHSU: func3=010  (result = (rs1 × rs2)[63:32] signed×unsigned)
MULHU:  func3=011  (result = (rs1 × rs2)[63:32] unsigned)
DIV:    func3=100  (result = rs1 ÷ rs2 signed)
DIVU:   func3=101  (result = rs1 ÷ rs2 unsigned)
REM:    func3=110  (result = rs1 % rs2 signed remainder)
REMU:   func3=111  (result = rs1 % rs2 unsigned remainder)
```

---

## RVV - Vector Extension Subset

### Configuration Overview
- **Vector Registers**: v0-v31 (32 registers)
- **VLEN**: 128 bits (vector register width)
- **VLMAX**: 16 elements (for 8-bit elements; scales with element width)
- **ELEN**: 32 bits (maximum element width)
- **Lanes**: 4 parallel 32-bit execution lanes

```
Each vector register (128 bits):
┌────────────────────────────────────────────────────────────┐
│ Element 3  │ Element 2  │ Element 1  │ Element 0          │
│ [127:96]   │ [95:64]    │ [63:32]    │ [31:0]            │
└────────────────────────────────────────────────────────────┘
4 lanes × 32-bit = 128 bits total
```

### Vector Configuration
```
VSETVLI rd, rs1, vtypei
Format: vtypei[10:0] | rs1[4:0] | 111 | rd[4:0] | 1010111
- Sets vector length and type
- Returns new VL to rd
```

### Vector Arithmetic (V-Type)
```
Format: vm | vs2[4:0] | vs1[4:0] | func3[2:0] | vd[4:0] | opcode[6:0]
opcode = 1010111

VADD.VV:  func3=000
VSUB.VV:  func3=010
VMUL.VV:  func3=100
VDIV.VV:  func3=110
VAND.VV:  func3=1000 (logical AND)
VOR.VV:   func3=1000 (logical OR)
VXOR.VV:  func3=1000 (logical XOR)
VSLL.VV:  func3=1001 (shift left)
VSRL.VV:  func3=1010 (shift right logical)
VSRA.VV:  func3=1011 (shift right arithmetic)
```

### Vector Load/Store
```
VLE32.V vd, (rs1)      ; Load 32-bit elements
VSE32.V vs3, (rs1)     ; Store 32-bit elements
```

---

## Instruction Encoding Examples

### Example 1: ADD x2, x3, x4
```
Binary: 0000000 00100 00011 000 00010 0110011
Hex:    0x0062
Fields: func7=0000000, rs2=4, rs1=3, func3=000, rd=2, opcode=0110011
```

### Example 2: MUL x2, x3, x4
```
Binary: 0000001 00100 00011 000 00010 0110011
Hex:    0x0242
Fields: func7=0000001, rs2=4, rs1=3, func3=000, rd=2, opcode=0110011
```

### Example 3: ADDI x2, x3, 10
```
Binary: 000000001010 00011 000 00010 0010011
Hex:    0x00A18113
Fields: imm=000000001010, rs1=3, func3=000, rd=2, opcode=0010011
```

---

## Supported Instructions Summary

### ALU Operations (12)
ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU + immediate variants

### Memory (6)
LB, LH, LW, LBU, LHU + SB, SH, SW

### Control (4)
BEQ, BNE, BLT, BGE, BLTU, BGEU + JAL, JALR

### Multiply/Divide (8)
MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU

### Vector (15+)
VSETVLI, VADD, VSUB, VMUL, VDIV, VAND, VOR, VXOR, shifts, load/store

**Total: ~50 instructions supported**
