#!/usr/bin/env python3
"""Add the RVPS-backed AMD SNP initdata check to the CPU policy.

Trustee exposes the verified initdata digest as `input.init_data` to the CPU
attestation policy. The policy checks it against the `snp_init_data` RVPS
reference values at attestation time. With no registered reference value, the
check fails closed until one is registered.

Usage: patch-cpu-snp-init-data.py
Prints the updated ConfigMap JSON to stdout for `oc apply -f -`.
"""
import json
import subprocess
import sys

NAMESPACE = "trustee-operator-system"
CONFIGMAP = "trusteeconfig-attestation-policy-cpu"

OLD_CHECK = (
    '  input.snp.measurement in query_reference_value("snp_launch_measurement")\n'
    '}'
)
NEW_CHECK = (
    '  input.snp.measurement in query_reference_value("snp_launch_measurement")\n'
    '  # Bind AMD HOST_DATA to the expected initdata registered in RVPS.\n'
    '  input.init_data in query_reference_value("snp_init_data")\n'
    '}'
)
CHECK = 'input.init_data in query_reference_value("snp_init_data")'

result = subprocess.run(
    ["oc", "get", "configmap", CONFIGMAP, "-n", NAMESPACE, "-o", "json"],
    capture_output=True,
    text=True,
    check=True,
)
cm = json.loads(result.stdout)

rego = cm["data"]["default_cpu.rego"]
if CHECK in rego:
    print("INFO: SNP initdata RVPS check already present in policy — no change needed.", file=sys.stderr)
    print(json.dumps(cm))
    sys.exit(0)

if OLD_CHECK not in rego:
    print("ERROR: expected SNP measurement check not found in CPU policy.", file=sys.stderr)
    print(f"  Looking for:\n{OLD_CHECK}", file=sys.stderr)
    print("The upstream policy may have changed — review and update this script.", file=sys.stderr)
    sys.exit(1)

cm["data"]["default_cpu.rego"] = rego.replace(OLD_CHECK, NEW_CHECK, 1)
print(json.dumps(cm))
