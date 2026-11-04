import os,shutil,argparse,hashlib,json,re,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parent
parser=argparse.ArgumentParser()
parser.add_argument('--negative-check',action='store_true')
args=parser.parse_args()
image=ROOT/'src/firmware/production.hex'
binary=ROOT/'src/firmware/production.bin'
active_init=ROOT/'src/firmware/firmware_init.vh'
active_report=ROOT/'identity.json'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
record=json.loads(active_report.read_text(encoding='utf-8'))
assert sha(binary)==record['firmware_sha256']
tokens=image.read_text(encoding='ascii').split()
assert len(tokens)==16384
words=[int(t,16) for t in tokens]
entries=re.findall(r"rom\[(\d+)\]\s*=\s*32'h([0-9a-fA-F]{8})",active_init.read_text())
assert len(entries)==16384 and all(int(index)==i and int(value,16)==words[i] for i,(index,value) in enumerate(entries))
blob=binary.read_bytes()
assert b''.join(w.to_bytes(4,'little') for w in words)[:len(blob)]==blob
input_hashes={str(p):sha(p) for p in [image,binary,active_init,active_report,Path(__file__).resolve()]}
image_literal=json.dumps(image.as_posix(),ensure_ascii=False)
out=ROOT/'synth_rom';out.mkdir(parents=True,exist_ok=True)
net=ROOT/'pds/synthesize/test_ddr_syn.vm'
net_sha=sha(net)
(out/'result.json').write_text(json.dumps({'passed':False,'status':'running','netlist_sha256':net_sha,
    'firmware_hex_path':str(image),'firmware_binary_path':str(binary),'input_hashes':input_hashes}),encoding='utf-8')
text=net.read_text()
header=re.search(r'^module local_memory\b.*?;',text,re.M|re.S).group(0)
module=re.search(r'^module local_memory\b.*?^endmodule',text,re.M|re.S).group(0)
instance=re.search(r'\blocal_memory\s+u_memory\s*\((.*?)\);',text,re.S).group(1)
connection=re.search(r'\.rdata\s*\((.*?)\)',instance,re.S).group(1).strip()
if connection.startswith('{') and connection.endswith('}'):
    output_bits=[part.strip() for part in connection[1:-1].split(',')][::-1]
elif re.fullmatch(r'[A-Za-z_][A-Za-z0-9_$]*',connection):
    # A fully preserved vector needs no cross-hierarchy recovery. Confirm its
    # width and each real output driver before observing it directly below.
    if not re.search(r'\bwire\s+\[31:0\]\s+'+re.escape(connection)+r'\s*;',text):
        raise RuntimeError('Expected a 32-bit synthesized rdata connection')
    for bit in range(32):
        if not re.search(r'\.(?:Z|Z5|Q)\s*\(\s*rdata\['+str(bit)+r'\]\s*\)',module):
            raise RuntimeError(f'Direct rdata[{bit}] has no synthesized output driver')
    output_bits=[connection+'['+str(bit)+']' for bit in range(32)]
else:
    raise RuntimeError('Unsupported synthesized rdata connection; inspect output wiring')
if len(output_bits)!=32:raise RuntimeError('Expected 32 synthesized rdata output bits')
port_defs=re.findall(r'^\s*(input|output)\s*(\[\d+:\d+\])?\s*(\\\S+|\w+)\s*[,\n]',header,re.M)
recovered={}
observation={}
for bit,wire in enumerate(output_bits):
    observation[str(bit)]={'port':'rdata','bit':bit,'soc_connection':wire}
    if not wire.endswith('_floating'):continue
    # Do not mask a broken driver. This adaptation is allowed only where the
    # vector bit was explicitly disconnected by synthesis and is undriven.
    if re.search(r'\.(?:Z|Z5|Q)\s*\(\s*rdata\['+str(bit)+r'\]\s*\)',module) or re.search(r'assign\s+rdata\['+str(bit)+r'\]\s*=',module):
        raise RuntimeError(f'Floating rdata[{bit}] still has a driver; inspect netlist')
    export='\\u_soc/lrd_'+str(bit)
    if ('output','',export) not in port_defs:
        raise RuntimeError(f'No surviving registered output for rdata[{bit}]')
    cells=re.findall(r'\bGTP_DFF_RE\b.*?;',module,re.S)
    matches=[cell for cell in cells if re.search(r'\.Q\s*\(\s*'+re.escape(export)+r'\s*\)',cell)]
    if len(matches)!=1 or not re.search(r'\.CE\s*\(\s*accept_1\s*\)',matches[0]) or not re.search(r'/\*\s*\\rdata\[',matches[0]):
        raise RuntimeError(f'Unexpected registered-read structure for {export}')
    source=re.search(r'\.D\s*\(\s*(\S+)\s*\)',matches[0]).group(1)
    # The D input must be the synthesized read selector, not a constant or a
    # testbench substitute. It continues to depend on the real DRM outputs.
    if not re.search(r'\.(?:Z|Z5)\s*\(\s*'+re.escape(source)+r'\s*\)',module):
        raise RuntimeError(f'Read-selector driver not found for {export}')
    recovered[export]=bit
    observation[str(bit)]={'port':export,'register_data':source,'enable':'accept_1',
                          'reason':'rdata vector bit removed by cross-hierarchy synthesis',
                          'soc_connection':wire}

