// Bundled-data snapshot: destination holds its sample until the next request.
// The request cannot be reissued until both source-domain acknowledgements arrive.
module video_snapshot #(parameter WIDTH=128)(
 input wire src_clk,src_resetn,input wire [WIDTH-1:0] src_data,
 input wire request_toggle,output reg ack_toggle,
 output reg [WIDTH-1:0] held_data);
 (* async_reg="true" *) reg req_meta,req_sync;
 (* async_reg="true" *) reg [2:0] reset_pipe;
 always @(posedge src_clk or negedge src_resetn)
  if(!src_resetn)reset_pipe<=0;else reset_pipe<={reset_pipe[1:0],1'b1};
 wire local_resetn=reset_pipe[2];
 always @(posedge src_clk or negedge local_resetn) begin
  if(!local_resetn)begin req_meta<=0;req_sync<=0;ack_toggle<=0;held_data<=0;end
  else begin
   req_meta<=request_toggle;req_sync<=req_meta;
   if(req_sync!=ack_toggle)begin held_data<=src_data;ack_toggle<=req_sync;end
  end
 end
endmodule
