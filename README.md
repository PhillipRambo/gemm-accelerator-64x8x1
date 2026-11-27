# RTL of the 64x8x1 GeMM/GeMV accelerator

The accelerator has 64 PEs with 8 multipliers each (512 multipliers in total). Every PE has a bank of 8 accumulators, so the array runs output stationary with N-blocking (nb = 8). The SRAM ports are A = 104 B, B = 8 B and C = 16 B per cycle (1024 bits in total), fixed for all workloads. 

The folder follows the structure of the course repository (`cpaep2627_project`), so the same commands work here. It only contains files that are part of this design.

```
.
|-- Makefile                  # Verilator build/run and Questasim targets (from the course, see below)
|-- questa_setup.sh           # source this on an ESAT machine before running Questasim
|-- flists/                   # one filelist per testbench, named like the testbench
|-- includes/                 # from the course, unchanged: golden model, start/wait and verify tasks
|-- rtl/
|   |-- common/               # from the course, unchanged
|   |   |-- metrics_pkg.sv        # shared area/energy counters (used by every hook)
|   |   |-- single_port_memory.sv # the SRAM macro every design must use
|   |   `-- ceiling_counter.sv    # loop counter, used by the controller
|   `-- gemm/
|       |-- mac_pe_bank.sv        # PE: 8 multipliers + adder tree + bank of 8 accumulators
|       |-- mac_array.sv          # 64 PEs, A row per PE, B column broadcast, c_o[m][column]
|       |-- a_tile_buffer.sv      # A tile, double buffered (active + shadow), 5 words of 104 B
|       |-- b_buffer.sv           # one B column (8 B), loaded every compute cycle
|       |-- output_buffer.sv      # one block (64 x 8 int32), drained in 16 B words
|       |-- gemm_controller.sv    # loop counters, A fetch, handshakes, address generation
|       `-- gemm_accelerator_top.sv # the course I/O with wider SRAM ports for the wiring only
`-- tb/
    |-- tb_gemm_accelerator.sv # top level: the course testbench, all six workloads + edge cases
    |-- tb_mac_pe_bank.sv     # unit test of mac_pe_bank (12 checks)
    |-- tb_mac_array.sv       # unit test of mac_array (9 checks)
    |-- tb_a_tile_buffer.sv   # unit test of a_tile_buffer (8 checks)
    |-- tb_b_buffer.sv        # unit test of b_buffer (5 checks)
    `-- tb_output_buffer.sv   # unit test of output_buffer (8 checks)
```

## Running a testbench

Run every command from this folder. `TEST_MODULE` picks the testbench (default `tb_gemm_accelerator`), and its filelist is `flists/<TEST_MODULE>.flist`.

| What | Command |
|---|---|
| Build and run with Verilator (WSL) | `make TEST_MODULE=tb_gemm_accelerator run` |
| Only build with Verilator | `make TEST_MODULE=tb_gemm_accelerator` (binary in `bin/`) |
| Run with Questasim (ESAT, the reference simulator) | `source ./questa_setup.sh` then `make TEST_MODULE=tb_gemm_accelerator questasim-run` |
| Questasim with the GUI (waveforms, coverage) | `make TEST_MODULE=tb_gemm_accelerator questasim-run-gui` |
| A unit test | the same commands with `TEST_MODULE=tb_mac_pe_bank`, `tb_mac_array`, `tb_a_tile_buffer`, `tb_b_buffer` or `tb_output_buffer` |
| Remove all build output | `make clean` |

The Makefile differs from the course's in two places. The Verilator binary is rebuilt when any source or the filelist changes (the course version only watched the filelist), and the `run` target builds if needed and then runs the simulation.


## The top-level testbench

`tb_gemm_accelerator.sv` is the course's `tb_one_mac_gemm.sv`, adapted to this design. It keeps the course structure and uses the course's `includes/` unchanged: `gemm_golden` computes the golden C, `start_and_wait_gemm` starts the accelerator and counts the cycles until `done_o`, and `verify_result_c` compares the result (simple copy of original repo). What it adds:

- the SRAMs with the accelerator's port widths (A 104 B, B 8 B, C 16 B) and 65536 words deep,
- A is generated in chunks of rows, because the course functions work on arrays of 65536 entries and A of GeMV 3 has 2816 * 2048 values, so thats a lot more than what fitted meaning the verilator build used around 40Gb of RAM when increasing the datadepth
- the six workloads of the assignment in one simulation without a reset between them, followed by six edge cases for the controller (partial N blocks, blocks of one tile or one column),
- the normalized latency (1000 * cycles / MACs) and the score J in the final report.

Memory layout (also in the header of `tb/tb_gemm_accelerator.sv`):

- **A**, tile-major: tile (m_t, k_t) is 5 words from address (m_t * K/8 + k_t) * 5. Word w holds rows 13w ... 13w+12 of the tile, 8 int8 each, zero padded.
- **B**: word k_t * N + n holds B[8k_t ... 8k_t+7][n].
- **C**, column-major with 4 rows per word: C[m][n] is word n * M/4 + m/4, lane m % 4.

The design needs M to be a multiple of 64 and K a multiple of 8 (true for all six workloads)

## Status

All testbenches pass in Verilator 5.032.

| Testbench | Result |
|---|---|
| `tb_gemm_accelerator` | 12/12 cases pass (6 workloads + 6 edge cases), J = 6.39, area 2818 |
| `tb_mac_pe_bank` (8 multipliers, 8 accumulators) | 12/12 checks pass, area 32 |
| `tb_mac_array` (64x8x1, nb = 8) | 9/9 checks pass, area 2048 |
| `tb_a_tile_buffer` (2 x 64 x 8 int8) | 8/8 checks pass, area 256, energy 128 per tile |
| `tb_b_buffer` (8 int8) | 5/5 checks pass, area 2, energy 2 per load |
| `tb_output_buffer` (64 x 8 int32) | 8/8 checks pass, area 512, energy 64 per column |

Results of the top-level testbench (energy per case from start to done, including the SRAM accesses):

| Case | M | K | N | Cycles | Energy | Norm. latency | Energy/MAC |
|---|---|---|---|---|---|---|---|
| GeMM 1 | 64 | 64 | 32 | 583 | 845,375 | 4.45 | 6.45 |
| GeMM 2 | 64 | 128 | 32 | 656 | 1,557,056 | 2.50 | 5.94 |
| GeMM 3 | 64 | 576 | 32 | 2448 | 6,539,959 | 2.08 | 5.54 |
| GeMV 1 | 1536 | 576 | 1 | 8659 | 17,687,384 | 9.79 | 19.99 |
| GeMV 2 | 3072 | 1024 | 1 | 30739 | 62,733,106 | 9.77 | 19.94 |
| GeMV 3 | 2816 | 2048 | 1 | 56339 | 114,827,749 | 9.77 | 19.91 |


The unit testbenches check their module against a golden model (or, for the output buffer, a scoreboard of expected words) in every clock cycle, not only at the end of a test. Each testbench was also run against deliberately broken versions of its module (for example a PE that ignores `acc_sel`, or an A tile buffer that writes into the active half), and every one of them failed. 
