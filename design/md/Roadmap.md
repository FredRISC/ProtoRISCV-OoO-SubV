1. Micro-op Cracking (LMUL > 1): Industry cores dynamically support LMUL=2,4,8 by stalling the decoder and "cracking" the instruction into multiple LMUL=1 micro-operations. Our core currently only supports LMUL=1.

2. Element-Level Chaining: Our VEU computes all 128 bits in one cycle (or waits for all 128 bits to load from the LSQ) before broadcasting. An industry core starts broadcasting element 0 on cycle 1, and the dependent instruction starts computing element 0 on cycle 2, while the first instruction is still computing element 1. This requires complex Bypass FIFOs.

3. Pipelined VEU: Our VEU is a 1-cycle combinational block. At 128 bits, this would severely limit our maximum clock frequency (Fmax). Industry VEUs are deeply pipelined (e.g., 4 to 6 stages).

4. Masking (v0.t): We skipped the vector mask register and masked execution paths to save routing complexity.

5. Exceptions & vstart: If an industry LSQ hits a Page Fault on the 3rd element of a vector load, it halts, saves the index to the vstart CSR, flushes the pipeline, and later resumes from element 3. We assume flat memory that never faults mid-vector.
