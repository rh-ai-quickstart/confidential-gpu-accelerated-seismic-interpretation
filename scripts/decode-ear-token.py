#!/usr/bin/env python3
"""
Decode an EAR (Entity Attestation Report) JWT token from CDH and display trust claims
with a top-level summary of issues and full evidence details.

Reads the CDH /aa/token JSON response from stdin:
  {"token": "<JWT>", "tee_keypair": "..."}
Or accepts a raw JWT string directly.

Usage:
    curl -s http://127.0.0.1:8006/aa/token?token_type=kbs | python3 scripts/decode-ear-token.py

    # With expected TDX measurements for mismatch detection:
    ... | python3 scripts/decode-ear-token.py \
        --mr-td $TDX_MR_TD --xfam $TDX_XFAM \
        --rtmr-1 $TDX_RTMR_1 --rtmr-2 $TDX_RTMR_2

    # Or via environment variables (used by make debug-attestation):
    export TDX_MR_TD=... TDX_XFAM=... TDX_RTMR_1=... TDX_RTMR_2=...
    ... | python3 scripts/decode-ear-token.py
"""
import sys
import json
import base64
import os
import argparse

AFFIRMING_MIN = 2
AFFIRMING_MAX = 31

# Evidence keys that map to Makefile TDX_* variables
MEASUREMENT_KEYS = {
    'mr_td':  ('TDX_MR_TD',  '--mr-td'),
    'xfam':   ('TDX_XFAM',   '--xfam'),
    'rtmr_1': ('TDX_RTMR_1', '--rtmr-1'),
    'rtmr_2': ('TDX_RTMR_2', '--rtmr-2'),
}


def affirming(val):
    return isinstance(val, int) and AFFIRMING_MIN <= val <= AFFIRMING_MAX


def decode_jwt_payload(token):
    parts = token.split('.')
    if len(parts) != 3:
        raise ValueError(f"Expected 3-part JWT, got {len(parts)} parts")
    b64 = parts[1]
    b64 += '=' * ((4 - len(b64) % 4) % 4)
    return json.loads(base64.urlsafe_b64decode(b64))


def normalize_hex(val):
    return str(val).lower().lstrip('0x') if val else ''


def print_value(key, val, indent=8):
    """Print a key/value from evidence, pretty-printing nested dicts/lists."""
    prefix = ' ' * indent
    if isinstance(val, dict):
        print(f"{prefix}{key}:")
        for k, v in sorted(val.items()):
            print_value(k, v, indent + 2)
    elif isinstance(val, list):
        print(f"{prefix}{key}:")
        for item in val:
            print_value('', item, indent + 2)
    elif isinstance(val, str) and '\n' in val:
        # Multi-line string (e.g. PEM cert, Rego policy) — indent each line
        print(f"{prefix}{key}:")
        for line in val.splitlines():
            print(f"{prefix}  {line}")
    else:
        print(f"{prefix}{key:<30} {val}")


def find_nested(obj, key):
    """Recursively find the first value for a key in a nested dict/list."""
    if isinstance(obj, dict):
        if key in obj:
            return obj[key]
        for v in obj.values():
            result = find_nested(v, key)
            if result is not None:
                return result
    elif isinstance(obj, list):
        for item in obj:
            result = find_nested(item, key)
            if result is not None:
                return result
    return None


def collect_submod_data(sub, expected):
    """
    Return a dict describing a submod's claims, evidence, and any detected issues.
    """
    tv = sub.get('ear.trustworthiness-vector', {})
    status = sub.get('ear.status', 'unknown')

    ev = sub.get('ear.veraison.annotated-evidence', {})
    if isinstance(ev, str):
        try:
            ev = json.loads(ev)
        except Exception:
            ev = {}

    # Expand rtmr array form into rtmr_0 .. rtmr_3
    rtmr_arr = ev.get('rtmr')
    if isinstance(rtmr_arr, list):
        for i, r in enumerate(rtmr_arr):
            ev.setdefault(f'rtmr_{i}', r)

    issues = []

    # Check each trustworthiness vector claim
    for claim in ('executables', 'hardware', 'configuration'):
        val = tv.get(claim)
        if val is None or affirming(val):
            continue

        issue = {'claim': claim, 'value': val, 'details': []}

        if claim == 'hardware':
            tcb = find_nested(ev, 'tcb_status')
            if tcb:
                issue['details'].append(f"tcb_status = {tcb}")

        elif claim == 'executables':
            for key in ('mr_td', 'rtmr_0', 'rtmr_1', 'rtmr_2', 'rtmr_3', 'xfam'):
                actual = ev.get(key)
                if actual is None:
                    continue
                exp = expected.get(key, '')
                if exp:
                    match = normalize_hex(actual) == normalize_hex(exp)
                    tag = 'MATCH' if match else 'MISMATCH'
                    issue['details'].append(f"{key}")
                    issue['details'].append(f"  actual   = {actual}")
                    issue['details'].append(f"  expected = {exp}  [{tag}]")
                else:
                    issue['details'].append(f"{key} = {actual}")

        elif claim == 'configuration':
            for key in ('rtmr_3',):
                actual = ev.get(key)
                if actual is not None:
                    issue['details'].append(f"{key} = {actual}")

        issues.append(issue)

    return {
        'status': status,
        'tv': tv,
        'ev': ev,
        'issues': issues,
    }


