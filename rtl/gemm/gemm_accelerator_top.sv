//---------------------------
// GeMM/GeMV accelerator top module (64 x 8 x 1, nb = 8)
//
// Description:
// Connects the controller, the buffers and the MAC array to the three
// SRAMs. Same I/O as the course's 1-MAC baseline, only the SRAM data
// ports are wider. There is no logic here, only wiring.
//
// Ports A + B + C = 832 + 64 + 128 = 1024 bits
// Multipliers = 64 * 8 = 512
//
// Parameters:
// - InDataWidth   : Width of the input data
// - OutDataWidth  : Width of the output data
// - AddrWidth     : Width of the SRAM addresses
// - SizeAddrWidth : Width of the size inputs
// - ArrM, ArrK    : PEs and inputs per PE (64 x 8)
// - NumAcc        : Accumulators per PE (nb = 8)
// - RowsPerWord   : Tile rows in one SRAM A word (13)
// - WordOutputs   : Values in one SRAM C word (4)
//
// Ports:
// - clk_i, rst_ni  : Clock and active-low reset
// - start_i        : Start a GeMM
// - M/K/N_size_i   : Sizes of the workload
// - sram_a_*       : SRAM A read port (104 B)
// - sram_b_*       : SRAM B read port (8 B)
// - sram_c_*       : SRAM C write port (16 B)
// - done_o         : High in the cycle of the last SRAM C write
//---------------------------

