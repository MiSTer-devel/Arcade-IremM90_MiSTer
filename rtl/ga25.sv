//============================================================================
//  Copyright (C) 2024 Martin Donlon
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module GA25(
    input clk,
    input clk_ram,

    input ce, // 13.33MHz
    output ce_pix, // 6.66MHz

    input paused,

    input reset,

    input mem_cs,
    input mem_wr,
    input mem_rd,
    input io_wr,
    input io_rd,

    output busy,

    input [15:0] addr,
    input [15:0] cpu_din,
    output reg [15:0] cpu_dout,
    
    input NL,

    input [63:0] sdr_data,
    output [24:0] sdr_addr,
    output sdr_req,
    input sdr_rdy,
    output sdr_64bit,

    output reg vblank,
    output reg vsync,
    output reg hblank,
    output reg hsync,

    output reg [10:0] color_out,

    input [1:0] dbg_en_layers,
    input dbg_solid_sprites
);

// VRAM
reg [14:0] vram_addr;
reg [15:0] vram_data;
wire [15:0] vram_q;
reg vram_we;

singleport_ram #(.widthad(15), .width(16), .name("VRAM")) vram(
    .clock(clk),
    .address(vram_addr),
    .q(vram_q),
    .wren(vram_we),
    .data(vram_data)
);

//// VIDEO TIMING
reg [9:0] hcnt, vcnt;
reg vpulse, hpulse;

