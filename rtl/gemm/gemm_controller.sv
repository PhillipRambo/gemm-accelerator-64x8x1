//---------------------------
// GeMM controller (loop counters, handshakes and address generation)
//
// Runs the loop nest m_t -> n_blk -> k_t -> n of the 64 x 8 x 1 accelerator
// with N-blocking (nb = NumAcc = 8) and generates all SRAM addresses.
// Two engines run in parallel:
// - Fetch engine:   reads the 5 SRAM A words of the next A tile into the
//                   shadow half of the A tile buffer, one tile ahead.
// - Compute engine: issues one B column per cycle. Stalls at the first column
//                   of a tile until the tile is fetched, and at the first
//                   column of a block until the previous block is unloaded.
//---------------------------

module gemm_controller #(
  parameter int unsigned SizeAddrWidth = 12,
  parameter int unsigned AddrWidth = 16,
  parameter int unsigned ArrM = 64,
  parameter int unsigned ArrK = 8,
  parameter int unsigned NumAcc = 8,
  parameter int unsigned RowsPerWord = 13,
  parameter int unsigned WordOutputs = 4,
  parameter int unsigned NumWords = (ArrM + RowsPerWord - 1) / RowsPerWord,  // 5
  parameter int unsigned NumGroups = ArrM / WordOutputs                      // 16
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic start_i,
  input  logic [SizeAddrWidth-1:0] M_size_i,
  input  logic [SizeAddrWidth-1:0] K_size_i,
  input  logic [SizeAddrWidth-1:0] N_size_i,
  output logic done_o,

  // SRAM A and the A tile buffer
  output logic [AddrWidth-1:0] sram_a_addr_o,
  output logic sram_a_re_o,
  output logic a_wr_en_o,
  output logic [$clog2(NumWords)-1:0] a_wr_word_o,
  output logic a_swap_o,

  // SRAM B and the B buffer
  output logic [AddrWidth-1:0] sram_b_addr_o,
  output logic sram_b_re_o,
  output logic b_load_o,

  // MAC array
  output logic mac_valid_o,
  output logic init_save_o,
  output logic [$clog2(NumAcc)-1:0] acc_sel_o,

  // Output buffer and SRAM C
  output logic out_load_o,
  output logic [$clog2(NumAcc+1)-1:0] out_num_cols_o,
  input  logic out_ready_i,
  input  logic out_wr_en_i,
  input  logic [$clog2(NumGroups)-1:0] out_grp_i,
  output logic [AddrWidth-1:0] sram_c_addr_o
);

  //---------------------------
  // Sizes in tiles
  //---------------------------
  logic [SizeAddrWidth-1:0] num_m_tiles;
  logic [SizeAddrWidth-1:0] num_k_tiles;
  logic [SizeAddrWidth-1:0] num_n_blocks;
  logic [SizeAddrWidth-1:0] col_words;     // SRAM C words per column

  assign num_m_tiles  = M_size_i / ArrM;
  assign num_k_tiles  = K_size_i / ArrK;
  assign num_n_blocks = (N_size_i + NumAcc - 1) / NumAcc;
  assign col_words    = M_size_i / WordOutputs;

  //---------------------------
  // Main state
  //---------------------------
  typedef enum logic {
    ControllerIdle,
    ControllerBusy
  } controller_state_t;

  controller_state_t state_q;
  logic start;
  logic c_active_q;
  logic f_active_q;

  assign start = (state_q == ControllerIdle) && start_i;

  //---------------------------
  // Compute engine counters: n -> k_t -> n_blk -> m_t (i.e forms the nested loop)
  //---------------------------
  logic issue;

  logic [SizeAddrWidth-1:0] n_cnt;
  logic [SizeAddrWidth-1:0] kt_cnt;
  logic [SizeAddrWidth-1:0] nb_cnt;

  logic n_last;
  logic kt_last;   // last column of a block
  logic nb_last;   // last column of a row tile
  logic mt_last;   // last column of the job

  // The last block can be partial: min(8, N - 8 * n_blk)
  logic [SizeAddrWidth-1:0] block_cols;

  assign block_cols = (N_size_i - nb_cnt * NumAcc >= NumAcc)
                    ? SizeAddrWidth'(NumAcc)
                    : N_size_i - nb_cnt * NumAcc;

  ceiling_counter #(
    .Width      (SizeAddrWidth),
    .HasCeiling (1)
  ) i_n_counter (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .tick_i       (issue),
    .clear_i      (start),
    .ceiling_i    (block_cols),
    .count_o      (n_cnt),
    .last_value_o (n_last)
  );

  ceiling_counter #(
    .Width      (SizeAddrWidth),
    .HasCeiling (1)
  ) i_kt_counter (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .tick_i       (n_last),
    .clear_i      (start),
    .ceiling_i    (num_k_tiles),
    .count_o      (kt_cnt),
    .last_value_o (kt_last)
  );

  ceiling_counter #(
    .Width      (SizeAddrWidth),
    .HasCeiling (1)
  ) i_nb_counter (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .tick_i       (kt_last),
    .clear_i      (start),
    .ceiling_i    (num_n_blocks),
    .count_o      (nb_cnt),
    .last_value_o (nb_last)
  );

  ceiling_counter #(
    .Width      (SizeAddrWidth),
    .HasCeiling (1)
  ) i_mt_counter (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .tick_i       (nb_last),
    .clear_i      (start),
    .ceiling_i    (num_m_tiles),
    .count_o      (),
    .last_value_o (mt_last)
  );

  //---------------------------
  // A fetch engine counters: word -> k_t -> n_blk -> m_t
  // (same tile order as the compute engine, one tile ahead)
  //---------------------------
  logic f_issue;

  logic [SizeAddrWidth-1:0] fw_cnt;

  logic fw_last;    // last word of a tile
  logic fkt_last;   // last word of an A strip
  logic fnb_last;   // strip read for the last block
  logic fmt_last;   // last A read of the job

  ceiling_counter #(
    .Width      (SizeAddrWidth),
    .HasCeiling (1)
  ) i_fw_counter (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .tick_i       (f_issue),
    .clear_i      (start),
    .ceiling_i    (SizeAddrWidth'(NumWords)),
    .count_o      (fw_cnt),
    .last_value_o (fw_last)
  );

  ceiling_counter #(
    .Width      (SizeAddrWidth),
    .HasCeiling (1)
  ) i_fkt_counter (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .tick_i       (fw_last),
    .clear_i      (start),
    .ceiling_i    (num_k_tiles),
    .count_o      (),
    .last_value_o (fkt_last)
  );

  ceiling_counter #(
    .Width      (SizeAddrWidth),
    .HasCeiling (1)
  ) i_fnb_counter (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .tick_i       (fkt_last),
    .clear_i      (start),
    .ceiling_i    (num_n_blocks),
    .count_o      (),
    .last_value_o (fnb_last)
  );

  ceiling_counter #(
    .Width      (SizeAddrWidth),
    .HasCeiling (1)
  ) i_fmt_counter (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .tick_i       (fnb_last),
    .clear_i      (start),
    .ceiling_i    (num_m_tiles),
    .count_o      (),
    .last_value_o (fmt_last)
  );

  //---------------------------
  // Handshakes
  //---------------------------
  logic first_col;        // first column of an A tile
  logic first_of_block;   // first column of a block
  logic shadow_full_q;    // all reads of the shadow tile are issued
  logic tile_ready;
  logic wait_tile, wait_out;
  logic unloaded_q;       // block issued, not yet in the output buffer
  logic load_pending_q;   // block complete in the accumulators, not yet loaded
  logic s1_valid_q, s1_first_col_q;

  assign first_col      = (n_cnt == '0);
  assign first_of_block = first_col && (kt_cnt == '0);

  // Swap in stage 1 of the first column of a tile
  assign a_swap_o = s1_valid_q && s1_first_col_q;

  assign f_issue = f_active_q && (!shadow_full_q || a_swap_o);

  // A tile swapped in this cycle belongs to the previous issue, so it does
  // not count (matters for 1-column blocks)
  assign tile_ready = (shadow_full_q && !a_swap_o) || (f_issue && fw_last);
  assign out_load_o = load_pending_q && out_ready_i;

  assign wait_tile = first_col && !tile_ready;
  assign wait_out  = first_of_block && unloaded_q && !out_load_o;
  assign issue     = c_active_q && !wait_tile && !wait_out;

  //---------------------------
  // Compute pipeline: stage 1 = B word arrives, stage 2 = MAC,
  // stage 3 = block complete in the accumulators
  //---------------------------
  logic s1_init_q, s1_block_end_q;
  logic [$clog2(NumAcc)-1:0] s1_sel_q;
  logic s2_valid_q, s2_init_q, s2_block_end_q;
  logic [$clog2(NumAcc)-1:0] s2_sel_q;
  logic s3_block_end_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s1_valid_q <= 1'b0;
      s1_first_col_q <= 1'b0;
      s1_init_q <= 1'b0;
      s1_sel_q <= '0;
      s1_block_end_q <= 1'b0;
      s2_valid_q <= 1'b0;
      s2_init_q <= 1'b0;
      s2_sel_q  <= '0;
      s2_block_end_q <= 1'b0;
      s3_block_end_q <= 1'b0;
    end else begin
      s1_valid_q <= issue;
      s1_first_col_q <= first_col;
      s1_init_q <= (kt_cnt == '0);
      s1_sel_q  <= n_cnt[$clog2(NumAcc)-1:0];
      s1_block_end_q <= kt_last;
      s2_valid_q <= s1_valid_q;
      s2_init_q <= s1_init_q;
      s2_sel_q  <= s1_sel_q;
      s2_block_end_q <= s1_valid_q && s1_block_end_q;
      s3_block_end_q <= s2_valid_q && s2_block_end_q;
    end
  end

  assign b_load_o = s1_valid_q;
  assign mac_valid_o = s2_valid_q;
  assign init_save_o = s2_init_q;
  assign acc_sel_o = s2_sel_q;

  //---------------------------
  // State and handshake registers
  //---------------------------
  logic [$clog2(NumAcc+1)-1:0] pend_cols_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= ControllerIdle;
      c_active_q <= 1'b0;
      f_active_q <= 1'b0;
      shadow_full_q <= 1'b0;
      unloaded_q <= 1'b0;
      load_pending_q <= 1'b0;
      pend_cols_q <= '0;
    end else begin
      if (start) state_q <= ControllerBusy;
      else if (done_o) state_q <= ControllerIdle;

      if (start) c_active_q <= 1'b1;
      else if (issue && mt_last) c_active_q <= 1'b0;
      if (start) f_active_q <= 1'b1;
      else if (f_issue && fmt_last) f_active_q <= 1'b0;

      if (start) shadow_full_q <= 1'b0;
      else if (f_issue && fw_last) shadow_full_q <= 1'b1;
      else if (a_swap_o) shadow_full_q <= 1'b0;

      // Set wins: a 1-column block can be issued when the previous loads
      if (issue && kt_last) unloaded_q <= 1'b1;
      else if (out_load_o) unloaded_q <= 1'b0;
      if (s3_block_end_q) load_pending_q <= 1'b1;
      else if (out_load_o) load_pending_q <= 1'b0;
      if (issue && kt_last) pend_cols_q <= block_cols[$clog2(NumAcc+1)-1:0];
    end
  end

  assign out_num_cols_o = pend_cols_q;

  // High in the cycle of the last SRAM C write
  assign done_o = (state_q == ControllerBusy) && !c_active_q && !unloaded_q &&
                  out_wr_en_i && out_ready_i;

  //---------------------------
  // Address generation
  //---------------------------
  logic [AddrWidth-1:0] a_ptr_q, a_strip_q;     // A: current word, strip start
  logic [AddrWidth-1:0] b_kbase_q, b_nbase_q;   // B: k_t * N + 8 n_blk, and 8 n_blk
  logic [AddrWidth-1:0] c_base_q, c_mbase_q;    // C: block base, and 16 m_t
  logic [AddrWidth-1:0] pend_cbase_q;
  logic [AddrWidth-1:0] c_col_ptr_q;

  // A: the strip of a row tile is re-read for every block
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      a_ptr_q  <= '0;
      a_strip_q <= '0;
    end else if (start) begin
      a_ptr_q <= '0;
      a_strip_q <= '0;
    end else if (f_issue) begin
      if (fkt_last && fnb_last) begin      // next row tile
        a_ptr_q <= a_ptr_q + 1'b1;
        a_strip_q <= a_ptr_q + 1'b1;
      end else if (fkt_last) begin         // re-read strip for next block
        a_ptr_q <= a_strip_q;
      end else begin
        a_ptr_q <= a_ptr_q + 1'b1;
      end
    end
  end

  // B: word k_t * N + 8 n_blk + n
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      b_kbase_q <= '0;
      b_nbase_q <= '0;
    end else if (start) begin
      b_kbase_q <= '0;
      b_nbase_q <= '0;
    end else if (n_last) begin
      if (kt_last && nb_last) begin        // next row tile
        b_kbase_q <= '0;
        b_nbase_q <= '0;
      end else if (kt_last) begin          // next block
        b_kbase_q <= b_nbase_q + NumAcc;
        b_nbase_q <= b_nbase_q + NumAcc;
      end else begin                       // next k-step
        b_kbase_q <= b_kbase_q + N_size_i;
      end
    end
  end

  assign sram_b_addr_o = b_kbase_q + n_cnt;
  assign sram_b_re_o = issue;

  // C: block (m_t, n_blk) starts at word 8 n_blk * M/4 + 16 m_t
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      c_base_q  <= '0;
      c_mbase_q <= '0;
      pend_cbase_q <= '0;
      c_col_ptr_q  <= '0;
    end else begin
      if (start) begin
        c_base_q  <= '0;
        c_mbase_q <= '0;
      end else if (issue && kt_last) begin
        pend_cbase_q <= c_base_q;
        if (nb_last) begin                  // next row tile
          c_base_q  <= c_mbase_q + NumGroups;
          c_mbase_q <= c_mbase_q + NumGroups;
        end else begin                      // next block
          c_base_q  <= c_base_q + NumAcc * col_words;
        end
      end
      // Drain column by column, M/4 words apart
      if (out_load_o) begin
        c_col_ptr_q <= pend_cbase_q;
      end else if (out_wr_en_i && out_grp_i == NumGroups - 1) begin
        c_col_ptr_q <= c_col_ptr_q + col_words;
      end
    end
  end

  assign sram_c_addr_o = c_col_ptr_q + out_grp_i;

  //---------------------------
  // A tile buffer write (SRAM A data arrives one cycle after the read)
  //---------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      a_wr_en_o <= 1'b0;
      a_wr_word_o <= '0;
    end else begin
      a_wr_en_o <= f_issue;
      a_wr_word_o <= fw_cnt[$clog2(NumWords)-1:0];
    end
  end

  assign sram_a_addr_o = a_ptr_q;
  assign sram_a_re_o = f_issue;

  //---------------------------
  // Size checks (simulation only)
  //---------------------------
  always @(posedge clk_i) begin
    if (rst_ni && start) begin
      if (M_size_i == 0 || M_size_i % ArrM != 0)
        $error("%m: M = %0d must be a non-zero multiple of %0d", M_size_i, ArrM);
      if (K_size_i == 0 || K_size_i % ArrK != 0)
        $error("%m: K = %0d must be a non-zero multiple of %0d", K_size_i, ArrK);
      if (N_size_i == 0)
        $error("%m: N must be at least 1");
    end
  end

endmodule