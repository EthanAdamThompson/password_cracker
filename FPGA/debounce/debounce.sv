/***************************************************************************
* 
* Filename: debounce.sv
*
* Author: Ethan Thompson
* Description: This file creates the state machine for debouncing
*
****************************************************************************/

module debounce #(parameter CLK_FREQUENCY = 100_000_000, WAIT_TIME_US = 5000)(
        input logic  clk,           // Clock
        input logic  rst,           // Active high synchronous reset
        input logic  noisy,         // Noisy debounce input
        output logic debounced      // Debounced output
    );


    // Determine the number of clock cycles to display each digit
    localparam TIMER_CLOCK_COUNT = (CLK_FREQUENCY / 1_000_000) * WAIT_TIME_US;
    // Determine the number of bits needed to represent the maximum count value
    localparam TIMER_COUNTER_WIDTH = $clog2(TIMER_CLOCK_COUNT);
    // Declare a signal used for this counter signal
    logic [TIMER_COUNTER_WIDTH-1:0] timer_counter;
    // Creates a signal that is asserted when TIMER_CLOCK_COUNT is at its maximum value
    logic timerDone;
    // Decleration of clrTimer
    logic clrTimer;

    // Creates a free running counter
    always_ff @(posedge clk)begin
        if(rst) timer_counter <= 0;
        else if(clrTimer) timer_counter <= 0;
        else if(timer_counter == TIMER_CLOCK_COUNT - 1) timer_counter <= 0;
        else timer_counter <= timer_counter + 1;
    end
    assign timerDone = (timer_counter == (TIMER_CLOCK_COUNT - 1));

    //////////////////
    // State Machine:
    //////////////////

    // Decleration of the states 
    typedef enum logic [1:0] {
        S0,
        S1,
        S2,
        S3
    } state_t;

    state_t state, next_state;

    // rst button implentation, FF block to hold the state values
    always_ff @(posedge clk) begin
        if (rst)
            state <= S0;
        else
            state <= next_state;
    end

    // always_comb block to change states
    always_comb begin
        next_state = state;  // default

        case (state)
            S0: if (noisy) next_state = S1; // No second transition needed for !noisy due to default
            S1: if (noisy && timerDone)  next_state = S2;
                    else if(!noisy) next_state = S0; // (noisy && !timerDone) covered by default
            S2: if (!noisy) next_state = S3; // No second transition for noisy needed due to default
            S3: if (!noisy && timerDone) next_state = S0;
                    else if (noisy) next_state = S2; // (!noisy && !timerDone) covered by default
        endcase
    end

    // Second always_comb block for the debounced value
    always_comb begin
        case (state)
            S0: debounced = 0;
            S1: debounced = 0;
            S2: debounced = 1;
            S3: debounced = 1;
        endcase
    end

    // Third always_comb block for the 
    always_comb begin
        case (state)
            S0: clrTimer = 1;
            S1: clrTimer = 0;
            S2: clrTimer = 1;
            S3: clrTimer = 0;
        endcase
    end
endmodule 
