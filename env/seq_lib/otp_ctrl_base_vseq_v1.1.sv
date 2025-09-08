//--------------------------------
//--------------------------------
//     BASE VSEQUENCE
//--------------------------------
//--------------------------------
class otp_ctrl_base_vseq extends cip_base_vseq #(
    .RAL_T               (otp_ctrl_core_reg_block),
    .CFG_T               (otp_ctrl_env_cfg),
    .COV_T               (otp_ctrl_env_cov),
    .VIRTUAL_SEQUENCER_T (otp_ctrl_virtual_sequencer)
  );
    `uvm_object_utils(otp_ctrl_base_vseq)
    //`uvm_object_new

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
    endfunction: build_phase

    // various knobs to enable certain routines
    bit do_otp_ctrl_init = 1'b1;
    bit do_otp_pwr_init  = 1'b1;

    // To only write unused OTP address, sequence will collect all the written addresses to an
    // associative array to avoid `write_blank_addr_error`.
    bit write_unused_addr = 1;
    static bit used_dai_addrs[bit [OTP_ADDR_WIDTH - 1 : 0]];

    rand bit [NumOtpCtrlIntr-1:0] en_intr;

    rand int apply_reset_during_pwr_init_cycles;

    bit is_valid_dai_op = 1;

      // According to spec, the period between digest calculation and reset should not issue any write.
    bit [NumPart-2:0] digest_calculated;

    // For stress_all_with_rand reset sequence to issue reset during OTP operations.
    bit do_digest_cal, do_otp_rd, do_otp_wr;

    // LC program request will use a separate variable to automatically set to non-blocking setting
    // when LC error bit is set.
    bit default_req_blocking = 1;
    bit lc_prog_blocking     = 1;
    bit dai_wr_inprogress = 0;
    uint32_t op_done_spinwait_timeout_ns = 20_000_000;

    otp_ctrl_callback_vseq callback_vseq;

    constraint apply_reset_during_pwr_init_cycles_c {
        apply_reset_during_pwr_init_cycles == 0;
    }

    virtual task pre_start();
        `uvm_create_on(callback_vseq, p_sequencer);
        super.pre_start();
    endtask : pre_start

    virtual task dut_init(string reset_kind = "HARD");
        // OTP has dut and edn reset. If assign OTP values after `super.dut_init()`, and if dut reset
        // deasserts earlier than edn reset, some OTP outputs might remain X or Z when dut clock is
        // running.
        otp_ctrl_vif_init();
        super.dut_init(reset_kind);
        callback_vseq.dut_init_callback();

        cfg.backdoor_clear_mem = 0;
        // reset power init pin and lc pins
        if (do_otp_ctrl_init && do_apply_reset) otp_ctrl_init();
        cfg.clk_rst_vif.wait_clks($urandom_range(0, 10));
        if (do_otp_pwr_init && do_apply_reset) otp_pwr_init();
        callback_vseq.post_otp_pwr_init();
    endtask : dut_init

      // Cfg errors are cleared after reset
    virtual task apply_reset(string kind = "HARD");
        super.apply_reset(kind);
        cfg.otp_ctrl_vif.release_part_access_mubi();
        clear_seq_flags();
    endtask : apply_reset

  virtual task otp_ctrl_vif_init();
    cfg.otp_ctrl_vif.drive_pwr_otp_init(0);
    cfg.otp_ctrl_vif.drive_ext_voltage_h_io(1'bz);

    // Unused signals in open sourced OTP memory
    `DV_CHECK_RANDOMIZE_FATAL(cfg.dut_cfg)
    cfg.otp_ctrl_vif.otp_ast_pwr_seq_h_i    = cfg.dut_cfg.otp_ast_pwr_seq_h;
    cfg.otp_ctrl_vif.scan_en_i              = cfg.dut_cfg.scan_en;
    cfg.otp_ctrl_vif.scan_rst_ni            = cfg.dut_cfg.scan_rst_n;
    cfg.otp_ctrl_vif.scanmode_i             = cfg.dut_cfg.scanmode;
    cfg.otp_ctrl_vif.otp_vendor_test_ctrl_i = cfg.dut_cfg.otp_vendor_test_ctrl;
  endtask : otp_ctrl_vif_init

  // drive otp_pwr req pin to initialize OTP, and wait until init is done
  virtual task otp_pwr_init();
    cfg.otp_ctrl_vif.drive_pwr_otp_init(1);
    if (apply_reset_during_pwr_init_cycles > 0) begin
      `DV_SPINWAIT_EXIT(
          cfg.clk_rst_vif.wait_clks(apply_reset_during_pwr_init_cycles);,
          wait (cfg.otp_ctrl_vif.pwr_otp_done_o == 1);)
      if (cfg.otp_ctrl_vif.pwr_otp_done_o == 0) begin
        cfg.otp_ctrl_vif.drive_pwr_otp_init(0);
        apply_reset();
        cfg.otp_ctrl_vif.drive_pwr_otp_init(1);
      end
    end
    wait (cfg.otp_ctrl_vif.pwr_otp_done_o == 1);
    cfg.otp_ctrl_vif.drive_pwr_otp_init(0);
    digest_calculated = 0;
  endtask : otp_pwr_init

    virtual function void clear_seq_flags();
        do_digest_cal = 0;
        do_otp_rd = 0;
        do_otp_wr = 0;
    endfunction

    // setup basic otp_ctrl features
    virtual task otp_ctrl_init();
    // reset memory to avoid readout X
        clear_otp_memory();
        // lc_state = lc_state_e'(0);
        // lc_cnt   = lc_cnt_e'(0);
  endtask

    virtual function void clear_otp_memory();
        cfg.mem_bkdr_util_h.clear_mem();
        cfg.backdoor_clear_mem = 1;
        used_dai_addrs.delete();
    endfunction

    // Overide this task for otp_ctrl_common_vseq and otp_ctrl_stress_all_with_rand_reset_vseq
    // because some registers won't set to default value until otp_init is done.
    virtual task read_and_check_all_csrs_after_reset();
        cfg.otp_ctrl_vif.drive_lc_escalate_en(lc_ctrl_pkg::Off);
        otp_pwr_init();
        super.read_and_check_all_csrs_after_reset();
    endtask
endclass : otp_ctrl_base_vseq