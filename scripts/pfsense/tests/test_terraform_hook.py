"""builtin provider만으로 실제 Terraform plan의 동기화 연결과 사전 조건을 검사한다."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]


@unittest.skipUnless(shutil.which('terraform'), 'Terraform CLI가 필요합니다.')
class TerraformHookTests(unittest.TestCase):
    def test_hook_and_missing_config_and_disabled_network(self):
        with tempfile.TemporaryDirectory(prefix='vpn hook test ') as temp:
            repo = Path(temp)/'repo'
            root = repo/'terraform/live/base'
            scripts = repo/'scripts/pfsense'
            stub = root/'vpc'
            stub.mkdir(parents=True)
            scripts.mkdir(parents=True)
            for name in ('sync_vpn.py', 'vpn-sync.php'):
                shutil.copyfile(REPO/'scripts/pfsense'/name, scripts/name)
            # 외부 접속 대신 실제 local-exec 인자·환경을 기록하는 드라이버.
            (scripts/'sync_vpn.py').write_text('import os,json,sys\nfrom pathlib import Path\nPath("hook-invocation.json").write_text(json.dumps({"args":sys.argv[1:],"settings":json.loads(os.environ["DEVOOPS_VPN_SYNC"])}),encoding="utf-8")\n')
            shutil.copyfile(REPO/'terraform/live/base/vpn-sync.tf', root/'vpn-sync.tf')
            (stub/'main.tf').write_text('output "vpn_connection_id" { value = "vpn-1234567890abcdef0" }\noutput "vpn_sync_revision" {\n value = "example-revision"\n sensitive = true\n}\n')
            (root/'main.tf').write_text('''variable "network_enabled" { default = true }
locals {
 cfg = { network = { enabled = var.network_enabled } }
 region = "us-east-2"
 account_id = "123456789012"
}
module "vpc" {
 source = "./vpc"
 count = var.network_enabled ? 1 : 0
}
''')
            def run(*args):
                return subprocess.run(['terraform', '-chdir='+str(root), *args], capture_output=True, text=True, encoding='utf-8', timeout=45)
            initialized = run('init', '-backend=false', '-input=false', '-no-color')
            self.assertEqual(initialized.returncode, 0, initialized.stderr)
            settings = root/'settings.json'
            variables = root/'inputs.tfvars.json'
            variables.write_text(json.dumps({'vpn_sync': {'config_path': str(settings), 'python_executable': sys.executable}}))
            missing = run('plan', '-input=false', '-no-color', '-var-file='+str(variables))
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn('scripts/pfsense/vpn-sync.example.json', missing.stderr)
            settings.write_text('{}')  # Terraform은 존재/해시만 검사, 실제 JSON 검증은 Python이 맡는다.
            plan = run('plan', '-input=false', '-no-color', '-var-file='+str(variables), '-out=hook.tfplan')
            self.assertEqual(plan.returncode, 0, plan.stderr)
            data = json.loads(run('show', '-json', 'hook.tfplan').stdout)
            changes = data['resource_changes']
            self.assertEqual([(r['address'], r['change']['actions']) for r in changes], [('terraform_data.vpn_sync[0]', ['create'])])
            self.assertEqual(changes[0]['change']['after']['triggers_replace']['vpn_id'], 'vpn-1234567890abcdef0')
            off = run('plan', '-input=false', '-no-color', '-var-file='+str(variables), '-var=network_enabled=false')
            self.assertEqual(off.returncode, 0, off.stderr)
            self.assertIn('No changes.', off.stdout)
            applied = run('apply', '-input=false', '-no-color', 'hook.tfplan')
            self.assertEqual(applied.returncode, 0, applied.stderr)
            invocation = json.loads((root/'hook-invocation.json').read_text(encoding='utf-8'))
            self.assertEqual(invocation['args'], ['terraform'])
            self.assertEqual(invocation['settings']['expected_account_id'], '123456789012')
            self.assertTrue(invocation['settings']['apply'])
            self.assertEqual(Path(invocation['settings']['config']).resolve(), settings.resolve())


if __name__ == '__main__':
    unittest.main()
