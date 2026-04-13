`timescale 1ps/1ps

// This is a module implementing L1 cache featuring MSHR (Miss Status Handling Register)
// This module inputs a memory read or write requests (address, size) and track the MSHRs (store lsq tag into target list, store cacheline tag)
// and decodes the address into cache line tag, index, and byte offest to check the cache
// and finally returns data to output

`define CacheLineSize 64   // 64 bytes per line
`define L1CacheSize 2**12 // 4KB
`define NUM_OF_LINES L1CacheSize/CacheLineSize //2**6 = 64 cache lines
`define NUM_OF_WAYS 4     // 4-way associative cache
`define NUM_OF_SETS  L1CacheSize/ (NUM_OF_WAYS*CacheLineSize)

`define INDEX_BITS $clog2(NUM_OF_SETS)
`define OFFSET_BITS $clog2(CacheLineSize)
`define TAG_BITS XLEN - INDEX_BITS - OFFSET_BITS

`define BLOCK_ID_SIZE TAG_BITS+INDEX_BITS

`define MSHR_SIZE 16
`define TARGET_LIST_SIZE 4
`define STORE_BUFFER_SIZE 4

`define XLEN 32 
`define LSQ_SIZE 16

module L1Cache (
// global signals
input clk,
input rst_n,

// Load interface
input read_req_in,
input load_byte_en_in,
output read_port_stall_out, // stall
output [XLEN-1:0] read_data_out,
output read_data_valid_out,

// Store interface
input write_req_in,
input [XLEN-1:0] write_data_in,
input [3:0] store_byte_en_in, 
output write_port_stall_out, // stall

// General input signals
input address_in,
input [$clog2(LSQ_SIZE)-1:0] lsq_tag_in, // Used if missed in Cache

// L2 interface
output [BLOCK_ID_SIZE-1:0] L2_req_block_id_out, 
output L2_block_req_out,
input [BLOCK_ID_SIZE-1:0] L2_return_block_id_in,
input [CacheLineSize-1:0] L2_return_block_data_in,
input L2_return_block_valid_in
);

// Cacheline struct
typedef struct packed {
// logic [`NUM_OF_STATE:0] state; // Assuming L1 is private; this will be present in L2
logic valid;
logic dirty;
logic [TAG_BITS-1:0] tag;
logic [CacheLineSize-1:0][7:0] data; // 64 bytes per line

} CacheLine_t;

CacheLine_t [$clog2(NUM_OF_WAYS)-1:0] L1Cache_inst [NUM_OF_SETS-1:0];

// Decode request address
logic [TAG_BITS-1:0] extracted_tag;
logic [INDEX_BITS-1:0] extracted_index;
logic [OFFSET_BITS-1:0] extracted_offset;
assign extracted_tag = address_in[(XLEN-1)-:TAG_BITS];
assign extracted_index = address_in[OFFSET_BIT +: INDEX_BITS];
assign extracted_offset = address_in[0 +: OFFSET_BITS];

logic [BLOCK_ID_SIZE-1:0] extracted_block_id;
assign extracted_block_id = {extracted_tag, extracted_index};
logic Cache_hit;

// MSHR struct
typedef struct packed {
    logic valid = 0;
    logic [BLOCK_ID_SIZE-1:0] block_id; // We need tag and index to match a cache line
    logic [$clog2(LSQ_SIZE)-1:0] target_list [TARGET_LIST_SIZE-1:0];
    logic [$clog(TARGET_LIST_SIZE)-1:0] target_list_ptr = 0; // pointer to the front of the target list
} MSHR_t;

MSHR_t MSHR_inst [MSHR_SIZE-1:0];

// Store Buffer struct
typedef struct packed {
    logic valid;
    logic [BLOCK_ID_SIZE-1:0] block_id;
    logic [7:0][CacheLineSize-1:0] store_data; // Coalesced
    logic [CacheLineSize-1:0] write_byte_en;
} Store_Buffer_t;

Store_Buffer_t Store_Buffer_inst [MSHR_SIZE-1:0];


// MSHR Signals for Checking on Cacheline Return
logic MSHR_hit; // find a MSHR waiting for the same cache line
logic [$clog(MSHR_SIZE)-1:0] MSHR_hit_ID;
// MSHR Signals for Allocation 
logic [$clog(MSHR_SIZE)-1:0] MSHR_alloc_ID; // the allocated MSHR ID
logic MSHR_AVAILABLE; // no MSHR available
// Cache Block Return logic
logic [TAG_BITS-1:0] L2_return_tag;
logic [INDEX_BITS-1:0] L2_return_index;
assign L2_return_tag = L2_return_block_id_in[(BLOCK_ID_SIZE-1)-:TAG_BITS];
assign L2_return_index = L2_return_block_id_in[INDEX_BITS-1:0];
logic MSHR_Broadcast_tag;
logic [NUM_OF_WAYS-1:0] Eviction_Target_Way; // TODO: Requiring Eviction Policy 

