"""실제 AWS/SSH 없이 계정 경계·HA 순서·부분 실패 복구를 검증한다."""
import contextlib
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('sync_vpn', Path(__file__).parents[1]/'sync_vpn.py')
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


def vpn_fixture():
    tunnels = ''
    for number in (1, 2):
        tunnels += f'''<ipsec_tunnel><vpn_gateway><tunnel_outside_address><ip_address>203.0.113.{number}</ip_address></tunnel_outside_address><tunnel_inside_address><ip_address>169.254.{number}.1</ip_address></tunnel_inside_address></vpn_gateway><customer_gateway><tunnel_outside_address><ip_address>198.51.100.1</ip_address></tunnel_outside_address><tunnel_inside_address><ip_address>169.254.{number}.2</ip_address></tunnel_inside_address></customer_gateway><ike><pre_shared_key>example_key_{number}</pre_shared_key></ike></ipsec_tunnel>'''
    return {'CustomerGatewayConfiguration': '<vpn_connection>'+tunnels+'</vpn_connection>', 'Options': {'StaticRoutesOnly': False}}


class FakeAWS:
    def vpn(self, vpn_id):
        return {'VgwTelemetry': [{'Status': 'UP', 'AcceptedRouteCount': 1}] * 2}


class FakeFirewall:
    def __init__(self, host, role, events, changed=True, lose_response=False):
        self.host, self.role, self.events = host, role, events
        self.changed, self.lose_response = changed, lose_response
        self.request = {'tunnels': [{'peer': '169.254.1.1'}, {'peer': '169.254.2.1'}]}
        self.saved = False

    def rpc(self, mode, **fields):
        self.events.append((self.host, mode))
        if mode == 'apply' and self.changed:
            self.saved = True
            self.changed = False
            if self.lose_response:
                raise sync.SyncError('Response lost after write')
        if mode == 'restore':
            assert self.saved
            self.changed = True
        return {'host': self.host, 'role': self.role, 'changed': self.changed,
                'config_sha256': 'a'*64, 'bgpd_running': self.role == 'MASTER'}

    def bgp_ready(self, peers):
        return True


class SyncTests(unittest.TestCase):
    def test_xml_uses_both_tunnels_without_printing_keys(self):
        values = sync.tunnels_from_aws(vpn_fixture())
        self.assertEqual([v['peer'] for v in values], ['169.254.1.1', '169.254.2.1'])
        self.assertEqual(values[1]['public'], '198.51.100.1')

    def test_static_vpn_rejected(self):
        value = vpn_fixture()
        value['Options']['StaticRoutesOnly'] = True
        with self.assertRaises(sync.SyncError):
            sync.tunnels_from_aws(value)

    def test_malformed_secret_does_not_leak_to_error(self):
        value = vpn_fixture()
        value['CustomerGatewayConfiguration'] = value['CustomerGatewayConfiguration'].replace('example_key_1', 'PRIVATE-KEY-WITH-INVALID-CHARACTERS!')
        with self.assertRaises(sync.SyncError) as result:
            sync.tunnels_from_aws(value)
        self.assertNotIn('PRIVATE-KEY', str(result.exception))

    def test_shared_outside_address_rejected(self):
        value = vpn_fixture()
        value['CustomerGatewayConfiguration'] = value['CustomerGatewayConfiguration'].replace('203.0.113.2', '203.0.113.1')
        with self.assertRaises(sync.SyncError):
            sync.tunnels_from_aws(value)

    def run_pair(self, firewalls, apply=True):
        with patch.object(sync.time, 'sleep'), contextlib.redirect_stdout(io.StringIO()):
            sync.synchronize(FakeAWS(), 'vpn-abc', firewalls, apply, 30)

    def test_standby_updated_before_active(self):
        events = []
        pair = [FakeFirewall('a', 'MASTER', events), FakeFirewall('b', 'BACKUP', events)]
        self.run_pair(pair)
        self.assertEqual([host for host, mode in events if mode == 'apply'], ['b', 'a'])

    def test_no_changes_causes_no_restore_or_remote_mutation(self):
        events = []
        pair = [FakeFirewall('a', 'MASTER', events, False), FakeFirewall('b', 'BACKUP', events, False)]
        self.run_pair(pair)
        self.assertFalse(any(fw.saved for fw in pair))
        self.assertFalse(any(mode == 'restore' for _, mode in events))

    def test_plan_never_applies(self):
        events = []
        self.run_pair([FakeFirewall('a', 'MASTER', events), FakeFirewall('b', 'BACKUP', events)], False)
        self.assertEqual(events, [('a', 'plan'), ('b', 'plan')])

    def test_split_brain_blocks_all_writes(self):
        events = []
        with self.assertRaises(sync.SyncError):
            self.run_pair([FakeFirewall('a', 'MASTER', events), FakeFirewall('b', 'MASTER', events)])
        self.assertFalse(any(mode == 'apply' for _, mode in events))

    def test_response_loss_still_restores_both_in_reverse_order(self):
        events = []
        pair = [FakeFirewall('a', 'MASTER', events, lose_response=True), FakeFirewall('b', 'BACKUP', events)]
        with self.assertRaises(sync.SyncError):
            self.run_pair(pair)
        self.assertEqual([host for host, mode in events if mode == 'restore'], ['a', 'b'])

    def test_remote_errors_do_not_echo_payload(self):
        with patch.object(sync.subprocess, 'run', return_value=type('Result', (), {'returncode': 1, 'stderr': 'PRIVATE-PSK', 'stdout': ''})()):
            with self.assertRaises(sync.SyncError) as result:
                sync.command(['php'], body='PRIVATE-PSK')
            self.assertNotIn('PRIVATE-PSK', str(result.exception))


if __name__ == '__main__':
    unittest.main()
