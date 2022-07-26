module sprite (
	input CLK_32M,
    input CE_PIX,

	input CLK_96M,

	input [15:0] DIN,
	output [15:0] DOUT,
	output DOUT_VALID,
	
	input [19:0] A,
    input [1:0] BYTE_SEL,

    input BUFDBEN,
    input MRD,
    input MWR,

    input HBLK,
    input [8:0] VE,
    input NL,

    input DMA_ON,
    output reg TNSL,

    output [7:0] pix_test,

    input [24:0] base_address,

    output [1:0] sdr_wr_sel,
	output [15:0] sdr_din,
	input [15:0] sdr_dout,
	output [24:1] sdr_addr,
	output sdr_req,
	input sdr_ack
);

assign sdr_wr_sel = 2'b00;
assign sdr_din = 0;

wire [7:0] dout_h, dout_l;

assign DOUT = { dout_h, dout_l };
assign DOUT_VALID = MRD & BUFDBEN;

dpramv #(.widthad_a(9)) ram_h
(
	.clock_a(CLK_32M),
	.address_a(A[9:1]),
	.q_a(dout_h),
	.wren_a(MWR & BUFDBEN & BYTE_SEL[1]),
	.data_a(DIN[15:8]),

	.clock_b(CLK_32M),
	.address_b(dma_rd_addr),
	.data_b(),
	.wren_b(0),
	.q_b(dma_h)
);

dpramv #(.widthad_a(9)) ram_l
(
	.clock_a(CLK_32M),
	.address_a(A[9:1]),
	.q_a(dout_l),
	.wren_a(MWR & BUFDBEN & BYTE_SEL[0]),
	.data_a(DIN[7:0]),

	.clock_b(CLK_32M),
	.address_b(dma_rd_addr),
	.data_b(),
	.wren_b(0),
	.q_b(dma_l)
);

reg [63:0] objram[128];

reg [7:0] dma_l, dma_h;
reg [10:0] dma_counter;
wire [9:0] dma_rd_addr = dma_counter[10:1];

always_ff @(posedge CLK_32M) begin
    reg [7:0] b[6];
    if (DMA_ON & TNSL) begin
        TNSL <= 0;
        dma_counter <= 11'd0;
    end

    if (~TNSL) begin
        case (dma_counter[2:0])
        3'b001: begin
            b[0] <= dma_l;
            b[1] <= dma_h;
        end
        3'b011: begin
            b[2] <= dma_l;
            b[3] <= dma_h;
        end
        3'b101: begin
            b[4] <= dma_l;
            b[5] <= dma_h;
        end
        3'b111: objram[dma_counter[10:3]] <= { dma_h, dma_l, b[5], b[4], b[3], b[2], b[1], b[0] };
        endcase

        dma_counter <= dma_counter + 11'd1;
        if (dma_counter == 11'h3ff) TNSL <= 1;
    end
end

reg line_buffer_ack, line_buffer_req;
reg [3:0] line_buffer_color;
reg [31:0] line_buffer_in;
reg [9:0] line_buffer_x;

line_buffer line_buffer(
    .CLK_32M(CLK_32M),
    .CLK_96M(CLK_96M),
    .CE_PIX(CE_PIX),

    .V0(VE[0]),

    .wr_req(line_buffer_req),
    .wr_ack(line_buffer_ack),
    .data_in(line_buffer_in),
    .color_in(line_buffer_color),
    .position_in(line_buffer_x),

    .pixel_out(pix_test)
);

function [15:0] reverse_bytes(input [15:0] b);
	begin
		reverse_bytes = { b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15],
                          b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7] };
	end
endfunction

reg [63:0] cur_obj;
wire [8:0] obj_org_y = cur_obj[8:0];
wire [15:0] obj_code = cur_obj[31:16];
wire [3:0] obj_color = cur_obj[35:32];
wire obj_flipx = cur_obj[43];
wire obj_flipy = cur_obj[42];
wire [1:0] obj_height = cur_obj[45:44];
wire [1:0] obj_width = cur_obj[47:46];
wire [9:0] obj_org_x = cur_obj[57:48];
reg [8:0] width_px, height_px;
reg [3:0] width, height;
reg [8:0] rel_y;

wire [8:0] row_y = obj_flipy ? (height_px - rel_y) : rel_y;

