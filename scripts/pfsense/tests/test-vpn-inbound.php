<?php
// php scripts/pfsense/tests/test-vpn-inbound.php
if (!defined('DEVOOPS_VPN_POLICY_TEST')) {
    define('DEVOOPS_VPN_POLICY_TEST', true);
    require __DIR__ . '/../vpn-inbound.php';
}
$desired = ['interface' => 'enc0', 'type' => 'pass', 'ipprotocol' => 'inet', 'protocol' => 'tcp',
    'source' => ['address' => '172.28.0.0/16'], 'destination' => ['any' => ''],
    'descr' => 'DevOops AWS VPN inbound TCP'];
$legacy = $desired;
$legacy['descr'] = '';
$legacy['tracker'] = '1794460813';
$original = $legacy;
function verify($condition, $message) {
    if (!$condition) throw new RuntimeException($message);
}
function rejects($rules, $desired) {
    try { plan_vpn_inbound($rules, $desired); } catch (RuntimeException $error) { return true; }
    return false;
}
verify(plan_vpn_inbound([$legacy], $desired)['operation'] === 'keep_existing', 'Legacy unnamed rule must be adopted.');
verify($legacy === $original, 'Existing rule metadata must not change.');
verify(plan_vpn_inbound([], $desired)['operation'] === 'append_rule', 'A missing rule must be planned.');
verify(rejects([$legacy, $legacy], $desired), 'Duplicates must require review.');
$disabled = $legacy;
$disabled['disabled'] = 'yes';
verify(rejects([$disabled], $desired), 'A disabled rule must not be bypassed by a new allow.');
$drift = $desired;
$drift['destination'] = ['address' => '172.30.0.40', 'port' => '9092'];
verify(rejects([$drift], $desired), 'Named scope drift must not be silently widened.');
$other = $legacy;
$other['interface'] = 'lan';
verify(plan_vpn_inbound([$other], $desired)['change'], 'A LAN rule is not an IPsec rule.');
$restricted = $legacy;
$restricted['destination']['port'] = '9092';
verify(plan_vpn_inbound([$restricted], $desired)['change'], 'A port-limited rule is not the reviewed all-port rule.');
echo "8 planner checks passed; no pfSense config loaded or changed.\n";
