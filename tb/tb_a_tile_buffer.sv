//--------------------------
// A tile buffer testbench
// - Unit test for a_tile_buffer (two halves of 64 x 8 int8, written in 5 words of 104 B)
//
// The golden model keeps both halves and which one is active. A write puts
// rows 13w ... 13w+12 of word w into the shadow half (rows past 63 are the
// padding of the last word and are dropped). A swap exchanges the halves.
// The write data is random everywhere, the padding bytes included.
//
// Timing: inputs change on the falling edge and the DUT updates on the rising
// edge. Every cycle, cycle() first checks the whole active tile against the
// golden model (the result of the previous cycle) and then drives the next
// inputs, so the tests also show that writing the shadow half never changes
// what the array sees.
//
// Tests:
//   1. Reset          : the active tile is 0
//   2. Fill the shadow: 5 writes without a swap: the active tile does not change
//   3. Swap           : the written tile appears all at once
//   4. Like the loop  : tile t+1 is written while tile t is active, with stall
//                       cycles between the writes, and the swap comes together
//                       with the last word
//   5. Any order      : the words in reverse order and one word rewritten
//                       (the last write wins)
//   6. Swap only      : two swaps without writes go back to the same tile
//   7. Energy         : writing one tile costs 128 (512 B, an 8-bit register = 1/4)
//   8. Area           : metrics_pkg::area = 2 halves * 512 B / 4 = 256
//
// Run from the folder with the Makefile (see README.md):
//   make TEST_MODULE=tb_a_tile_buffer run
//--------------------------

