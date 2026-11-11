<?php
require_once('config.inc');
require_once('ipsec.inc');
require_once('/usr/local/pkg/frr.inc');
if (!function_exists('ipsec_configure') || !function_exists('frr_generate_config')) {
    fwrite(STDERR, 'Required pfSense apply functions are unavailable.' . PHP_EOL);
    exit(1);
}

function fail_lifecycle_vpn($message) {
    fwrite(STDERR, $message . PHP_EOL);
    exit(1);
}

$request = json_decode(base64_decode('__REQUEST__', true), true, 512, JSON_THROW_ON_ERROR);
$settings = $request['config'];
if (config_get_path('interfaces/lan/ipaddr') !== $settings['pfSenseHost'] ||
    config_get_path('gateways/defaultgw4') !== 'WANGW' ||
    (string)config_get_path('installedpackages/frrbgp/config/0/asnum') !== '65010') {
    fail_lifecycle_vpn('Unexpected primary pfSense LAN, gateway, or BGP ASN.');
}
$phase1 = config_get_path('ipsec/phase1', []);
$phase2 = config_get_path('ipsec/phase2', []);
$neighbors = config_get_path('installedpackages/frrbgpneighbors/config', []);
$interfaces = config_get_path('interfaces', []);
$indexes = [];
foreach ([1, 2] as $id) {
    $p1 = array_keys(array_filter($phase1, fn($p) => (string)$p['ikeid'] === (string)$id &&
        $p['interface'] === 'wan' && $p['iketype'] === 'ikev2' && $p['descr'] === 'AWS-Tunnel' . $id));
    $p2 = array_keys(array_filter($phase2, fn($p) => (string)$p['ikeid'] === (string)$id && $p['mode'] === 'vti'));
    $peers = array_keys(array_filter($neighbors, fn($p) =>
        $p['updatesource'] === 'opt' . $id && (string)$p['asnum'] === '64512'));
    if (count($p1) !== 1 || count($p2) !== 1 || count($peers) !== 1 ||
        ($interfaces['opt' . $id]['if'] ?? '') !== 'ipsec' . $id) {
        fail_lifecycle_vpn('AWS VPN tunnel or FRR interface differs from the reviewed topology.');
    }
    $indexes[] = [$p1[0], $p2[0], $peers[0]];
}
if ($request['operation'] === 'check') {
    echo json_encode(['topologyVerified' => true]);
    exit(0);
}
if ($request['operation'] === 'configure') {
    if (count($request['tunnels'] ?? []) !== 2) fail_lifecycle_vpn('Two AWS tunnels are required.');
    foreach ($request['tunnels'] as $i => $t) {
        foreach (['outside', 'local', 'peer', 'public'] as $key) {
            if (!filter_var($t[$key] ?? '', FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
                fail_lifecycle_vpn('Invalid AWS tunnel address.');
            }
        }
        if (!preg_match('/^[A-Za-z0-9._]{8,64}$/D', $t['psk'] ?? '')) fail_lifecycle_vpn('Invalid AWS tunnel key.');
        [$p1, $p2, $peer] = $indexes[$i];
        $phase1[$p1]['remote-gateway'] = $t['outside'];
        $phase1[$p1]['myid_data'] = $t['public'];
        $phase1[$p1]['pre-shared-key'] = $t['psk'];
        unset($phase1[$p1]['disabled']);
        $phase2[$p2]['localid']['address'] = $t['local'];
        $phase2[$p2]['remoteid']['address'] = $t['peer'];
        $neighbors[$peer]['peer'] = $t['peer'];
    }
} elseif ($request['operation'] === 'disable') {
    foreach ($indexes as [$p1, $p2, $peer]) $phase1[$p1]['disabled'] = true;
} else {
    fail_lifecycle_vpn('Unknown VPN operation.');
}
umask(0077);
$directory = '/root/devoops-vpn-backups';
if (!is_dir($directory) && !mkdir($directory, 0700)) fail_lifecycle_vpn('Cannot create VPN backup directory.');
$backup = $directory . '/lifecycle-' . date('Ymd-His') . '-' . bin2hex(random_bytes(3)) . '.xml';
if (!copy('/cf/conf/config.xml', $backup) || !chmod($backup, 0600) ||
    hash_file('sha256', $backup) !== hash_file('sha256', '/cf/conf/config.xml')) {
    fail_lifecycle_vpn('Cannot verify VPN configuration backup.');
}
config_set_path('ipsec/phase1', $phase1);
config_set_path('ipsec/phase2', $phase2);
config_set_path('installedpackages/frrbgpneighbors/config', $neighbors);
write_config('DevOops infrastructure lifecycle: ' . $request['operation'] . ' AWS tunnels');
ipsec_configure(true);
frr_generate_config();
echo json_encode(['updated' => true, 'backup' => $backup]);
