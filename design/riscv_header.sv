// ============================================================================
// riscv_header.sv
// ============================================================================
// Include this in ALL modules with: `include "riscv_header.sv"

`ifndef RISCV_HEADER_SV
`define RISCV_HEADER_SV

// ============================================================================
// INSTRUCTION SET ARCHITECTURE (RISC-V RV32IM)
// ============================================================================

parameter XLEN = 32;              // Scalar register width
parameter INST_WIDTH = 32;        // Instruction width

// Funct3 codes
`define FUNCT3_ADD_SUB 3'b000
`define FUNCT3_SLL     3'b001
`define FUNCT3_SLT     3'b010
`define FUNCT3_SLTU    3'b011
`define FUNCT3_XOR     3'b100
`define FUNCT3_SR      3'b101
`define FUNCT3_OR      3'b110
`define FUNCT3_AND     3'b111

// Funct7 codes
`define FUNCT7_M_EXT   7'b0000001

// ALU Operation Codes (4-bit)
`define ALU_ADD  4'b0000
`define ALU_SUB  4'b0001
`define ALU_SLL  4'b0010
`define ALU_SLT  4'b0011
`define ALU_SLTU 4'b0100
`define ALU_XOR  4'b0101
`define ALU_SRL  4'b0110
`define ALU_SRA  4'b0111
`define ALU_OR   4'b1000
`define ALU_AND  4'b1001
`define ALU_VSETVL 4'b1010
`define UNKNOWN_ALU_OP 4'b1111

// Vector Operation Codes (4-bit, shared with ALU_OP bus)
`define VEC_OP_ADD 4'b0000
`define VEC_OP_SUB 4'b0001
`define VEC_OP_MUL 4'b0010
`define VEC_OP_AND 4'b0011
`define VEC_OP_OR  4'b0100
`define VEC_OP_XOR 4'b0101
`define VEC_OP_SLL 4'b0110
`define VEC_OP_SRL 4'b0111
`define VEC_OP_SRA 4'b1011
`define UNKNOWN_VEC_OP 4'b1111

// Reservation Station Types (for routing in dispatch)
`define RS_TYPE_NONE 4'b0000
`define RS_TYPE_ALU  4'b0001
`define RS_TYPE_MEM  4'b0010
`define RS_TYPE_MUL  4'b0100
`define RS_TYPE_DIV  4'b1000
`define RS_TYPE_VEC  4'b1010

// Instruction types (for routing in dispatch)
parameter logic [3:0] `IBASE_ALU = 4'h0;       // ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU
parameter logic [3:0] `IBASE_ALU_IMM = 4'h1;  // ADDI, ANDI, ORI, XORI, SLLI, SRLI, SRAI
parameter logic [3:0] `IBASE_LOAD = 4'h2;     // LW, LH, LB, LBU, LHU
parameter logic [3:0] `IBASE_STORE = 4'h3;    // SW, SH, SB
parameter logic [3:0] `IBASE_BRANCH = 4'h4;   // BEQ, BNE, BLT, BGE, BLTU, BGEU
parameter logic [3:0] `IBASE_JAL = 4'h5;      // JAL
parameter logic [3:0] `IBASE_JALR = 4'hC;     // JALR
parameter logic [3:0] `IBASE_LUI = 4'h6;      // LUI
parameter logic [3:0] `IBASE_AUIPC = 4'hD;    // AUIPC
parameter logic [3:0] `M_EXT_MUL = 4'h7;      // MUL, MULH, MULHSU, MULHU (RV32M)
parameter logic [3:0] `M_EXT_DIV = 4'h8;      // DIV, DIVU, REM, REMU (RV32M)
parameter logic [3:0] `V_EXT_VEC = 4'h9;      // VADD, VMUL, etc (RVV)
parameter logic [3:0] `V_EXT_LOAD = 4'hA; // Vector Load
parameter logic [3:0] `V_EXT_STORE = 4'hB;// Vector Store
parameter logic [3:0] `V_EXT_CONFIG = 4'hE; // VSETVLI
parameter logic [3:0] `IBASE_UNKNOWN = 4'hF;  // Unknown instruction

// Exception codes
parameter EXCEPTION_CODE_WIDTH = 4;
parameter logic [EXCEPTION_CODE_WIDTH-1:0] `EXC_EXTERNAL_INT = 4'h0;
parameter logic [EXCEPTION_CODE_WIDTH-1:0] `EXC_ILLEGAL_INSTR = 4'h2;
parameter logic [EXCEPTION_CODE_WIDTH-1:0] `EXC_INSTR_MISALIGN = 4'h0;
parameter logic [EXCEPTION_CODE_WIDTH-1:0] `EXC_LOAD_MISALIGN = 4'h4;
parameter logic [EXCEPTION_CODE_WIDTH-1:0] `EXC_STORE_MISALIGN = 4'h6;

