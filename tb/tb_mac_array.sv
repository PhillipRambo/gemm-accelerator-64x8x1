//--------------------------
// MAC array testbench
// - Unit test for mac_array (64 PEs x 8 multipliers, 8 accumulators per PE)
// - The PE itself is tested in tb_mac_pe_bank. This test checks the wiring:
//   PE m gets row m of A, all PEs get the same B column and acc_sel, and
//   c_o[m][j] is row m, column j.
// - Inputs change on the falling edge. Every cycle all 64 x 8 accumulators
//   are compared with a golden model.
//
// Tests:
//   1. Reset: all accumulators are 0
//   2. Blocks like in the accelerator: k-steps outer, 8 columns inner
//   3. Stall: valid low with init_save high, nothing may change
//   4. acc_clr clears all accumulators
//   5. valid has priority over acc_clr
//   6. Blocks back to back
//   7. Extreme values -128 * -128 and -128 * 127 over K = 2048
//   8. Area = 64 PEs * 32 = 2048
//
// Run from the folder with the Makefile (see README.md):
//   make TEST_MODULE=tb_mac_array run             (Verilator)
//   make TEST_MODULE=tb_mac_array questasim-run   (Questasim)
//--------------------------

module tb_mac_array;

  //---------------------------
  // Design Time Parameters
  //---------------------------
  parameter int unsigned InDataWidth  = 8;
  parameter int unsigned OutDataWidth = 32;
  parameter int unsigned ArrM         = 64;
  parameter int unsigned ArrK         = 8;
  parameter int unsigned NumAcc       = 8;

  localparam int unsigned SelWidth = $clog2(NumAcc);

  //---------------------------
  // Test Parameters
  //---------------------------
  parameter int unsigned NumBlocks       = 5;    // test 2
  parameter int unsigned MaxKSteps       = 16;   // test 2: k-steps per block
  parameter int unsigned StallCycles     = 5;    // test 3
  parameter int unsigned NumBackToBack   = 5;    // test 6
  parameter int unsigned ExtremeKSteps   = 256;  // test 7: K = 2048 / 8
  parameter int unsigned MaxErrorsToShow = 5;    // per test
  parameter int unsigned TimeoutCycles   = 100_000;  // stop after this many cycles

  //---------------------------
  // Wires
  //---------------------------
  logic clk_i, rst_ni;

  logic signed [ArrM-1:0][  ArrK-1:0][ InDataWidth-1:0] a_i;  // a_i[m][k]
  logic signed [ArrK-1:0][ InDataWidth-1:0]             b_i;  // b_i[k]
  logic        [SelWidth-1:0]                           acc_sel_i;
  logic                                                 valid_i;
  logic                                                 init_save_i;
  logic                                                 acc_clr_i;
  logic signed [ArrM-1:0][NumAcc-1:0][OutDataWidth-1:0] c_o;  // c_o[m][j]

  // Golden model, one value per accumulator
  int golden [ArrM][NumAcc];

  // Fixed input values for test 7
  bit fill_mode = 1'b0;
  int fill_a, fill_b;

  // Counters per test and in total
  string       test_name;
  int unsigned test_errors;
  int unsigned test_cycles;
  int unsigned num_checks = 0;
  int unsigned num_errors = 0;

  //---------------------------
  // DUT
  //---------------------------
  mac_array #(
    .InDataWidth  ( InDataWidth  ),
    .OutDataWidth ( OutDataWidth ),
    .ArrM         ( ArrM         ),
    .ArrK         ( ArrK         ),
    .NumAcc       ( NumAcc       )
  ) i_dut (
    .clk_i        ( clk_i        ),
    .rst_ni       ( rst_ni       ),
    .a_i          ( a_i          ),
    .b_i          ( b_i          ),
    .acc_sel_i    ( acc_sel_i    ),
    .valid_i      ( valid_i      ),
    .init_save_i  ( init_save_i  ),
    .acc_clr_i    ( acc_clr_i    ),
    .c_o          ( c_o          )
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

  // Dot product of row m of A with the B column
  function automatic int dot(input int m);
    int sum = 0;
    for (int k = 0; k < ArrK; k++) begin
      sum += $signed(a_i[m][k]) * $signed(b_i[k]);
    end
    return sum;
  endfunction

  task automatic golden_clear();
    foreach (golden[m, j]) golden[m][j] = 0;
  endtask

  // What the DUT should do at the next rising edge
  task automatic golden_update();
    if (valid_i) begin
      for (int m = 0; m < ArrM; m++) begin
        if (init_save_i) golden[m][acc_sel_i] = dot(m);
        else             golden[m][acc_sel_i] += dot(m);
      end
    end else if (acc_clr_i) begin
      golden_clear();
    end
  endtask

  //---------------------------
  // Stimulus and checking
  //---------------------------

  // New A tile and B column
  task automatic new_data();
    for (int m = 0; m < ArrM; m++) begin
      for (int k = 0; k < ArrK; k++) begin
        a_i[m][k] = fill_mode ? InDataWidth'(fill_a) : InDataWidth'($urandom());
      end
    end
    for (int k = 0; k < ArrK; k++) begin
      b_i[k] = fill_mode ? InDataWidth'(fill_b) : InDataWidth'($urandom());
    end
  endtask

  // Compare all accumulators with the golden model
  task automatic check_all();
    test_cycles++;
    for (int m = 0; m < ArrM; m++) begin
      for (int j = 0; j < NumAcc; j++) begin
        if ($signed(c_o[m][j]) !== golden[m][j]) begin
          if (test_errors < MaxErrorsToShow) begin
            $display("  MISMATCH %s, cycle %0d: C[%0d][%0d] = %0d, expected %0d",
                     test_name, test_cycles, m, j, $signed(c_o[m][j]), golden[m][j]);
          end
          test_errors++;
        end
      end
    end
  endtask

  // One cycle: check the outputs, then drive new inputs
  task automatic cycle(input int unsigned sel, input bit valid, input bit init, input bit clr);
    @(negedge clk_i);
    check_all();
    new_data();
    acc_sel_i   = SelWidth'(sel);
    valid_i     = valid;
    init_save_i = init;
    acc_clr_i   = clr;
    golden_update();
  endtask

  // Compute on accumulator sel, first = first k-step
  task automatic k_step(input int unsigned sel, input bit first);
    cycle(sel, 1'b1, first, 1'b0);
  endtask

  // No valid input
  task automatic idle();
    cycle(0, 1'b0, 1'b0, 1'b0);
  endtask

  // One block: k-steps outer, columns inner
  task automatic block(input int unsigned k_steps);
    for (int k = 0; k < k_steps; k++) begin
      for (int n = 0; n < NumAcc; n++) begin
        k_step(n, k == 0);
      end
    end
  endtask

  task automatic start_test(input string name);
    test_name   = name;
    test_errors = 0;
    test_cycles = 0;
  endtask

  // Check the last cycle and print the result
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
    real expected_area;

    // Reset
    rst_ni      = 1'b0;
    a_i         = '0;
    b_i         = '0;
    acc_sel_i   = '0;
    valid_i     = 1'b0;
    init_save_i = 1'b0;
    acc_clr_i   = 1'b0;
    golden_clear();
    repeat (3) @(negedge clk_i);
    rst_ni = 1'b1;

    // 1. Reset
    start_test("1. reset: all accumulators 0");
    repeat (3) idle();
    end_test();

    // 2. Blocks with 1 to MaxKSteps k-steps
    start_test($sformatf("2. %0d interleaved blocks (1..%0d k-steps)", NumBlocks, MaxKSteps));
    for (int b = 0; b < NumBlocks; b++) begin
      block($urandom_range(MaxKSteps, 1));
      idle();
    end
    end_test();

    // 3. Stall between two k-steps
    start_test("3. stall with init_save high");
    block(1);
    repeat (StallCycles) cycle($urandom_range(NumAcc - 1), 1'b0, 1'b1, 1'b0);
    for (int n = 0; n < NumAcc; n++) k_step(n, 1'b0);  // second k-step adds on top
    end_test();

    // 4. Clear
    start_test("4. acc_clr");
    cycle(0, 1'b0, 1'b0, 1'b1);
    repeat (2) idle();
    end_test();

    // 5. valid before acc_clr
    start_test("5. valid wins over acc_clr");
    block(2);
    cycle(3, 1'b1, 1'b0, 1'b1);  // accumulator 3 of every row adds, nothing is cleared
    cycle(5, 1'b1, 1'b1, 1'b1);  // accumulator 5 of every row loads, nothing is cleared
    end_test();

    // 6. Blocks back to back
    start_test($sformatf("6. %0d back-to-back blocks", NumBackToBack));
    repeat (NumBackToBack) block(4);
    end_test();

    // 7. Extreme values over K = 2048
    //    256 * 8 * (-128 * -128) = 33554432
    //    256 * 8 * (-128 * 127)  = -33292288
    fill_mode = 1'b1;
    fill_a    = -128;
    for (int pass = 0; pass < 2; pass++) begin
      int expected;
      fill_b   = (pass == 0) ? -128 : 127;
      expected = ExtremeKSteps * ArrK * fill_a * fill_b;
      start_test($sformatf("7. extreme values, A = -128, B = %0d, K = %0d",
                           fill_b, ExtremeKSteps * ArrK));
      block(ExtremeKSteps);
      // Also check the golden model against the hand calculation
      foreach (golden[m, j]) begin
        if (golden[m][j] != expected) begin
          if (test_errors < MaxErrorsToShow) begin
            $display("  MISMATCH golden C[%0d][%0d] = %0d, hand calculation %0d",
                     m, j, golden[m][j], expected);
          end
          test_errors++;
        end
      end
      end_test();
    end
    fill_mode = 1'b0;

    // 8. Area
    expected_area = ArrM * (3 * ArrK + NumAcc * (OutDataWidth / 32));
    num_checks++;
    if (metrics_pkg::area == expected_area) begin
      $display("[PASS] 8. area = %0.0f (%0d PEs x %0d)", metrics_pkg::area,
               ArrM, 3 * ArrK + NumAcc * (OutDataWidth / 32));
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
      $fatal(1, "tb_mac_array failed");
    end
  end

  // Stop if the test hangs
  initial begin
    repeat (TimeoutCycles) @(posedge clk_i);
    $fatal(1, "Timeout after %0d cycles", TimeoutCycles);
  end

endmodule
