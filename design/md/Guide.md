# RAT+PHYSICAL PROCESSOR - COMPLETE LEARNING GUIDE

## START HERE

This is your **ONE comprehensive guide** for the RAT+PHYSICAL RISC-V RV32 out-of-order processor.

It covers:
- Architecture overview
- Project structure & hierarchy
- All 28 modules (specifications + I/O)
- Data flow & signal routing
- RAT+PHYSICAL key concepts
- Implementation phases
- Testbench design

**Read this first. Then investigate the code.**

---

## PART 1: ARCHITECTURE OVERVIEW

### What is This Project?

A **RISC-V RV32 out-of-order processor** using **RAT+PHYSICAL renaming** with **Tomasulo algorithm**.

**Key features:**
- Single-issue, 6-stage pipeline
- Out-of-order execution via Tomasulo
- 28 modules total
- Supports RV32IM (multiply/divide)
- Vector extension (RVV) ready

### Why RAT+PHYSICAL?

**RAT = Register Alias Table** maps architectural registers to physical registers

**PHYSICAL = Dedicated register file for speculative data**

**Benefit:** Clean separation of concerns
- Arch regs: Final committed state
- Physical regs: Speculative data during execution
- ROB: Ordering only (not data storage)
- Scales well to superscalar

---

## PART 2: DATA FLOW (RAT+PHYSICAL)

```
┌─────────────────────────────────────────────────────────────┐
│ DISPATCH STAGE                                              │
├─────────────────────────────────────────────────────────────┤
│ 1. Read arch registers (x2, x3 from arch regfile)          │
│ 2. RAT lookup: x2 → p5, x3 → p6 (physical regs)            │
│ 3. Allocate new physical reg: x1 → p7                       │
│ 4. Create RS entry with phys reg tags                       │
│    RS: [src1_tag=p5, src2_tag=p6, op=ADD, dst_tag=p7]      │
└─────────────────────┬───────────────────────────────────────┘
                      ↓
┌─────────────────────────────────────────────────────────────┐
│ RESERVATION STATION WAITING                                 │
├─────────────────────────────────────────────────────────────┤
│ RS monitors CDB for matching tags (p5, p6)                  │
│ When both operands ready: issue to execute                  │
└─────────────────────┬───────────────────────────────────────┘
                      ↓
┌─────────────────────────────────────────────────────────────┐
│ EXECUTE STAGE (FU)                                          │
├─────────────────────────────────────────────────────────────┤
│ Read operands → ALU compute → result                        │
│ Send to CDB: (tag=p7, result=value)                         │
└─────────────────────┬───────────────────────────────────────┘
                      ↓
┌─────────────────────────────────────────────────────────────┐
│ CDB BROADCAST (to multiple destinations)                    │
├─────────────────────────────────────────────────────────────┤
│ (tag=p7, result=value) goes to:                             │
│  ├─ Physical register file → phys_regs[p7] = value          │
│  ├─ RS waiting for p7 → capture value                       │
│  └─ ROB tracking entry → mark ready=YES                     │
└─────────────────────┬───────────────────────────────────────┘
                      ↓
┌─────────────────────────────────────────────────────────────┐
│ COMMIT STAGE (In-order from ROB)                            │
├─────────────────────────────────────────────────────────────┤
│ if (ROB_head ready) {                                        │
│   arch_x1 ← phys_regs[p7]   // Get from physical regs      │
│   RAT[1] ← p7               // Update RAT                   │
│   free_list.free(p_old)     // Free old writer              │
│ }                                                            │
└─────────────────────────────────────────────────────────────┘
```

**Key insight:** Results stored in **physical_register_file**, NOT in ROB!

---

## PART 3: 6-STAGE PIPELINE

| Stage | Function | Cycles | Key Module |
|-------|----------|--------|-----------|
| 1. **Fetch** | Read from I-cache, increment PC | 1 | fetch_stage_SEPARATE.sv |
| 2. **Decode** | Extract fields, opcode → type | 1 | decode_stage_SEPARATE.sv |
| 3. **Dispatch** | Read regs, allocate RS/ROB, rename | 1 | dispatch_stage.sv |
| 4. **Execute** | All FUs (1-6 cycles each) | 1-6 | execute_stage.sv |
| 5. **Writeback** | CDB broadcast to phys_regs | 1 | writeback_stage.sv |
| 6. **Commit** | In-order retirement, free resources | 1 | commit_stage.sv |

---

## PART 4: PROJECT STRUCTURE (28 Modules)

### 4.1 Pipeline Stages (7 modules)

