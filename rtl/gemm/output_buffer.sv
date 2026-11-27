//---------------------------
// Output buffer
//
// Description:
// This module takes a finished block of the MAC array (ArrM x NumAcc int32 =
// 64 rows x 8 columns = 2 KB) in ONE cycle and then drains it to SRAM C, one
// 16 B word (WordOutputs = 4 int32) per cycle, while the array already
// computes the next block.
//
// Drain order: column by column, and inside a column 4 rows per word, so word
// (col, grp) holds C[4*grp ... 4*grp+3][col] with data_o[i] = row 4*grp + i.
// A full block is 8 columns x 16 words = 128 cycles. A block can have fewer
// columns (num_cols_i, a GeMV block has 1): only those are copied and drained.
// The controller turns (col_o, grp_o) into the SRAM C address.
//
// ready_o is high when a load is accepted: when the buffer is empty, or in
// the cycle of the last word, so that blocks can follow without a gap.
// The controller must only load when ready_o is high.
//
// Parameters:
// - OutDataWidth : Width of the output data (int32)
// - ArrM         : Number of rows in a block (one per PE)
// - NumAcc       : Number of columns in a full block (accumulators per PE)
// - WordOutputs  : Outputs in one SRAM C word (16 B / 4 B = 4)
//
// Ports:
// - clk_i        : Clock input
// - rst_ni       : Active-low reset input
// - load_i       : Copy the block from the array (only when ready_o is high)
// - num_cols_i   : Columns in this block, 1 .. NumAcc
// - c_i          : All accumulators of the array, c_i[m][j] = row m, column j
// - ready_o      : A load is accepted in this cycle
// - wr_en_o      : data_o is a valid word for SRAM C in this cycle
// - col_o        : Column of the block that data_o belongs to
// - grp_o        : Row group of data_o (rows 4*grp_o ... 4*grp_o+3)
// - data_o       : One SRAM C word, data_o[i] = C[4*grp_o + i][col_o]
//---------------------------

module output_buffer #(
  parameter int unsigned OutDataWidth = 32,
  parameter int unsigned ArrM = 64,
  parameter int unsigned NumAcc = 8,
  parameter int unsigned WordOutputs = 4,
  // Words per column: 64 / 4 = 16
  parameter int unsigned NumGroups = ArrM / WordOutputs
) (
  input  logic clk_i,
  input  logic rst_ni,
  // Load side (from the MAC array)
  input  logic load_i,
  input  logic [$clog2(NumAcc+1)-1:0] num_cols_i,
  input  logic signed [ArrM-1:0][NumAcc-1:0][OutDataWidth-1:0] c_i,
  output logic ready_o,
  // Drain side (to SRAM C)
  output logic wr_en_o,
  output logic [$clog2(NumAcc)-1:0] col_o,
  output logic [$clog2(NumGroups)-1:0] grp_o,
  output logic signed [WordOutputs-1:0][OutDataWidth-1:0] data_o
);

  // Storage and drain state
  logic signed [ArrM-1:0][NumAcc-1:0][OutDataWidth-1:0] buf_q;
  logic busy_q;   // a block is draining
  logic [$clog2(NumAcc+1)-1:0] cols_q;   // columns of that block
  logic [$clog2(NumAcc)-1:0] col_q;    // word being drained:
  logic [$clog2(NumGroups)-1:0] grp_q;    // column and row group
  logic last_word;

  assign last_word = busy_q && (grp_q == NumGroups - 1) && (col_q == cols_q - 1);
  assign ready_o = !busy_q || last_word;

  // Copy on load, otherwise step through the words of the block
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int m = 0; m < ArrM; m++) buf_q[m] <= '0;
      busy_q <= 1'b0;
      cols_q <= '0;
      col_q  <= '0;
      grp_q  <= '0;
    end else if (load_i) begin
      for (int m = 0; m < ArrM; m++) begin
        for (int j = 0; j < NumAcc; j++) begin
          if (j < num_cols_i) buf_q[m][j] <= c_i[m][j];   // unused columns keep their clock off
        end
      end
      busy_q <= 1'b1;
      cols_q <= num_cols_i;
      col_q  <= '0;
      grp_q  <= '0;
    end else if (busy_q) begin
      if (last_word) begin
        busy_q <= 1'b0;
        col_q  <= '0;
        grp_q  <= '0;
      end else if (grp_q == NumGroups - 1) begin
        col_q <= col_q + 1'b1;
        grp_q <= '0;
      end else begin
        grp_q <= grp_q + 1'b1;
      end
    end
  end

  // The word being drained (a mux, reading the buffer is free)
  always_comb begin
    for (int i = 0; i < WordOutputs; i++) begin
      data_o[i] = buf_q[grp_q * WordOutputs + i][col_q];
    end
  end

  assign wr_en_o = busy_q;
  assign col_o   = col_q;
  assign grp_o   = grp_q;

  // Wrong use by the controller
  always @(posedge clk_i) begin
    if (rst_ni && load_i && !ready_o) begin
      $error("%m: load while the previous block is still draining");
    end
    if (rst_ni && load_i && (num_cols_i == 0 || num_cols_i > NumAcc)) begin
      $error("%m: num_cols_i = %0d is outside 1 .. %0d", num_cols_i, NumAcc);
    end
  end

  //--------------------------------
  // Area logging (Table 3: 1 per 32-bit register)
  // ArrM x NumAcc int32 = 64 * 8 = 512
  //--------------------------------
  initial begin
    #0;
    metrics_pkg::area += ArrM * NumAcc * OutDataWidth / 32;
    $display("%m added %0d to area", ArrM * NumAcc * OutDataWidth / 32);
  end

  //--------------------------------
  // Energy logging (Table 3: 1 per 32-bit register update)
  // A load updates ArrM registers per column of the block: 64 per column,
  // 512 for a full block. Draining only reads, which is free.
  //--------------------------------
  always @(posedge clk_i) begin
    if (rst_ni && load_i) begin
      metrics_pkg::energy += num_cols_i * ArrM * OutDataWidth / 32.0;
    end
  end

endmodule
