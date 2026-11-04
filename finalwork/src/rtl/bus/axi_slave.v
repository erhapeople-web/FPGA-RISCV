// Single-ID AXI4 target with independently buffered AW and W channels.
// The local target registers its response. Forward it without another cycle,
// capturing one beat if AXI is stalled. Invalid bursts still return SLVERR.
module axi_slave(
    input wire clk,resetn,
    input wire arvalid,output wire arready,input wire [31:0] araddr,input wire [7:0] arlen,
    input wire [2:0] arsize,input wire [1:0] arburst,
    output wire rvalid,input wire rready,output wire [31:0] rdata,output wire [1:0] rresp,output wire rlast,
    input wire awvalid,output wire awready,input wire [31:0] awaddr,
    input wire [7:0] awlen,input wire [2:0] awsize,input wire [1:0] awburst,
    input wire wvalid,output wire wready,input wire [31:0] wdata,input wire [3:0] wstrb,input wire wlast,
    output wire bvalid,input wire bready,output wire [1:0] bresp,
    output wire mem_valid,input wire mem_ready,output wire mem_write,
    output wire [31:0] mem_addr,mem_wdata,output wire [3:0] mem_wstrb,
    input wire mem_rvalid,output wire mem_rready,input wire [31:0] mem_rdata,input wire mem_error
);
    reg read_active,read_wait,read_bad,write_wait,have_aw,have_w,write_bad,write_last;
    reg [31:0] read_addr,write_addr,write_data;
    reg [3:0] write_strobe;
    reg [7:0] remaining;
    reg r_hold_valid,b_hold_valid,r_hold_last;
    reg [31:0] r_hold_data;
    reg [1:0] r_hold_resp,b_hold_resp;
    wire read_bypass=read_wait && mem_rvalid;
    wire write_bypass=write_wait && mem_rvalid;
    // VALID and payload do not depend on AXI READY. The local response is
    // consumed once, then held here if the AXI receiver did not accept it.
    assign rvalid=resetn && (r_hold_valid || read_bypass);
    assign rdata=r_hold_valid ? r_hold_data:mem_rdata;
    assign rresp=r_hold_valid ? r_hold_resp:(mem_error ? 2'b10:2'b00);
    assign rlast=r_hold_valid ? r_hold_last:remaining==0;
    assign bvalid=resetn && (b_hold_valid || write_bypass);
    assign bresp=b_hold_valid ? b_hold_resp:(mem_error ? 2'b10:2'b00);
    wire take_aw=awvalid && awready,take_w=wvalid && wready;
    wire take_ar=arvalid && arready;
    wire [31:0] selected_aw=have_aw ? write_addr:awaddr;
    wire [31:0] selected_data=have_w ? write_data:wdata;
    wire [3:0] selected_strobe=have_w ? write_strobe:wstrb;
    wire selected_bad=have_aw ? write_bad:(awlen!=0 || awsize!=2 || awburst!=1 || |awaddr[1:0]);
    wire selected_last=have_w ? write_last:wlast;
    // Join independently accepted AW/W directly into the local request.
    // A concurrent AR keeps read-first ordering. If the local target stalls,
    // the normal AW/W registers retain every field on the acceptance edge.
    wire choose_write=(have_aw || take_aw) && (have_w || take_w) &&
        !read_active && !write_wait && !bvalid && !take_ar;
    assign arready=resetn && !read_active && !write_wait && !have_aw && !have_w && !bvalid;
    assign awready=resetn && !have_aw && !write_wait && !bvalid;
    assign wready=resetn && !have_w && !write_wait && !bvalid;
    // A retiring R beat frees the registered local response slot. Start the
    // next burst beat in that cycle; if local READY is low, read_addr advances
    // to this same payload and the request stays asserted on the next cycle.
    wire advance_read=rvalid && rready && remaining!=0;
    wire issue_read=read_active && !read_bad && ((!read_wait && !rvalid) || advance_read);
    wire [31:0] selected_read_addr=advance_read ? read_addr+4:read_addr;
    assign mem_valid=resetn && ((issue_read) || (choose_write && !selected_bad && selected_last));
    assign mem_write=choose_write;
    assign mem_addr=choose_write ? selected_aw:selected_read_addr;
    assign mem_wdata=selected_data;assign mem_wstrb=selected_strobe;
    assign mem_rready=resetn && (read_wait || write_wait);
    always @(posedge clk)begin
        if(!resetn)begin
            read_active<=0;read_wait<=0;write_wait<=0;have_aw<=0;have_w<=0;
            r_hold_valid<=0;b_hold_valid<=0;r_hold_data<=0;r_hold_resp<=0;r_hold_last<=0;b_hold_resp<=0;
            read_addr<=0;write_addr<=0;
            remaining<=0;read_bad<=0;write_bad<=0;write_last<=0;write_data<=0;write_strobe<=0;
        end else begin
            if(arvalid && arready)begin
                read_active<=1;read_addr<=araddr;remaining<=arlen;
                read_bad<=arsize!=2 || arburst!=1 || |araddr[1:0] ||
                          ({1'b0,araddr[11:0]}+({5'b0,arlen}+13'd1)*13'd4)>13'd4096;
            end
            if(awvalid && awready)begin
                have_aw<=1;write_addr<=awaddr;write_bad<=awlen!=0 || awsize!=2 || awburst!=1 || |awaddr[1:0];
            end
            if(wvalid && wready)begin have_w<=1;write_data<=wdata;write_strobe<=wstrb;write_last<=wlast;end
            if(mem_valid && mem_ready)begin
                if(choose_write)begin write_wait<=1;have_aw<=0;have_w<=0;end
                else read_wait<=1;
            end
            if(choose_write && (selected_bad || !selected_last))begin
                have_aw<=0;have_w<=0;b_hold_valid<=1;b_hold_resp<=2;
            end
            if(read_active && read_bad && !rvalid)begin
                r_hold_valid<=1;r_hold_data<=0;r_hold_resp<=2;r_hold_last<=remaining==0;
            end
            if(mem_rvalid && mem_rready)begin
                if(write_wait)begin
                    write_wait<=0;b_hold_valid<=!bready;b_hold_resp<=mem_error ? 2:0;
                end else begin
                    read_wait<=0;r_hold_valid<=!rready;r_hold_data<=mem_rdata;
                    r_hold_resp<=mem_error ? 2:0;r_hold_last<=remaining==0;
                end
            end
            if(rvalid && rready)begin
                r_hold_valid<=0;
                if(remaining==0)read_active<=0;
                else begin remaining<=remaining-1'b1;read_addr<=read_addr+4;end
            end
            if(bvalid && bready)b_hold_valid<=0;
            // This assignment wins over consumption of the preceding local
            // response when a new read request is accepted on the same edge.
            if(mem_valid && mem_ready && !choose_write)read_wait<=1;
        end
    end
endmodule