```
fetch_stage.sv
├─ I/O: imem_addr (out) ← Program counter
│      imem_data (in) ← Instruction from memory
│      pc_out (out) ← Next PC
│      instr_out (out) ← Fetched instruction
├─ Internal: PC incrementer, branch target handling
└─ Latency: 1 cycle

decode_stage.sv
├─ I/O: instr_in (in) ← From fetch
│      instr_type_out (out) ← ALU/LOAD/MUL/etc
│      [extracted fields]
├─ Internal: Opcode decoder, field extraction, immed sign-ext
└─ Latency: 1 cycle

dispatch_stage.sv
├─ I/O: instr_in, instr_type, pc_in, valid_in
│      src1_value, src2_value (from arch regfile)
│      src1_value (out), src2_value (out), imm, alu_op
├─ Internal: Operand reading, immediate computation
└─ Routes instruction to correct RS type
└─ Latency: 1 cycle

execute_stage.sv (Encapsulates ALL FUs)
├─ I/O: [ALU inputs] [MUL inputs] [DIV inputs] [MEM inputs] [VEC inputs]
│      [ALU outputs] [MUL outputs] [DIV outputs] [MEM outputs] [VEC outputs]
│      cdb_result, cdb_tag, cdb_valid (out)
├─ Internal: ALU (1 cycle), MUL (4 stages), DIV (6 stages), LSU (2 cycles), VEU (4 lanes)
│            CDB arbitration (priority: ALU > LSU > MUL > DIV > VEU)
└─ Latency: FU-dependent (1-6 cycles)

writeback_stage.sv
├─ I/O: result_data, result_tag, result_valid (in)
│      cdb_result, cdb_tag, cdb_valid (out)
├─ Internal: Pass-through (or optional buffering)
└─ Latency: 1 cycle

commit_stage.sv
├─ I/O: rob_result (from ROB - unused in RAT+PHYSICAL!)
│      rob_dest_reg, rob_valid (in)
│      reg_write_addr, reg_write_data, reg_write_en (out)
├─ Internal: Read from physical_regfile (NOT ROB), write to arch regfile
└─ Latency: 1 cycle

exception_handler.sv
├─ I/O: ext_irq, illegal_instr, *_misalign (in)
│      exception_valid, exception_code, flush_pipeline (out)
├─ Internal: Exception detection & reporting
└─ Latency: 1 cycle
```

### 4.2 Tomasulo Core (3 modules)

```
reservation_station.sv (Instantiated 5 times: ALU, MEM, MUL, DIV, VEC)
├─ I/O: src1_value, src1_tag, src1_valid (in - operand 1)
│      src2_value, src2_tag, src2_valid (in - operand 2)
│      immediate (in), alu_op (in), dispatch_valid (in)
│      cdb_result, cdb_tag, cdb_valid (in - for forwarding)
│      operand1, operand2, execute_op, execute_valid, assigned_tag (out)
├─ Internal: FIFO queue of instructions waiting for operands
│           Tag-matching for CDB forwarding
│           Ready detection (both operands available?)
│           Priority encoding for issue
├─ Size: ALU=8, MEM=8, MUL=4, DIV=4, VEC=8 entries
└─ Function: Hold & issue instructions out-of-order when ready

reorder_buffer.sv (1 module, 16 entries)
├─ I/O: alloc_instr_type, alloc_dest_reg, alloc_phys_reg, alloc_valid (in)
│      result_data, result_tag, result_valid (in - from CDB)
│      commit_valid, commit_instr_type, commit_dest_arch, commit_dest_phys (out)
├─ Internal: FIFO tracking instructions in program order
│           Stores: destination arch reg, destination phys reg
│           NO DATA STORAGE (unlike Classic Tomasulo!)
│           Marks entry ready when CDB broadcasts matching tag
├─ Size: 16 entries (instruction window limit)
└─ Function: Ensure in-order retirement even though execution out-of-order

load_store_queue.sv (1 module)
├─ I/O: load_addr, load_valid (in) → load_data (out)
│      store_addr, store_data, store_valid (in) → store_blocked (out)
│      dmem_addr, dmem_write_data, dmem_we (out)
│      dmem_read_data (in), dmem_valid (in)
│      lsq_lq_full, lsq_sq_full (out)
├─ Internal: Load queue (8), store queue (8)
│           Address comparison for hazard detection
│           Store-to-load forwarding
├─ Size: LQ=8, SQ=8 entries
└─ Function: Handle memory operations, prevent WAR/RAW/WAW violations
```

### 4.3 Register & Renaming (4 modules - RAT+PHYSICAL specific!)

