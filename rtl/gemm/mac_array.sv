//---------------------------
// MAC array
// Description:
// This module builds the spatial MAC array of the accelerator out of
// mac_pe_bank instances. It contains no arithmetic of its own: a
// generate loop copies the PE ArrM times during elaboration.
//
// The final design is 64 x 8 x 1 (M x K x N) = 512 multipliers

// Parameters:
// - InDataWidth  : Width of the input data (int8)
// - OutDataWidth : Width of the output data (int32)
// - ArrM         : Number of PEs (parallel along M)
// - ArrK         : Number of inputs per PE (parallel along K)
// - NumAcc       : Number of accumulators per PE (output columns per block)
//
// Ports:
// - clk_i        : Clock input
// - rst_ni       : Active-low reset input
// - a_i          : A tile, a_i[m][k] (ArrM x ArrK values)
// - b_i          : One column of B, b_i[k] (ArrK values), broadcast to all PEs
// - acc_sel_i    : Which accumulator (column of the block) to update this cycle
// - valid_i      : A and B inputs are valid, so compute this cycle
// - init_save_i  : First k-step of a column: load instead of accumulate
// - acc_clr_i    : Clear all accumulators
// - c_o          : All accumulators, c_o[m][j] = row m, column j of the block
//---------------------------

module mac_array #(
  parameter int unsigned InDataWidth  = 8,
  parameter int unsigned OutDataWidth = 32,
  parameter int unsigned ArrM = 64,
  parameter int unsigned ArrK = 8,
  parameter int unsigned NumAcc = 8
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic signed [ArrM-1:0][ArrK-1:0][ InDataWidth-1:0] a_i,
  input  logic signed [  ArrK-1:0][ InDataWidth-1:0] b_i,
  input  logic [$clog2(NumAcc)-1:0] acc_sel_i,
  input  logic valid_i,
  input  logic init_save_i,
  input  logic acc_clr_i,
  output logic signed [  ArrM-1:0][NumAcc-1:0][OutDataWidth-1:0] c_o
);

  //---------------------------
  // PE column: ArrM PEs, one per row of the output tile
  //---------------------------
  genvar m;
  for (m = 0; m < ArrM; m++) begin : g_m
    mac_pe_bank #(
      .InDataWidth ( InDataWidth),
      .NumInputs ( ArrK ),   // K is summed inside the PE
      .OutDataWidth ( OutDataWidth),
      .NumAcc ( NumAcc)
    ) i_pe (
      .clk_i ( clk_i),
      .rst_ni ( rst_ni),
      .a_i ( a_i[m]),   // row m of A: one row per PE
      .b_i ( b_i),   // the same B column for all PEs
      .acc_sel_i ( acc_sel_i),
      .a_valid_i ( valid_i),
      .b_valid_i ( valid_i),
      .init_save_i ( init_save_i),
      .acc_clr_i ( acc_clr_i),
      .c_o ( c_o[m] )    // the NumAcc accumulators of row m
    );
  end

endmodule
