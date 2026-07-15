//============================================================================
//  Irem M72 for MiSTer FPGA - Z80-based sound system
//
//  Copyright (C) 2022 Martin Donlon
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


/*
void m90_state::m90_sound_cpu_map(address_map &map)
{
	map(0x0000, 0xefff).rom();
	map(0xf000, 0xffff).ram();
}

void m90_state::m90_sound_cpu_io_map(address_map &map)
{
	map.global_mask(0xff);
	map(0x00, 0x01).rw("ymsnd", FUNC(ym2151_device::read), FUNC(ym2151_device::write));
	map(0x80, 0x80).r("soundlatch", FUNC(generic_latch_8_device::read));
	map(0x80, 0x81).w(m_audio, FUNC(m72_audio_device::rtype2_sample_addr_w));
	map(0x82, 0x82).w(m_audio, FUNC(m72_audio_device::sample_w));
	map(0x83, 0x83).w("soundlatch", FUNC(generic_latch_8_device::acknowledge_w));
	map(0x84, 0x84).r(m_audio, FUNC(m72_audio_device::sample_r));
}
*/

import board_pkg::*;

module sound (
    input clk, // 40M
    input clk_ram,

    input reset,

    input m99,

    input latch_wr,
    input [7:0] latch_din,

    input paused,

    output [15:0] sound_out,

    // sample ROM in SDRAM (256KB samples don't fit in on-chip BRAM)
    output [24:0] sdr_sample_addr,
    input  [63:0] sdr_sample_data,
    output        sdr_sample_req,
    input         sdr_sample_rdy,

    // ioctl
    input bram_wr,
    input [7:0] bram_data,
    input [19:0] bram_addr,
    input bram_z80_cs
);


