import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

HERE=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(HERE))
from core import classify,decide
NOW=2000000000


def fixture():
    expected={name:{'ip':'172.30.0.'+str(i+11),'control_plane':name.startswith('master')}
              for i,name in enumerate(['master1','master2','master3','worker1','worker2','worker3'])}
    units={n:{'LoadState':'loaded','ActiveState':'active','UnitFileState':'enabled'} for n in ['containerd','kubelet']}
    snapshot={'api_ready':True,'cluster_uid':'cluster-uid','nodes':{'items':[]},'pods':{'items':[]},'probes':{}}
    for name,host in expected.items():
        snapshot['nodes']['items'].append({'metadata':{'name':name},'spec':{},'status':{
            'addresses':[{'type':'InternalIP','address':host['ip']}],
            'conditions':[{'type':'Ready','status':'True'}]}})
        snapshot['probes'][name]={'reachable':True,'observation':{'captured_at':NOW,
            'units':copy.deepcopy(units),'disks':[{'path':'/','free_percent':50}],
            'memory_available_mb':4096,'memory_total_mb':12000}}
    return snapshot,expected


def stop(snapshot,name='worker1',services=('kubelet',)):
    node=next(n for n in snapshot['nodes']['items'] if n['metadata']['name']==name)
    node['status']['conditions'][0]['status']='False'
    for service in services:
        snapshot['probes'][name]['observation']['units'][service]['ActiveState']='failed'


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.s,self.e=fixture()
        self.p={'expected_cluster_uid':'cluster-uid','auto_repair_enabled':True,
                'confirmations':3,'cooldown_seconds':1800}
    def classify(self):return classify(self.s,self.e,self.p,NOW)
    def test_healthy_has_no_action(self):
        self.assertEqual(self.classify()['code'],'HEALTHY')
        self.assertIsNone(self.classify()['action'])
    def test_confirmed_worker_has_ordered_start_plan(self):
        stop(self.s,services=('containerd','kubelet'))
        self.assertEqual(self.classify()['action'],{'host':'worker1','services':['containerd','kubelet']})
    def test_global_api_outage_never_starts_services(self):
        stop(self.s);self.s['api_ready']=False
        self.assertIsNone(self.classify()['action'])
    def test_wrong_cluster_uid_and_node_address_block_action(self):
        stop(self.s);self.s['cluster_uid']='different'
        self.assertEqual(self.classify()['code'],'CLUSTER_IDENTITY_MISMATCH')
        self.s['cluster_uid']='cluster-uid';self.e['worker1']['ip']='1.2.3.4'
        self.assertEqual(self.classify()['code'],'NODE_ADDRESS_MISMATCH')
    def test_missing_ssh_and_stale_observations_block_action(self):
        stop(self.s);self.s['probes']['master3']['reachable']=False
        self.assertIsNone(self.classify()['action'])
        self.s['probes']['master3']['reachable']=True
        self.s['probes']['master3']['observation']['captured_at']=NOW-600
        self.assertIsNone(self.classify()['action'])
    def test_masked_or_disabled_service_is_not_enabled(self):
        stop(self.s)
        for value in ['disabled','masked','static']:
            self.s['probes']['worker1']['observation']['units']['kubelet']['UnitFileState']=value
            self.assertIsNone(self.classify()['action'])
    def test_resource_pressure_and_low_disk_block_action(self):
        stop(self.s);self.s['probes']['worker1']['observation']['disks'][0]['free_percent']=2
        self.assertEqual(self.classify()['code'],'RESOURCE_PRESSURE')
        self.s['probes']['worker1']['observation']['disks'][0]['free_percent']=50
        self.s['nodes']['items'][0]['status']['conditions'].append({'type':'MemoryPressure','status':'True'})
        self.assertEqual(self.classify()['code'],'RESOURCE_PRESSURE')
    def test_multiple_failed_nodes_block_action(self):
        stop(self.s);stop(self.s,'worker2')
        self.assertEqual(self.classify()['code'],'MULTI_NODE_FAILURE')
    def test_control_plane_requires_explicit_policy(self):
        stop(self.s,'master1')
        self.assertEqual(self.classify()['code'],'CONTROL_PLANE_REVIEW_REQUIRED')
        self.p['allow_control_plane_service_start']=True
        self.assertEqual(self.classify()['action']['host'],'master1')
    def test_crashloop_is_app_issue_without_service_action(self):
        self.s['pods']['items']=[{'metadata':{'name':'backend-x','namespace':'platform'},'status':{
            'containerStatuses':[{'name':'backend','state':{'waiting':{'reason':'CrashLoopBackOff'}}}]}}]
        self.assertEqual(self.classify()['code'],'APP_WORKLOAD_ISSUE')
        self.assertIsNone(self.classify()['action'])
    def test_maintenance_node_blocks_action(self):
        stop(self.s);self.s['nodes']['items'][3]['spec']['unschedulable']=True
        self.assertEqual(self.classify()['code'],'NODE_MAINTENANCE')
    def test_three_confirmations_and_dual_enable_required(self):
        stop(self.s);state={};result=self.classify()
        for i in range(2):
            state,action,_=decide(result,state,self.p,NOW+i,True)
            self.assertIsNone(action)
        state,action,_=decide(result,state,self.p,NOW+2,True)
        self.assertEqual(action['host'],'worker1')
        self.assertIsNone(decide(result,state,self.p,NOW+3,False)[1])
        self.p['auto_repair_enabled']=False
        self.assertIsNone(decide(result,state,self.p,NOW+3,True)[1])
    def test_uid_cooldown_maintenance_and_circuit_stop_dispatch(self):
        stop(self.s);result=self.classify();state={'signature':json.dumps(result['action'],sort_keys=True),'failure_count':9}
        self.assertIsNone(decide(result,state,self.p,NOW,True,True)[1])
        self.assertIsNone(decide(result,{**state,'last_attempt':NOW-10},self.p,NOW,True)[1])
        self.assertIsNone(decide(result,{**state,'circuit_open':True},self.p,NOW,True)[1])
        self.p['expected_cluster_uid']=''
        self.assertIsNone(decide(result,state,self.p,NOW,True)[1])
    def test_sustained_health_closes_circuit(self):
        state={'circuit_open':True}
        for i in range(3):state,_,_=decide(self.classify(),state,self.p,NOW+i,True)
        self.assertFalse(state['circuit_open'])



