//--------------------------
// B buffer testbench
// - Unit test for b_buffer (one B column of 8 int8)
//
// Timing: inputs change on the falling edge and the DUT updates on the rising
// edge. Every cycle, cycle() first checks the stored column against the
// golden model (the result of the previous cycle) and then drives the next
// inputs.
//
// Tests:
//   1. Reset     : the column is 0
//   2. Streaming : a new column is loaded every cycle, like the loop does
//   3. Hold      : load low while b_i keeps changing: the column is kept (stall)
//   4. Energy    : one load costs 2 (64 bits)
//   5. Area      : metrics_pkg::area = 8 B / 4 = 2
//
// Run from the folder with the Makefile (see README.md):
//   make TEST_MODULE=tb_b_buffer run
//--------------------------

module tb_b_buffer;

  //---------------------------
  // Design Time Parameters
  //---------------------------
  parameter int unsigned InDataWidth = 8;
  parameter int unsigned ArrK        = 8;

  //---------------------------
  // Test Parameters
  //---------------------------
  parameter int unsigned NumLoads        = 50;  // test 2
  parameter int unsigned HoldCycles      = 5;   // test 3
  parameter int unsigned MaxErrorsToShow = 5;   // per test
  parameter int unsigned TimeoutCycles   = 100_000;  // safety net (cycles)

  //---------------------------
  // Wires
  //---------------------------
  logic clk_i, rst_ni;

  logic                                     load_i;
  logic signed [ArrK-1:0][InDataWidth-1:0]  b_i;   // b_i[k]
  logic signed [ArrK-1:0][InDataWidth-1:0]  b_o;   // b_o[k]

  // Golden model: the stored column
  int golden [ArrK];

  // Bookkeeping per test and in total
  string       test_name;
  int unsigned test_errors;
  int unsigned test_cycles;
  int unsigned num_checks = 0;
  int unsigned num_errors = 0;

  //---------------------------
  // DUT
  //---------------------------
  b_buffer #(
    .InDataWidth ( InDataWidth ),
    .ArrK        ( ArrK        )
  ) i_dut (
    .clk_i       ( clk_i       ),
    .rst_ni      ( rst_ni      ),
    .load_i      ( load_i      ),
    .b_i         ( b_i         ),
    .b_o         ( b_o         )
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

  // Compare the stored column with the golden model right now
  task automatic check_all();
    test_cycles++;
    for (int k = 0; k < ArrK; k++) begin
      if ($signed(b_o[k]) !== golden[k]) begin
        if (test_errors < MaxErrorsToShow) begin
          $display("  MISMATCH %s, cycle %0d: B[%0d] = %0d, expected %0d",
                   test_name, test_cycles, k, $signed(b_o[k]), golden[k]);
        end
        test_errors++;
      end
    end
  endtask

  // One clock cycle: on the falling edge, check the result of the previous
  // cycle, then drive a new random column and update the golden model
  task automatic cycle(input bit load);
    @(negedge clk_i);
    check_all();
    for (int k = 0; k < ArrK; k++) b_i[k] = InDataWidth'($urandom());
    load_i = load;
    if (load) begin
      for (int k = 0; k < ArrK; k++) golden[k] = $signed(b_i[k]);
    end
  endtask

  task automatic start_test(input string name);
    test_name   = name;
    test_errors = 0;
    test_cycles = 0;
  endtask

  // One idle cycle checks the last driven cycle, then report the test
  task automatic end_test();
    cycle(1'b0);
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
    rst_ni = 1'b0;
    load_i = 1'b0;
    b_i    = '0;
    foreach (golden[k]) golden[k] = 0;
    repeat (3) @(negedge clk_i);
    rst_ni = 1'b1;

    // 1. Reset
    start_test("1. reset: column 0");
    repeat (3) cycle(1'b0);
    end_test();

    // 2. A new column every cycle
    start_test($sformatf("2. %0d loads back to back", NumLoads));
    repeat (NumLoads) cycle(1'b1);
    end_test();

    // 3. Stall: no load while the input changes
    start_test("3. hold without load");
    cycle(1'b1);
    repeat (HoldCycles) cycle(1'b0);
    end_test();

    // 4. Energy of one load: 64 bits -> 2
    start_test("4. energy of one load = 2");
    energy_before = metrics_pkg::energy;
    cycle(1'b1);
    cycle(1'b0);
    if (metrics_pkg::energy - energy_before != ArrK * InDataWidth / 32) begin
      $display("  MISMATCH energy of one load = %0.2f, expected %0d",
               metrics_pkg::energy - energy_before, ArrK * InDataWidth / 32);
      test_errors++;
    end
    end_test();

    // 5. Area: ArrK int8
    expected_area = ArrK * InDataWidth / 32;
    num_checks++;
    if (metrics_pkg::area == expected_area) begin
      $display("[PASS] 5. area = %0.0f (%0d B / 4)", metrics_pkg::area, ArrK * InDataWidth / 8);
    end else begin
      $display("[FAIL] 5. area = %0.0f, expected %0.0f", metrics_pkg::area, expected_area);
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
      $fatal(1, "tb_b_buffer failed");
    end
  end

  // Safety net: stop if the test hangs. Counted in clock cycles, so it does
  // not depend on the time unit of the simulator.
  initial begin
    repeat (TimeoutCycles) @(posedge clk_i);
    $fatal(1, "Timeout after %0d cycles", TimeoutCycles);
  end

endmodule
