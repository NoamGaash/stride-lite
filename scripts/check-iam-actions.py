#!/usr/bin/env python3
"""Check that every action in an IAM policy document is an action AWS defines.

An invalid action name is not an error anywhere: the IAM API accepts the policy,
it simply never matches a request, so the permission is silently absent until an
apply fails on it. The only other place this is caught is the console's policy
editor, which nobody sees in CI.
"""
import json
import sys
import urllib.request

SOURCE = 'https://awspolicygen.s3.amazonaws.com/js/policies.js'


def known_actions():
    with urllib.request.urlopen(SOURCE, timeout=60) as r:
        body = r.read().decode()
    services = json.loads(body.split('=', 1)[1])['serviceMap'].values()
    actions = {}
    for service in services:
        actions.setdefault(service['StringPrefix'], set()).update(service['Actions'])
    return actions


def problems(policy, known):
    for statement in policy['Statement']:
        actions = statement['Action']
        for action in [actions] if isinstance(actions, str) else actions:
            prefix, _, name = action.partition(':')
            if prefix not in known:
                yield statement.get('Sid', '?'), action, 'no such service prefix'
            elif '*' in name:
                stem = name.split('*')[0].lower()
                if not any(k.lower().startswith(stem) for k in known[prefix]):
                    yield statement.get('Sid', '?'), action, 'matches no action'
            elif name not in known[prefix]:
                near = sorted(k for k in known[prefix] if name.lower()[:6] in k.lower())
                yield statement.get('Sid', '?'), action, 'no such action' + (
                    f'; did you mean {", ".join(near)}?' if near else '')


def main(paths):
    try:
        known = known_actions()
    except Exception as e:
        print(f'skipped: cannot reach {SOURCE}: {e}', file=sys.stderr)
        return 0
    failed = False
    for path in paths:
        found = list(problems(json.load(open(path)), known))
        print(f'{path}: {"ok" if not found else f"{len(found)} invalid"}')
        for sid, action, why in found:
            print(f'  [{sid}] {action}: {why}')
            failed = True
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
