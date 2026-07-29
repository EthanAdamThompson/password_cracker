/***************************************************************************
* 
* Filename: vga_timing.sv
*
* Author: Ethan Thompson
* Description: Creates the necessary timing signals for the VGA display
* 
*
****************************************************************************/
module vga_timing  (
        input logic              clk,            //  Clock input
        input logic              rst,            //  Reset input
        output logic             h_sync,         //  Low asserted horizontal sync VGA signal
        output logic             v_sync,         //	 Low asserted vertical sync VGA signal
        output logic  [9:0]      pixel_x,        //	 Column of the current VGA pixel
        output logic  [9:0]      pixel_y,        //  Row of the current VGA pixel
        output logic             last_column,    //  The current pixel_x correspond to the last visible column
        output logic             last_row,       //  The current pixel_y corresponds to the last visible row
        output logic             blank           //  The current pixel is part of a horizontal or vertical retrace. output must be blanked.
    );

    // Digit Select counter
    logic [1:0] digit_display_counter;

    // Every fourth tick from the clock will flip pixel_en from enabled to disabled.
    logic pixel_en;


    // Clock Divider Counter
    always_ff @(posedge clk)begin
        if(rst) digit_display_counter <= 0;
        else digit_display_counter <= digit_display_counter + 1;
    end
    assign pixel_en = (digit_display_counter == 2'b11);

    // Horizontal Pixel Counter
    always_ff @(posedge clk)begin
        if(rst) pixel_x <= 0;
        else if(pixel_en == 1 )begin
            if(pixel_x >= 799) pixel_x <= 0;
            else pixel_x <= pixel_x + 1;
        end
    end
    assign last_column = (pixel_x == 639);

    // Vertical Pixel Counter
    always_ff @(posedge clk)begin
        if(rst) pixel_y <= 0;
        else if(pixel_x == 799 && pixel_en == 1 )begin
            if(pixel_y >= 520) pixel_y <= 0;
            else pixel_y <= pixel_y + 1;
        end
    end
    assign last_row = (pixel_y == 479);

    // h_sync
    always_comb begin
        if(pixel_x <= 639) h_sync = 1;
        else if(pixel_x <= 655) h_sync = 1;  
        else if(pixel_x <= 751) h_sync = 0;
        else h_sync = 1; 
    end

    // v_sync
    always_comb begin
        if(pixel_y <= 479) v_sync = 1;
        else if(pixel_y <= 489) v_sync = 1;  
        else if(pixel_y <= 491) v_sync = 0;
        else v_sync = 1; 
    end

    // Blank when pixel_x or pixel_y is in a non-visible area    
    assign blank = ((pixel_x >= 640) || (pixel_y >= 480));


    
endmodule
