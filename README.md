# ProtoRISCV: Out-of-Order RV32IM-SubV Processor

ProtoRISC is a single-issue, speculatively-renamed, Out-of-Order RISC-V processor prototype, supporting the **RV32IM** base integer instruction set alongside a tightly-coupled Vector Coprocessor implementing a targeted subset of the **Zve32x** Vector Extension.

This project serves as a comprehensive study of OoO RISC-V architecture and a foundation for expanding to a more advanced design. This prototype utilizes a fully tag-based **Unified Scalar/Vector Datapath** and a modern **Register Alias Table (RAT) + Physical Register File (PRF)** architecture (inspired by the MIPS R10000/Alpha 21264) to achieve precise, high-performance out-of-order execution.  

## Architectural Highlights

* **7-Stage Pipeline:** Fetch $\rightarrow$ Decode $\rightarrow$ Dispatch/Rename $\rightarrow$ Issue $\rightarrow$ RegRead $\rightarrow$ Execute $\rightarrow$ Commit (ROB).
* **Hardware Renaming (RAT+PRF):** Eliminates the traditional Architectural Register File (ARF). Speculative data lives entirely in the PRF. The Reorder Buffer (ROB) handles in-order retirement by updating the Commit RAT, maintaining a precise architectural state to ensure clean exception handling and exact branch misprediction recovery.
* **Unified Issue & Payload Datapath:** Scalar and vector instructions share the same Reservation Stations and `reg_read_stage` routing logic, minimizing footprint and complexity.
* **Superscalar Backend:** While the frontend is 1-wide, the backend is fully superscalar, capable of issuing and executing up to 5 disjoint instruction types (ALU, MEM, MUL, DIV, VEC) simultaneously.
* **Scheduled & Unscheduled Bypass Networks:** Both the scalar and vector datapaths utilize a dual-tier forwarding bus architecture—a scheduled bus for deterministic operations (ALU, MUL, etc.) and an unscheduled bus prioritized for variable-latency operations (Load/Store).
* **Dynamic Branch Prediction:** 2-bit Branch History Table (BHT) and Branch Target Buffer (BTB) integrated into the Fetch stage, with delayed precise state recovery handled by the ROB.
* **Vector Coprocessor (`VLEN=128`):** A 4-lane Vector Execution Unit processes 128-bit blocks. Vector length (`vl`) and type (`vtype`) are dynamically tracked through the pipeline as physical dependencies.
* **Vector-Aware Load/Store Queue (LSQ):** Out-of-Order memory subsystem featuring combinational memory disambiguation and Store-to-Load Forwarding. An embedded FSM automatically bridges the 128-bit Vector datapath with the 32-bit memory interface.

---

## Quick Start & Verification

The processor is verified using **Verilator**, which compiles the SystemVerilog RTL directly into a highly optimized, cycle-accurate C++ executable. The verification suite utilizes directed, **white-box SystemVerilog testbenches** to expose complex microarchitectural edge cases such as memory disambiguation flushes, cross-domain tag aliasing, and store-to-load forwarding. *(Note: This repository is actively growing; more comprehensive verification suites and randomized testbenches are planned for future updates.)*

### Prerequisites
* `make`
* `verilator` (Version 5.0+ required for `--timing` support)

### Running the Simulation
To compile the RTL into a Verilator C++ model and execute the core testbench:
```bash
cd design
make sim-verilator
```
*To target a different test scenario, edit the `--top-module` flag in the `Makefile`.*

---

## Project Documentation

Detailed architectural breakdowns and references can be found in the `design/md/` directory:

* **ISA & Instruction Reference:** Complete list of supported RV32IM and RVV instructions, encoding formats, and Vector execution rationale.
* **Testbench Guide:** Overview of the directed testbenches, trace logging, and memory configurations.
* **Architecture Roadmap:** An analysis of the architectural shortcuts taken in this prototype, and the required microarchitectural upgrades (e.g., Element-level Chaining, Micro-op Cracking) to reach commercial silicon parity.