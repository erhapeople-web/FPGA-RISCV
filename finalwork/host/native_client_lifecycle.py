"""Read-only completion evidence for this candidate's NativeCFG children.

A recorded exit belongs to the complete original owner. A PID now occupied by
a different creation time proves that original child is gone; the new process
is never inspected beyond PID/birth time and is never stopped. A same-birth
identity mismatch or missing completion record remains unverified.
"""
from pathlib import Path
import math
import os


def normalized(path):return os.path.normcase(str(Path(path).resolve()))


def completed_client(owner,completion,*,process_factory=None):
    """Return an auditable stopped verdict; never terminate any process.

    Callers must separately validate the owner's private run/command paths.
    A nonzero integer return code still proves exit, not command success.
    """
    result=dict(stopped=False,pid=owner.get('pid')if isinstance(owner,dict)else None,
                completion_verified=False,pid_reused=False,foreign_process_touched=False)
    try:
        birth=owner['create_time'];pid=owner['pid']
        if (type(pid)is not int or pid<=0 or isinstance(birth,bool)or not isinstance(birth,(int,float))
                or not math.isfinite(birth)or birth<=0 or not isinstance(completion,dict)
                or completion.get('owner')!=owner or type(completion.get('returncode'))is not int):
            result['reason']='missing_or_mismatched_exit_provenance';return result
        # These fields are part of the provenance even when the PID is absent.
        if (not isinstance(owner.get('exe'),str)or not owner['exe']or
                not isinstance(owner.get('cwd'),str)or not owner['cwd']or
                not isinstance(owner.get('cmdline'),list)or not owner['cmdline']or
                any(not isinstance(value,str)for value in owner['cmdline'])):
            result['reason']='invalid_original_process_identity';return result
        result.update(completion_verified=True,returncode=completion['returncode'],original_create_time=birth)
        missing=(ProcessLookupError,)
        try:
            import psutil
            missing+=(psutil.NoSuchProcess,)
        except ImportError:
            if process_factory is None:raise
        factory=process_factory if process_factory is not None else psutil.Process
        try:
            process=factory(pid)
            if process.pid!=pid:
                result['reason']='process_lookup_pid_mismatch';return result
            observed=process.create_time()
            if isinstance(observed,bool)or not isinstance(observed,(int,float))or not math.isfinite(observed)or observed<=0:
                result['reason']='invalid_observed_create_time';return result
            result['observed_create_time']=observed
            if abs(observed-birth)>.000001:
                result.update(stopped=True,pid_reused=True,reason='recorded_exit_and_different_process_birth')
                return result
            if (normalized(process.exe())!=normalized(owner['exe'])or process.cmdline()!=owner['cmdline']or
                    normalized(process.cwd())!=normalized(owner['cwd'])):
                result['reason']='same_birth_process_identity_mismatch';return result
            # Fail closed if the process identity changes during inspection.
            again=process.create_time()
            if (isinstance(again,bool)or not isinstance(again,(int,float))or not math.isfinite(again)or
                    again<=0 or abs(again-birth)>.000001):
                result['reason']='process_changed_during_identity_read';return result
            if process.is_running():
                result['reason']='original_process_still_running';return result
            result.update(stopped=True,reason='recorded_exit_and_original_process_inactive')
        except missing:
            result.update(stopped=True,reason='recorded_exit_and_process_absent')
        return result
    except Exception as error:
        result.update(stopped=False,reason='completion_observation_failed',error=repr(error));return result
