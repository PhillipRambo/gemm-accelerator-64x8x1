//---------------------------
// A tile buffer
//
// Description:
// Holds the A tile (64 x 8 int8) that the MAC array uses. It is double
// buffered: the array reads the active half while the next tile is written
// into the other half, one SRAM A word at a time. swap_i switches the halves.
//
// An SRAM A word is 104 B = 13 rows of the tile, so one tile is 5 words.
// The last word only has 12 rows, its last 8 B are padding and not stored.
// A write and a swap are allowed in the same cycle.
//
// Parameters:
// - InDataWidth : Width of the input data
// - ArrM        : Rows in the tile (one per PE)
// - ArrK        : Values per row
// - RowsPerWord : Tile rows in one SRAM A word
//
// Ports:
// - clk_i       : Clock input
// - rst_ni      : Active-low reset input
// - wr_en_i     : Write a word into the shadow half
// - wr_word_i   : Word number in the tile (0 to 4)
// - wr_data_i   : SRAM A word, wr_data_i[r][k]
// - swap_i      : Swap the two halves
// - a_o         : Active tile to the MAC array, a_o[m][k]
//---------------------------

module a_tile_buffer #(
  parameter int unsigned InDataWidth = 8,
  parameter int unsigned ArrM = 64,
  parameter int unsigned ArrK = 8,
  parameter int unsigned RowsPerWord = 13,
  // 5 words per tile
  parameter int unsigned NumWords = (ArrM + RowsPerWord - 1) / RowsPerWord
) (
  input  logic clk_i,
  input  logic rst_ni,
  // From SRAM A
  input  logic wr_en_i,
  input  logic [$clog2(NumWords)-1:0]  wr_word_i,
  input  logic signed [ RowsPerWord-1:0][ArrK-1:0][InDataWidth-1:0] wr_data_i,
  input  logic  swap_i,
  // To the MAC array
  output logic signed [ArrM-1:0][ArrK-1:0][InDataWidth-1:0] a_o
);

  // Two halves, active_q is the one the array reads
  logic signed [ArrM-1:0][ArrK-1:0][InDataWidth-1:0] half_q [2];
  logic  active_q;

  // Writes go into the half that is not active.
  // Row m of the tile is in word m / 13, slot m % 13.

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      half_q[0] <= '0;  // setting half 1 of tile buffer to 0
      half_q[1] <= '0;  // setting half 2 of tile buffer to 0
      active_q  <= 1'b0;
    end else begin
      if (wr_en_i) begin
        for (int m = 0; m < ArrM; m++) begin
          if (m / RowsPerWord == wr_word_i) begin
            half_q[!active_q][m] <= wr_data_i[m % RowsPerWord];
          end
        end
      end
      if (swap_i) begin
        active_q <= !active_q;
      end
    end
  end

  // The array reads the active half
  assign a_o = half_q[active_q];

  //--------------------------------
  // Area logging
  // 1 per 32-bit register: 2 halves * 512 B / 4 B = 256
  //--------------------------------
  initial begin
    #0;
    metrics_pkg::area += 2 * ArrM * ArrK * InDataWidth / 32;
    $display("%m added %0d to area", 2 * ArrM * ArrK * InDataWidth / 32);
  end

  //--------------------------------
  // Energy logging
  // 1 per 32-bit register that is written. A row is 8 B = 2,
  // so a full tile costs 128. Reading is free.
  //--------------------------------
  always @(posedge clk_i) begin
    if (rst_ni && wr_en_i) begin
      metrics_pkg::energy += rows_in_word(wr_word_i) * ArrK * InDataWidth / 32.0;
    end
  end

  // Number of rows in word w (the last word has 12)
  function automatic int unsigned rows_in_word(input int unsigned w);
    return (ArrM - w * RowsPerWord < RowsPerWord) ? ArrM - w * RowsPerWord : RowsPerWord;
  endfunction

endmodule
