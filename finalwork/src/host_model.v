module ddr3_test #(
 
   parameter MEM_ROW_WIDTH       = 15          ,
    
   parameter MEM_COLUMN_WIDTH    = 10          ,
   
   parameter MEM_BANK_WIDTH      = 3           ,
  
  parameter MEM_DQ_WIDTH         =  32         ,
  
  parameter MEM_DM_WIDTH         =  4         ,
  
  parameter MEM_DQS_WIDTH        =  4         ,
   
   parameter CTRL_ADDR_WIDTH     = MEM_ROW_WIDTH + MEM_COLUMN_WIDTH + MEM_BANK_WIDTH        
  )(                                                              
   input                              ref_clk                       ,    
   input                              resetn                        ,            
   output                             core_clk                      ,            
   output                             pll_lock                      ,    
   output                             phy_pll_lock                  ,
   output                             gpll_lock                     ,        
   output                             rst_gpll_lock                 ,            
   output                             ddrphy_cpd_lock               ,      
   output                             ddr_init_done                 ,            

   input  [CTRL_ADDR_WIDTH-1:0]       axi_awaddr                    ,
   input                              axi_awuser_ap                 ,
   input  [3:0]                       axi_awuser_id                 ,
   input  [3:0]                       axi_awlen                     ,
   output                             axi_awready                   ,
   input                              axi_awvalid                   ,

   input  [8*MEM_DQ_WIDTH-1:0]        axi_wdata                     ,
   input  [MEM_DQ_WIDTH-1:0]          axi_wstrb                     ,
   output                             axi_wready                    ,
   output [3:0]                       axi_wusero_id                 ,
   output                             axi_wusero_last               ,

   input  [CTRL_ADDR_WIDTH-1:0]       axi_araddr                    ,
   input                              axi_aruser_ap                 ,
   input  [3:0]                       axi_aruser_id                 ,
   input  [3:0]                       axi_arlen                     ,
   output                             axi_arready                   ,
   input                              axi_arvalid                   ,

   output [8*MEM_DQ_WIDTH-1:0]        axi_rdata                     ,
   output [3:0]                       axi_rid                       ,
   output                             axi_rlast                     ,
   output                             axi_rvalid                    ,

   input                              apb_clk                       ,
   input                              apb_rst_n                     ,
   input                              apb_sel                       ,
   input                              apb_enable                    ,
   input  [7:0]                       apb_addr                      ,
   input                              apb_write                     ,
   output                             apb_ready                     ,
   input  [15:0]                      apb_wdata                     ,
   output [15:0]                      apb_rdata                     ,


   output                             mem_cs_n                      ,

   output                             mem_rst_n                     ,                       
   output                             mem_ck                        ,
   output                             mem_ck_n                      ,
   output                             mem_cke                       ,
   output                             mem_ras_n                     ,
   output                             mem_cas_n                     ,
   output                             mem_we_n                      , 
   output                             mem_odt                       ,
   output [MEM_ROW_WIDTH-1:0]         mem_a                         ,   
   output [MEM_BANK_WIDTH-1:0]        mem_ba                        ,   
   inout  [MEM_DQS_WIDTH-1:0]         mem_dqs                       ,
   inout  [MEM_DQS_WIDTH-1:0]         mem_dqs_n                     ,
   inout  [MEM_DQ_WIDTH-1:0]          mem_dq                        ,
   output [MEM_DM_WIDTH-1:0]          mem_dm                        , 

   //debug
   input                              dbg_gate_start                ,
   input                              dbg_cpd_start                 ,
   input                              dbg_ddrphy_rst_n              ,
   input                              dbg_gpll_scan_rst             ,

   input                              samp_position_dyn_adj         ,
   input  [8*MEM_DQS_WIDTH-1:0]       init_samp_position_even       ,
   input  [8*MEM_DQS_WIDTH-1:0]       init_samp_position_odd        ,

   input                              wrcal_position_dyn_adj        ,
   input  [8*MEM_DQS_WIDTH-1:0]       init_wrcal_position           ,
 
   input                              force_read_clk_ctrl           ,
   input  [4*MEM_DQS_WIDTH-1:0]       init_slip_step                ,  
   input  [3*MEM_DQS_WIDTH-1:0]       init_read_clk_ctrl            ,

   output [33:0]                      debug_calib_ctrl              ,
   output [17*MEM_DQS_WIDTH -1:0]     dbg_slice_status              ,
   output [22*MEM_DQS_WIDTH -1:0]     dbg_slice_state               ,
   output [69*MEM_DQS_WIDTH -1:0]     debug_data                    ,
   output [1:0]                       dbg_dll_upd_state             ,
   output [8:0]                       debug_gpll_dps_phase          ,
   
   output [2:0]                       dbg_rst_dps_state             ,
   output [5:0]                       dbg_tran_err_rst_cnt          ,
   output                             dbg_ddrphy_init_fail          , 
   
   input                              debug_cpd_offset_adj          ,
   input                              debug_cpd_offset_dir          ,
   input  [9:0]                       debug_cpd_offset              ,  
   output [9:0]                       debug_dps_cnt_dir0            , 
   output [9:0]                       debug_dps_cnt_dir1            ,

   input                              ck_dly_en                     ,
   input  [7:0]                       init_ck_dly_step              ,
   output [7:0]                       ck_dly_set_bin                ,
  
   output                             align_error                   ,
   output [3:0]                       debug_rst_state               ,
   output [3:0]                       debug_cpd_state               
);

