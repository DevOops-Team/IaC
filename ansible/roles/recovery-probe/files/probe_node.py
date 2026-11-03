#!/usr/bin/env python3
"""Read-only Linux observations; no logs, secrets, system mutation or Kubernetes reset."""
import json
import shutil
import subprocess
import time
from pathlib import Path


def main():
    units = {}
    for name in ['containerd', 'kubelet']:
        cmd = ['systemctl', 'show', name + '.service', '--no-pager',
               '--property=LoadState,ActiveState,SubState,UnitFileState,Result']
        try:
            p = subprocess.run(cmd, text=True, capture_output=True, timeout=8)
            units[name] = dict(line.split('=', 1) for line in p.stdout.splitlines() if '=' in line)
        except (OSError, subprocess.TimeoutExpired):
            units[name] = {'LoadState': 'unknown'}
    mem = {}
    for line in Path('/proc/meminfo').read_text().splitlines():
        key, value = line.split(':', 1)
        if key in ['MemTotal', 'MemAvailable']:
            mem[key] = int(value.split()[0]) / 1024
    disks = []
    for path in ['/', '/var/lib/containerd', '/var/lib/kubelet', '/var/lib/etcd']:
        if Path(path).exists():
            usage = shutil.disk_usage(path)
            disks.append({'path': path, 'free_percent': usage.free / usage.total * 100})
    print(json.dumps({'captured_at': time.time(), 'units': units, 'disks': disks,
                      'memory_available_mb': mem.get('MemAvailable', 0),
                      'memory_total_mb': mem.get('MemTotal', 0)}))


if __name__ == '__main__':
    main()
