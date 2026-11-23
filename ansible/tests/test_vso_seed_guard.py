"""실제 Ansible role을 가짜 kubectl로 실행한다. 클러스터·비밀값 접근 없음."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ANSIBLE = Path(__file__).resolve().parents[1]
TARGETS = ["platform/ghcr-pull", "data-system/ghcr-pull",
           "cert-manager/cloudflare-dns-api-token"]
FAKE_KUBECTL = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
a = sys.argv[1:]
scenario = json.loads(os.environ['VSO_TEST_SCENARIO'])
if 'customresourcedefinitions' in a:
    if scenario.get('discovery_error'):
        sys.exit(1)
    print(json.dumps({'items': [{'metadata': {'name': 'vaultstaticsecrets.secrets.hashicorp.com'}}]
                     if scenario.get('crd', True) else []}))
elif 'vaultstaticsecrets.secrets.hashicorp.com' in a:
    if scenario.get('list_error'):
        sys.exit(1)
    print(json.dumps({'items': [
        {'metadata': {'namespace': t.split('/')[0]},
         'spec': {'destination': {'name': t.split('/')[1], 'create': False}}}
        for t in scenario.get('protected', [])]}))
elif 'secret' in a and 'get' in a:
    if scenario.get('missing_secret'):
        sys.exit(1)
    print('secret/' + a[a.index('secret') + 1])
elif 'namespace' in a:
    print('namespace/present')
elif 'apply' in a:
    body = json.loads(sys.stdin.read())
    # 테스트라도 비밀값은 로그에 남기지 않는다.
    with open(os.environ['VSO_TEST_WRITES'], 'a') as f:
        f.write(body['metadata']['namespace'] + '/' + body['metadata']['name'] + '\n')
    print('configured')
else:
    sys.exit(2)
'''


class SeedGuardTests(unittest.TestCase):
    def run_role(self, scenario, explicit=None, credentials=True):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            stub = folder / 'kubectl'
            stub.write_text(FAKE_KUBECTL)
            stub.chmod(0o755)
            playbook = folder / 'playbook.yml'
            playbook.write_text(json.dumps([{
                'hosts': 'localhost', 'connection': 'local', 'gather_facts': False,
                'vars': {'manager_context': 'test-only',
                         'ansible_python_interpreter': sys.executable,
                         'gitops_vso_managed_secrets': explicit or []},
                'roles': ['gitops-secrets'],
            }]))
            writes = folder / 'writes'
            env = os.environ.copy()
            env.update({
                'PATH': str(folder) + os.pathsep + env['PATH'],
                'ANSIBLE_ROLES_PATH': str(ANSIBLE / 'roles'),
                'ANSIBLE_LOCAL_TEMP': str(folder / 'local'),
                'ANSIBLE_REMOTE_TEMP': str(folder / 'remote'),
                'ANSIBLE_FORKS': '1',
                'VSO_TEST_SCENARIO': json.dumps(scenario),
                'VSO_TEST_WRITES': str(writes),
            })
            for key in ['GHCR_USERNAME', 'GHCR_TOKEN', 'CLOUDFLARE_DNS_API_TOKEN']:
                env.pop(key, None)
                if credentials:
                    env[key] = 'fake-test-value'
            result = subprocess.run(
                [shutil.which('ansible-playbook'), '-i', 'localhost,', str(playbook)],
                cwd=ANSIBLE, env=env, capture_output=True, text=True, timeout=90)
            return result, writes.read_text().splitlines() if writes.exists() else []

    def test_existing_vso_destinations_are_not_written_without_bootstrap_credentials(self):
        result, writes = self.run_role({'protected': TARGETS}, credentials=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(writes, [])

    def test_no_vso_keeps_existing_bootstrap_behavior(self):
        result, writes = self.run_role({'crd': False})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sorted(writes), sorted(TARGETS))

    def test_mixed_ownership_only_writes_unmigrated_targets(self):
        result, writes = self.run_role({'protected': [TARGETS[2]]})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sorted(writes), sorted(TARGETS[:2]))

    def test_explicit_handoff_protects_values_when_crd_is_missing(self):
        result, writes = self.run_role({'crd': False}, explicit=TARGETS, credentials=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(writes, [])

    def test_api_discovery_error_never_falls_back_to_overwriting(self):
        result, writes = self.run_role({'discovery_error': True})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(writes, [])

    def test_vso_list_error_never_falls_back_to_overwriting(self):
        result, writes = self.run_role({'list_error': True})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(writes, [])

    def test_missing_handed_off_secret_fails_instead_of_reseeding(self):
        result, writes = self.run_role({'protected': TARGETS, 'missing_secret': True})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(writes, [])


if __name__ == '__main__':
    unittest.main()
