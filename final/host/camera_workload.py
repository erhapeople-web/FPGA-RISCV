"""One real on-board camera inference. Host performs no inference or box writes.

The injected link is the sole UART owner; check() supplies STOP/OT/watchdog and
overall deadlines. All writes, reads, identities and CRCs are recorded. There
is no automatic upload or RUN retry. Snapshot readback is for independent
post-run verification and never supplies the device's detections.
"""
from pathlib import Path
import hashlib
import json
import struct
import time
import zlib

ROOT=Path(__file__).resolve().parents[1]
HEADER=struct.Struct('<4sBBHIHH')
# The current128-byte device RX FIFO is required. Actual CPU/ROM tests cover
# four contiguous complete DATA frames; BEGIN/COMMIT still wait for their ACK.
DATA_WINDOW=4
MODEL_SHA='03656fe3497662bee48bd21ab7bb617a7c1273a8595714ba8e2d3d99df307c90'
OPS_SHA='9151c5f1171155f90975a6d68ed598663cdf58515a8c3569da6a050d2e40e072'
PREPROCESS_VERSION=0x10002
CAMERA_PREPROCESSING='RGB565 left-shift expand;central crop x80 y10 w160 h160;no resize or padding;RGB NCHW uint8'

def sha(data):return hashlib.sha256(data).hexdigest()
def encode(cmd,region,seq,offset,payload=b''):
 payload=bytes(payload)
 if not(0<=cmd<256 and 0<=region<256 and 0<=seq<65536 and 0<=offset<2**32 and len(payload)<=256):
  raise ValueError('AIP1 request range')
 body=HEADER.pack(b'AIP1',cmd,region,seq,offset,len(payload),0)+payload
 return body+struct.pack('<I',zlib.crc32(body))

def decode(raw):
 if len(raw)<20:raise ValueError('Short AIP1 frame')
 magic,cmd,region,seq,offset,n,flags=HEADER.unpack_from(raw)
 if magic!=b'AIP1' or flags or n>256 or len(raw)!=20+n:raise ValueError('AIP1 header/size')
 if zlib.crc32(raw[:-4])!=struct.unpack_from('<I',raw,len(raw)-4)[0]:raise ValueError('AIP1 response CRC')
 return dict(command=cmd,region=region,sequence=seq,offset=offset,payload=raw[16:-4])

def preprocess_snapshot(raw):
 """Reference for the v0x10002 central crop of the full locked snapshot."""
 if len(raw)!=320*180*2:raise ValueError('Snapshot is not320x180 RGB565')
 output=bytearray(3*160*160)
 for y in range(160):
  pixels=struct.unpack_from('<160H',raw,((y+10)*320+80)*2)
  for x in range(160):
   p=pixels[x];at=y*160+x
   output[at]=((p>>11)&31)<<3
   output[25600+at]=((p>>5)&63)<<2
   output[51200+at]=(p&31)<<3
 return bytes(output)

