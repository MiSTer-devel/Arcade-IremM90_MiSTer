//============================================================================
//  Irem M90 for MiSTer FPGA - sound sample ROM cache (SDRAM-backed)
//
//  Riskchal's sample ROM (rc_v0) is 256KB, too large to keep in on-chip BRAM
//  alongside everything else. The sound CPU streams samples sequentially at the
//  ~7.8kHz NMI rate, so a small direct-mapped cache over SDRAM is more than fast
//  enough. Modeled on rom_cache.sv (same clk/clk_ram req/ack handshake and the
//  version-counter reset-invalidate trick), adapted for 18-bit byte addressing
//  and 8-bit output.
//============================================================================

import board_pkg::*;

module sample_cache(
    input clk,
    input clk_ram,
    input reset,

    output reg [24:0]   sdr_addr,
    input      [63:0]   sdr_data,
    output reg          sdr_req,
    input               sdr_rdy,

    input      [17:0]   addr,        // byte address into the 256KB sample space
    output     [7:0]    data
);

localparam CACHE_WIDTH = 8;          // 256 lines of 64 bits (8 bytes) = 2KB cache

// line = addr[17:3]; index = line[7:0]; tag = version ++ line[14:8]
wire [7:0]  index = addr[10:3];
wire [8:0]  tag   = { version, addr[17:11] };

reg [1:0]  version;
reg [63:0] cache_data[2**CACHE_WIDTH];
reg [8:0]  cache_tag[2**CACHE_WIDTH];

reg [63:0] cache_line;
reg [8:0]  cached_tag;
reg [2:0]  byte_ofs;

assign data = cache_line[{byte_ofs, 3'b000} +: 8];

enum { IDLE, CACHE_CHECK, SDR_WAIT } state = IDLE;
reg read_req, read_ack;
reg prev_reset;

always_ff @(posedge clk) begin
    cache_line <= cache_data[index];
    cached_tag <= cache_tag[index];
    byte_ofs   <= addr[2:0];

    prev_reset <= reset;

    if (reset) begin
        state <= IDLE;
        if (~prev_reset) version <= version + 2'd1;   // invalidate whole cache
    end else begin
        case (state)
        IDLE:        state <= CACHE_CHECK;             // continuously keep current line resident
        CACHE_CHECK: begin
            if (cached_tag == tag) begin
                state <= IDLE;
            end else begin
                sdr_addr <= REGION_SOUND_SAMPLES.base_addr[24:0] + { 7'd0, addr[17:3], 3'b000 };
                read_req <= ~read_req;
                state <= SDR_WAIT;
            end
        end
        SDR_WAIT: begin
            if (read_req == read_ack) begin
                cache_tag[index] <= tag;
                state <= IDLE;
            end
        end
        endcase
    end
end

reg read_req_prev;
always_ff @(posedge clk_ram) begin
    sdr_req <= 0;
    read_req_prev <= read_req;

    if (sdr_rdy) begin
        cache_data[index] <= sdr_data;
        read_ack <= read_req;
    end

    if (read_req != read_req_prev) begin
        sdr_req <= 1;
    end
end

endmodule
