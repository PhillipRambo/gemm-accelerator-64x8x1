//--------------------------
// Top-level testbench of the 64 x 8 x 1 GeMM/GeMV accelerator
// - Based on the course testbench tb_one_mac_gemm.sv
// - Uses the course includes/ for the golden model (gemm_golden), the start
//   and cycle count (start_and_wait_gemm) and the check (verify_result_c)
// - Runs the 6 workloads and 6 edge cases back to back without a reset
//
// Memory layouts (also in README.md):
// - A: tile-major. Tile (m_t, k_t) is 5 words from (m_t * K/8 + k_t) * 5.
//      Word w holds rows 13w to 13w+12 of the tile, 8 int8 each, zero padded.
// - B: word k_t * N + n holds B[8k_t to 8k_t+7][n].
// - C: column-major, 4 rows per word: C[m][n] is word n * M/4 + m/4, lane m % 4.
//
// Run from the folder with the Makefile (see README.md):
//   make TEST_MODULE=tb_gemm_accelerator run             (Verilator)
//   make TEST_MODULE=tb_gemm_accelerator questasim-run   (Questasim)
//--------------------------

module tb_gemm_accelerator;

  //---------------------------
  // Design Time Parameters
  //---------------------------

  // General parameters
  parameter int unsigned InDataWidth   = 8;
  parameter int unsigned OutDataWidth  = 32;
  parameter int unsigned SizeAddrWidth = 12;    // M up to 3072

  // Accelerator: 64 x 8 x 1 array, 8 accumulators per PE
  parameter int unsigned ArrM          = 64;
  parameter int unsigned ArrK          = 8;
  parameter int unsigned NumAcc        = 8;
  parameter int unsigned RowsPerWord   = 13;    // 13 rows of 8 B in an SRAM A word
  parameter int unsigned WordOutputs   = 4;     // 4 int32 in an SRAM C word

  localparam int unsigned NumWords   = (ArrM + RowsPerWord - 1) / RowsPerWord;  // 5
  localparam int unsigned PortAWidth = RowsPerWord * ArrK * InDataWidth;        // 832 bits
  localparam int unsigned PortBWidth = ArrK * InDataWidth;                      // 64 bits
  localparam int unsigned PortCWidth = WordOutputs * OutDataWidth;              // 128 bits

  // SRAM depth. GeMV 3 needs 2816/64 * 2048/8 * 5 = 56320 words of A.
  // Also the size of the flat arrays in the course functions.
  parameter int unsigned DataDepth     = 65536;
  parameter int unsigned AddrWidth     = (DataDepth <= 1) ? 1 : $clog2(DataDepth);

  //---------------------------
  // Test cases
  //---------------------------
  // workload = 1 for the 6 cases of the assignment (used for J)
  // M must be a multiple of 64 and K a multiple of 8
  //---------------------------
  typedef struct {
    string       name;
    int unsigned M;
    int unsigned K;
    int unsigned N;
    bit          workload;
  } test_case_t;

  localparam int unsigned NumCases = 12;

  test_case_t test_cases [NumCases] = '{
    //  name        M     K     N   workload
    '{"GeMM 1",     64,   64,  32, 1'b1},
    '{"GeMM 2",     64,  128,  32, 1'b1},
    '{"GeMM 3",     64,  576,  32, 1'b1},
    '{"GeMV 1",   1536,  576,   1, 1'b1},
    '{"GeMV 2",   3072, 1024,   1, 1'b1},
    '{"GeMV 3",   2816, 2048,   1, 1'b1},
    // Edge cases for the controller
    '{"Edge 1",     64,    8,   1, 1'b0},   // one tile, one column
    '{"Edge 2",    128,   16,  12, 1'b0},   // 2 row tiles, a partial block of 4 columns
    '{"Edge 3",    192,   24,   9, 1'b0},   // 3 row tiles, a partial block of 1 column
    '{"Edge 4",     64,    8,  24, 1'b0},   // 1 k-step per block, limited by port C
    '{"Edge 5",    128,    8,   1, 1'b0},   // blocks of a single issue
    '{"Edge 6",     64,   16,  64, 1'b0}    // 8 blocks back to back
  };

  // Results per case for the final report
  int unsigned case_cycles [NumCases];
  real         case_energy [NumCases];
  int unsigned case_errors [NumCases];

  //---------------------------
  // Wires
  //---------------------------

  // Size control
  logic [SizeAddrWidth-1:0] M_i, K_i, N_i;

  // Clock, reset, and other signals
  logic clk_i;
  logic rst_ni;
  logic start;
  logic done;
  logic [AddrWidth-1:0] test_depth;

  //---------------------------
  // Memory
  //---------------------------
  // Flat row-major matrices, A is done in chunks of rows
  logic signed [ InDataWidth-1:0] A_chunk  [DataDepth];   // some rows of A
  logic signed [ InDataWidth-1:0] B_flat   [DataDepth];
  logic signed [OutDataWidth-1:0] G_chunk  [DataDepth];   // golden C of those rows
  logic signed [OutDataWidth-1:0] G_memory [DataDepth];   // golden C, all rows
  logic signed [OutDataWidth-1:0] C_flat   [DataDepth];   // SRAM C, unpacked

  // Memory control
  logic [AddrWidth-1:0] sram_a_addr;
  logic [AddrWidth-1:0] sram_b_addr;
  logic [AddrWidth-1:0] sram_c_addr;
  logic                    sram_a_re;
  logic                    sram_b_re;

  // Memory access
  logic signed [PortAWidth-1:0] sram_a_rdata;
  logic signed [PortBWidth-1:0] sram_b_rdata;
  logic signed [PortCWidth-1:0] sram_c_wdata;
  logic                         sram_c_we;

  //---------------------------
  // Declaration of input and output memories (course macro, wider words)
  //---------------------------

  // Input memory A (read only), 104 B words
  single_port_memory #(
    .DataWidth     ( PortAWidth   ),
    .DataDepth     ( DataDepth    ),
    .AddrWidth     ( AddrWidth    )
  ) i_sram_a (
    .clk_i         ( clk_i        ),
    .rst_ni        ( rst_ni       ),
    .mem_addr_i    ( sram_a_addr  ),
    .mem_re_i      ( sram_a_re    ),
    .mem_we_i      ( '0           ),
    .mem_wr_data_i ( '0           ),
    .mem_rd_data_o ( sram_a_rdata )
  );

  // Input memory B (read only), 8 B words
  single_port_memory #(
    .DataWidth     ( PortBWidth   ),
    .DataDepth     ( DataDepth    ),
    .AddrWidth     ( AddrWidth    )
  ) i_sram_b (
    .clk_i         ( clk_i        ),
    .rst_ni        ( rst_ni       ),
    .mem_addr_i    ( sram_b_addr  ),
    .mem_re_i      ( sram_b_re    ),
    .mem_we_i      ( '0           ),
    .mem_wr_data_i ( '0           ),
    .mem_rd_data_o ( sram_b_rdata )
  );

  // Output memory C (write only), 16 B words
  single_port_memory #(
    .DataWidth     ( PortCWidth   ),
    .DataDepth     ( DataDepth    ),
    .AddrWidth     ( AddrWidth    )
  ) i_sram_c (
    .clk_i         ( clk_i        ),
    .rst_ni        ( rst_ni       ),
    .mem_addr_i    ( sram_c_addr  ),
    .mem_re_i      ( '0           ),
    .mem_we_i      ( sram_c_we    ),
    .mem_wr_data_i ( sram_c_wdata ),
    .mem_rd_data_o ( /* unused */ )
  );

  //---------------------------
  // DUT instantiation
  //---------------------------
  gemm_accelerator_top #(
    .InDataWidth    ( InDataWidth   ),
    .OutDataWidth   ( OutDataWidth  ),
    .AddrWidth      ( AddrWidth     ),
    .SizeAddrWidth  ( SizeAddrWidth ),
    .ArrM           ( ArrM          ),
    .ArrK           ( ArrK          ),
    .NumAcc         ( NumAcc        ),
    .RowsPerWord    ( RowsPerWord   ),
    .WordOutputs    ( WordOutputs   )
  ) i_dut (
    .clk_i          ( clk_i         ),
    .rst_ni         ( rst_ni        ),
    .start_i        ( start         ),
    .N_size_i       ( N_i           ),
    .M_size_i       ( M_i           ),
    .K_size_i       ( K_i           ),
    .sram_a_addr_o  ( sram_a_addr   ),
    .sram_b_addr_o  ( sram_b_addr   ),
    .sram_c_addr_o  ( sram_c_addr   ),
    .sram_a_re_o    ( sram_a_re     ),
    .sram_b_re_o    ( sram_b_re     ),
    .sram_a_rdata_i ( sram_a_rdata  ),
    .sram_b_rdata_i ( sram_b_rdata  ),
    .sram_c_wdata_o ( sram_c_wdata  ),
    .sram_c_we_o    ( sram_c_we     ),
    .done_o         ( done          )
  );

  //---------------------------
  // Tasks and functions
  //---------------------------
  `include "includes/common_tasks.svh"
  `include "includes/test_tasks.svh"
  `include "includes/test_func.svh"

  // metrics_pkg::area is added by every module at time 0.
  // metrics_pkg::energy is reset before each case and read after it.

  //---------------------------
  // Packing into the memory layout of the accelerator
  //---------------------------

  // SRAM A: set all words of the case to 0 first (padding)
  task automatic clear_a(input int unsigned M, input int unsigned K);
    for (int unsigned addr = 0; addr < (M / ArrM) * (K / ArrK) * NumWords; addr++) begin
      i_sram_a.memory[addr] = '0;
    end
  endtask

  // SRAM A: write the rows in A_chunk into their tile words.
  // Row m, value k goes to tile (m / 64, k / 8), word (m % 64) / 13,
  // byte 8 * ((m % 64) % 13) + k % 8.
  task automatic pack_a_rows(input int unsigned m0, input int unsigned rows,
                             input int unsigned K);
    logic [PortAWidth-1:0] word;
    int unsigned           m, tile_row, addr;
    for (int unsigned i = 0; i < rows; i++) begin
      m        = m0 + i;
      tile_row = m % ArrM;
      for (int unsigned kt = 0; kt < K / ArrK; kt++) begin
        addr = ((m / ArrM) * (K / ArrK) + kt) * NumWords + tile_row / RowsPerWord;
        word = i_sram_a.memory[addr];
        for (int unsigned k = 0; k < ArrK; k++) begin
          word[((tile_row % RowsPerWord) * ArrK + k) * InDataWidth +: InDataWidth] =
            A_chunk[i * K + kt * ArrK + k];
        end
        i_sram_a.memory[addr] = word;
      end
    end
  endtask

  // SRAM B: one word is 8 values of one column
  task automatic pack_b(input int unsigned K, input int unsigned N);
    logic [PortBWidth-1:0] word;
    for (int unsigned kt = 0; kt < K / ArrK; kt++) begin
      for (int unsigned n = 0; n < N; n++) begin
        for (int unsigned k = 0; k < ArrK; k++) begin
          word[k * InDataWidth +: InDataWidth] = B_flat[(kt * ArrK + k) * N + n];
        end
        i_sram_b.memory[kt * N + n] = word;
      end
    end
  endtask

  // SRAM C: fill with DEADBEEF so missing writes show up as errors
  task automatic clear_c(input int unsigned M, input int unsigned N);
    for (int unsigned addr = 0; addr < M * N / WordOutputs; addr++) begin
      i_sram_c.memory[addr] = {WordOutputs{32'hDEAD_BEEF}};
    end
  endtask

  // SRAM C to flat row-major C
  task automatic unpack_c(input int unsigned M, input int unsigned N);
    logic [PortCWidth-1:0] word;
    for (int unsigned n = 0; n < N; n++) begin
      for (int unsigned m = 0; m < M; m++) begin
        word = i_sram_c.memory[n * (M / WordOutputs) + m / WordOutputs];
        C_flat[m * N + n] = word[(m % WordOutputs) * OutDataWidth +: OutDataWidth];
      end
    end
  endtask

  //---------------------------
  // Test control
  //---------------------------

  // Clock generation
  initial begin
    clk_i = 1'b0;
    forever #5 clk_i = ~clk_i;  // 100MHz clock
  end

  // Sequence driver
  initial begin
    int unsigned chunk_rows;   // rows of A per gemm_golden call

    // Reset only once, the cases run back to back
    start  = 1'b0;
    M_i    = '0;
    K_i    = '0;
    N_i    = '0;
    rst_ni = 1'b0;
    #50;
    rst_ni = 1'b1;

    foreach (test_cases[c]) begin
      M_i = test_cases[c].M;
      K_i = test_cases[c].K;
      N_i = test_cases[c].N;

      $display("[%0s] A (%0d x %0d) * B (%0d x %0d) -> C (%0d x %0d)",
               test_cases[c].name, M_i, K_i, K_i, N_i, M_i, N_i);

      // Random int8 data for B as a flat row-major matrix
      for (integer k = 0; k < K_i; k++) begin
        for (integer n = 0; n < N_i; n++) begin
          B_flat[k*N_i+n] = $urandom() % (2 ** InDataWidth);
        end
      end
      pack_b(K_i, N_i);

      // A is made in chunks of rows that fit in the course arrays.
      // For each chunk: random data, golden result, pack into SRAM A
      clear_a(M_i, K_i);
      for (int unsigned m0 = 0; m0 < M_i; m0 += chunk_rows) begin
        chunk_rows = DataDepth / K_i;                         // rows that fit
        if (chunk_rows > M_i - m0) chunk_rows = M_i - m0;     // last chunk
        for (integer m = 0; m < chunk_rows; m++) begin
          for (integer k = 0; k < K_i; k++) begin
            A_chunk[m*K_i+k] = $urandom() % (2 ** InDataWidth);
          end
        end
        gemm_golden(chunk_rows, K_i, N_i, A_chunk, B_flat, G_chunk);
        for (int unsigned i = 0; i < chunk_rows * N_i; i++) begin
          G_memory[m0 * N_i + i] = G_chunk[i];
        end
        pack_a_rows(m0, chunk_rows, K_i);
      end
      clear_c(M_i, N_i);

      // Just delay 1 cycle
      clk_delay(1);

      // Energy of this case only
      metrics_pkg::energy = 0;
      start_and_wait_gemm(case_cycles[c]);
      case_energy[c] = metrics_pkg::energy;

      // Verify the result
      unpack_c(M_i, N_i);
      test_depth = M_i * N_i;
      verify_result_c(G_memory, C_flat, test_depth,
                      0, // Set this to 1 to make mismatches fatal
                      case_errors[c]);

      $display("[%0s] %0s: %0d cycles, %0.0f energy units\n",
               test_cases[c].name, (case_errors[c] == 0) ? "PASS" : "FAIL",
               case_cycles[c], case_energy[c]);

      // Just some trailing cycles
      // For easier monitoring in waveform
      clk_delay(10);
    end

    print_report();
    $finish;
  end

  //---------------------------
  // Final report
  //---------------------------
  // Pad a string with spaces to a fixed width
  function automatic string pad(string str, int unsigned width);
    while (str.len() < width) str = {str, " "};
    return str;
  endfunction

  task automatic print_report();
    int unsigned num_failed = 0;
    int unsigned num_workloads = 0;
    real         macs, norm_latency, j_sum = 0.0;

    $display("");
    $display("==================================================================================");
    $display(" RESULTS");
    $display("----------------------------------------------------------------------------------");
    $display(" %s | %4s %4s %4s | %8s | %12s | %10s | %8s | %s",
             pad("Case", 8), "M", "K", "N", "Cycles", "Energy", "Norm. lat.", "En./MAC", "Check");
    $display("----------------------------------------------------------------------------------");
    foreach (test_cases[c]) begin
      macs         = real'(test_cases[c].M) * test_cases[c].K * test_cases[c].N;
      norm_latency = 1000.0 * case_cycles[c] / macs;
      if (c > 0 && test_cases[c].workload != test_cases[c-1].workload)
        $display("----------------------------------------------------------------------------------");
      $display(" %s | %4d %4d %4d | %8d | %12.0f | %10.2f | %8.2f | %s",
               pad(test_cases[c].name, 8), test_cases[c].M, test_cases[c].K,
               test_cases[c].N, case_cycles[c], case_energy[c], norm_latency,
               case_energy[c] / macs, (case_errors[c] == 0) ? "PASS" : "FAIL");
      if (case_errors[c] != 0) num_failed++;
      if (test_cases[c].workload) begin
        j_sum += norm_latency;
        num_workloads++;
      end
    end
    $display("----------------------------------------------------------------------------------");
    $display(" J (mean normalized latency of the %0d workloads, x1000): %0.2f",
             num_workloads, j_sum / num_workloads);
    $display(" Area: %0.0f area units", metrics_pkg::area);
    $display("==================================================================================");
    $display("");

    if (num_failed != 0) begin
      $fatal(1, "%0d of %0d cases FAILED", num_failed, NumCases);
    end
    $display("All %0d cases passed!", NumCases);
  endtask

endmodule
