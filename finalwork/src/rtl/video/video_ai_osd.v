`timescale 1ns/1ps
// CPU-written detection rectangles. No built-in detections or pixel classifier.
// Inclusive screen coordinates; metadata packs {class16,score16}. At most16 boxes.
// Stable-payload CDC: shadow/count cannot change from request until pixel ACK.
// A new set is applied only on a blanking frame_boundary. The boundary clock's
// registered output still uses the previous set; every following pixel uses the
// new set. All RGB/sync/DE outputs have exactly one pixel-clock register delay.
// Either domain reset flushes both sides, including pending update and boxes.
module video_ai_osd #(
    parameter integer SCREEN_W=1280, SCREEN_H=720
)(
    input wire clk,resetn,access,write,
    input wire [7:0] addr,
    input wire [31:0] wdata,
    input wire [3:0] wstrb,
    output reg [31:0] rdata,
    output reg error,
    output wire busy,
    input wire pix_clk,pix_resetn,frame_boundary,
    input wire [23:0] in_rgb,
    input wire in_hs,in_vs,in_de,
    input wire [10:0] x,
    input wire [9:0] y,
    output reg [23:0] out_rgb,
    output reg out_hs,out_vs,out_de
);
    localparam [15:0] MAX_X=SCREEN_W-1, MAX_Y=SCREEN_H-1;
    wire link_resetn=resetn && pix_resetn;
    reg cpu_release_meta=0 /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg cpu_release_sync_q=0 /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg pix_release_meta=0 /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg pix_release_sync_q=0 /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    always @(posedge clk or negedge link_resetn)
        if(!link_resetn)begin cpu_release_meta<=0;cpu_release_sync_q<=0;end
        else begin cpu_release_meta<=1;cpu_release_sync_q<=cpu_release_meta;end
    always @(posedge pix_clk or negedge link_resetn)
        if(!link_resetn)begin pix_release_meta<=0;pix_release_sync_q<=0;end
        else begin pix_release_meta<=1;pix_release_sync_q<=pix_release_meta;end
    wire cpu_live=cpu_release_sync_q, pix_live=pix_release_sync_q;
    reg [31:0] shadow_xy1[0:15],shadow_xy2[0:15],shadow_meta[0:15];
    reg [1:0] shadow_written[0:15];
    reg [3:0] index;
    reg [4:0] submitted_count;
    reg request_toggle,ack_toggle;
    reg request_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg request_sync_q /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg ack_meta /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg ack_sync_q /* synthesis syn_srlstyle="registers" syn_preserve=1 syn_allow_retiming=0 */;
    reg observed_ack;
    reg [31:0] submitted_sequence,acknowledged_sequence;
    reg [4:0] acknowledged_count;
    assign busy=!cpu_live || request_toggle!=ack_sync_q || ack_sync_q!=observed_ack;
    always @(posedge clk or negedge cpu_live)
        if(!cpu_live)begin ack_meta<=0;ack_sync_q<=0;end
        else begin ack_meta<=ack_toggle;ack_sync_q<=ack_meta;end
    always @(posedge pix_clk or negedge pix_live)
        if(!pix_live)begin request_meta<=0;request_sync_q<=0;end
        else begin request_meta<=request_toggle;request_sync_q<=request_meta;end

    function [31:0] clamp_xy;
        input [31:0] value;
        begin clamp_xy={value[31:16]>MAX_Y ? MAX_Y:value[31:16],
                        value[15:0]>MAX_X ? MAX_X:value[15:0]};end
    endfunction
    reg commit_valid;
    integer k;
    always @* begin
        commit_valid=(wdata<=16);
        for(k=0;k<16;k=k+1)begin
            if(k<wdata && (shadow_written[k]!=2'b11 ||
               shadow_xy1[k][15:0]>shadow_xy2[k][15:0] ||
               shadow_xy1[k][31:16]>shadow_xy2[k][31:16]))commit_valid=0;
        end
    end
    always @* begin
        rdata=0;error=0;
        if(access)begin
            if(addr[1:0]!=0)error=1;
            else if(write)begin
                if(wstrb!=4'hf || busy)error=1;
                else case(addr)
                    8'h84:if(wdata>15)error=1;
                    8'h88,8'h8c,8'h90:begin end
                    8'h94:if(!commit_valid)error=1;
                    default:error=1;
                endcase
            end else case(addr)
                8'h80:rdata=32'h4f530001;
                8'h84:rdata={28'b0,index};
                8'h88:rdata=shadow_xy1[index];
                8'h8c:rdata=shadow_xy2[index];
                8'h90:rdata=shadow_meta[index];
                8'h94:rdata={27'b0,submitted_count};
                8'h98:rdata={11'b0,acknowledged_count,acknowledged_sequence[7:0],7'b0,busy};
                8'h9c:rdata=acknowledged_sequence;
                default:error=1;
            endcase
        end
    end
    integer c;
    always @(posedge clk or negedge cpu_live)begin
        if(!cpu_live)begin
            index<=0;submitted_count<=0;request_toggle<=0;observed_ack<=0;
            submitted_sequence<=0;acknowledged_sequence<=0;acknowledged_count<=0;
            for(c=0;c<16;c=c+1)begin
                shadow_xy1[c]<=0;shadow_xy2[c]<=0;shadow_meta[c]<=0;shadow_written[c]<=0;
            end
        end else begin
            if(ack_sync_q!=observed_ack)begin
                observed_ack<=ack_sync_q;acknowledged_sequence<=submitted_sequence;
                acknowledged_count<=submitted_count;
            end
            if(access && write && !error)case(addr)
                8'h84:index<=wdata[3:0];
                8'h88:begin shadow_xy1[index]<=clamp_xy(wdata);shadow_written[index][0]<=1;end
                8'h8c:begin shadow_xy2[index]<=clamp_xy(wdata);shadow_written[index][1]<=1;end
                8'h90:shadow_meta[index]<=wdata;
                8'h94:begin
                    submitted_count<=wdata[4:0];submitted_sequence<=submitted_sequence+1'b1;
                    request_toggle<=!request_toggle;
                end
                default:begin end
            endcase
        end
    end

    reg [31:0] active_xy1[0:15],active_xy2[0:15],active_meta[0:15];
    reg [4:0] active_count;
    integer p;
    always @(posedge pix_clk or negedge pix_live)begin
        if(!pix_live)begin
            active_count<=0;ack_toggle<=0;
            for(p=0;p<16;p=p+1)begin active_xy1[p]<=0;active_xy2[p]<=0;active_meta[p]<=0;end
        end else if(frame_boundary && request_sync_q!=ack_toggle)begin
            // This multi-cycle stable bus is never an independently synchronized
            // bit vector. Source stays unchanged until ACK traverses two CPU FFs.
            active_count<=submitted_count;
            for(p=0;p<16;p=p+1)begin
                active_xy1[p]<=shadow_xy1[p];active_xy2[p]<=shadow_xy2[p];active_meta[p]<=shadow_meta[p];
            end
            ack_toggle<=request_sync_q;
        end
    end
    function [23:0] class_color;
        input [1:0] category;
        begin case(category)
            0:class_color=24'h00ff00;
            1:class_color=24'hff4000;
            2:class_color=24'hffff00;
            default:class_color=24'h00ffff;
        endcase end
    endfunction
    reg [23:0] overlay_rgb;
    reg found,inside_box,border;
    reg [15:0] bx1,by1,bx2,by2;
    integer b;
    always @* begin
        overlay_rgb=in_rgb;found=0;inside_box=0;border=0;
        bx1=0;by1=0;bx2=0;by2=0;
        for(b=0;b<16;b=b+1)begin
            bx1=active_xy1[b][15:0];by1=active_xy1[b][31:16];
            bx2=active_xy2[b][15:0];by2=active_xy2[b][31:16];
            inside_box=(x>=bx1 && x<=bx2 && y>=by1 && y<=by2);
            border=(x-bx1<2 || bx2-x<2 || y-by1<2 || by2-y<2);
            if(in_de && b<active_count && inside_box && border && !found)begin
                overlay_rgb=class_color(active_meta[b][17:16]);found=1;
            end
        end
    end
    always @(posedge pix_clk or negedge pix_live)begin
        if(!pix_live)begin out_rgb<=0;out_hs<=0;out_vs<=0;out_de<=0;end
        else begin out_rgb<=overlay_rgb;out_hs<=in_hs;out_vs<=in_vs;out_de<=in_de;end
    end
`ifndef SYNTHESIS
    initial if(SCREEN_W<1 || SCREEN_W>2048 || SCREEN_H<1 || SCREEN_H>1024)
        $fatal(1,"OSD_SCREEN_PARAMETER_ERROR");
`endif
endmodule
