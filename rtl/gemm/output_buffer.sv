//---------------------------
// Output buffer
//
// Description:
// Copies a finished block from the MAC array (64 x 8 int32) in one cycle
// and writes it to SRAM C one word (4 int32) per cycle, while the array
// works on the next block.
//
// The words go out column by column, 16 words per column, so a full block
// takes 128 cycles. A block can have fewer columns (num_cols_i, 1 for a
// GeMV), then only those columns are copied and written.
// ready_o is high when the buffer is empty or on its last word, so the
// next block can be loaded without a gap.
//
// Parameters:
// - OutDataWidth : Width of the output data
// - ArrM         : Rows in a block (one per PE)
// - NumAcc       : Columns in a full block
// - WordOutputs  : Values in one SRAM C word
//
// Ports:
// - clk_i        : Clock input
// - rst_ni       : Active-low reset input
// - load_i       : Copy a block (only when ready_o is high)
// - num_cols_i   : Columns in the block (1 to 8)
// - c_i          : Accumulators of the array, c_i[m][j]
// - ready_o      : A new block can be loaded
// - wr_en_o      : data_o should be written to SRAM C
// - col_o        : Column of the word
// - grp_o        : Row group of the word (rows 4*grp_o to 4*grp_o+3)
// - data_o       : The word, data_o[i] = C[4*grp_o + i][col_o]
//---------------------------

module output_buffer #(
  parameter int unsigned OutDataWidth = 32,
  parameter int unsigned ArrM = 64,
  parameter int unsigned NumAcc = 8,
  parameter int unsigned WordOutputs = 4,
  // 16 words per column
  parameter int unsigned NumGroups = ArrM / WordOutputs
) (
  input  logic clk_i,
  input  logic rst_ni,
  // From the MAC array
  input  logic load_i,
  input  logic [$clog2(NumAcc+1)-1:0] num_cols_i,
  input  logic signed [ArrM-1:0][NumAcc-1:0][OutDataWidth-1:0] c_i,
  output logic ready_o,
  // To SRAM C
  output logic wr_en_o,
  output logic [$clog2(NumAcc)-1:0] col_o,
  output logic [$clog2(NumGroups)-1:0] grp_o,
  output logic signed [WordOutputs-1:0][OutDataWidth-1:0] data_o
);

  // Block storage and drain counters
  logic signed [ArrM-1:0][NumAcc-1:0][OutDataWidth-1:0] buf_q;
  logic busy_q;   // a block is being written out
  logic [$clog2(NumAcc+1)-1:0] cols_q;   // columns of that block
  logic [$clog2(NumAcc)-1:0] col_q;    // column of the current word
  logic [$clog2(NumGroups)-1:0] grp_q;    // row group of the current word
  logic last_word;

  assign last_word = busy_q && (grp_q == NumGroups - 1) && (col_q == cols_q - 1);
  assign ready_o = !busy_q || last_word;

  // Copy a block on load, otherwise go to the next word
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
          if (j < num_cols_i) buf_q[m][j] <= c_i[m][j];   // only the used columns
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

  // Current word
  always_comb begin
    for (int i = 0; i < WordOutputs; i++) begin
      data_o[i] = buf_q[grp_q * WordOutputs + i][col_q];
    end
  end

  assign wr_en_o = busy_q;
  assign col_o   = col_q;
  assign grp_o   = grp_q;

  // Checks for wrong use
  always @(posedge clk_i) begin
    if (rst_ni && load_i && !ready_o) begin
      $error("%m: load while the previous block is still draining");
    end
    if (rst_ni && load_i && (num_cols_i == 0 || num_cols_i > NumAcc)) begin
      $error("%m: num_cols_i = %0d is outside 1 .. %0d", num_cols_i, NumAcc);
    end
  end

  //--------------------------------
  // Area logging
  // 1 per 32-bit register: 64 * 8 = 512
  //--------------------------------
  initial begin
    #0;
    metrics_pkg::area += ArrM * NumAcc * OutDataWidth / 32;
    $display("%m added %0d to area", ArrM * NumAcc * OutDataWidth / 32);
  end

  //--------------------------------
  // Energy logging
  // 1 per 32-bit register that is written, so 64 per column.
  // Writing the words out only reads the buffer, which is free.
  //--------------------------------
  always @(posedge clk_i) begin
    if (rst_ni && load_i) begin
      metrics_pkg::energy += num_cols_i * ArrM * OutDataWidth / 32.0;
    end
  end

endmodule