```
register_file.sv (32 architectural registers)
├─ I/O: read_addr1, read_addr2 (in) → read_data1, read_data2 (out)
│      write_addr, write_data, write_en (in)
├─ Internal: 32×32-bit storage (x0-x31 arch registers)
├─ Read: COMBINATIONAL (fastest!)
├─ Write: SEQUENTIAL on commit only
└─ Function: Hold FINAL committed state ONLY (no speculative data!)

physical_register_file.sv (64 physical registers - NEW!)
├─ I/O: write_addr (in, 6-bit) → phys_regs[addr] (storage)
│      write_data, write_en (in - from CDB)
│      read_addr1, read_addr2 (in) → read_data1, read_data2 (out)
│      status_wr_addr, status_wr_en (in)
│      status_valid[63:0] (out - per-entry ready bits)
├─ Internal: 64×32-bit storage (p0-p63)
│           Valid bits per entry (when result available)
├─ Read: COMBINATIONAL
├─ Write: SEQUENTIAL from CDB
└─ Function: Hold ALL speculative data during execution!

rat.sv (Register Alias Table - NEW!)
├─ I/O: src1_arch, src2_arch (in, 5-bit) → src1_phys, src2_phys (out, 6-bit)
│      dst_arch (in, 5-bit) → dst_phys (out, 6-bit)
│      rename_en (in)
│      commit_arch, commit_phys, commit_en (in - update on commit)
├─ Internal: 32 entries (one per arch reg), each stores 6-bit phys reg ID
│           Allocation counter (round-robin or free list)
├─ Read: COMBINATIONAL
├─ Write: SEQUENTIAL on dispatch (rename) & commit (update)
└─ Function: Map arch registers to physical registers

free_list.sv (Tracks free physical registers)
├─ I/O: alloc_req (in) → alloc_phys (out, 6-bit), alloc_valid (out)
│      free_phys (in, 6-bit), free_en (in)
├─ Internal: 64-bit bitmap (1=free, 0=allocated)
├─ Alloc: Search for first free bit
├─ Free: Set bit to 1 (on commit)
└─ Function: Manage physical reg allocation/deallocation
```

### 4.4 Support Modules (6 modules)

```
common_data_bus.sv (CDB Arbitration)
├─ I/O: alu_result, alu_tag, alu_valid (in, priority 1)
│      lsu_result, lsu_tag, lsu_valid (in, priority 2)
│      mul_result, mul_tag, mul_valid (in, priority 3)
│      div_result, div_tag, div_valid (in, priority 4)
│      vec_result, vec_tag, vec_valid (in, priority 5)
│      cdb_result, cdb_tag, cdb_valid (out)
├─ Internal: Priority encoder (one per cycle)
└─ Function: Broadcast ONE result per cycle to all waiters

vector_register_file.sv (32 architectural vector registers)
├─ I/O: read_addr1, read_addr2 (in) → read_data1, read_data2 (out, 128-bit)
│      write_addr, write_data, write_en (in)
├─ Internal: 32×128-bit storage (v0-v31 arch vector regs)
├─ Similar to scalar register_file
└─ Function: Hold architectural vector register state

hazard_detection.sv
├─ I/O: rs_full, rob_full, lsq_full, load_blocked, store_blocked (in)
│      stall_fetch, stall_decode, stall_dispatch (out)
├─ Internal: Simple combinational logic (OR of full signals)
└─ Function: Generate stall signals to pipeline

main_controller.sv
├─ I/O: rs_full, rob_full, lsq_full, branch_mispredict (in)
│      stall_fetch, stall_decode, stall_dispatch (out)
│      flush_pipeline (out)
├─ Internal: FSM for pipeline control
└─ Function: Coordinate stalling & flushing

branch_predictor.sv
├─ I/O: pc (in) → predicted_target (out)
│      is_branch, branch_taken (in)
│      branch_mispredict (out)
├─ Internal: Static predictor (backward=taken, forward=not)
└─ Function: Predict branch targets (later upgrade to 2-bit)

forwarding_logic.sv
├─ I/O: cdb_result, cdb_tag, cdb_valid (in)
│      req_src1_tag, req_src2_tag (in, physical reg IDs)
│      forwarded_src1, forwarded_src2 (out)
│      src1_available, src2_available (out)
├─ Internal: Tag matching against CDB
└─ Function: Forward CDB results to waiting instructions
```

### 4.5 Functional Units (5 modules, inside execute_stage)

