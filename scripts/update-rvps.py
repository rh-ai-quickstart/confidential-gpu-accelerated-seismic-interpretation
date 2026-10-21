#!/usr/bin/env python3
"""
Upsert RVPS reference values for OSC 1.13+ (BoT 1.2 format).

For OSC 1.13+ (Red Hat build of Trustee 1.2), the configmap key reference_value
stores a JSON object where each measurement name maps to a base64-encoded entry:

  {"name": "mr_td", "expiration": "2099-12-31T00:00:00Z", "value": ["hex..."]}

Usage: update-rvps.py <current_json> <initdata_binding_value> [--amd]
  current_json        - existing JSON content of the reference_value key ({} if empty)
  initdata_binding_value - TDX mr_config_id; ignored for AMD
  --amd               - register AMD SEV-SNP values instead of TDX values

TDX hardware measurements are read from the environment:
  TDX_MR_TD   - OVMF firmware measurement
  TDX_RTMR_1  - kata kernel + initrd measurement
  TDX_RTMR_2  - additional boot measurement
  TDX_XFAM    - QEMU CPU feature mask

AMD SEV-SNP reference values are read from:
  SNP_MEASUREMENT  - hex-encoded launch measurement from the Trustee claim
  SNP_INIT_DATA_HASH - SHA-256 initdata digest used as AMD SNP HOST_DATA
  SNP_BOOTLOADER  - reported bootloader SVN
  SNP_TEE_SVN      - reported TEE SVN
  SNP_SVN          - reported SNP SVN
  SNP_MICROCODE    - reported microcode version

Values absent from the environment are silently skipped.
Each named entry is appended if new; existing entries gain the new value
only if not already present (safe to run repeatedly).

Prints the updated JSON to stdout.
"""
import base64
import json
import os
import sys

EXPIRATION = "2099-12-31T00:00:00Z"


def decode_entry(b64str):
    padding = (4 - len(b64str) % 4) % 4
    return json.loads(base64.b64decode(b64str + '=' * padding).decode())


def encode_entry(entry):
    return base64.b64encode(json.dumps(entry, separators=(',', ':')).encode()).decode()


def upsert(entries, name, value):
    if value is None or value == '':
        return
    if name in entries:
        try:
            entry = decode_entry(entries[name])
        except Exception:
            entry = {"name": name, "expiration": EXPIRATION, "value": []}
        if value not in entry["value"]:
            entry["value"].append(value)
        entries[name] = encode_entry(entry)
    else:
        entry = {"name": name, "expiration": EXPIRATION, "value": [value]}
        entries[name] = encode_entry(entry)


def upsert_snp_measurement(entries, raw_value):
    if not raw_value:
        return
    try:
        measurement = bytes.fromhex(raw_value)
    except ValueError:
        print("ERROR: SNP_MEASUREMENT must be a 48-byte hex digest", file=sys.stderr)
        sys.exit(1)
    if len(measurement) != 48:
        print(
            f"ERROR: SNP_MEASUREMENT must be 96 hex characters, got {len(raw_value)}",
            file=sys.stderr,
        )
        sys.exit(1)

    name = 'snp_launch_measurement'
    value = measurement.hex()
    upsert(entries, name, value)


def upsert_snp_init_data(entries, raw_value):
    value = raw_value.strip().lower()
    if len(value) != 64:
        print(
            f"ERROR: SNP_INIT_DATA_HASH must be 64 hex characters, got {len(value)}",
            file=sys.stderr,
        )
        sys.exit(1)
    try:
        bytes.fromhex(value)
    except ValueError:
        print("ERROR: SNP_INIT_DATA_HASH must contain only hexadecimal characters", file=sys.stderr)
        sys.exit(1)
    upsert(entries, 'snp_init_data', value)


if len(sys.argv) not in (3, 4) or (len(sys.argv) == 4 and sys.argv[3] != "--amd"):
    print(f"Usage: {sys.argv[0]} <current_json> <mr_config_id_value> [--amd]", file=sys.stderr)
    sys.exit(1)

current_json, mr_config_id = sys.argv[1], sys.argv[2]
amd = len(sys.argv) == 4

entries = {}
if current_json.strip() and current_json.strip() != '{}':
    try:
        entries = json.loads(current_json)
    except Exception:
        entries = {}

if amd:
    upsert_snp_init_data(entries, os.environ.get('SNP_INIT_DATA_HASH', '').strip())
    upsert_snp_measurement(entries, os.environ.get('SNP_MEASUREMENT', '').strip())
    for rvps_name, env_name in (
        ('snp_bootloader', 'SNP_BOOTLOADER'),
        ('snp_tee_svn', 'SNP_TEE_SVN'),
        ('snp_snp_svn', 'SNP_SVN'),
        ('snp_microcode', 'SNP_MICROCODE'),
    ):
        raw_value = os.environ.get(env_name, '').strip()
        if raw_value:
            try:
                value = int(raw_value, 10)
            except ValueError:
                print(f"ERROR: {env_name} must be a decimal integer, got {raw_value!r}", file=sys.stderr)
                sys.exit(1)
            upsert(entries, rvps_name, value)
else:
    upsert(entries, 'mr_config_id', mr_config_id)
    upsert(entries, 'mr_td',        os.environ.get('TDX_MR_TD', ''))
    upsert(entries, 'xfam',         os.environ.get('TDX_XFAM', ''))
    upsert(entries, 'rtmr_0',       os.environ.get('TDX_RTMR_0', ''))
    upsert(entries, 'rtmr_1',       os.environ.get('TDX_RTMR_1', ''))
    upsert(entries, 'rtmr_2',       os.environ.get('TDX_RTMR_2', ''))
    upsert(entries, 'rtmr_3',       os.environ.get('TDX_RTMR_3', ''))
    upsert(entries, 'td_attributes', os.environ.get('TDX_TD_ATTRIBUTES', ''))
    upsert(entries, 'mr_seam',      os.environ.get('TDX_MR_SEAM', ''))

print(json.dumps(entries))