module tb_a_tile_buffer;

  //---------------------------
  // Design Time Parameters
  //---------------------------
  parameter int unsigned InDataWidth = 8;
  parameter int unsigned ArrM        = 64;
  parameter int unsigned ArrK        = 8;
  parameter int unsigned RowsPerWord = 13;

  localparam int unsigned NumWords  = (ArrM + RowsPerWord - 1) / RowsPerWord;  // 5
  localparam int unsigned WordWidth = $clog2(NumWords);

  //---------------------------
  // Test Parameters
  //---------------------------
  parameter int unsigned NumTiles        = 20;  // test 4
  parameter int unsigned MaxStall        = 2;   // test 4: stall cycles between writes
  parameter int unsigned MaxErrorsToShow = 5;   // per test
  parameter int unsigned TimeoutCycles   = 100_000;  // safety net (cycles)

  //---------------------------
  // Wires
  //---------------------------
  logic clk_i, rst_ni;

  logic                                                     wr_en_i;
  logic        [  WordWidth-1:0]                            wr_word_i;
  logic signed [RowsPerWord-1:0][ArrK-1:0][InDataWidth-1:0] wr_data_i;  // wr_data_i[r][k]
  logic                                                     swap_i;
  logic signed [       ArrM-1:0][ArrK-1:0][InDataWidth-1:0] a_o;        // a_o[m][k]

  // Golden model: both halves and the active one
  int golden [2][ArrM][ArrK];
  int golden_active;

  // Bookkeeping per test and in total
  string       test_name;
  int unsigned test_errors;
  int unsigned test_cycles;
  int unsigned num_checks = 0;
  int unsigned num_errors = 0;

  //---------------------------
  // DUT
  //---------------------------
  a_tile_buffer #(
    .InDataWidth ( InDataWidth ),
    .ArrM        ( ArrM        ),
    .ArrK        ( ArrK        ),
    .RowsPerWord ( RowsPerWord )
  ) i_dut (
    .clk_i       ( clk_i       ),
    .rst_ni      ( rst_ni      ),
    .wr_en_i     ( wr_en_i     ),
    .wr_word_i   ( wr_word_i   ),
    .wr_data_i   ( wr_data_i   ),
    .swap_i      ( swap_i      ),
    .a_o         ( a_o         )
  );

  //---------------------------
  // Clock
  //---------------------------
  initial begin
    clk_i = 1'b0;
    forever #5 clk_i = ~clk_i;  // 100 MHz
  end

  //---------------------------
  // Golden model
  //---------------------------
  task automatic golden_clear();
    foreach (golden[h, m, k]) golden[h][m][k] = 0;
    golden_active = 0;
  endtask

  // Predict what the DUT does with the inputs driven now at the next rising edge
  task automatic golden_update();
    if (wr_en_i) begin
      for (int r = 0; r < RowsPerWord; r++) begin
        int row = wr_word_i * RowsPerWord + r;
        if (row < ArrM) begin
          for (int k = 0; k < ArrK; k++) begin
            golden[1 - golden_active][row][k] = $signed(wr_data_i[r][k]);
          end
        end
      end
    end
    if (swap_i) golden_active = 1 - golden_active;
  endtask

  //---------------------------
  // Stimulus and checking
  //---------------------------

  // Compare the whole active tile with the golden model right now
  task automatic check_all();
    test_cycles++;
    for (int m = 0; m < ArrM; m++) begin
      for (int k = 0; k < ArrK; k++) begin
        if ($signed(a_o[m][k]) !== golden[golden_active][m][k]) begin
          if (test_errors < MaxErrorsToShow) begin
            $display("  MISMATCH %s, cycle %0d: A[%0d][%0d] = %0d, expected %0d",
                     test_name, test_cycles, m, k, $signed(a_o[m][k]),
                     golden[golden_active][m][k]);
          end
          test_errors++;
        end
      end
    end
  endtask

  // One clock cycle: on the falling edge, check the result of the previous
  // cycle, then drive new inputs and update the golden model
  task automatic cycle(input bit wr_en, input int unsigned word, input bit swap);
    @(negedge clk_i);
    check_all();
    for (int r = 0; r < RowsPerWord; r++) begin
      for (int k = 0; k < ArrK; k++) begin
        wr_data_i[r][k] = InDataWidth'($urandom());
      end
    end
    wr_en_i   = wr_en;
    wr_word_i = WordWidth'(word);
    swap_i    = swap;
    golden_update();
  endtask

  task automatic write(input int unsigned word, input bit swap);
    cycle(1'b1, word, swap);
  endtask

  task automatic idle();
    cycle(1'b0, 0, 1'b0);
  endtask

  task automatic start_test(input string name);
    test_name   = name;
    test_errors = 0;
    test_cycles = 0;
  endtask

  // One idle cycle checks the last driven cycle, then report the test
  task automatic end_test();
    idle();
    num_checks++;
    num_errors += test_errors;
    if (test_errors == 0) $display("[PASS] %s (%0d cycles checked)", test_name, test_cycles);
    else                  $display("[FAIL] %s: %0d wrong values", test_name, test_errors);
  endtask

  //---------------------------
  // Test sequence
  //---------------------------
  initial begin
    real energy_before, expected_area;

    // Reset
    rst_ni    = 1'b0;
    wr_en_i   = 1'b0;
    wr_word_i = '0;
    wr_data_i = '0;
    swap_i    = 1'b0;
    golden_clear();
    repeat (3) @(negedge clk_i);
    rst_ni = 1'b1;

    // 1. Reset
    start_test("1. reset: active tile 0");
    repeat (3) idle();
    end_test();

    // 2. Fill the shadow half, no swap: the array must not see it
    start_test("2. writes to the shadow half do not change the active tile");
    for (int w = 0; w < NumWords; w++) write(w, 1'b0);
    repeat (3) idle();
    end_test();

    // 3. Swap: the tile written in test 2 becomes active
    start_test("3. swap");
    cycle(1'b0, 0, 1'b1);
    end_test();

    // 4. Like the controller: write tile t+1 while tile t is active,
    //    with stalls, and swap together with the last word
    start_test($sformatf("4. %0d tiles back to back, swap with the last word", NumTiles));
    for (int t = 0; t < NumTiles; t++) begin
      for (int w = 0; w < NumWords; w++) begin
        repeat ($urandom_range(MaxStall)) idle();
        write(w, w == NumWords - 1);
      end
    end
    end_test();

    // 5. Words in reverse order, then word 2 again: the last write wins
    start_test("5. words in any order, a rewritten word");
    for (int w = NumWords - 1; w >= 0; w--) write(w, 1'b0);
    write(2, 1'b0);
    cycle(1'b0, 0, 1'b1);
    end_test();

    // 6. Two swaps without writes: back to the same tile
    start_test("6. swap without writes");
    cycle(1'b0, 0, 1'b1);
    cycle(1'b0, 0, 1'b1);
    end_test();

    // 7. Energy of one tile: 13 + 13 + 13 + 13 + 12 rows of 8 B = 512 B -> 128
    start_test("7. energy of one tile = 128");
    energy_before = metrics_pkg::energy;
    for (int w = 0; w < NumWords; w++) write(w, w == NumWords - 1);
    idle();
    if (metrics_pkg::energy - energy_before != ArrM * ArrK * InDataWidth / 32) begin
      $display("  MISMATCH energy of one tile = %0.2f, expected %0d",
               metrics_pkg::energy - energy_before, ArrM * ArrK * InDataWidth / 32);
      test_errors++;
    end
    end_test();

    // 8. Area: two halves of ArrM x ArrK int8
    expected_area = 2 * ArrM * ArrK * InDataWidth / 32;
    num_checks++;
    if (metrics_pkg::area == expected_area) begin
      $display("[PASS] 8. area = %0.0f (2 halves x %0d B / 4)", metrics_pkg::area,
               ArrM * ArrK * InDataWidth / 8);
    end else begin
      $display("[FAIL] 8. area = %0.0f, expected %0.0f", metrics_pkg::area, expected_area);
      num_errors++;
    end

    // Summary
    repeat (2) @(negedge clk_i);
    $display("");
    $display("==============================================");
    if (num_errors == 0) begin
      $display(" All %0d checks passed", num_checks);
      $display("==============================================");
      $finish;
    end else begin
      $display(" %0d errors in %0d checks", num_errors, num_checks);
      $display("==============================================");
      $fatal(1, "tb_a_tile_buffer failed");
    end
  end

  // Safety net: stop if the test hangs. Counted in clock cycles, so it does
  // not depend on the time unit of the simulator.
  initial begin
    repeat (TimeoutCycles) @(posedge clk_i);
    $fatal(1, "Timeout after %0d cycles", TimeoutCycles);
  end

endmodule
