//-----------------------
// MAC processing element with an accumulator bank 
//
// Description:
// This module implements a more complex Multiply-Accumulate (MAC) processing element (PE) than given initially
// that can handle multiple input pairs simultaneously. It takes in multiple pairs of
// input operands, performs multiplication on each pair, however now it can hold 8  output columns (N) with a bank of accumulators.
// The PE supports initialization and accumulation control signals.
// This has an output stationary structure.
//
// Parameters:
// - InDataWidth  : Width of the input data (default: 8 bits)
// - NumInputs    : Number of input pairs to process simultaneously (default: 8)
// - OutDataWidth : Width of the output data (default: 32 bits)
// - NumAcc       : Number of accumulators in the bank (default: 8, must be >= 2) 
//
// Ports:
// - clk_i        : Clock input
// - rst_ni       : Active-low reset input
// - a_i         : Input operand A (array of NumInputs elements)
// - b_i         : Input operand B (array of NumInputs elements)
// - acc_sel_i    : Which accumulator to update this cycle (0 .. NumAcc-1) 
// - a_valid_i    : Valid signal for input A
// - b_valid_i    : Valid signal for input B
// - init_save_i  : Initialization signal for saving the first multiplication result
//                  (only has effect when A and B are valid)
// - acc_clr_i    : Clear signal for all accumulators 
// - c_o          : All accumulators at once, c_o[j] = accumulator j
//-----------------------

module mac_pe_bank #(
  parameter int unsigned InDataWidth  = 8, // assign the data witdh in this case 1 bytes
  parameter int unsigned NumInputs    = 8, // K = 8: 8 bytes of A and B per cycle (8 multipliers)
  parameter int unsigned OutDataWidth = 32,
  parameter int unsigned NumAcc       = 8 // assign the number of accummulators needed 
)(
  // Clock and reset
  input  logic clk_i,
  input  logic rst_ni,
  // Input operands
  input  logic signed [NumInputs-1:0][InDataWidth-1:0] a_i,
  input  logic signed [NumInputs-1:0][InDataWidth-1:0] b_i,
  // Accumulator select
  input  logic [$clog2(NumAcc)-1:0] acc_sel_i,  // making sure that we get enough bits to set the select
  // Valid signals for inputs
  input  logic a_valid_i,
  input  logic b_valid_i,
  input  logic init_save_i,
  // Clear signal for output
  input  logic acc_clr_i,
  // Output accumulation
  output logic signed [NumAcc-1:0][OutDataWidth-1:0] c_o // fanning out the outputs of accummualotrs
);

  // Wires and logic
  logic acc_valid;
  logic signed [OutDataWidth-1:0] mult_result;

  assign acc_valid = a_valid_i && b_valid_i;

  // Combined multiplication, so the for loop unrolls into numinputs parallel multipliers and and adder tree
  always_comb begin
    mult_result = '0;
    for (int i = 0; i < NumInputs; i++) begin
      mult_result += $signed(a_i[i]) * $signed(b_i[i]);
    end
  end

  // Accumulation unit, the written out put is selected for a given accummulator
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      c_o <= '0;
    end else if (acc_valid) begin // acc valid control valid inputs to produce product
      if (init_save_i) begin 
        c_o[acc_sel_i] <= mult_result; // overwrite for k=0                 
      end else begin
        c_o[acc_sel_i] <= c_o[acc_sel_i] + mult_result;  // next k-steps we add
      end
    end else if (acc_clr_i) begin
      c_o <= '0; // clear all 8 accummulators
    end
  end

  //--------------------------------
  // DESIGN NOTE: IMPORTANT! Area logging
  // Make sure to add an area logging mechanic
  // In this scenario, we add to the shared area
  // variable in metrics_pkg (rtl/common/metrics_pkg.sv),
  // so this works under any testbench top.
  //
  // In here the area is dependent on the MAC and register.
  // From the document's table:
  // 1 multiply = 2, 1 add = 1
  // 1 MAC = 1 multiply + 1 adder = 2 + 1 = 3
  // 1 32-bit register = 1, and there are NumAcc of them 
  // For NumInputs = 8, NumAcc = 8: 3*8 + 8 = 32
  //--------------------------------

  initial begin
    #0;
    metrics_pkg::area += (3*NumInputs) + NumAcc*(OutDataWidth/32); 
    $display("%m added %d to area", (3*NumInputs) + NumAcc*(OutDataWidth/32)); 
  end

  //--------------------------------
  //  DESIGN NOTE: IMPORTANT! Energy logging
  // Energy is dependent on how many MAC operations you do
  // Operation is triggered for any change in its inputs (estimate it)
  // Local register is triggered for every change in its output too
  //
  // From the table we had:
  // one int8 x int8 = 2 energy units per op
  // one int32 adder = 1 energy unit per op
  // then we have the c_o output stationary NumAcc accumulator which has:
  // 1 32-bit register = 1 energy per update
  // The total energy per cycle is then the sum of the MAC operations and the register update.
  //--------------------------------

  // Always @ makes these asynchronous events
  genvar i;
  generate  for (i = 0; i < NumInputs; i++) begin
    always @ (a_i[i] or b_i[i]) begin
      metrics_pkg::energy += 2 + 1; //1 MUL + 1 ADD
    end
  end
  endgenerate

  // one hook per accumulator, so only the accumulators that change cost energy
  // (normally 1 per cycle, a clear of the whole bank counts every changed one)
  genvar j;
  generate for (j = 0; j < NumAcc; j++) begin : g_acc_energy
    always @ (c_o[j]) begin
      metrics_pkg::energy += 1; // 1 energy for the register update
    end
  end
  endgenerate


endmodule
