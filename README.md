# Out-of-Order-RVV

## FredRISC: Out-of-Order RV32IMV Processor

This project implements a high-performance, 6-stage Out-of-Order RISC-V processor supporting the `RV32IM` base integer and multiplication extensions, along with a subset of the `RVV` (Vector) extension (`Zve32x`).

It utilizes a modern **Register Alias Table (RAT) + Physical Register File (PRF)** architecture to achieve precise out-of-order execution and hardware renaming, fully decoupling architectural state from speculative execution.

### Core Architecture

The processor is divided into a 6-stage pipeline:
1. **Fetch:** Program Counter generation and instruction memory access.
2. **Decode:** Instruction classification and immediate generation.
3. **Dispatch:** Hardware register renaming (RAT), ROB allocation, LSQ allocation, and Reservation Station dispatch.
4. **Issue & RegRead:** Tomasulo-based Reservation Stations (RS) hold instructions until operands are ready on the Common Data Bus (CDB). A predictive Issue Scheduler arbitrates functional units.
5. **Execute:** Multiple encapsulated Functional Units (ALU, Pipelined Multiplier, Pipelined Divider, Vector Execution Unit, and Load/Store Queue).
6. **Commit:** In-order retirement via the Reorder Buffer (ROB) to update the architectural register file.

### Current Vector Extension Support (`LMUL = 1`)

The core currently natively supports the RISC-V Vector Extension with **`LMUL = 1`** (Vector Length Multiplier). 

* **Vector Length (`vl`):** Handled dynamically via physical register renaming to prevent Out-of-Order hazards.
* **Vector Type (`vtype`):** Speculatively tracked via `vector_csr` and tunneled through the payload datapath.
* **Execution:** A parameterized 128-bit Vector Execution Unit (VEU) utilizing 4 parallel 32-bit execution lanes.
* **Memory:** Native 128-bit datapaths routed to the execute stage to support `VLE32.V` and `VSE32.V`.

---

### Future Roadmap: `LMUL > 1` Support

Support for register grouping (`LMUL > 1`, e.g., `MAX_LMUL = 4`) will be supported in future revisions. Moving beyond `LMUL = 1` significantly increases the complexity of dependency tracking. 

Implementing `LMUL > 1` will require transitioning to a **Micro-op (uOp) Cracking** architecture, impacting the following modules:

* **`dispatch_stage.sv`:** Must detect `LMUL > 1` from the speculative `vtype` CSR and stall the frontend, breaking the single vector instruction into `LMUL` distinct uOps mapped to sequential architectural registers.
* **`vector_rat.sv` & `vector_free_list.sv`:** Will process mapping requests sequentially over `LMUL` cycles, avoiding the need for heavily multi-ported SRAM arrays.
* **`reorder_buffer.sv`:** Must allocate consecutive tracking entries for the cracked uOps to ensure all grouped physical registers are retired and freed correctly in-order.
* **`reservation_station.sv`:** No major changes required if cracking is used! Each uOp acts as an independent `LMUL=1` instruction tracking its specific physical tags.
* **`vector_execution_unit.sv`:** Executes the cracked uOps sequentially as they independently wake up from the Reservation Station.
* **`load_store_queue.sv` (VLSU):** Must be overhauled with a state machine capable of generating multiple contiguous 128-bit memory requests from a single base address, writing each loaded block to the distinct physical registers assigned to the uOps.