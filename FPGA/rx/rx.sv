/***************************************************************************
* 
* Filename: rx.sv
*
* Author: Ethan Thompson
* Description: Creates the RX for the uart. Uses a state machine to track
* When the data comes in and how to send it while tracking Parity
*
******************************************************* *********************/
module rx #(parameter CLK_FREQUENCY = 100_000_000, BAUD_RATE = 19_200)(
        input logic  clk,           // 100 MHz System Clock
        input logic  rst,           // System reset active high
        input logic  Sin,           // Receiver serial input signal
        output logic Receive,       // Indicates that a byte has been received over RX line (Sin), and is retrieved from the Dout pins. 
        input logic  ReceiveAck,    // Indicates that the byte on the Dout pins has been received. (ReceiveAck serves as ACK)
        output logic [7:0] Dout,    // 8-bit data received by the module. Valid when Receive is high.
        output logic parityErr      // Indicates that there was a parity error. Valid when Receive is high.
    );
    // Determine the number of clock cycles 
    localparam TIMER_CLOCK_COUNT = (CLK_FREQUENCY / BAUD_RATE);
    // Determine the number of bits needed to represent the maximum count value
    localparam TIMER_COUNTER_WIDTH = $clog2(TIMER_CLOCK_COUNT);
    // Declare a signal used for this counter signal
    logic [TIMER_COUNTER_WIDTH-1:0] timer_counter;

    // FSM decleration
    typedef enum logic [2:0] {
        POWERUP,
        IDLE,
        COUNT,
        WAIT
    } state_t;

    state_t state, next_state;

    // Baud Timer variables
    logic full_count;
    logic half_count;

    // Baud Timer
     always_ff @(posedge clk)begin
        if (rst) timer_counter <= 0;
        else if (state != COUNT) timer_counter <= 0;
        else if (state == COUNT) begin
            if (timer_counter == TIMER_CLOCK_COUNT - 1)timer_counter <= 0;
            else timer_counter <= timer_counter + 1;
        end
    end
    assign half_count = (timer_counter == ((TIMER_CLOCK_COUNT - 1)/2));
    assign full_count = (timer_counter == (TIMER_CLOCK_COUNT - 1));

    // Bit Counter variables
    logic [3:0] bits_received;

    // Bit Counter
    always_ff @(posedge clk)begin
        if(rst) bits_received <= 0;
        else if (state == IDLE) bits_received <= 0;
        else if(half_count) 
            if(bits_received == 10) bits_received <= 0;
            else bits_received <= bits_received + 1;
    end

    // Shift Register Variables
    logic [9:0] shift_reg;
    logic shift_enable;


    // Shift Register
    always_ff @(posedge clk)begin
        if(rst) shift_reg <= 9'b000000000;
        else if ((state == COUNT) && half_count ) shift_reg <= {Sin,shift_reg[9:1]}; 
    end
    assign Dout = shift_reg[7:0];

    // Parity Checker (latched after full byte received)
    logic parity_error_latched;

    // Latch parity only when full byte received (state WAIT)
    always_ff @(posedge clk) begin
        if (rst)
            parity_error_latched <= 1'b0;
        else if (state == WAIT && Receive) // latch once when byte is valid
            parity_error_latched <= ~(^shift_reg[8:0]); // ^Dout computes parity of data bits
        else if (state == IDLE)
            parity_error_latched <= 1'b0; // clear for next byte
        end
    assign parityErr = parity_error_latched;

    // Finite State Machine 
    always_ff @(posedge clk) begin
    if(rst)
        state <= POWERUP;
    else
        state <= next_state;
    end

    // Finite State Machine logic
    always_comb begin
        next_state = state;  // default

        case (state)
           POWERUP:
            if(Sin == 1)
                next_state = IDLE;

            IDLE:
            if(Sin == 0)
                next_state = COUNT;

            COUNT:
            if(half_count && bits_received == 10)
                next_state = WAIT;

            WAIT:
            if(ReceiveAck)
                next_state = IDLE;
        endcase
    end

     // -------------------------------------------------
    // FSM Output Logic
    // -------------------------------------------------
    always_comb begin
        shift_enable = 0;
        Receive = 0;

        case (state)

            IDLE: begin
                shift_enable = 0;
            end

            COUNT: begin
                shift_enable = 1;
            end

            WAIT: begin
                Receive = 1;
            end

        endcase
    end


endmodule