def print_summary(all_data, verifier):
    total_issues = sum(len(d['issues']) for d in all_data.values())

    print(f"\n=== SUMMARY ===")
    print(f"Verifier: {verifier}")

    if total_issues == 0:
        print("Status:   ALL CLAIMS AFFIRMING — resource policy should allow key release.\n")
        return

    print(f"Status:   {total_issues} issue(s) found — resource policy will DENY key release.\n")

    n = 0
    for name, data in sorted(all_data.items()):
        for issue in data['issues']:
            n += 1
            claim = issue['claim']
            val = issue['value']
            print(f"  Issue {n}: [{name}] {claim} = {val}")
            for line in issue['details']:
                print(f"           {line}")
            print()


def print_evidence_section(name, data, expected):
    status = data['status']
    tv = data['tv']
    ev = data['ev']

    marker = 'OK  ' if status == 'affirming' else 'FAIL'
    print(f"  [{marker}] {name}  (status: {status})")

    print("    Trustworthiness vector:")
    for claim in ('executables', 'hardware', 'configuration'):
        val = tv.get(claim)
        if val is None:
            continue
        if affirming(val):
            label = 'affirming'
        else:
            label = 'NON-AFFIRMING  <-- blocking'
        print(f"        {claim:<22} {val:>3}  ({label})")

    nvidia = ev.get('nvidia', {})
    tdx_keys = [k for k in ev if k != 'nvidia']

    if tdx_keys:
        print("    CPU / TEE Evidence:")
        for key in sorted(tdx_keys):
            val = ev[key]
            exp = expected.get(key, '')
            prefix = '        '
            if key == 'tcb_status':
                note = '  <-- causes hardware=97' if val != 'UpToDate' else ''
                print(f"{prefix}{key:<30} {val}{note}")
            elif exp:
                match = normalize_hex(val) == normalize_hex(exp)
                tag = 'MATCH    ' if match else 'MISMATCH <--'
                print(f"{prefix}{key:<30} {val}")
                print(f"{prefix}{'':30} expected: {exp}  [{tag}]")
            else:
                print_value(key, val, indent=8)

    if nvidia and isinstance(nvidia, dict):
        print("    NVIDIA / GPU Evidence:")
        for key in sorted(nvidia.keys()):
            print_value(key, nvidia[key], indent=8)

    print()


def main():
    parser = argparse.ArgumentParser(description="Decode EAR JWT and show trust claims")
    parser.add_argument('--mr-td',  default=os.environ.get('TDX_MR_TD',  ''),
                        help='Expected MR_TD (or set TDX_MR_TD env var)')
    parser.add_argument('--xfam',   default=os.environ.get('TDX_XFAM',   ''),
                        help='Expected XFAM (or set TDX_XFAM env var)')
    parser.add_argument('--rtmr-1', default=os.environ.get('TDX_RTMR_1', ''),
                        help='Expected RTMR_1 (or set TDX_RTMR_1 env var)')
    parser.add_argument('--rtmr-2', default=os.environ.get('TDX_RTMR_2', ''),
                        help='Expected RTMR_2 (or set TDX_RTMR_2 env var)')
    args = parser.parse_args()

    expected = {
        'mr_td':  args.mr_td,
        'xfam':   args.xfam,
        'rtmr_1': args.rtmr_1,
        'rtmr_2': args.rtmr_2,
    }

    raw = sys.stdin.read().strip()
    if not raw:
        print("ERROR: empty input — CDH token endpoint may be unreachable", file=sys.stderr)
        sys.exit(1)

    try:
        data = json.loads(raw)
        token = data['token']
    except (json.JSONDecodeError, KeyError):
        token = raw

    try:
        claims = decode_jwt_payload(token)
    except Exception as e:
        print(f"ERROR: failed to decode JWT: {e}", file=sys.stderr)
        sys.exit(1)

    verifier = claims.get('ear.verifier-id', {}).get('build', 'unknown')

    submods = claims.get('submods', {})
    if not submods:
        print(f"\nVerifier: {verifier}")
        print("No submods found in token payload.")
        return

    all_data = {name: collect_submod_data(sub, expected) for name, sub in submods.items()}

    print_summary(all_data, verifier)

    print("=== DETAIL ===\n")
    for name in sorted(all_data):
        print_evidence_section(name, all_data[name], expected)


if __name__ == '__main__':
    main()
