//---------------------------
// B buffer
//
// Description:
// This module holds the B column (ArrK int8 = 8 B) that is broadcast to all
// PEs of the MAC array. Every compute cycle needs a new column n, so the
// buffer is loaded with one SRAM B word (port B = 8 B) per cycle. When the
// controller stalls, load_i stays low and the column is kept.
//
// Parameters:
// - InDataWidth : Width of the input data (int8)
// - ArrK        : Number of values in the column (inputs per PE)
//
// Ports:
// - clk_i       : Clock input
// - rst_ni      : Active-low reset input
// - load_i      : Load a new column from SRAM B
// - b_i         : The SRAM B word, b_i[k] (ArrK values)
// - b_o         : The stored column, b_o[k], to all PEs
//---------------------------

module b_buffer #(
  parameter int unsigned InDataWidth = 8,
  parameter int unsigned ArrK = 8
) (
  input  logic  clk_i,
  input  logic  rst_ni,
  input  logic  load_i,
  input  logic signed [ArrK-1:0][InDataWidth-1:0] b_i,
  output logic signed [ArrK-1:0][InDataWidth-1:0] b_o
);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      b_o <= '0;
    end else if (load_i) begin
      b_o <= b_i;
    end
  end

  //--------------------------------
  // Area logging (Table 3: 1 per 32-bit register)
  //--------------------------------
  initial begin
    #0;
    metrics_pkg::area += ArrK * InDataWidth / 32;
    $display("%m added %0d to area", ArrK * InDataWidth / 32);
  end

  //--------------------------------
  // Energy logging (Table 3: 1 per 32-bit register update)
  // Every load updates 64 bits: 2 units. Reading is free.
  //--------------------------------
  always @(posedge clk_i) begin
    if (rst_ni && load_i) begin
      metrics_pkg::energy += ArrK * InDataWidth / 32.0;
    end
  end

endmodule
