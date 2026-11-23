"""공통 인증 role의 흐름/멱등성 시험. CLI와 health module은 모의이며 외부 접속 없음."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ANSIBLE = Path(__file__).resolve().parents[1]
FAKE_CLI = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
a = sys.argv[1:]
statefile = Path(os.environ['AUTH_TEST_STATE'])
s = json.loads(statefile.read_text())
if Path(sys.argv[0]).name == 'kubectl':
    if 'view' in a:
        print(json.dumps({'clusters': [{'cluster': {'server': s.get('api', 'https://172.30.0.120:6443')}}]}))
    elif 'configmap' in a:
        print(json.dumps({'data': {'ca.crt': 'PUBLIC-KUBERNETES-CA'}}))
    elif 'apply' in a:
        body = json.loads(sys.stdin.read())
        s.setdefault('ca_namespaces', []).append(body['metadata']['namespace'])
        print('secret/vault-vm-ca unchanged')
    else:
        sys.exit(8)
elif a[:2] == ['auth', 'list']:
    print(json.dumps(s.get('mounts', {})))
elif a[:2] == ['auth', 'enable']:
    s.setdefault('mounts', {})['onprem/'] = {'type': 'kubernetes'}
elif a[0] == 'read':
    if s.get('deny_read'):
        print('permission denied', file=sys.stderr)
        sys.exit(2)
    path = a[-1]
    if path not in s.get('records', {}):
        print('No value found at ' + path, file=sys.stderr)
        sys.exit(2)
    print(json.dumps({'data': s['records'][path]}))
elif a[:2] == ['policy', 'write']:
    path = 'sys/policies/acl/' + a[2]
    s.setdefault('records', {})[path] = {'policy': sys.stdin.read()}
    s.setdefault('writes', []).append(path)
elif a[0] == 'write':
    path = a[1]
    body = json.loads(sys.stdin.read())
    if '/role/' in path:
        body['token_ttl'] = 600
        body['token_max_ttl'] = 3600
    s.setdefault('records', {})[path] = body
    s.setdefault('writes', []).append(path)
else:
    sys.exit(9)
statefile.write_text(json.dumps(s))
'''
FAKE_HEALTH = '''#!/usr/bin/python
from ansible.module_utils.basic import AnsibleModule
module = AnsibleModule(argument_spec=dict(
    url=dict(type='str'), ca_path=dict(type='str'),
    use_proxy=dict(type='bool'), status_code=dict(type='list', elements='int')),
    supports_check_mode=True)
module.exit_json(changed=False, status=200)
'''


class CommonAuthTests(unittest.TestCase):
    def run_role(self, folder, state):
        folder = Path(folder)
        statefile = folder / 'state.json'
        statefile.write_text(json.dumps(state))
        for name in ['vault', 'kubectl']:
            p = folder / name
            p.write_text(FAKE_CLI)
            p.chmod(0o755)
        library = folder / 'library'
        library.mkdir(exist_ok=True)
        (library / 'test_vault_health.py').write_text(FAKE_HEALTH)
        # FQCN builtin URI를 우회하지 않도록 테스트용 복사본의 health task만 명시적으로 계측한다.
        roles = folder / 'roles'
        role = roles / 'vault-kubernetes-auth'
        shutil.copytree(ANSIBLE / 'roles/vault-kubernetes-auth', role, dirs_exist_ok=True)
        tasks = role / 'tasks/main.yml'
        tasks.write_text(tasks.read_text().replace('ansible.builtin.uri:', 'test_vault_health:'))
        ca = folder / 'public-ca.crt'
        ca.write_text('PUBLIC-VAULT-CA\n')
        play = folder / 'play.yml'
        play.write_text(json.dumps([{
            'hosts': 'localhost', 'connection': 'local', 'gather_facts': False,
            'vars': {
                'ansible_python_interpreter': sys.executable,
                'manager_context': 'test-only', 'vault_auth_configure_confirmed': True,
                'vault_public_ca_file': str(ca),
            },
            'roles': ['vault-kubernetes-auth'],
        }]))
        env = os.environ.copy()
        env.pop('VAULT_TOKEN', None)
        env.update({
            'PATH': str(folder) + os.pathsep + env['PATH'],
            'ANSIBLE_ROLES_PATH': str(roles),
            'ANSIBLE_LIBRARY': str(library),
            'ANSIBLE_LOCAL_TEMP': str(folder / 'local'),
            'ANSIBLE_REMOTE_TEMP': str(folder / 'remote'),
            'ANSIBLE_FORKS': '1', 'AUTH_TEST_STATE': str(statefile),
        })
        result = subprocess.run(
            [shutil.which('ansible-playbook'), '-i', 'localhost,', str(play)],
            cwd=ANSIBLE, env=env, capture_output=True, text=True, timeout=90)
        return result, json.loads(statefile.read_text())

    def test_both_service_roles_and_public_ca_are_idempotent_without_kv_writes(self):
        with tempfile.TemporaryDirectory() as folder:
            first, state = self.run_role(folder, {})
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
            self.assertEqual(len(state['writes']), 5)  # auth + policy/role × 2
            for service, namespace in [('backend', 'platform'), ('collector', 'data-system')]:
                role = state['records'][f'auth/onprem/role/{service}-db-sync']
                self.assertEqual(role['bound_service_account_namespaces'], [namespace])
                policy = state['records'][f'sys/policies/acl/{service}-db-read']['policy']
                self.assertIn(f'devoops/data/onprem/{namespace}/{service}-db', policy)
                self.assertNotIn('*', policy)
            self.assertEqual(sorted(state['ca_namespaces']), ['data-system', 'platform'])
            writes = list(state['writes'])
            second, state = self.run_role(folder, state)
            self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
            self.assertEqual(state['writes'], writes)
            self.assertTrue(all(not p.startswith('devoops/') for p in writes))

    def test_wrong_cluster_is_rejected_before_vault_writes(self):
        with tempfile.TemporaryDirectory() as folder:
            result, state = self.run_role(folder, {'api': 'https://wrong-cluster:6443'})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Refuse to configure authentication against another cluster', result.stdout)
            self.assertEqual(state.get('writes', []), [])

    def test_permission_denied_is_not_treated_as_missing_configuration(self):
        with tempfile.TemporaryDirectory() as folder:
            result, state = self.run_role(folder, {
                'mounts': {'onprem/': {'type': 'kubernetes'}}, 'deny_read': True})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('permission denied', result.stdout + result.stderr)
            self.assertEqual(state.get('writes', []), [])

    def test_existing_reviewer_configuration_is_not_silently_replaced(self):
        with tempfile.TemporaryDirectory() as folder:
            result, state = self.run_role(folder, {
                'mounts': {'onprem/': {'type': 'kubernetes'}},
                'records': {'auth/onprem/config': {'kubernetes_host': 'https://other:6443'}}})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Require explicit review before replacing existing auth configuration', result.stdout)
            self.assertEqual(state.get('writes', []), [])


if __name__ == '__main__':
    unittest.main()