module gemm_accelerator_top #(
  parameter int unsigned InDataWidth = 8,
  parameter int unsigned OutDataWidth = 32,
  parameter int unsigned AddrWidth = 16,
  parameter int unsigned SizeAddrWidth = 12,
  parameter int unsigned ArrM = 64,
  parameter int unsigned ArrK = 8,
  parameter int unsigned NumAcc = 8,
  parameter int unsigned RowsPerWord = 13,
  parameter int unsigned WordOutputs = 4,
  // SRAM port widths in bits
  parameter int unsigned PortAWidth = RowsPerWord * ArrK * InDataWidth,   // 832
  parameter int unsigned PortBWidth = ArrK * InDataWidth,                 // 64
  parameter int unsigned PortCWidth = WordOutputs * OutDataWidth          // 128
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic start_i,
  input  logic [SizeAddrWidth-1:0] M_size_i,
  input  logic [SizeAddrWidth-1:0] K_size_i,
  input  logic [SizeAddrWidth-1:0] N_size_i,
  output logic [AddrWidth-1:0] sram_a_addr_o,
  output logic [AddrWidth-1:0] sram_b_addr_o,
  output logic [AddrWidth-1:0] sram_c_addr_o,
  output logic sram_a_re_o,
  output logic sram_b_re_o,
  input  logic signed [PortAWidth-1:0] sram_a_rdata_i,
  input  logic signed [PortBWidth-1:0] sram_b_rdata_i,
  output logic signed [PortCWidth-1:0] sram_c_wdata_o,
  output logic sram_c_we_o,
  output logic done_o
);

  localparam int unsigned NumWords = (ArrM + RowsPerWord - 1) / RowsPerWord;  // 5
  localparam int unsigned NumGroups = ArrM / WordOutputs;                     // 16

  //---------------------------
  // Check the limits of the assignment
  //---------------------------
  initial begin
    if (ArrM * ArrK > 512)
      $fatal(1, "%m: %0d multipliers, the budget is 512", ArrM * ArrK);
    if (PortAWidth + PortBWidth + PortCWidth > 1024)
      $fatal(1, "%m: SRAM ports are %0d bits, the budget is 1024",
             PortAWidth + PortBWidth + PortCWidth);
  end

  //---------------------------
  // Wires
  //---------------------------

  // A tile buffer
  logic a_wr_en, a_swap;
  logic [$clog2(NumWords)-1:0] a_wr_word;
  logic signed [ArrM-1:0][ArrK-1:0][InDataWidth-1:0] a_tile;

  // B buffer
  logic b_load;
  logic signed [ArrK-1:0][InDataWidth-1:0] b_col;

  // MAC array
  logic mac_valid, init_save;
  logic [$clog2(NumAcc)-1:0] acc_sel;
  logic signed [ArrM-1:0][NumAcc-1:0][OutDataWidth-1:0] acc;

  // Output buffer
  logic out_load, out_ready, out_wr_en;
  logic [$clog2(NumAcc+1)-1:0] out_num_cols;
  logic [$clog2(NumGroups)-1:0] out_grp;

  //---------------------------
  // Controller
  //---------------------------
  gemm_controller #(
    .SizeAddrWidth  ( SizeAddrWidth ),
    .AddrWidth      ( AddrWidth     ),
    .ArrM           ( ArrM          ),
    .ArrK           ( ArrK          ),
    .NumAcc         ( NumAcc        ),
    .RowsPerWord    ( RowsPerWord   ),
    .WordOutputs    ( WordOutputs   )
  ) i_gemm_controller (
    .clk_i          ( clk_i         ),
    .rst_ni         ( rst_ni        ),
    .start_i        ( start_i       ),
    .M_size_i       ( M_size_i      ),
    .K_size_i       ( K_size_i      ),
    .N_size_i       ( N_size_i      ),
    .done_o         ( done_o        ),
    .sram_a_addr_o  ( sram_a_addr_o ),
    .sram_a_re_o    ( sram_a_re_o   ),
    .a_wr_en_o      ( a_wr_en       ),
    .a_wr_word_o    ( a_wr_word     ),
    .a_swap_o       ( a_swap        ),
    .sram_b_addr_o  ( sram_b_addr_o ),
    .sram_b_re_o    ( sram_b_re_o   ),
    .b_load_o       ( b_load        ),
    .mac_valid_o    ( mac_valid     ),
    .init_save_o    ( init_save     ),
    .acc_sel_o      ( acc_sel       ),
    .out_load_o     ( out_load      ),
    .out_num_cols_o ( out_num_cols  ),
    .out_ready_i    ( out_ready     ),
    .out_wr_en_i    ( out_wr_en     ),
    .out_grp_i      ( out_grp       ),
    .sram_c_addr_o  ( sram_c_addr_o )
  );

  //---------------------------
  // Input buffers
  //---------------------------
  a_tile_buffer #(
    .InDataWidth ( InDataWidth    ),
    .ArrM        ( ArrM           ),
    .ArrK        ( ArrK           ),
    .RowsPerWord ( RowsPerWord    )
  ) i_a_tile_buffer (
    .clk_i       ( clk_i          ),
    .rst_ni      ( rst_ni         ),
    .wr_en_i     ( a_wr_en        ),
    .wr_word_i   ( a_wr_word      ),
    .wr_data_i   ( sram_a_rdata_i ),  // 13 rows of 8 int8
    .swap_i      ( a_swap         ),
    .a_o         ( a_tile         )
  );

  b_buffer #(
    .InDataWidth ( InDataWidth    ),
    .ArrK        ( ArrK           )
  ) i_b_buffer (
    .clk_i       ( clk_i          ),
    .rst_ni      ( rst_ni         ),
    .load_i      ( b_load         ),
    .b_i         ( sram_b_rdata_i ),  // 8 int8 of one B column
    .b_o         ( b_col          )
  );

  //---------------------------
  // MAC array
  //---------------------------
  mac_array #(
    .InDataWidth  ( InDataWidth  ),
    .OutDataWidth ( OutDataWidth ),
    .ArrM         ( ArrM         ),
    .ArrK         ( ArrK         ),
    .NumAcc       ( NumAcc       )
  ) i_mac_array (
    .clk_i        ( clk_i        ),
    .rst_ni       ( rst_ni       ),
    .a_i          ( a_tile       ),
    .b_i          ( b_col        ),
    .acc_sel_i    ( acc_sel      ),
    .valid_i      ( mac_valid    ),
    .init_save_i  ( init_save    ),
    .acc_clr_i    ( 1'b0         ),   // not used, init_save starts every output
    .c_o          ( acc          )
  );

  //---------------------------
  // Output buffer
  //---------------------------
  output_buffer #(
    .OutDataWidth ( OutDataWidth   ),
    .ArrM         ( ArrM           ),
    .NumAcc       ( NumAcc         ),
    .WordOutputs  ( WordOutputs    )
  ) i_output_buffer (
    .clk_i        ( clk_i          ),
    .rst_ni       ( rst_ni         ),
    .load_i       ( out_load       ),
    .num_cols_i   ( out_num_cols   ),
    .c_i          ( acc            ),
    .ready_o      ( out_ready      ),
    .wr_en_o      ( out_wr_en      ),
    .col_o        ( /* unused */   ),   // not needed, the controller uses grp
    .grp_o        ( out_grp        ),
    .data_o       ( sram_c_wdata_o )  // 4 int32 of one column
  );

  assign sram_c_we_o = out_wr_en;

endmodule