class WatcherIntegrationTests(unittest.TestCase):
    def test_fake_cli_pipeline_observes_then_dispatches_once(self):
        import yaml
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);bin=root/'bin';bin.mkdir()
            snapshot,expected=fixture();stop(snapshot)
            inventory={'_meta':{'hostvars':{name:{'ip':h['ip'],'onprem_inventory_confirmed':True} for name,h in expected.items()}},
                       'kube_control_plane':{'hosts':[n for n in expected if n.startswith('master')]},
                       'kube_node':{'hosts':[n for n in expected if n.startswith('worker')]}}
            payload={'snapshot':snapshot,'inventory':inventory}
            (bin/'fixture.json').write_text(json.dumps(payload))
            common = "import json,sys,time\nfrom pathlib import Path\nbase=Path(__file__).parent\ndata=json.loads((base/'fixture.json').read_text())\n"
            def executable(name,body):
                path=bin/name;path.write_text('#!'+sys.executable+'\n'+common+body);path.chmod(0o755)
            executable('ansible-inventory',"print(json.dumps(data['inventory']))\n")
            executable('kubectl',"""
args=sys.argv[1:]
if '--raw=/readyz' in args: print('ok')
elif 'namespace' in args: print(json.dumps({'metadata':{'uid':'cluster-uid'}}))
elif 'nodes' in args: print(json.dumps(data['snapshot']['nodes']))
elif 'pods' in args: print(json.dumps(data['snapshot']['pods']))
else: raise SystemExit(2)
""")
            executable('ansible-playbook',"""
args=sys.argv[1:];extra=json.loads(args[args.index('-e')+1])
if 'playbooks/recovery/diagnose.yml' in args:
    out=Path(extra['recovery_output_dir'])
    for name,probe in data['snapshot']['probes'].items():
        probe['observation']['captured_at']=time.time()
        (out/(name+'.json')).write_text(json.dumps(probe))
elif 'playbooks/recovery/repair-services.yml' in args:
    assert args[args.index('--limit')+1]=='worker1'
    assert extra['recovery_services']==['kubelet']
    with (base/'dispatch.jsonl').open('a') as stream: stream.write(json.dumps(extra)+'\\n')
else: raise SystemExit(2)
""")
            config={'manager_context':'fake-manager','kubeconfig_file':str(root/'fake.kubeconfig'),
                    'state_dir':str(root/'state'),'ansible_playbook':str(bin/'ansible-playbook'),
                    'kubectl':str(bin/'kubectl'),'expected_cluster_uid':'cluster-uid',
                    'auto_repair_enabled':True,'confirmations':3,'cooldown_seconds':1800}
            cfg=root/'config.yml';cfg.write_text(yaml.safe_dump(config))
            cmd=[sys.executable,str(HERE/'watcher.py'),'--config',str(cfg)]
            for flags in [[],['--apply'],['--apply'],['--apply']]:
                run=subprocess.run(cmd+flags,text=True,capture_output=True)
                self.assertEqual(run.returncode,0,run.stderr)
            dispatches=(bin/'dispatch.jsonl').read_text().splitlines()
            self.assertEqual(len(dispatches),1)
            state=json.loads((root/'state/state.json').read_text())
            self.assertTrue(state['circuit_open'])
            report=json.loads((root/'state/latest.json').read_text())
            self.assertIn('circuit open',report['decision'])
            self.assertIsNone(report['action'])


if __name__=='__main__':unittest.main()

