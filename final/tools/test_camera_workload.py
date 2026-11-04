"""Mock-device wire tests. Real fixed model/ops bytes; no inference or hardware."""
from pathlib import Path
import hashlib
import importlib.util
import json
import shutil
import struct
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'evidence/camera_workload_tests'
SOURCE = ROOT / 'host/camera_workload.py'
HEADER = struct.Struct('<4sBBHIHH')
RAW_RED = b'\x00\xf8' * 57600
# Independent constant-color construction, not the implementation's image code.
EXPECTED_INPUT = bytes([248]) * 25600 + bytes(51200)
INPUT_SHA = hashlib.sha256(EXPECTED_INPUT).digest()
BOX = struct.pack('<6i', 40*256, 50*256, 90*256, 80*256, 24000, 41)
NOMINAL_CASES=('nominal','nominal_pixel_ready','nominal_crop_gradient','nominal_outside_crop_changed','nominal_split')


def gradient_fixture():
    # Construct the input directly from channel formulae at source coordinates;
    # no production preprocessing function is used for these expected bytes.
    def channels(x,y):return ((x+3*y)&31,(2*x+y)&63,(x^y)&31)
    raw=b''.join(struct.pack('<H',(r<<11)|(g<<5)|b)
        for y in range(180)for x in range(320)for r,g,b in [channels(x,y)])
    expected=bytearray()
    for channel,shift in [(0,3),(1,2),(2,3)]:
        expected.extend(channels(x,y)[channel]<<shift for y in range(10,170)for x in range(80,240))
    return raw,bytes(expected)


def wire(cmd, region, seq, offset, payload=b''):
    body = HEADER.pack(b'AIP1', cmd, region, seq, offset, len(payload), 0) + payload
    return body + struct.pack('<I', zlib.crc32(body))