// ============================================================================
// REGISTER FILES
// ============================================================================

// Scalar registers
parameter NUM_INT_REGS = 32;           // x0-x31 (architectural)

// Vector registers
parameter NUM_VEC_REGS = 32;           // v0-v31 (architectural)

// ============================================================================
// PHYSICAL REGISTERS (RAT+PHYSICAL SPECIFIC)
// ============================================================================

parameter NUM_PHYS_REGS = 64;          // 64 physical registers total
                                        // 32 for arch (x0-x31)
                                        // 32 extra for speculation

parameter PHYS_REG_TAG_WIDTH = 6;      // 6 bits to address 64 phys regs (0-63)

// ============================================================================
// PIPELINE STRUCTURE
// ============================================================================

// Reservation stations
parameter ALU_RS_SIZE = 8;             // ALU reservation station entries
parameter MEM_RS_SIZE = 8;             // Load/Store RS entries
parameter MUL_RS_SIZE = 4;             // Multiplier RS entries
parameter DIV_RS_SIZE = 4;             // Divider RS entries
parameter VEC_RS_SIZE = 8;             // Vector RS entries

// Reorder Buffer
parameter ROB_SIZE = 16;               // Instruction window size

// Load-Store Queue
parameter LSQ_SIZE = 16;               // Unified Load/Store queue depth
parameter LSQ_TAG_WIDTH = 4;           // log2(16)

// ============================================================================
// FUNCTIONAL UNIT LATENCIES (PIPELINED)
// ============================================================================

parameter MUL_LATENCY = 4;             // Multiplier: 4-cycle pipeline
parameter DIV_LATENCY = 6;             // Divider: 6-cycle pipeline

// ============================================================================
// VECTOR EXTENSION (RVV)
// ============================================================================

parameter VLEN = 128;                  // Vector register width (bits)
parameter MAX_LMUL = 1;                // Maximum LMUL supported
parameter MAX_VLMAX = VLEN * MAX_LMUL/8;  // Absolute physical max elements (effective VLEN / MIN_SEW)
parameter ELEN = 32;                   // Element width (bits)
parameter NUM_VEC_LANES = 4;           // Number of parallel lanes
parameter DLEN = ELEN * NUM_VEC_LANES; // Data path width for vector operations (bits)

// ----------------------------------------------------------------------------
// RVV MINIMAL SUBSET TARGET (Zve32x - Stripped Down)
// ----------------------------------------------------------------------------
// - Config: vsetvli (Sets VL, assumes ELEN=32, LMUL=1, vstart=0)
// - Memory: vle32.v (Vector Load), vse32.v (Vector Store)
// - Arith (OPVV): vadd.vv, vsub.vv, vmul.vv, vand.vv, vor.vv, vxor.vv
// - Arith (OPVI): vadd.vi, vand.vi, vor.vi, vxor.vi
// - Shifts (OPVI): vsll.vi, vsrl.vi, vsra.vi
// - Excluded: Floating-point, mask operations, widening/narrowing, reductions
// - Dependencies: OPVX requires cross-domain scalar snooping (Future feature)
// ----------------------------------------------------------------------------

// ============================================================================
// CDB (COMMON DATA BUS)
// ============================================================================

parameter CDB_TAG_WIDTH = 6;           // Matches PHYS_REG_TAG_WIDTH in RAT+PHYSICAL
parameter NUM_CDBS = 2;                // Dual CDB Architecture (Scheduled + Unscheduled)
                                        // CDB broadcasts PHYSICAL register tags

// ============================================================================
// FORWARDING & OPERAND DELIVERY
// ============================================================================

// In RAT+PHYSICAL:
// - Operands identified by PHYSICAL register tags (6 bits)
// - CDB carries physical reg tags
// - Forwarding logic matches phys reg tags
// - Results stored in physical_register_file (not ROB)

// ============================================================================
// DEBUG / SIMULATION
// ============================================================================

parameter SIMULATION = 1;              // Set 0 for synthesis
parameter DEBUG_LEVEL = 1;             // Debug verbosity (0-3)

`endif // RISCV_HEADER_SV