assign core_clk=ref_clk;
reg [7:0]memory[0:8191]; reg init_r=0; integer init_count=0,state=0,delay_count=0,base=0,aw_count=0,ar_count=0,j;
reg awready=0,arready=0,wready=0,wlast=0,rvalid=0,rlast=0; reg [255:0]rdata=0;
assign ddr_init_done=init_r; assign axi_awready=awready;assign axi_arready=arready;assign axi_wready=wready;
assign axi_wusero_last=wlast;assign axi_wusero_id=0;assign axi_rvalid=rvalid;assign axi_rlast=rlast;assign axi_rid=0;assign axi_rdata=rdata;
assign pll_lock=resetn;assign phy_pll_lock=resetn;assign gpll_lock=resetn;assign rst_gpll_lock=resetn;assign ddrphy_cpd_lock=resetn;
always @(posedge ref_clk or negedge resetn)begin
 if(!resetn)begin init_count<=0;init_r<=0;state<=0;awready<=0;arready<=0;wready<=0;wlast<=0;rvalid<=0;rlast<=0;aw_count<=0;ar_count<=0;for(j=0;j<8192;j=j+1)memory[j]<=(j*13+7)%256;end
 else begin
 if(!init_r)begin init_count<=init_count+1;if(init_count==2000)init_r<=1;end
 if((axi_awvalid||axi_arvalid)&&!init_r)$fatal(1,"BEFORE_INIT");
 if((axi_awvalid&&(axi_awuser_ap!==0||axi_awuser_id!==0))||(axi_arvalid&&(axi_aruser_ap!==0||axi_aruser_id!==0)))$fatal(1,"BAD_HOST_ID_AP");
 wready<=0;wlast<=0;rvalid<=0;rlast<=0;
 case(state)
 0:begin awready<=init_r;arready<=init_r;
 if(axi_awvalid&&awready)begin if(axi_awlen!=0||axi_awaddr[2:0]!=0||axi_awaddr*4<32'h01000000||axi_awaddr*4-32'h01000000+31>=8192)$fatal(1,"BAD_AW");base<=axi_awaddr*4-32'h01000000;aw_count<=aw_count+1;awready<=0;arready<=0;delay_count<=3;state<=1;end
 else if(axi_arvalid&&arready)begin if(axi_arlen!=0||axi_araddr[2:0]!=0||axi_araddr*4<32'h01000000||axi_araddr*4-32'h01000000+31>=8192)$fatal(1,"BAD_AR");base<=axi_araddr*4-32'h01000000;ar_count<=ar_count+1;awready<=0;arready<=0;delay_count<=5;state<=3;end end
 1:if(delay_count)delay_count<=delay_count-1;else begin wready<=1;wlast<=1;state<=2;end
 2:begin for(j=0;j<32;j=j+1)if(axi_wstrb[j])memory[base+j]<=axi_wdata[j*8+:8];state<=0;end
 3:if(delay_count)delay_count<=delay_count-1;else begin for(j=0;j<32;j=j+1)rdata[j*8+:8]<=memory[base+j];rvalid<=1;rlast<=1;state<=4;end
 4:state<=0;
 endcase end end
endmodule
module GTP_INBUFDS(output O,input I,IB);assign O=I;endmodule
module GTP_CLKBUFG(output CLKOUT,input CLKIN);assign CLKOUT=CLKIN;endmodule
module ips2l_rst_sync_v1_3 #(parameter DATA_WIDTH=1,DFT_VALUE=0)(input clk,rst_n,input [DATA_WIDTH-1:0] sig_async,output reg [DATA_WIDTH-1:0] sig_synced);
always @(posedge clk or negedge rst_n) if(!rst_n)sig_synced<=DFT_VALUE;else sig_synced<=sig_async; endmodule
module adc_ctrl(input clk,rst_n,dbg_temp_rd,dbg_volt_rd,output [15:0] pdata);assign pdata=0;endmodule

