/***************************************************************************
* 
* Filename: password_top.sv
*
* Author: Ethan Thompson
* Description: Handles the top level aspects of the password cracker
*
****************************************************************************/
module password_top #(
    parameter FILENAME = "",
    parameter CLK_FREQUENCY = 100_000_000,
    parameter BAUD_RATE = 19_200,
    parameter WAIT_TIME_US = 5_000,
    parameter REFRESH_RATE = 200,
    parameter FOREGROUND_COLOR = 12'hfff,
    parameter BACKGROUND_COLOR = 12'h000
)(
    input  logic clk,           // Clock
    input  logic btnd,          // Reset
    input  logic uart_rx,       // Receive the data 

    // VGA
    output logic Hsync,
    output logic Vsync,
    output logic [3:0] vgaRed,
    output logic [3:0] vgaGreen,
    output logic [3:0] vgaBlue,

    // 7-seg
    output logic [3:0] anode,
    output logic [7:0] segment
);
    /////////////////////////////
    // Intermediate Declerations
    /////////////////////////////
    // Synchronizers
    logic rst, rst_sync1;

    
    // VGA timing
    logic hsync, vsync, blank;
    logic [9:0] pixel_x, pixel_y;
    logic last_row;
    logic last_column;
    // VGA 
    logic [11:0] rgb_next;
    logic [11:0] rgb_d1, rgb_d2, rgb_d3;
    logic hsync_d1, hsync_d2, hsync_d3;
    logic vsync_d1, vsync_d2, vsync_d3;
    logic write_char;
    logic [11:0] char_addr;
    logic [7:0] char_data;
    logic write_display;
    // Character Write declerations
    logic char_we;
    logic pixel_out;

    // Misc. Signals
    logic done_top;
    logic error_top;
    

    // Seven Seg
    logic [15:0] display_data;
    logic [3:0]  sev_seg_blank;
    
    // Intermeddiate Signals
    logic                              cracked;
    logic [31:0]                       attempts;
    logic [8*8-1:0]                    candidate;
    logic [8*8-1:0]                    target_out;
    logic [$clog2(9)-1:0]              chars_entered;



    // UART signals
    logic [7:0] rx_data;
    logic       rx_valid;
    logic       rx_parity;

    // Edge-detect signals
    logic receive;
    logic receive_d;
    logic ack;

    // Generate 1-clock pulse
    always_ff @(posedge clk) begin
        if (rst)
            receive_d <= 1'b0;
        else
            receive_d <= receive;
    end

    assign ack      = receive & ~receive_d;
    assign rx_valid = ack;

    // UART receiver
    rx #(
        .CLK_FREQUENCY(CLK_FREQUENCY),
        .BAUD_RATE(BAUD_RATE)
    ) uart_rx_inst (
        .clk(clk),
        .rst(rst),
        .Sin(uart_rx),
        .Receive(receive),
        .ReceiveAck(ack),
        .Dout(rx_data),
        .parityErr(rx_parity)
    );




    /////////////////
    // Synchronizers
    /////////////////
    always_ff @(posedge clk) begin
        // Synchronizer for rst
        rst_sync1 <= btnd;
        rst <= rst_sync1;

    end


    /////////////////
    // Password Cracker
    /////////////////
    logic [$clog2(9)-1:0] pw_len_out;


    password_crack #(.PW_LEN(8)) u_crack (
        .clk(clk),
        .rst(rst),
        
        .uart_data(rx_data),
        .uart_valid(rx_valid),

        .cracked(cracked),
        .done(done_top),
        .attempts(attempts), // 32 Bits
        .candidate(candidate), //[PW_LEN*8-1:0]
        .target_out(target_out), //[PW_LEN*8-1:0]
        .chars_entered(chars_entered), //[$clog2(PW_LEN+1)-1:0]
        .pw_len_out(pw_len_out)   // add this
    );


    ///////////////////////
    // Character Generator
    ///////////////////////
    // Calls the char_gen module
    char_gen #(.FILENAME(FILENAME)) 
    cg (
        .clk(clk),
        .char_we(char_we),  
        .char_addr(char_addr),
        .char_value(char_data[6:0]),
        .pixel_x(pixel_x),
        .pixel_y(pixel_y[8:0]),
        .pixel_out(pixel_out)
    );

    //////////////
    // VGA Timing
    //////////////
    // vga_timing Module
    vga_timing vga_timing (
        .clk(clk),
        .rst(rst),
        .h_sync(hsync),
        .v_sync(vsync),
        .pixel_x(pixel_x),
        .pixel_y(pixel_y),
        .last_column(last_column),
        .last_row(last_row),
        .blank(blank)
    );
    // Covers what to do when the last_column and last_row are met
    assign write_display = (last_column && last_row);
    /////////////////////
    // Write VGA Monitor
    /////////////////////
    write_vga #(.TARGET_ROW(10),
    .TARGET_COLUMN(15),
    .CANDIDATE_ROW(11),
    .CANDIDATE_COLUMN(15),
    .ATTEMPTS_ROW(12),
    .ATTEMPTS_COLUMN(15), 
    .PW_LEN(8)) 
    vga (
        .clk(clk),
        .rst(rst),
        .write_display(write_display),
        .target(target_out),
        .candidate(candidate),
        .attempts(attempts),
        .char_addr(char_addr),
        .char_data(char_data),
        .write_char(write_char)
    );
    assign char_we = write_char;
    //////////////////////////
    // 3-Cycle Pipeline Delay
    //////////////////////////
    // Synchronizer
    always_ff @(posedge clk) begin
        rgb_d1 <= rgb_next;
        rgb_d2 <= rgb_d1;
        rgb_d3 <= rgb_d2;

        hsync_d1 <= hsync;
        hsync_d2 <= hsync_d1;
        hsync_d3 <= hsync_d2;

        vsync_d1 <= vsync;
        vsync_d2 <= vsync_d1;
        vsync_d3 <= vsync_d2;
    end

    //////////////////////////
    // Seven Segment Display
    //////////////////////////
    // Calling the seven_segment4 Module
    seven_segment4 #(.CLK_FREQUENCY(CLK_FREQUENCY),.REFRESH_RATE(REFRESH_RATE)) 
    SSD (
        .clk(clk),
        .rst(rst),
        .data_in(display_data),
        .blank(sev_seg_blank),
        .dp_in(4'b0000),
        .anode(anode), 
        .segment(segment)
    );
    

    // Display logic
    always_comb begin
        if(!done_top) display_data = 16'hFFFF;
        else if (cracked) display_data = 16'hc0de;
        else display_data = 16'hdead;
    end

    assign sev_seg_blank = {4{~done_top}};

    //////////////
    // VGA Logic
    /////////////
    // Flip-Flop for vgaRed
    always_ff @(posedge clk)begin
        if(rst) vgaRed <= 4'h0;
        else vgaRed <= rgb_d3[11:8];
    end
    // Flip-Flop for vgaGreen
    always_ff @(posedge clk)begin
        if(rst) vgaGreen <= 4'h0;
        else vgaGreen <= rgb_d3[7:4];
    end
    // Flip-Flop for vgaBlue
    always_ff @(posedge clk)begin
        if(rst) vgaBlue <= 4'h0;
        else vgaBlue <= rgb_d3[3:0];
    end

    // Output
    assign Hsync = hsync_d3;
    assign Vsync = vsync_d3;

    // comvinational logic for whenter to display black or white on the screen
    always_comb begin
    if (pixel_out)
        rgb_next = FOREGROUND_COLOR;
    else
        rgb_next = BACKGROUND_COLOR;
    end

endmodule