definitions={'local_memory':port_defs}
for module_name in ['ddr_mmio','mac8_mmio']:
    h=re.search(r'^module '+module_name+r'\b.*?;',text,re.M|re.S).group(0)
    definitions[module_name]=re.findall(r'^\s*(input|output)\s*(\[\d+:\d+\])?\s*(\\\S+|\w+)\s*[,\n]',h,re.M)
outs={name for defs in definitions.values() for direction,width,name in defs if direction=='output' and not width and name.startswith('_N')}
ins={name for defs in definitions.values() for direction,width,name in defs if direction=='input' and not width and name.startswith('_N')}
shared=outs&ins
assert shared,'No shared scalar decode outputs found'
# Confirm actual parent-SoC connections before using a same-name wire.
for module_name,defs in definitions.items():
    inst=re.search(r'\b'+module_name+r'\s+\w+\s*\((.*?)\);',text,re.S).group(1)
    for direction,width,name in defs:
        if name in shared:
            connection=re.search(r'\.'+re.escape(name)+r'\s*\((.*?)\)',inst,re.S).group(1).strip()
            assert connection==name,(module_name,name,connection)
helper_instances=[]
helper_ports={}
for module_name in ['ddr_mmio','mac8_mmio']:
    defs=definitions[module_name]
    ports2=[]
    for direction,width,name in defs:
        if name in shared:value=name
        elif direction=='output':value=''
        elif name=='addr' or name.endswith('/read_addr'):value='address'
        elif name=='clk':value='clk'
        elif name=='resetn':value='resetn'
        else:value=(str(int(width[1:].split(':')[0])+1) if width else '1')+"'b0"
        ports2.append('.'+name+(' ' if name.startswith('\\') else '')+'('+value+')')
    helper_instances.append(module_name+' decode_'+module_name+'('+',\n'.join(ports2)+');')
    helper_ports[module_name]=[name for direction,width,name in defs if name in shared and direction=='output']
all_shared_outputs=[name for name in shared if ('output','',name) in port_defs]+[n for v in helper_ports.values() for n in v]
assert sorted(all_shared_outputs)==sorted(shared),'Every shared decoder signal must have exactly one real synthesized producer'
(out/'decoder_binding.json').write_text(json.dumps({'real_modules':helper_ports,'scope':'actual mapped shared address-decode producers; no substituted decoder constants'},indent=2),encoding='utf-8')

ports=[]
for direction,width,name in port_defs:
    if name in shared:value=name
    elif direction=='output':
        value='raw_actual' if name=='rdata' else ('registered_actual['+str(recovered[name])+']' if name in recovered else '')
    elif name=='addr' or name.endswith('/read_addr'):value='address'
    elif name=='clk':value='clk'
    elif name=='resetn':value='resetn'
    elif name=='uart_rx':value="1'b1"
    else:value=(str(int(width[1:].split(':')[0])+1) if width else '1')+"'b0"
    ports.append('.'+name+(' ' if name.startswith('\\') else '')+'('+value+')')
