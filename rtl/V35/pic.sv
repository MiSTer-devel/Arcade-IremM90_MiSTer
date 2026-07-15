`ifdef LINTING
`include "types.sv"
`endif

import types::*;

module v35_edge_trigger(
    input clk,
    input ce,
    input reset,

    input signal,
    input dir,
    output reg trigger
);

reg prev_signal;
always_ff @(posedge clk) begin
    if (reset) begin
        trigger <= 0;
        prev_signal <= signal;
    end else if (ce) begin
        trigger <= (signal ^ prev_signal) & (prev_signal ^ dir);
        prev_signal <= signal;
    end
end

endmodule


module v35_pic(
    input clk,
    input ce,
    input reset,
    
    input NMI,
    input INT,
    input [7:0] EXIC0,
    input [7:0] EXIC1,
    input [7:0] EXIC2,
    input [7:0] TMIC0,
    input [7:0] TMIC1,
    input [7:0] TMIC2,

    output reg [7:0] ISPR,

    input IE,

    output reg NMI_clear,
    output reg INT_clear,
    output reg EXIC0_clear,
    output reg EXIC1_clear,
    output reg EXIC2_clear,
    output reg TMIC0_clear,
    output reg TMIC1_clear,
    output reg TMIC2_clear,


    output int_req,
    output reg [7:0] int_vector,
    input int_ack,

    input fint
);

function bit [7:0] prio_mask(bit [2:0] prio);
    case(prio)
        3'd0: return 8'b00000001;
        3'd1: return 8'b00000011;
        3'd2: return 8'b00000111;
        3'd3: return 8'b00001111;
        3'd4: return 8'b00011111;
        3'd5: return 8'b00111111;
        3'd6: return 8'b01111111;
        3'd7: return 8'b11111111;
    endcase
endfunction

enum
{
    IRQ_NONE,
    IRQ_NMI,
    IRQ_INT,
    IRQ_EXIC0,
    IRQ_EXIC1,
    IRQ_EXIC2,
    IRQ_TMIC0,
    IRQ_TMIC1,
    IRQ_TMIC2
} irq_type;

assign int_req = irq_type != IRQ_NONE;

reg ack_prev;
reg second_ack;

always_ff @(posedge clk) begin
    NMI_clear <= 0;
    INT_clear <= 0;
    EXIC0_clear <= 0;
    EXIC1_clear <= 0;
    EXIC2_clear <= 0;
    TMIC0_clear <= 0;
    TMIC1_clear <= 0;
    TMIC2_clear <= 0;

    if (reset) begin
        ISPR <= 0;
        irq_type <= IRQ_NONE;
        second_ack <= 0;
    end else if (ce) begin
        ack_prev <= int_ack;
        
        if (fint) begin
            if (ISPR[0]) ISPR[0] <= 0;
            else if (ISPR[1]) ISPR[1] <= 0;
            else if (ISPR[2]) ISPR[2] <= 0;
            else if (ISPR[3]) ISPR[3] <= 0;
            else if (ISPR[4]) ISPR[4] <= 0;
            else if (ISPR[5]) ISPR[5] <= 0;
            else if (ISPR[6]) ISPR[6] <= 0;
            else if (ISPR[7]) ISPR[7] <= 0;
        end

        if (int_req) begin
            if (int_ack & ~ack_prev) begin
                second_ack <= 1;
                if (~second_ack) begin
                    case(irq_type)
                        IRQ_NMI: begin
                            NMI_clear <= 1;
                            int_vector <= 8'd2;
                        end
                        IRQ_INT: begin
                            INT_clear <= 1;
                            int_vector <= 8'd0; // TODO: read from external
                        end
                        IRQ_EXIC0: begin
                            EXIC0_clear <= 1;
                            int_vector <= 8'd24;
                            ISPR <= ISPR | ( 8'd1 << EXIC0[2:0] );
                        end
                        IRQ_EXIC1: begin
                            EXIC1_clear <= 1;
                            int_vector <= 8'd25;
                            ISPR <= ISPR | ( 8'd1 << EXIC1[2:0] );
                        end
                        IRQ_EXIC2: begin
                            EXIC2_clear <= 1;
                            int_vector <= 8'd26;
                            ISPR <= ISPR | ( 8'd1 << EXIC2[2:0] );
                        end
                        IRQ_TMIC0: begin
                            TMIC0_clear <= 1;
                            int_vector <= 8'd28;
                            ISPR <= ISPR | ( 8'd1 << TMIC0[2:0] );
                        end
                        IRQ_TMIC1: begin
                            TMIC1_clear <= 1;
                            int_vector <= 8'd29;
                            ISPR <= ISPR | ( 8'd1 << TMIC1[2:0] );
                        end
                        IRQ_TMIC2: begin
                            TMIC2_clear <= 1;
                            int_vector <= 8'd30;
                            ISPR <= ISPR | ( 8'd1 << TMIC2[2:0] );
                        end
                        default: begin end // How?
                    endcase
                end else begin
                    second_ack <= 0;
                    irq_type <= IRQ_NONE;
                end
            end
        end else begin
            second_ack <= 0;
            if (NMI) begin
                irq_type <= IRQ_NMI;
            end else if (INT & IE) begin
                irq_type <= IRQ_INT;
            end else if (IE) begin
                if ((ISPR & prio_mask(EXIC0[2:0])) == 8'd0 && EXIC0[7] & ~EXIC0[6]) begin
                    irq_type <= IRQ_EXIC0;
                end else if ((ISPR & prio_mask(EXIC1[2:0])) == 8'd0 && EXIC1[7] & ~EXIC1[6]) begin
                    irq_type <= IRQ_EXIC1;
                end else if ((ISPR & prio_mask(EXIC2[2:0])) == 8'd0 && EXIC2[7] & ~EXIC2[6]) begin
                    irq_type <= IRQ_EXIC2;
                end else if ((ISPR & prio_mask(TMIC0[2:0])) == 8'd0 && TMIC0[7] & ~TMIC0[6]) begin
                    irq_type <= IRQ_TMIC0;
                end else if ((ISPR & prio_mask(TMIC1[2:0])) == 8'd0 && TMIC1[7] & ~TMIC1[6]) begin
                    irq_type <= IRQ_TMIC1;
                end else if ((ISPR & prio_mask(TMIC2[2:0])) == 8'd0 && TMIC2[7] & ~TMIC2[6]) begin
                    irq_type <= IRQ_TMIC2;
                end
            end
        end
    end
end


endmodule


// V35 on-chip timer unit (Timer 0 / Timer 1).
//
// Models MAME's v25/v35 timer behaviour:
//   interval mode : period = PCK * MDx * (TMCx[6] ? 128 : 6)   master clocks
//   one-shot mode : period = PCK * TM0 * (TMC0[6] ? 128 : 12)  master clocks  (Timer 0)
// where PCK is the system clock prescaler selected by PRC[1:0] (2/4/8).
// Timer 0 fires INTTU0; Timer 1 (interval) fires INTTU1 and INTTU2.
module v35_timer(
    input clk,
    input ce,               // master clock enable (same clock the CPU counts)
    input reset,

    input [1:0] pck_sel,    // sfr.PRC[1:0]

    input [15:0] TM0,
    input [15:0] MD0,
    input [15:0] TM1,
    input [15:0] MD1,
    input [7:0]  TMC0,
    input [7:0]  TMC1,

    output reg tu0_set,     // -> TMIC0 (INTTU0)
    output reg tu1_set,     // -> TMIC1 (INTTU1)
    output reg tu2_set      // -> TMIC2 (INTTU2)
);

// PCK clock divider selected by PRC[1:0] is a power of two (2, 4, 8; 3 is
// invalid -> 8), so "PCK * prescaler" is just a left shift (no multiplier).
wire [2:0] pck_shift = (pck_sel == 2'd3) ? 3'd3 : ({1'b0, pck_sel} + 3'd1);

// Timer 0
wire [7:0]  presc0     = TMC0[6] ? 8'd128 : (TMC0[0] ? 8'd12 : 8'd6);
wire [15:0] presc0_max = {8'd0, presc0} << pck_shift;
reg  [15:0] presc0_cnt;
reg  [15:0] cnt0;
reg         run0;
reg         prev_ts0;

// Timer 1 (interval mode only)
wire [7:0]  presc1     = TMC1[6] ? 8'd128 : 8'd6;
wire [15:0] presc1_max = {8'd0, presc1} << pck_shift;
reg  [15:0] presc1_cnt;
reg  [15:0] cnt1;
reg         run1;
reg         prev_ts1;

always_ff @(posedge clk) begin
    tu0_set <= 0;
    tu1_set <= 0;
    tu2_set <= 0;

    if (reset) begin
        run0 <= 0; run1 <= 0;
        prev_ts0 <= 0; prev_ts1 <= 0;
        presc0_cnt <= 0; presc1_cnt <= 0;
        cnt0 <= 0; cnt1 <= 0;
    end else begin
        prev_ts0 <= TMC0[7];
        prev_ts1 <= TMC1[7];

        // ---- Timer 0 ----
        if (TMC0[7] & ~prev_ts0) begin
            // start: rising edge of TS0
            presc0_cnt <= 0;
            if (TMC0[0]) begin      // one-shot: count down TM0
                cnt0 <= TM0;
                run0 <= (TM0 != 16'd0);
            end else begin          // interval: count down MD0
                cnt0 <= MD0;
                run0 <= (MD0 != 16'd0);
            end
        end else if (~TMC0[7]) begin
            run0 <= 0;
        end else if (run0 & ce) begin
            if (presc0_cnt >= presc0_max - 16'd1) begin
                presc0_cnt <= 0;
                if (cnt0 <= 16'd1) begin
                    tu0_set <= 1;
                    if (TMC0[0]) run0 <= 0;   // one-shot: stop after firing
                    else         cnt0 <= MD0; // interval: reload from MD0
                end else begin
                    cnt0 <= cnt0 - 16'd1;
                end
            end else begin
                presc0_cnt <= presc0_cnt + 16'd1;
            end
        end

        // ---- Timer 1 (interval) ----
        if (TMC1[7] & ~prev_ts1) begin
            presc1_cnt <= 0;
            cnt1 <= MD1;
            run1 <= (MD1 != 16'd0);
        end else if (~TMC1[7]) begin
            run1 <= 0;
        end else if (run1 & ce) begin
            if (presc1_cnt >= presc1_max - 16'd1) begin
                presc1_cnt <= 0;
                if (cnt1 <= 16'd1) begin
                    tu1_set <= 1;
                    tu2_set <= 1;
                    cnt1 <= MD1;
                end else begin
                    cnt1 <= cnt1 - 16'd1;
                end
            end else begin
                presc1_cnt <= presc1_cnt + 16'd1;
            end
        end
    end
end

endmodule