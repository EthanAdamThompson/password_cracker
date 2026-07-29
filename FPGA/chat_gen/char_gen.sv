/***************************************************************************
* 
* Filename: char_gen.sv
*
* Author: Ethan Thompson
* Description: Creates the character Generation module
*
****************************************************************************/
module char_gen #(parameter FILENAME = "font_rom.sv")(
        input logic  clk,               // 100 MHz System Clock
        input logic  char_we,           // Character write enable
        input logic  [11:0] char_addr,  // The write address of the character memory
        input logic  [6:0] char_value,  // The 7-bit value to pad and write into the character memory
        input logic  [9:0] pixel_x,     // The column address of the current pixel
        input logic  [8:0] pixel_y,     // The row address of the current pixel
        output logic pixel_out          // The value of the character output pixel
    );
    //////////////////////////////////
    // Intermediate Logic Declerations
    //////////////////////////////////
    // Character Memory
    logic [7:0] mem_data [0:4095];
    logic [7:0] char_read_value;
    logic [11:0] char_read_addr;

    // Font ROM
    logic [10:0] rom_addr;
    logic [7:0]  rom_data;
    logic [8:0] pixel_y_r;

    // Pipeline pixel_x (2 cycles)
    logic [9:0] pixel_x_r1, pixel_x_r2;

    // 


    // =========================
    // Character Memory
    // =========================
    // Initialize memory
    initial begin
        if (FILENAME != "")
            $readmemh(FILENAME, mem_data);
    end

    // Synchronous logic (Write Port)
    always_ff @(posedge clk)begin
        if(char_we) mem_data[char_addr] <= {1'b0, char_value};
    end

    // Generate read address (row = pixel_y/16, col = pixel_x/8)
    assign char_read_addr = {pixel_y[8:4], pixel_x[9:3]};

    // Read port
    always_ff @(posedge clk) begin
        char_read_value <= mem_data[char_read_addr];
    end


    // =========================
    // Font ROM
    // =========================
    // Assigns the ROM address based on the char_read_value and pixel_y_r
    assign rom_addr = {char_read_value[6:0], pixel_y_r[3:0]};
    // calling the font_rom module
    font_rom rom (.clk(clk),.addr(rom_addr),.data(rom_data));

    // =========================
    // Pipeline pixel_x (2 cycles)
    // =========================
    // x delay using a synchronizer
    always_ff @(posedge clk) begin
        pixel_x_r1 <= pixel_x;
        pixel_x_r2 <= pixel_x_r1;
    end
    // Single delay for y
    always_ff @(posedge clk) begin
        pixel_y_r <= pixel_y;
    end

    // =========================
    // Pixel selection
    // =========================
    assign pixel_out = rom_data[7 - pixel_x_r2[2:0]];

endmodule
