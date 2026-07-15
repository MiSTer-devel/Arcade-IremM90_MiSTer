`ifdef LINTING
`include "types.sv"
`endif

import types::*;

interface ISCR_if(input logic clk, input logic reset);
    logic [7:0] value;

    logic cpu_set;
    logic [7:0] cpu_value;

    logic ctrl_set_if;
    logic ctrl_clear_if;

    logic IF;
    logic IMK;
    logic MS;
    logic ENCS;
    logic [2:0] PR;
endinterface

module ISCR(ISCR_if inf);
    assign inf.IF = inf.value[7];
    assign inf.IMK = inf.value[6];
    assign inf.MS = inf.value[5];
    assign inf.ENCS = inf.value[4];
    assign inf.PR = inf.value[2:0];

    always @(posedge inf.clk) begin
        if (inf.reset) begin
            inf.value <= 8'h47;
        end else begin
            if (inf.cpu_set) begin
                inf.value <= inf.cpu_value;
            end
            if (inf.ctrl_clear_if) begin
                inf.value[7] <= 0;
            end
            if (inf.ctrl_set_if) begin
                inf.value[7] <= 1;
            end
        end
    end
endmodule

module V35(
    input               clk,

    input               ce,

    input               n_reset,

    // A0-19
    output      [19:0]  addr,


    // Memory access signals
    output              r_w,
    output              n_ube,
    output              n_iostb,
    output              n_mreq,
    output              n_mstb,


    // Bus Control
    input               ready,
    input               n_poll, 

    //input               n_ea,

    //output              n_hldak,
    //input               hldrq,
    //output              n_refrq,



    // D0-15
    output      [15:0]  dout,
    input       [15:0]  din,


    // PORTS
    output       [7:0]  p0out,
    input        [7:0]  p0in,
    output       [7:0]  p1out,
    input        [7:0]  p1in,
    output       [7:0]  p2out,
    input        [7:0]  p2in,


    // Analog Comparator
    //input        [7:0]  ptin,


    // Clock Outputs
    //output              clkout,
    //output              tout,


    // Serial
    //input               n_cts0,
    //input               n_cts1,
    //input               rxd0,
    //input               rxd1,
    //output              txd0,
    //output              txd1,
    //output              n_sck0,


    // DMA
    //output              n_dmaak0,
    //output              n_dmaak1,
    //input               dmarq0,
    //input               dmarq1,
    //output              n_tc0,
    //output              n_tc1,


    // Interrupts
    input               intreq, // INT
    output              n_intak,

    input               n_intp0,
    input               n_intp1,
    input               n_intp2,

    input               nmi,


    // Non-hardware
    input               turbo,

    input secure,

    input secure_wr,
    input [7:0] secure_addr,
    input [7:0] secure_byte
);

wire reset = ~n_reset;

assign n_intak = 1; // TODO

// Register file
// Segment registers
reg [15:0] reg_ds0 /*verilator public*/;
reg [15:0] reg_ds1 /*verilator public*/;
reg [15:0] reg_ss  /*verilator public*/;
reg [15:0] reg_ps  /*verilator public*/;

// General purpose
reg [15:0] reg_aw  /*verilator public*/;
reg [15:0] reg_bw  /*verilator public*/;
reg [15:0] reg_cw  /*verilator public*/;
reg [15:0] reg_dw  /*verilator public*/;
reg [15:0] reg_sp  /*verilator public*/;
reg [15:0] reg_bp  /*verilator public*/;
reg [15:0] reg_ix  /*verilator public*/;
reg [15:0] reg_iy  /*verilator public*/;

wire [15:0] cur_pc  /*verilator public*/;

reg [15:0] TA;
reg [15:0] TB;

struct
{
    bit [7:0] PRC;
    bit [7:0] IDB;
    bit [7:0] INTM;
} sfr;

wire [7:0] ISPR;
wire RAMEN = sfr.PRC[6];

// V35 on-chip 256-byte internal RAM, enabled via RAMEN (PRC[6]).
// Located at the {IDB}Exx page. Used by some games (e.g. Risky Challenge)
// as fast scratch RAM; must behave as real read/write RAM.
//
// Split into even/odd byte banks so each has a single read port and a single
// write port -> infers distributed RAM (MLAB) instead of ~2K flip-flops plus
// wide multiplexers, which would not fit the device. Unaligned word accesses
// are supported: the low bank is simply addressed at idx+1 for the high byte.
(* ramstyle = "MLAB" *) reg [7:0] internal_ram_lo[128] /* verilator public */; // even bytes
(* ramstyle = "MLAB" *) reg [7:0] internal_ram_hi[128] /* verilator public */; // odd bytes

ISCR_if EXIC0(clk, reset); ISCR sfr_EXIC0(EXIC0);
ISCR_if EXIC1(clk, reset); ISCR sfr_EXIC1(EXIC1);
ISCR_if EXIC2(clk, reset); ISCR sfr_EXIC2(EXIC2);

// Timer unit interrupt-control registers (INTTU0/1/2) and timer data registers.
ISCR_if TMIC0(clk, reset); ISCR sfr_TMIC0(TMIC0);
ISCR_if TMIC1(clk, reset); ISCR sfr_TMIC1(TMIC1);
ISCR_if TMIC2(clk, reset); ISCR sfr_TMIC2(TMIC2);

reg [15:0] TM0, MD0, TM1, MD1;
reg [7:0]  TMC0, TMC1;

reg halt /*verilator public*/; // TODO, do something with this

flags_t flags;
wire [15:0] reg_psw /*verilator public*/ = {
    flags.MD,
    3'b111,
    flags.V,
    flags.DIR,
    flags.IE,
    flags.BRK,
    flags.S,
    flags.Z,
    1'b0,
    flags.AC,
    1'b0,
    flags.P,
    1'b1,
    flags.CY
};

// Data Pointer operations
reg [19:0] dp_addr;
reg [15:0] dp_dout;
sreg_index_e dp_sreg;
reg dp_zero_seg;
reg dp_write;
reg dp_wide;
reg dp_io;
reg dp_req;
wire dp_ready;

wire [15:0] bcu_din;
reg [15:0] internal_din;
reg bcu_read;
wire [15:0] mem_din = bcu_read ? bcu_din : internal_din;

// Instruction prefetch
reg [15:0] next_pc /*verilator public*/;
reg set_pc /*verilator public*/;

wire [7:0] ipq[8];
wire [3:0] ipq_len;

nec_decode_t decoded /*verilator public*/;
wire [15:0] dbg_ipc /* verilator public */ = decoded.pc;  // executed instruction start IP (for tracing)
opcode_e cur_opcode;

reg [1:0] ce_count;
reg ce_phase;
reg ce_1, ce_2;

always_ff @(posedge clk) begin
    ce_1 <= 0;
    ce_2 <= 0;
    if (ce) begin
        if (ce_count == 2'b00) begin
            if (ce_phase) begin
                ce_2 <= 1;
            end else begin
                ce_1 <= 1;
            end

            ce_phase <= ~ce_phase;
            ce_count <= sfr.PRC[1:0];
        end else begin
            ce_count <= ce_count - 2'd1;
        end
    end
end


function bit [15:0] calc_ea(nec_decode_t dec);
    bit [15:0] addr;

    if (dec.dest == OPERAND_IO_DIRECT || dec.source0 == OPERAND_IO_DIRECT) begin
        addr = { 8'd0, dec.disp[7:0] };
    end else if (dec.dest == OPERAND_IO_INDIRECT || dec.source0 == OPERAND_IO_INDIRECT) begin
        addr = reg_dw;
    end else begin
        case(dec.rm)
        3'b000: addr = reg_bw + reg_ix;
        3'b001: addr = reg_bw + reg_iy;
        3'b010: addr = reg_bp + reg_ix;
        3'b011: addr = reg_bp + reg_iy;
        3'b100: addr = reg_ix;
        3'b101: addr = reg_iy;
        3'b110: addr = dec.mod == 0 ? dec.disp : reg_bp;
        3'b111: addr = reg_bw;
        endcase

        if (dec.mod == 2'b01) addr = addr + { {8{dec.disp[7]}}, dec.disp[7:0] };
        else if (dec.mod == 2'b10) addr = addr + dec.disp;
    end

    return addr;
endfunction

function bit [19:0] calc_physical_addr(sreg_index_e sreg, bit [15:0] ea);
    bit [19:0] addr;
    case(sreg)
    DS0: addr = {reg_ds0, 4'd0} + {4'd0, ea};
    DS1: addr = {reg_ds1, 4'd0} + {4'd0, ea};
    SS: addr = {reg_ss, 4'd0} + {4'd0, ea};
    PS: addr = {reg_ps, 4'd0} + {4'd0, ea};
    endcase
    return addr;
endfunction

function bit [7:0] get_reg8(reg8_index_e r);
    case(r)
    AL: return reg_aw[7:0];
    AH: return reg_aw[15:8];
    BL: return reg_bw[7:0];
    BH: return reg_bw[15:8];
    CL: return reg_cw[7:0];
    CH: return reg_cw[15:8];
    DL: return reg_dw[7:0];
    DH: return reg_dw[15:8];
    endcase
endfunction

function bit [15:0] get_reg16(reg16_index_e r);
    case(r)
    AW: return reg_aw;
    BW: return reg_bw;
    CW: return reg_cw;
    DW: return reg_dw;
    SP: return reg_sp;
    BP: return reg_bp;
    IX: return reg_ix;
    IY: return reg_iy;
    endcase
endfunction

task set_reg8(input reg8_index_e r, input bit[7:0] val);
    case(r)
    AL: reg_aw[7:0]  <= val;
    AH: reg_aw[15:8] <= val;
    BL: reg_bw[7:0]  <= val;
    BH: reg_bw[15:8] <= val;
    CL: reg_cw[7:0]  <= val;
    CH: reg_cw[15:8] <= val;
    DL: reg_dw[7:0]  <= val;
    DH: reg_dw[15:8] <= val;
    endcase
endtask

task set_reg16(input reg16_index_e r, input bit[15:0] val);
    case(r)
    AW: reg_aw <= val;
    BW: reg_bw <= val;
    CW: reg_cw <= val;
    DW: reg_dw <= val;
    SP: reg_sp <= val;
    BP: reg_bp <= val;
    IX: reg_ix <= val;
    IY: reg_iy <= val;
    endcase
endtask

task set_sreg(input sreg_index_e r, input bit[15:0] val);
    case(r)
    DS0: reg_ds0 <= val;
    DS1: reg_ds1 <= val;
    SS: reg_ss <= val;
    PS: begin
        reg_ps <= val;
        set_pc <= 1;
    end
    endcase
endtask

task write_memory(input bit [15:0] addr, input sreg_index_e seg, input width_e width, input [15:0] data);
    bit [19:0] phys_addr;
    phys_addr = calc_physical_addr(seg, addr);

    if (phys_addr[19:0] == 20'hfffff) begin
        sfr.IDB <= data[7:0];
    end else if (phys_addr[19:8] == { sfr.IDB, 4'hf }) begin
        case(phys_addr[7:0])
        8'h40: sfr.INTM <= data[7:0];
        8'h4c: begin EXIC0.cpu_set <= 1; EXIC0.cpu_value <= data[7:0]; end
        8'h4d: begin EXIC1.cpu_set <= 1; EXIC1.cpu_value <= data[7:0]; end
        8'h4e: begin EXIC2.cpu_set <= 1; EXIC2.cpu_value <= data[7:0]; end
        // Timer data registers (16-bit; also allow high-byte access)
        8'h80: if (width != BYTE) TM0 <= data; else TM0[7:0] <= data[7:0];
        8'h81: TM0[15:8] <= data[7:0];
        8'h82: if (width != BYTE) MD0 <= data; else MD0[7:0] <= data[7:0];
        8'h83: MD0[15:8] <= data[7:0];
        8'h88: if (width != BYTE) TM1 <= data; else TM1[7:0] <= data[7:0];
        8'h89: TM1[15:8] <= data[7:0];
        8'h8a: if (width != BYTE) MD1 <= data; else MD1[7:0] <= data[7:0];
        8'h8b: MD1[15:8] <= data[7:0];
        // Timer control registers
        8'h90: TMC0 <= data[7:0];
        8'h91: TMC1 <= data[7:0];
        // Timer interrupt-control registers
        8'h9c: begin TMIC0.cpu_set <= 1; TMIC0.cpu_value <= data[7:0]; end
        8'h9d: begin TMIC1.cpu_set <= 1; TMIC1.cpu_value <= data[7:0]; end
        8'h9e: begin TMIC2.cpu_set <= 1; TMIC2.cpu_value <= data[7:0]; end
        8'heb: sfr.PRC <= data[7:0];
        8'hff: sfr.IDB <= data[7:0];
        default: begin end
        endcase
    end else if (RAMEN && phys_addr[19:8] == { sfr.IDB, 4'he }) begin
        if (width == BYTE) begin
            if (phys_addr[0]) internal_ram_hi[phys_addr[7:1]] <= data[7:0];
            else              internal_ram_lo[phys_addr[7:1]] <= data[7:0];
        end else if (phys_addr[0]) begin
            // unaligned word: low byte at odd addr (hi bank), high byte at next even (lo bank, idx+1)
            internal_ram_hi[phys_addr[7:1]]          <= data[7:0];
            internal_ram_lo[phys_addr[7:1] + 7'd1]   <= data[15:8];
        end else begin
            // aligned word
            internal_ram_lo[phys_addr[7:1]] <= data[7:0];
            internal_ram_hi[phys_addr[7:1]] <= data[15:8];
        end
    end else begin
        dp_addr <= phys_addr;
        dp_dout <= data;
        dp_write <= 1;
        dp_io <= 0;
        dp_wide <= width == BYTE ? 0 : 1;
        dp_req <= 1;
    end
endtask

task read_memory(input bit [15:0] addr, input sreg_index_e seg, input width_e width);
    bit [19:0] phys_addr;
    phys_addr = calc_physical_addr(seg, addr);

    bcu_read <= 0;

    if (phys_addr[19:0] == 20'hfffff) begin
        internal_din <= { 8'h0, sfr.IDB };
    end else if (phys_addr[19:8] == { sfr.IDB, 4'hf }) begin
        case(phys_addr[7:0])
        8'h50: internal_din <= { 8'h0, sfr.INTM };
        8'h4c: internal_din <= { 8'h0, EXIC0.value };
        8'h4d: internal_din <= { 8'h0, EXIC1.value };
        8'h4e: internal_din <= { 8'h0, EXIC2.value };
        8'h80: internal_din <= TM0;
        8'h82: internal_din <= MD0;
        8'h88: internal_din <= TM1;
        8'h8a: internal_din <= MD1;
        8'h9c: internal_din <= { 8'h0, TMIC0.value };
        8'h9d: internal_din <= { 8'h0, TMIC1.value };
        8'h9e: internal_din <= { 8'h0, TMIC2.value };
        8'heb: internal_din <= { 8'h0, sfr.PRC };
        8'hfc: internal_din <= { 8'h0, ISPR };
        8'hff: internal_din <= { 8'h0, sfr.IDB };
        default: internal_din <= 16'hf00d;
        endcase
    end else if (RAMEN && phys_addr[19:8] == { sfr.IDB, 4'he }) begin
        if (width == BYTE)
            internal_din <= phys_addr[0] ? { 8'h0, internal_ram_hi[phys_addr[7:1]] }
                                         : { 8'h0, internal_ram_lo[phys_addr[7:1]] };
        else if (phys_addr[0])
            // unaligned word: low byte from hi[idx], high byte from lo[idx+1]
            internal_din <= { internal_ram_lo[phys_addr[7:1] + 7'd1], internal_ram_hi[phys_addr[7:1]] };
        else
            // aligned word
            internal_din <= { internal_ram_hi[phys_addr[7:1]], internal_ram_lo[phys_addr[7:1]] };
    end else begin
        dp_addr <= phys_addr;
        dp_write <= 0;
        dp_io <= 0;
        dp_wide <= width == BYTE ? 0 : 1;
        dp_req <= 1;
        bcu_read <= 1;
    end
endtask

task write_io(input bit [15:0] addr, input width_e width, input [15:0] data);
    dp_addr <= {4'd0, addr};
    dp_dout <= data;
    dp_write <= 1;
    dp_io <= 1;
    dp_wide <= width == BYTE ? 0 : 1;
    dp_req <= 1;
endtask

task read_io(input bit [15:0] addr, input width_e width);
    dp_addr <= {4'd0, addr};
    dp_write <= 0;
    dp_io <= 1;
    dp_wide <= width == BYTE ? 0 : 1;
    dp_req <= 1;
    bcu_read <= 1;
endtask


function bit [15:0] get_operand(nec_decode_t dec, operand_e operand);
    if (dec.width == BYTE) begin
        case(operand)
        OPERAND_ACC: return { 8'd0, reg_aw[7:0] };
        OPERAND_IMM: return { 8'd0, dec.imm[7:0] };
        OPERAND_IMM8: return { 8'd0, dec.imm[7:0] };
        OPERAND_IMM_EXT: return { {8{dec.imm[7]}}, dec.imm[7:0] };
        OPERAND_MODRM: begin
            if (dec.mod == 2'b11)
                return { 8'd0, get_reg8(reg8_index_e'(dec.rm)) };
            else
                return { 8'd0, mem_din[7:0] };
        end
        OPERAND_IO_DIRECT,
        OPERAND_IO_INDIRECT: return { 8'd0, mem_din[7:0] };
        OPERAND_REG_0: return { 8'd0, get_reg8(reg8_index_e'(dec.reg0)) };
        OPERAND_REG_1: return { 8'd0, get_reg8(reg8_index_e'(dec.reg1)) };
        OPERAND_CL: return { 8'd0, reg_cw[7:0] };
        default: return 16'hffff;
        endcase
    end else begin
        case(operand)
        OPERAND_ACC: return reg_aw;
        OPERAND_IMM: return dec.imm[15:0];
        OPERAND_IMM8: return { 8'd0, dec.imm[7:0] };
        OPERAND_IMM_EXT: return { {8{dec.imm[7]}}, dec.imm[7:0] };
        OPERAND_MODRM: begin
            if (dec.mod == 2'b11)
                return get_reg16(reg16_index_e'(dec.rm));
            else
                return mem_din;
        end
        OPERAND_IO_DIRECT,
        OPERAND_IO_INDIRECT: return { mem_din[15:0] };
        OPERAND_SREG: begin
            case(dec.sreg)
            DS0: return reg_ds0;
            DS1: return reg_ds1;
            SS: return reg_ss;
            PS: return reg_ps;
            endcase
        end
        OPERAND_REG_0: return get_reg16(reg16_index_e'(dec.reg0));
        OPERAND_REG_1: return get_reg16(reg16_index_e'(dec.reg1));
        OPERAND_CL: return { 8'd0, reg_cw[7:0] };
        default: return 16'hffff;
        endcase
    end
    return 16'hfefe;
endfunction

task load_operands(input nec_decode_t dec);
    op_result <= get_operand(dec, dec.source0);
    TA <= get_operand(dec, dec.source0);
    TB <= get_operand(dec, dec.source1);

    alu_operation <= ALU_OP_NONE;
    alu_wide <= dec.width == WORD;
    use_alu_result <= 1;

    case(dec.opcode)
        OP_ALU: begin
            alu_operation <= dec.alu_operation;
        end

        default: begin
            use_alu_result <= 0;
        end
    endcase
endtask


task shifter(shift_operation_e op, bit wide, bit single);
    bit calc_flags;
    bit [15:0] res;
    bit V;

    calc_flags = 0;

    V = flags.V;

    case(op)
        SHIFT_OP_ROL: begin
            if (wide) begin
                res = {TA[14:0], TA[15]};
                flags.CY <= TA[15];
                V = TA[15] ^ TA[14];
            end else begin
                res[7:0] = {TA[6:0], TA[7]};
                flags.CY <= TA[7];
                V = TA[7] ^ TA[6];
            end
        end

        SHIFT_OP_ROLC: begin
            if (wide) begin
                res = {TA[14:0], flags.CY};
                flags.CY <= TA[15];
                V = TA[15] ^ TA[14];
            end else begin
                res[7:0] = {TA[6:0], flags.CY};
                flags.CY <= TA[7];
                V = TA[7] ^ TA[6];
            end
        end

        SHIFT_OP_ROR: begin
            flags.CY <= TA[0];
            if (wide) begin
                res = {TA[0], TA[15:1]};
                V = TA[15] ^ TA[0];
            end else begin
                res[7:0] = {TA[0], TA[7:1]};
                V = TA[7] ^ TA[0];
            end
        end

        SHIFT_OP_RORC: begin
            flags.CY <= TA[0];
            if (wide) begin
                res = {flags.CY, TA[15:1]};
                V = TA[15] ^ flags.CY;
            end else begin
                res[7:0] = {flags.CY, TA[7:1]};
                V = TA[7] ^ flags.CY;
            end
        end

        SHIFT_OP_SHL: begin
            if (wide) begin
                flags.CY <= TA[15];
                V = TA[15] ^ TA[14];
                res = { TA[14:0], 1'b0 };
            end else begin
                flags.CY <= TA[7];
                V = TA[7] ^ TA[6];
                res[7:0] = { TA[6:0], 1'b0 };
            end
            calc_flags = 1;
        end

        SHIFT_OP_SHR: begin
            if (wide) begin
                flags.CY <= TA[0];
                V = TA[15];
                res = { 1'b0, TA[15:1] };
            end else begin
                flags.CY <= TA[0];
                V = TA[7];
                res[7:0] = { 1'b0, TA[7:1] };
            end
            calc_flags = 1;
        end

        SHIFT_OP_SHRA: begin
            if (wide) begin
                flags.CY <= TA[0];
                V = 0;
                res = { TA[15], TA[15:1] };
            end else begin
                flags.CY <= TA[0];
                V = 0;
                res[7:0] = { TA[7], TA[7:1] };
            end
            calc_flags = 1;
        end

        default: begin
        end
    endcase

    if (calc_flags) begin
        flags.P <= ~(res[0] ^ res[1] ^ res[2] ^ res[3] ^ res[4] ^ res[5] ^ res[6] ^ res[7]);
        flags.S <= wide ? res[15] : res[7];
        flags.Z <= wide ? res[15:0] == 16'd0 : res[7:0] == 8'd0;
    end

    if (single) flags.V <= V;

    op_result <= res;
    TA <= res;
endtask

task handle_branch(input nec_decode_t dec);
    case(dec.opcode)
        OP_B_COND: begin
            bit cond = 0;
            case(dec.cond)
            4'b0000: cond = flags.V; /* V */
            4'b0001: cond = ~flags.V; /* NV */
            4'b0010: cond = flags.CY; /* C/L */
            4'b0011: cond = ~flags.CY; /* NC/NL */
            4'b0100: cond = flags.Z; /* E/Z */
            4'b0101: cond = ~flags.Z; /* NE/NZ */
            4'b0110: cond = (flags.CY | flags.Z); /* NH */
            4'b0111: cond = ~(flags.CY | flags.Z); /* H */
            4'b1000: cond = flags.S; /* N */
            4'b1001: cond = ~flags.S; /* P */
            4'b1010: cond = flags.P; /* PE */
            4'b1011: cond = ~flags.P; /* PO */
            4'b1100: cond = (flags.S ^ flags.V); /* LT */
            4'b1101: cond = ~(flags.S ^ flags.V); /* GE */
            4'b1110: cond = (flags.S ^ flags.V) | flags.Z; /* LE */
            4'b1111: cond = ~((flags.S ^ flags.V) | flags.Z); /* GT */
            endcase

            if (cond) begin
                next_pc <= dec.end_pc + get_operand(dec, dec.source0);
                set_pc <= 1;
                state <= IDLE;
            end else begin
                state <= EXECUTE;
            end
        end

        OP_B_CW_COND: begin
            bit cond = 0;
            case(dec.cond)
            4'b0000: begin
                reg_cw <= reg_cw - 16'd1;
                cond = reg_cw != 16'd1 && ~flags.Z;
            end
            4'b0001: begin
                reg_cw <= reg_cw - 16'd1;
                cond = reg_cw != 16'd1 && flags.Z;
            end
            4'b0010: begin
                reg_cw <= reg_cw - 16'd1;
                cond = reg_cw != 16'd1;
            end
            4'b0011: cond = (reg_cw == 0);
            default: begin
            end
            endcase

            if (cond) begin
                next_pc <= dec.end_pc + TA;
                set_pc <= 1;
                state <= IDLE;
            end else begin
                state <= EXECUTE;
            end
        end

        OP_BR_REL: begin
            next_pc <= dec.end_pc + TA;
            set_pc <= 1;
            state <= IDLE;
        end

        OP_BR_ABS: begin
            if (dec.source0 == OPERAND_IMM && dec.width == DWORD) begin
                next_pc <= dec.imm[15:0];
                reg_ps <= dec.imm[31:16];
            end else if (dec.width == WORD) begin
                next_pc <= TA;
            end else if (dec.source0 == OPERAND_MODRM && dec.width == DWORD) begin
                next_pc <= TA;
                reg_ps <= TB;
            end
            set_pc <= 1;
            state <= IDLE;
        end

        OP_RET: begin
            set_pc <= 1;
            state <= IDLE;
        end

        OP_RET_POP_VALUE: begin
            reg_sp <= reg_sp + TA;
            set_pc <= 1;
            state <= IDLE;
        end

        default: begin
        end
    endcase
endtask



reg [7:0] interrupt_vector;
reg brkn_pending;   // set by OP_BRKN so INT_FETCH_VEC switches to native mode after the push
wire bcu_intreq;
wire bcu_intack;
wire [7:0] bcu_intvec;
wire block_prefetch;
wire bcu_intack_cycle;

bus_control_unit_v35 BCU(
    .clk, .ce_1, .ce_2,
    .reset, .ready,
    .n_ube, .r_w,
    .n_iostb, .n_mreq, .n_mstb,
    .addr, .dout, .din,

    .reg_ps,

    .pfp_set(set_pc), .block_prefetch,
    .ipq, .ipq_head(set_pc ? next_pc : cur_pc), .ipq_len,

    .dp_addr, .dp_dout, .dp_din(bcu_din),
    .dp_write, .dp_wide, .dp_io, .dp_req,
    .dp_ready,

    .intreq(bcu_intreq), .intack(bcu_intack), .intvec(bcu_intvec),
    .intack_cycle(bcu_intack_cycle),

    .implementation_fault()
);

wire retire_op /* verilator public */ = state == IDLE && next_decode_valid && dp_ready;
wire is_idle /* verilator public */ = (state == IDLE);
wire next_decode_valid;
nec_decode_t next_decode;

nec_decode nec_decode(
    .clk, .ce_1, .ce_2,
    .ipq_len,
    .ipq,
    .new_pc(next_pc), .set_pc,
    .pc(cur_pc),
    .valid(next_decode_valid),
    .decoded(next_decode),
    .retire_op,
    .block_prefetch,

    .secure(secure & ~flags.MD),   // native mode (MD=1) executes un-decrypted; MAME: decrypt only when MF==0
    .secure_wr,
    .secure_addr,
    .secure_byte
);

alu_operation_e alu_operation;
wire [15:0] alu_result;
flags_t alu_flags_result;
reg use_alu_result;
reg alu_wide;
wire [9:0] alu_delay;

alu ALU(
    .clk,

    .operation(alu_operation),
    .ta(TA),
    .tb(TB),
    .result(alu_result),
    .wide(alu_wide),

    .delay(alu_delay),

    .flags_in(flags),
    .flags(alu_flags_result)
);

reg div_start, div_wide, div_signed;
wire div_done, div_overflow, div_dbz;
reg [32:0] div_num, div_denom;
wire [15:0] div_quot, div_rem;

nec_divider divider(
    .clk, .ce(ce_1 | ce_2),
    .reset,
    .start(div_start),
    .done(div_done),
    .overflow(div_overflow),
    .dbz(div_dbz),
    .wide(div_wide),
    .a(div_num),
    .b(div_denom),
    .quot(div_quot),
    .rem(div_rem)
);

cpu_state_e state /* verilator public */;

assign bcu_intreq = state == INT_ACK_WAIT;

reg int_processing;
reg [15:0] calculated_ea;
reg [15:0] op_result;
reg [15:0] op_result_high;

reg [15:0] branch_new_pc;
reg [15:0] branch_new_ps;

reg [3:0] exec_stage;
reg [7:0] shift_count;

reg [15:0] push_list;
reg [15:0] pop_list;
reg [15:0] push_sp_save;
reg pop_store;

reg [4:0] prepare_nesting_level;
reg [15:0] prepare_sp_save;

reg [6:0] bcd_offset;
reg [4:0] bcd_acc_high, bcd_acc_low;
reg [7:0] bcd_acc, bcd_src;
reg [4:0] bcd_result_high, bcd_result_low;

reg stack_modified_pc, stack_modified_ps;

reg [9:0] cycles;
reg [9:0] op_delay;
reg [9:0] exec_delay;

// EXT and INS storage
reg [15:0] bitfield_addr;
reg [15:0] bitfield_mask;
reg [15:0] bitfield_out;
width_e bitfield_width;
reg [2:0] bitfield_shift;

reg fint;

always_ff @(posedge clk) begin
    bit [15:0] addr;
    bit [31:0] result32;
    bit [15:0] temp;
    bit [15:0] src;
    bit [7:0] temp8;
    bit [9:0] delay;

    delay = 0;

    if (reset) begin
        dp_req <= 0;
        reg_ps <= 16'hffff;
        reg_ss <= 16'd0;
        reg_ds0 <= 16'd0;
        reg_ds1 <= 16'd0;
        next_pc <= 16'd0;
        set_pc <= 1;

        bcu_read <= 0;
        
        reg_aw <= 16'd0;
        reg_bw <= 16'd0;
        reg_cw <= 16'd0;
        reg_dw <= 16'd0;
        reg_sp <= 16'd0;
        reg_bp <= 16'd0;
        reg_ix <= 16'd0;
        reg_iy <= 16'd0;

        flags.V <= 0;
        flags.S <= 0;
        flags.Z <= 0;
        flags.AC <= 0;
        flags.P <= 0;
        flags.CY <= 0;
        flags.MD <= ~secure;   // secure game boots in secure mode (MD=0 -> decrypt); MAME: MF=table?0:1
        flags.DIR <= 0;
        flags.IE <= 0;
        flags.BRK <= 0;
        brkn_pending <= 0;

        sfr.IDB <= 8'hcc;
        sfr.PRC <= 8'h4e;
        sfr.INTM <= 8'h00;

        TM0 <= 16'd0; MD0 <= 16'd0;
        TM1 <= 16'd0; MD1 <= 16'd0;
        TMC0 <= 8'd0; TMC1 <= 8'd0;

        state <= IDLE;
        int_processing <= 0;
        use_alu_result <= 0;

        stack_modified_pc <= 0;
        stack_modified_ps <= 0;

        halt <= 0;
    end else if (ce_1 | ce_2) begin
        div_start <= 0;
        set_pc <= 0;
        dp_req <= 0;

        if (ce_1) fint <= 0;

        EXIC0.cpu_set <= 0;
        EXIC1.cpu_set <= 0;
        EXIC2.cpu_set <= 0;
        TMIC0.cpu_set <= 0;
        TMIC1.cpu_set <= 0;
        TMIC2.cpu_set <= 0;

        case(state)
            IDLE: if (ce_1) begin
                use_alu_result <= 0;
                stack_modified_pc <= 0;
                stack_modified_ps <= 0;

                exec_stage <= 4'd0;
                exec_delay <= 10'd0;
                shift_count <= 8'd0;

                if (dp_ready) begin
                    op_delay <= 10'd0;
                    cycles <= 10'd0;

                    if (pic_intreq & flags.IE) begin
                        state <= INT_ACK_WAIT;
                    end else if (next_decode_valid) begin
                        decoded <= next_decode;
                        cur_opcode <= next_decode.opcode;
                        push_sp_save <= reg_sp;
                        push_list <= next_decode.push;
                        pop_list <= next_decode.pop;

                        next_pc <= cur_pc;

                        calculated_ea <= calc_ea(next_decode);

                        load_operands(next_decode);

                        if (next_decode.mem_read && next_decode.opcode != OP_LDEA)
                            state <= FETCH_OPERAND;
                        else if (next_decode.push != 16'd0)
                            state <= PUSH;
                        else if (next_decode.pop != 16'd0) begin
                            if (dp_ready) begin
                                read_memory(reg_sp, SS, WORD);
                                reg_sp <= reg_sp + 16'd2;
                                state <= POP_WAIT;
                            end else begin
                                state <= POP;
                            end
                        end else if (next_decode.opclass == BRANCH)
                            state <= BRANCHING;
                        else
                            state <= EXECUTE;
                    end
                end
            end // IDLE

            FETCH_OPERAND: if (ce_1 & dp_ready) begin
                if (decoded.io)
                    read_io(calculated_ea, decoded.width);
                else
                    read_memory(calculated_ea, decoded.segment, decoded.width);
                state <= WAIT_OPERAND1;
            end

            WAIT_OPERAND1: if (ce_1 & dp_ready) begin
                load_operands(decoded);
                if (decoded.width == DWORD) begin
                    read_memory(calculated_ea + 16'd2, decoded.segment, WORD);
                    state <= WAIT_OPERAND2;
                end else begin
                    if (push_list != 16'd0)
                        state <= PUSH;
                    else if (pop_list != 16'd0)
                        state <= POP;
                    else if (decoded.opclass == BRANCH)
                        state <= BRANCHING;
                    else if (decoded.opcode == OP_MOV)
                        state <= EXECUTE;
                    else
                        state <= EXECUTE_STALL;
                end
            end

            WAIT_OPERAND2: if (ce_1 & dp_ready) begin
                TB <= mem_din;

                if (push_list != 16'd0)
                    state <= PUSH;
                else if (pop_list != 16'd0)
                    state <= POP;
                else if (decoded.opclass == BRANCH)
                    state <= BRANCHING;
                else
                    state <= EXECUTE;
            end // WAIT_OPERAND2

            BRANCHING: if (ce_2) begin
                handle_branch(decoded);
            end

            INT_ACK_WAIT: if (ce_1) begin
                if (bcu_intack) begin
                    interrupt_vector <= pic_intvec;
                    state <= INT_INITIATE;
                end
            end // INT_ACK_WAIT

            INT_INITIATE: if (ce_1) begin
                push_list <= STACK_PC | STACK_PS | STACK_PSW;
                state <= PUSH;
                int_processing <= 1;
            end

            INT_FETCH_VEC: if (dp_ready & ce_1) begin
                flags.IE <= 0;
                flags.BRK <= 0;
                if (brkn_pending) flags.MD <= 1;   // BRKN: enter native mode (after PSW pushed)
                brkn_pending <= 0;
                dp_addr <= { 10'd0, interrupt_vector[7:0], 2'b00 };
                dp_write <= 0;
                dp_io <= 0;
                dp_wide <= 1;
                dp_req <= 1;
                bcu_read <= 1;
                state <= INT_FETCH_WAIT1;
            end

            INT_FETCH_WAIT1: if (dp_ready & ce_1) begin
                next_pc <= mem_din;
                dp_addr <= { 10'd0, interrupt_vector[7:0], 2'b10 };
                dp_req <= 1;
                bcu_read <= 1;
                state <= INT_FETCH_WAIT2;
            end

            INT_FETCH_WAIT2: if (dp_ready & ce_1) begin
                reg_ps <= mem_din;
                set_pc <= 1;
                int_processing <= 0;
                state <= IDLE;
            end

            EXECUTE_STALL: if (ce_1) begin
                state <= EXECUTE;
            end

            EXECUTE: begin
                bit working;
                bit exception;
                bit check_interrupt;
                bit block_run;

                if (dp_ready & ce_1 & |exec_delay & ~turbo) begin
                    exec_delay <= exec_delay - 10'd1;
                end else if (dp_ready & ce_1) begin
                    working = 0;
                    exception = 0;
                    check_interrupt = 0;
                    
                    exec_stage <= exec_stage + 4'd1;

                    case(decoded.opcode)
                        OP_NOP: begin
                            delay = 1;
                        end

                        OP_POPR: begin
                            delay = 1;
                        end

                        OP_PUSH,
                        OP_PUSHR,
                        OP_POP: begin
                        end

                        OP_B_COND,
                        OP_B_CW_COND: begin
                            delay = 1;
                        end

                        OP_NOT1_CY:  flags.CY <= ~flags.CY;
                        OP_CLR1_CY:  flags.CY <= 0;
                        OP_SET1_CY:  flags.CY <= 1;
                        OP_DI:       flags.IE <= 0;
                        OP_EI:       flags.IE <= 1;
                        OP_CLR1_DIR: flags.DIR <= 0;
                        OP_SET1_DIR: flags.DIR <= 1;
                        OP_HALT:     halt <= 1;

                        OP_CVTWL: reg_dw <= reg_aw[15] ? 16'hffff : 16'h0000;
                        OP_CVTBW: reg_aw[15:8] <= reg_aw[7] ? 8'hff : 8'h00;

                        OP_CVTBD: begin
                            if (exec_stage == 0) begin
                                div_signed <= 0;
                                div_wide <= 0;
                                div_start <= 1;
                                div_num <= { 25'd0, reg_aw[7:0] };
                                div_denom <= 33'd10;
                                working = 1;
                                delay = 11;
                            end else begin
                                if (div_done) begin
                                    reg_aw[15:8] <= div_quot[7:0];
                                    reg_aw[7:0] <= div_rem[7:0];
                                    flags.Z <= ~(|{div_quot[7:0], div_rem[7:0]});
                                    flags.S <= div_rem[7];
                                    flags.P <= ~(^div_rem[7:0]);
                                end else begin
                                    working = 1;
                                    exec_stage <= exec_stage;
                                end
                            end
                        end

                        OP_CVTDB: begin
                            temp8 = reg_aw[7:0] + (reg_aw[15:8] * 8'd10);
                            flags.Z <= ~|temp8;
                            flags.S <= temp8[7];
                            flags.P <= ~(^temp8);
                            reg_aw <= { 8'd0, temp8 };
                            delay = 8;
                        end

                        OP_MOV: begin
                            op_result <= TA;
                        end

                        OP_MOV_SEG: begin
                            set_reg16(reg16_index_e'(decoded.reg0), TA);
                            set_sreg(sreg_index_e'(decoded.sreg), TB);
                            delay = 10'd2;
                        end

                        OP_MOV_PSW_AH: begin
                            flags.CY  <= reg_aw[8];
                            flags.P   <= reg_aw[10];
                            flags.AC  <= reg_aw[12];
                            flags.Z   <= reg_aw[14];
                            flags.S   <= reg_aw[15];
                        end

                        OP_MOV_AH_PSW: begin
                            reg_aw[15:8]  <= reg_psw[7:0];
                        end

                        OP_LDEA: begin
                            delay = 1;
                            op_result <= calculated_ea;
                        end

                        OP_XCH: begin
                            op_result <= TA;
                            delay = decoded.mem_read ? 3 : 1;
                            if (decoded.width == BYTE) begin
                                set_reg8(reg8_index_e'(decoded.reg0), TB[7:0]);
                            end else begin
                                set_reg16(reg16_index_e'(decoded.reg0), TB);
                            end
                        end

                        OP_ALU: begin
                        end

                        OP_STM: begin
                            block_run = 1;
                            if (decoded.rep != REPEAT_NONE) begin
                                if (reg_cw == 16'd0) begin
                                    block_run = 0;
                                end else begin
                                    reg_cw <= reg_cw - 16'd1;
                                    working = reg_cw == 16'd1 ? 0 : 1;
                                    check_interrupt = 1;
                                end
                                delay = 1;
                            end else begin
                                delay = 3;
                            end

                            if (block_run) begin
                                write_memory(reg_iy, DS1, decoded.width, reg_aw);
                                if (flags.DIR)
                                    reg_iy <= reg_iy - ( decoded.width == BYTE ? 16'd1 : 16'd2 );
                                else
                                    reg_iy <= reg_iy + ( decoded.width == BYTE ? 16'd1 : 16'd2 );
                            end


                        end

                        OP_LDM: begin
                            if (exec_stage == 0) begin
                                working = 1;
                                if (decoded.rep != REPEAT_NONE) begin
                                    if (reg_cw == 16'd0) begin
                                        working = 0;
                                    end else begin
                                        reg_cw <= reg_cw - 16'd1;
                                    end
                                end
                            end else if (exec_stage == 1) begin
                                read_memory(reg_ix, decoded.segment, decoded.width);
                                working = 1;
                            end else begin
                                working = 1;
                                if (decoded.width == BYTE)
                                    reg_aw[7:0] <= mem_din[7:0];
                                else
                                    reg_aw <= mem_din;

                                if (flags.DIR) begin
                                    reg_ix <= reg_ix - ( decoded.width == BYTE ? 16'd1 : 16'd2 );
                                end else begin
                                    reg_ix <= reg_ix + ( decoded.width == BYTE ? 16'd1 : 16'd2 );
                                end
                                exec_stage <= 1;

                                if (decoded.rep != REPEAT_NONE) begin
                                    if (reg_cw == 16'd0) begin
                                        working = 0;
                                        delay = 3;
                                    end else begin
                                        reg_cw <= reg_cw - 16'd1;
                                    end
                                    check_interrupt = 1;
                                end else begin
                                    delay = 2;
                                    working = 0;
                                end
                            end
                        end

                        OP_MOVBK: begin
                            if (exec_stage == 0) begin
                                block_run = 1;
                                if (decoded.rep != REPEAT_NONE) begin
                                    if (reg_cw == 16'd0) begin
                                        block_run = 0;
                                    end else begin
                                        reg_cw <= reg_cw - 16'd1;
                                    end
                                end

                                if (block_run) begin
                                    read_memory(reg_ix, decoded.segment, decoded.width);
                                    working = 1;
                                end
                            end else begin
                                write_memory(reg_iy, DS1, decoded.width, mem_din);
                                if (flags.DIR) begin
                                    reg_iy <= reg_iy - ( decoded.width == BYTE ? 16'd1 : 16'd2 );
                                    reg_ix <= reg_ix - ( decoded.width == BYTE ? 16'd1 : 16'd2 );
                                end else begin
                                    reg_iy <= reg_iy + ( decoded.width == BYTE ? 16'd1 : 16'd2 );
                                    reg_ix <= reg_ix + ( decoded.width == BYTE ? 16'd1 : 16'd2 );
                                end
                                exec_stage <= 0;

                                if (decoded.rep != REPEAT_NONE) begin
                                    working = reg_cw != 16'd0;
                                    check_interrupt = 1;
                                    delay = 2;
                                end else begin
                                    delay = 3;
                                end
                            end
                        end
                        OP_CMPBK: begin
                            if (exec_stage == 0) begin
                                block_run = 1;
                                if (decoded.rep != REPEAT_NONE) begin
                                    if (reg_cw == 16'd0) begin
                                        block_run = 0;
                                    end else begin
                                        reg_cw <= reg_cw - 16'd1;
                                    end
                                end

                                if (block_run) begin
                                    read_memory(reg_ix, decoded.segment, decoded.width);
                                    working = 1;
                                end
                            end else if (exec_stage == 1) begin
                                TA <= decoded.width == WORD ? mem_din : { 8'd0, mem_din[7:0] };
                                read_memory(reg_iy, DS1, decoded.width);
                                working = 1;
                                if (flags.DIR) begin
                                    reg_iy <= reg_iy - ( decoded.width == BYTE ? 16'd1 : 16'd2 );
                                    reg_ix <= reg_ix - ( decoded.width == BYTE ? 16'd1 : 16'd2 );
                                end else begin
                                    reg_iy <= reg_iy + ( decoded.width == BYTE ? 16'd1 : 16'd2 );
                                    reg_ix <= reg_ix + ( decoded.width == BYTE ? 16'd1 : 16'd2 );
                                end
                            end else if (exec_stage == 2) begin
                                TB <= decoded.width == WORD ? mem_din : { 8'd0, mem_din[7:0] };
                                alu_operation <= ALU_OP_CMP;
                                alu_wide <= decoded.width == WORD ? 1 : 0;
                                working = 1;
                            end else if (exec_stage == 3) begin
                                working = 1;
                                flags <= alu_flags_result;
                                exec_stage <= 0;
                                if (decoded.rep != REPEAT_NONE) begin
                                    delay = 3;
                                    if (reg_cw == 16'd0) working = 0;
                                    else if (decoded.rep == REPEAT_NZ) working = ~alu_flags_result.Z;
                                    else if (decoded.rep == REPEAT_Z) working = alu_flags_result.Z;
                                    else if (decoded.rep == REPEAT_NC) working = ~alu_flags_result.CY;
                                    else if (decoded.rep == REPEAT_C) working = alu_flags_result.CY;
                                    check_interrupt = 1;
                                end else begin
                                    delay = 5;
                                    working = 0;
                                end
                            end
                        end

                        OP_CMPM: begin
                            if (exec_stage == 0) begin
                                block_run = 1;
                                if (decoded.rep != REPEAT_NONE) begin
                                    if (reg_cw == 16'd0) begin
                                        block_run = 0;
                                    end else begin
                                        reg_cw <= reg_cw - 16'd1;
                                    end
                                end

                                if (block_run) begin
                                    read_memory(reg_iy, DS1, decoded.width);
                                    working = 1;
                                end
                            end else if (exec_stage == 1) begin
                                TA <= decoded.width == WORD ? reg_aw : { 8'd0, reg_aw[7:0] };
                                TB <= decoded.width == WORD ? mem_din : { 8'd0, mem_din[7:0] };;
                                alu_operation <= ALU_OP_CMP;
                                alu_wide <= decoded.width == WORD ? 1 : 0;
                                working = 1;
                                if (flags.DIR) begin
                                    reg_iy <= reg_iy - ( decoded.width == BYTE ? 16'd1 : 16'd2 );
                                end else begin
                                    reg_iy <= reg_iy + ( decoded.width == BYTE ? 16'd1 : 16'd2 );
                                end
                            end else if (exec_stage == 2) begin
                                working = 1;
                                flags <= alu_flags_result;
                                exec_stage <= 0;
                                if (decoded.rep != REPEAT_NONE) begin
                                    if (reg_cw == 16'd0) working = 0;
                                    else if (decoded.rep == REPEAT_NZ) working = ~alu_flags_result.Z;
                                    else if (decoded.rep == REPEAT_Z) working = alu_flags_result.Z;
                                    else if (decoded.rep == REPEAT_NC) working = ~alu_flags_result.CY;
                                    else if (decoded.rep == REPEAT_C) working = alu_flags_result.CY;
                                    check_interrupt = 1;
                                end else begin
                                    working = 0;
                                end
                            end
                        end

                        OP_INM,
                        OP_OUTM: begin
                            if (exec_stage == 0) begin
                                block_run = 1;
                                if (decoded.rep != REPEAT_NONE) begin
                                    if (reg_cw == 16'd0) begin
                                        block_run = 0;
                                    end else begin
                                        reg_cw <= reg_cw - 16'd1;
                                    end
                                end

                                if (block_run) begin
                                    if (decoded.opcode == OP_INM)
                                        read_io(reg_dw, decoded.width);
                                    else
                                        read_memory(reg_ix, decoded.segment, decoded.width);
                                    working = 1;
                                end
                            end else begin
                                if (decoded.opcode == OP_INM) begin
                                    write_memory(reg_iy, DS1, decoded.width, mem_din);
                                    if (flags.DIR) begin
                                        reg_iy <= reg_iy - ( decoded.width == BYTE ? 16'd1 : 16'd2 );
                                    end else begin
                                        reg_iy <= reg_iy + ( decoded.width == BYTE ? 16'd1 : 16'd2 );
                                    end
                                end else begin
                                    write_io(reg_dw, decoded.width, mem_din);
                                    if (flags.DIR) begin
                                        reg_ix <= reg_ix - ( decoded.width == BYTE ? 16'd1 : 16'd2 );
                                    end else begin
                                        reg_ix <= reg_ix + ( decoded.width == BYTE ? 16'd1 : 16'd2 );
                                    end
                                end
                                exec_stage <= 0;

                                if (decoded.rep != REPEAT_NONE) begin
                                    working = reg_cw != 16'd0;
                                    check_interrupt = 1;
                                    delay = 7;
                                end else begin
                                    delay = 8;
                                end
                            end
                        end

                        OP_SHIFT: begin
                            if (shift_count != TB[7:0]) begin
                                shifter(decoded.shift, decoded.width == WORD, 0);
                                shift_count <= shift_count + 8'd1;
                                working = 1;
                            end else begin
                                delay = 2;
                            end
                        end

                        OP_SHIFT1: begin
                            shifter(decoded.shift, decoded.width == WORD, 1);
                        end


                        // TODO OUTM, INM
                        
                        OP_DIV,
                        OP_DIVU: begin
                            bit [15:0] operand;
                            operand = TA;

                            if (exec_stage == 0) begin
                                div_start <= 1;
                                if (decoded.opcode == OP_DIVU) begin
                                    if (decoded.width == BYTE) begin
                                        delay = 11;
                                        div_wide <= 0;
                                        div_num <= { 17'd0, reg_aw };
                                        div_denom <= { 25'd0, operand[7:0] };
                                    end else begin
                                        delay = 19;
                                        div_wide <= 1;
                                        div_num <= { 1'd0, reg_dw, reg_aw };
                                        div_denom <= { 17'd0, operand[15:0] };
                                    end
                                end else begin
                                    if (decoded.width == BYTE) begin
                                        delay = 15;
                                        div_wide <= 0;
                                        div_num <= { {17{reg_aw[15]}}, reg_aw };
                                        div_denom <= { {25{operand[7]}}, operand[7:0] };
                                    end else begin
                                        delay = 23;
                                        div_wide <= 1;
                                        div_num <= { reg_dw[15], reg_dw, reg_aw };
                                        div_denom <= { {17{operand[15]}}, operand[15:0] };
                                    end
                                end
                                working = 1;
                            end else begin
                                if (div_done) begin
                                    if (decoded.width == BYTE) begin
                                        if (div_dbz | div_overflow) begin
                                            interrupt_vector <= 8'd0;
                                            exception = 1;
                                        end else begin
                                            reg_aw <= { div_rem[7:0], div_quot[7:0] };
                                        end
                                    end else begin
                                        if (div_dbz | div_overflow) begin
                                            interrupt_vector <= 8'd0;
                                            exception = 1;
                                        end else begin
                                            reg_aw <= div_quot[15:0];
                                            reg_dw <= div_rem[15:0];
                                        end
                                    end
                                end else begin
                                    working = 1;
                                    exec_stage <= exec_stage;
                                end
                            end
                        end

                        OP_MULU: begin
                            flags.CY <= 0;
                            flags.V <= 0;
                            result32 = TA * TB;
                            if (decoded.width == WORD) begin
                                flags.CY <= |result32[31:16];
                                flags.V <= |result32[31:16];
                                delay = 12;
                            end else begin
                                flags.CY <= |result32[31:8];
                                flags.V <= |result32[31:8];
                                delay = 8;
                            end
                            op_result <= result32[15:0];
                            op_result_high <= result32[31:16];
                        end
                        
                        OP_MUL: begin 
                            flags.CY <= 0;
                            flags.V <= 0;

                            if (decoded.width == WORD) begin
                                result32 = $signed(TA) * $signed(TB);
                                if (16'd0 != result32[31:16]) begin
                                    flags.CY <= 1;
                                    flags.V <= 1;
                                end
                                delay = 12;
                            end else begin
                                result32[15:0] = $signed(TA[7:0]) * $signed(TB[7:0]);
                                if (8'd0 != result32[15:8]) begin
                                    flags.CY <= 1;
                                    flags.V <= 1;
                                end
                                delay = 8;
                            end
                            op_result <= result32[15:0];
                            op_result_high <= result32[31:16];
                        end                              

                        OP_PREPARE: begin
                            working = exec_stage != 3;
                            if (exec_stage == 0) begin
                                prepare_nesting_level <= decoded.imm[20:16];
                                reg_sp <= reg_sp - 16'd2;
                                prepare_sp_save <= reg_sp - 16'd2;
                                write_memory(reg_sp - 16'd2, SS, WORD, reg_bp);
                                working = 1;
                                delay = 10'd6;
                                case(decoded.imm[20:16])
                                5'd0: exec_stage <= 3;
                                5'd1: exec_stage <= 2;
                                default: exec_stage <= 1;
                                endcase
                            end else if (exec_stage == 1) begin
                                reg_sp <= reg_sp - 16'd2;
                                reg_bp <= reg_bp - 16'd2;
                                write_memory(reg_sp - 16'd2, SS, WORD, reg_bp - 16'd2);
                                prepare_nesting_level <= prepare_nesting_level - 5'd1;
                                if (prepare_nesting_level > 5'd2) begin
                                    exec_stage <= exec_stage;
                                    delay = 10'd7;
                                end
                            end else if (exec_stage == 2) begin
                                reg_sp <= reg_sp - 16'd2;
                                write_memory(reg_sp - 16'd2, SS, WORD, prepare_sp_save);
                                delay = 10'd3;
                            end else if (exec_stage == 3) begin
                                reg_bp <= prepare_sp_save;
                                reg_sp <= reg_sp - decoded.imm[15:0];
                            end
                        end

                        OP_DISPOSE: begin
                            working = exec_stage == 0;
                            if (exec_stage == 0) begin
                                reg_sp <= reg_bp + 2;
                                read_memory(reg_bp, SS, WORD);
                            end else begin
                                reg_bp <= mem_din;
                                delay = 10'd4;
                            end
                        end

                        OP_CHKIND: begin
                            temp = get_reg16(reg16_index_e'(decoded.reg0));
                            delay = 10'd9;
                            if (TA > temp || TB < temp) begin
                                interrupt_vector <= 8'd5;
                                exception = 1;
                            end
                        end

                        OP_TRANS: begin
                            working = exec_stage != 2;
                            if (exec_stage == 1) begin
                                read_memory(reg_bw + { 8'd0, reg_aw[7:0]}, decoded.segment, BYTE);
                            end else if (exec_stage == 2) begin
                                reg_aw[7:0] <= mem_din[7:0];
                            end
                        end

                        OP_BRK3: begin
                            interrupt_vector <= 8'd3;
                            exception = 1;
                        end

                        OP_BRK: begin
                            interrupt_vector <= decoded.imm[7:0];
                            exception = 1;
                        end

                        OP_BRKV: begin
                            if (flags.V) begin
                                interrupt_vector <= 8'd4;
                                exception = 1;
                            end
                        end

                        // BRKN imm8: software break to NATIVE mode. Vectors like an
                        // interrupt (pushes PSW/PS/PC) then forces MD=1 so the handler
                        // executes un-decrypted. MD is set after the push (see
                        // INT_FETCH_VEC) so the saved PSW keeps the pre-break mode.
                        OP_BRKN: begin
                            interrupt_vector <= decoded.imm[7:0];
                            exception = 1;
                            brkn_pending <= 1;
                        end

                        OP_FINT: begin
                            fint <= 1;
                        end

                        OP_ADD4S, OP_SUB4S, OP_CMP4S: begin
                            working = 1;
                            if (exec_stage == 0) begin
                                bcd_offset <= 7'd0;
                                flags.Z <= 1;
                                flags.CY <= 0;
                            end else if (exec_stage == 1) begin
                                // byte count = ceil(CL/2) = floor(CL/2) + (CL & 1), matching MAME's (CL+1)/2
                                if (bcd_offset == (reg_cw[7:1] + { 6'd0, reg_cw[0] })) begin
                                    working = 0;
                                    delay = 0;
                                end else begin
                                    read_memory(reg_ix + {9'd0, bcd_offset}, decoded.segment, BYTE);
                                end
                            end else if (exec_stage == 2) begin
                                bcd_src <= mem_din[7:0] + { 7'd0, flags.CY };
                                flags.CY <= 0;
                                read_memory(reg_iy + {9'd0, bcd_offset}, DS1, BYTE);
                            end else if (exec_stage == 3) begin
                                if (decoded.opcode == OP_ADD4S) begin
                                    bcd_acc_low  <= { 1'b0, mem_din[3:0] } + { 1'b0, bcd_src[3:0] };
                                    bcd_acc_high <= { 1'b0, mem_din[7:4] } + { 1'b0, bcd_src[7:4] };
                                end else begin
                                    bcd_acc_low  <= { 1'b0, mem_din[3:0] } - { 1'b0, bcd_src[3:0] };
                                    bcd_acc_high <= { 1'b0, mem_din[7:4] } - { 1'b0, bcd_src[7:4] };
                                end
                            end else if (exec_stage == 4) begin
                                bcd_result_low = bcd_acc_low;
                                bcd_result_high = bcd_acc_high;
                                if (bcd_result_low > 5'd9) begin
                                    if (decoded.opcode == OP_ADD4S) begin
                                        // decimal carry into the high nibble
                                        bcd_result_low = bcd_acc_low + 5'd6;
                                        bcd_result_high = bcd_acc_high + 5'd1;
                                    end else begin
                                        // SUB4S/CMP4S: decimal borrow from the high nibble
                                        bcd_result_low = bcd_acc_low - 5'd6;
                                        bcd_result_high = bcd_acc_high - 5'd1;
                                    end
                                end

                                if (bcd_result_high > 5'd9) begin
                                    if (decoded.opcode == OP_ADD4S) begin
                                        bcd_result_high = bcd_result_high + 5'd6;
                                    end else begin
                                        bcd_result_high = bcd_result_high - 5'd6;
                                    end
                                    flags.CY <= 1;
                                end
                                bcd_acc <= { bcd_result_high[3:0], bcd_result_low[3:0] };
                                delay = 13;
                            end else if (exec_stage == 5) begin
                                if (|bcd_acc) flags.Z <= 0;
                                if (decoded.opcode != OP_CMP4S) begin
                                    write_memory(reg_iy + { 9'd0, bcd_offset}, DS1, BYTE, { 8'd0, bcd_acc });
                                end else begin
                                    delay = 1;
                                end
                                bcd_offset <= bcd_offset + 7'd1;
                                exec_stage <= 1; // loop                                
                            end
                        end

                        OP_ROL4: begin
                            reg_aw[3:0] <= TA[7:4];
                            op_result <= { 8'd0, TA[3:0], reg_aw[3:0] };
                            delay = 10'd8;
                        end

                        OP_ROR4: begin
                            reg_aw[3:0] <= TA[3:0];
                            op_result <= { 8'd0, reg_aw[3:0], TA[7:4] };
                            delay = 10'd8;
                        end

                        OP_EXT: begin
                            working = 1;
                            // TA = bit offset
                            // TB = width
                            case(exec_stage)
                                0: begin
                                    bit [16:0] mask17;
                                    bitfield_addr <= reg_ix + { 14'd0, TA[4:3] };
                                    bitfield_width <= ( { 2'd0, TA[2:0] } + { 1'd0, TB[3:0] } ) < 5'd7 ? WORD : BYTE;
                                    mask17 = (17'd2 << TB[3:0]) - 17'd1;
                                    bitfield_mask <= mask17[15:0];
                                    bitfield_shift <= TA[2:0];
                                end
                                1: begin
                                    read_memory(bitfield_addr, decoded.segment, bitfield_width);
                                end
                                2: begin
                                    bit [7:0] new_offset;
                                    new_offset = TA[7:0] + { 4'd0, TB[3:0] } + 8'd1;
                                    if (new_offset > 8'd15) begin
                                        op_result <= {8'd0, new_offset - 8'd16};
                                        reg_ix <= reg_ix + 16'd2;
                                    end else begin
                                        op_result <= {8'd0, new_offset};
                                    end
                                    reg_aw <= ( mem_din >> bitfield_shift ) & bitfield_mask;
                                    working = 0;
                                end
                            endcase
                        end

                        OP_INS: begin
                            working = 1;
                            case(exec_stage)
                                0: begin
                                    bit [16:0] mask17;
                                    bitfield_addr <= reg_iy + { 14'd0, TA[4:3] };
                                    bitfield_width <= ( { 2'd0, TA[2:0] } + { 1'd0, TB[3:0] } ) < 5'd7 ? WORD : BYTE;
                                    mask17 = (17'd2 << TB[3:0]) - 17'd1;
                                    bitfield_mask <= mask17[15:0] << TA[2:0];
                                    bitfield_shift <= TA[2:0];
                                end
                                1: begin
                                    read_memory(bitfield_addr, DS1, bitfield_width);
                                end
                                2: begin
                                    bitfield_out <= (mem_din & ~bitfield_mask) | ((reg_aw << bitfield_shift) & bitfield_mask);
                                end
                                3: begin
                                    write_memory(bitfield_addr, DS1, bitfield_width, bitfield_out);
                                end
                                4: begin
                                    bit [7:0] new_offset;
                                    new_offset = TA[7:0] + { 4'd0, TB[3:0] } + 8'd1;
                                    if (new_offset > 8'd15) begin
                                        op_result <= {8'd0, new_offset - 8'd16};
                                        reg_iy <= reg_iy + 16'd2;
                                    end else begin
                                        op_result <= {8'd0, new_offset};
                                    end
                                    working = 0;
                                end
                            endcase
                        end

                        default: begin // TODO exception
                        end

                    endcase

                    if (~working) begin
                        bit need_delay;
                        op_delay <= delay + alu_delay;
                        need_delay = delay > 0 || alu_delay > 0;

                        if (exception) begin
                            state <= INT_INITIATE;
                        end else begin
                            if (need_delay & ~turbo) begin
                                state <= STORE_DELAY;
                                cycles <= 10'd1;
                            end else begin
                                state <= STORE_REGISTER;
                            end
                        end
                    end else if (check_interrupt) begin
                        if (pic_intreq & flags.IE) begin
                            state <= INT_ACK_WAIT;
                            next_pc <= decoded.pc;
                        end
                    end
                    exec_delay <= delay;
                end
            end // EXECUTE

            PUSH: if (ce_1) begin
                if (push_list == 16'd0) begin
                    if (int_processing) begin
                        state <= INT_FETCH_VEC;
                    end else if (decoded.opcode == OP_PUSH) begin
                        state <= IDLE;
                    end else if (decoded.opclass == BRANCH) begin
                        state <= BRANCHING;
                    end else begin
                        state <= EXECUTE;
                    end
                end else if (dp_ready) begin
                    reg_sp <= reg_sp - 16'd2;
                    state <= PUSH_WRITE;
                end
            end

            PUSH_WRITE: if (dp_ready & ce_1) begin
                bit [15:0] push_data;
                bit [15:0] list;
                int push_idx;

                push_idx = 0;
                list = push_list;
                for (int i = 15; i >= 0; i = i - 1) begin
                    if (list[i]) push_idx = i;
                end

                case(push_idx)
                0:  push_data = reg_aw;
                1:  push_data = reg_cw;
                2:  push_data = reg_dw;
                3:  push_data = reg_bw;
                4:  push_data = push_sp_save;
                5:  push_data = push_sp_save; // DISCARD
                6:  push_data = reg_bp;
                7:  push_data = reg_ix;
                8:  push_data = reg_iy;
                9:  push_data = reg_ds1;
                10: push_data = reg_psw;
                11: push_data = reg_ps;
                12: push_data = reg_ss;
                13: push_data = reg_ds0;
                14: push_data = next_pc;
                15: push_data = TA;
                endcase

                write_memory(reg_sp, SS, WORD, push_data);

                list[push_idx] = 0;
                push_list <= list;

                state <= PUSH;
            end // PUSH

            POP_STORE: if (ce_1 & dp_ready) begin
                if (pop_store) begin
                    write_memory(calculated_ea, decoded.segment, WORD, TA);
                end
                state <= POP_CHECK;
            end

            POP_CHECK: if (ce_1 & dp_ready) begin
                if (pop_list == 16'd0) begin
                    if (decoded.opcode == OP_POP) begin
                        state <= IDLE;
                    end else if (decoded.opclass == BRANCH) begin
                        state <= BRANCHING;
                    end else begin
                        state <= EXECUTE;
                    end
                end else begin
                    state <= POP;
                end            
            end

            POP: if (dp_ready & ce_1) begin
                read_memory(reg_sp, SS, WORD);
                reg_sp <= reg_sp + 16'd2;

                state <= POP_WAIT;
            end // POP

            POP_WAIT: if (ce_1 & dp_ready) begin
                bit [15:0] list;
                int pop_idx = 0;

                pop_store <= 0;

                list = pop_list;
                for (int i = 0; i < 16; i = i + 1) begin
                    if (list[i]) pop_idx = i;
                end

                case(pop_idx)
                    0:  reg_aw <= mem_din;
                    1:  reg_cw <= mem_din;
                    2:  reg_dw <= mem_din;
                    3:  reg_bw <= mem_din;
                    4:  reg_sp <= mem_din;
                    5:  begin end // skip
                    6:  reg_bp <= mem_din;
                    7:  reg_ix <= mem_din;
                    8:  reg_iy <= mem_din;
                    9:  reg_ds1 <= mem_din;
                    10: begin
                        flags.CY  <= mem_din[0];
                        flags.P   <= mem_din[2];
                        flags.AC  <= mem_din[4];
                        flags.Z   <= mem_din[6];
                        flags.S   <= mem_din[7];
                        flags.BRK <= mem_din[8];
                        flags.IE  <= mem_din[9];
                        flags.DIR <= mem_din[10];
                        flags.V   <= mem_din[11];
                        flags.MD  <= mem_din[15]; // restore mode flag (RETI/POPF) -> returns from BRKN native handler
                    end
                    11: begin
                        reg_ps <= mem_din;
                        stack_modified_ps <= 1;
                    end
                    12: reg_ss <= mem_din;
                    13: reg_ds0 <= mem_din;
                    14: begin
                        next_pc <= mem_din;
                        stack_modified_pc <= 1;
                    end
                    15: begin
                        if (decoded.mod == 2'b11) begin
                            set_reg16(reg16_index_e'(decoded.rm), mem_din);
                        end else begin
                            TA <= mem_din;
                            pop_store <= 1;
                        end
                    end
                endcase

                list[pop_idx] = 0;
                pop_list <= list;
                state <= POP_STORE;
            end // POP_WAIT

            STORE_DELAY: if (ce_1) begin
                if (~&cycles) cycles <= cycles + 10'd1;
                if (cycles >= op_delay) begin
                    state <= STORE_REGISTER;
                end
            end

            STORE_MEMORY: begin
                if (ce_1 & dp_ready) begin
                    if (decoded.io)
                        write_io(calculated_ea, decoded.width, op_result);
                    else
                        write_memory(calculated_ea, decoded.segment, decoded.width, op_result);
                    state <= IDLE;
                end
            end

            STORE_REGISTER: begin
                 if (ce_2) begin
                    if (use_alu_result) begin
                        result32 = { 16'd0, alu_result };
                        op_result <= alu_result; // for STORE_MEMORY
                        flags <= alu_flags_result;
                    end else begin
                        result32 = { op_result_high, op_result };
                    end

                    case(decoded.dest)
                        OPERAND_ACC: begin
                            if (decoded.width == BYTE)
                                reg_aw[7:0] <= result32[7:0];
                            else
                                reg_aw <= result32[15:0];
                        end
                        OPERAND_MODRM: begin
                            if (decoded.mod == 2'b11) begin
                                if (decoded.width == BYTE)
                                    set_reg8(reg8_index_e'(decoded.rm), result32[7:0]);
                                else
                                    set_reg16(reg16_index_e'(decoded.rm), result32[15:0]);
                            end
                        end
                        OPERAND_SREG: begin
                            set_sreg(sreg_index_e'(decoded.sreg), result32[15:0]);
                        end
                        OPERAND_REG_0: begin
                            if (decoded.width == BYTE)
                                set_reg8(reg8_index_e'(decoded.reg0), result32[7:0]);
                            else
                                set_reg16(reg16_index_e'(decoded.reg0), result32[15:0]);
                        end
                        OPERAND_REG_1: begin
                            if (decoded.width == BYTE)
                                set_reg8(reg8_index_e'(decoded.reg1), result32[7:0]);
                            else
                                set_reg16(reg16_index_e'(decoded.reg1), result32[15:0]);
                        end
                        OPERAND_PRODUCT: begin
                            if (decoded.width == WORD) reg_dw <= result32[31:16];
                            reg_aw <= result32[15:0];
                        end
                        default: begin end
                    endcase

                    if (decoded.mem_write) begin
                        state <= STORE_MEMORY;
                    end else begin
                        state <= IDLE;
                    end
                end
            end // STORE_REGISTER

            // for linting, should not be possible
            default: begin end
        endcase
    end
end


v35_edge_trigger intp0_edge(
    .clk(clk),
    .ce(ce_1),
    .reset(reset),
    .signal(~n_intp0),
    .dir(sfr.INTM[2]),
    .trigger(EXIC0.ctrl_set_if)
);

v35_edge_trigger intp1_edge(
    .clk(clk),
    .ce(ce_1),
    .reset(reset),
    .signal(~n_intp1),
    .dir(sfr.INTM[4]),
    .trigger(EXIC1.ctrl_set_if)
);

v35_edge_trigger intp2_edge(
    .clk(clk),
    .ce(ce_1),
    .reset(reset),
    .signal(~n_intp2),
    .dir(sfr.INTM[6]),
    .trigger(EXIC2.ctrl_set_if)
);

// On-chip timer unit. Counts on the master clock enable and raises the
// timer interrupt-control registers, which feed the PIC (vectors 28/29/30).
v35_timer timer(
    .clk(clk),
    .ce(ce),
    .reset(reset),

    .pck_sel(sfr.PRC[1:0]),

    .TM0(TM0), .MD0(MD0), .TM1(TM1), .MD1(MD1),
    .TMC0(TMC0), .TMC1(TMC1),

    .tu0_set(TMIC0.ctrl_set_if),
    .tu1_set(TMIC1.ctrl_set_if),
    .tu2_set(TMIC2.ctrl_set_if)
);

wire [7:0] pic_intvec;
wire pic_intreq;

v35_pic pic(
    .clk(clk),
    .ce(ce_1),
    .reset(reset),

    .NMI(0),
    .INT(0),

    .EXIC0(EXIC0.value),
    .EXIC1(EXIC1.value),
    .EXIC2(EXIC2.value),
    .TMIC0(TMIC0.value),
    .TMIC1(TMIC1.value),
    .TMIC2(TMIC2.value),

    .ISPR(ISPR),

    .IE(flags.IE),

    .NMI_clear(),
    .INT_clear(),
    .EXIC0_clear(EXIC0.ctrl_clear_if),
    .EXIC1_clear(EXIC1.ctrl_clear_if),
    .EXIC2_clear(EXIC2.ctrl_clear_if),
    .TMIC0_clear(TMIC0.ctrl_clear_if),
    .TMIC1_clear(TMIC1.ctrl_clear_if),
    .TMIC2_clear(TMIC2.ctrl_clear_if),

    .int_req(pic_intreq),
    .int_vector(pic_intvec),
    .int_ack(bcu_intack_cycle & ~n_mreq),

    .fint(fint)
);


endmodule