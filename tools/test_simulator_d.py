#!/usr/bin/env python3
"""Opt-in exact-assigned-device D shutdown via an already-running GUI. Never boots/installs/launches/erases devices."""
import argparse
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--udid', required=True, help='One explicitly selected UDID from existing Zapas assignment')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--run', action='store_true')
    args = parser.parse_args()
    if not args.run:
        parser.error('Explicit --run is required')
    if not args.output.resolve().is_relative_to(ROOT / '.local') or not args.runtime.resolve().is_relative_to(ROOT / '.local'):
        parser.error('runtime/output must stay in repository .local')
    binary = args.app.resolve() / 'Contents/MacOS/zapas'
    environment = dict(os.environ, ZAPAS_RUNTIME=str(args.runtime.resolve()))
    checks = []
    def cli(*arguments, code=0):
        p = subprocess.run([str(binary), *arguments], env=environment, capture_output=True, text=True, timeout=50)
        assert p.returncode == code, (arguments, p.returncode, p.stdout, p.stderr)
        assert p.stderr == '' and len(p.stdout.splitlines()) == 1
        return json.loads(p.stdout)
    def inventory():
        p = subprocess.run(['/usr/bin/xcrun', 'simctl', 'list', 'devices', '-j'], capture_output=True, text=True, check=True, timeout=20)
        value = json.loads(p.stdout)
        assert sum(map(len, value['devices'].values())) <= 8, 'Inventory limit requires user decision; harness never removes devices'
        return value
    # Full inventory of ALL runtimes before acting, regardless of Booted state.
    before = inventory()
    assignment = json.loads((ROOT / '.local/simulator-assignment.json').read_text())
    assert assignment['project'] == 'Zapas' and args.udid in assignment['udids']
    listed = cli('simulators', 'list', '--json')
    selected = next(d for d in listed['data']['devices'] if d['device']['udid'] == args.udid)
    assert selected['assignmentVerified'] and selected['incarnation']
    assert selected['device']['isIOS'] and selected['device']['isAvailable'] and selected['device']['assignment'] == 'Zapas'
    assert selected['device']['state'] in ('Booted', 'Shutdown')
    checks.append('full_inventory_and_explicit_pinned_assignment')
    preview = cli('simulators', 'preview', '--selection', json.dumps(selected), '--json')
    plan = preview['data']['developmentPlan']
    assert plan['simulator'] == selected and plan['kind'] == 'simulatorShutdown'
    checks.append('exact_preview_with_impact')
    refusal = cli('simulators', 'apply', '--plan', plan['id'], '--json', code=2)
    assert refusal['errors'][0]['code'] == 'invalid_arguments'
    checks.append('missing_apply_refused')
    refusal = cli('debuggers', 'apply', '--plan', plan['id'], '--apply', '--json', code=1)
    assert refusal['errors'][0]['code'] == 'preview_expired_or_used'
    checks.append('wrong_kind_refused_without_consuming')
    applied = cli('simulators', 'apply', '--plan', plan['id'], '--apply', '--json')
    outcome = applied['data']['developmentOutcome']
    assert outcome['result']['status'] == 'confirmed', outcome
    if selected['device']['state'] == 'Shutdown':
        assert outcome['result']['issue']['code'] == 'device_already_shutdown'
        checks.append('already_shutdown_confirmed_without_command')
    else:
        checks.append('booted_to_shutdown_confirmed')
    after = inventory()
    current = next(d for group in after['devices'].values() for d in group if d['udid'] == args.udid)
    assert current['state'] == 'Shutdown'
    foreign_before = {d['udid']: (r, d['state'], d.get('dataPath')) for r, group in before['devices'].items() for d in group if d['udid'] != args.udid}
    foreign_after = {d['udid']: (r, d['state'], d.get('dataPath')) for r, group in after['devices'].items() for d in group if d['udid'] != args.udid}
    assert foreign_before == foreign_after, 'Concurrent external change or failed isolation observation; inspect local evidence'
    checks.append('all_unselected_devices_unchanged_in_observed_interval')
    result = cli('simulators', 'result', '--plan', plan['id'], '--json')
    assert result['data']['developmentOutcome'] == outcome
    cli('simulators', 'apply', '--plan', plan['id'], '--apply', '--json', code=1)
    checks.append('immutable_result_and_single_use')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(status='PASS', checks=checks, before=before, listed=listed, preview=preview, applied=applied, after=after), indent=2) + '\n')
    print(f'PASS: {len(checks)} checks, selected device only; raw evidence retained in .local')


if __name__ == '__main__':
    main()
