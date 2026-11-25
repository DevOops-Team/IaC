#!/usr/bin/env python3
"""GPU-270: AWS VPN 정보를 두 pfSense에 반영한다. Python 표준 라이브러리만 사용."""
import argparse
import base64
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import uuid
import xml.etree.ElementTree as ET


class SyncError(RuntimeError):
    pass


def command(args, *, body=None, timeout=45):
    """실패한 원문에는 PSK가 있을 수 있으므로 stderr/인자를 예외에 넣지 않는다."""
    try:
        result = subprocess.run(args, input=body, capture_output=True, text=True,
                                encoding='utf-8', timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise SyncError('외부 명령 실행 실패 또는 시간 초과. 연결과 실행 파일을 확인하세요.') from None
    if result.returncode:
        raise SyncError('외부 명령 실패. AWS 인증·SSH 연결 또는 방화벽의 private 백업을 확인하세요.')
    return result.stdout


class AWS:
    def __init__(self, region):
        self.region = region

    def call(self, *args):
        raw = command(['aws', *args, '--region', self.region, '--output', 'json', '--no-cli-pager'])
        try:
            return json.loads(raw)
        except ValueError:
            raise SyncError('AWS CLI 응답이 올바른 JSON이 아닙니다.') from None

    def vpn(self, vpn_id):
        values = self.call('ec2', 'describe-vpn-connections', '--vpn-connection-ids', vpn_id)['VpnConnections']
        if len(values) != 1 or values[0]['VpnConnectionId'] != vpn_id or values[0]['State'] != 'available':
            raise SyncError('지정한 VPN이 available 상태가 아닙니다.')
        return values[0]


def tunnels_from_aws(vpn):
    if vpn.get('Options', {}).get('StaticRoutesOnly'):
        raise SyncError('BGP VPN만 지원합니다.')
    try:
        xml = ET.fromstring(vpn['CustomerGatewayConfiguration'])
        tunnels = []
        for item in xml.findall('ipsec_tunnel'):
            tunnel = {key: item.findtext(path) for key, path in {
                'outside': 'vpn_gateway/tunnel_outside_address/ip_address',
                'local': 'customer_gateway/tunnel_inside_address/ip_address',
                'peer': 'vpn_gateway/tunnel_inside_address/ip_address',
                'public': 'customer_gateway/tunnel_outside_address/ip_address',
                'psk': 'ike/pre_shared_key',
            }.items()}
            for key in ('outside', 'local', 'peer', 'public'):
                ipaddress.IPv4Address(tunnel[key])
            if not re.fullmatch(r'[A-Za-z0-9._]{8,64}', tunnel['psk'] or ''):
                raise ValueError()
            tunnels.append(tunnel)
        if len(tunnels) != 2 or len({t['outside'] for t in tunnels}) != 2:
            raise ValueError()
        return tunnels
    except (ValueError, TypeError, KeyError, ET.ParseError):
        raise SyncError('AWS 터널 구성 형식이 예상과 다릅니다. 원문을 로그에 출력하지 마세요.') from None


def read_settings(path):
    try:
        settings = json.loads(Path(path).expanduser().read_text(encoding='utf-8-sig'))
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', settings['jump_host']):
            raise ValueError()
        if not re.fullmatch(r'_vip[a-fA-F0-9]+', settings['carp_vip']):
            raise ValueError()
        if len(settings['firewalls']) != 2:
            raise ValueError()
        hosts = []
        for fw in settings['firewalls']:
            ipaddress.IPv4Address(fw['host'])
            if not re.fullmatch(r'SHA256:[A-Za-z0-9+/]{43}', fw['fingerprint']):
                raise ValueError()
            hosts.append(fw['host'])
        if len(set(hosts)) != 2:
            raise ValueError()
        for key in ('ssh_config', 'identity_file'):
            settings[key] = str(Path(settings[key]).expanduser().resolve(strict=True))
        if not 30 <= int(settings.get('timeout_seconds', 240)) <= 600:
            raise ValueError()
        return settings
    except (OSError, ValueError, KeyError, TypeError):
        raise SyncError('로컬 VPN 설정·SSH 경로·양쪽 콘솔 검증 지문을 확인하세요.') from None


class Firewall:
    def __init__(self, settings, fw, tunnels, directory):
        self.host = fw['host']
        self.settings = settings
        self.request = {'host': self.host, 'carp_vip': settings['carp_vip'], 'tunnels': tunnels}
        common = ['ssh', '-F', settings['ssh_config'], '-o', 'BatchMode=yes',
                  '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=10']
        scan = command(common + [settings['jump_host'],
                       'ssh-keyscan -T 5 -t ed25519 ' + self.host + ' 2>/dev/null'])
        keys = [line for line in scan.splitlines() if line.startswith(self.host + ' ssh-ed25519 ')]
        if len(keys) != 1:
            raise SyncError('방화벽 호스트 키를 하나로 확인하지 못했습니다.')
        try:
            digest = base64.b64encode(hashlib.sha256(base64.b64decode(keys[0].split()[2], validate=True)).digest()).decode().rstrip('=')
        except ValueError:
            raise SyncError('호스트 키 형식 오류.') from None
        if 'SHA256:' + digest != fw['fingerprint']:
            raise SyncError('방화벽 SSH 키가 콘솔 검증 지문과 다릅니다.')
        known = Path(directory) / self.host
        known.write_text(keys[0] + '\n', encoding='ascii')
        self.prefix = common + ['-J', settings['jump_host'], '-o', 'HostKeyAlgorithms=ssh-ed25519',
                               '-o', 'UserKnownHostsFile=' + str(known), '-o', 'IdentitiesOnly=yes',
                               '-i', settings['identity_file'], 'root@' + self.host]

    def rpc(self, mode, **fields):
        payload = dict(self.request, mode=mode, **fields)
        encoded = base64.b64encode(json.dumps(payload).encode()).decode()
        source = Path(__file__).with_name('vpn-sync.php').read_text(encoding='utf-8')
        raw = command(self.prefix + ['php'], body=source.replace('__REQUEST__', encoded), timeout=120)
        try:
            result = json.loads(raw)
            if result['host'] != self.host or result['role'] not in ('MASTER', 'BACKUP'):
                raise ValueError()
            return result
        except (ValueError, KeyError):
            raise SyncError('방화벽 응답 형식 오류. private 백업을 확인하세요.') from None

    def bgp_ready(self, peers):
        try:
            data = json.loads(command(self.prefix + ['/usr/local/bin/vtysh -c "show bgp ipv4 unicast summary json"']))
            family = data.get('ipv4Unicast', data)
            values = family.get('peers', {})
            return all(values.get(peer, {}).get('state') == 'Established'
                       and int(values[peer].get('pfxRcd', 0)) >= 1 for peer in peers)
        except (SyncError, ValueError, TypeError):
            return False


def pair_roles(plans):
    roles = [plan['role'] for plan in plans]
    if sorted(roles) != ['BACKUP', 'MASTER']:
        raise SyncError('MASTER 1대/BACKUP 1대가 아닙니다. 절체·분할 상태부터 확인하세요.')
    return roles.index('MASTER'), roles.index('BACKUP')


def synchronize(aws, vpn_id, firewalls, apply, timeout):
    initial = [fw.rpc('plan') for fw in firewalls]
    master, backup = pair_roles(initial)
    print(json.dumps({'mode': 'apply' if apply else 'plan', 'hosts': [
        {'host': fw.host, 'role': p['role'], 'changed': p['changed']} for fw, p in zip(firewalls, initial)]}), flush=True)
    if not apply:
        return
    receipts = []
    try:
        for index in (backup, master):
            # 주 XMLRPC가 대기의 설정을 변경할 수 있어 각 쓰기 직전 다시 읽는다.
            current = [fw.rpc('plan') for fw in firewalls]
            if pair_roles(current) != (master, backup):
                raise SyncError('동기화 중 CARP 역할이 바뀌었습니다.')
            receipt = uuid.uuid4().hex
            if current[index]['changed']:
                receipts.append((index, receipt))
            result = firewalls[index].rpc('apply', receipt=receipt, expected_config_sha256=current[index]['config_sha256'])
            if result.get('reload_failed'):
                raise SyncError('방화벽 서비스 재설정 실패.')
        deadline = time.monotonic() + timeout
        while True:
            final = [fw.rpc('plan') for fw in firewalls]
            if pair_roles(final) != (master, backup):
                raise SyncError('연결 검증 중 CARP 역할이 바뀌었습니다.')
            if any(p['changed'] for p in final):
                raise SyncError('양쪽 구성 불일치 또는 동시 변경이 발생했습니다.')
            if final[backup].get('bgpd_running'):
                raise SyncError('BACKUP 노드의 BGP가 활성화돼 있습니다. CARP 연동을 점검하세요.')
            telemetry = aws.vpn(vpn_id).get('VgwTelemetry', [])
            aws_ready = len(telemetry) == 2 and all(t['Status'] == 'UP' and int(t.get('AcceptedRouteCount', 0)) >= 1 for t in telemetry)
            peers = [t['peer'] for t in firewalls[master].request['tunnels']]
            if aws_ready and firewalls[master].bgp_ready(peers):
                print('VPN HA sync 완료: 양쪽 설정 일치, AWS 터널 2 UP, 활성 노드 BGP 경로 정상.', flush=True)
                return
            if time.monotonic() >= deadline:
                raise SyncError('VPN/BGP 연결 검증 시간 초과.')
            time.sleep(5)
    except Exception:
        failed = []
        for index, receipt in reversed(receipts):
            try:
                current = firewalls[index].rpc('plan')
                result = firewalls[index].rpc('restore', receipt=receipt, expected_config_sha256=current['config_sha256'])
                if result.get('reload_failed'):
                    raise SyncError('복구 뒤 서비스 재설정 실패')
            except Exception:
                failed.append(firewalls[index].host)
        if failed:
            raise SyncError('자동 복구 미완료: ' + ', '.join(failed) + '. /root/devoops-vpn-sync 백업을 점검하세요.') from None
        raise SyncError('VPN 동기화/연결 검증 실패. 이번 실행은 변경 전 중단되었거나 복구했으며 다음 단계는 중단합니다.') from None


def main():
    if sys.argv[1:] == ['terraform']:
        args = argparse.Namespace(**json.loads(os.environ['DEVOOPS_VPN_SYNC']))
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('--config', required=True)
        parser.add_argument('--vpn-id', required=True)
        parser.add_argument('--region', required=True)
        parser.add_argument('--expected-account-id', required=True)
        parser.add_argument('--apply', action='store_true')
        args = parser.parse_args()
    if not re.fullmatch(r'vpn-[0-9a-f]+', args.vpn_id) or not re.fullmatch(r'\d{12}', args.expected_account_id):
        raise SyncError('VPN ID 또는 계정 ID 형식 오류.')
    settings = read_settings(args.config)
    aws = AWS(args.region)
    if aws.call('sts', 'get-caller-identity')['Account'] != args.expected_account_id:
        raise SyncError('Terraform과 AWS CLI 계정이 다릅니다.')
    tunnels = tunnels_from_aws(aws.vpn(args.vpn_id))
    with tempfile.TemporaryDirectory(prefix='devoops-vpn-keys-') as directory:
        firewalls = [Firewall(settings, fw, tunnels, directory) for fw in settings['firewalls']]
        synchronize(aws, args.vpn_id, firewalls, args.apply, int(settings.get('timeout_seconds', 240)))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(str(error) if isinstance(error, SyncError) else 'VPN 동기화 실패. 입력/연결과 private 백업을 확인하세요.', file=sys.stderr)
        sys.exit(1)
