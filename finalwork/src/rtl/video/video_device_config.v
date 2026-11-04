`timescale 1ns/1ps
// Configuration sequencers run entirely on the C1 100 MHz clock.
// Tables follow the supplied demo, with explicit/read-back DVP polarity below.
// OV5640 DVP Application Guide 4.2 (PDF p27): 4740[5]=1 launches data
// on the falling PCLK edge; the FPGA captures on the rising edge.
// No retry after NACK/timeout. restart resets BOTH devices and bus engines.
module video_device_config #(
    parameter CLOCK_HZ=100000000,
    parameter I2C_HZ=100000,
    parameter POWERUP_CYCLES=1000000
)(
    input wire clk,resetn,restart,
    output reg cam_resetn,
    output wire cam_scl,inout wire cam_sda,
    output wire hdmi_scl,inout wire hdmi_sda,
    output reg hdmi_resetn,
    output reg cam_done,hdmi_done,
    output reg [15:0] cam_id,
    output wire [7:0] error
);
    localparam POWER_DELAY=(POWERUP_CYCLES<1) ? 1:POWERUP_CYCLES;
    // Reference WAIT was 0x30d39a clocks at 10 MHz, i.e. about 320 ms.
    localparam HDMI_SETTLE_RAW=(CLOCK_HZ/100)*32;
    localparam HDMI_SETTLE=(HDMI_SETTLE_RAW<1) ? 1:HDMI_SETTLE_RAW;
    localparam C_POWER=0,C_SETTLE=1,C_ID_H=2,C_ID_H_WAIT=3,
        C_ID_L=4,C_ID_L_WAIT=5,C_WRITE=6,C_WRITE_WAIT=7,
        C_RESET_WAIT=8,C_VERIFY=9,C_VERIFY_WAIT=10,C_DONE=11,C_FAIL=12;
    localparam H_POWER=0,H_SETTLE=1,H_PROBE_W=2,H_PROBE_W_WAIT=3,
        H_PROBE_R=4,H_PROBE_R_WAIT=5,H_WRITE=6,H_WRITE_WAIT=7,
        H_WAIT=8,H_DONE=9,H_FAIL=10;
    localparam CAMERA_WRITES=258,HDMI_WRITES=49,CAMERA_CHECKS=11;
    reg [3:0] cs,hs;
    reg [31:0] cam_delay,hdmi_delay;
    reg [8:0] ci;
    reg [5:0] hi;
    reg [3:0] verify_index;
    reg [3:0] cam_error,hdmi_error;
    reg cam_start,cam_read,hdmi_start,hdmi_read;
    reg [15:0] cam_addr,hdmi_addr;
    reg [7:0] cam_data,hdmi_data;
    wire cam_busy,cam_xdone,cam_nack,cam_timeout;
    wire hdmi_busy,hdmi_xdone,hdmi_nack,hdmi_timeout;
    wire [7:0] cam_rdata,hdmi_rdata;
    wire bus_resetn=resetn && !restart;
    assign error={hdmi_error,cam_error};

    video_i2c_master #(.CLOCK_HZ(CLOCK_HZ),.I2C_HZ(I2C_HZ)) u_camera_bus(
        .clk(clk),.resetn(bus_resetn),.start(cam_start),.read(cam_read),
        .lsb_first(1'b0),.device_addr(7'h3c),.reg_addr(cam_addr),.write_data(cam_data),
        .busy(cam_busy),.done(cam_xdone),.nack(cam_nack),.timeout(cam_timeout),
        .read_data(cam_rdata),.scl(cam_scl),.sda(cam_sda));
    video_i2c_master #(.CLOCK_HZ(CLOCK_HZ),.I2C_HZ(I2C_HZ)) u_hdmi_bus(
        .clk(clk),.resetn(bus_resetn),.start(hdmi_start),.read(hdmi_read),
        .lsb_first(1'b1),.device_addr(7'h59),.reg_addr(hdmi_addr),.write_data(hdmi_data),
        .busy(hdmi_busy),.done(hdmi_xdone),.nack(hdmi_nack),.timeout(hdmi_timeout),
        .read_data(hdmi_rdata),.scl(hdmi_scl),.sda(hdmi_sda));

    function [23:0] camera_table;
        input [8:0] index;
        begin case(index)
            0:camera_table=24'h310311;
            1:camera_table=24'h300882;
            2:camera_table=24'h300842;
            3:camera_table=24'h310303;
            4:camera_table=24'h3017ff;
            5:camera_table=24'h3018ff;
            6:camera_table=24'h30341a;
            7:camera_table=24'h303713;
            8:camera_table=24'h310801;
            9:camera_table=24'h363036;
            10:camera_table=24'h36310e;
            11:camera_table=24'h3632e2;
            12:camera_table=24'h363312;
            13:camera_table=24'h3621e0;
            14:camera_table=24'h3704a0;
            15:camera_table=24'h37035a;
            16:camera_table=24'h371578;
            17:camera_table=24'h371701;
            18:camera_table=24'h370b60;
            19:camera_table=24'h37051a;
            20:camera_table=24'h390502;
            21:camera_table=24'h390610;
            22:camera_table=24'h39010a;
            23:camera_table=24'h373112;
            24:camera_table=24'h360008;
            25:camera_table=24'h360133;
            26:camera_table=24'h302d60;
            27:camera_table=24'h362052;
            28:camera_table=24'h371b20;
            29:camera_table=24'h471c50;
            30:camera_table=24'h3a1343;
            31:camera_table=24'h3a1800;
            32:camera_table=24'h3a19f8;
            33:camera_table=24'h363513;
            34:camera_table=24'h363603;
            35:camera_table=24'h363440;
            36:camera_table=24'h362201;
            37:camera_table=24'h3c0134;
            38:camera_table=24'h3c0428;
            39:camera_table=24'h3c0598;
            40:camera_table=24'h3c0600;
            41:camera_table=24'h3c0708;
            42:camera_table=24'h3c0800;
            43:camera_table=24'h3c091c;
            44:camera_table=24'h3c0a9c;
            45:camera_table=24'h3c0b40;
            46:camera_table=24'h381000;
            47:camera_table=24'h381110;
            48:camera_table=24'h381200;
            49:camera_table=24'h370864;
            50:camera_table=24'h400102;
            51:camera_table=24'h40051a;
            52:camera_table=24'h300000;
            53:camera_table=24'h3004ff;
            54:camera_table=24'h300e58;
            55:camera_table=24'h302e00;
            56:camera_table=24'h430060;
            57:camera_table=24'h501f01;
            58:camera_table=24'h440e00;
            59:camera_table=24'h5000a7;
            60:camera_table=24'h3a0f30;
            61:camera_table=24'h3a1028;
            62:camera_table=24'h3a1b30;
            63:camera_table=24'h3a1e26;
            64:camera_table=24'h3a1160;
            65:camera_table=24'h3a1f14;
            66:camera_table=24'h580023;
            67:camera_table=24'h580114;
            68:camera_table=24'h58020f;
            69:camera_table=24'h58030f;
            70:camera_table=24'h580412;
            71:camera_table=24'h580526;
            72:camera_table=24'h58060c;
            73:camera_table=24'h580708;
            74:camera_table=24'h580805;
            75:camera_table=24'h580905;
            76:camera_table=24'h580a08;
            77:camera_table=24'h580b0d;
            78:camera_table=24'h580c08;
            79:camera_table=24'h580d03;
            80:camera_table=24'h580e00;
            81:camera_table=24'h580f00;
            82:camera_table=24'h581003;
            83:camera_table=24'h581109;
            84:camera_table=24'h581207;
            85:camera_table=24'h581303;
            86:camera_table=24'h581400;
            87:camera_table=24'h581501;
            88:camera_table=24'h581603;
            89:camera_table=24'h581708;
            90:camera_table=24'h58180d;
            91:camera_table=24'h581908;
            92:camera_table=24'h581a05;
            93:camera_table=24'h581b06;
            94:camera_table=24'h581c08;
            95:camera_table=24'h581d0e;
            96:camera_table=24'h581e29;
            97:camera_table=24'h581f17;
            98:camera_table=24'h582011;
            99:camera_table=24'h582111;
            100:camera_table=24'h582215;
            101:camera_table=24'h582328;
            102:camera_table=24'h582446;
            103:camera_table=24'h582526;
            104:camera_table=24'h582608;
            105:camera_table=24'h582726;
            106:camera_table=24'h582864;
            107:camera_table=24'h582926;
            108:camera_table=24'h582a24;
            109:camera_table=24'h582b22;
            110:camera_table=24'h582c24;
            111:camera_table=24'h582d24;
            112:camera_table=24'h582e06;
            113:camera_table=24'h582f22;
            114:camera_table=24'h583040;
            115:camera_table=24'h583142;
            116:camera_table=24'h583224;
            117:camera_table=24'h583326;
            118:camera_table=24'h583424;
            119:camera_table=24'h583522;
            120:camera_table=24'h583622;
            121:camera_table=24'h583726;
            122:camera_table=24'h583844;
            123:camera_table=24'h583924;
            124:camera_table=24'h583a26;
            125:camera_table=24'h583b28;
            126:camera_table=24'h583c42;
            127:camera_table=24'h583dce;
            128:camera_table=24'h5180ff;
            129:camera_table=24'h5181f2;
            130:camera_table=24'h518200;
            131:camera_table=24'h518314;
            132:camera_table=24'h518425;
            133:camera_table=24'h518524;
            134:camera_table=24'h518609;
            135:camera_table=24'h518709;
            136:camera_table=24'h518809;
            137:camera_table=24'h518975;
            138:camera_table=24'h518a54;
            139:camera_table=24'h518be0;
            140:camera_table=24'h518cb2;
            141:camera_table=24'h518d42;
            142:camera_table=24'h518e3d;
            143:camera_table=24'h518f56;
            144:camera_table=24'h519046;
            145:camera_table=24'h5191f8;
            146:camera_table=24'h519204;
            147:camera_table=24'h519370;
            148:camera_table=24'h5194f0;
            149:camera_table=24'h5195f0;
            150:camera_table=24'h519603;
            151:camera_table=24'h519701;
            152:camera_table=24'h519804;
            153:camera_table=24'h519912;
            154:camera_table=24'h519a04;
            155:camera_table=24'h519b00;
            156:camera_table=24'h519c06;
            157:camera_table=24'h519d82;
            158:camera_table=24'h519e38;
            159:camera_table=24'h548001;
            160:camera_table=24'h548108;
            161:camera_table=24'h548214;
            162:camera_table=24'h548328;
            163:camera_table=24'h548451;
            164:camera_table=24'h548565;
            165:camera_table=24'h548671;
            166:camera_table=24'h54877d;
            167:camera_table=24'h548887;
            168:camera_table=24'h548991;
            169:camera_table=24'h548a9a;
            170:camera_table=24'h548baa;
            171:camera_table=24'h548cb8;
            172:camera_table=24'h548dcd;
            173:camera_table=24'h548edd;
            174:camera_table=24'h548fea;
            175:camera_table=24'h54901d;
            176:camera_table=24'h53811e;
            177:camera_table=24'h53825b;
            178:camera_table=24'h538308;
            179:camera_table=24'h53840a;
            180:camera_table=24'h53857e;
            181:camera_table=24'h538688;
            182:camera_table=24'h53877c;
            183:camera_table=24'h53886c;
            184:camera_table=24'h538910;
            185:camera_table=24'h538a01;
            186:camera_table=24'h538b98;
            187:camera_table=24'h558006;
            188:camera_table=24'h558340;
            189:camera_table=24'h558410;
            190:camera_table=24'h558910;
            191:camera_table=24'h558a00;
            192:camera_table=24'h558bf8;
            193:camera_table=24'h501d40;
            194:camera_table=24'h530008;
            195:camera_table=24'h530130;
            196:camera_table=24'h530210;
            197:camera_table=24'h530300;
            198:camera_table=24'h530408;
            199:camera_table=24'h530530;
            200:camera_table=24'h530608;
            201:camera_table=24'h530716;
            202:camera_table=24'h530908;
            203:camera_table=24'h530a30;
            204:camera_table=24'h530b04;
            205:camera_table=24'h530c06;
            206:camera_table=24'h502500;
            207:camera_table=24'h300802;
            208:camera_table=24'h303521;
            209:camera_table=24'h303669;
            210:camera_table=24'h3c0708;
            211:camera_table=24'h382047;
            212:camera_table=24'h382100;
            213:camera_table=24'h381431;
            214:camera_table=24'h381531;
            215:camera_table=24'h380000;
            216:camera_table=24'h380100;
            217:camera_table=24'h380200;
            218:camera_table=24'h3803fa;
            219:camera_table=24'h38040a;
            220:camera_table=24'h38053f;
            221:camera_table=24'h380606;
            222:camera_table=24'h3807a9;
            223:camera_table=24'h380805;
            224:camera_table=24'h380900;
            225:camera_table=24'h380a02;
            226:camera_table=24'h380bd0;
            227:camera_table=24'h380c07;
            228:camera_table=24'h380d64;
            229:camera_table=24'h380e02;
            230:camera_table=24'h380fe4;
            231:camera_table=24'h381304;
            232:camera_table=24'h361800;
            233:camera_table=24'h361229;
            234:camera_table=24'h370952;
            235:camera_table=24'h370c03;
            236:camera_table=24'h3a0202;
            237:camera_table=24'h3a03e0;
            238:camera_table=24'h3a0800;
            239:camera_table=24'h3a096f;
            240:camera_table=24'h3a0a00;
            241:camera_table=24'h3a0b5c;
            242:camera_table=24'h3a0e06;
            243:camera_table=24'h3a0d08;
            244:camera_table=24'h3a1402;
            245:camera_table=24'h3a15e0;
            246:camera_table=24'h400402;
            247:camera_table=24'h30021c;
            248:camera_table=24'h3006c3;
            249:camera_table=24'h471303;
            250:camera_table=24'h440704;
            251:camera_table=24'h460b37;
            252:camera_table=24'h460c20;
            253:camera_table=24'h483716;
            254:camera_table=24'h382404;
            255:camera_table=24'h500183;
            256:camera_table=24'h350300;
            257:camera_table=24'h474020; // Falling-edge DVP data launch; ungated PCLK
            default:camera_table=0;
        endcase end
    endfunction
    function [23:0] hdmi_table;
        input [5:0] index;
        begin case(index)
            0:hdmi_table=24'h128104;
            1:hdmi_table=24'h001604;
            2:hdmi_table=24'h000901;
            3:hdmi_table=24'h000709;
            4:hdmi_table=24'h0008f0;
            5:hdmi_table=24'h000af0;
            6:hdmi_table=24'h000611;
            7:hdmi_table=24'h053184;
            8:hdmi_table=24'h090020;
            9:hdmi_table=24'h090147;
            10:hdmi_table=24'h090409;
            11:hdmi_table=24'h092307;
            12:hdmi_table=24'h092444;
            13:hdmi_table=24'h092544;
            14:hdmi_table=24'h090f80;
            15:hdmi_table=24'h091f07;
            16:hdmi_table=24'h09201e;
            17:hdmi_table=24'h001820;
            18:hdmi_table=24'h05c0fe;
            19:hdmi_table=24'h000b00;
            20:hdmi_table=24'h050706;
            21:hdmi_table=24'h090604;
            22:hdmi_table=24'h09205e;
            23:hdmi_table=24'h0926dd;
            24:hdmi_table=24'h09270d;
            25:hdmi_table=24'h092888;
            26:hdmi_table=24'h092908;
            27:hdmi_table=24'h091001;
            28:hdmi_table=24'h000b11;
            29:hdmi_table=24'h050e00;
            30:hdmi_table=24'h050a82;
            31:hdmi_table=24'h050902;
            32:hdmi_table=24'h050b0d;
            33:hdmi_table=24'h050d06;
            34:hdmi_table=24'h050d11;
            35:hdmi_table=24'h050d58;
            36:hdmi_table=24'h050d00;
            37:hdmi_table=24'h050d00;
            38:hdmi_table=24'h050d00;
            39:hdmi_table=24'h050d00;
            40:hdmi_table=24'h050d00;
            41:hdmi_table=24'h050d00;
            42:hdmi_table=24'h050d00;
            43:hdmi_table=24'h050d00;
            44:hdmi_table=24'h050d00;
            45:hdmi_table=24'h050d00;
            46:hdmi_table=24'h050d00;
            47:hdmi_table=24'h050e40;
            48:hdmi_table=24'h050700;
            default:hdmi_table=0;
        endcase end
    endfunction

    function [23:0] camera_check;
        input [3:0] index;
        begin
            case(index)
                0:camera_check=24'h430060; // RGB565
                1:camera_check=24'h501f01; // RGB ISP output
                2:camera_check=24'h380805; // 1280 high
                3:camera_check=24'h380900;
                4:camera_check=24'h380a02; // 720 high
                5:camera_check=24'h380bd0;
                6:camera_check=24'h303521;
                7:camera_check=24'h303669;
                8:camera_check=24'h382047;
                9:camera_check=24'h382100;
                10:camera_check=24'h474020; // Refuse startup if launch polarity differs
                default:camera_check=0;
            endcase
        end
    endfunction
    wire [23:0] cam_word=camera_table(ci);
    wire [23:0] hdmi_word=hdmi_table(hi);
    wire [23:0] check_word=camera_check(verify_index);

    always @(posedge clk or negedge resetn)begin
        if(!resetn)begin
            cs<=C_POWER;cam_resetn<=0;cam_done<=0;cam_id<=0;cam_error<=0;
            cam_delay<=0;ci<=0;verify_index<=0;cam_start<=0;cam_read<=0;cam_addr<=0;cam_data<=0;
        end else if(restart)begin
            cs<=C_POWER;cam_resetn<=0;cam_done<=0;cam_id<=0;cam_error<=0;
            cam_delay<=0;ci<=0;verify_index<=0;cam_start<=0;cam_read<=0;cam_addr<=0;cam_data<=0;
        end else begin
            cam_start<=0;
            case(cs)
                C_POWER:if(cam_delay>=POWER_DELAY-1)begin
                    cam_resetn<=1;cam_delay<=0;cs<=C_SETTLE;
                end else cam_delay<=cam_delay+1'b1;
                C_SETTLE:if(cam_delay>=POWER_DELAY-1)begin cam_delay<=0;cs<=C_ID_H;end
                         else cam_delay<=cam_delay+1'b1;
                C_ID_H:if(!cam_busy)begin cam_read<=1;cam_addr<=16'h300a;cam_start<=1;cs<=C_ID_H_WAIT;end
                C_ID_H_WAIT:if(cam_xdone)begin
                    if(cam_nack || cam_timeout)begin cam_error<={2'b0,cam_timeout,cam_nack};cs<=C_FAIL;end
                    else begin cam_id[15:8]<=cam_rdata;cs<=C_ID_L;end
                end
                C_ID_L:if(!cam_busy)begin cam_read<=1;cam_addr<=16'h300b;cam_start<=1;cs<=C_ID_L_WAIT;end
                C_ID_L_WAIT:if(cam_xdone)begin
                    cam_id[7:0]<=cam_rdata;
                    if(cam_nack || cam_timeout)begin cam_error<={2'b0,cam_timeout,cam_nack};cs<=C_FAIL;end
                    else if({cam_id[15:8],cam_rdata}!=16'h5640)begin cam_error<=4'b0100;cs<=C_FAIL;end
                    else begin ci<=0;cs<=C_WRITE;end
                end
                C_WRITE:if(!cam_busy)begin
                    cam_read<=0;cam_addr<=cam_word[23:8];cam_data<=cam_word[7:0];
                    cam_start<=1;cs<=C_WRITE_WAIT;
                end
                C_WRITE_WAIT:if(cam_xdone)begin
                    if(cam_nack || cam_timeout)begin cam_error<={2'b0,cam_timeout,cam_nack};cs<=C_FAIL;end
                    else if(ci==1)begin ci<=ci+1'b1;cam_delay<=0;cs<=C_RESET_WAIT;end
                    else if(ci==CAMERA_WRITES-1)begin verify_index<=0;cs<=C_VERIFY;end
                    else begin ci<=ci+1'b1;cs<=C_WRITE;end
                end
                C_RESET_WAIT:if(cam_delay>=POWER_DELAY-1)begin cam_delay<=0;cs<=C_WRITE;end
                             else cam_delay<=cam_delay+1'b1;
                C_VERIFY:if(!cam_busy)begin
                    cam_read<=1;cam_addr<=check_word[23:8];cam_start<=1;cs<=C_VERIFY_WAIT;
                end
                C_VERIFY_WAIT:if(cam_xdone)begin
                    if(cam_nack || cam_timeout)begin cam_error<={2'b0,cam_timeout,cam_nack};cs<=C_FAIL;end
                    else if(cam_rdata!=check_word[7:0])begin cam_error<=4'b1000;cs<=C_FAIL;end
                    else if(verify_index==CAMERA_CHECKS-1)begin cam_done<=1;cs<=C_DONE;end
                    else begin verify_index<=verify_index+1'b1;cs<=C_VERIFY;end
                end
                C_DONE:cam_done<=1;
                C_FAIL:cam_done<=0;
                default:begin cam_error<=4'b1000;cam_done<=0;cs<=C_FAIL;end
            endcase
        end
    end

    always @(posedge clk or negedge resetn)begin
        if(!resetn)begin
            hs<=H_POWER;hdmi_resetn<=0;hdmi_done<=0;hdmi_error<=0;
            hdmi_delay<=0;hi<=0;hdmi_start<=0;hdmi_read<=0;hdmi_addr<=0;hdmi_data<=0;
        end else if(restart)begin
            hs<=H_POWER;hdmi_resetn<=0;hdmi_done<=0;hdmi_error<=0;
            hdmi_delay<=0;hi<=0;hdmi_start<=0;hdmi_read<=0;hdmi_addr<=0;hdmi_data<=0;
        end else begin
            hdmi_start<=0;
            case(hs)
                H_POWER:if(hdmi_delay>=POWER_DELAY-1)begin
                    hdmi_resetn<=1;hdmi_delay<=0;hs<=H_SETTLE;
                end else hdmi_delay<=hdmi_delay+1'b1;
                H_SETTLE:if(hdmi_delay>=POWER_DELAY-1)begin hdmi_delay<=0;hs<=H_PROBE_W;end
                         else hdmi_delay<=hdmi_delay+1'b1;
                H_PROBE_W:if(!hdmi_busy)begin
                    hdmi_read<=0;hdmi_addr<=16'h0003;hdmi_data<=8'h5a;hdmi_start<=1;hs<=H_PROBE_W_WAIT;
                end
                H_PROBE_W_WAIT:if(hdmi_xdone)begin
                    if(hdmi_nack || hdmi_timeout)begin hdmi_error<={2'b0,hdmi_timeout,hdmi_nack};hs<=H_FAIL;end
                    else hs<=H_PROBE_R;
                end
                H_PROBE_R:if(!hdmi_busy)begin hdmi_read<=1;hdmi_addr<=16'h0003;hdmi_start<=1;hs<=H_PROBE_R_WAIT;end
                H_PROBE_R_WAIT:if(hdmi_xdone)begin
                    if(hdmi_nack || hdmi_timeout)begin hdmi_error<={2'b0,hdmi_timeout,hdmi_nack};hs<=H_FAIL;end
                    else if(hdmi_rdata!=8'h5a)begin hdmi_error<=4'b0100;hs<=H_FAIL;end
                    else begin hi<=0;hs<=H_WRITE;end
                end
                H_WRITE:if(!hdmi_busy)begin
                    hdmi_read<=0;hdmi_addr<=hdmi_word[23:8];hdmi_data<=hdmi_word[7:0];
                    hdmi_start<=1;hs<=H_WRITE_WAIT;
                end
                H_WRITE_WAIT:if(hdmi_xdone)begin
                    if(hdmi_nack || hdmi_timeout)begin hdmi_error<={2'b0,hdmi_timeout,hdmi_nack};hs<=H_FAIL;end
                    else if(hi==18)begin hi<=hi+1'b1;hdmi_delay<=0;hs<=H_WAIT;end
                    else if(hi==HDMI_WRITES-1)begin hdmi_done<=1;hs<=H_DONE;end
                    else begin hi<=hi+1'b1;hs<=H_WRITE;end
                end
                H_WAIT:if(hdmi_delay>=HDMI_SETTLE-1)begin hdmi_delay<=0;hs<=H_WRITE;end
                       else hdmi_delay<=hdmi_delay+1'b1;
                H_DONE:hdmi_done<=1;
                H_FAIL:hdmi_done<=0;
                default:begin hdmi_error<=4'b0100;hdmi_done<=0;hs<=H_FAIL;end
            endcase
        end
    end
endmodule
