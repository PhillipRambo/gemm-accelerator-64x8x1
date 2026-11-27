//--------------------------
// Output buffer testbench
// - Unit test for output_buffer (64 x 8 int32, written out in words of 4 int32)
// - When a block is loaded, the words it should give are put in a queue.
//   Every cycle with wr_en_o the next word is taken from the queue and
//   compared (data, column and row group).
// - c_i changes every cycle like the array does, so the test also checks
//   that the buffer writes out its own copy. A load is only requested when
//   ready_o is high, like the controller does.
//
// Tests:
//   1. Reset: nothing to write, ready
//   2. Full block: 8 columns = 128 words in the right order
//   3. Partial blocks of 1 and 3 columns
//   4. Blocks back to back, the next load comes on the last word
//   5. Random column counts and gaps
//   6. Extreme values -2^31 and 2^31 - 1
//   7. Energy of a load = 64 per column
//   8. Area = 64 * 8 = 512
//
// Run from the folder with the Makefile (see README.md):
//   make TEST_MODULE=tb_output_buffer run
//--------------------------

module tb_output_buffer;

  //---------------------------
  // Design Time Parameters
  //---------------------------
  parameter int unsigned OutDataWidth = 32;
  parameter int unsigned ArrM         = 64;
  parameter int unsigned NumAcc       = 8;
  parameter int unsigned WordOutputs  = 4;

  localparam int unsigned NumGroups    = ArrM / WordOutputs;  // 16 words per column
  localparam int unsigned ColWidth     = $clog2(NumAcc);
  localparam int unsigned GrpWidth     = $clog2(NumGroups);
  localparam int unsigned NumColsWidth = $clog2(NumAcc + 1);

  //---------------------------
  // Test Parameters
  //---------------------------
  parameter int unsigned NumBackToBack   = 4;   // test 4
  parameter int unsigned NumRandomBlocks = 30;  // test 5
  parameter int unsigned MaxGap          = 3;   // test 5: idle cycles between blocks
  parameter int unsigned MaxErrorsToShow = 5;   // per test
  parameter int unsigned TimeoutCycles   = 100_000;  // stop after this many cycles

  //---------------------------
  // Wires
  //---------------------------
  logic clk_i, rst_ni;

  logic                                                 load_i;
  logic        [NumColsWidth-1:0]                       num_cols_i;
  logic signed [ArrM-1:0][NumAcc-1:0][OutDataWidth-1:0] c_i;     // c_i[m][j]
  logic                                                 ready_o;
  logic                                                 wr_en_o;
  logic        [ColWidth-1:0]                           col_o;
  logic        [GrpWidth-1:0]                           grp_o;
  logic signed [WordOutputs-1:0][OutDataWidth-1:0]      data_o;  // data_o[i]

  // Queue of the words that should come out
  typedef struct packed {
    logic [ColWidth-1:0]                      col;
    logic [GrpWidth-1:0]                      grp;
    logic [WordOutputs-1:0][OutDataWidth-1:0] data;
  } word_t;

  word_t expected_q [$];

  // Extreme values for test 6
  bit extreme_mode = 1'b0;

  // Counters per test and in total
  string       test_name;
  int unsigned test_errors;
  int unsigned test_cycles;
  int unsigned num_checks = 0;
  int unsigned num_errors = 0;

  //---------------------------
  // DUT
  //---------------------------
  output_buffer #(
    .OutDataWidth ( OutDataWidth ),
    .ArrM         ( ArrM         ),
    .NumAcc       ( NumAcc       ),
    .WordOutputs  ( WordOutputs  )
  ) i_dut (
    .clk_i        ( clk_i        ),
    .rst_ni       ( rst_ni       ),
    .load_i       ( load_i       ),
    .num_cols_i   ( num_cols_i   ),
    .c_i          ( c_i          ),
    .ready_o      ( ready_o      ),
    .wr_en_o      ( wr_en_o      ),
    .col_o        ( col_o        ),
    .grp_o        ( grp_o        ),
    .data_o       ( data_o       )
  );

  //---------------------------
  // Clock
  //---------------------------
  initial begin
    clk_i = 1'b0;
    forever #5 clk_i = ~clk_i;  // 100 MHz
  end

  //---------------------------
  // Stimulus and checking
  //---------------------------

  // New values on the array outputs
  task automatic new_data();
    for (int m = 0; m < ArrM; m++) begin
      for (int j = 0; j < NumAcc; j++) begin
        if (extreme_mode) c_i[m][j] = ((m + j) % 2 == 0) ? 32'h8000_0000 : 32'h7FFF_FFFF;
        else              c_i[m][j] = OutDataWidth'($urandom());
      end
    end
  endtask

  // Put the words of the loaded block in the queue,
  // column by column, rows 4g to 4g+3 in word g
  task automatic push_block(input int unsigned cols);
    for (int j = 0; j < cols; j++) begin
      for (int g = 0; g < NumGroups; g++) begin
        word_t w;
        w.col = ColWidth'(j);
        w.grp = GrpWidth'(g);
        for (int i = 0; i < WordOutputs; i++) w.data[i] = c_i[g * WordOutputs + i][j];
        expected_q.push_back(w);
      end
    end
  endtask

  task automatic error(input string msg);
    if (test_errors < MaxErrorsToShow) begin
      $display("  MISMATCH %s, cycle %0d: %s", test_name, test_cycles, msg);
    end
    test_errors++;
  endtask

  // Check the outputs of this cycle against the queue
  task automatic check_outputs();
    word_t exp;
    test_cycles++;
    if (wr_en_o !== (expected_q.size() > 0)) begin
      error($sformatf("wr_en_o = %b with %0d words left", wr_en_o, expected_q.size()));
    end
    if (wr_en_o === 1'b1 && expected_q.size() > 0) begin
      exp = expected_q.pop_front();
      if (col_o !== exp.col || grp_o !== exp.grp) begin
        error($sformatf("word (col %0d, grp %0d), expected (col %0d, grp %0d)",
                        col_o, grp_o, exp.col, exp.grp));
      end
      if (data_o !== exp.data) begin
        error($sformatf("data of (col %0d, grp %0d) = %h, expected %h",
                        exp.col, exp.grp, data_o, exp.data));
      end
    end
    if (ready_o !== (expected_q.size() == 0)) begin
      error($sformatf("ready_o = %b with %0d words left after this one",
                      ready_o, expected_q.size()));
    end
  endtask

  // One cycle: check the outputs, then drive new inputs.
  // A load only happens when ready_o is high, loaded says if it did.
  task automatic cycle(input bit want_load, input int unsigned cols, output bit loaded);
    @(negedge clk_i);
    check_outputs();
    new_data();
    loaded     = want_load && ready_o;
    load_i     = loaded;
    num_cols_i = NumColsWidth'(cols);
    if (loaded) push_block(cols);
  endtask

  task automatic idle();
    bit loaded;
    cycle(1'b0, 1, loaded);
  endtask

  // Load a block as soon as the buffer is ready
  task automatic send_block(input int unsigned cols);
    bit loaded;
    do cycle(1'b1, cols, loaded); while (!loaded);
  endtask

  task automatic wait_drained();
    while (expected_q.size() > 0) idle();
  endtask

  task automatic start_test(input string name);
    test_name   = name;
    test_errors = 0;
    test_cycles = 0;
  endtask

  // Write out everything, check one more cycle and print the result
  task automatic end_test();
    wait_drained();
    idle();
    num_checks++;
    num_errors += test_errors;
    if (test_errors == 0) $display("[PASS] %s (%0d cycles checked)", test_name, test_cycles);
    else                  $display("[FAIL] %s: %0d errors", test_name, test_errors);
  endtask

  //---------------------------
  // Test sequence
  //---------------------------
  initial begin
    real energy_before, expected_area;

    // Reset
    rst_ni     = 1'b0;
    load_i     = 1'b0;
    num_cols_i = '0;
    for (int m = 0; m < ArrM; m++) c_i[m] = '0;
    repeat (3) @(negedge clk_i);
    rst_ni = 1'b1;

    // 1. Reset
    start_test("1. reset: nothing to write, ready");
    repeat (3) idle();
    end_test();

    // 2. One full block while c_i keeps changing
    start_test("2. full block (8 columns, 128 words)");
    send_block(NumAcc);
    end_test();

    // 3. Partial blocks
    start_test("3. partial blocks (1 and 3 columns)");
    send_block(1);
    wait_drained();
    send_block(3);
    end_test();

    // 4. Back to back, each load comes on the last word
    start_test($sformatf("4. %0d full blocks back to back", NumBackToBack));
    repeat (NumBackToBack) send_block(NumAcc);
    end_test();

    // 5. Random column counts and gaps
    start_test($sformatf("5. %0d random blocks", NumRandomBlocks));
    for (int b = 0; b < NumRandomBlocks; b++) begin
      repeat ($urandom_range(MaxGap)) idle();
      send_block($urandom_range(NumAcc, 1));
    end
    end_test();

    // 6. Extreme values
    start_test("6. extreme values -2^31 and 2^31 - 1");
    extreme_mode = 1'b1;
    send_block(NumAcc);
    end_test();
    extreme_mode = 1'b0;

    // 7. Energy of a load, for 1 and for 8 columns
    start_test("7. energy of a load = 64 per column");
    for (int pass = 0; pass < 2; pass++) begin
      int unsigned cols = (pass == 0) ? 1 : NumAcc;
      energy_before = metrics_pkg::energy;
      send_block(cols);
      idle();
      if (metrics_pkg::energy - energy_before != cols * ArrM * OutDataWidth / 32) begin
        $display("  MISMATCH energy of a %0d-column load = %0.2f, expected %0d", cols,
                 metrics_pkg::energy - energy_before, cols * ArrM * OutDataWidth / 32);
        test_errors++;
      end
      wait_drained();
    end
    end_test();

    // 8. Area
    expected_area = ArrM * NumAcc * OutDataWidth / 32;
    num_checks++;
    if (metrics_pkg::area == expected_area) begin
      $display("[PASS] 8. area = %0.0f (%0d x %0d int32)", metrics_pkg::area, ArrM, NumAcc);
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
      $fatal(1, "tb_output_buffer failed");
    end
  end

  // Stop if the test hangs
  initial begin
    repeat (TimeoutCycles) @(posedge clk_i);
    $fatal(1, "Timeout after %0d cycles", TimeoutCycles);
  end

endmodule