if '.rdata(raw_actual)' not in ports:raise RuntimeError('Unsupported netlist interface')
assignments='\n'.join('assign actual['+str(bit)+']='+('registered_actual' if bit in recovered.values() else 'raw_actual')+'['+str(bit)+'];' for bit in range(32))
bench='''`timescale 1ns/1ps
module tb_synth_rom;
reg clk=0,resetn=0;always #5 clk=~clk;
reg [31:0] address=0;wire [31:0] actual,raw_actual,registered_actual;
reg [31:0] expected[0:16383];integer n;
GTP_GRS GRS_INST(.GRS_N(resetn));
'''+assignments+'''
'''+''.join('wire '+name+';\n' for name in sorted(shared))+ '\n'.join(helper_instances)+'''
local_memory dut('''+',\n'.join(ports)+''');
initial begin
    $readmemh('''+image_literal+''',expected);
    repeat(5)@(negedge clk);resetn=1;
    force dut.accept_1=1'b1;
    for(n=0;n<16384;n=n+1)begin
        @(negedge clk);address=n*4;
        repeat(3)@(posedge clk);#1;
        if(actual!==expected[n])$fatal(1,"ROM word %0d got=%08x expected=%08x",n,actual,expected[n]);
    end
    $display("SYNTH_ROM_PASS words=16384 local_memory_read_mux");$finish;
end
initial begin #1000000;$fatal(1,"ROM scan timeout");end
endmodule
'''
tb=out/'tb_synth_rom.sv';tb.write_text(bench,encoding='utf-8')
iv=Path(shutil.which('iverilog') or r'D:\RISC-V\iverilog\bin\iverilog.exe')
library=Path(os.environ.get('PDS_HOME', r'D:\FPGA2\PDS_2022.2-SP6.4'))/'arch/vendor/pango/verilog/simulation'
def scan(source,stem):
    cmd=[str(iv),'-B'+str(iv.parent.parent/'lib/ivl'),'-g2012','-s','tb_synth_rom','-y',str(library),'-o',str(out/(stem+'.vvp')),str(source),str(tb)]
    p=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True,errors='replace')
    (out/(('compile' if stem=='scan' else stem+'_compile')+'.log')).write_text(p.stdout+p.stderr,encoding='utf-8')
    if p.returncode:raise RuntimeError(p.stdout[-1000:]+p.stderr[-3000:])
    p=subprocess.run([str(iv.parent/'vvp.exe'),str(out/(stem+'.vvp'))],cwd=ROOT,capture_output=True,text=True,timeout=180)
    (out/(stem+'.log')).write_text(p.stdout+p.stderr,encoding='utf-8')
    return p
p=scan(net,'scan')
print(p.stdout[-1500:]+p.stderr[-1500:],flush=True)
if p.returncode or 'SYNTH_ROM_PASS' not in p.stdout:raise RuntimeError('Synthesized ROM scan failed')
negative=None
if args.negative_check:
    # Change only the stored image in a disposable copy. Flipping bit 1 also
    # exercises the output bit whose vector port this synthesis removed.
    target=re.search(r'\bGTP_DRM36K_E1\s*/\*\s*rom_0\s*\*/.*?\.INIT_00\(288\x27b([01]{288})\)',text,re.S)
    if not target:raise RuntimeError('Unsupported ROM initialization for negative check')
    position=target.end(1)-2
    corrupted=text[:position]+('1' if text[position]=='0' else '0')+text[position+1:]
    temp=out/'negative_rom_bitflip.vm';temp.write_text(corrupted,encoding='ascii')
    failed=scan(temp,'negative_rom_bitflip')
    if failed.returncode==0 or 'ROM word ' not in failed.stdout or 'SYNTH_ROM_PASS' in failed.stdout:
        raise RuntimeError('Negative ROM bit-flip check did not detect image corruption')
    negative={'passed':True,'mutation':'rom_0 INIT_00 bit 1 flipped in temporary netlist only',
              'netlist_sha256':sha(temp),'log_sha256':sha(out/'negative_rom_bitflip.log'),
              'detected_failure':failed.stdout.strip()}
    print('SYNTH_ROM_NEGATIVE_PASS '+failed.stdout.splitlines()[0],flush=True)
if sha(net)!=net_sha:raise RuntimeError('Synthesized netlist changed during scan')
if input_hashes!={name:sha(Path(name)) for name in input_hashes}:
    raise RuntimeError('ROM verification inputs changed during scan')
(out/'result.json').write_text(json.dumps({'passed':True,'words':16384,'netlist_sha256':net_sha,
    'firmware_binary_path':str(binary),'firmware_hex_path':str(image),
    'firmware_binary_sha256':sha(binary),'firmware_hex_sha256':sha(image),
    'active_firmware_init_sha256':sha(active_init),'active_build_report_sha256':sha(active_report),
    'input_hashes':input_hashes,
    'script_sha256':sha(Path(__file__)),'testbench_sha256':sha(tb),'vvp_sha256':sha(out/'scan.vvp'),
    'log_sha256':sha(out/'scan.log'),'observation_map':observation,'negative_check':negative,
    'scope':'Synthesized ROM and local-memory read mux/output registers; accept enable forced; not CPU or AXI gate-level validation'},indent=2),encoding='utf-8')
