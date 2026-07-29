// =============================================================================
// write_vga.sv
//
// Rewritten for the password cracker demo.
//
// Displays three rows on the VGA screen:
//   Row TARGET_ROW    : "Target:   <PW_LEN ASCII chars>"   — the password to crack
//   Row CANDIDATE_ROW : "Candidate: <PW_LEN ASCII chars>"  — current guess
//   Row ATTEMPTS_ROW  : "Attempts:  <8 hex digits>"   — attempt counter
//
// The ASCII characters in target/candidate are written directly (no conversion).
// The attempts counter is shown as 8 hex nibbles using nibble_to_char().
//
// Parameters
//   TARGET_ROW       – VGA text row for target password    (default 10)
//   TARGET_COLUMN    – VGA text column for target data     (default 15)
//   CANDIDATE_ROW    – VGA text row for candidate          (default 11)
//   CANDIDATE_COLUMN – VGA text column for candidate data  (default 15)
//   ATTEMPTS_ROW     – VGA text row for attempt counter    (default 12)
//   ATTEMPTS_COLUMN  – VGA text column for attempt data    (default 15)
//   PW_LEN           – password length in characters       (default 6)
//
// Ports
//   clk           – clock
//   rst           – active-high synchronous reset
//   write_display – one-cycle pulse at end of each VGA frame (last_row & last_col)
//   target        – latched target password  [PW_LEN*8-1:0], MSB = first char
//   candidate     – current candidate        [PW_LEN*8-1:0], MSB = first char
//   attempts      – 32-bit attempt counter
//   char_addr     – {row[4:0], col[6:0]} address into character RAM
//   char_data     – ASCII byte to write
//   write_char    – write-enable to character RAM
// =============================================================================

