class otp_ctrl_scoreboard #(type CFG_T = otp_ctrl_env_cfg)
    extends cip_base_scoreboard #(
     .CFG_T(CFG_T), 
     .RAL_T(otp_ctrl_core_reg_block),
     .COV_T(otp_ctrl_env_cov)
     );

    `uvm_component_param_utils(otp_ctrl_scoreboard#(CFG_T))

    // local variables
    bit [TL_DW-1:0] otp_a [OTP_ARRAY_SIZE];

      // lc_state and lc_cnt that stored in OTP
    bit [LC_PROG_DATA_SIZE-1:0] otp_lc_data;
    bit [EDN_BUS_WIDTH-1:0]     edn_data_q[$];

    // This flag is used when reset is issued during otp dai write access.
    bit dai_wr_ip;
    int dai_digest_ip = LifeCycleIdx; // Default to LC as it does not have digest.
    bit ignore_digest_chk = 0;
    
    // This bit is used for DAI interface to mark if the read access is valid.
    bit dai_read_valid;

    // This captures the regwen state as configured by the SW side (i.e. without HW modulation
    // with the idle signal overlaid).
    bit direct_access_regwen_state = 1;
    
    // ICEBOX(#17798): currently scb will skip checking the readout value if the ECC error is
    // uncorrectable. Because if the error is uncorrectable, current scb does not track all the
    // backdoor injected values.
    // This issue proposes to track the otp_memory_array in mem_bkdr_if and once backdoor inject any
    // value, mem_bkdr_if will update its otp_memory_array.
    bit check_dai_rd_data = 1;

    // Status related variables
    bit under_chk, under_dai_access;
    bit [TL_DW-1:0] exp_status, status_mask;

    otp_alert_e exp_alert = OtpNoAlert;

    // local queues to hold incoming packets pending comparison

    `uvm_component_new

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        
    endfunction : build_phase

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        
    endfunction : connect_phase

    task run_phase(uvm_phase phase);
        super.run_phase(phase);
        fork
            process_wipe_mem();
            process_otp_power_up();
        join_none
    endtask : run_phase

    task process_wipe_mem();
        forever begin
            @(posedge cfg.backdoor_clear_mem) begin
                bit [SCRAMBLE_DATA_SIZE-1:0] data;
                otp_a        = '{default:0};
                otp_lc_data  = '{default:0};
                // secret partitions have been scrambled before writing to OTP.
                // here calculate the pre-srambled raw data when clearing internal OTP to all 0s.
                data = descramble_data(0, Secret0Idx);
                for (int i = Secret0Offset / TL_SIZE;
                    i <= Secret0DigestOffset / TL_SIZE - 1;
                    i++) begin
                otp_a[i] = ((i - Secret0Offset / TL_SIZE) % 2) ?
                    data[SCRAMBLE_DATA_SIZE-1:TL_DW] : data[TL_DW-1:0];
                end
                // secret partitions have been scrambled before writing to OTP.
                // here calculate the pre-srambled raw data when clearing internal OTP to all 0s.
                data = descramble_data(0, Secret1Idx);
                for (int i = Secret1Offset / TL_SIZE;
                    i <= Secret1DigestOffset / TL_SIZE - 1;
                    i++) begin
                otp_a[i] = ((i - Secret1Offset / TL_SIZE) % 2) ?
                    data[SCRAMBLE_DATA_SIZE-1:TL_DW] : data[TL_DW-1:0];
                end
                // secret partitions have been scrambled before writing to OTP.
                // here calculate the pre-srambled raw data when clearing internal OTP to all 0s.
                data = descramble_data(0, Secret2Idx);
                for (int i = Secret2Offset / TL_SIZE;
                    i <= Secret2DigestOffset / TL_SIZE - 1;
                    i++) begin
                otp_a[i] = ((i - Secret2Offset / TL_SIZE) % 2) ?
                    data[SCRAMBLE_DATA_SIZE-1:TL_DW] : data[TL_DW-1:0];
                end
                `uvm_info(`gfn, "clear internal memory and digest", UVM_HIGH)
                cfg.backdoor_clear_mem = 0;
                dai_wr_ip = 0;
                dai_digest_ip = LifeCycleIdx;
            end
        end
    endtask : process_wipe_mem

    task process_otp_power_up();
        forever begin
            wait(cfg.en_scb);
            @(posedge cfg.otp_ctrl_vif.pwr_otp_done_o || cfg.under_reset ||
              cfg.otp_ctrl_vif.alert_reqs) begin
                if (!cfg.under_reset && !cfg.otp_ctrl_vif.alert_reqs && cfg.en_scb) begin
                    otp_ctrl_part_pkg::otp_hw_cfg0_data_t  exp_hw_cfg0_data;
                    otp_ctrl_part_pkg::otp_hw_cfg1_data_t  exp_hw_cfg1_data;

                    predict_digest_csrs();

                if (cfg.otp_ctrl_vif.under_error_states() == 0) begin
                    // Dai access is unlocked because the power init is done
                    void'(ral.direct_access_regwen.predict(direct_access_regwen_state));

                    // Dai idle is set because the otp init is done
                    exp_status[OtpDaiIdleIdx] = 1;
                end
                // Hwcfg_o gets data from OTP HW cfg partition
                exp_hw_cfg0_data = cfg.otp_ctrl_vif.under_error_states() ?
                                    otp_ctrl_part_pkg::PartInvDefault[HwCfg0Offset*8 +: HwCfg0Size*8] :
                                    otp_hw_cfg0_data_t'({<<32 {otp_a[HwCfg0Offset/4 +: HwCfg0Size/4]}});
                `DV_CHECK_EQ(cfg.otp_ctrl_vif.otp_broadcast_o.valid, lc_ctrl_pkg::On)
                `DV_CHECK_EQ(cfg.otp_ctrl_vif.otp_broadcast_o.hw_cfg0_data, exp_hw_cfg0_data)

                // Hwcfg_o gets data from OTP HW cfg partition
                exp_hw_cfg1_data = cfg.otp_ctrl_vif.under_error_states() ?
                                    otp_ctrl_part_pkg::PartInvDefault[HwCfg1Offset*8 +: HwCfg1Size*8] :
                                    otp_hw_cfg1_data_t'({<<32 {otp_a[HwCfg1Offset/4 +: HwCfg1Size/4]}});
                `DV_CHECK_EQ(cfg.otp_ctrl_vif.otp_broadcast_o.valid, lc_ctrl_pkg::On)
                `DV_CHECK_EQ(cfg.otp_ctrl_vif.otp_broadcast_o.hw_cfg1_data, exp_hw_cfg1_data)
                end else if (cfg.otp_ctrl_vif.alert_reqs) begin
                // Ignore digest CSR check when otp_ctrl initialization is interrupted by fatal errors.
                // SCB cannot predict how many partitions already finished initialization and updated
                // the digest value to CSRs.
                ignore_digest_chk = 1;
                end
            end
        end
    endtask : process_otp_power_up

endclass : otp_ctrl_scoreboard