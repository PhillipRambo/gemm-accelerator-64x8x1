//---------------------------
// A tile buffer (double buffered)
//
// Description:
// This module holds the A tile (ArrM x ArrK int8 = 64 x 8 = 512 B) that the
// MAC array reads. It has two halves: the ACTIVE half drives the array, while
// the next tile is written into the SHADOW half, one SRAM A word per write.
// swap_i exchanges the two halves, so the new tile reaches the array all at
// once and the fetch of the next tile hides behind the compute of this one
// (5 reads per tile against nb = 8 cycles of use).
//
// One SRAM A word (port A = 104 B) holds RowsPerWord = 13 rows of 8 values:
// word w holds rows 13w ... 13w+12, so a tile takes 5 words. The last word
// only has 12 real rows (52 ... 63). Its last 8 B are padding and are dropped.
// Inside a word, wr_data_i[r][k] is row 13w + r, value k.
//
// A write and a swap in the same cycle are allowed: the word goes into the
// shadow half and that half becomes active at the same clock edge, so the
// controller can swap together with the last word of a tile.
//
// Parameters:
// - InDataWidth : Width of the input data (int8)
// - ArrM        : Number of rows in a tile (one per PE)
// - ArrK        : Number of values per row (inputs per PE)
// - RowsPerWord : Rows of the tile in one SRAM A word (104 B / 8 B = 13)
//
// Ports:
// - clk_i       : Clock input
// - rst_ni      : Active-low reset input
// - wr_en_i     : Write one SRAM A word into the shadow half
// - wr_word_i   : Which word of the tile (0 .. NumWords-1)
// - wr_data_i   : The SRAM A word, wr_data_i[r][k] (RowsPerWord x ArrK values)
// - swap_i      : Exchange the halves: the shadow half becomes active
// - a_o         : The active tile, a_o[m][k] (ArrM x ArrK values), to the array
//---------------------------

module a_tile_buffer #(
  parameter int unsigned InDataWidth = 8,
  parameter int unsigned ArrM = 64,
  parameter int unsigned ArrK = 8,
  parameter int unsigned RowsPerWord = 13,
  // Words per tile: ceil(64 / 13) = 5
  parameter int unsigned NumWords = (ArrM + RowsPerWord - 1) / RowsPerWord
) (
  input  logic clk_i,
  input  logic rst_ni,
  // Write side (from SRAM A)
  input  logic wr_en_i,
  input  logic [$clog2(NumWords)-1:0]  wr_word_i,
  input  logic signed [ RowsPerWord-1:0][ArrK-1:0][InDataWidth-1:0] wr_data_i,
  input  logic  swap_i,
  // Read side (to the MAC array)
  output logic signed [ArrM-1:0][ArrK-1:0][InDataWidth-1:0] a_o
);

  // The two halves and which one is active
  logic signed [ArrM-1:0][ArrK-1:0][InDataWidth-1:0] half_q [2];
  logic  active_q;

  // Write into the shadow half (!active_q), and swap.
  // Row m of the tile is slot m % RowsPerWord of word m / RowsPerWord, so
  // every row has its own write enable (wr_word_i == m / RowsPerWord). The
  // padding slot of the last word belongs to no row and is never stored.

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

  // The array always reads the active half (a 2:1 mux)
  assign a_o = half_q[active_q];

  //--------------------------------
  // Area logging (Table 3: 1 per 32-bit register)
  //--------------------------------
  initial begin
    #0;
    metrics_pkg::area += 2 * ArrM * ArrK * InDataWidth / 32;
    $display("%m added %0d to area", 2 * ArrM * ArrK * InDataWidth / 32);
  end

  //--------------------------------
  // Energy logging (Table 3: 1 per 32-bit register update)
  // Every write updates the rows of one word (13, or 12 for the last word),
  // 8 B per row = 2 units per row, so one tile of 512 B costs 128.
  // Reading the active half is free.
  //--------------------------------
  always @(posedge clk_i) begin
    if (rst_ni && wr_en_i) begin
      metrics_pkg::energy += rows_in_word(wr_word_i) * ArrK * InDataWidth / 32.0;
    end
  end

  // Real rows in word w (the last word of the tile has fewer)
  function automatic int unsigned rows_in_word(input int unsigned w);
    return (ArrM - w * RowsPerWord < RowsPerWord) ? ArrM - w * RowsPerWord : RowsPerWord;
  endfunction

endmodule