```
alu.sv (1-cycle combinational)
├─ Operations: ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU
├─ I/O: operand1, operand2, alu_op (in) → result, valid_out (out)
├─ Latency: 1 cycle
└─ Status: Can issue 1 per cycle

multiplier.sv (4-stage pipelined via MUL_LATENCY parameter)
├─ Operations: MUL (low), MULH, MULHSU, MULHU
├─ I/O: multiplicand, multiplier, mul_type (in) → product_low, product_high (out)
├─ Latency: 4 cycles (configurable)
└─ Status: Can issue 1 per cycle, results back after 4 cycles

divider.sv (6-stage pipelined via DIV_LATENCY parameter)
├─ Operations: DIV, DIVU, REM, REMU
├─ I/O: dividend, divisor, div_type (in) → quotient, remainder (out)
├─ Latency: 6 cycles (configurable)
└─ Status: Can issue 1 per cycle, results back after 6 cycles

vector_execution_unit.sv (4 parallel lanes)
├─ Operations: VADD, VSUB, VMUL, VDIV, VAND, VOR, VXOR
├─ I/O: vec_src1, vec_src2 (in, 128-bit) → vec_result (out, 128-bit)
├─ Internal: Generates 4 vector_lane.sv instances
├─ Latency: 1 cycle per vector instruction
└─ Throughput: 4 elements per cycle

vector_lane.sv (Single 32-bit element ALU)
├─ Internal: Replicated 4 times inside VEU
├─ Operations: Element-wise arithmetic/logic
├─ Latency: 1 cycle
└─ Status: Parallel execution (4 lanes simultaneously)
```

### 4.6 Top Module (1)

```
riscv_core_top_RAT_PHYSICAL.sv
├─ Instantiates: All 28 modules above
├─ Signal routing: Fetch → Decode → Dispatch → Execute → Commit
├─ Wiring: Complex! Every module interconnected
├─ Key signals:
│  ├─ RAT wiring (arch → phys mapping)
│  ├─ Physical regfile wiring (CDB → writes)
│  ├─ RS wiring (all 5 types)
│  ├─ ROB wiring (ordering tracking)
│  ├─ CDB wiring (result broadcast)
│  └─ Free list wiring (allocation/deallocation)
└─ ~400 lines of pure integration
```

---

## PART 5: MODULE I/O SPECIFICATIONS (Quick Reference)

### Key Signals

**Physical register tag (6 bits):**
```systemverilog
wire [5:0] phys_reg_tag;  // 0-63 (address into physical_register_file)
// CDB carries these: cdb_tag[5:0]
// RS store these: *_tag[5:0]
// RAT outputs these: src1_phys[5:0], src2_phys[5:0], dst_phys[5:0]
```

**Common signals across modules:**
```systemverilog
clk                  // System clock
rst_n                // Active-low reset
flush_pipeline       // On misprediction (from controller)
*_valid              // Data valid on this cycle
*_tag                // Identifier (physical reg ID)
cdb_result[31:0]     // Result broadcast (32-bit)
cdb_valid            // CDB has valid result this cycle
```

---

## PART 6: CRITICAL RAT+PHYSICAL CONCEPTS

### Concept 1: Separation of Data Storage

| Component | Stores | Updated |
|-----------|--------|---------|
| **Arch regfile** | Committed state | On commit |
| **Phys regfile** | Speculative data | From CDB |
| **ROB** | Ordering info only | Marks ready on CDB |

### Concept 2: Tag Matching

**Dispatch:**
```
x2 → RAT lookup → physical p5
x3 → RAT lookup → physical p6
Instruction: ADD x1, x2, x3
RS entry: [src1_tag=p5, src2_tag=p6, op=ADD]
```

**Execute:**
```
ALU computes result → CDB broadcasts (tag=p7, result=value)
```

**Forwarding:**
```
RS waiting for p7 sees CDB (tag=p7)
RS captures value directly from CDB
```

### Concept 3: Commit & Free

**On commit (in-order from ROB):**
```
ROB_head: [dest_arch=x1, dest_phys=p7, ready=YES]
Action:
  1. arch_x1 ← phys_regs[p7]      // Write arch reg from phys reg
  2. RAT[1] ← p7                   // Update RAT (p7 is new owner)
  3. free_list.free(p_old)         // Old writer returned to free pool
  4. phys_regs[p7] stay intact     // Still available for in-flight instrs
```

---

## PART 7: IMPLEMENTATION PHASES (Quick Roadmap)

**Phase 1: Setup**
- Include `riscv_header.sv` in all modules
- Verify all parameters set correctly

**Phase 2: Register Infrastructure (CRITICAL!)**
1. register_file.sv (arch regs)
2. physical_register_file.sv (NEW - phys regs)
3. rat.sv (NEW - mapping table)
4. free_list.sv (allocation/free)
5. forwarding_logic.sv (updated)

