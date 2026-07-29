***************************************************************************
* 
* Filename: seven_segment4.sv
*
* Author: Ethan Thompson
* Description: Creates a multi-segment display controller that will drive 
* the four-digit seven segment display on the Basys3 board.
*
****************************************************************************/
module seven_segment4 #(parameter CLK_FREQUENCY = 100_000_000, REFRESH_RATE = 200) (
        input logic             clk,        //	Clock input
        input logic             rst,        // 	Reset input
        input logic  [15:0]     data_in,    // 	Indicates the 16-bit value to display on the 4 digits
        input logic  [3:0]      blank,      //	Indicates which digits to blank
        input logic  [3:0]      dp_in,      // 	Indicates which digit points to display
        output logic [7:0]      segment,    //  Cathode signals for seven-segment display segment[0] to CA, segment[6] to CG, and segment[7] to DP.
        output logic [3:0]      anode       // 	Anode signals for each of the four digits.
    );
    // Creating a Digital Display Counter
    // Determine the number of clock cycles to display each digit
    localparam DIGIT_DISPLAY_CLOCKS = CLK_FREQUENCY / REFRESH_RATE / 4;
    // Determine the number of bits needed to represent the maximum count value
    localparam DIGIT_COUNTER_WIDTH = $clog2(DIGIT_DISPLAY_CLOCKS);

    // Declare a signal used for this counter signal
    logic [DIGIT_COUNTER_WIDTH-1:0] digit_display_counter;

    // Digit Select counter
    logic [1:0] digit_select_counter;

    // Display Data to connect between the seven segment decoder and data selection MUX
    logic [3:0] display_data;


    // Creates a free running counter
    always_ff @(posedge clk)begin
        if(rst) digit_display_counter <= 0;
        else if(digit_display_counter == DIGIT_DISPLAY_CLOCKS - 1) digit_display_counter <= 0;
        else digit_display_counter <= digit_display_counter + 1;
    end

    // Changes which Seven_Seg display is shown by incrementing digit_select_counter
    always_ff @(posedge clk)begin
        if(rst) digit_select_counter <=0;
        else if(digit_display_counter == DIGIT_DISPLAY_CLOCKS - 1) digit_select_counter <= digit_select_counter + 1; 
    end  

    // Creates the multiplexer for assigning data_in to display_data
    always_comb begin
        case(digit_select_counter)
            2'b00: display_data = data_in[3:0];
            2'b01: display_data = data_in[7:4];
            2'b10: display_data = data_in[11:8];
            2'b11: display_data = data_in[15:12];
            default :  display_data = 4'b0000;
        endcase
    end 

    // Instances the seven segment from a previous lab
    // -----------------------------
    // Seven Segment Display Instance
    // -----------------------------
    seven_segment SSD (.data(display_data),.segment(segment[6:0]));

    // Creates the multiplexer for assigning the data point
    always_comb begin
        case(digit_select_counter)
            2'b00: segment[7] = ~dp_in[0];
            2'b01: segment[7] = ~dp_in[1];
            2'b10: segment[7] = ~dp_in[2];
            2'b11: segment[7] = ~dp_in[3];
        endcase
    end 

    // Creates the multiplexer for assigning which anode is on
    always_comb begin
        case(digit_select_counter)
            2'b00: anode = (blank | 4'b1110);
            2'b01: anode = (blank | 4'b1101);
            2'b10: anode = (blank | 4'b1011);
            2'b11: anode = (blank | 4'b0111);
        endcase
    end 



endmodule