wire ce_1_7m, ce_3_5m;
jtframe_frac_cen #(2) jt51_cen
(
    .clk(clk),
    .cen_in(~paused),
    .n(10'd63),
    .m(10'd704),
    .cen({ce_1_7m, ce_3_5m})
);


wire [7:0] ram_rom_dout;

wire ram_write = &z80_addr[15:12] & ~z80_mreq_n & ~z80_wr_n;

singleport_ram #(.widthad(16), .width(8), .name("SND")) sound_ram_rom(
    .clock(clk),
    .address(bram_z80_cs ? bram_addr[15:0] : z80_addr),
    .q(ram_rom_dout),
    .wren((bram_z80_cs & bram_wr) | ram_write),
    .data(bram_z80_cs ? bram_data : z80_dout)
);

reg [17:0] sample_addr;
wire [7:0] sample_data;
reg sample_play = 0;

sample_cache sample_rom(   // 256KB sample ROM in SDRAM, streamed via a small cache
    .clk(clk),
    .clk_ram(clk_ram),
    .reset(reset),
    .sdr_addr(sdr_sample_addr),
    .sdr_data(sdr_sample_data),
    .sdr_req(sdr_sample_req),
    .sdr_rdy(sdr_sample_rdy),
    .addr(sample_addr),
    .data(sample_data)
);

wire [7:0] ym_dout;

wire ym_cs = m99 ? (~z80_iorq_n && (z80_addr[7:1] == 7'b0100000)) : (~z80_iorq_n && z80_addr[7:1] == 7'b0000000);
wire ym_irq_n;

wire z80_iorq_n, z80_rd_n, z80_wr_n, z80_mreq_n, z80_m1_n;

wire [15:0] z80_addr;
wire [7:0] z80_din;
wire [7:0] z80_dout;

always_comb begin
    z80_din = 8'hff;
    if ( ~z80_m1_n & ~z80_iorq_n ) begin
        z80_din = {2'b11, ~snd_latch_ready, ym_irq_n, 4'b1111};
    end else if ( ~z80_rd_n ) begin
        if (ym_cs) begin
            z80_din = ym_dout;
        end else if (~z80_iorq_n) begin
            if (m99) begin
                if (z80_addr[7:0] == 8'h42) begin
                    z80_din = snd_latch;
                end
            end else begin
                if (z80_addr[7:0] == 8'h80) begin
                    z80_din = snd_latch;
                end else if (z80_addr[7:0] == 8'h84) begin
                    z80_din = sample_data;
                end
            end
        end else begin
            z80_din = ram_rom_dout;
        end
    end
end

T80s z80(
    .RESET_n(~reset),
    .CLK(clk),
    .CEN(ce_3_5m),

    .INT_n(ym_irq_n & ~snd_latch_ready),
    .NMI_n(~z80_nmi),

    .M1_n(z80_m1_n),
    .MREQ_n(z80_mreq_n),
    .IORQ_n(z80_iorq_n),
    .RD_n(z80_rd_n),
    .WR_n(z80_wr_n),
    .A(z80_addr),
    .DI(z80_din),
    .DO(z80_dout)
);

wire [15:0] ym_audio;

jt51 ym2151(
    .rst(reset),
    .clk(clk),
    .cen(ce_3_5m),
    .cen_p1(ce_1_7m),
    .cs_n(~ym_cs),
    .wr_n(z80_wr_n),
    .a0(z80_addr[0]),
    .din(z80_dout),
    .dout(ym_dout),
    .irq_n(ym_irq_n),
    .xleft(ym_audio),
    .xright()
);

reg [7:0] snd_latch;
reg snd_latch_ready = 0;

reg [13:0] nmi_counter = 0;
reg z80_nmi = 0;
reg z80_iorq_n_old;

reg [7:0] sample_out;

always @(posedge clk) begin
    if (reset) begin
        z80_nmi <= 0;
        nmi_counter <= 0;
        snd_latch_ready <= 0;
        sample_play <= 0;
    end else if (~paused) begin

        // NMI frequency is 7812.5Khz
        // On original hardware this is derived from the 32Mhz CPU clock, divided by 4096
        // 4Mhz signal is divided by the 74LS161 counters IC71 and IC72
        // Here since we have a 40Mhz sys_clk, we divide by 5120
        nmi_counter <= nmi_counter + 14'd1;
        if (nmi_counter == 14'd5119) begin
            if (m99) begin
                if (sample_data == 8'd0 || ~sample_play) begin
                    sample_play <= 0;
                end else begin
                    sample_out <= sample_data;
                    sample_addr <= sample_addr + 18'd1;
                end
            end else begin
                z80_nmi <= 1;
            end
            nmi_counter <= 14'd0;
        end

        if (latch_wr) begin
            snd_latch <= latch_din;
            snd_latch_ready <= 1;
        end

        if (~z80_m1_n && ~z80_mreq_n && z80_addr == 16'h0066)
            z80_nmi <= 0;

        z80_iorq_n_old <= z80_iorq_n;
        if (z80_iorq_n_old & ~z80_iorq_n) begin
            if (~z80_wr_n) begin
                if (m99) begin
                    case(z80_addr[7:0])
                        8'h00: sample_addr[11:0] <= { z80_dout, 4'd0 };
                        8'h01: sample_addr[17:12] <= z80_dout[5:0];
                        8'h04: begin end
                        8'h06: begin
                            sample_play <= 1;
                        end
                        8'h42: snd_latch_ready <= 0;
                        default: begin end
                    endcase
                end else begin
                    case(z80_addr[7:0])
                        8'h80: sample_addr[12:0] <= { z80_dout, 5'd0 };
                        8'h81: sample_addr[17:13] <= z80_dout[4:0];
                        8'h82: begin
                            sample_out <= z80_dout;
                            sample_addr <= sample_addr + 18'd1;
                        end
                        8'h83: snd_latch_ready <= 0;
                        default: begin end
                    endcase
                end
            end
        end
    end
end

wire [7:0] signed_sample = sample_out - 8'h80;
reg [15:0] filtered_sample;
reg [15:0] filtered_ym_audio;

// 3.5Khz 2nd order low pass filter with additional 10dB attenuation
IIR_filter #(
    .use_params(1),
    .stereo(0),
    .coeff_x(0.00005223613830195753 * 0.31622776601),
    .coeff_x0(2),
    .coeff_x1(1),
    .coeff_x2(0),
    .coeff_y0(-1.99131174878388250704),
    .coeff_y1(0.99134932873949543897),
    .coeff_y2(0)
    ) samples_lpf (
	.clk(clk),
	.reset(reset),

	.ce(ce_3_5m),
	.sample_ce(ce_3_5m),

	.cx(),
	.cx0(),
	.cx1(),
	.cx2(),
	.cy0(),
	.cy1(),
	.cy2(),

	.input_l({signed_sample[7:0], {8{signed_sample[0]}}}),
    .input_r(),
	.output_l(filtered_sample),
    .output_r()
);


// 9khz 1st order, 10khz 2nd order
IIR_filter #(
    .use_params(1),
    .stereo(0),
    .coeff_x(0.00000663036349096853),
    .coeff_x0(3),
    .coeff_x1(3),
    .coeff_x2(1),
    .coeff_y0(-2.95950327886750486073),
    .coeff_y1(2.91969995512661473214),
    .coeff_y2(-0.96019190621343297742)
    ) ym_lpf (
	.clk(clk),
	.reset(reset),

	.ce(ce_3_5m),
	.sample_ce(ce_3_5m),

	.cx(),
	.cx0(),
	.cx1(),
	.cx2(),
	.cy0(),
	.cy1(),
	.cy2(),

	.input_l(ym_audio),
    .input_r(),
	.output_l(filtered_ym_audio),
    .output_r()
);

reg [16:0] sound_out_17bit;
always @(posedge clk) begin 
    sound_out_17bit <= {filtered_ym_audio[15], filtered_ym_audio[15:0]} + {filtered_sample[15], filtered_sample[15:0]};
end

assign sound_out = sound_out_17bit[16:1];

endmodule