**Phase 3: Pipeline Stages**
1. fetch_stage_SEPARATE.sv
2. decode_stage_SEPARATE.sv
3. dispatch_stage.sv
4. execute_stage.sv (encapsulates all FUs)
5. writeback_stage.sv
6. commit_stage.sv

**Phase 4: Tomasulo Core**
1. reservation_station.sv (5 instances)
2. reorder_buffer.sv
3. load_store_queue.sv

**Phase 5: Data Path**
1. common_data_bus.sv (CDB)
2. vector_register_file.sv
3. hazard_detection.sv

**Phase 6: Control**
1. main_controller.sv
2. branch_predictor.sv
3. exception_handler.sv

**Phase 7: Integration**
1. riscv_core_top_RAT_PHYSICAL.sv (connect everything!)

**Phase 8: Testing**
1. tb_riscv_core.sv (test all functionality)

---

## PART 8: TESTBENCH (tb_riscv_core.sv)

### Testbench Structure

```systemverilog
module tb_riscv_core;

// Test scenarios:

Test 1: Single ALU instruction
  ADD x1, x2, x3
  Verify: x1 = x2 + x3

Test 2: Dependent instructions (in-order)
  ADD x1, x2, x3      // produces x1
  ADD x4, x1, x5      // needs x1
  Verify: x4 correct

Test 3: Out-of-order execution
  MUL x1, x2, x3      // 4 cycles
  ADD x4, x5, x6      // 1 cycle, should complete first!
  Verify: Timing correct

Test 4: Multiplication
  MUL x1, 5, 3
  Verify: x1 = 15 (after 4 cycles)

Test 5: Division
  DIV x1, 10, 3
  Verify: x1 = 3 (after 6 cycles)

Test 6: Store-Load forwarding
  SW x2, 0(x1)        // Store
  LW x3, 0(x1)        // Load - should forward
  Verify: x3 = x2 (same address!)

Test 7: Vector operations
  VADD v1, v2, v3
  Verify: 4 lanes executing in parallel

Test 8-11: More complex scenarios...
```

### Key Testbench Features

- Instruction injection into fetch stage
- Cycle-by-cycle tracing
- Register file state verification
- Physical register forwarding verification
- ROB state tracking
- CDB signal monitoring

---

## PART 9: QUICK START CHECKLIST

### Before coding:
- [ ] Read this file completely
- [ ] Understand RAT+PHYSICAL data flow
- [ ] Review Part 4 module specifications
- [ ] Study riscv_header.sv parameters

### Setup:
- [ ] Copy all 28 modules to project directory
- [ ] Copy riscv_header.sv (with RAT+PHYSICAL params)
- [ ] Copy riscv_core_top_RAT_PHYSICAL.sv as top module
- [ ] Copy tb_riscv_core.sv as testbench

### Implementation:
- [ ] Phase 1: Setup (rinclude header)
- [ ] Phase 2: Register infrastructure (5 modules)
- [ ] Phase 3: Pipeline stages (6 modules)
- [ ] Phase 4: Tomasulo core (3 modules)
- [ ] Phase 5-6: Support modules (7 modules)
- [ ] Phase 7: Integration (top module)
- [ ] Phase 8: Testing (testbench)

### Compilation:
```
iverilog -g2009 -I. *.sv -o sim
vvp sim
```

---

## KEY FILES YOU HAVE

```
Essential:
├─ riscv_header.sv (parameters)
├─ RAT_PHYSICAL_REGS_CORRECTED.sv (4 modules)
├─ riscv_core_top_RAT_PHYSICAL.sv (integration)
├─ forwarding_logic.sv (updated)
└─ 25 other modules (unchanged from before)

Reference:
├─ RISC-V Green Card.pdf (instruction encoding)
├─ RVV_SUBSET.md (vector details)
└─ INSTRUCTION.md (instruction reference)

Testing:
└─ tb_riscv_core.sv (testbench)
```

---

## NEXT STEPS

1. **Read this file completely** (you are here)
2. **Study the 4 RAT+PHYSICAL core modules:**
   - register_file.sv (CORRECTED)
   - physical_register_file.sv (NEW)
   - rat.sv (NEW)
   - forwarding_logic.sv (UPDATED)
3. **Review riscv_core_top_RAT_PHYSICAL.sv** to see how everything connects
4. **Understand the data flow** (Part 1 diagram)
5. **Start implementing** following Phase 1-8 roadmap

**You are ready. Begin!**

