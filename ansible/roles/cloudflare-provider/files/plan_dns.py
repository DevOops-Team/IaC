"""Plan one DNS-only record; refuse implicit takeover of an existing hostname."""
import ipaddress
import json
import sys


def plan(config):
    address = ipaddress.ip_address(config['ip'])
    if not address.is_global or address.is_multicast:
        raise ValueError('A globally routable public IP is required')
    ttl = int(config.get('ttl', 300))
    if not 60 <= ttl <= 86400:
        raise ValueError('TTL must be between 60 and 86400 seconds')
    desired = dict(type='A' if address.version == 4 else 'AAAA',
                   name=config['name'], content=str(address), proxied=False, ttl=ttl)
    records = config['records']
    if len(records) > 1:
        raise ValueError('Multiple records exist; reconcile them explicitly first')
    if not records:
        return dict(method='POST', suffix='', body=desired)
    old = records[0]
    if all(old.get(key) == value for key, value in desired.items()):
        return dict(method='NONE', suffix='', body=desired)
    if (not config.get('replace_id') or old['id'] != config['replace_id']
            or old['content'] != config.get('previous_content')):
        raise ValueError('Changing an existing record requires its ID and current content')
    # PATCH preserves unrelated record metadata and avoids deleting the old record first.
    return dict(method='PATCH', suffix='/' + old['id'], body=desired)


if __name__ == '__main__':
    try:
        print(json.dumps(plan(json.load(sys.stdin))))
    except (ValueError, KeyError) as exc:
        sys.exit(str(exc))