class Session:
 def __init__(self,link,run,check,progress_callback=None,clock=time.monotonic):
  self.link,self.run,self.check,self.callback,self.clock=link,Path(run),check,progress_callback,clock
  self.run.mkdir(parents=True,exist_ok=True)
  self.tx=(self.run/'uart_tx.bin').open('wb');self.rx=(self.run/'uart_rx.bin').open('wb')
  self.events=(self.run/'transactions.jsonl').open('w',encoding='utf-8')
  self.progress=(self.run/'node_progress.jsonl').open('w',encoding='utf-8')
  self.tx_bytes=self.rx_bytes=self.requests=self.responses=0
  self.nodes=[];self.phases=[];self.camera_seq=None;self.last_progress=None
  self.inference_started=False
  self.started=clock();self.last_callback=self.started
 def close(self):
  for f in (self.tx,self.rx,self.events,self.progress):f.close()
 def event(self,record):
  record=dict(monotonic=self.clock(),**record)
  self.events.write(json.dumps(record)+'\n');self.events.flush()
  return record
 def notify(self,record):
  if self.callback:self.callback(record)
 def send(self,cmd,region,seq,offset,payload=b''):
  self.check();raw=encode(cmd,region,seq,offset,payload)
  start=self.tx_bytes;self.tx.write(raw);self.tx.flush()
  written=self.link.write(raw)
  if written is not None and written!=len(raw):raise IOError('Partial UART write; request is not retried')
  self.tx_bytes+=len(raw);self.requests+=1
  self.event(dict(direction='tx',command=cmd,region=region,sequence=seq,offset=offset,wire_offset=start,wire_bytes=len(raw),sha256=sha(raw)))
  self.check()
 def exact(self,n,deadline):
  out=bytearray()
  while len(out)<n:
   self.check()
   if self.clock()>=deadline:raise TimeoutError('UART frame deadline; no retry')
   data=self.link.read(n-len(out))
   if data:
    self.rx.write(data);self.rx.flush();self.rx_bytes+=len(data);out.extend(data)
  return bytes(out)
 def receive(self,seconds=8):
  deadline=self.clock()+seconds;start=self.rx_bytes
  header=self.exact(16,deadline)
  if header[:4]!=b'AIP1':raise ValueError('Unexpected bytes on CPU UART')
  size=HEADER.unpack(header)[5]
  if size>256:raise ValueError('UART payload exceeds256')
  raw=header+self.exact(size+4,deadline);answer=decode(raw);self.responses+=1
  self.event(dict(direction='rx',**{k:v for k,v in answer.items()if k!='payload'},wire_offset=start,wire_bytes=len(raw),sha256=sha(raw)))
  if answer['command']==0xb2:raise RuntimeError('Device camera/hook failure: '+answer['payload'].hex())
  return answer
 def progress_frame(self,answer):
  if not self.inference_started:raise ValueError('Inference progress before RUN')
  if (answer['region'],answer['sequence'],len(answer['payload']))!=(0,0,32):raise ValueError('Progress identity')
  phase,node,frame,lo,hi,calls,hits,misses=struct.unpack('<8I',answer['payload'])
  if phase not in (1,2,3,4,5,6,7,8) or answer['offset']!=node:raise ValueError('Progress phase/index')
  at=len(self.phases)
  if at<3:expected=(at+1,0)
  elif at<122:expected=(4,at-2)
  elif at==122:expected=(6,119) if phase==6 else (5,119)
  elif at==123:expected=(7,119)
  elif at==124:expected=(8,119)
  else:expected=(5,119) if at==125 else None
  if (phase,node)!=expected:raise ValueError('Missing/reordered capture, graph or OSD phase')
  if phase>=2:
   if not frame:raise ValueError('No camera frame identity')
   if self.camera_seq is not None and frame!=self.camera_seq:raise ValueError('Camera frame identity changed')
   self.camera_seq=frame
  if phase==4:
   if node!=len(self.nodes)+1 or node>119:raise ValueError('Missing/reordered completed AI node')
   self.nodes.append(node)
  if phase==5 and(node!=119 or len(self.nodes)!=119):raise ValueError('Incomplete graph before OSD')
  record=dict(phase=phase,node=node,camera_frame_seq=frame,cpu_cycles=lo+(hi<<32),cache_calls=calls,cache_hits=hits,cache_misses=misses,host_monotonic=self.clock())
  if self.last_progress and record['cpu_cycles']<self.last_progress['cpu_cycles']:raise ValueError('Device cycle counter regressed')
  self.phases.append(phase);self.last_progress=record
  self.progress.write(json.dumps(record)+'\n');self.progress.flush();self.notify(record)
 def expected(self,cmd,region,seq,offset,seconds=8):
  while True:
   answer=self.receive(seconds)
   if answer['command']==0xb0:self.progress_frame(answer);continue
   if tuple(answer[k]for k in ('command','region','sequence','offset'))!=(cmd,region,seq,offset):raise ValueError('Response identity')
   return answer['payload']
 def ack(self,cmd,region,seq,offset,next_offset,seconds=8):
  payload=self.expected(cmd|0x80,region,seq,offset,seconds)
  if len(payload)!=12:raise ValueError('ACK length')
  status,nxt,mask=struct.unpack('<III',payload)
  if status or nxt!=next_offset or mask&~7:raise ValueError(f'Device rejected/misacknowledged command{cmd}: {status}/{nxt}/{mask}')
  return mask
 def upload(self,region,data):
  if region not in (1,2,3):raise ValueError('Upload region')
  before=(1<<(region-1))-1;after=(1<<region)-1
  started=self.clock();seq=0
  self.send(1,region,seq,0,struct.pack('<I',len(data))+hashlib.sha256(data).digest())
  mask=self.ack(1,region,seq,0,0)
  if mask!=before:raise ValueError('BEGIN validity mask differs from committed prefix')
  for batch_start in range(0,len(data),256*DATA_WINDOW):
   pending=[]
   for offset in range(batch_start,min(len(data),batch_start+256*DATA_WINDOW),256):
    seq+=1;part=data[offset:offset+256];self.send(2,region,seq,offset,part)
    pending.append((seq,offset,offset+len(part)))
   for reply_seq,offset,next_offset in pending:
    mask=self.ack(2,region,reply_seq,offset,next_offset)
    if mask!=before:raise ValueError('DATA validity mask differs from committed prefix')
    if self.clock()-self.last_callback>=1:
     self.notify(dict(phase='upload',region=region,bytes=next_offset,total=len(data)));self.last_callback=self.clock()
  seq+=1;self.send(3,region,seq,len(data));mask=self.ack(3,region,seq,len(data),len(data),seconds=25)
  if mask!=after:raise ValueError('COMMIT did not validate exact region prefix')
  return dict(region=region,bytes=len(data),sha256=sha(data),seconds=self.clock()-started,last_sequence=seq,validmask=mask,DATA_window=DATA_WINDOW)
 def inference(self):
  self.inference_started=True
  seq=1;self.send(5,0,seq,0)
  mask=self.ack(5,0,seq,0,0,seconds=270)
  if mask!=7:raise ValueError('RUN not fully ready')
  boxes=bytearray()
  while True:
   answer=self.receive(30)
   if answer['command']==0xb0:self.progress_frame(answer);continue
   if (answer['region'],answer['sequence'])!=(0,seq):raise ValueError('Detection response identity')
   p=answer['payload']
   if answer['command']==0x90:
    if answer['offset']!=len(boxes)//24 or not len(p) or len(p)%24 or len(boxes)+len(p)>300*24:raise ValueError('Detection ordering/range')
    boxes.extend(p)
   elif answer['command']==0x91:
    if len(p)!=40:raise ValueError('Detection end length')
    count,crc=struct.unpack_from('<II',p)
    if count!=len(boxes)//24 or answer['offset']!=count or crc!=zlib.crc32(boxes):raise ValueError('Detection count/CRC')
    if self.nodes!=list(range(1,120)) or 5 not in self.phases or self.camera_seq is None:raise ValueError('Missing real capture/119nodes/OSD completion')
    (self.run/'detections.boxes').write_bytes(boxes)
    return dict(box_count=count,boxes_sha256=sha(boxes),boxes_q8_q15_class=[list(v)for v in struct.iter_unpack('<6i',boxes)],input_sha256=p[8:].hex(),camera_frame_seq=self.camera_seq,node_count=len(self.nodes),last_progress=self.last_progress)
   else:raise ValueError('Unexpected response while reading detections')
 def snapshot(self):
  raw=bytearray();seq=1000
  for offset in range(0,115200,240):
   count=min(240,115200-offset);self.send(0x21,0,seq,offset,struct.pack('<I',count))
   part=self.expected(0xa1,0,seq,offset)
   if len(part)!=count:raise ValueError('Snapshot chunk length')
   raw.extend(part);seq+=1
  (self.run/'camera_snapshot.rgb565').write_bytes(raw)
  tensor=preprocess_snapshot(raw);(self.run/'camera_input.reference.bin').write_bytes(tensor)
  return dict(snapshot_bytes=len(raw),snapshot_sha256=sha(raw),preprocessed_input_sha256=sha(tensor),
   preprocess_version=PREPROCESS_VERSION,camera_preprocessing=CAMERA_PREPROCESSING,input_crop_xywh=[80,10,160,160])
 def status(self,sequence=2000):
  self.send(0x22,0,sequence,0);p=self.expected(0xa2,0,sequence,0)
  if len(p)!=32:raise ValueError('Camera status length')
  frame,status,version,osd_sequence,count,calls,hits,misses=struct.unpack('<8I',p)
  if frame!=self.camera_seq or status&0x17!=0x12 or version!=PREPROCESS_VERSION or osd_sequence!=1 or count>16:raise ValueError('Capture/locked-display/OSD status')
  return dict(camera_frame_seq=frame,capture_status=status,preprocess_version=version,OSD_commit_sequence=osd_sequence,OSD_box_count=count,cache_calls=calls,cache_hits=hits,cache_misses=misses)

