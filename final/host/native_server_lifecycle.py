"""Close only candidate-owned JTAG generations, including witnessed exits.

No import side effects. A reused PID is observed only through PID/birth; it is
never adopted, signalled, or inspected as an owned server. Parent mechanics and
NativeCFG remain unchanged.
"""
import math
from pathlib import Path


def finite_time(value):
    return type(value) in (int,float) and math.isfinite(value) and value>0


def generation_identity(server,index,generation,native):
    owner=generation.get('owner',{})
    folder=(Path(server.run)/'server'/('generation_%03d'%index)).resolve()
    command=[str(server.exe),'-port',str(server.port),'-work_dir',str(folder)]
    return (type(owner.get('pid')) is int and owner['pid']>0 and finite_time(owner.get('create_time'))
            and native.normalized(owner.get('exe',''))==native.normalized(server.exe)
            and owner.get('cmdline')==command and generation.get('command')==command
            and native.normalized(owner.get('cwd',''))==native.normalized(folder)
            and generation.get('exe_sha256')==native.sha(server.exe)
            and native.read_json(folder/'ownership.json',{})==owner)


def witnessed_exit(generation,events):
    owner=generation['owner'];last=generation.get('last_state',{})
    started=generation.get('started_epoch');exited=generation.get('observed_exited_epoch')
    return (finite_time(started) and finite_time(exited) and finite_time(last.get('epoch'))
            and owner['create_time']<=started<=exited<=last['epoch']
            and last.get('state')=='own_pid_exited_port_free' and last.get('pid')==owner['pid']
            and finite_time(last.get('monotonic')) and last in events)


def close_server(server,*,cleared,watchdog_ended,native,process_factory=None,stop_fn=None):
    if cleared is not True or watchdog_ended is not True:
        return dict(closed=False,reason='Clear evidence or watchdog termination unverified; own server retained')
    lookup=process_factory or server._proc;stop_fn=stop_fn or native.stop_exact
    try:
        import json
        events=[json.loads(line)for line in (Path(server.run)/'server_lifecycle.jsonl').read_text(encoding='utf-8').splitlines() if line.strip()]
    except FileNotFoundError:events=[]
    except Exception as error:return dict(closed=False,reason='Invalid server lifecycle evidence',error=repr(error))
    results=[]
    for index,generation in enumerate(server.generations):
        owner=generation.get('owner',{});pid=owner.get('pid')
        try:
            if not generation_identity(server,index,generation,native):
                raise ValueError('Saved generation identity/ownership mismatch')
            exited=witnessed_exit(generation,events)
            try:process=lookup(pid)
            except Exception as error:
                import psutil
                if isinstance(error,(ProcessLookupError,psutil.NoSuchProcess)):process=None
                else:raise
            if process is None:
                results.append(dict(stopped=exited,pid=pid,already_exited=exited,
                                    reason='witnessed_exit' if exited else 'missing_verified_exit'))
                continue
            birth=process.create_time();again=process.create_time()
            if process.pid!=pid or not finite_time(birth) or not finite_time(again) or abs(birth-again)>.000001:
                raise ValueError('Current PID birth observation invalid/changed')
            if abs(birth-owner['create_time'])>.000001:
                results.append(dict(stopped=exited,pid=pid,pid_reused=True,foreign_process_touched=False,
                                    reason='witnessed_exit_and_reused_PID' if exited else 'missing_verified_exit'))
            elif exited:
                results.append(dict(stopped=False,pid=pid,reason='exit_evidence_conflicts_with_same_birth_PID'))
            else:
                results.append(stop_fn(owner,lookup))
        except Exception as error:
            results.append(dict(stopped=False,pid=pid,error=repr(error)))
    try:
        listeners=[row.pid for row in server._listeners()]
        server.save()
    except Exception as error:return dict(closed=False,generations=results,error=repr(error))
    return dict(closed=bool(results) and all(row.get('stopped') is True for row in results) and not listeners,
                generations=results,remaining_listener_PIDs=listeners)
