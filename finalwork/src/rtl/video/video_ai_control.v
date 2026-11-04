// Extended video window: stable camera snapshot at +40..64, real-result OSD
// at +80..9c. Every bus access is a single accepted CPU-domain pulse.
module video_ai_control #(
 parameter integer PIXELS=57600,
 parameter integer CAPTURE_TIMEOUT_CYCLES=100000000
)(
 input clk,resetn,access,write,input [7:0] addr,
 input [31:0] wdata,input [3:0] wstrb,
 output reg [31:0] rdata,output reg error,
 input cam_clk,pipe_resetn,pix_clk,
 input pixel_wr_en,input [15:0] pixel_wr_addr,pixel_wr_data,
 input frame_end_valid,input [31:0] frame_end_seq,
 input frame_boundary,input [31:0] front_seq,input front_valid,display_locked,
 output lock_request,output [31:0] lock_seq,
 input [23:0] in_rgb,input in_hs,in_vs,in_de,
 input [10:0] x,input [9:0] y,
 output [23:0] out_rgb,output out_hs,out_vs,out_de
);
 wire cap_ready,cap_busy,cap_error,cap_read_valid;
 wire [15:0] cap_read_data;
 wire [31:0] cap_seq;
 reg [15:0] read_index,pixel_latch;
 reg pixel_valid;
 reg [31:0] completed;
 reg previous_ready;
 reg display_lock_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
 reg display_lock_sync_q /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
 always @(posedge clk or negedge resetn)
  if(!resetn)begin display_lock_meta<=0;display_lock_sync_q<=0;end
  else begin display_lock_meta<=display_locked;display_lock_sync_q<=display_lock_meta;end
 wire cap_selected=addr>=8'h40 && addr<=8'h64;
 wire osd_selected=addr>=8'h80 && addr<=8'h9c;
 wire command=access && write && addr==8'h44 && !error;
 wire start=command && wdata==1;
 wire release_capture=command && wdata==2;
 wire read_request=access && write && addr==8'h50 && !error;
 wire [31:0] osd_rdata;
 wire osd_error,osd_busy;
 always @* begin
  rdata=0;error=0;
  if(osd_selected)begin rdata=osd_rdata;error=osd_error;end
  else if(cap_selected)begin
   case(addr)
    8'h40:rdata=32'h43500001;
    8'h44:if(!write)error=1;
    8'h48:rdata={27'd0,display_lock_sync_q,pixel_valid,cap_error,cap_ready,cap_busy};
    8'h4c:rdata=cap_seq;
    8'h50:rdata={16'd0,read_index};
    8'h54:begin rdata={16'd0,pixel_latch};if(!write && (!pixel_valid || !cap_ready || cap_busy || cap_error))error=1;end
    8'h58:rdata=PIXELS;
    8'h5c:rdata={31'd0,cap_error};
    8'h60:rdata=completed;
    8'h64:rdata=32'd921600;
    default:error=1;
   endcase
   if(write)begin
    if(wstrb!=4'hf || (addr!=8'h44 && addr!=8'h50))error=1;
    if(addr==8'h44 && wdata!=1 && wdata!=2)error=1;
    if(addr==8'h44 && wdata==1 && (cap_busy || cap_ready || cap_error))error=1;
    if(addr==8'h50 && (!cap_ready || cap_busy || cap_error || wdata>=PIXELS))error=1;
   end
  end else error=1;
 end
 always @(posedge clk or negedge resetn)begin
  if(!resetn)begin read_index<=0;pixel_latch<=0;pixel_valid<=0;completed<=0;previous_ready<=0;end
  else begin
   previous_ready<=cap_ready;
   if(start || release_capture || !cap_ready || cap_error)pixel_valid<=0;
   if(read_request)begin read_index<=wdata[15:0];pixel_valid<=0;end
   if(cap_read_valid && cap_ready && !cap_error && !release_capture && !start)begin pixel_latch<=cap_read_data;pixel_valid<=1;end
   if(cap_ready && !previous_ready)completed<=completed+1;
  end
 end
 video_ai_capture #(.PIXELS(PIXELS),.CAPTURE_TIMEOUT_CYCLES(CAPTURE_TIMEOUT_CYCLES)) u_capture(
  .clk(clk),.resetn(resetn),.capture_start(start),.release_capture(release_capture),
  .read_index(wdata[15:0]),.read_request(read_request),.read_data(cap_read_data),.read_valid(cap_read_valid),
  .ready(cap_ready),.busy(cap_busy),.frame_seq(cap_seq),.error(cap_error),
  .cam_clk(cam_clk),.cam_resetn(pipe_resetn),.pixel_wr_en(pixel_wr_en),.pixel_wr_addr(pixel_wr_addr),.pixel_wr_data(pixel_wr_data),
  .frame_end_valid(frame_end_valid),.frame_end_seq(frame_end_seq),
  .pix_clk(pix_clk),.pix_resetn(pipe_resetn),.frame_boundary(frame_boundary),.front_seq(front_seq),.front_valid(front_valid),
  .display_locked(display_locked),.lock_request(lock_request),.lock_seq(lock_seq));
 video_ai_osd u_osd(
  .clk(clk),.resetn(resetn),.access(access && osd_selected),.write(write),.addr(addr),.wdata(wdata),.wstrb(wstrb),
  .rdata(osd_rdata),.error(osd_error),.busy(osd_busy),
  .pix_clk(pix_clk),.pix_resetn(pipe_resetn),.frame_boundary(frame_boundary),
  .in_rgb(in_rgb),.in_hs(in_hs),.in_vs(in_vs),.in_de(in_de),.x(x),.y(y),
  .out_rgb(out_rgb),.out_hs(out_hs),.out_vs(out_vs),.out_de(out_de));
endmodule