class FakeDevice:
    def __init__(self, fault=None):
        self.fault=fault;self.pending=bytearray();self.writes=0;self.reads=0;self.mask=0
        self.regions={};self.seen=set();self.snapshot_requests=0;self.status_requests=0
        self.raw,self.expected_input=gradient_fixture() if fault=='nominal_crop_gradient' else (RAW_RED,EXPECTED_INPUT)
        if fault=='nominal_outside_crop_changed':self.raw=b'\xff\xff'+self.raw[2:]
    def enqueue(self, cmd, region, seq, offset, payload=b''):
        frame=bytearray(wire(cmd,region,seq,offset,payload))
        if self.fault=='response_crc' and self.writes==1:frame[-1]^=1
        self.pending.extend(frame)
    def ack(self,cmd,region,seq,offset,nxt):
        mask=self.mask;status=0
        if self.writes==1:
            if self.fault=='ack_command':cmd=2
            if self.fault=='ack_region':region=2
            if self.fault=='ack_sequence':seq+=1
            if self.fault=='ack_offset':offset+=1
            if self.fault=='ack_status':status=3
            if self.fault=='ack_next':nxt+=1
            if self.fault=='ack_reserved_mask':mask=8
            if self.fault=='premature_mask':mask=1
        if self.fault=='lost_previous_mask' and cmd==1 and region==2:mask=0
        if self.fault=='future_region_mask' and cmd==3 and region==1:mask=3
        self.enqueue(cmd|0x80,region,seq,offset,struct.pack('<3I',status,nxt,mask))
    def progress(self,phase,node,cycle):
        frame=0 if phase==1 else 17;seq=0;offset=node
        if self.fault=='zero_camera_identity' and phase==2:frame=0
        if self.fault=='changed_camera_identity' and phase==4 and node==5:frame=18
        if self.fault=='progress_identity' and phase==2:seq=1
        if self.fault=='progress_offset' and phase==2:offset=1
        if self.fault=='cycles_regressed' and phase==4 and node==2:cycle=1
        self.enqueue(0xb0,0,seq,offset,struct.pack('<8I',phase,node,frame,cycle,0,1000,700,300))
    def inference(self,seq):
        for phase in [1,2,3]:
            if self.fault=='omit_capture_phases' or self.fault=='omit_phase2' and phase==2:continue
            self.progress(phase,0,phase*100)
        nodes=list(range(1,120))
        if self.fault=='missing_node':nodes.remove(42)
        if self.fault=='reordered_nodes':nodes[1],nodes[2]=nodes[2],nodes[1]
        if self.fault=='duplicate_node':nodes.insert(1,1)
        for node in nodes:self.progress(4,node,300+node*100)
        if self.fault=='nominal_split':
            self.progress(6,119,12300);self.progress(7,119,12500)
        self.enqueue(0x85,0,seq,0,struct.pack('<3I',0,0,7))
        boxes=BOX;offset=0;region=0;reply_seq=seq
        if self.fault=='detection_identity':reply_seq+=1
        if self.fault=='detection_offset':offset=1
        if self.fault=='detection_empty':boxes=b''
        self.enqueue(0x90,region,reply_seq,offset,boxes)
        if self.fault=='nominal_split':self.progress(8,119,12800)
        if self.fault!='omit_phase5':self.progress(5,119,13000)
        crc=zlib.crc32(BOX);count=1;input_sha=hashlib.sha256(self.expected_input).digest()
        if self.fault=='end_count':count=2
        if self.fault=='end_crc':crc^=1
        if self.fault=='input_sha':input_sha=bytes(32)
        self.enqueue(0x91,0,seq,count,struct.pack('<II',count,crc)+input_sha)
    def write(self,raw):
        self.writes+=1
        if self.fault=='partial_write':return len(raw)-1
        if self.fault=='timeout':return len(raw)
        assert len(raw)>=20
        magic,cmd,region,seq,offset,n,flags=HEADER.unpack_from(raw)
        assert magic==b'AIP1' and not flags and n<=256 and len(raw)==n+20
        assert zlib.crc32(raw[:-4])==struct.unpack_from('<I',raw,len(raw)-4)[0]
        assert (cmd,region,seq,offset) not in self.seen,'unexpected automatic retry'
        self.seen.add((cmd,region,seq,offset));payload=raw[16:-4]
        if self.fault=='device_error' and self.writes==1:
            self.enqueue(0xb2,0,seq,cmd,b'\xc2\0\0\0');return len(raw)
        if cmd==1:
            assert region in (1,2,3) and seq==0 and offset==0 and n==36
            length=struct.unpack_from('<I',payload)[0]
            self.regions[region]={'size':length,'sha':payload[4:],'data':bytearray(),'seq':0}
            self.ack(cmd,region,seq,offset,0)
        elif cmd==2:
            item=self.regions[region];assert seq==item['seq']+1 and offset==len(item['data'])
            item['data'].extend(payload);item['seq']=seq;self.ack(cmd,region,seq,offset,len(item['data']))
        elif cmd==3:
            item=self.regions[region];assert seq==item['seq']+1 and offset==item['size']==len(item['data']) and n==0
            assert hashlib.sha256(item['data']).digest()==item['sha']
            if region==3:assert item['data']==bytes(76800)
            self.mask|=1<<(region-1);self.ack(cmd,region,seq,offset,len(item['data']))
        elif cmd==5:
            assert self.mask==7 and (region,seq,offset,n)==(0,1,0,0);self.inference(seq)
        elif cmd==0x22:
            assert (region,seq,offset,n)==(0,2000+self.status_requests,0,0)
            after=self.status_requests==1;self.status_requests+=1
            frame,status,version,osdseq,count=17,18,0x10002,1,1
            if self.fault=='nominal_pixel_ready':status=26
            if self.fault=='status_frame':frame=18
            if self.fault=='status_error':status=6
            if self.fault=='status_version':version=0
            if self.fault=='status_legacy_version':version=0x10001
            if self.fault=='status_osd_sequence':osdseq=0
            if self.fault=='status_osd_count':count=0
            if self.fault=='status_lock_missing':status=2
            if self.fault=='status_busy':status=19
            if self.fault=='status_osd_second_commit':osdseq=2
            if after:
                if self.fault=='status_after_lock_missing':status=2
                if self.fault=='status_after_busy':status=19
                if self.fault=='status_after_ready_lost':status=16
                if self.fault=='status_after_error':status=22
                if self.fault=='status_after_frame_changed':frame=18
                if self.fault=='status_after_sequence_changed':osdseq=2
                if self.fault=='status_after_count_changed':count=0
                if self.fault=='status_after_legacy_version':version=0x10001
            self.enqueue(0xa2,0,seq,0,struct.pack('<8I',frame,status,version,osdseq,count,1000,700,300))
        elif cmd==0x21:
            count=struct.unpack('<I',payload)[0]
            assert (region,n)==(0,4) and offset==self.snapshot_requests*240 and seq==1000+self.snapshot_requests
            part=self.raw[offset:offset+count]
            if self.fault=='snapshot_length' and offset==0:part=part[:-2]
            if self.fault=='snapshot_bytes' and offset<=6560<offset+count:
                at=6560-offset;part=part[:at]+b'\xff\xff'+part[at+2:]
            if self.fault=='snapshot_identity' and offset==0:seq+=1
            self.enqueue(0xa1,0,seq,offset,part);self.snapshot_requests+=1
        else:raise AssertionError('Unexpected request command')
        return len(raw)
    def read(self,n):
        self.reads+=1;take=min(n,7,len(self.pending));out=bytes(self.pending[:take]);del self.pending[:take];return out


def load_module():
    spec=importlib.util.spec_from_file_location('tested_camera_workload',SOURCE)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module


