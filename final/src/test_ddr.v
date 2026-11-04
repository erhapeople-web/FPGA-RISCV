

////////////////////////////////////////////////////////////////
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC
// ALL RIGHTS REVERVED.
////////////////////////////////////////////////////////////////
//Description:
//Author:  wxxiao
//History: v1.0
////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
module test_ddr #(
   parameter THERMAL_DIAGNOSTIC = 0,
   parameter THERMAL_CPU_LOAD = 1,
   parameter LOAD_VIDEO_ENABLE = 1,
   parameter LOAD_LIMIT_SECONDS = 300,
   parameter LOAD_CLOCK_HZ = 27000000,
   parameter LOAD_WARMUP_CYCLES = 2700000,
   parameter LOAD_CONVERSION_TIMEOUT_CYCLES = 27000000,
   parameter THERMAL_BASE_CYCLES = 100000000,
   parameter THERMAL_DWELL_CYCLES = 200000000,
   parameter THERMAL_TIMEOUT_CYCLES = 300000000,
   parameter THERMAL_VIDEO_SECONDS = 900,
   parameter THERMAL_WARMUP_CYCLES = 2700000,
   parameter THERMAL_SAMPLE_CYCLES = 27000000,
   parameter THERMAL_ACCESS_TIMEOUT = 270000,
   parameter THERMAL_BAUD = 115200,

   parameter MEM_ROW_WIDTH        = 15         ,

   parameter MEM_COLUMN_WIDTH     = 10         ,

   parameter MEM_BANK_WIDTH       = 3          ,

  parameter MEM_DQ_WIDTH          = 32         ,

  parameter MEM_DQS_WIDTH         = 4

)(
input                                ref_clk_p                 ,
input                                ref_clk_n                 ,
input                                free_clk                  ,
input                                rst_board                 ,
output                               pll_lock                  ,
output                               ddrphy_cpd_lock           ,
output                               ddr_init_done             ,
//uart
input                                uart_rxd                  ,
output                               uart_txd                  ,


output                               mem_cs_n                  ,

output                               mem_rst_n                 ,
output                               mem_ck                    ,
output                               mem_ck_n                  ,
output                               mem_cke                   ,
output                               mem_ras_n                 ,
output                               mem_cas_n                 ,
output                               mem_we_n                  ,
output                               mem_odt                   ,
output      [MEM_ROW_WIDTH-1:0]      mem_a                     ,
output      [MEM_BANK_WIDTH-1:0]     mem_ba                    ,
inout       [MEM_DQ_WIDTH/8-1:0]     mem_dqs                   ,
inout       [MEM_DQ_WIDTH/8-1:0]     mem_dqs_n                 ,
inout       [MEM_DQ_WIDTH-1:0]       mem_dq                    ,
output      [MEM_DQ_WIDTH/8-1:0]     mem_dm                    ,
output reg                           heart_beat_led            ,
output                               cpu_ready_led,
output                               err_flag_led,
// camera (OV5640 on the FMC J2 connector)
input                                cam_pclk                  ,
input                                cam_vsync                 ,
input                                cam_href                  ,
input  [7:0]                         cam_data                  ,
output                               cam_resetn                ,
output                               cam_scl                   ,
inout                                cam_sda                   ,
// HDMI out (MS7210)
output                               hdmi_resetn               ,
output                               hdmi_scl                  ,
inout                                hdmi_sda                  ,
output                               pix_clk                   ,
output                               hs_out                    ,
output                               vs_out                    ,
output                               de_out                    ,
output [7:0]                         r_out                     ,
output [7:0]                         g_out                     ,
output [7:0]                         b_out                     

);


parameter CTRL_ADDR_WIDTH = MEM_ROW_WIDTH + MEM_BANK_WIDTH + MEM_COLUMN_WIDTH;
parameter TH_1S = 27'd33000000;
parameter REM_DQS_WIDTH = 9 - MEM_DQS_WIDTH;

wire                        core_clk                   ;
wire [CTRL_ADDR_WIDTH-1:0]  axi_awaddr                 ;
wire                        axi_awuser_ap              ;
wire [3:0]                  axi_awuser_id              ;
wire [3:0]                  axi_awlen                  ;
wire                        axi_awready                ;
wire                        axi_awvalid                ;
wire [MEM_DQ_WIDTH*8-1:0]   axi_wdata                  ;
wire [MEM_DQ_WIDTH*8/8-1:0] axi_wstrb                  ;
wire                        axi_wready                 ;
wire [3:0]                  axi_wusero_id              ;
wire                        axi_wusero_last            ;
wire [CTRL_ADDR_WIDTH-1:0]  axi_araddr                 ;
wire                        axi_aruser_ap              ;
wire [3:0]                  axi_aruser_id              ;
wire [3:0]                  axi_arlen                  ;
wire                        axi_arready                ;
wire                        axi_arvalid                ;
wire [MEM_DQ_WIDTH*8-1:0]   axi_rdata  /* synthesis syn_keep = 1 */;
wire                        axi_rvalid /* synthesis syn_keep = 1 */;
wire [3:0]                  axi_rid                    ;
wire                        axi_rlast                  ;
wire                        resetn                     ;
wire                        bist_run_led               ;
wire                        err_flag                   ;

assign err_flag_led = err_flag | bist_run_led | thermal_ot | (THERMAL_DIAGNOSTIC && diag_fault);

reg  [26:0]                 cnt                        ;
wire [7:0]                  err_cnt                    ;
wire                        free_clk_g                 ;

//***********************************************************************************
//uart ctrl
wire [31:0]                 ctrl_bus_0                 ;
wire [31:0]                 ctrl_bus_1                 ;
wire [31:0]                 ctrl_bus_2                 ;
wire [31:0]                 ctrl_bus_3                 ;
wire [31:0]                 ctrl_bus_4                 ;
wire [31:0]                 ctrl_bus_5                 ;
wire [31:0]                 ctrl_bus_6                 ;
wire [31:0]                 ctrl_bus_7                 ;
wire [31:0]                 ctrl_bus_8                 ;
wire [31:0]                 ctrl_bus_9                 ;
wire [31:0]                 ctrl_bus_10                ;
wire [31:0]                 ctrl_bus_11                ;
wire [31:0]                 ctrl_bus_12                ;
wire [31:0]                 ctrl_bus_13                ;

wire [31:0]                 status_bus_80              ;
wire [31:0]                 status_bus_81              ;
wire [31:0]                 status_bus_82              ;
wire [31:0]                 status_bus_83              ;
wire [31:0]                 status_bus_84              ;
wire [31:0]                 status_bus_85              ;
wire [31:0]                 status_bus_86              ;
wire [31:0]                 status_bus_87              ;
wire [31:0]                 status_bus_88              ;
wire [31:0]                 status_bus_89              ;
wire [31:0]                 status_bus_8a              ;
wire [31:0]                 status_bus_8b              ;
wire [31:0]                 status_bus_8c              ;
wire [31:0]                 status_bus_8d              ;
wire [31:0]                 status_bus_8e              ;
wire [31:0]                 status_bus_8f              ;

wire [31:0]                 status_bus_90              ;
wire [31:0]                 status_bus_91              ;
wire [31:0]                 status_bus_92              ;
wire [31:0]                 status_bus_93              ;
wire [31:0]                 status_bus_94              ;
wire [31:0]                 status_bus_95              ;
wire [31:0]                 status_bus_96              ;
wire [31:0]                 status_bus_97              ;
wire [31:0]                 status_bus_98              ;
wire [31:0]                 status_bus_99              ;
wire [31:0]                 status_bus_9a              ;
wire [31:0]                 status_bus_9b              ;
wire [31:0]                 status_bus_9c              ;
wire [31:0]                 status_bus_9d              ;
wire [31:0]                 status_bus_9e              ;
wire [31:0]                 status_bus_9f              ;

