`timescale 1ns/1ps
// One independent RGB565 snapshot RAM: camera-clock write, CPU-clock read.
// The video pipeline keeps sole ownership of its original three display banks.
// A request arriving inside a frame waits for address zero. Only a complete,
// ordered image followed by a good-frame EOF can request a display lock. Ready
// additionally requires the pixel domain to confirm that exact frame is held.
//
// CPU contract: capture_start is accepted only when !busy && !ready && !error.
// A completed/failed operation must be released before another capture. Release
// also aborts an in-flight capture; busy remains high until both domains have
// acknowledged cleanup. Read responses are synchronous one-cycle pulses. Any
// invalid CPU command/read fails closed and requires release_capture to recover.
module video_ai_capture #(
    parameter integer PIXELS=57600,
    parameter integer CAPTURE_TIMEOUT_CYCLES=100000000
)(
    input wire clk,resetn,capture_start,release_capture,
    input wire [15:0] read_index,
    input wire read_request,
    output wire [15:0] read_data,
    output reg read_valid,ready,busy,
    output reg [31:0] frame_seq,
    output reg error,
    input wire cam_clk,cam_resetn,
    input wire pixel_wr_en,
    input wire [15:0] pixel_wr_addr,pixel_wr_data,
    input wire frame_end_valid,
    input wire [31:0] frame_end_seq,
    input wire pix_clk,pix_resetn,frame_boundary,
    input wire [31:0] front_seq,
    input wire front_valid,display_locked,
    output reg lock_request,
    output reg [31:0] lock_seq
);
    // All three participants belong to one cancelable transaction. Asserting
    // any participant's reset invalidates that transaction in every domain.
    wire reset_all_n=resetn && cam_resetn && pix_resetn;
    reg cpu_reset_meta=0 /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg cpu_reset_sync=0 /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg cam_reset_meta=0 /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg cam_reset_sync=0 /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg pix_reset_meta=0 /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg pix_reset_sync=0 /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    always @(posedge clk or negedge reset_all_n)
        if(!reset_all_n)begin cpu_reset_meta<=0;cpu_reset_sync<=0;end
        else begin cpu_reset_meta<=1;cpu_reset_sync<=cpu_reset_meta;end
    always @(posedge cam_clk or negedge reset_all_n)
        if(!reset_all_n)begin cam_reset_meta<=0;cam_reset_sync<=0;end
        else begin cam_reset_meta<=1;cam_reset_sync<=cam_reset_meta;end
    always @(posedge pix_clk or negedge reset_all_n)
        if(!reset_all_n)begin pix_reset_meta<=0;pix_reset_sync<=0;end
        else begin pix_reset_meta<=1;pix_reset_sync<=pix_reset_meta;end

    reg owned,request_toggle,release_toggle,releasing;
    localparam TW=(CAPTURE_TIMEOUT_CYCLES<2)?1:$clog2(CAPTURE_TIMEOUT_CYCLES);
    reg [TW-1:0] age;

    // Request and cancellation controls, each with two preserved FFs. The
    // release handshake prevents an immediate new request from hiding a short
    // idle level or reusing a canceled toggle while stale valid is still high.
    reg cam_owned_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg cam_owned_sync /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg cam_req_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg cam_req_sync /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg cam_rel_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg cam_rel_sync /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg pix_owned_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg pix_owned_sync /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg pix_req_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg pix_req_sync /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg pix_rel_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg pix_rel_sync /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    always @(posedge cam_clk or negedge cam_reset_sync)
        if(!cam_reset_sync)begin
            cam_owned_meta<=0;cam_owned_sync<=0;cam_req_meta<=0;cam_req_sync<=0;
            cam_rel_meta<=0;cam_rel_sync<=0;
        end else begin
            cam_owned_meta<=owned;cam_owned_sync<=cam_owned_meta;
            cam_req_meta<=request_toggle;cam_req_sync<=cam_req_meta;
            cam_rel_meta<=release_toggle;cam_rel_sync<=cam_rel_meta;
        end
    always @(posedge pix_clk or negedge pix_reset_sync)
        if(!pix_reset_sync)begin
            pix_owned_meta<=0;pix_owned_sync<=0;pix_req_meta<=0;pix_req_sync<=0;
            pix_rel_meta<=0;pix_rel_sync<=0;
        end else begin
            pix_owned_meta<=owned;pix_owned_sync<=pix_owned_meta;
            pix_req_meta<=request_toggle;pix_req_sync<=pix_req_meta;
            pix_rel_meta<=release_toggle;pix_rel_sync<=pix_rel_meta;
        end

    reg cam_req_seen,cam_operation,collecting,cam_complete,cam_complete_tag,cam_release_ack;
    reg [16:0] count;
    reg [31:0] captured_seq;
    // No reset on the array: valid/ownership state masks stale RAM bytes.
    reg [15:0] pixels [0:PIXELS-1] /* synthesis syn_ramstyle="block_ram" */;
    wire pixel_in_range=pixel_wr_addr<PIXELS;
    wire pixel_order_ok=pixel_wr_addr==0 || (collecting && count<PIXELS && pixel_wr_addr==count);
    wire camera_write=cam_reset_sync && cam_owned_sync && cam_operation &&
        !cam_complete && pixel_wr_en && pixel_in_range && pixel_order_ok;
    always @(posedge cam_clk)
        if(camera_write)pixels[pixel_wr_addr]<=pixel_wr_data;

    always @(posedge cam_clk or negedge cam_reset_sync)begin
        if(!cam_reset_sync)begin
            cam_req_seen<=0;cam_operation<=0;collecting<=0;cam_complete<=0;
            cam_complete_tag<=0;cam_release_ack<=0;count<=0;captured_seq<=0;
        end else if(!cam_owned_sync)begin
            cam_req_seen<=cam_req_sync;cam_operation<=0;collecting<=0;
            cam_complete<=0;count<=0;cam_release_ack<=cam_rel_sync;
        end else if(cam_req_sync!=cam_req_seen)begin
            cam_req_seen<=cam_req_sync;cam_operation<=1;collecting<=0;
            cam_complete<=0;count<=0;
        end else if(cam_operation && !cam_complete)begin
            if(pixel_wr_en)begin
                if(!pixel_in_range)begin collecting<=0;count<=0;end
                else if(pixel_wr_addr==0)begin
                    // A new SOF, including recovery after a malformed frame.
                    collecting<=1;count<=1;
                end else if(collecting && count<PIXELS && pixel_wr_addr==count)
                    count<=count+1'b1;
                else begin collecting<=0;count<=0;end
            end
            if(frame_end_valid)begin
                if(collecting && count==PIXELS && !pixel_wr_en)begin
                    captured_seq<=frame_end_seq;cam_complete_tag<=cam_req_seen;
                    cam_complete<=1;cam_operation<=0;
                end else begin collecting<=0;count<=0;end
            end
        end
    end

    reg pix_cam_valid_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg pix_cam_valid_sync /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg pix_cam_tag_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg pix_cam_tag_sync /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg pix_req_seen,pix_operation,pix_complete,pix_complete_tag,pix_fault,pix_release_ack;
    always @(posedge pix_clk or negedge pix_reset_sync)begin
        if(!pix_reset_sync)begin
            pix_cam_valid_meta<=0;pix_cam_valid_sync<=0;
            pix_cam_tag_meta<=0;pix_cam_tag_sync<=0;
        end else begin
            pix_cam_valid_meta<=cam_complete;pix_cam_valid_sync<=pix_cam_valid_meta;
            pix_cam_tag_meta<=cam_complete_tag;pix_cam_tag_sync<=pix_cam_tag_meta;
        end
    end
    always @(posedge pix_clk or negedge pix_reset_sync)begin
        if(!pix_reset_sync)begin
            pix_req_seen<=0;pix_operation<=0;pix_complete<=0;pix_complete_tag<=0;
            pix_fault<=0;pix_release_ack<=0;lock_request<=0;lock_seq<=0;
        end else if(!pix_owned_sync)begin
            pix_req_seen<=pix_req_sync;pix_operation<=0;pix_complete<=0;
            pix_fault<=0;lock_request<=0;
            // Do not acknowledge cancellation while stale camera valid could
            // be mistaken for the following operation (including an abort).
            if(!pix_cam_valid_sync)pix_release_ack<=pix_rel_sync;
        end else if(pix_req_sync!=pix_req_seen)begin
            pix_req_seen<=pix_req_sync;pix_operation<=1;pix_complete<=0;
            pix_fault<=0;lock_request<=0;
        end else if(pix_complete)begin
            if(!front_valid || !display_locked || front_seq!=lock_seq)begin
                pix_fault<=1;pix_complete<=0;
            end
        end else if(pix_operation && !pix_fault && pix_cam_valid_sync && pix_cam_tag_sync==pix_req_seen)begin
            if(!lock_request)begin
                // Bundled payload has been stable since camera completion,
                // before that completion traversed both synchronizer stages.
                lock_request<=1;lock_seq<=captured_seq;
            end else if(frame_boundary && front_valid && display_locked && front_seq==lock_seq)begin
                pix_complete<=1;pix_complete_tag<=pix_req_seen;
            end
        end
    end

    reg cam_valid_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg cam_valid_sync /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg cam_tag_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg cam_tag_sync /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg pix_valid_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg pix_valid_sync /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg pix_tag_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg pix_tag_sync /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg pix_fault_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg pix_fault_sync /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg cam_ack_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg cam_ack_sync /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg pix_ack_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg pix_ack_sync /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    always @(posedge clk or negedge cpu_reset_sync)begin
        if(!cpu_reset_sync)begin
            cam_valid_meta<=0;cam_valid_sync<=0;cam_tag_meta<=0;cam_tag_sync<=0;
            pix_valid_meta<=0;pix_valid_sync<=0;pix_tag_meta<=0;pix_tag_sync<=0;
            pix_fault_meta<=0;pix_fault_sync<=0;cam_ack_meta<=0;cam_ack_sync<=0;
            pix_ack_meta<=0;pix_ack_sync<=0;
        end else begin
            cam_valid_meta<=cam_complete;cam_valid_sync<=cam_valid_meta;
            cam_tag_meta<=cam_complete_tag;cam_tag_sync<=cam_tag_meta;
            pix_valid_meta<=pix_complete;pix_valid_sync<=pix_valid_meta;
            pix_tag_meta<=pix_complete_tag;pix_tag_sync<=pix_tag_meta;
            pix_fault_meta<=pix_fault;pix_fault_sync<=pix_fault_meta;
            cam_ack_meta<=cam_release_ack;cam_ack_sync<=cam_ack_meta;
            pix_ack_meta<=pix_release_ack;pix_ack_sync<=pix_ack_meta;
        end
    end

    wire legal_read=cpu_reset_sync && read_request && ready && !error &&
        !release_capture && !capture_start && read_index<PIXELS;
    reg [15:0] pixel_read_data;
    always @(posedge clk)
        if(legal_read)pixel_read_data<=pixels[read_index];
    assign read_data=pixel_read_data;

    task cancel_operation;
        begin
            owned<=0;ready<=0;busy<=1;releasing<=1;age<=0;frame_seq<=0;
            release_toggle<=~release_toggle;
        end
    endtask
    always @(posedge clk or negedge cpu_reset_sync)begin
        if(!cpu_reset_sync)begin
            owned<=0;request_toggle<=0;release_toggle<=0;releasing<=0;
            read_valid<=0;ready<=0;busy<=0;frame_seq<=0;error<=0;age<=0;
        end else begin
            read_valid<=legal_read;
            if(releasing && cam_ack_sync==release_toggle && pix_ack_sync==release_toggle &&
               !cam_valid_sync && !pix_valid_sync)begin
                releasing<=0;busy<=0;
            end
            if(busy && owned && !releasing && !error)begin
                if(pix_fault_sync)begin error<=1;cancel_operation();end
                else if(cam_valid_sync && cam_tag_sync==request_toggle &&
                        pix_valid_sync && pix_tag_sync==request_toggle)begin
                    ready<=1;busy<=0;frame_seq<=captured_seq;
                end else if(age>=CAPTURE_TIMEOUT_CYCLES-1)begin error<=1;cancel_operation();end
                else age<=age+1'b1;
            end
            if(ready && pix_fault_sync)begin error<=1;read_valid<=0;cancel_operation();end
            if(read_request && !legal_read && !release_capture)begin
                error<=1;read_valid<=0;
                if(!releasing)cancel_operation();
            end
            if(capture_start && !release_capture)begin
                if(!owned && !busy && !ready && !error && !releasing && !read_request)begin
                    owned<=1;request_toggle<=~request_toggle;busy<=1;ready<=0;
                    frame_seq<=0;age<=0;
                end else begin
                    error<=1;read_valid<=0;
                    if(!releasing)cancel_operation();
                end
            end
            if(release_capture)begin
                error<=0;read_valid<=0;
                if(!releasing)cancel_operation();
            end
        end
    end
`ifndef SYNTHESIS
    initial if(PIXELS<1 || PIXELS>65536 || CAPTURE_TIMEOUT_CYCLES<16)
        $fatal(1,"AI_CAPTURE_PARAMETER_ERROR");
`endif
endmodule