def run_case(name,expect_failure):
    module=load_module();device=FakeDevice(None if name=='nominal' else name)
    if name=='timeout':
        real_session=module.Session
        class QuickSession(real_session):
            def __init__(self,*args,**kwargs):
                self.now=0
                def clock():self.now+=1;return self.now
                kwargs['clock']=clock;super().__init__(*args,**kwargs)
        module.Session=QuickSession
    checks=0
    def check():
        nonlocal checks
        checks+=1
        if name=='STOP' and checks>=10:raise RuntimeError('TEST_STOP_REQUESTED')
    runs=OUT/'temporary_runs';runs.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=name+'_',dir=runs) as directory:
        run=Path(directory).resolve();assert run.is_relative_to(OUT.resolve())
        caught=None;result=None
        try:result=module.run_workload(device,run,check)
        except Exception as error:caught=type(error).__name__+': '+str(error)
        saved=json.loads((run/'application_result.json').read_text()) if (run/'application_result.json').is_file() else None
        if name in NOMINAL_CASES:
            assert result and result['passed'] and device.snapshot_requests==480 and device.status_requests==2
            assert result['status_after_snapshot']['camera_frame_seq']==result['status']['camera_frame_seq']
            assert result['status_after_snapshot']['OSD_commit_sequence']==result['status']['OSD_commit_sequence']==1
            assert result['status_after_snapshot']['OSD_box_count']==result['status']['OSD_box_count']==1
            assert result['status']['preprocess_version']==result['status_after_snapshot']['preprocess_version']==0x10002
            assert result['snapshot']['input_crop_xywh']==[80,10,160,160]
            assert (run/'camera_snapshot.rgb565').read_bytes()==device.raw
            assert (run/'camera_input.reference.bin').read_bytes()==device.expected_input
            assert (run/'detections.boxes').read_bytes()==BOX
            for region,filename in [(1,'model.bin'),(2,'ops.bin')]:assert bytes(device.regions[region]['data'])==(ROOT/'data'/filename).read_bytes()
            shutil.copy2(run/'application_result.json',OUT/(name+'_mock_application_result.json'))
        accepted=caught is None
        passed=(not accepted) if expect_failure else accepted
        if expect_failure and caught and saved:assert saved['passed'] is False
        if name=='partial_write':assert device.writes==1
        row={'name':name,'passed':passed,'expected_rejection':expect_failure,'rejected':not accepted,
            'exception':caught,'writes':device.writes,'reads':device.reads,'checks':checks,
            'snapshot_requests':device.snapshot_requests,'status_requests':device.status_requests,'saved_application_passed':saved['passed'] if saved else None}
        print('CAMERA_WORKLOAD_TEST',name,'PASS' if passed else 'FAILED_ACCEPTED_INVALID_SESSION',flush=True)
        return row


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    names=['nominal','nominal_pixel_ready','nominal_crop_gradient','nominal_outside_crop_changed','nominal_split','response_crc','ack_command','ack_region','ack_sequence','ack_offset','ack_status','ack_next',
        'ack_reserved_mask','premature_mask','lost_previous_mask','future_region_mask','omit_capture_phases','omit_phase2',
        'missing_node','reordered_nodes','duplicate_node','zero_camera_identity','changed_camera_identity',
        'progress_identity','progress_offset','cycles_regressed','omit_phase5','detection_identity','detection_offset',
        'detection_empty','end_count','end_crc','input_sha','status_frame','status_error','status_version',
        'status_osd_sequence','status_osd_count','snapshot_length','snapshot_bytes','snapshot_identity',
        'partial_write','STOP','timeout','device_error','status_lock_missing','status_busy','status_osd_second_commit',
        'status_after_lock_missing','status_after_busy','status_after_ready_lost','status_after_error',
        'status_after_frame_changed','status_after_sequence_changed','status_after_count_changed',
        'status_legacy_version','status_after_legacy_version']
    rows=[run_case(name,name not in NOMINAL_CASES)for name in names]
    result={'passed':all(r['passed']for r in rows),'device':'fake_device','hardware_access':False,'AI_inference_executed':False,
        'scope':'Independent fake wire device; complete real model/ops upload and one-frame host orchestration, no board/model math',
        'source_sha256':{str(p):hashlib.sha256(p.read_bytes()).hexdigest()for p in [SOURCE,Path(__file__).resolve(),ROOT/'data/model.bin',ROOT/'data/ops.bin']},
        'raw_fixture':'RGB565 red and independent spatial RGB gradient; v10002 central crop input; fabricated detection for transport tests only',
        'independent_input_sha256':INPUT_SHA.hex(),'tests':rows,'test_count':len(rows)}
    (OUT/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print('CAMERA_WORKLOAD_TESTS_RESULT',result['passed'],len(rows),flush=True)
    raise SystemExit(0 if result['passed'] else 1)


if __name__=='__main__':main()
