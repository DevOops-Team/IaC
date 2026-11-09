import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('plan_dns', ROOT / 'ansible/roles/cloudflare-provider/files/plan_dns.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class DNSPlanTests(unittest.TestCase):
    def config(self, **changes):
        config = dict(ip='8.8.8.8', name='example.com', records=[])
        config.update(changes)
        return config

    def test_create_public_ipv4_dns_only(self):
        result = module.plan(self.config())
        self.assertEqual(result['method'], 'POST')
        self.assertEqual(result['body']['type'], 'A')
        self.assertIs(result['body']['proxied'], False)

    def test_ipv6(self):
        result = module.plan(self.config(ip='2606:4700:4700::1111'))
        self.assertEqual(result['body']['type'], 'AAAA')

    def test_private_and_invalid_ips_rejected(self):
        for ip in ['192.168.1.2', '127.0.0.1', '::1', 'invalid', '224.0.0.1']:
            with self.subTest(ip=ip), self.assertRaises(ValueError):
                module.plan(self.config(ip=ip))

    def test_idempotent(self):
        body = module.plan(self.config())['body']
        self.assertEqual(module.plan(self.config(records=[dict(body, id='abc')]))['method'], 'NONE')

    def test_tunnel_cutover_requires_matching_id_and_content(self):
        old = dict(id='abc', type='CNAME', name='example.com', content='old.cfargotunnel.com', proxied=True, ttl=1)
        for consent in [{}, dict(replace_id='wrong', previous_content=old['content']), dict(replace_id='abc', previous_content='wrong')]:
            with self.subTest(consent=consent), self.assertRaises(ValueError):
                module.plan(self.config(records=[old], **consent))
        result = module.plan(self.config(records=[old], replace_id='abc', previous_content=old['content']))
        self.assertEqual(result['method'], 'PATCH')
        self.assertEqual(result['suffix'], '/abc')
        self.assertEqual(result['body']['type'], 'A')

    def test_multiple_records_rejected(self):
        with self.assertRaises(ValueError):
            module.plan(self.config(records=[{}, {}]))

    def test_proxy_toggle_requires_confirmation(self):
        body = module.plan(self.config())['body']
        with self.assertRaises(ValueError):
            module.plan(self.config(records=[dict(body, id='abc', proxied=True)]))

    def test_bad_ttl(self):
        with self.assertRaises(ValueError):
            module.plan(self.config(ttl=0))


if __name__ == '__main__':
    unittest.main()