module write_vga #(
    parameter int TARGET_ROW       = 10,
    parameter int TARGET_COLUMN    = 15,
    parameter int CANDIDATE_ROW    = 11,
    parameter int CANDIDATE_COLUMN = 15,
    parameter int ATTEMPTS_ROW     = 12,
    parameter int ATTEMPTS_COLUMN  = 15,
    parameter int PW_LEN           = 6
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        write_display,

    input  logic [PW_LEN*8-1:0] target,
    input  logic [PW_LEN*8-1:0] candidate,
    input  logic [31:0]          attempts,

    output logic [11:0] char_addr,
    output logic [7:0]  char_data,
    output logic        write_char
);

    // -------------------------------------------------------------------------
    // Hex nibble → ASCII helper (unchanged from original)
    // -------------------------------------------------------------------------
    function automatic logic [7:0] nibble_to_char(input logic [3:0] n);
        if (n < 10)
            return n + 8'h30;       // '0'-'9'
        else
            return n + 8'd55;       // 'A'-'F'
    endfunction

    // -------------------------------------------------------------------------
    // Layout constants
    // -------------------------------------------------------------------------
    // Number of characters written per row:
    //   target/candidate : PW_LEN ASCII bytes
    //   attempts         : 8 hex digits (32-bit counter)
    localparam int ATT_COLS = 8;

    // -------------------------------------------------------------------------
    // State machine
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        IDLE,
        WRITE_TARGET,
        WRITE_CANDIDATE,
        WRITE_ATTEMPTS,
        DONE
    } state_t;

    state_t cs, ns;

    logic [4:0] cur_row,  next_row;
    logic [6:0] cur_col,  next_col;

    // Shift register wide enough for the largest payload (attempts = 8 bytes)
    // We store ASCII bytes left-aligned; unused bytes are 0.
    localparam int SR_BYTES = (PW_LEN > ATT_COLS) ? PW_LEN : ATT_COLS;
    localparam int SR_BITS  = SR_BYTES * 8;

    logic [SR_BITS-1:0] sr,          // shift register
                         sr_load;    // value to load
    logic                sr_we;      // load enable
    logic                sr_shift;   // shift enable
    logic [6:0]          end_col;    // last column index for current row

    // -------------------------------------------------------------------------
    // Build the attempts ASCII string (8 hex chars, MSB first)
    // -------------------------------------------------------------------------
    logic [ATT_COLS*8-1:0] attempts_ascii;
    assign attempts_ascii = {
        nibble_to_char(attempts[31:28]),
        nibble_to_char(attempts[27:24]),
        nibble_to_char(attempts[23:20]),
        nibble_to_char(attempts[19:16]),
        nibble_to_char(attempts[15:12]),
        nibble_to_char(attempts[11:8]),
        nibble_to_char(attempts[7:4]),
        nibble_to_char(attempts[3:0])
    };

    // -------------------------------------------------------------------------
    // Shift register
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst)
            sr <= '0;
        else if (sr_we)
            sr <= sr_load;
        else if (sr_shift)
            sr <= {sr[SR_BITS-9:0], 8'h0};  // shift left, drop MSB byte
    end

    // Top byte of shift register drives char_data
    assign char_data = sr[SR_BITS-1 -: 8];

    // -------------------------------------------------------------------------
    // Sequential state + row/col registers
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            cs      <= IDLE;
            cur_row <= '0;
            cur_col <= '0;
        end else begin
            cs      <= ns;
            cur_row <= next_row;
            cur_col <= next_col;
        end
    end

    // -------------------------------------------------------------------------
    // Next-state / output logic
    // -------------------------------------------------------------------------
    always_comb begin
        // Defaults
        ns         = cs;
        next_row   = cur_row;
        next_col   = cur_col;
        write_char = 1'b0;
        sr_we      = 1'b0;
        sr_shift   = 1'b0;
        sr_load    = '0;
        end_col    = '0;

        case (cs)

            // ------------------------------------------------------------------
            IDLE: begin
                if (write_display) begin
                    // Load target password into shift register (pad to SR_BITS)
                    sr_load  = SR_BITS'(target);  // zero-extend if SR>PW_LEN bytes
                    // If PW_LEN < SR_BYTES we need target left-aligned
                    sr_load  = {target, {(SR_BITS - PW_LEN*8){1'b0}}};
                    sr_we    = 1'b1;
                    next_row = TARGET_ROW[4:0];
                    next_col = TARGET_COLUMN[6:0];
                    ns       = WRITE_TARGET;
                end
            end

            // ------------------------------------------------------------------
            // Write PW_LEN ASCII bytes of the target password
            // ------------------------------------------------------------------
            WRITE_TARGET: begin
                write_char = 1'b1;
                end_col    = TARGET_COLUMN[6:0] + PW_LEN[6:0] - 1;
                if (cur_col == end_col) begin
                    // Load candidate into shift register
                    sr_load  = {candidate, {(SR_BITS - PW_LEN*8){1'b0}}};
                    sr_we    = 1'b1;
                    next_row = CANDIDATE_ROW[4:0];
                    next_col = CANDIDATE_COLUMN[6:0];
                    ns       = WRITE_CANDIDATE;
                end else begin
                    sr_shift   = 1'b1;
                    next_col   = cur_col + 1;
                end
            end

            // ------------------------------------------------------------------
            // Write PW_LEN ASCII bytes of the current candidate
            // ------------------------------------------------------------------
            WRITE_CANDIDATE: begin
                write_char = 1'b1;
                end_col    = CANDIDATE_COLUMN[6:0] + PW_LEN[6:0] - 1;
                if (cur_col == end_col) begin
                    // Load attempts hex string into shift register
                    sr_load  = {attempts_ascii, {(SR_BITS - ATT_COLS*8){1'b0}}};
                    sr_we    = 1'b1;
                    next_row = ATTEMPTS_ROW[4:0];
                    next_col = ATTEMPTS_COLUMN[6:0];
                    ns       = WRITE_ATTEMPTS;
                end else begin
                    sr_shift   = 1'b1;
                    next_col   = cur_col + 1;
                end
            end

            // ------------------------------------------------------------------
            // Write 8 hex digits of the attempts counter
            // ------------------------------------------------------------------
            WRITE_ATTEMPTS: begin
                write_char = 1'b1;
                end_col    = ATTEMPTS_COLUMN[6:0] + ATT_COLS[6:0] - 1;
                if (cur_col == end_col) begin
                    ns = DONE;
                end else begin
                    sr_shift   = 1'b1;
                    next_col   = cur_col + 1;
                end
            end

            // ------------------------------------------------------------------
            DONE: begin
                if (~write_display)
                    ns = IDLE;
            end

            default: ns = IDLE;

        endcase
    end

    // -------------------------------------------------------------------------
    // char_addr = {row[4:0], col[6:0]}
    // -------------------------------------------------------------------------
    assign char_addr = {cur_row, cur_col};

endmodule
