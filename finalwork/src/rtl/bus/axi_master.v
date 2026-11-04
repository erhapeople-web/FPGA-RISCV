// AXI4 single-ID master: aligned 32-bit INCR reads (1 or 4 beats), single writes.
// AW and W remain independently asserted until their own handshakes.
module axi_master(
    input wire clk,resetn,
    input wire cmd_valid,output wire cmd_ready,input wire [31:0] cmd_addr,cmd_wdata,
    input wire cmd_write,cmd_line,input wire [3:0] cmd_wstrb,
    output wire ret_valid,input wire ret_ready,output wire [31:0] ret_data,
    output wire ret_error,ret_last,
    output wire arvalid,input wire arready,output wire [31:0] araddr,output wire [7:0] arlen,
    output wire [2:0] arsize,output wire [1:0] arburst,
    input wire rvalid,output wire rready,input wire [31:0] rdata,input wire [1:0] rresp,input wire rlast,
    output wire awvalid,input wire awready,output wire [31:0] awaddr,
    output wire [7:0] awlen,output wire [2:0] awsize,output wire [1:0] awburst,
    output wire wvalid,input wire wready,output wire [31:0] wdata,output wire [3:0] wstrb,output wire wlast,
    input wire bvalid,output wire bready,input wire [1:0] bresp
);
    localparam IDLE=0,READ_ADDR=1,READ_DATA=2,WRITE_SEND=3,WRITE_RESP=4;
    reg [2:0] state;
    reg aw_done,w_done;
    reg [31:0] saved_araddr,saved_awaddr,saved_wdata;
    reg [7:0] saved_arlen;reg [3:0] saved_wstrb;
    // Only internal command VALID drives the fall-through AXI VALID. AXI
    // READY never feeds VALID; unaccepted channels retain registered payload.
    wire bypass_read=state==IDLE && cmd_valid && !cmd_write;
    wire bypass_write=state==IDLE && cmd_valid && cmd_write;
    assign araddr=state==IDLE ? cmd_addr:saved_araddr;
    assign arlen=state==IDLE ? (cmd_line ? 8'd3:8'd0):saved_arlen;
    assign awaddr=state==IDLE ? cmd_addr:saved_awaddr;
    assign wdata=state==IDLE ? cmd_wdata:saved_wdata;
    assign wstrb=state==IDLE ? cmd_wstrb:saved_wstrb;
    assign cmd_ready=resetn && state==IDLE;
    assign arvalid=resetn && (state==READ_ADDR || bypass_read);
    assign arsize=2;assign arburst=1;
    assign awvalid=resetn && ((state==WRITE_SEND && !aw_done) || bypass_write);
    assign wvalid=resetn && ((state==WRITE_SEND && !w_done) || bypass_write);
    assign awsize=2;assign awlen=0;assign awburst=1;assign wlast=1;
    assign ret_valid=resetn && ((state==READ_DATA && rvalid) || (state==WRITE_RESP && bvalid));
    assign ret_data=state==READ_DATA ? rdata:0;
    assign ret_error=state==READ_DATA ? |rresp:|bresp;
    assign ret_last=state==READ_DATA ? rlast:1;
    assign rready=resetn && state==READ_DATA && ret_ready;
    assign bready=resetn && state==WRITE_RESP && ret_ready;
    always @(posedge clk)begin
        if(!resetn)begin state<=IDLE;aw_done<=0;w_done<=0;saved_araddr<=0;saved_arlen<=0;saved_awaddr<=0;saved_wdata<=0;saved_wstrb<=0;end
        else case(state)
            IDLE:if(cmd_valid)begin
                saved_araddr<=cmd_addr;saved_arlen<=cmd_line ? 3:0;saved_awaddr<=cmd_addr;saved_wdata<=cmd_wdata;saved_wstrb<=cmd_wstrb;
                if(cmd_write)begin
                    aw_done<=awready;w_done<=wready;
                    state<=awready && wready ? WRITE_RESP:WRITE_SEND;
                end else begin
                    aw_done<=0;w_done<=0;state<=arready ? READ_DATA:READ_ADDR;
                end
            end
            READ_ADDR:if(arready)state<=READ_DATA;
            READ_DATA:if(rvalid && rready && rlast)state<=IDLE;
            WRITE_SEND:begin
                if(awready)aw_done<=1;if(wready)w_done<=1;
                if((aw_done || awready) && (w_done || wready))state<=WRITE_RESP;
            end
            WRITE_RESP:if(bvalid && bready)state<=IDLE;
            default:state<=IDLE;
        endcase
    end
endmodule
