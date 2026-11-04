`timescale 1ns/1ps
// Hardware video data path, independent of CPU/DDR memory. Camera RGB565 is
// sampled on cam_clk, with pixel-valid every second byte. Exactly complete
// frames enter the ready FIFO. No bank is overwritten until display returns it.
// Controls synchronize first, then take effect at the corresponding SOF.
module video_pipeline #(
    parameter IN_W=1280, IN_H=720, SMALL_W=320, SMALL_H=180,
    parameter H_SYNC=40, H_BP=220, H_FP=110,
    parameter V_SYNC=5, V_BP=20, V_FP=5,
    parameter SWAP_BYTES=0, SWAP_RB=1, AI_LINK_ENABLE=0
)(
    input cam_clk, pix_clk, arstn,
    input cam_enable, display_enable, test_pattern, freeze, clear_toggle,
    input cam_vs, cam_href,
    input [7:0] cam_data,
    output reg [23:0] rgb,
    output reg hs, vs, de,
    output [127:0] cam_stats, pix_stats,
    output reg [31:0] display_seq,
    output display_valid,
    output reg cam_running,
    output [2:0] pix_mode,
    output clear_ack_cam, clear_ack_pix,
    input ai_lock_request,
    input [31:0] ai_lock_seq,
    output ai_display_locked,
    output ai_pixel_wr_en,
    output [15:0] ai_pixel_wr_addr, ai_pixel_wr_data,
    output ai_frame_end_valid,
    output [31:0] ai_frame_end_seq,
    output frame_boundary,
    output reg [10:0] scan_x,
    output reg [9:0] scan_y
);
    function integer clog2;
        input integer n;
        integer k;
        begin clog2=0; for(k=n-1;k>0;k=k>>1) clog2=clog2+1;
              if(clog2<1) clog2=1; end
    endfunction
    localparam PIXELS=SMALL_W*SMALL_H, AW=clog2(PIXELS);
    localparam HT=H_SYNC+H_BP+IN_W+H_FP;
    localparam VT=V_SYNC+V_BP+IN_H+V_FP;
    localparam HCW=clog2(HT), VCW=clog2(VT);
    (* ASYNC_REG="TRUE" *) reg [1:0] cam_reset_pipe, pix_reset_pipe;
    always @(posedge cam_clk or negedge arstn)
        if(!arstn) cam_reset_pipe<=0;
        else cam_reset_pipe<={cam_reset_pipe[0],1'b1};
    always @(posedge pix_clk or negedge arstn)
        if(!arstn) pix_reset_pipe<=0;
        else pix_reset_pipe<={pix_reset_pipe[0],1'b1};
    wire cam_rstn=cam_reset_pipe[1], pix_rstn=pix_reset_pipe[1];
    (* ASYNC_REG="TRUE" *) reg [1:0] cam_en_sync, cam_freeze_sync, cam_clear_sync;
    (* ASYNC_REG="TRUE" *) reg [1:0] pix_en_sync, pix_freeze_sync, pat_sync, pix_clear_sync;
    reg cam_clear_seen, pix_clear_seen;
    assign clear_ack_cam=cam_clear_seen;
    assign clear_ack_pix=pix_clear_seen;
    reg vs_s, href_s, vs_prev, href_prev;
    reg [7:0] data_s;
    always @(posedge cam_clk or negedge cam_rstn) begin
        if(!cam_rstn) begin
            cam_en_sync<=0; cam_freeze_sync<=0; cam_clear_sync<=0;
            vs_s<=0; href_s<=0; data_s<=0; vs_prev<=0; href_prev<=0;
        end else begin
            cam_en_sync<={cam_en_sync[0],cam_enable};
            cam_freeze_sync<={cam_freeze_sync[0],freeze};
            cam_clear_sync<={cam_clear_sync[0],clear_toggle};
            vs_s<=cam_vs; href_s<=cam_href; data_s<=cam_data;
            vs_prev<=vs_s; href_prev<=href_s;
        end
    end
    always @(posedge pix_clk or negedge pix_rstn) begin
        if(!pix_rstn) begin
            pix_en_sync<=0; pix_freeze_sync<=0; pat_sync<=0; pix_clear_sync<=0;
        end else begin
            pix_en_sync<={pix_en_sync[0],display_enable};
            pix_freeze_sync<={pix_freeze_sync[0],freeze};
            pat_sync<={pat_sync[0],test_pattern};
            pix_clear_sync<={pix_clear_sync[0],clear_toggle};
        end
    end
    wire cam_sof=vs_s && !vs_prev;
    wire cam_eol=!href_s && href_prev;

    reg publish_pending;
    reg [33:0] publish_data;
    wire publish_ready, ready_valid, ready_pop;
    wire [33:0] ready_data;
    wire return_push, return_ready, return_valid;
    wire [1:0] return_data;
    reg [1:0] front_bank;
    reg front_valid;
    video_async_fifo #(.WIDTH(34)) ready_fifo(
        .wr_clk(cam_clk),.wr_rstn(cam_rstn),.wr_valid(publish_pending),
        .wr_data(publish_data),.wr_ready(publish_ready),
        .rd_clk(pix_clk),.rd_rstn(pix_rstn),.rd_valid(ready_valid),
        .rd_data(ready_data),.rd_ready(ready_pop));
    video_async_fifo #(.WIDTH(2)) return_fifo(
        .wr_clk(pix_clk),.wr_rstn(pix_rstn),.wr_valid(return_push),
        .wr_data(front_bank),.wr_ready(return_ready),
        .rd_clk(cam_clk),.rd_rstn(cam_rstn),.rd_valid(return_valid),
        .rd_data(return_data),.rd_ready(1'b1));

    reg [2:0] free_mask;
    reg [2:0] published_mask;
    reg [1:0] capture_bank;
    reg in_frame, capture_active, frame_bad, half_byte;
    reg [7:0] first_byte;
    reg [31:0] source_x, line_bytes, line_count, sample_count, capture_seq;
    reg [31:0] captured_count, dropped_count, bad_count, cam_fifo_error;
    reg [2:0] next_free;
    reg [2:0] next_published;
    reg [31:0] cam_error_next;
    wire [15:0] pair_raw = SWAP_BYTES ? {data_s,first_byte} : {first_byte,data_s};
    wire [15:0] pair_rgb = SWAP_RB ? {pair_raw[4:0],pair_raw[10:5],pair_raw[15:11]} : pair_raw;
    wire ram_wr_en = cam_rstn && in_frame && capture_active && !frame_bad &&
        !vs_s && href_s && half_byte && source_x<IN_W && line_count<IN_H &&
        source_x[1:0]==0 && line_count[1:0]==0 && sample_count<PIXELS;
    wire [AW-1:0] ram_wr_addr=sample_count[AW-1:0];
    // Sensor EOF may lower the last HREF and raise VS on the SAME PCLK.
    // Include that final EOL in validation before resetting the next frame.
    wire ending_line_good = !half_byte && line_bytes==2*IN_W && source_x==IN_W;
    wire [31:0] ending_lines=line_count+(cam_eol ? 32'd1:32'd0);
    wire ending_frame_good = !frame_bad && !half_byte && !href_s &&
        ending_lines==IN_H && sample_count==PIXELS && (!cam_eol || ending_line_good);
    assign ai_pixel_wr_en=ram_wr_en;
    assign ai_pixel_wr_addr=ram_wr_addr;
    assign ai_pixel_wr_data=pair_rgb;
    assign ai_frame_end_valid=cam_sof && in_frame && capture_active && ending_frame_good && (!publish_pending || publish_ready);
    assign ai_frame_end_seq=capture_seq+32'd1;
    assign cam_stats={cam_fifo_error,bad_count,dropped_count,captured_count};
    always @(posedge cam_clk or negedge cam_rstn) begin
        if(!cam_rstn) begin
            free_mask<=3'b111; published_mask<=0; capture_bank<=0;
            in_frame<=0; capture_active<=0; frame_bad<=0; half_byte<=0; cam_running<=0;
            first_byte<=0; source_x<=0; line_bytes<=0; line_count<=0; sample_count<=0;
            capture_seq<=0; captured_count<=0; dropped_count<=0; bad_count<=0;
            cam_fifo_error<=0; publish_pending<=0; publish_data<=0; cam_clear_seen<=0;
        end else begin
            next_free=free_mask;
            next_published=published_mask;
            cam_error_next=cam_fifo_error;
            if(publish_pending && publish_ready) publish_pending<=0;
            if(return_valid) begin
                if(return_data>2 || next_free[return_data] || !next_published[return_data] ||
                   (capture_active && return_data==capture_bank))
                    cam_error_next=cam_error_next+1;
                else begin next_free[return_data]=1'b1; next_published[return_data]=1'b0; end
            end
            if(cam_sof) begin
                // Feedback means the requested enable was applied at a SOF;
                // bank pressure/freeze is separately visible in mode/counters.
                cam_running<=cam_en_sync[1];
                if(in_frame && capture_active) begin
                    if(ending_frame_good) begin
                        if(!publish_pending || publish_ready) begin
                            publish_data<={capture_seq+32'd1,capture_bank};
                            publish_pending<=1;
                            capture_seq<=capture_seq+1;
                            captured_count<=captured_count+1;
                            next_published[capture_bank]=1'b1;
                        end else begin
                            // A valid frame never disappears silently on a queue error.
                            cam_error_next=cam_error_next+1;
                            next_free[capture_bank]=1'b1;
                            dropped_count<=dropped_count+1;
                        end
                    end else begin
                        bad_count<=bad_count+1;
                        next_free[capture_bank]=1'b1;
                    end
                end
                in_frame<=1; capture_active<=0; frame_bad<=0; half_byte<=0;
                source_x<=0; line_bytes<=0; line_count<=0; sample_count<=0;
                if(cam_en_sync[1] && !cam_freeze_sync[1]) begin
                    if(next_free!=0) begin
                        capture_active<=1;
                        if(next_free[0]) begin capture_bank<=0; next_free[0]=0; end
                        else if(next_free[1]) begin capture_bank<=1; next_free[1]=0; end
                        else begin capture_bank<=2; next_free[2]=0; end
                    end else dropped_count<=dropped_count+1;
                end
            end else if(in_frame && capture_active) begin
                if(href_s && !vs_s) begin
                    line_bytes<=line_bytes+1;
                    if(line_count>=IN_H || line_bytes>=2*IN_W) frame_bad<=1;
                    if(!half_byte) begin first_byte<=data_s; half_byte<=1; end
                    else begin
                        half_byte<=0; source_x<=source_x+1;
                        if(ram_wr_en) sample_count<=sample_count+1;
                    end
                end
                if(cam_eol) begin
                    if(half_byte || line_bytes!=2*IN_W || source_x!=IN_W) frame_bad<=1;
                    half_byte<=0; line_bytes<=0; source_x<=0; line_count<=line_count+1;
                end
            end
            free_mask<=next_free;
            published_mask<=next_published;
            cam_fifo_error<=cam_error_next;
            if(cam_clear_sync[1]!=cam_clear_seen) begin
                cam_clear_seen<=cam_clear_sync[1];
                captured_count<=0; dropped_count<=0; bad_count<=0; cam_fifo_error<=0;
            end
        end
    end

    reg [HCW-1:0] h_count;
    reg [VCW-1:0] v_count;
    reg display_on, pattern_on, freeze_on;
    reg [31:0] displayed_count, repeated_count, pix_fifo_error;
    assign frame_boundary=(h_count==0 && v_count==0);
    wire active_raw = h_count>=H_SYNC+H_BP && h_count<H_SYNC+H_BP+IN_W &&
                      v_count>=V_SYNC+V_BP && v_count<V_SYNC+V_BP+IN_H;
    wire hs_raw=h_count<H_SYNC, vs_raw=v_count<V_SYNC;
    wire [31:0] active_x=h_count-(H_SYNC+H_BP);
    wire [31:0] active_y=v_count-(V_SYNC+V_BP);
    wire [31:0] read_address=(active_y>>2)*SMALL_W+(active_x>>2);
    wire ram_rd_en=active_raw && display_on && front_valid && !pattern_on;
    wire [15:0] ram_rd_data;
    wire ready_token_ok=ready_data[1:0]<3 && (!front_valid || ready_data[1:0]!=front_bank);
    assign ai_display_locked=AI_LINK_ENABLE && ai_lock_request && front_valid && display_seq==ai_lock_seq;
    assign ready_pop=pix_rstn && frame_boundary && pix_en_sync[1] && !ai_display_locked &&
        !pix_freeze_sync[1] && ready_valid && (!ready_token_ok || !front_valid || return_ready);
    assign return_push=ready_pop && ready_token_ok && front_valid;
    assign display_valid=front_valid;
    assign pix_mode={freeze_on,pattern_on,display_on};
    assign pix_stats={pix_fifo_error,repeated_count,displayed_count,display_seq};
    video_frame_ram #(.DEPTH(PIXELS),.ADDR_WIDTH(AW)) frame_ram(
        .wr_clk(cam_clk),.wr_en(ram_wr_en),.wr_bank(capture_bank),
        .wr_addr(ram_wr_addr),.wr_data(pair_rgb),
        .rd_clk(pix_clk),.rd_en(ram_rd_en),.rd_bank(front_bank),
        .rd_addr(read_address[AW-1:0]),.rd_data(ram_rd_data));

    // One synchronous RAM read + one RGB output register. The matching timing
    // tags traverse these same two clocked stages. There is no DDR de_re offset.
    reg hs_q,vs_q,de_q,has_frame_q,pattern_q;
    reg [10:0] scan_x_q;
    reg [9:0] scan_y_q;
    reg [2:0] bar_q;
    wire [2:0] bar_raw = active_x < IN_W/8 ? 0 :
        active_x < IN_W*2/8 ? 1 : active_x < IN_W*3/8 ? 2 :
        active_x < IN_W*4/8 ? 3 : active_x < IN_W*5/8 ? 4 :
        active_x < IN_W*6/8 ? 5 : active_x < IN_W*7/8 ? 6 : 7;
    reg [23:0] pattern_rgb;
    always @* begin
        case(bar_q)
            0: pattern_rgb=24'hffffff;
            1: pattern_rgb=24'hffff00;
            2: pattern_rgb=24'h00ffff;
            3: pattern_rgb=24'h00ff00;
            4: pattern_rgb=24'hff00ff;
            5: pattern_rgb=24'hff0000;
            6: pattern_rgb=24'h0000ff;
            default: pattern_rgb=24'h000000;
        endcase
    end
    always @(posedge pix_clk or negedge pix_rstn) begin
        if(!pix_rstn) begin
            h_count<=0; v_count<=0; front_bank<=0; front_valid<=0; display_seq<=0;
            display_on<=0; pattern_on<=0; freeze_on<=0; displayed_count<=0; repeated_count<=0;
            pix_fifo_error<=0; pix_clear_seen<=0;
            hs_q<=0; vs_q<=0; de_q<=0; has_frame_q<=0; pattern_q<=0; bar_q<=0;
            rgb<=0; hs<=0; vs<=0; de<=0;
            scan_x_q<=0;scan_y_q<=0;scan_x<=0;scan_y<=0;
        end else begin
            if(h_count==HT-1) begin
                h_count<=0;
                if(v_count==VT-1) v_count<=0; else v_count<=v_count+1;
            end else h_count<=h_count+1;
            if(frame_boundary) begin
                display_on<=pix_en_sync[1]; pattern_on<=pat_sync[1]; freeze_on<=pix_freeze_sync[1];
                if(ready_pop) begin
                    if(!ready_token_ok) begin
                        pix_fifo_error<=pix_fifo_error+1;
                        if(front_valid) repeated_count<=repeated_count+1;
                    end else begin
                        front_bank<=ready_data[1:0]; front_valid<=1;
                        display_seq<=ready_data[33:2]; displayed_count<=displayed_count+1;
                    end
                end else if(front_valid && pix_en_sync[1]) repeated_count<=repeated_count+1;
            end
            hs_q<=hs_raw; vs_q<=vs_raw; de_q<=active_raw && display_on;
            scan_x_q<=active_raw ? active_x[10:0]:11'd0;
            scan_y_q<=active_raw ? active_y[9:0]:10'd0;
            scan_x<=scan_x_q;scan_y<=scan_y_q;
            has_frame_q<=front_valid; pattern_q<=pattern_on;
            bar_q<=bar_raw;
            hs<=hs_q; vs<=vs_q; de<=de_q;
            if(!de_q) rgb<=0;
            else if(pattern_q) rgb<=pattern_rgb;
            else if(has_frame_q)
                rgb<={ram_rd_data[15:11],3'b0,ram_rd_data[10:5],2'b0,ram_rd_data[4:0],3'b0};
            else rgb<=0;
            if(pix_clear_sync[1]!=pix_clear_seen) begin
                pix_clear_seen<=pix_clear_sync[1];
                displayed_count<=0; repeated_count<=0; pix_fifo_error<=0;
            end
        end
    end
`ifndef SYNTHESIS
    initial begin
        if(IN_W!=4*SMALL_W || IN_H!=4*SMALL_H)
            $fatal(1,"video_pipeline requires exact 4x4 source/sample geometry");
        if(H_SYNC<1 || V_SYNC<1 || H_FP<1 || V_FP<1)
            $fatal(1,"video_pipeline requires nonzero sync and front porch");
    end
`endif
endmodule
