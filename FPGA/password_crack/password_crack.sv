// =============================================================================
// password_crack.sv
//
// Plaintext brute-force password cracker with runtime-variable password length.
// User enters 1–PW_LEN characters, then presses start to lock the length and
// begin cracking.
//
// Parameters
//   PW_LEN       – maximum password length (default 6)
//
// Ports
//   clk          – clock
//   rst          – active-high synchronous reset
//   sw           – 8 switches = one ASCII byte
//   btn_confirm  – latch current switch value as next password character
//   btn_start    – lock length and begin cracking (needs at least 1 char)
//   cracked      – high when a match is found
//   done         – high when search is complete (match or exhausted)
//   attempts     – running count of candidates tried
//   candidate    – current candidate (PW_LEN bytes, left-aligned)
//   target_out   – the latched target (PW_LEN bytes, left-aligned)
//   chars_entered– how many characters confirmed so far
//   pw_len_out   – the locked password length (valid once cracking starts)
// =============================================================================

module password_crack #(
    parameter int PW_LEN = 8
) (
    input  wire logic        clk,
    input  wire logic        rst,

    // Password entry
    input  wire logic [7:0]  uart_data,
    input  wire logic        uart_valid,

    // Status outputs
    output logic             cracked,
    output logic             done,
    output logic [31:0]      attempts,
    output logic [PW_LEN*8-1:0] candidate,
    output logic [PW_LEN*8-1:0] target_out,
    output logic [$clog2(PW_LEN+1)-1:0] chars_entered,
    output logic [$clog2(PW_LEN+1)-1:0] pw_len_out
);

    localparam int CHARSET_SIZE = 10;
    localparam int IDX_BITS     = $clog2(CHARSET_SIZE);
    localparam int LEN_BITS     = $clog2(PW_LEN+1);

    function automatic logic [7:0] idx_to_ascii(input logic [IDX_BITS-1:0] idx);
        return 8'h30 + idx;
    endfunction


    // =========================================================================
    // Target password register
    // Accepts characters freely up to PW_LEN. Length is locked on btn_start.
    // =========================================================================
    logic [PW_LEN*8-1:0]  target;
    logic [LEN_BITS-1:0]  char_idx;       // chars confirmed so far
    logic [LEN_BITS-1:0]  pw_len_locked;  // locked on start

    assign target_out    = target;
    assign chars_entered = char_idx;
    assign pw_len_out    = pw_len_locked;

    wire can_confirm = (char_idx < PW_LEN[LEN_BITS-1:0]);

    always_ff @(posedge clk) begin
        if (rst) begin
            target        <= '0;
            char_idx      <= '0;
            pw_len_locked <= '0;
        end else begin    
        if (uart_valid && can_confirm) begin
            if (uart_data >= "0" && uart_data <= "9") begin
                target[((PW_LEN - 1 - char_idx) * 8) +: 8] <= uart_data;
                char_idx <= char_idx + 1;
            end
        end
            // Lock the length when start is pressed, provided at least 1 char entered
        if (uart_valid &&
        ((uart_data == 8'h0D) || (uart_data == 8'h0A)) &&
        (char_idx > 0))
        begin
            pw_len_locked <= char_idx;
        end
        end
    end

    // =========================================================================
    // Per-character charset indices
    // =========================================================================
    logic [IDX_BITS-1:0] cidx      [0:PW_LEN-1];
    logic [IDX_BITS-1:0] next_cidx [0:PW_LEN-1];

    genvar g;
    generate
        for (g = 0; g < PW_LEN; g++) begin : gen_candidate
            assign candidate[((PW_LEN-1-g)*8) +: 8] = idx_to_ascii(cidx[g]);
        end
    endgenerate

    // =========================================================================
    // Combinational increment + all_max
    // Only iterates over pw_len_locked positions, rightmost first.
    // =========================================================================
    logic all_max;

    always_comb begin
        logic c;
        logic [IDX_BITS-1:0] sum;
        for (int k = 0; k < PW_LEN; k++)
            next_cidx[k] = cidx[k];
        c       = 1'b1;
        all_max = 1'b1;
        for (int k = PW_LEN-1; k >= 0; k--) begin
            if (k < pw_len_locked) begin
                sum = cidx[k] + {{(IDX_BITS-1){1'b0}}, c};
                if (sum >= 4'd10) begin
                    next_cidx[k] = '0;
                    c = 1'b1;
                end else begin
                    next_cidx[k] = sum;
                    c = 1'b0;
                end
                if (cidx[k] != CHARSET_SIZE[IDX_BITS-1:0] - 1)
                    all_max = 1'b0;
            end
        end
    end

    // =========================================================================
    // Match — only compare the locked-length slice (MSB-first)
    // =========================================================================
    logic match;
    always_comb begin
        match = 1'b1;
        for (int k = 0; k < PW_LEN; k++) begin
            if (k < pw_len_locked) begin
                if (candidate[((PW_LEN-1-k)*8) +: 8] !=
                    target   [((PW_LEN-1-k)*8) +: 8])
                    match = 1'b0;
            end
        end
    end

    // =========================================================================
    // Cracker FSM
    // =========================================================================
    typedef enum logic [2:0] {
        CR_IDLE,
        CR_INIT,
        CR_COMPARE,
        CR_INC,
        CR_FOUND,
        CR_EXHAUST
    } state_t;

    state_t cs;

    always_ff @(posedge clk) begin
        if (rst) begin
            cs       <= CR_IDLE;
            cracked  <= 1'b0;
            done     <= 1'b0;
            attempts <= '0;
            for (int k = 0; k < PW_LEN; k++) cidx[k] <= '0;
        end else begin
            case (cs)

                CR_IDLE: begin
                    cracked <= 1'b0;
                    done <= 1'b0;

                    if (uart_valid &&
                    ((uart_data == 8'h0D) || (uart_data == 8'h0A)) &&
                    (char_idx > 0))
                    begin
                        cs <= CR_INIT;
                    end
                end

                CR_INIT: begin
                    attempts <= '0;
                    for (int k = 0; k < PW_LEN; k++) cidx[k] <= '0;
                    cs <= CR_COMPARE;
                end

                CR_COMPARE: begin
                    attempts <= attempts + 1;
                    if (match)
                        cs <= CR_FOUND;
                    else if (all_max)
                        cs <= CR_EXHAUST;
                    else
                        cs <= CR_INC;
                end

                CR_INC: begin
                    for (int k = 0; k < PW_LEN; k++)
                        cidx[k] <= next_cidx[k];
                    cs <= CR_COMPARE;
                end

                CR_FOUND: begin
                    cracked <= 1'b1;
                    done    <= 1'b1;
                    if (uart_valid && uart_data >= "0" && uart_data <= "9") begin
                        target        <= '0;
                        target[((PW_LEN-1)*8)+:8] <= uart_data;
                        char_idx      <= 1;
                        pw_len_locked <= 0;
                        cs            <= CR_IDLE;
                    end 
                end

                CR_EXHAUST: begin
                    cracked <= 1'b0;
                    done    <= 1'b1;
                    if (uart_valid && uart_data >= "0" && uart_data <= "9") begin
                        target        <= '0;
                        target[((PW_LEN-1)*8)+:8] <= uart_data;
                        char_idx      <= 1;
                        pw_len_locked <= 0;
                        cs            <= CR_IDLE;
                    end
                end

            endcase
        end
    end

endmodule