wire [9:0] VE = vcnt ^ {1'b0, {9{NL}}};

always_ff @(posedge clk) begin
    bit _hblank, _vblank;

    if (ce_pix) begin
        hcnt <= hcnt + 10'd1;
        if (hcnt == 10'd469) begin
            hcnt <= 10'd46;
            vcnt <= vcnt + 10'd1;
            if (vcnt == 10'd375) begin
                vcnt <= 10'd114;
            end
        end

        _hblank = hcnt < 10'd101 || hcnt > 10'd420;
        _vblank = vcnt > 10'd375 || vcnt < 10'd136;

        hblank <= _hblank;
        vblank <= _vblank;
        hsync <= hcnt < 10'd63 || hcnt > 10'd446;
        vsync <= vcnt > 10'd119 && vcnt < 10'd130;
        hpulse <= hcnt == 10'd46;
        vpulse <= (vcnt == 10'd124 && hcnt > 10'd260) || (vcnt == 10'd125 && hcnt < 10'd260);
    end
end

wire [21:0] rom_addr[2];
wire [31:0] rom_data[2];
wire        rom_req[2];
wire        rom_rdy[2];

wire [21:0] obj_gfx_addr;
wire [63:0] obj_gfx_data;
wire        obj_gfx_req;
wire        obj_gfx_rdy;

ga25_sdram sdram(
    .clk(clk),
    .clk_ram(clk_ram),

    .addr_a(rom_addr[0]),
    .data_a(rom_data[0]),
    .req_a(rom_req[0]),
    .rdy_a(rom_rdy[0]),

    .addr_b(rom_addr[1]),
    .data_b(rom_data[1]),
    .req_b(rom_req[1]),
    .rdy_b(rom_rdy[1]),

    .addr_c(obj_gfx_addr),
    .data_c(obj_gfx_data),
    .req_c(obj_gfx_req),
    .rdy_c(obj_gfx_rdy),

    .sdr_addr,
    .sdr_data,
    .sdr_req,
    .sdr_rdy,
    .sdr_64bit,
);

//// MEMORY ACCESS
reg [3:0] mem_cyc;

reg [9:0] x_ofs[2], y_ofs[2];
reg [7:0] control[2];
reg [9:0] rowscroll[2];
reg [9:0] rowselect[2];
reg [7:0] vid_ctrl;

wire [14:0] layer_vram_addr[2];
reg layer_load[2];
wire layer_prio[2];
wire [7:0] layer_color[2];
wire layer_enabled[2];
reg [15:0] vram_latch;

reg [1:0] cpu_access_rq;
reg cpu_access_we;
reg [15:0] cpu_access_din;

reg [47:0] control_save_0[512];
reg [47:0] control_save_1[512];

reg [47:0] control_restore[2];

reg rowscroll_active;

assign busy = |cpu_access_rq;
reg prev_access;

assign ce_pix = ce & ~mem_cyc[0];


reg [47:0] obj_data;
reg [7:0] obj_color;
reg [2:0] obj_sel;
reg [14:0] obj_addr;

always_ff @(posedge clk) begin
    bit [9:0] rs_y;

    // increment mem_cyc even during reset
    if (ce) begin
        mem_cyc <= mem_cyc + 4'd1;
    end

    if (reset) begin
        cpu_access_rq <= 2'd0;
        vram_we <= 0;
        
        // layer regs
        x_ofs[0] <= 10'd0; x_ofs[1] <= 10'd0;
        y_ofs[0] <= 10'd0; y_ofs[1] <= 10'd0;
        control[0] <= 8'd0; control[1] <= 8'd0;

        rowscroll_active <= 0;

    end else begin
        prev_access <= mem_cs & (mem_rd | mem_wr);
        if (mem_cs & (mem_rd | mem_wr) & ~busy & ~prev_access) begin
            cpu_access_rq <= 2'd2;
            cpu_access_we <= mem_wr;
            cpu_access_din <= cpu_din;
        end
        
        vram_we <= 0;

        if (ce) begin
            obj_sel <= 3'b000;

            if (ce_pix) begin
                layer_load[0] <= 0; layer_load[1] <= 0;

                color_out <= 11'd0;

                if (~vid_ctrl[2]) begin
                    color_out <= |layer_color[0][3:0] ? { 3'd0, layer_color[0] } : { 3'd0, layer_color[1] };
                    if (|obj_color[3:0]) begin
                        if (~layer_prio[0] & ~layer_prio[1]) begin
                            color_out <= { 3'd1, obj_color };
                        end else begin
                            if (vid_ctrl[0] & ~obj_color[7]) begin
                                color_out <= { 3'd1, obj_color };
                            end else if (vid_ctrl[1] & ~&obj_color[7:6]) begin
                                color_out <= { 3'd1, obj_color };
                            end
                        end
                    end
                end

                if (hpulse) begin
                    mem_cyc <= 4'd15; // NOTE: this should be true already except for the first cycles after reset
                    rowscroll_active <= 1;
                    obj_addr <= 15'h7700;
                end
            end

            case(mem_cyc)
                4'd0: begin
                    if (rowscroll_active) begin
                        rs_y = y_ofs[0] + VE;
                        vram_addr <= 15'h7800 + rs_y;
                    end else begin
                        vram_addr <= layer_vram_addr[0];
                    end
                end
                4'd1: begin
                    if (rowscroll_active) begin
                        rowscroll[0] <= vram_q[9:0];
                    end else begin
                        vram_latch <= vram_q;
                    end
                end
                4'd2: begin
                    if (rowscroll_active) begin
                        vram_addr <= 15'h7c00 + VE[8:0];
                    end else begin
                        vram_addr <= layer_vram_addr[0] | 15'd1;
                        layer_load[0] <= 1;
                    end
                end
                4'd3: begin
                    if (rowscroll_active) begin
                        rowselect[0] <= vram_q[9:0];
                    end
                end
                4'd4: begin
                    vram_addr <= obj_addr;
                end
                4'd5: begin
                    obj_data[15:0] <= vram_q;
                    obj_sel[0] <= 1;
                    obj_addr <= obj_addr + 15'd1;
                end
                4'd6: begin
                    vram_addr <= obj_addr;
                end
                4'd7: begin
                    obj_data[31:16] <= vram_q;
                    obj_sel[1] <= 1;
                    obj_addr <= obj_addr + 15'd1;
                end
                4'd8: begin
                    if (rowscroll_active) begin
                        rs_y = y_ofs[1] + VE;
                        vram_addr <= 15'h7a00 + rs_y;
                    end else begin
                        vram_addr <= layer_vram_addr[1];
                    end
                end
                4'd9: begin
                    if (rowscroll_active) begin
                        rowscroll[1] <= vram_q[9:0];
                    end else begin
                        vram_latch <= vram_q;
                    end
                end
                4'd10: begin
                    if (rowscroll_active) begin
                        vram_addr <= 15'h7e00 + VE[8:0];
                    end else begin
                        vram_addr <= layer_vram_addr[1] | 15'd1;
                        layer_load[1] <= 1;
                    end
                end
                4'd11: begin
                    if (rowscroll_active) begin
                        rowselect[1] <= vram_q[9:0];
                    end
                    rowscroll_active <= 0;
                end
                4'd12: begin
                    vram_addr <= obj_addr;
                end
                4'd13: begin
                    obj_data[47:32] <= vram_q;
                    obj_sel[2] <= 1;
                    obj_addr <= obj_addr + 15'd1;
                end
                4'd14: begin
                    vram_addr <= addr[15:1];
                    vram_we <= cpu_access_we;
                    vram_data <= cpu_access_din;
                    if (cpu_access_rq == 2'd2) cpu_access_rq <= 2'd1;
                end
                4'd15: begin
                    cpu_dout <= vram_q;
                    if (cpu_access_rq == 2'd1) begin
                        cpu_access_rq <= 2'd0;
                        cpu_access_we <= 0;
                    end
                end
            endcase
        end

        if (io_wr) begin
            case(addr[7:0])
            'h80: y_ofs[0][9:0] <= cpu_din[9:0];
            'h82: x_ofs[0][9:0] <= cpu_din[9:0];
            
            'h84: y_ofs[1][9:0] <= cpu_din[9:0];
            'h86: x_ofs[1][9:0] <= cpu_din[9:0];
            
            'h8a: control[0] <= cpu_din[7:0];
            'h8c: control[1] <= cpu_din[7:0];

            'h8e: vid_ctrl <= cpu_din[7:0];
            endcase
        end

        if (hcnt == 10'd104 && ~paused) begin // end of hblank
            control_save_0[vcnt] <= { y_ofs[0], x_ofs[0], control[0], rowselect[0], rowscroll[0] };
            control_save_1[vcnt] <= { y_ofs[1], x_ofs[1], control[1], rowselect[1], rowscroll[1] };
        end else if (paused) begin
            control_restore[0] <= control_save_0[vcnt];
            control_restore[1] <= control_save_1[vcnt];
        end
    end
end

ga25_obj ga25_obj(
    .clk,
    .clk_ram,
    .ce,
    .ce_pix,
    
    .reset,

    .color(obj_color),

    .NL,
    .hpulse,
    .vpulse,

    .obj_in(obj_data),
    .obj_sel(obj_sel),

    .sdr_data(obj_gfx_data),
    .sdr_addr(obj_gfx_addr),
    .sdr_req(obj_gfx_req),
    .sdr_rdy(obj_gfx_rdy),
    .sdr_refresh(),

    .dbg_solid_sprites(dbg_solid_sprites)
);


//// LAYERS
generate
	genvar i;
    for(i = 0; i < 2; i = i + 1 ) begin : generate_layer
        wire [9:0] _y_ofs = paused ? control_restore[i][47:38] : y_ofs[i];
        wire [9:0] _x_ofs = paused ? control_restore[i][37:28] : x_ofs[i];
        wire [7:0] _control = paused ? control_restore[i][27:20] : control[i];
        wire [9:0] _rowselect = paused ? control_restore[i][19:10] : rowselect[i];
        wire [9:0] _rowscroll = paused ? control_restore[i][9:0] : rowscroll[i];


        ga25_layer layer(
            .clk(clk),
            .ce_pix(ce_pix),

            .NL(NL),

            .control(_control),

            .x_ofs(_x_ofs),
            .y_ofs(_y_ofs),
  
            .x_base({hcnt[9:3] ^ {7{NL}}, 3'd0}),
            .y_base(VE),
            .rowscroll(_rowscroll),
            .rowselect(_rowselect),

            .vram_addr(layer_vram_addr[i]),

            .load(layer_load[i]),
            .attrib(vram_q),
            .index(vram_latch),

            .color_out(layer_color[i]),
            .prio_out(layer_prio[i]),
            .color_enabled(layer_enabled[i]),

            .sdr_addr(rom_addr[i]),
            .sdr_data(rom_data[i]),
            .sdr_req(rom_req[i]),
            .sdr_rdy(rom_rdy[i]),

            .dbg_enabled(dbg_en_layers[i])
        );
    end
endgenerate
endmodule

