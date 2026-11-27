//--------------------------
// MAC PE bank testbench
// - Unit test for mac_pe_bank (8 multipliers, 8 accumulators)
// - Inputs change on the falling edge. Every cycle all accumulators are
//   compared with a golden model, also the ones that are not selected.
//
// Tests:
//   1. Reset: all accumulators are 0
//   2. Blocks like in the accelerator: k-steps outer, 8 columns inner
//   3. Stall: valid low with init_save high, nothing may change
//   4. Only a_valid or only b_valid: no update
//   5. acc_clr clears all accumulators
//   6. valid has priority over acc_clr
//   7. Blocks back to back
//   8. Asynchronous reset while the accumulators are full
//   9. Random control signals
//  10. Extreme values -128 * -128 and -128 * 127 over K = 2048
//  11. Area = 3 * 8 + 8 = 32
//
// Run from the folder with the Makefile (see README.md):
//   make TEST_MODULE=tb_mac_pe_bank run             (Verilator)
//   make TEST_MODULE=tb_mac_pe_bank questasim-run   (Questasim)
//--------------------------

module tb_mac_pe_bank;

  //---------------------------
  // Design Time Parameters
  //---------------------------
  parameter int unsigned InDataWidth  = 8;
  parameter int unsigned NumInputs    = 8;   // K = 8 multipliers per PE
  parameter int unsigned OutDataWidth = 32;
  parameter int unsigned NumAcc       = 8;   // nb = 8 accumulators per PE

  localparam int unsigned SelWidth = $clog2(NumAcc);

  //---------------------------
  // Test Parameters
  //---------------------------
  parameter int unsigned NumBlocks       = 10;   // test 2
  parameter int unsigned MaxKSteps       = 16;   // test 2: k-steps per block
  parameter int unsigned StallCycles     = 5;    // test 3
  parameter int unsigned NumBackToBack   = 5;    // test 7
  parameter int unsigned NumRandomCycles = 500;  // test 9
  parameter int unsigned ExtremeKSteps   = 256;  // test 10: K = 2048 / 8
  parameter int unsigned MaxErrorsToShow = 5;    // per test
  parameter int unsigned TimeoutCycles   = 100_000;  // stop after this many cycles

  //---------------------------
  // Wires
  //---------------------------
  logic clk_i, rst_ni;

  logic signed [NumInputs-1:0][ InDataWidth-1:0] a_i;  // one row of A
  logic signed [NumInputs-1:0][ InDataWidth-1:0] b_i;  // one column of B
  logic        [ SelWidth-1:0]                   acc_sel_i;
  logic                                          a_valid_i;
  logic                                          b_valid_i;
  logic                                          init_save_i;
  logic                                          acc_clr_i;
  logic signed [   NumAcc-1:0][OutDataWidth-1:0] c_o;  // c_o[j]: accumulator j

  // Golden model, one value per accumulator
  int golden [NumAcc];

  // Fixed input values for test 10
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
  mac_pe_bank #(
    .InDataWidth  ( InDataWidth  ),
    .NumInputs    ( NumInputs    ),
    .OutDataWidth ( OutDataWidth ),
    .NumAcc       ( NumAcc       )
  ) i_dut (
    .clk_i        ( clk_i        ),
    .rst_ni       ( rst_ni       ),
    .a_i          ( a_i          ),
    .b_i          ( b_i          ),
    .acc_sel_i    ( acc_sel_i    ),
    .a_valid_i    ( a_valid_i    ),
    .b_valid_i    ( b_valid_i    ),
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

  // Dot product of the current inputs
  function automatic int dot();
    int sum = 0;
    for (int k = 0; k < NumInputs; k++) begin
      sum += $signed(a_i[k]) * $signed(b_i[k]);
    end
    return sum;
  endfunction

  task automatic golden_clear();
    foreach (golden[j]) golden[j] = 0;
  endtask

  // What the DUT should do at the next rising edge
  task automatic golden_update();
    if (a_valid_i && b_valid_i) begin
      if (init_save_i) golden[acc_sel_i] = dot();
      else             golden[acc_sel_i] += dot();
    end else if (acc_clr_i) begin
      golden_clear();
    end
  endtask

  //---------------------------
  // Stimulus and checking
  //---------------------------

  // New A and B values
  task automatic new_data();
    for (int k = 0; k < NumInputs; k++) begin
      a_i[k] = fill_mode ? InDataWidth'(fill_a) : InDataWidth'($urandom());
      b_i[k] = fill_mode ? InDataWidth'(fill_b) : InDataWidth'($urandom());
    end
  endtask

  // Compare all accumulators with the golden model
  task automatic check_all();
    test_cycles++;
    for (int j = 0; j < NumAcc; j++) begin
      if ($signed(c_o[j]) !== golden[j]) begin
        if (test_errors < MaxErrorsToShow) begin
          $display("  MISMATCH %s, cycle %0d: acc %0d = %0d, expected %0d",
                   test_name, test_cycles, j, $signed(c_o[j]), golden[j]);
        end
        test_errors++;
      end
    end
  endtask

  // One cycle: check the outputs, then drive new inputs
  task automatic cycle(input int unsigned sel, input bit a_valid, input bit b_valid,
                       input bit init, input bit clr);
    @(negedge clk_i);
    check_all();
    new_data();
    acc_sel_i   = SelWidth'(sel);
    a_valid_i   = a_valid;
    b_valid_i   = b_valid;
    init_save_i = init;
    acc_clr_i   = clr;
    golden_update();
  endtask

  // Compute on accumulator sel, first = first k-step
  task automatic k_step(input int unsigned sel, input bit first);
    cycle(sel, 1'b1, 1'b1, first, 1'b0);
  endtask

  // No valid input
  task automatic idle();
    cycle(0, 1'b0, 1'b0, 1'b0, 1'b0);
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
    a_valid_i   = 1'b0;
    b_valid_i   = 1'b0;
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
    repeat (StallCycles) cycle($urandom_range(NumAcc - 1), 1'b0, 1'b0, 1'b1, 1'b0);
    for (int n = 0; n < NumAcc; n++) k_step(n, 1'b0);  // second k-step adds on top
    end_test();

    // 4. Only one valid signal
    start_test("4. only a_valid or only b_valid");
    for (int n = 0; n < NumAcc; n++) begin
      cycle(n, 1'b1, 1'b0, 1'b0, 1'b0);
      cycle(n, 1'b0, 1'b1, 1'b1, 1'b0);
    end
    end_test();

    // 5. Clear
    start_test("5. acc_clr");
    cycle(0, 1'b0, 1'b0, 1'b0, 1'b1);
    repeat (2) idle();
    end_test();

    // 6. valid before acc_clr
    start_test("6. valid wins over acc_clr");
    block(2);
    cycle(3, 1'b1, 1'b1, 1'b0, 1'b1);  // acc 3 adds, nothing is cleared
    cycle(5, 1'b1, 1'b1, 1'b1, 1'b1);  // acc 5 loads, nothing is cleared
    end_test();

    // 7. Blocks back to back
    start_test($sformatf("7. %0d back-to-back blocks", NumBackToBack));
    repeat (NumBackToBack) block(4);
    end_test();

    // 8. Asynchronous reset
    start_test("8. asynchronous reset with full accumulators");
    block(2);
    @(negedge clk_i);
    check_all();               // the last k-step
    rst_ni    = 1'b0;          // reset, no clock edge yet
    a_valid_i = 1'b0;
    b_valid_i = 1'b0;
    golden_clear();
    #1;
    check_all();               // cleared without a clock edge
    @(negedge clk_i);
    rst_ni = 1'b1;
    end_test();

    // 9. Random controls (valid 75 %, init_save 25 %, clear 10 %)
    start_test($sformatf("9. %0d cycles with random controls", NumRandomCycles));
    for (int i = 0; i < NumRandomCycles; i++) begin
      cycle($urandom_range(NumAcc - 1),
            $urandom_range(3) != 0,
            $urandom_range(3) != 0,
            $urandom_range(3) == 0,
            $urandom_range(9) == 0);
    end
    end_test();

    // 10. Extreme values over K = 2048
    //     256 * 8 * (-128 * -128) = 33554432
    //     256 * 8 * (-128 * 127)  = -33292288
    fill_mode = 1'b1;
    fill_a    = -128;
    for (int pass = 0; pass < 2; pass++) begin
      int expected;
      fill_b   = (pass == 0) ? -128 : 127;
      expected = ExtremeKSteps * NumInputs * fill_a * fill_b;
      start_test($sformatf("10. extreme values, A = -128, B = %0d, K = %0d",
                           fill_b, ExtremeKSteps * NumInputs));
      block(ExtremeKSteps);
      // Also check the golden model against the hand calculation
      foreach (golden[j]) begin
        if (golden[j] != expected) begin
          $display("  MISMATCH golden acc %0d = %0d, hand calculation %0d", j, golden[j], expected);
          test_errors++;
        end
      end
      end_test();
    end
    fill_mode = 1'b0;

    // 11. Area
    expected_area = 3 * NumInputs + NumAcc * (OutDataWidth / 32);
    num_checks++;
    if (metrics_pkg::area == expected_area) begin
      $display("[PASS] 11. area = %0.0f (3 x %0d MACs + %0d accumulators)",
               metrics_pkg::area, NumInputs, NumAcc);
    end else begin
      $display("[FAIL] 11. area = %0.0f, expected %0.0f", metrics_pkg::area, expected_area);
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
      $fatal(1, "tb_mac_pe_bank failed");
    end
  end

  // Stop if the test hangs
  initial begin
    repeat (TimeoutCycles) @(posedge clk_i);
    $fatal(1, "Timeout after %0d cycles", TimeoutCycles);
  end

endmodule
