//---------------------------
// B buffer
//
// Description:
// Holds one column of B (8 int8) that goes to all PEs. A new column is
// loaded from SRAM B every compute cycle. When load_i is low the column
// is kept.
//
// Parameters:
// - InDataWidth : Width of the input data
// - ArrK        : Values in the column
//
// Ports:
// - clk_i       : Clock input
// - rst_ni      : Active-low reset input
// - load_i      : Load a new column
// - b_i         : SRAM B word, b_i[k]
// - b_o         : Stored column to all PEs, b_o[k]
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
  // Area logging
  // 1 per 32-bit register: 8 B / 4 B = 2
  //--------------------------------
  initial begin
    #0;
    metrics_pkg::area += ArrK * InDataWidth / 32;
    $display("%m added %0d to area", ArrK * InDataWidth / 32);
  end

  //--------------------------------
  // Energy logging
  // Every load writes 64 bits = 2. Reading is free.
  //--------------------------------
  always @(posedge clk_i) begin
    if (rst_ni && load_i) begin
      metrics_pkg::energy += ArrK * InDataWidth / 32.0;
    end
  end

endmodule