wire [31:0]                 status_bus_a0              ; 
wire [31:0]                 status_bus_a1              ; 
wire [31:0]                 status_bus_a2              ;
wire [31:0]                 status_bus_a3              ; 
wire [31:0]                 status_bus_a4              ; 
wire [31:0]                 status_bus_a5              ; 
wire [31:0]                 status_bus_a6              ; 
wire [31:0]                 status_bus_a7              ; 
wire [31:0]                 status_bus_a8              ;
wire [31:0]                 status_bus_a9              ;
wire [31:0]                 status_bus_aa              ;
wire [31:0]                 status_bus_ab              ;          
wire [31:0]                 status_bus_ac              ;          
wire [31:0]                 status_bus_ad              ;          
wire [31:0]                 status_bus_ae              ;          
wire [31:0]                 status_bus_af              ;          

wire [31:0]                 status_bus_b0              ;          
wire [31:0]                 status_bus_b1              ;          
wire [31:0]                 status_bus_b2              ;          
wire [31:0]                 status_bus_b3              ;          
wire [31:0]                 status_bus_b4              ;          
wire [31:0]                 status_bus_b5              ;          
wire [31:0]                 status_bus_b6              ;          
wire [31:0]                 status_bus_b7              ;          
wire [31:0]                 status_bus_b8              ;          
wire [31:0]                 status_bus_b9              ;          
wire [31:0]                 status_bus_ba              ;          
wire [31:0]                 status_bus_bb              ;          
wire [31:0]                 status_bus_bc              ;          
wire [31:0]                 status_bus_bd              ;          
wire [31:0]                 status_bus_be              ;          
wire [31:0]                 status_bus_bf              ;

wire [31:0]                 status_bus_c0              ;          
wire [31:0]                 status_bus_c1              ;          
wire [31:0]                 status_bus_c2              ;          
wire [31:0]                 status_bus_c3              ;          
wire [31:0]                 status_bus_c4              ;          
wire [31:0]                 status_bus_c5              ;          
wire [31:0]                 status_bus_c6              ;          
wire [31:0]                 status_bus_c7              ;          
wire [31:0]                 status_bus_c8              ;          
wire [31:0]                 status_bus_c9              ;          
wire [31:0]                 status_bus_ca              ;          
wire [31:0]                 status_bus_cb              ;          
wire [31:0]                 status_bus_cc              ;          
wire [31:0]                 status_bus_cd              ;          
wire [31:0]                 status_bus_ce              ;          
wire [31:0]                 status_bus_cf              ;

wire [31:0]                 status_bus_d0              ;          
wire [31:0]                 status_bus_d1              ;          
wire [31:0]                 status_bus_d2              ;          
wire [31:0]                 status_bus_d3              ;          
wire [31:0]                 status_bus_d4              ;          
wire [31:0]                 status_bus_d5              ;          
wire [31:0]                 status_bus_d6              ;          
wire [31:0]                 status_bus_d7              ;          
wire [31:0]                 status_bus_d8              ;          
wire [31:0]                 status_bus_d9              ;          
wire [31:0]                 status_bus_da              ;          
wire [31:0]                 status_bus_db              ;          
wire [31:0]                 status_bus_dc              ;          
wire [31:0]                 status_bus_dd              ;          
wire [31:0]                 status_bus_de              ;          
wire [31:0]                 status_bus_df              ;

wire [31:0]                 status_bus_e0              ;
wire [31:0]                 status_bus_e1              ;
wire [31:0]                 status_bus_e2              ;
wire [31:0]                 status_bus_e3              ;
wire [31:0]                 status_bus_e4              ;

wire [31:0]                 status_bus_lock            ;
wire                        uart_read_req              ;
wire                        uart_read_ack              ;
wire [7:0]                  uart_read_addr             ;

wire                         free_clk_rst_n            ;
wire                         dbg_ddr_rst_n             ;
wire                         dbg_gate_start            ;
wire                         dbg_cpd_start             ;
wire                         dbg_ddrphy_rst_n          ;
wire                         dbg_gpll_scan_rst         ;
wire                         manu_clear_syn            ;
wire                         dbg_temp_rd               ;
wire                         dbg_volt_rd               ;
wire [15:0]                  adc_rdata                 ;
wire                         core_clk_rst_n            ;
wire [33:0]                  debug_calib_ctrl          ;
wire [69*MEM_DQS_WIDTH -1:0] debug_data                ;
wire [17*MEM_DQS_WIDTH -1:0] dbg_slice_status          ;
wire [22*MEM_DQS_WIDTH -1:0] dbg_slice_state           ;
wire [1:0]                   dbg_dll_upd_state         ;
wire [8:0]                   debug_gpll_dps_phase      ;
wire [69*9 -1:0]             status_debug_data         ;
wire [22*9 -1:0]             status_dbg_slice_state    ;
wire [3:0]                   test_main_state           ;
wire [2:0]                   test_wr_state             ;
wire [2:0]                   test_rd_state             ;

wire [2:0]                   dbg_rst_dps_state         ;
wire [5:0]                   dbg_tran_err_rst_cnt      ;
wire                         dbg_ddrphy_init_fail      ;

wire                         debug_cpd_offset_adj      ;
wire                         debug_cpd_offset_dir      ;
wire  [9:0]                  debug_cpd_offset          ;

wire                         force_read_clk_ctrl       ;
wire  [4*9-1:0]              init_slip_step            ;
wire  [3*9-1:0]              init_read_clk_ctrl        ;

wire                         align_error               ;
wire  [3:0]                  debug_rst_state           ;
wire  [3:0]                  debug_cpd_state           ;
wire  [9:0]                  debug_dps_cnt_dir0        ;
wire  [9:0]                  debug_dps_cnt_dir1        ;

wire  [64*9-1:0]             status_err_data_out       ;
wire  [64*9-1:0]             status_err_flag_out       ;
wire  [64*9-1:0]             status_next_err_data      ;
wire  [MEM_DQ_WIDTH*8-1:0]   err_data_out              ;
wire  [MEM_DQ_WIDTH*8-1:0]   err_flag_out              ;
wire                         manu_clear                ;

wire                         samp_position_dyn_adj     ;
wire  [8*9-1:0]              init_samp_position_even   ;
wire  [8*9-1:0]              init_samp_position_odd    ;
wire                         wrcal_position_dyn_adj    ;
wire  [8*9-1:0]              init_wrcal_position       ;

wire                         rst_gpll_lock             ;
wire                         ref_clk                   ;

wire  [1:0]                  wr_mode                   ;
wire  [1:0]                  data_mode                 ;
wire                         len_random_en             ;
wire  [3:0]                  fix_axi_len               ;
wire                         bist_stop                 ;
wire  [3:0]                  read_repeat_num           ;
wire                         data_order                ;
wire  [7:0]                  dq_inversion              ;
wire                         insert_err                ;
wire  [MEM_DQ_WIDTH*8-1:0]   exp_data_out              ;
wire                         next_err_flag             ;
wire  [15:0]                 result_bit_out            ;
wire  [MEM_DQ_WIDTH*8-1:0]   next_err_data             ;
wire  [MEM_DQ_WIDTH-1:0]     err_data_pre              ;
wire  [MEM_DQ_WIDTH-1:0]     err_data_aft              ;
wire  [71:0]                 status_err_data_pre       ;
wire  [71:0]                 status_err_data_aft       ;