def run_workload(link,run,check,progress_callback=None):
 check();run=Path(run);model=(ROOT/'data/model.bin').read_bytes();ops=(ROOT/'data/ops.bin').read_bytes()
 if sha(model)!=MODEL_SHA or sha(ops)!=OPS_SHA:raise ValueError('Accepted model/ops identity mismatch')
 s=Session(link,run,check,progress_callback)
 result={'passed':False,'scope':'Single physical camera frame, on-board production119-node graph with MAC8/CPU/DDR and actual PP output to HDMI OSD; host performs no inference','host_inference_used':False,'golden_boxes_sent':False,'UART_baud':921600,'DATA_window':DATA_WINDOW,'model_sha256':MODEL_SHA,'ops_sha256':OPS_SHA,'uploads':[]}
 try:
  for region,data in [(1,model),(2,ops),(3,bytes(76800))]:result['uploads'].append(s.upload(region,data))
  result['input_upload_note']='Zero placeholder only satisfies production region protocol; valid RUN replaces INPUT with actual locked camera preprocessing before inference and hashes that real input.'
  result['inference']=s.inference();result['status']=s.status();result['snapshot']=s.snapshot()
  result['status_after_snapshot']=s.status(sequence=2001)
  for key in ('camera_frame_seq','OSD_commit_sequence','OSD_box_count'):
   if result['status_after_snapshot'][key]!=result['status'][key]:raise ValueError('Capture/OSD identity changed during snapshot readback')
  if result['snapshot']['preprocessed_input_sha256']!=result['inference']['input_sha256']:raise ValueError('Returned actual-input SHA does not match captured camera frame')
  if result['status']['OSD_box_count']!=min(16,result['inference']['box_count']):raise ValueError('OSD committed count differs from actual detections')
  check();result['passed']=True
  return result
 except BaseException as error:
  result['error']=type(error).__name__+': '+str(error)
  raise
 finally:
  result.update(wall_seconds=s.clock()-s.started,requests=s.requests,responses=s.responses,tx_bytes=s.tx_bytes,rx_bytes=s.rx_bytes,completed_nodes=len(s.nodes))
  s.close();result['tx_sha256']=sha((run/'uart_tx.bin').read_bytes());result['rx_sha256']=sha((run/'uart_rx.bin').read_bytes())
  (run/'application_result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
