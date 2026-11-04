"""Read-only check. No member removal, alarm clearing, service stop or restore."""
import json
import subprocess
import sys


def assess(health, alarm_free):
    good=[name for name,ok in health.items() if ok]
    if not alarm_free:
        return dict(state='CORRUPTION_OR_ALARM_REVIEW',healthy_members=len(good),operational=False)
    if len(health)!=3 or len(good)<2:
        return dict(state='QUORUM_NOT_CONFIRMED',healthy_members=len(good),operational=False)
    return dict(state='HEALTHY' if len(good)==3 else 'DEGRADED_ONE_MEMBER',
                healthy_members=len(good),operational=True)


def main():
    host,endpoints=sys.argv[1:]
    prefix=['/usr/local/bin/etcdctl','--dial-timeout=3s','--command-timeout=5s',
            '--cacert=/etc/ssl/etcd/ssl/ca.pem',
            '--cert=/etc/ssl/etcd/ssl/admin-'+host+'.pem',
            '--key=/etc/ssl/etcd/ssl/admin-'+host+'-key.pem']
    health={}
    for endpoint in endpoints.split(','):
        result=subprocess.run(prefix+['--endpoints='+endpoint,'endpoint','health','--write-out=json'],
                              text=True,capture_output=True,timeout=15)
        try:
            data=json.loads(result.stdout)
            health[endpoint]=result.returncode==0 and len(data)==1 and data[0].get('health') is True
        except (ValueError,TypeError,KeyError):
            health[endpoint]=False
    healthy=next((e for e,ok in health.items() if ok),None)
    alarm_free=False
    if healthy:
        result=subprocess.run(prefix+['--endpoints='+healthy,'alarm','list','--write-out=json'],
                              text=True,capture_output=True,timeout=15)
        try:
            alarms=json.loads(result.stdout)
            alarm_free=result.returncode==0 and isinstance(alarms,dict) and not alarms.get('alarms')
        except ValueError:
            pass
    report=assess(health,alarm_free)
    report['endpoints']=health
    print(json.dumps(report))
    return 0 if report['operational'] else 1


if __name__=='__main__':
    raise SystemExit(main())