//Store Buffer Signals
logic [BLOCK_ID_SIZE-1:0] write_block_id_passthrough;
logic [OFFSET_BITS-1:0] write_offset_passthrough;
logic write_req_passthrough; 
logic [XLEN-1:0] write_data_passthrough; 
logic [3:0] write_byte_en_passthrough;
logic [$clog(MSHR_SIZE)-1:0] MSHR_ID_passthrough;
logic Store_Buffer_ID_Alloc;
assign Store_Buffer_ID_Alloc = MSHR_ID_passthrough;

// Cache logic (load, store, miss)
always @(posedge clk || negedge rst_n) begin : CACHE_LOGIC
    if(!rst_n) begin
        read_data_out <= 'd0;
        read_port_stall_out <= 1'b0;
        write_port_stall_out <= 1'b0;
        read_data_valid <= 1'b0;
        L2_block_req_out <= 1'b0;
    end
    else begin
        if(read_req_in) begin
            L2_block_req_out <= 1'b0;
            read_port_stall_out <= 1'b0;
            read_data_valid <= 1'b0;
            if(!MSHR_hit) begin // No MSHR is waiting for the tag, check if any way in the set is holding the line
                for(int i=0;i<NUM_OF_WAYS;i=i+1) begin // traverse each way to find if there is a hit
                    if(L1Cache_inst[extracted_index][i].valid && L1Cache_inst[extracted_index][i].tag == extracted_tag) begin
                        read_data_out <= L1Cache_inst[extracted_index][i].data;
                        read_data_valid <= 'd1; // Hit in the L1Cache!
                        read_port_stall <= 1'b0;
                        Cache_hit <= 1'b1;
                        break;
                    end
                    
                    if(i == (NUM_OF_WAYS-1)) begin
                        // Cache line not found in the set, need to allocate a MSHR
                        if (MSHR_AVAILABLE) begin
                            MSHR_inst[MSHR_alloc_ID].block_id <= extracted_block_id;
                            MSHR_inst[MSHR_alloc_ID].valid <= 1'b1;
                            MSHR_inst[MSHR_alloc_ID].target_list_ptr <= 'd0;
                            MSHR_inst[MSHR_alloc_ID].target_list[0] <= lsq_tag_in;
                            L2_block_req_out <= 1'b1;
                            L2_req_block_id_out <= extracted_block_id;
                        end
                        else begin
                            // No MSHR is free, need to stall
                            read_port_stall <= 1'b1; // assuming lsq handles this approprioately, e.g. holding the same request until stall is de-asserted
                        end
                    end
                end
            end
            else begin // Find a MSHR waiting for the same tag, add the coming lsq_tag to the target list
                if(MSHR_inst[MSHR_hit_ID].target_list_ptr + 1 < TARGET_LIST_SIZE) begin
                    MSHR_inst[MSHR_hit_ID].target_list[(MSHR_inst[MSHR_hit_ID].target_list_ptr + 1)] <= lsq_tag_in;
                    MSHR_inst[MSHR_hit_ID].target_list_ptr = MSHR_inst[MSHR_hit_ID].target_list_ptr + 1;
                end
                else begin
                    //The MSHR's target list is full, so we need to stall the read port
                    read_port_stall_out <= 1'b1;                
                end
            end
        end
        else if(write_req_in) begin
            L2_block_req_out <= 1'b0;
            write_port_stall_out <= 1'b0; 
            write_req_passthrough <= 1'b0; 
            if(!MSHR_hit) begin // No MSHR is waiting for the tag, check if any way in the set is holding the line
                for(int i=0;i<NUM_OF_WAYS;i=i+1) begin
                    if(L1Cache_inst[extracted_index][i].valid && L1Cache_inst[extracted_index][i].tag == extracted_tag) begin
                        if(store_byte_en_in[0]) L1Cache_inst[extracted_index][i].data[extracted_offset] <= write_data_in[7:0];
                        if(store_byte_en_in[1]) L1Cache_inst[extracted_index][i].data[extracted_offset+1] <= write_data_in[15:8];
                        if(store_byte_en_in[2]) L1Cache_inst[extracted_index][i].data[extracted_offset+2] <= write_data_in[23:16];
                        if(store_byte_en_in[3]) L1Cache_inst[extracted_index][i].data[extracted_offset+3] <= write_data_in[31:24];
                        L1Cache_inst[extracted_index][i].dirty <= 'd1;
                        break;
                    end

                    if(i == (NUM_OF_WAYS-1)) begin
                        // Cache line not found in the set, need to allocate a MSHR
                        if (MSHR_AVAILABLE) begin
                            MSHR_inst[MSHR_alloc_ID].block_id <= {extracted_tag, extracted_index};
                            MSHR_inst[MSHR_alloc_ID].valid <= 1'b1;
                            MSHR_inst[MSHR_alloc_ID].target_list_ptr <= 'd0;
                            MSHR_inst[MSHR_alloc_ID].target_list[0] <= lsq_tag_in;
                            L2_block_req_out <= 1'b1;
                            L2_req_block_id_out <= extracted_block_id;
                            // need to pass the req to store buffer
                            write_req_passthrough <= 1'b1;
                            write_block_id_passthrough <= extracted_block_id;
                            write_offset_passthrough <= extracted_offset;
                            write_data_passthrough <= write_data_in;
                            write_byte_en_passthrough <= store_byte_en_in;
                            MSHR_ID_passthrough <= MSHR_alloc_ID;
                        end
                        else begin
                            // No MSHR is free, need to stall
                            write_port_stall_out <= 1'b1;  
                        end    
                    end 
                end        
            end
            else begin
                if(MSHR_inst[MSHR_hit_ID].target_list_ptr + 1 < TARGET_LIST_SIZE) begin
                    MSHR_inst[MSHR_hit_ID].target_list[(MSHR_inst[MSHR_hit_ID].target_list_ptr + 1)] <= lsq_tag_in;
                    MSHR_inst[MSHR_hit_ID].target_list_ptr = MSHR_inst[MSHR_hit_ID].target_list_ptr + 1;
                    write_req_passthrough <= 1'b1;
                    write_block_id_passthrough <= extracted_block_id;
                    write_offset_passthrough <= extracted_offset;
                    write_data_passthrough <= write_data_in;
                    write_byte_en_passthrough <= store_byte_en_in;
                    MSHR_ID_passthrough <= MSHR_hit_ID;
                end
                else begin
                    //The MSHR's target list is full, so we need to stall the read (or write port)
                    read_port_stall_out <= 1'b1;                
                end 
            end
        end
        
        // Return Block handling: Find a block to replace in the set
        if(L2_return_block_valid_in) begin
            L1Cache_inst[L2_return_index][Eviction_Target_Way].tag <= L2_return_tag;
            L1Cache_inst[L2_return_index][Eviction_Target_Way].data <= L2_return_block_data_in;
            L1Cache_inst[L2_return_index][Eviction_Target_Way].valid <= 1'b1;
            L1Cache_inst[L2_return_index][Eviction_Target_Way].dirty <= 1'b0;
            // Find the corresponding MSHR
            for(int i=0;i<MSHR_SIZE;i=i+1) begin
                if(MSHR_inst[i].valid && MSHR_inst[i].block_id == L2_return_block_id_in) begin // find an MSHR waiting for this returned block
                    // TODO: drain and retire the MSHR and write the store buffer coalesced result
                    // 1. Write the coalesced data from Store buffer to the Cache line
                    // 2. Ask LSQ's lsq_tag entries to send request again, since the block has just arrived
                    // Store_Buffer_Retire <= 1'b1;
                    // MSHR_Retire <= 1'b1; 
                    // Retire_id <= i; 
                    break;
                end
            end
        end

        // Store Buffer logic
        // Find an available store buffer (can use MSHR_ID_passthrough = store buffer id for simple allocation) and Coalesce write data and byte_en 
        if(write_req_passthrough) begin
            Store_Buffer_inst[Store_Buffer_ID_Alloc].valid <= 1'b1;
            if(write_byte_en_passthrough[0]) Store_Buffer_inst[Store_Buffer_ID_Alloc].store_data[write_offset_passthrough] <= write_data_passthrough[7:0];
            if(write_byte_en_passthrough[1]) Store_Buffer_inst[Store_Buffer_ID_Alloc].store_data[write_offset_passthrough+1] <= write_data_passthrough[15:7];
            if(write_byte_en_passthrough[2]) Store_Buffer_inst[Store_Buffer_ID_Alloc].store_data[write_offset_passthrough+2] <= write_data_passthrough[23:16];
            if(write_byte_en_passthrough[3]) Store_Buffer_inst[Store_Buffer_ID_Alloc].store_data[write_offset_passthrough+3] <= write_data_passthrough[31:24];
            Store_Buffer_inst[Store_Buffer_ID_Alloc].block_id <= write_block_id_passthrough;
            Store_Buffer_inst[Store_Buffer_ID_Alloc].write_byte_en[write_offset_passthrough +:3] <= Store_Buffer_inst[Store_Buffer_ID_Alloc].write_byte_en[write_offset_passthrough +:3] | write_byte_en_passthrough;
            // ...
        end
        /* TODO: write coalesced data to cache line
        if(Store_Buffer_Retire) begin
            Store_Buffer_inst[Retire_id].valid <= 1'b0;
            L1Cache_inst[todo][todo].data <= Store_Buffer_inst[Retire_id].store_data;
        end
        */
    end

end

// MSHR Allocation logic
always_comb begin : MSHR_ALLOC
    MSHR_AVAILABLE = 1'b0;
    MSHR_alloc_ID = 'd0;
    for (int i=0;i<MSHR_SIZE;i=i+1) begin
        if(!MSHR_inst[i].valid) begin
            MSHR_alloc_ID = i;
            MSHR_AVAILABLE = 1'b1;
            break;
        end
    end
end

// MSHR Hit Check logic
always_comb begin : MSHR_HIT
    MSHR_hit = 1'b0;
    MSHR_hit_ID = 'd0;
    for (int i=0;i<MSHR_SIZE;i=i+1) begin
        if(MSHR_inst[i].valid && MSHR_inst[i].block_id == extracted_block_id) begin
            MSHR_hit = 1'b1;
            MSHR_hit_ID = i;
            break;
        end
    end
end


endmodule
