/***************************************************************************
* 
* Filename: seven_segment.sv
*
* Author: Ethan Thompson
* Description: This file is the logic for writing to a seven segment display
*
****************************************************************************/

module seven_segment (
        input logic  [3:0]   data,
        output logic [6:0]   segment
    );
    // Intermediate signals
    logic A, B, C, D;
    logic not_A, not_B, not_C, not_D;

    // NOTs
    not(not_A, A);
    not(not_B, B);
    not(not_C, C);
    not(not_D, D);
    

    assign A = data[3];
    assign B = data[2];
    assign C = data[1];
    assign D = data[0];


    /////////////////
    // Segment A
    /////////////////
    // Segment A: Dataflow SV using an assign statement and a logical expression in ‘minterm’ SOP form

    assign segment[0] = (~A & ~B & ~C & D) || (~A &  B &  ~C & ~D) || ( A & ~B &  C &  D) || ( A &  B & ~C &  D);

    /////////////////
    // Segment B
    /////////////////
    // Segment B: Dataflow SV using an assign statement and a logical expression in ‘maxterm’ POS form

    assign segment[1] = 
    (A | B | C | D) &
    (A | B | C | ~D) &
    (A | B | ~C | D) &
    (A | B | ~C | ~D) &
    (A | ~B | C | D) &
    (A | ~B | ~C | ~D) &
    (~A | B | C | D) &
    (~A | B | C | ~D) &
    (~A | B | ~C | D) &
    (~A | ~B | C | ~D);
        
    /////////////////
    // Segment C
    /////////////////
    // Segment C: Gate-level in minimized SOP form (use only gates!)

    // Intermediate signals for segment C

    logic not_A_not_B_C_not_D, A_B_not_D, A_B_and_C;


    // ANDs 
    and(not_A_not_B_C_not_D, not_A, not_B, C, not_D);
    and(A_B_not_D, A, B, not_D);
    and(A_B_and_C, A, B, C);

    // OR, assigning value to segment[2] at the end

    or(segment[2], not_A_not_B_C_not_D, A_B_not_D, A_B_and_C);


    /////////////////
    // Segment D
    /////////////////
    // Segment D: Use a look-up table LUT4 primitive (see below for details)

    LUT4 #(.INIT(16'h8492)) seg_LUT (.O(segment[3]), .I0(data[0]), .I1(data[1]), .I2(data[2]), .I3(data[3]) );
        
    /////////////////
    // Segment E
    /////////////////
    // Segment E: Gate-level in minimized POS form   
    // Intermediate signals
    logic B_or_D, not_A_or_not_B, not_A_or_not_C, not_C_or_D; 

    // ORs
    or(B_or_D, B, D);
    or(not_A_or_not_B, not_A, not_B);
    or(not_A_or_not_C, not_A, not_C);
    or(not_C_or_D, not_C, D);

    // AND
    and(segment[4], B_or_D, not_A_or_not_B, not_A_or_not_C, not_C_or_D);


    
    /////////////////
    // Segment F
    /////////////////
    // Segment F: Dataflow SV using an assign statement and the ?: (sometimes called the ternary) operator.
    assign segment[5] = (~A & ~B & ~C & D) ? 1'b1 : (~A & ~B & C & ~D) ? 1'b1 : (~A & ~B & C & D) ? 1'b1 : (~A & B & C & D) ? 1'b1 : (A & B & ~C & D) ? 1'b1 : 1'b0;

        
    /////////////////
    // Segment G
    /////////////////
    // Segment G: Gate-level only using ‘nand’ gates

    logic nA, nB, nC, nD;
    logic t1, t2, t3;

    // Inverters using NAND
    nand (nA, A, A);
    nand (nB, B, B);
    nand (nC, C, C);
    nand (nD, D, D);

    // Product terms (inverted)
    nand (t1, nA, nB, nC); // (A̅ B̅ C̅)'
    nand (t2, nD, nC, A, B);  // (A̅ B C)'
    nand (t3, C, B, D, nA); // (C B̅ D̅)'

    // Final NAND (OR of products)
    nand (segment[6], t1, t2, t3);
 
endmodule
