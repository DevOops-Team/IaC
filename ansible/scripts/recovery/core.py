"""Pure decision functions shared by the watcher and offline tests."""
import json

SERVICES = ('containerd', 'kubelet')


def ready(node):
    return any(c.get('type') == 'Ready' and c.get('status') == 'True'
               for c in node.get('status', {}).get('conditions', []))


def classify(snapshot, expected, policy, now):
    result = {'code': 'HEALTHY', 'action': None, 'infrastructure_healthy': False,
              'pod_issues': [], 'details': []}
    for pod in (snapshot.get('pods') or {}).get('items', []):
        if pod.get('status', {}).get('phase') == 'Pending' and any(
                c.get('type') == 'PodScheduled' and c.get('status') == 'False'
                for c in pod.get('status', {}).get('conditions', [])):
            result['pod_issues'].append({'namespace':pod['metadata']['namespace'],
                'pod':pod['metadata']['name'], 'reason':'Unschedulable'})
        for c in pod.get('status', {}).get('initContainerStatuses', []) + pod.get('status', {}).get('containerStatuses', []):
            reason = c.get('state', {}).get('waiting', {}).get('reason')
            if reason in ['CrashLoopBackOff', 'ImagePullBackOff', 'ErrImagePull', 'CreateContainerConfigError']:
                result['pod_issues'].append({'namespace': pod['metadata']['namespace'],
                    'pod': pod['metadata']['name'], 'container': c['name'], 'reason': reason})
    result['pod_issues'] = result['pod_issues'][:50]
    if not snapshot.get('api_ready') or snapshot.get('nodes') is None or not snapshot.get('cluster_uid'):
        result['code'] = 'API_NETWORK_OR_AUTH_FAILURE'
        return result
    uid = policy.get('expected_cluster_uid')
    if uid and uid != snapshot['cluster_uid']:
        result['code'] = 'CLUSTER_IDENTITY_MISMATCH'
        return result
    nodes = {n['metadata']['name']: n for n in snapshot['nodes']['items']}
    if set(nodes) != set(expected):
        result['code'] = 'TOPOLOGY_MISMATCH'
        return result
    for name, host in expected.items():
        ips = {a['address'] for a in nodes[name]['status'].get('addresses', []) if a['type'] == 'InternalIP'}
        if host['ip'] not in ips:
            result['code'] = 'NODE_ADDRESS_MISMATCH'
            return result
    probes = snapshot.get('probes', {})
    for name in expected:
        p = probes.get(name, {})
        obs = p.get('observation', {})
        age = now - obs.get('captured_at', 0)
        if not p.get('reachable') or age < -30 or age > policy.get('max_probe_age_seconds', 300):
            result['code'] = 'SSH_OR_PROBE_UNAVAILABLE'
            return result
        if set(obs.get('units', {})) != set(SERVICES):
            result['code'] = 'INCOMPLETE_OBSERVATION'
            return result
        if not obs.get('disks') or obs.get('memory_total_mb', 0) <= 0:
            result['code'] = 'INCOMPLETE_OBSERVATION'
            return result
    unhealthy = [name for name, n in nodes.items() if not ready(n)]
    service_hosts = [name for name in expected if any(
        probes[name]['observation']['units'][u].get('ActiveState') != 'active' for u in SERVICES)]
    if any(c.get('status') == 'True' and c.get('type') in ['DiskPressure','MemoryPressure','PIDPressure']
           for n in nodes.values() for c in n['status'].get('conditions', [])):
        result['code'] = 'RESOURCE_PRESSURE'
        return result
    if not unhealthy and not service_hosts:
        result['infrastructure_healthy'] = True
        result['code'] = 'APP_WORKLOAD_ISSUE' if result['pod_issues'] else 'HEALTHY'
        return result
    if len(service_hosts) > 1 or len(unhealthy) > 1:
        result['code'] = 'MULTI_NODE_FAILURE'
        return result
    if len(service_hosts) != 1 or unhealthy != service_hosts:
        result['code'] = 'NODE_OR_CNI_FAILURE'
        return result
    name = service_hosts[0]
    node = nodes[name]
    obs = probes[name]['observation']
    if node.get('spec', {}).get('unschedulable') or node['metadata'].get('deletionTimestamp'):
        result['code'] = 'NODE_MAINTENANCE'
        return result
    if any(c.get('status') == 'True' and c.get('type') in ['DiskPressure', 'MemoryPressure', 'PIDPressure']
           for c in node['status'].get('conditions', [])):
        result['code'] = 'RESOURCE_PRESSURE'
        return result
    if (obs['memory_available_mb'] < policy.get('min_memory_mb', 256)
        or obs['memory_available_mb'] / obs['memory_total_mb'] < policy.get('min_memory_ratio', .05)
        or any(d['free_percent'] < policy.get('min_disk_free_percent', 10) for d in obs['disks'])):
        result['code'] = 'RESOURCE_PRESSURE'
        return result
    if expected[name]['control_plane'] and not policy.get('allow_control_plane_service_start', False):
        result['code'] = 'CONTROL_PLANE_REVIEW_REQUIRED'
        return result
    broken = []
    for unit in SERVICES:
        value = obs['units'][unit]
        if value.get('LoadState') != 'loaded':
            result['code'] = 'SERVICE_INSTALLATION_OR_CONFIG_FAILURE'
            return result
        if value.get('ActiveState') == 'active':
            continue
        if value.get('UnitFileState') != 'enabled' or value.get('ActiveState') not in ['inactive', 'failed']:
            result['code'] = 'SERVICE_DISABLED_OR_TRANSITIONING'
            return result
        broken.append(unit)
    result['code'] = 'CONFIRMED_SERVICE_STOP'
    result['action'] = {'host': name, 'services': broken}
    return result


def decide(result, state, policy, now, apply=False, maintenance=False):
    """Update confirmation/cooldown state; at most one node is ever a repair candidate."""
    state = dict(state)
    if result['infrastructure_healthy']:
        state['healthy_count'] = state.get('healthy_count', 0) + 1
        if state['healthy_count'] >= policy.get('confirmations', 3):
            state.update(circuit_open=False, signature=None, failure_count=0)
    else:
        state['healthy_count'] = 0
    action = result.get('action')
    signature = json.dumps(action, sort_keys=True) if action else None
    state['failure_count'] = state.get('failure_count', 0) + 1 if signature and state.get('signature') == signature else (1 if signature else 0)
    state['signature'] = signature
    if maintenance:
        state.update(signature=None, failure_count=0)
        return state, None, 'maintenance marker present'
    if not action:
        return state, None, 'no eligible service action'
    if not apply or not policy.get('auto_repair_enabled', False):
        return state, None, 'observe only'
    if not policy.get('expected_cluster_uid'):
        return state, None, 'expected cluster UID required for automatic repair'
    if state.get('circuit_open'):
        return state, None, 'circuit open; requires investigation or sustained healthy state'
    if state['failure_count'] < policy.get('confirmations', 3):
        return state, None, 'waiting for consecutive confirmations'
    if now - state.get('last_attempt', 0) < policy.get('cooldown_seconds', 1800):
        return state, None, 'repair cooldown'
    return state, action, 'eligible for one serialized repair'