wire                         gpll_lock                 ;
wire                         phy_pll_lock              ;

wire                         ck_dly_en                 ;
wire  [7:0]                  init_ck_dly_step          ;
wire  [7:0]                  ck_dly_set_bin            ;  

GTP_INBUFDS refclk_inbuf
(
    .O                          (ref_clk                      ),
    .I                          (ref_clk_p                    ),
    .IB                         (ref_clk_n                    )
);

GTP_CLKBUFG free_clk_ibufg
(
    .CLKOUT                     (free_clk_g                   ),
    .CLKIN                      (free_clk                     )
);

assign status_dbg_slice_state = {{22*REM_DQS_WIDTH{1'b0}},dbg_slice_state};
assign status_debug_data      = {{69*REM_DQS_WIDTH{1'b0}},debug_data};
assign status_err_data_out    = {{64*REM_DQS_WIDTH{1'b0}},err_data_out   };
assign status_err_flag_out    = {{64*REM_DQS_WIDTH{1'b0}},err_flag_out   };
assign status_next_err_data   = {{64*REM_DQS_WIDTH{1'b0}},next_err_data  };
assign status_err_data_pre    = {{ 8*REM_DQS_WIDTH{1'b0}},err_data_pre   };
assign status_err_data_aft    = {{ 8*REM_DQS_WIDTH{1'b0}},err_data_aft   };

//control bus 0
parameter DFT_CTRL_BUS_0 = 32'h0000_1001;
assign dbg_ddr_rst_n     = ctrl_bus_0[0];
assign dbg_gate_start    = ctrl_bus_0[4];
assign dbg_cpd_start     = ctrl_bus_0[8];
assign dbg_ddrphy_rst_n  = ctrl_bus_0[12];
assign dbg_gpll_scan_rst = ctrl_bus_0[16];

//control bus 1
parameter DFT_CTRL_BUS_1  = 32'h0000_0001;
assign len_random_en     = ctrl_bus_1[0];
assign manu_clear        = ctrl_bus_1[1];
assign data_order        = ctrl_bus_1[2];
assign fix_axi_len        = ctrl_bus_1[7:4];
assign wr_mode           = ctrl_bus_1[9:8];
assign data_mode         = ctrl_bus_1[11:10];
assign read_repeat_num   = ctrl_bus_1[15:12];
assign dbg_temp_rd       = ctrl_bus_1[20];
assign dbg_volt_rd       = ctrl_bus_1[24];

//control bus 2
parameter DFT_CTRL_BUS_2    = 32'h00_00_00_00;
assign debug_cpd_offset_adj = ctrl_bus_2[0];
assign debug_cpd_offset_dir = ctrl_bus_2[4];
assign debug_cpd_offset     = ctrl_bus_2[17:8];

//control bus 3
parameter DFT_CTRL_BUS_3        = 32'h00_00_00_00;
assign force_read_clk_ctrl      = ctrl_bus_3[0];
assign init_read_clk_ctrl       = ctrl_bus_3[27:1];
assign init_slip_step[35:32]    = ctrl_bus_3[31:28];

//control bus 4
parameter DFT_CTRL_BUS_4        = 32'h00_00_00_00;
assign init_slip_step[31:0]     = ctrl_bus_4[31:0];

//control bus 5
parameter DFT_CTRL_BUS_5          = 32'h00_00_00_00;
assign wrcal_position_dyn_adj     = ctrl_bus_5[0];
assign init_wrcal_position[71:64] = ctrl_bus_5[11:4];

//control bus 6
parameter DFT_CTRL_BUS_6          = 32'h00_00_00_00;
assign init_wrcal_position[63:32] = ctrl_bus_6[31:0];

//control bus 7
parameter DFT_CTRL_BUS_7          = 32'h00_00_00_00;
assign init_wrcal_position[31:0]  = ctrl_bus_7[31:0];

//control bus 8
parameter DFT_CTRL_BUS_8              = 32'h00_10_00_00;
assign samp_position_dyn_adj          = ctrl_bus_8[0];
assign init_samp_position_even[71:64] = ctrl_bus_8[11:4];
assign init_samp_position_odd[71:64]  = ctrl_bus_8[19:12];
assign ck_dly_en                      = ctrl_bus_8[20];
assign init_ck_dly_step               = ctrl_bus_8[31:24];

//control bus 9
parameter DFT_CTRL_BUS_9              = 32'h00_00_00_00;
assign init_samp_position_even[63:32] = ctrl_bus_9[31:0];

//control bus 10
parameter DFT_CTRL_BUS_10             = 32'h00_00_00_00;
assign init_samp_position_even[31:0]  = ctrl_bus_10[31:0];

//control bus 11
parameter DFT_CTRL_BUS_11            = 32'h00_00_00_00;
assign init_samp_position_odd[63:32] = ctrl_bus_11[31:0];

//control bus 12
parameter DFT_CTRL_BUS_12            = 32'h00_00_00_00;
assign init_samp_position_odd[31:0]  = ctrl_bus_12[31:0];

//control bus 13
parameter DFT_CTRL_BUS_13            = 32'h00_00_00_00;
assign bist_stop                     = ctrl_bus_13[0];
assign dq_inversion                  = ctrl_bus_13[15:8];
assign insert_err                    = ctrl_bus_13[16];

//status
assign status_bus_80 = {align_error,dbg_ddrphy_init_fail,dbg_tran_err_rst_cnt,1'b0,dbg_rst_dps_state,3'b0,heart_beat_led,
                        3'b0,ddr_init_done,3'b0,ddrphy_cpd_lock,2'b0,rst_gpll_lock,pll_lock,phy_pll_lock,gpll_lock,bist_run_led,err_flag};
assign status_bus_81 = {2'b0,debug_calib_ctrl[29:0]};
assign status_bus_82 = {24'b0,ck_dly_set_bin};
assign status_bus_83 = {28'b0,debug_calib_ctrl[33:30]};
assign status_bus_84 = 32'b0;
assign status_bus_85 = 32'b0;
assign status_bus_86 = 32'b0;
assign status_bus_87 = 32'b0;
assign status_bus_88 = 32'b0;
assign status_bus_89 = 32'b0;
assign status_bus_8a = {debug_rst_state,debug_cpd_state,7'b0,debug_gpll_dps_phase,8'b0};
assign status_bus_8b = {adc_rdata[15:4],1'b0,test_rd_state,1'b0,test_wr_state,test_main_state,err_cnt};
assign status_bus_8c = {6'b0,debug_dps_cnt_dir1,6'b0,debug_dps_cnt_dir0};
assign status_bus_8d = 32'b0;
assign status_bus_8e = 32'b0;
assign status_bus_8f = 32'b0;

assign status_bus_90 = status_debug_data[32*0 +: 32];
assign status_bus_91 = status_debug_data[32*1 +: 32];
assign status_bus_92 = status_debug_data[32*2 +: 32];
assign status_bus_93 = status_debug_data[32*3 +: 32];
assign status_bus_94 = status_debug_data[32*4 +: 32];
assign status_bus_95 = status_debug_data[32*5 +: 32];
assign status_bus_96 = status_debug_data[32*6 +: 32];
assign status_bus_97 = status_debug_data[32*7 +: 32];
assign status_bus_98 = status_debug_data[32*8 +: 32];
assign status_bus_99 = status_debug_data[32*9 +: 32];
assign status_bus_9a = status_debug_data[32*10 +: 32];
assign status_bus_9b = status_debug_data[32*11 +: 32];
assign status_bus_9c = status_debug_data[32*12 +: 32];
assign status_bus_9d = status_debug_data[32*13 +: 32];
assign status_bus_9e = status_debug_data[32*14 +: 32];
assign status_bus_9f = status_debug_data[32*15 +: 32];

assign status_bus_a0 = status_debug_data[32*16 +: 32];
assign status_bus_a1 = status_debug_data[32*17 +: 32];
assign status_bus_a2 = status_debug_data[32*18 +: 32];
assign status_bus_a3 = status_dbg_slice_state[32*0 +: 32];
assign status_bus_a4 = status_dbg_slice_state[32*1 +: 32];
assign status_bus_a5 = status_dbg_slice_state[32*2 +: 32];
assign status_bus_a6 = status_dbg_slice_state[32*3 +: 32];
assign status_bus_a7 = status_dbg_slice_state[32*4 +: 32];
assign status_bus_a8 = status_dbg_slice_state[32*5 +: 32];
assign status_bus_a9 = {status_debug_data[32*19 +: 13],13'b0,status_dbg_slice_state[32*6 +: 6]};
assign status_bus_aa = status_err_flag_out[32*0 +: 32];
assign status_bus_ab = status_err_flag_out[32*1 +: 32];
assign status_bus_ac = status_err_flag_out[32*2 +: 32];
assign status_bus_ad = status_err_flag_out[32*3 +: 32];
assign status_bus_ae = status_err_flag_out[32*4 +: 32];
assign status_bus_af = status_err_flag_out[32*5 +: 32];

assign status_bus_b0 = status_err_flag_out[32*6 +: 32];
assign status_bus_b1 = status_err_flag_out[32*7 +: 32];
assign status_bus_b2 = status_err_flag_out[32*8 +: 32];
assign status_bus_b3 = status_err_flag_out[32*9 +: 32];
assign status_bus_b4 = status_err_flag_out[32*10 +: 32];
assign status_bus_b5 = status_err_flag_out[32*11 +: 32];
assign status_bus_b6 = status_err_flag_out[32*12 +: 32];
assign status_bus_b7 = status_err_flag_out[32*13 +: 32];
assign status_bus_b8 = status_err_flag_out[32*14 +: 32];
assign status_bus_b9 = status_err_flag_out[32*15 +: 32];
assign status_bus_ba = status_err_flag_out[32*16 +: 32];
assign status_bus_bb = status_err_flag_out[32*17 +: 32];
assign status_bus_bc = status_err_data_out[32*0 +: 32];
assign status_bus_bd = status_err_data_out[32*1 +: 32];
assign status_bus_be = status_err_data_out[32*2 +: 32];
assign status_bus_bf = status_err_data_out[32*3 +: 32];

assign status_bus_c0 = status_err_data_out[32*4 +: 32];
assign status_bus_c1 = status_err_data_out[32*5 +: 32];
assign status_bus_c2 = status_err_data_out[32*6 +: 32];
assign status_bus_c3 = status_err_data_out[32*7 +: 32];
assign status_bus_c4 = status_err_data_out[32*8 +: 32];
assign status_bus_c5 = status_err_data_out[32*9 +: 32];
assign status_bus_c6 = status_err_data_out[32*10 +: 32];
assign status_bus_c7 = status_err_data_out[32*11 +: 32];
assign status_bus_c8 = status_err_data_out[32*12 +: 32];
assign status_bus_c9 = status_err_data_out[32*13 +: 32];
assign status_bus_ca = status_err_data_out[32*14 +: 32];
assign status_bus_cb = status_err_data_out[32*15 +: 32];
assign status_bus_cc = status_err_data_out[32*16 +: 32];
assign status_bus_cd = status_err_data_out[32*17 +: 32];
assign status_bus_ce = status_next_err_data[32*0 +: 32];
assign status_bus_cf = status_next_err_data[32*1 +: 32];

assign status_bus_d0 = status_next_err_data[32*2 +: 32];
assign status_bus_d1 = status_next_err_data[32*3 +: 32];
assign status_bus_d2 = status_next_err_data[32*4 +: 32];
assign status_bus_d3 = status_next_err_data[32*5 +: 32];
assign status_bus_d4 = status_next_err_data[32*6 +: 32];
assign status_bus_d5 = status_next_err_data[32*7 +: 32];
assign status_bus_d6 = status_next_err_data[32*8 +: 32];
assign status_bus_d7 = status_next_err_data[32*9 +: 32];
assign status_bus_d8 = status_next_err_data[32*10 +: 32];
assign status_bus_d9 = status_next_err_data[32*11 +: 32];
assign status_bus_da = status_next_err_data[32*12 +: 32];
assign status_bus_db = status_next_err_data[32*13 +: 32];
assign status_bus_dc = status_next_err_data[32*14 +: 32];
assign status_bus_dd = status_next_err_data[32*15 +: 32];
assign status_bus_de = status_next_err_data[32*16 +: 32];
assign status_bus_df = status_next_err_data[32*17 +: 32];

assign status_bus_e0 = status_err_data_pre[32*0 +: 32];
assign status_bus_e1 = status_err_data_pre[32*1 +: 32];
assign status_bus_e2 = {16'b0,status_err_data_aft[32*2 +: 8],status_err_data_pre[32*2 +: 8]};
assign status_bus_e3 = status_err_data_aft[32*0 +: 32];
assign status_bus_e4 = status_err_data_aft[32*1 +: 32];

//control signal sync

ips2l_rst_sync_v1_3 #(
    .DATA_WIDTH                 (1                            ),
    .DFT_VALUE                  (1'b0                         )
) u_manu_clear_sync(
    .clk                        (core_clk                     ),
    .rst_n                      (core_clk_rst_n               ),
    .sig_async                  (manu_clear                   ),
    .sig_synced                 (manu_clear_syn               )
);

//reset sync
ips2l_rst_sync_v1_3 #(
    .DATA_WIDTH                 (1                            ),
    .DFT_VALUE                  (1'b0                         )
) u_free_clk_rst_sync (
    .clk                        (free_clk_g                   ),
    .rst_n                      (rst_board                    ),
    .sig_async                  (1'b1                         ),
    .sig_synced                 (free_clk_rst_n               )
);

assign ctrl_bus_0 = DFT_CTRL_BUS_0;
assign ctrl_bus_1 = DFT_CTRL_BUS_1;
assign ctrl_bus_2 = DFT_CTRL_BUS_2;
assign ctrl_bus_3 = DFT_CTRL_BUS_3;
assign ctrl_bus_4 = DFT_CTRL_BUS_4;
assign ctrl_bus_5 = DFT_CTRL_BUS_5;
assign ctrl_bus_6 = DFT_CTRL_BUS_6;
assign ctrl_bus_7 = DFT_CTRL_BUS_7;
assign ctrl_bus_8 = DFT_CTRL_BUS_8;
assign ctrl_bus_9 = DFT_CTRL_BUS_9;
assign ctrl_bus_10 = DFT_CTRL_BUS_10;
assign ctrl_bus_11 = DFT_CTRL_BUS_11;
assign ctrl_bus_12 = DFT_CTRL_BUS_12;
assign ctrl_bus_13 = DFT_CTRL_BUS_13;

uart_rd_lock u_uart_rd_lock
(
    .core_clk                   (core_clk                     ),
    .core_rst_n                 (core_clk_rst_n               ),

    .uart_read_req              (uart_read_req                ),
    .uart_read_ack              (uart_read_ack                ),
    .uart_read_addr             (uart_read_addr               ),

    .status_bus_80              (status_bus_80                ),
    .status_bus_81              (status_bus_81                ),
    .status_bus_82              (status_bus_82                ),
    .status_bus_83              (status_bus_83                ),
    .status_bus_84              (status_bus_84                ),
    .status_bus_85              (status_bus_85                ),
    .status_bus_86              (status_bus_86                ),
    .status_bus_87              (status_bus_87                ),
    .status_bus_88              (status_bus_88                ),
    .status_bus_89              (status_bus_89                ),
    .status_bus_8a              (status_bus_8a                ),
    .status_bus_8b              (status_bus_8b                ),
    .status_bus_8c              (status_bus_8c                ),
    .status_bus_8d              (status_bus_8d                ),
    .status_bus_8e              (status_bus_8e                ),
    .status_bus_8f              (status_bus_8f                ),

    .status_bus_90              (status_bus_90                ),
    .status_bus_91              (status_bus_91                ),
    .status_bus_92              (status_bus_92                ),
    .status_bus_93              (status_bus_93                ),
    .status_bus_94              (status_bus_94                ),
    .status_bus_95              (status_bus_95                ),
    .status_bus_96              (status_bus_96                ),
    .status_bus_97              (status_bus_97                ),
    .status_bus_98              (status_bus_98                ),
    .status_bus_99              (status_bus_99                ),
    .status_bus_9a              (status_bus_9a                ),
    .status_bus_9b              (status_bus_9b                ),
    .status_bus_9c              (status_bus_9c                ),
    .status_bus_9d              (status_bus_9d                ),
    .status_bus_9e              (status_bus_9e                ),
    .status_bus_9f              (status_bus_9f                ),

    .status_bus_a0              (status_bus_a0                ),
    .status_bus_a1              (status_bus_a1                ),
    .status_bus_a2              (status_bus_a2                ),
    .status_bus_a3              (status_bus_a3                ),
    .status_bus_a4              (status_bus_a4                ),
    .status_bus_a5              (status_bus_a5                ),
    .status_bus_a6              (status_bus_a6                ),
    .status_bus_a7              (status_bus_a7                ),
    .status_bus_a8              (status_bus_a8                ),
    .status_bus_a9              (status_bus_a9                ),
    .status_bus_aa              (status_bus_aa                ),
    .status_bus_ab              (status_bus_ab                ),
    .status_bus_ac              (status_bus_ac                ),
    .status_bus_ad              (status_bus_ad                ),
    .status_bus_ae              (status_bus_ae                ),
    .status_bus_af              (status_bus_af                ),

    .status_bus_b0              (status_bus_b0                ),
    .status_bus_b1              (status_bus_b1                ),
    .status_bus_b2              (status_bus_b2                ),
    .status_bus_b3              (status_bus_b3                ),
    .status_bus_b4              (status_bus_b4                ),
    .status_bus_b5              (status_bus_b5                ),
    .status_bus_b6              (status_bus_b6                ),
    .status_bus_b7              (status_bus_b7                ),
    .status_bus_b8              (status_bus_b8                ),
    .status_bus_b9              (status_bus_b9                ),
    .status_bus_ba              (status_bus_ba                ),
    .status_bus_bb              (status_bus_bb                ),
    .status_bus_bc              (status_bus_bc                ),
    .status_bus_bd              (status_bus_bd                ),
    .status_bus_be              (status_bus_be                ),
    .status_bus_bf              (status_bus_bf                ),

    .status_bus_c0              (status_bus_c0                ),
    .status_bus_c1              (status_bus_c1                ),
    .status_bus_c2              (status_bus_c2                ),
    .status_bus_c3              (status_bus_c3                ),
    .status_bus_c4              (status_bus_c4                ),
    .status_bus_c5              (status_bus_c5                ),
    .status_bus_c6              (status_bus_c6                ),
    .status_bus_c7              (status_bus_c7                ),
    .status_bus_c8              (status_bus_c8                ),
    .status_bus_c9              (status_bus_c9                ),
    .status_bus_ca              (status_bus_ca                ),
    .status_bus_cb              (status_bus_cb                ),
    .status_bus_cc              (status_bus_cc                ),
    .status_bus_cd              (status_bus_cd                ),
    .status_bus_ce              (status_bus_ce                ),
    .status_bus_cf              (status_bus_cf                ),

    .status_bus_d0              (status_bus_d0                ),
    .status_bus_d1              (status_bus_d1                ),
    .status_bus_d2              (status_bus_d2                ),
    .status_bus_d3              (status_bus_d3                ),
    .status_bus_d4              (status_bus_d4                ),
    .status_bus_d5              (status_bus_d5                ),
    .status_bus_d6              (status_bus_d6                ),
    .status_bus_d7              (status_bus_d7                ),
    .status_bus_d8              (status_bus_d8                ),
    .status_bus_d9              (status_bus_d9                ),
    .status_bus_da              (status_bus_da                ),
    .status_bus_db              (status_bus_db                ),
    .status_bus_dc              (status_bus_dc                ),
    .status_bus_dd              (status_bus_dd                ),
    .status_bus_de              (status_bus_de                ),
    .status_bus_df              (status_bus_df                ),

    .status_bus_e0              (status_bus_e0                ),
    .status_bus_e1              (status_bus_e1                ),
    .status_bus_e2              (status_bus_e2                ),
    .status_bus_e3              (status_bus_e3                ),
    .status_bus_e4              (status_bus_e4                ),

    .status_bus_lock            (status_bus_lock              )
);

//***********************************************************************************

assign resetn = dbg_ddr_rst_n & rst_board & cpu_locked & (!THERMAL_DIAGNOSTIC || diag_ddr_permit);

ips2l_rst_sync_v1_3 u_core_clk_rst_sync(
    .clk                        (core_clk                     ),
    .rst_n                      (resetn                       ),
    .sig_async                  (~dbg_gate_start              ),
    .sig_synced                 (core_clk_rst_n               )
);

//***********************************************************************************

`ifdef IPS_DDR_SPEEDUP_SIM
parameter MEM_SPACE_AW = 13; //to reduce simulation time
`else
parameter MEM_SPACE_AW = CTRL_ADDR_WIDTH;
`endif

//***********************************************************************************
always@(posedge core_clk or negedge core_clk_rst_n)
begin
   if (!core_clk_rst_n)
      cnt <= 27'd0;
   else if ( cnt >= TH_1S )
      cnt <= 27'd0;
   else
      cnt <= cnt + 27'd1;
end

always @(posedge core_clk or negedge core_clk_rst_n)
begin
   if (!core_clk_rst_n)
      heart_beat_led <= 1'd1;
   else if ( cnt >= TH_1S )
      heart_beat_led <= ~heart_beat_led;
end
ddr3_test #(
    .MEM_ROW_WIDTH              (MEM_ROW_WIDTH                ),
    .MEM_COLUMN_WIDTH           (MEM_COLUMN_WIDTH             ),
    .MEM_BANK_WIDTH             (MEM_BANK_WIDTH               ),
    .MEM_DQ_WIDTH               (MEM_DQ_WIDTH                 ),
    .MEM_DM_WIDTH               (MEM_DQS_WIDTH                ),
    .MEM_DQS_WIDTH              (MEM_DQS_WIDTH                ),
    .CTRL_ADDR_WIDTH            (CTRL_ADDR_WIDTH              )
  )I_ips_ddr_top(
    .ref_clk                    (ref_clk                      ),
    .resetn                     (resetn                       ),
    .core_clk                   (core_clk                     ),
    .pll_lock                   (pll_lock                     ),
    .phy_pll_lock               (phy_pll_lock                 ),
    .gpll_lock                  (gpll_lock                    ),
    .rst_gpll_lock              (rst_gpll_lock                ),
    .ddrphy_cpd_lock            (ddrphy_cpd_lock              ),
    .ddr_init_done              (ddr_init_done                ),

    .axi_awaddr                 (axi_awaddr                   ),
    .axi_awuser_ap              (axi_awuser_ap                ),
    .axi_awuser_id              (axi_awuser_id                ),
    .axi_awlen                  (axi_awlen                    ),
    .axi_awready                (axi_awready                  ),
    .axi_awvalid                (axi_awvalid                  ),

    .axi_wdata                  (axi_wdata                    ),
    .axi_wstrb                  (axi_wstrb                    ),
    .axi_wready                 (axi_wready                   ),
    .axi_wusero_id              (axi_wusero_id                ),
    .axi_wusero_last            (axi_wusero_last              ),

    .axi_araddr                 (axi_araddr                   ),
    .axi_aruser_ap              (axi_aruser_ap                ),
    .axi_aruser_id              (axi_aruser_id                ),
    .axi_arlen                  (axi_arlen                    ),
    .axi_arready                (axi_arready                  ),
    .axi_arvalid                (axi_arvalid                  ),

    .axi_rdata                  (axi_rdata                    ),
    .axi_rid                    (axi_rid                      ),
    .axi_rlast                  (axi_rlast                    ),
    .axi_rvalid                 (axi_rvalid                   ),

    .apb_clk                    (1'b0                         ),
    .apb_rst_n                  (1'b0                         ),
    .apb_sel                    (1'b0                         ),
    .apb_enable                 (1'b0                         ),
    .apb_addr                   (8'd0                         ),
    .apb_write                  (1'b0                         ),
    .apb_ready                  (                             ),
    .apb_wdata                  (16'd0                        ),
    .apb_rdata                  (                             ),


    .mem_cs_n                   (mem_cs_n                     ),

    .mem_rst_n                  (mem_rst_n                    ),
    .mem_ck                     (mem_ck                       ),
    .mem_ck_n                   (mem_ck_n                     ),
    .mem_cke                    (mem_cke                      ),
    .mem_ras_n                  (mem_ras_n                    ),
    .mem_cas_n                  (mem_cas_n                    ),
    .mem_we_n                   (mem_we_n                     ),
    .mem_odt                    (mem_odt                      ),
    .mem_a                      (mem_a                        ),
    .mem_ba                     (mem_ba                       ),
    .mem_dqs                    (mem_dqs                      ),
    .mem_dqs_n                  (mem_dqs_n                    ),
    .mem_dq                     (mem_dq                       ),
    .mem_dm                     (mem_dm                       ),

    //debug
    .dbg_gate_start             (dbg_gate_start               ),
    .dbg_cpd_start              (dbg_cpd_start                ),
    .dbg_ddrphy_rst_n           (dbg_ddrphy_rst_n             ),
    .dbg_gpll_scan_rst          (dbg_gpll_scan_rst            ),

    .samp_position_dyn_adj      (samp_position_dyn_adj        ),
    .init_samp_position_even    (init_samp_position_even[8*MEM_DQS_WIDTH -1:0]),
    .init_samp_position_odd     (init_samp_position_odd[8*MEM_DQS_WIDTH -1:0] ),

    .wrcal_position_dyn_adj     (wrcal_position_dyn_adj       ),
    .init_wrcal_position        (init_wrcal_position[8*MEM_DQS_WIDTH -1:0]    ),

    .force_read_clk_ctrl        (force_read_clk_ctrl          ),
    .init_slip_step             (init_slip_step[4*MEM_DQS_WIDTH-1:0]          ),
    .init_read_clk_ctrl         (init_read_clk_ctrl[3*MEM_DQS_WIDTH-1:0]      ),

    .debug_calib_ctrl           (debug_calib_ctrl             ),
    .dbg_dll_upd_state          (dbg_dll_upd_state            ),
    .dbg_slice_status           (dbg_slice_status             ),
    .dbg_slice_state            (dbg_slice_state              ),
    .debug_data                 (debug_data                   ),
    .debug_gpll_dps_phase       (debug_gpll_dps_phase         ),

    .dbg_rst_dps_state          (dbg_rst_dps_state            ),
    .dbg_tran_err_rst_cnt       (dbg_tran_err_rst_cnt         ),
    .dbg_ddrphy_init_fail       (dbg_ddrphy_init_fail         ),

    .debug_cpd_offset_adj       (debug_cpd_offset_adj         ),
    .debug_cpd_offset_dir       (debug_cpd_offset_dir         ),
    .debug_cpd_offset           (debug_cpd_offset             ),
    .debug_dps_cnt_dir0         (debug_dps_cnt_dir0           ),
    .debug_dps_cnt_dir1         (debug_dps_cnt_dir1           ),

    .ck_dly_en                  (ck_dly_en                    ),
    .init_ck_dly_step           (init_ck_dly_step             ),
    .ck_dly_set_bin             (ck_dly_set_bin               ),

    .align_error                (align_error                  ),
    .debug_rst_state            (debug_rst_state              ),
    .debug_cpd_state            (debug_cpd_state              )

  );

//***********************************************************************************

wire cpu_clk,cpu_locked,cpu_resetn,base_cpu_resetn,init_fault;
wire cpu_uart_txd,thermal_uart_txd,thermal_ot,thermal_measurement_ok;
wire load_permit,load_armed,load_fault,load_alarm;
wire [3:0] load_fault_reason;
wire diag_ddr_permit,diag_cpu_permit,diag_cfg_permit,diag_pipe_permit,diag_fault;
wire [3:0] thermal_phase_gray,diag_fault_reason;
wire [31:0] diag_context_source,diag_context_dest;
wire diag_loader_wait_seen;
// Declare every parent video net before generated children consume it.
// Otherwise Verilog can create an undriven child-scope implicit wire instead
// of resolving a later parent declaration (notably the3-bit mode_sync bus).
wire        pix_locked;
wire        video_access, video_write, video_error;
wire [7:0]  video_addr;
wire [31:0] video_wdata, video_rdata;
wire [3:0]  video_wstrb;
wire        cam_done, hdmi_done;
wire [15:0] cam_id;
wire [7:0]  cfg_error;
wire [3:0]  control;
wire        snap_req, clear_toggle, pipe_reset, restart;
wire [127:0] cam_stats, pix_stats, cam_held, pix_held;
wire [31:0] display_seq;
wire        display_valid, cam_ack, pix_ack, cam_running, clear_cam_ack, clear_pix_ack;
wire [2:0]  pix_mode;
wire [23:0] rgb,ai_rgb;
wire video_hs,video_vs,video_de;
wire ai_lock_request,ai_display_locked,ai_pixel_wr_en,ai_frame_end_valid,video_frame_boundary;
wire [31:0] ai_lock_seq,ai_frame_end_seq;
wire [15:0] ai_pixel_wr_addr,ai_pixel_wr_data;
wire [10:0] video_x;wire [9:0] video_y;
wire [31:0] control_rdata,ai_rdata;wire control_error,ai_error;
reg [7:0] reset_hold;
(* async_reg="true" *) reg dv_meta,dv_sync,pl_meta,pl_sync,run_meta,run_sync;
(* async_reg="true" *) reg [2:0] mode_meta,mode_sync;
wire video_ready,mmio_access,mmio_write,mmio_error,mmio_busy;
wire [7:0] mmio_addr;wire [31:0] mmio_wdata,mmio_rdata;wire [3:0] mmio_wstrb;
wire video_auto_done,video_auto_error;
wire video_cfg_resetn=cpu_resetn && (!THERMAL_CPU_LOAD || LOAD_VIDEO_ENABLE) && (!THERMAL_DIAGNOSTIC || diag_cfg_permit);
assign uart_txd=THERMAL_DIAGNOSTIC ? thermal_uart_txd:cpu_uart_txd;
generate if(THERMAL_DIAGNOSTIC || THERMAL_CPU_LOAD)begin:g_thermal_cpu_reset
  wire release_requested=base_cpu_resetn && (THERMAL_CPU_LOAD ? load_permit:diag_cpu_permit);
  reg cpu_release_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
  reg cpu_release_sync_q /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
  always @(posedge cpu_clk or negedge release_requested)
    if(!release_requested)begin cpu_release_meta<=0;cpu_release_sync_q<=0;end
    else begin cpu_release_meta<=1;cpu_release_sync_q<=cpu_release_meta;end
  assign cpu_resetn=cpu_release_sync_q;
end else begin:g_normal_cpu_reset
  assign cpu_resetn=base_cpu_resetn;
end endgenerate
wire [7:0] cpu_gpio;
board_clock u_clock(.clk27(free_clk_g),.resetn(rst_board),.clk100(cpu_clk),.locked(cpu_locked));
r2_reset_gate u_reset_gate(.cpu_clk(cpu_clk),.system_resetn(resetn),.ddr_init_async(ddr_init_done),.cpu_resetn(base_cpu_resetn),.init_fault(init_fault));
assign axi_awuser_ap=1'b0; assign axi_aruser_ap=1'b0;
assign axi_awuser_id=4'b0; assign axi_aruser_id=4'b0;
assign bist_run_led=1'b0; assign err_flag=init_fault || (cpu_gpio[7:4]==4'he) || (THERMAL_CPU_LOAD && load_fault);
assign cpu_ready_led=(cpu_gpio==8'h11) && cpu_resetn;
// Isolate the reproduced FOUR_FUSION+loop replay instruction-corruption defect.
// Keep the ordinary fusion/dual path and the validated Cache/AXI architecture.
ai_soc #(.THERMAL_OBSERVE(THERMAL_DIAGNOSTIC),.FOUR_FUSION(0)) u_soc(.clk(cpu_clk),.resetn(cpu_resetn),.uart_rx(THERMAL_DIAGNOSTIC ? 1'b1:uart_rxd),.uart_tx(cpu_uart_txd),.gpio_out(cpu_gpio),
 .diag_loader_wait_seen(diag_loader_wait_seen),
 .dclk(core_clk),.global_resetn(core_clk_rst_n),.ddr_init_done(ddr_init_done),
 .ddr_awaddr(axi_awaddr),.ddr_araddr(axi_araddr),.ddr_awvalid(axi_awvalid),.ddr_arvalid(axi_arvalid),
 .ddr_awready(axi_awready),.ddr_arready(axi_arready),.ddr_wready(axi_wready),.ddr_wlast(axi_wusero_last),
 .ddr_rvalid(axi_rvalid),.ddr_rlast(axi_rlast),.ddr_wid(axi_wusero_id),.ddr_rid(axi_rid),.ddr_rdata(axi_rdata),
 .ddr_wdata(axi_wdata),.ddr_wstrb(axi_wstrb),.ddr_awlen(axi_awlen),.ddr_arlen(axi_arlen),
 .video_access(video_access),.video_write(video_write),.video_addr(video_addr),
 .video_wdata(video_wdata),.video_wstrb(video_wstrb),.video_rdata(video_rdata),
 .video_error(video_error),.video_ready(video_ready));


// The former unused ADC debug chain is replaced by one observable read-only ADC.
assign adc_rdata=16'b0; // The legacy, unused status bus is not a second ADC consumer.
generate if(THERMAL_CPU_LOAD)begin:g_load_thermal
thermal_load_monitor #(.CLOCK_HZ(LOAD_CLOCK_HZ),.WARMUP_CYCLES(LOAD_WARMUP_CYCLES),
 .CONVERSION_TIMEOUT_CYCLES(LOAD_CONVERSION_TIMEOUT_CYCLES),.LIMIT_SECONDS(LOAD_LIMIT_SECONDS)) u_load_monitor(
 .clk27(free_clk_g),.resetn(free_clk_rst_n),.permit(load_permit),.armed(load_armed),
 .fault(load_fault),.fault_reason(load_fault_reason),.ot_sync(thermal_ot),.alarm_sync(load_alarm));
assign thermal_uart_txd=1'b1;
assign thermal_measurement_ok=load_permit;
assign diag_ddr_permit=1'b0;assign diag_cpu_permit=1'b0;assign diag_cfg_permit=1'b0;assign diag_pipe_permit=1'b0;
assign diag_fault=1'b0;assign diag_fault_reason=4'b0;assign thermal_phase_gray=4'b0;
assign diag_context_source=32'b0;assign diag_context_dest=32'b0;
end else begin:g_legacy_thermal
assign load_permit=1'b0;assign load_armed=1'b0;assign load_fault=1'b0;
assign load_alarm=1'b0;assign load_fault_reason=4'b0;
thermal_monitor #(.BAUD(THERMAL_BAUD),.WARMUP_CYCLES(THERMAL_WARMUP_CYCLES),
 .SAMPLE_CYCLES(THERMAL_SAMPLE_CYCLES),.ACCESS_TIMEOUT(THERMAL_ACCESS_TIMEOUT)) u_thermal(
 .clk27(free_clk_g),.resetn(free_clk_rst_n),.context_data(diag_context_dest),
 .tx(thermal_uart_txd),.ot_sync(thermal_ot),.measurement_ok(thermal_measurement_ok));
thermal_stage_control #(.BASE_CYCLES(THERMAL_BASE_CYCLES),.DWELL_CYCLES(THERMAL_DWELL_CYCLES),
 .TIMEOUT_CYCLES(THERMAL_TIMEOUT_CYCLES),.CLOCK_HZ(100000000),
 .VIDEO_RUN_SECONDS(THERMAL_VIDEO_SECONDS)) u_thermal_stage(
 .clk(cpu_clk),.resetn(free_clk_rst_n && cpu_locked),.ddr_init_async(ddr_init_done),
 .base_cpu_resetn(base_cpu_resetn),.cpu_reset_actual(cpu_resetn),.loader_poll_seen(diag_loader_wait_seen),
 .cam_done(cam_done),.hdmi_done(hdmi_done),.pix_locked(pl_sync),
 .video_auto_done(video_auto_done),.cam_running(run_sync),.pix_mode(mode_sync),.display_valid(dv_sync),
 .init_fault(init_fault),.cfg_error(cfg_error),.measurement_ok_async(thermal_measurement_ok),.ot_async(thermal_ot),
 .permit_ddr(diag_ddr_permit),.permit_cpu(diag_cpu_permit),.permit_cfg(diag_cfg_permit),.permit_pipe(diag_pipe_permit),
 .phase_gray(thermal_phase_gray),.fault_reason(diag_fault_reason),.fault(diag_fault),.context_word(diag_context_source));
thermal_context_cdc u_thermal_context(.src_clk(cpu_clk),.src_resetn(free_clk_rst_n && cpu_locked),
 .src_data(diag_context_source),.dst_clk(free_clk_g),.dst_resetn(free_clk_rst_n),.dst_data(diag_context_dest));
end endgenerate

// Video subsystem (camera -> BRAM frame store -> HDMI), from the D3 package.
// Clocking, reset sequencing, MMIO and CDC handshakes are the teammate's
// validated construction; only the clock source is our buffered 27 MHz.
// ---------------------------------------------------------------------------
video_clocks u_video_clock(.clk27(free_clk_g),.resetn(rst_board),.pix_clk(pix_clk),.locked(pix_locked));

video_device_config u_config(.clk(cpu_clk),.resetn(video_cfg_resetn),.restart(restart),
 .cam_resetn(cam_resetn),.cam_scl(cam_scl),.cam_sda(cam_sda),
 .hdmi_scl(hdmi_scl),.hdmi_sda(hdmi_sda),.hdmi_resetn(hdmi_resetn),
 .cam_done(cam_done),.hdmi_done(hdmi_done),.cam_id(cam_id),.error(cfg_error));

always @(posedge cpu_clk or negedge cpu_resetn)
 if(!cpu_resetn) reset_hold <= 8'hff;
 else if(pipe_reset) reset_hold <= 8'hff;
 else if(reset_hold != 0) reset_hold <= reset_hold - 1'b1;
wire pipe_arstn = cpu_resetn && pix_locked && reset_hold == 0 && (!THERMAL_CPU_LOAD || LOAD_VIDEO_ENABLE) && (!THERMAL_DIAGNOSTIC || diag_pipe_permit);

video_pipeline #(.AI_LINK_ENABLE(1)) u_video(.cam_clk(cam_pclk),.pix_clk(pix_clk),.arstn(pipe_arstn),
 .cam_enable(control[0] && cam_done),.display_enable(control[1]),
 .test_pattern(control[2]),.freeze(control[3]),.clear_toggle(clear_toggle),
 .cam_vs(cam_vsync),.cam_href(cam_href),.cam_data(cam_data),
 .rgb(rgb),.hs(video_hs),.vs(video_vs),.de(video_de),
 .cam_stats(cam_stats),.pix_stats(pix_stats),.display_seq(display_seq),.display_valid(display_valid),
 .cam_running(cam_running),.pix_mode(pix_mode),
 .clear_ack_cam(clear_cam_ack),.clear_ack_pix(clear_pix_ack),
 .ai_lock_request(ai_lock_request),.ai_lock_seq(ai_lock_seq),.ai_display_locked(ai_display_locked),
 .ai_pixel_wr_en(ai_pixel_wr_en),.ai_pixel_wr_addr(ai_pixel_wr_addr),.ai_pixel_wr_data(ai_pixel_wr_data),
 .ai_frame_end_valid(ai_frame_end_valid),.ai_frame_end_seq(ai_frame_end_seq),
 .frame_boundary(video_frame_boundary),.scan_x(video_x),.scan_y(video_y));
assign {r_out,g_out,b_out} = ai_rgb;

video_snapshot u_cam_snapshot(.src_clk(cam_pclk),.src_resetn(pipe_arstn),
 .src_data(cam_stats),.request_toggle(snap_req),.ack_toggle(cam_ack),.held_data(cam_held));
video_snapshot u_pix_snapshot(.src_clk(pix_clk),.src_resetn(pipe_arstn),
 .src_data(pix_stats),.request_toggle(snap_req),.ack_toggle(pix_ack),.held_data(pix_held));

always @(posedge cpu_clk or negedge cpu_resetn)
 if(!cpu_resetn) begin
   dv_meta<=0;dv_sync<=0;pl_meta<=0;pl_sync<=0;run_meta<=0;run_sync<=0;mode_meta<=0;mode_sync<=0;
 end else begin
   dv_meta<=display_valid;dv_sync<=dv_meta;pl_meta<=pix_locked;pl_sync<=pl_meta;
   run_meta<=cam_running;run_sync<=run_meta;mode_meta<=pix_mode;mode_sync<=mode_meta;
 end

wire [31:0] video_live = {24'b0,(reset_hold!=0),run_sync,dv_sync,hdmi_done,cam_done,pl_sync,cpu_locked,1'b1};

// Serialize automatic startup with CPU video requests. Nonvideo requests are independent.
video_mmio_arbiter u_video_arbiter(.clk(cpu_clk),.resetn(cpu_resetn),
 .start_ready(pl_sync && cam_done && hdmi_done && reset_hold==0 && (!THERMAL_DIAGNOSTIC || diag_pipe_permit)),
 .cpu_access(video_access),.cpu_write(video_write),.cpu_addr(video_addr),
 .cpu_wdata(video_wdata),.cpu_wstrb(video_wstrb),.cpu_ready(video_ready),
 .cpu_error(video_error),.cpu_rdata(video_rdata),.mmio_busy(mmio_busy),.mmio_error(mmio_error),.mmio_rdata(mmio_rdata),
 .mmio_access(mmio_access),.mmio_write(mmio_write),.mmio_addr(mmio_addr),
 .mmio_wdata(mmio_wdata),.mmio_wstrb(mmio_wstrb),
 .auto_done(video_auto_done),.auto_error(video_auto_error));

video_mmio u_video_mmio(.clk(cpu_clk),.resetn(cpu_resetn),.access(mmio_access && mmio_addr<8'h40),.write(mmio_write),
 .addr(mmio_addr),.wdata(mmio_wdata),.wstrb(mmio_wstrb),.rdata(control_rdata),.error(control_error),.operation_busy(mmio_busy),
 .live_status(video_live),.camera_id(cam_id),.config_error(cfg_error),
 .control_applied((run_sync==(control[0] && cam_done)) && mode_sync=={control[3],control[2],control[1]}),
 .cam_ack(cam_ack),.pix_ack(pix_ack),.clear_cam_ack(clear_cam_ack),.clear_pix_ack(clear_pix_ack),
 .cam_held(cam_held),.pix_held(pix_held),
 .control(control),.snap_request(snap_req),.clear_toggle(clear_toggle),
 .pipeline_reset(pipe_reset),.config_restart(restart));

assign mmio_rdata=mmio_addr<8'h40 ? control_rdata:ai_rdata;
assign mmio_error=mmio_addr<8'h40 ? control_error:ai_error;
video_ai_control u_ai_camera(
 .clk(cpu_clk),.resetn(cpu_resetn),.access(mmio_access && mmio_addr>=8'h40),.write(mmio_write),
 .addr(mmio_addr),.wdata(mmio_wdata),.wstrb(mmio_wstrb),.rdata(ai_rdata),.error(ai_error),
 .cam_clk(cam_pclk),.pipe_resetn(pipe_arstn),.pix_clk(pix_clk),
 .pixel_wr_en(ai_pixel_wr_en),.pixel_wr_addr(ai_pixel_wr_addr),.pixel_wr_data(ai_pixel_wr_data),
 .frame_end_valid(ai_frame_end_valid),.frame_end_seq(ai_frame_end_seq),
 .frame_boundary(video_frame_boundary),.front_seq(display_seq),.front_valid(display_valid),.display_locked(ai_display_locked),
 .lock_request(ai_lock_request),.lock_seq(ai_lock_seq),
 .in_rgb(rgb),.in_hs(video_hs),.in_vs(video_vs),.in_de(video_de),.x(video_x),.y(video_y),
 .out_rgb(ai_rgb),.out_hs(hs_out),.out_vs(vs_out),.out_de(de_out));

`ifndef SYNTHESIS
initial if(THERMAL_CPU_LOAD && THERMAL_DIAGNOSTIC)
 $fatal(1,"CPU_LOAD_AND_LEGACY_DIAGNOSTIC_ARE_MUTUALLY_EXCLUSIVE");
`endif

endmodule
