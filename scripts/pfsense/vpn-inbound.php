<?php
// Sent through SSH stdin. Never print the full pfSense configuration.
function plan_vpn_inbound(array $rules, array $desired): array {
    $matches = [];
    foreach ($rules as $i => $rule) {
        // A named rule with a changed scope requires a separate review.
        $same = true;
        foreach (['interface', 'type', 'ipprotocol', 'protocol', 'source', 'destination'] as $key) {
            if (($rule[$key] ?? null) != $desired[$key]) $same = false;
        }
        $sameScope = $same;
        // Do not adopt disabled, floating, scheduled, or policy-routed rules.
        foreach (['disabled', 'floating', 'sched', 'gateway', 'tag', 'tagged'] as $key) {
            if (isset($rule[$key]) && $rule[$key] !== '') $same = false;
        }
        if ($sameScope && !$same) {
            throw new RuntimeException('An equivalent rule is disabled or has special controls. Review instead of bypassing it.');
        }
        if (($rule['descr'] ?? '') === $desired['descr'] && !$same) {
            throw new RuntimeException('The managed rule has drifted. Review it before changing scope.');
        }
        if ($same) $matches[] = $i;
    }
    if (count($matches) > 1) throw new RuntimeException('Duplicate equivalent rules found; review rule order first.');
    return ['change' => !$matches, 'operation' => $matches ? 'keep_existing' : 'append_rule',
        'existing_tracker' => $matches ? ($rules[$matches[0]]['tracker'] ?? null) : null];
}

// Pure planner can be tested without loading pfSense libraries.
if (defined('DEVOOPS_VPN_POLICY_TEST')) return;

try {
    $request = json_decode(base64_decode('__REQUEST__', true), true, 512, JSON_THROW_ON_ERROR);
    if (!in_array($request['mode'] ?? '', ['plan', 'apply'], true)) throw new RuntimeException('Use plan or apply.');
    $expected = json_decode(base64_decode('__POLICY__', true), true, 512, JSON_THROW_ON_ERROR);
    // This revision codifies the reviewed existing scope, not a generic rule editor.
    if ($expected !== [
        'interface' => 'enc0', 'type' => 'pass', 'ipprotocol' => 'inet', 'protocol' => 'tcp',
        'source' => ['address' => '172.28.0.0/16'], 'destination' => ['any' => ''],
        'descr' => 'DevOops AWS VPN inbound TCP'
    ]) throw new RuntimeException('Policy differs from the reviewed scope. Review the code and policy together.');

    require_once('config.inc');
    require_once('filter.inc');
    if (config_get_path('interfaces/lan/ipaddr') !== $request['host']) throw new RuntimeException('Unexpected firewall LAN address.');
    if (config_get_path('ipsec/filtermode', 'enc') !== 'enc') throw new RuntimeException('IPsec filtering is not on enc0.');
    $before = hash_file('sha256', '/cf/conf/config.xml');
    $rules = config_get_path('filter/rule', []);
    $plan = plan_vpn_inbound($rules, $expected);
    $result = ['mode' => $request['mode'], 'host' => $request['host'], 'plan' => $plan,
        'scope' => $expected, 'applied' => false];
    if ($request['mode'] === 'apply' && $plan['change']) {
        if (($request['expected_config_sha256'] ?? '') !== $before) throw new RuntimeException('Configuration changed since plan. Run plan again.');
        umask(0077);
        $directory = '/root/devoops-firewall-backups';
        if (!is_dir($directory) && !mkdir($directory, 0700)) throw new RuntimeException('Cannot create backup directory.');
        $backup = $directory . '/vpn-inbound-' . gmdate('Ymd-His') . '-' . bin2hex(random_bytes(4)) . '.xml';
        if (!copy('/cf/conf/config.xml', $backup) || !chmod($backup, 0600) || hash_file('sha256', $backup) !== $before) {
            throw new RuntimeException('Configuration backup failed.');
        }
        if (hash_file('sha256', '/cf/conf/config.xml') !== $before) throw new RuntimeException('Concurrent configuration edit detected.');
        // Existing rules and their order stay intact. Existing equivalent rules are never renamed.
        $expected['tracker'] = (string)time();
        $trackers = array_column($rules, 'tracker');
        while (in_array($expected['tracker'], $trackers)) $expected['tracker'] = (string)((int)$expected['tracker'] + 1);
        $rules[] = $expected;
        config_set_path('filter/rule', $rules);
        if (write_config('DevOops: preserve AWS VPN inbound TCP policy') === false) throw new RuntimeException('Configuration write failed.');
        filter_configure();
        $result['applied'] = true;
        $result['backup_on_firewall'] = $backup;
        $result['notice'] = 'Filter reload requested; verify live rules and connectivity before declaring success.';
    }
    $result['config_sha256'] = hash_file('sha256', '/cf/conf/config.xml');
    echo json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL;
} catch (Throwable $error) {
    fwrite(STDERR, $error->getMessage() . PHP_EOL);
    exit(1);
}
