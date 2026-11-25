<?php
// GPU-270: SSH stdin으로만 전달한다. PSK와 전체 설정을 출력하지 않는다.
function vpn_sections(array $state): array {
    return array_intersect_key($state, array_flip(['phase1', 'phase2', 'neighbors']));
}
function vpn_digest(array $sections): string { return hash('sha256', json_encode($sections, JSON_THROW_ON_ERROR)); }
function vpn_plan(array $s, array $r): array {
    if (($s['lan'] ?? '') !== $r['host'] || ($s['frr_vip'] ?? '') !== $r['carp_vip']) {
        throw new RuntimeException('LAN address or FRR CARP binding differs from the reviewed topology.');
    }
    $desired = vpn_sections($s);
    if (count($r['tunnels'] ?? []) !== 2) throw new RuntimeException('Exactly two AWS tunnels are required.');
    foreach ($r['tunnels'] as $i => $t) {
        foreach (['outside', 'local', 'peer', 'public'] as $key) {
            if (!filter_var($t[$key] ?? '', FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) throw new RuntimeException('Invalid tunnel IPv4 address.');
        }
        if (!preg_match('/^[A-Za-z0-9._]{8,64}$/D', $t['psk'] ?? '')) throw new RuntimeException('Invalid tunnel key format.');
        $id = (string)($i + 1);
        $p1 = array_keys(array_filter($s['phase1'], fn($p) => (string)($p['ikeid'] ?? '') === $id));
        $p2 = array_keys(array_filter($s['phase2'], fn($p) => (string)($p['ikeid'] ?? '') === $id));
        $peers = array_keys(array_filter($s['neighbors'], fn($p) => ($p['updatesource'] ?? '') === 'opt'.$id));
        if (count($p1) !== 1 || count($p2) !== 1 || count($peers) !== 1) throw new RuntimeException('Missing or duplicate managed tunnel/neighbor.');
        [$a, $b, $c] = [$p1[0], $p2[0], $peers[0]];
        if (($s['phase1'][$a]['interface'] ?? '') !== $r['carp_vip'] ||
            ($s['phase1'][$a]['descr'] ?? '') !== 'AWS-Tunnel'.$id ||
            ($s['phase1'][$a]['iketype'] ?? '') !== 'ikev2' || isset($s['phase1'][$a]['disabled']) ||
            ($s['phase2'][$b]['mode'] ?? '') !== 'vti' || isset($s['phase2'][$b]['disabled']) ||
            ($s['interfaces']['opt'.$id]['if'] ?? '') !== 'ipsec'.$id ||
            (string)($s['neighbors'][$c]['asnum'] ?? '') !== '64512' || (string)($s['asn'] ?? '') !== '65010') {
            throw new RuntimeException('Managed topology changed or is disabled; review before updating.');
        }
        $desired['phase1'][$a]['remote-gateway'] = $t['outside'];
        $desired['phase1'][$a]['myid_data'] = $t['public'];
        $desired['phase1'][$a]['pre-shared-key'] = $t['psk'];
        $desired['phase2'][$b]['localid']['address'] = $t['local'];
        $desired['phase2'][$b]['remoteid']['address'] = $t['peer'];
        $desired['neighbors'][$c]['peer'] = $t['peer'];
    }
    return $desired;
}
if (defined('DEVOOPS_VPN_SYNC_TEST')) return;

ob_start();
try {
    $r = json_decode(base64_decode('__REQUEST__', true), true, 512, JSON_THROW_ON_ERROR);
    if (!in_array($r['mode'] ?? '', ['plan', 'apply', 'restore'], true)) throw new RuntimeException('Unknown operation.');
    require_once('config.inc');
    require_once('ipsec.inc');
    require_once('/usr/local/pkg/frr.inc');
    if (!function_exists('ipsec_configure') || !function_exists('frr_generate_config')) throw new RuntimeException('Required pfSense functions are missing.');
    $s = [
        'lan' => config_get_path('interfaces/lan/ipaddr'),
        'frr_vip' => config_get_path('installedpackages/frr/config/0/carpstatusvid'),
        'asn' => config_get_path('installedpackages/frrbgp/config/0/asnum'),
        'interfaces' => config_get_path('interfaces', []),
        'phase1' => config_get_path('ipsec/phase1', []),
        'phase2' => config_get_path('ipsec/phase2', []),
        'neighbors' => config_get_path('installedpackages/frrbgpneighbors/config', []),
    ];
    $before = vpn_sections($s);
    $desired = vpn_plan($s, $r); // restore도 대상/형태를 먼저 검증한다.
    $sha = hash_file('sha256', '/cf/conf/config.xml');
    $carp = shell_exec('/sbin/ifconfig vtnet1');
    if (!preg_match('/carp: (MASTER|BACKUP) vhid 1/', $carp, $role)) throw new RuntimeException('CARP role is ambiguous.');
    $result = ['host' => $r['host'], 'role' => $role[1], 'changed' => $desired != $before,
        'config_sha256' => $sha, 'section_sha256' => vpn_digest($before),
        'bgpd_running' => trim((string)shell_exec('/bin/pgrep -x bgpd')) !== ''];
    $directory = '/root/devoops-vpn-sync';
    if ($r['mode'] === 'restore') {
        $name = $r['receipt'] ?? '';
        if (!preg_match('/^[a-f0-9]{32}$/D', $name)) throw new RuntimeException('Invalid rollback receipt.');
        if (!is_file($directory.'/'.$name.'.json')) {
            // 이 실행은 설정을 쓰기 전에 실패했다. 다른 실행의 백업을 대신 쓰지 않는다.
            $result['changed'] = false;
            ob_end_clean();
            echo json_encode($result, JSON_THROW_ON_ERROR).PHP_EOL;
            exit(0);
        }
        $saved = json_decode(file_get_contents($directory.'/'.$name.'.json'), true, 512, JSON_THROW_ON_ERROR);
        if (vpn_digest($before) !== $saved['after'] && vpn_digest($before) !== vpn_digest($saved['before'])) throw new RuntimeException('Managed sections changed; automatic rollback stopped to preserve concurrent edits.');
        $desired = $saved['before'];
        $result['changed'] = $desired != $before;
    }
    if ($r['mode'] !== 'plan' && $result['changed']) {
        if (($r['expected_config_sha256'] ?? '') !== $sha) throw new RuntimeException('Configuration changed since planning; re-plan.');
        umask(0077);
        if (!is_dir($directory) && !mkdir($directory, 0700)) throw new RuntimeException('Cannot create private backup directory.');
        $receipt = $r['mode'] === 'apply' ? ($r['receipt'] ?? '') : bin2hex(random_bytes(16));
        if (!preg_match('/^[a-f0-9]{32}$/D', $receipt) || file_exists($directory.'/'.$receipt.'.json')) throw new RuntimeException('Invalid or reused operation receipt.');
        if (!copy('/cf/conf/config.xml', $directory.'/'.$receipt.'.xml') ||
            hash_file('sha256', $directory.'/'.$receipt.'.xml') !== $sha) throw new RuntimeException('Backup verification failed.');
        chmod($directory.'/'.$receipt.'.xml', 0600);
        if (file_put_contents($directory.'/'.$receipt.'.json', json_encode(['before' => $before, 'after' => vpn_digest($desired)], JSON_THROW_ON_ERROR), LOCK_EX) === false) throw new RuntimeException('Private receipt write failed.');
        chmod($directory.'/'.$receipt.'.json', 0600);
        if (hash_file('sha256', '/cf/conf/config.xml') !== $sha) throw new RuntimeException('Concurrent configuration edit detected.');
        config_set_path('ipsec/phase1', $desired['phase1']);
        config_set_path('ipsec/phase2', $desired['phase2']);
        config_set_path('installedpackages/frrbgpneighbors/config', $desired['neighbors']);
        if (write_config('DevOops VPN HA sync '.$r['mode']) === false) throw new RuntimeException('Configuration write failed; inspect private backup.');
        // 호출자가 쓰기 전부터 알고 있는 receipt로 응답 손실 때도 복구할 수 있다.
        $result['receipt'] = $receipt;
        $result['section_sha256'] = vpn_digest($desired);
        $result['config_sha256'] = hash_file('sha256', '/cf/conf/config.xml');
        try {
            ipsec_configure(true);
            frr_generate_config(); // CARP 연동을 보존하고 BACKUP을 강제로 활성화하지 않는다.
        } catch (Throwable $error) {
            $result['reload_failed'] = true;
        }
    }
    ob_end_clean();
    echo json_encode($result, JSON_THROW_ON_ERROR).PHP_EOL;
} catch (Throwable $error) {
    ob_end_clean();
    // 입력·설정 원문을 예외에 포함하지 않아 PSK가 에러 로그로 유출되지 않게 한다.
    fwrite(STDERR, $error instanceof RuntimeException ? $error->getMessage().PHP_EOL : "VPN sync failed; inspect private firewall backup.\n");
    exit(1);
}