always_ff @(posedge CLK_96M) begin
    reg old_v0 = 0;

    reg [7:0] obj_ptr = 0;
    reg [3:0] st = 0;
    reg [3:0] span;
	reg [15:0] code;
    reg [8:0] V;

    old_v0 <= VE[0];

    if (old_v0 != VE[0]) begin
        // new line, reset
        obj_ptr <= 0;
        st <= 0;
        V <= VE + 1;
    end else if (obj_ptr == 10'h80) begin
        // done, wait
        obj_ptr <= obj_ptr;
    end else if (sdr_ack != sdr_req) begin
        // wait
    end else begin
        st <= st + 1;
        case (st)
        0: cur_obj <= objram[obj_ptr];
        1: begin
            width_px <= 16 << obj_width;
            height_px <= 16 << obj_height;
            width <= 1 << obj_width;
            height <= 1 << obj_height;
            rel_y <= V + obj_org_y + ( 16 << obj_height );
            span <= 0;
        end
        2: begin
            if (rel_y >= height_px) begin
                st <= 0;
                obj_ptr <= obj_ptr + width;
            end
            code <= obj_code + row_y[8:4] + ( ( obj_flipx ? ( width - span - 1 ) : span ) * 8 );
        end
        3: begin
            sdr_addr <= base_address[24:1] + { code[11:0], obj_flipx, row_y[3:0], 1'b0 }; // 1st 16-bit of 1st column
            sdr_req <= ~sdr_ack;
        end
        4: begin
            line_buffer_in[15:0] <= obj_flipx ? reverse_bytes(sdr_dout) : sdr_dout;
            sdr_addr <= base_address[24:1] + { code[11:0], obj_flipx, row_y[3:0], 1'b1 }; // 2nd 16-bit of 1st column
            sdr_req <= ~sdr_ack;
        end
        5: begin
            line_buffer_in[31:16] <= obj_flipx ? reverse_bytes(sdr_dout) : sdr_dout;
            if (line_buffer_req != line_buffer_ack)
                st <= st; // wait
            else begin
                sdr_addr <= base_address[24:1] + { code[11:0], ~obj_flipx, row_y[3:0], 1'b0 }; // 1st 16-bit of 2nd column
                sdr_req <= ~sdr_ack;
                line_buffer_color <= obj_color;
                line_buffer_x = obj_org_x + ( 16 * span );
                line_buffer_req <= ~line_buffer_ack;
            end
        end
        6: begin
            line_buffer_in[15:0] <= obj_flipx ? reverse_bytes(sdr_dout) : sdr_dout;
            sdr_addr <= base_address[24:1] + { code[11:0], ~obj_flipx, row_y[3:0], 1'b1 }; // 2nd 16-bit of 2st column
            sdr_req <= ~sdr_ack;
        end
        7: begin
            line_buffer_in[31:16] <= obj_flipx ? reverse_bytes(sdr_dout) : sdr_dout;
            if (line_buffer_req != line_buffer_ack)
                st <= st; // wait
            else begin
                line_buffer_x = obj_org_x + 8 + ( 16 * span );
                line_buffer_req <= ~line_buffer_ack;
            end
        end
        8: begin
            if (span == (width - 1)) begin
                st <= 0;
                obj_ptr <= obj_ptr + width;
            end else begin
                st <= 2;
                span <= span + 1;
            end
        end
        endcase
    end
end

endmodule

module line_buffer(
    input CLK_32M,
    input CLK_96M,
    input CE_PIX,
    
    input V0,

    input wr_req,
    output reg wr_ack,
    input [31:0] data_in,
    input [3:0] color_in,
    input [9:0] position_in,

    output reg [7:0] pixel_out
);

reg [1:0] scan_buffer = 0;
reg [9:0] scan_pos = 0;
reg [7:0] line_pixel;
reg [9:0] line_position;
reg line_write = 0;

wire [7:0] scan_0, scan_1, scan_2;
dpramv #(.widthad_a(10)) buffer_0
(
	.clock_a(CLK_32M),
	.address_a(scan_pos),
	.q_a(scan_0),
	.wren_a(scan_buffer == 1),
	.data_a(8'd0),

	.clock_b(CLK_96M),
	.address_b(line_position),
	.data_b(line_pixel),
	.wren_b(scan_buffer == 2 && line_write),
	.q_b()
);

dpramv #(.widthad_a(10)) buffer_1
(
	.clock_a(CLK_32M),
	.address_a(scan_pos),
	.q_a(scan_1),
	.wren_a(scan_buffer == 2),
	.data_a(8'd0),

	.clock_b(CLK_96M),
	.address_b(line_position),
	.data_b(line_pixel),
	.wren_b(scan_buffer == 0 && line_write),
	.q_b()
);

dpramv #(.widthad_a(10)) buffer_2
(
	.clock_a(CLK_32M),
	.address_a(scan_pos),
	.q_a(scan_2),
	.wren_a(scan_buffer == 0),
	.data_a(8'd0),

	.clock_b(CLK_96M),
	.address_b(line_position),
	.data_b(line_pixel),
	.wren_b(scan_buffer == 1 && line_write),
	.q_b()
);

always_ff @(posedge CLK_96M) begin
    reg [31:0] data;
    reg [3:0] color;
    reg [9:0] position;
    reg [3:0] count = 0;

    line_write <= 0;
    
    if (count != 0) begin
		line_pixel <= { color, data[31], data[23], data[15], data[7] };
        line_write <= data[31] | data[23] | data[15] | data[7];
        line_position <= position;
        position <= position + 10'd1;
        count <= count - 4'd1;
        data <= { data[30:23], data[22:15], data[14:7], data[6:0], 1'b0 };
    end else if (wr_req != wr_ack) begin
        data <= data_in;
        color <= color_in;
        position <= position_in;
        count <= 4'd8;
        wr_ack <= wr_req;
    end
end

always_ff @(posedge CLK_32M) begin
    reg old_v0 = 0;

    if (old_v0 != V0) begin
        scan_pos <= 249; // TODO why?
        old_v0 <= V0;

        case (scan_buffer)
        0: scan_buffer <= 1;
        1: scan_buffer <= 2;
        default: scan_buffer <= 0;
        endcase

    end else if (CE_PIX) begin
        
        case (scan_buffer)
        0: pixel_out <= scan_0;
        1: pixel_out <= scan_1;
        2: pixel_out <= scan_2;
        endcase

        scan_pos <= scan_pos + 1;
    end
end

endmodule