<?php
define('DEVOOPS_VPN_SYNC_TEST', true);
require __DIR__.'/../vpn-sync.php';
function check_sync($condition, $message) { if (!$condition) throw new RuntimeException($message); }
function rejects_sync($s, $r) {
    try { vpn_plan($s, $r); } catch (RuntimeException $e) { return true; }
    return false;
}
$s = ['lan' => '172.30.0.2', 'frr_vip' => '_vip123', 'asn' => '65010', 'phase1' => [], 'phase2' => [], 'neighbors' => [], 'interfaces' => []];
$r = ['host' => '172.30.0.2', 'carp_vip' => '_vip123', 'tunnels' => []];
foreach ([1, 2] as $id) {
    $s['phase1'][] = ['ikeid' => (string)$id, 'interface' => '_vip123', 'descr' => 'AWS-Tunnel'.$id, 'iketype' => 'ikev2', 'lifetime' => '28800'];
    $s['phase2'][] = ['ikeid' => (string)$id, 'mode' => 'vti', 'localid' => ['netbits' => 30], 'remoteid' => ['netbits' => 30]];
    $s['neighbors'][] = ['updatesource' => 'opt'.$id, 'asnum' => '64512', 'password' => 'preserved-test-value'];
    $s['interfaces']['opt'.$id] = ['if' => 'ipsec'.$id];
    $r['tunnels'][] = ['outside' => '203.0.113.'.$id, 'local' => '169.254.'.$id.'.2', 'peer' => '169.254.'.$id.'.1', 'public' => '198.51.100.1', 'psk' => 'example_key_'.$id];
}
$original = $s;
$desired = vpn_plan($s, $r);
check_sync($s === $original, 'Planner must not mutate input.');
check_sync($desired['phase1'][0]['interface'] === '_vip123', 'CARP binding must stay intact.');
check_sync($desired['neighbors'][1]['password'] === 'preserved-test-value', 'Unmanaged neighbor fields must stay intact.');
check_sync($desired['phase2'][0]['localid']['netbits'] === 30, 'VTI mask must stay intact.');
check_sync($desired['phase1'][0]['remote-gateway'] === '203.0.113.1', 'New endpoint must be selected.');
check_sync(vpn_plan(array_replace($s, $desired), $r) === $desired, 'Second run must be idempotent.');
$drift = $s; $drift['phase1'][0]['interface'] = 'wan';
check_sync(rejects_sync($drift, $r), 'WAN-bound tunnel must not replace CARP.');
$drift = $s; $drift['phase1'][0]['disabled'] = '';
check_sync(rejects_sync($drift, $r), 'Disabled tunnel must not be enabled silently.');
$drift = $s; $drift['neighbors'][] = $drift['neighbors'][0];
check_sync(rejects_sync($drift, $r), 'Duplicate neighbor must block writing.');
$drift = $s; $drift['interfaces']['opt2']['if'] = 'ipsec9';
check_sync(rejects_sync($drift, $r), 'Unexpected interface assignment must block writing.');
$drift = $s; $drift['frr_vip'] = 'none';
check_sync(rejects_sync($drift, $r), 'FRR CARP drift must block writing.');
echo "11 VPN sync planner checks passed; no firewall configuration loaded.\n";
