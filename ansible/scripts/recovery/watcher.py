#!/usr/bin/env python3
"""One detection cycle. A systemd timer repeats it outside the managed Kubernetes cluster."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid
import yaml
from core import classify, decide

ROOT = Path(__file__).resolve().parents[2]


def atomic(path, value):
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(value, indent=2))
    temp.chmod(0o600)
    temp.replace(path)


def run(argv, env, timeout=90):
    try:
        p = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout
    except (OSError, subprocess.TimeoutExpired):
        return 124, ''


def absolute(value):
    path = Path(value).expanduser()
    return path if path.is_absolute() else ROOT / path


def cycle(config, apply=False):
    os.umask(0o077)
    state_dir = absolute(config.get('state_dir', '.state/recovery'))
    state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = open(state_dir/'watcher.lock', 'a')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print('Another recovery cycle is running; skipped.')
        return 0
    env = dict(os.environ)
    env.update(ANSIBLE_CONFIG=str(ROOT/'ansible.cfg'), ANSIBLE_LOCAL_TEMP=str(state_dir/'tmp'),
               ANSIBLE_SSH_CONTROL_PATH_DIR=str(state_dir/'ssh'), ANSIBLE_ROLES_PATH=str(ROOT/'roles'),
               ANSIBLE_HOST_KEY_CHECKING='True')
    for name in ['tmp','ssh','kube-cache','runs']:
        (state_dir/name).mkdir(exist_ok=True,mode=0o700)
    inventory = absolute(config.get('inventory_file','inventory/onprem/hosts.yaml'))
    ansible = absolute(config.get('ansible_playbook','.venv/bin/ansible-playbook'))
    inventory_cmd = str(ansible.with_name('ansible-inventory'))
    rc, raw = run([inventory_cmd,'-i',str(inventory),'--list'], env)
    if rc:
        raise RuntimeError('inventory compilation failed')
    inv = json.loads(raw)
    hosts = inv['_meta']['hostvars']
    cp = set(inv['kube_control_plane']['hosts'])
    workers = set(inv['kube_node']['hosts'])
    if len(cp)!=3 or len(workers)!=3 or cp & workers:
        raise RuntimeError('expected three dedicated control-plane and three worker nodes')
    expected = {name:{'ip':hosts[name]['ip'],'control_plane':name in cp} for name in sorted(cp|workers)}
    if config.get('auto_repair_enabled') and not all(hosts[n].get('onprem_inventory_confirmed') is True for n in expected):
        raise RuntimeError('automatic repair requires confirmed inventory')
    context = config['manager_context']
    if not context or context == 'YOUR_ONPREM_CONTEXT':
        raise RuntimeError('configure manager_context')
    kubeconfig = absolute(config['kubeconfig_file'])
    kube = [config.get('kubectl','kubectl'),'--context',context,'--kubeconfig',str(kubeconfig),
            '--cache-dir',str(state_dir/'kube-cache'),'--request-timeout=8s']
    def get(args):
        rc,out = run(kube+args,env,20)
        if rc:
            return None
        try:
            return json.loads(out)
        except ValueError:
            return None
    uid = get(['get','namespace','kube-system','-o','json'])
    ready_rc,_ = run(kube+['get','--raw=/readyz'],env,20)
    snapshot = {'api_ready':ready_rc==0,'cluster_uid':(uid or {}).get('metadata',{}).get('uid'),
                'nodes':get(['get','nodes','-o','json']),
                'pods':get(['get','pods','--all-namespaces','-o','json'])}
    run_dir=state_dir/'runs'/(time.strftime('%Y%m%dT%H%M%S',time.gmtime())+'-'+uuid.uuid4().hex[:8])
    run_dir.mkdir(mode=0o700)
    extra={'recovery_output_dir':str(run_dir)}
    command=[str(ansible),'-i',str(inventory),'playbooks/recovery/diagnose.yml','-e',json.dumps(extra)]
    if config.get('ssh_private_key_file'):
        command += ['--private-key',str(absolute(config['ssh_private_key_file']))]
    probe_rc,_=run(command,env,config.get('probe_timeout_seconds',120))
    snapshot['probes']={}
    for name in expected:
        path=run_dir/(name+'.json')
        if path.exists():
            try:
                snapshot['probes'][name]=json.loads(path.read_text())
            except ValueError:
                pass
    # A failed or interrupted Ansible run is never used as an automatic action source.
    if probe_rc:
        snapshot['probes']={}
    now=time.time()
    result=classify(snapshot,expected,config,now)
    state_path=state_dir/'state.json'
    state=json.loads(state_path.read_text()) if state_path.exists() else {}
    state,action,reason=decide(result,state,config,now,apply,(state_dir/'maintenance').exists())
    report={'observed_at':now,'cluster_uid':snapshot['cluster_uid'],'classification':result,
            'decision':reason,'action':None,'probe_returncode':probe_rc}
    if action:
        # Persist the circuit BEFORE dispatch: a killed runner cannot immediately retry a partial change.
        state.update(last_attempt=now,circuit_open=True)
        atomic(state_path,state)
        extra={'recovery_repair_enabled':True,'recovery_target':action['host'],
               'recovery_services':action['services'],'recovery_expected_cluster_uid':config['expected_cluster_uid'],
               'manager_context':context,'recovery_kubeconfig_file':str(kubeconfig),
               'recovery_kube_cache':str(state_dir/'kube-cache'),
               'recovery_min_memory_mb':config.get('min_memory_mb',256),
               'recovery_min_memory_ratio':config.get('min_memory_ratio',.05),
               'recovery_min_disk_free_percent':config.get('min_disk_free_percent',10),
               'recovery_allow_control_plane':config.get('allow_control_plane_service_start',False)}
        cmd=[str(ansible),'-i',str(inventory),'playbooks/recovery/repair-services.yml',
             '--limit',action['host'],'-e',json.dumps(extra)]
        if config.get('ssh_private_key_file'):
            cmd += ['--private-key',str(absolute(config['ssh_private_key_file']))]
        repair_rc,_=run(cmd,env,config.get('repair_timeout_seconds',240))
        report['action']={**action,'returncode':repair_rc,'verified_ready':repair_rc==0}
    atomic(state_path,state)
    atomic(run_dir/'report.json',report)
    atomic(state_dir/'latest.json',report)
    # Raw snapshots contain only health metadata, but still retain a bounded private history.
    runs=sorted((state_dir/'runs').iterdir())
    for old in runs[:-config.get('retain_runs',20)]:
        if old.is_dir():
            shutil.rmtree(old)
    print(json.dumps({'classification':result['code'],'decision':reason,'action':report['action']}))
    return 0


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--config',required=True,type=Path)
    p.add_argument('--apply',action='store_true',help='Still requires auto_repair_enabled=true and all runtime gates')
    args=p.parse_args()
    config=yaml.safe_load(args.config.read_text())
    if not isinstance(config,dict):
        raise ValueError('configuration must be a mapping')
    for name in ['auto_repair_enabled','allow_control_plane_service_start']:
        if name in config and not isinstance(config[name], bool):
            raise ValueError(name + ' must be a YAML boolean')
    if config.get('confirmations',3)<2 or config.get('cooldown_seconds',1800)<60 or config.get('retain_runs',20)<1:
        raise ValueError('invalid confirmation, cooldown or retention limits')
    return cycle(config,args.apply)


if __name__=='__main__':
    try:
        raise SystemExit(main())
    except Exception as e:
        # Do not print subprocess stderr, kubeconfigs, environment, or credential-bearing exception text.
        print('Recovery watcher failed ('+type(e).__name__+'); no further action.',file=sys.stderr)
        raise SystemExit(1)
