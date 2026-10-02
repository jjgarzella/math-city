#!/usr/bin/env python3
"""Five-day upstream status reminder; uses no agent or polecat slot."""
import argparse
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile

CITY = Path(__file__).resolve().parents[1]
RUNTIME = CITY / '.gc/runtime/upstream-folder-trust'
STATE = RUNTIME / 'state.json'
INTERVAL = dt.timedelta(days=5)


def timestamp(value):
    return value.astimezone(dt.timezone.utc).isoformat()


def save(value):
    fd, name = tempfile.mkstemp(dir=RUNTIME, prefix='.state-')
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, indent=2)
            stream.write('\n')
        os.replace(name, STATE)
    finally:
        if Path(name).exists():
            Path(name).unlink()


def github(endpoint):
    result = subprocess.run(['gh', 'api', 'repos/gastownhall/gascity/' + endpoint],
                            capture_output=True, text=True, check=True, timeout=20)
    return json.loads(result.stdout)


def snapshot():
    pr = github('pulls/6734')
    trust = github('issues/6713')
    hooks = github('issues/6464')
    return {
        'codex_trust_pr': {'url': pr['html_url'], 'state': pr['state'],
                           'merged': pr['merged'], 'merged_at': pr['merged_at'],
                           'merge_commit': pr['merge_commit_sha']},
        'trust_issue': {'url': trust['html_url'], 'state': trust['state']},
        'hook_review_issue': {'url': hooks['html_url'], 'state': hooks['state']},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--initialize', action='store_true')
    parser.add_argument('--preview', action='store_true', help='Read GitHub without sending mail or changing state')
    args = parser.parse_args()
    if args.preview:
        print(json.dumps(snapshot(), indent=2))
        return
    RUNTIME.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (RUNTIME / 'lock').open('a') as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        now = dt.datetime.now(dt.timezone.utc)
        if args.initialize:
            if not STATE.exists():
                save({'created_at': timestamp(now), 'next_check': timestamp(now + INTERVAL)})
            print(STATE.read_text())
            return
        state = json.loads(STATE.read_text())
        if now < dt.datetime.fromisoformat(state['next_check']):
            print('Next upstream folder-trust check: ' + state['next_check'])
            return
        current = snapshot()
        next_check = timestamp(now + INTERVAL)
        pr = current['codex_trust_pr']
        body = ('Scheduled five-day upstream folder-trust check.\n'
                f"Codex trust PR #6734: {pr['state']}, merged={pr['merged']}; {pr['url']}\n"
                f"Trust issue #6713: {current['trust_issue']['state']}; {current['trust_issue']['url']}\n"
                f"Hook-review issue #6464: {current['hook_review_issue']['state']}; {current['hook_review_issue']['url']}\n"
                f"Merge commit: {pr['merge_commit'] if pr['merged'] else 'not merged'}.\n"
                'Overseer direction: wait for upstream; no local backport or automatic install. '
                'Report the status to the overseer, and if fixed assess which upstream release contains it.\n'
                f'Next check: {next_check}.')
        subprocess.run(['gc', '--city', str(CITY), 'mail', 'send', 'gasvillage.mayor',
                        '-s', 'Five-day upstream folder-trust reminder', '-m', body],
                       check=True, timeout=60)
        state.update(last_checked=timestamp(now), next_check=next_check, result=current)
        save(state)
        print(body)


if __name__ == '__main__':
    main()
