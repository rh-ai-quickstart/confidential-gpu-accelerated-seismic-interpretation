#!/bin/bash
# Collect AMD SEV-SNP launch measurements from a temporary Kata confidential pod.
#
# Usage: collect-snp-measurements.sh [NAMESPACE [KATA_RUNTIME_CLASS]]
#   NAMESPACE          defaults to seismic-interpretation
#   KATA_RUNTIME_CLASS defaults to kata-cc-nvidia-gpu
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE=${1:-seismic-interpretation}
KATA_RUNTIME_CLASS=${2:-kata-cc-nvidia-gpu}
KBS_URL="https://kbs-service.trustee-operator-system.svc.cluster.local:8080"
PROBE_IMAGE="registry.access.redhat.com/ubi9/ubi-minimal:latest"
PROBE_POD="snp-measure-$$"
POLICY_FILE="${SCRIPT_DIR}/../policies/policy-dev.rego"

SNP_NODE=$(oc get nodes -l amd.feature.node.kubernetes.io/snp=true -o name 2>/dev/null | head -n1 || true)
if [ -z "$SNP_NODE" ]; then
  echo "ERROR: No node has the AMD SEV-SNP label amd.feature.node.kubernetes.io/snp=true." >&2
  echo "       Confirm SEV-SNP is enabled and Node Feature Discovery has labeled the node." >&2
  exit 1
fi

OSC_VERSION=$(oc get csv -n openshift-sandboxed-containers-operator \
  -o jsonpath='{.items[0].spec.version}' 2>/dev/null || true)
if [ -z "$OSC_VERSION" ]; then
  echo "WARNING: Could not determine OSC version (operator may not be installed)" >&2
  OSC_VERSION="unknown"
fi

echo "OpenShift Sandboxed Containers version: $OSC_VERSION"
echo "Collecting an AMD SEV-SNP report on $SNP_NODE"
echo ""

EVIDENCE_FILE=$(mktemp /tmp/snp-evidence.XXXXXX.json)
TOKEN_FILE=$(mktemp /tmp/snp-token.XXXXXX.json)
PROBE_MANIFEST=$(mktemp /tmp/snp-probe-XXXXXX.yaml)

cleanup() {
  rm -f "$EVIDENCE_FILE" "$TOKEN_FILE" "$PROBE_MANIFEST"
  echo "Deleting probe pod $PROBE_POD..."
  oc delete pod "$PROBE_POD" -n "$NAMESPACE" \
    --grace-period=0 --ignore-not-found 2>/dev/null || true
}
trap cleanup EXIT

if ! oc get secret trusteeconfig-https-cert-secret \
       -n trustee-operator-system &>/dev/null; then
  echo "ERROR: trusteeconfig-https-cert-secret not found in trustee-operator-system." >&2
  echo "       Run 'make setup-trustee-in-cluster' before collecting measurements." >&2
  exit 1
fi

if [ ! -f "$POLICY_FILE" ]; then
  echo "ERROR: Dev policy not found: $POLICY_FILE" >&2
  exit 1
fi

KBS_CERT=$(oc get secret trusteeconfig-https-cert-secret \
  -n trustee-operator-system \
  -o jsonpath='{.data.certificate}' | base64 -d)

# This probe uses the dev policy and omits the [image] table: it does not need
# the KBS image-policy resource to start its diagnostic container.
INITDATA=$(KBS_CERT="$KBS_CERT" KBS_URL="$KBS_URL" \
  python3 - "$POLICY_FILE" <<'PYTHON'
import base64, gzip, os, sys

kbs_url = os.environ['KBS_URL']
kbs_cert = os.environ['KBS_CERT']
with open(sys.argv[1]) as f:
    policy_rego = f.read()

aa_toml = f"""\
[token_configs]
[token_configs.coco_as]
url = "{kbs_url}"

[token_configs.kbs]
url = "{kbs_url}"
cert = \"\"\"
{kbs_cert}
\"\"\""""

cdh_toml = f"""\
socket = 'unix:///run/confidential-containers/cdh.sock'
credentials = []

[kbc]
name = "cc_kbc"
url = "{kbs_url}"
kbs_cert = \"\"\"
{kbs_cert}
\"\"\""""

toml = f"""\
algorithm = "sha256"
version = "0.1.0"

[data]
"aa.toml" = '''
{aa_toml}
'''

"cdh.toml" = '''
{cdh_toml}
'''

"policy.rego" = '''
{policy_rego}
'''
"""
print(base64.b64encode(gzip.compress(toml.encode())).decode(), end='')
PYTHON
)

if [ -z "$INITDATA" ]; then
  echo "ERROR: Failed to compute initdata blob." >&2
  exit 1
fi

echo "Launching temporary AMD SEV-SNP probe pod: $PROBE_POD"
cat > "$PROBE_MANIFEST" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${PROBE_POD}
  namespace: ${NAMESPACE}
  annotations:
    io.katacontainers.config.hypervisor.cc_init_data: "${INITDATA}"
    io.katacontainers.config.hypervisor.default_memory: "16384"
    io.katacontainers.config.hypervisor.kernel_params: "agent.guest_components_rest_api=all"
spec:
  runtimeClassName: ${KATA_RUNTIME_CLASS}
  restartPolicy: Never
  nodeSelector:
    amd.feature.node.kubernetes.io/snp: "true"
  containers:
  - name: probe
    image: ${PROBE_IMAGE}
    command: ["sleep", "120"]
    resources:
      requests:
        nvidia.com/pgpu: "1"
      limits:
        nvidia.com/pgpu: "1"
EOF
oc apply -f "$PROBE_MANIFEST"

echo "Waiting for probe pod to be ready (kata VMs can take up to 2 minutes)..."
oc wait pod "$PROBE_POD" -n "$NAMESPACE" \
  --for=condition=Ready --timeout=120s

echo "Querying AMD SEV-SNP attestation evidence..."
HTTP_STATUS=$(oc exec -n "$NAMESPACE" "$PROBE_POD" -c probe -- \
  curl -s -o /dev/null -w "%{http_code}" \
  "http://127.0.0.1:8006/aa/evidence?runtime_data=c25w" \
  2>/dev/null || echo "unreachable")

if [ "$HTTP_STATUS" != "200" ]; then
  echo "ERROR: /aa/evidence returned HTTP $HTTP_STATUS." >&2
  echo "       Confirm the Kata guest components REST API is enabled and the SNP probe pod started." >&2
  exit 1
fi

oc exec -n "$NAMESPACE" "$PROBE_POD" -c probe -- \
  curl -sf "http://127.0.0.1:8006/aa/evidence?runtime_data=c25w" \
  > "$EVIDENCE_FILE" 2>/dev/null

python3 - "$EVIDENCE_FILE" "$OSC_VERSION" "$NAMESPACE" <<'PYTHON'
import base64
import json
import sys

evidence_path, osc_version, namespace = sys.argv[1:]
with open(evidence_path) as f:
    raw = f.read().strip()
if not raw:
    raise SystemExit("ERROR: Empty response from AA evidence endpoint")

try:
    evidence = json.loads(raw)
except json.JSONDecodeError as exc:
    raise SystemExit(f"ERROR: Non-JSON response from AA: {raw[:500]}") from exc

report = evidence.get("attestation_report")
if not isinstance(report, dict):
    raise SystemExit(
        "ERROR: No attestation_report object in AA response. "
        f"Response keys: {list(evidence)}"
    )

measurement = report.get("measurement")
if isinstance(measurement, list):
    try:
        measurement_bytes = bytes(measurement)
    except (ValueError, TypeError) as exc:
        raise SystemExit(f"ERROR: Invalid byte array for report measurement: {exc}") from exc
elif isinstance(measurement, str):
    try:
        measurement_bytes = bytes.fromhex(measurement)
    except ValueError:
        try:
            measurement_bytes = base64.b64decode(measurement, validate=True)
        except Exception as exc:
            raise SystemExit("ERROR: Could not decode report measurement") from exc
else:
    raise SystemExit("ERROR: attestation_report has no supported measurement field")

if len(measurement_bytes) != 48:
    raise SystemExit(
        "ERROR: Expected the 48-byte SEV-SNP launch measurement, "
        f"got {len(measurement_bytes)} bytes"
    )

measurement_hex = measurement_bytes.hex()
reported_tcb = report.get("reported_tcb", {})

print("AMD SEV-SNP measurements:")
print(f"  measurement (hex):    {measurement_hex}")
print(f"  reported bootloader:  {reported_tcb.get('bootloader', 'unknown')}")
print(f"  reported TEE:         {reported_tcb.get('tee', 'unknown')}")
print(f"  reported SNP:         {reported_tcb.get('snp', 'unknown')}")
print(f"  reported microcode:   {reported_tcb.get('microcode', 'unknown')}")
print()
print(f"# SEV-SNP measurement (hex claim encoding; OSC {osc_version})")
print(f"SNP_MEASUREMENT ?= {measurement_hex}")
print(f"SNP_BOOTLOADER  ?= {reported_tcb.get('bootloader', '')}")
print(f"SNP_TEE_SVN      ?= {reported_tcb.get('tee', '')}")
print(f"SNP_SVN          ?= {reported_tcb.get('snp', '')}")
print(f"SNP_MICROCODE    ?= {reported_tcb.get('microcode', '')}")
print()
print("Register these values with Trustee RVPS:")
print(f"make set-rvps-values NAMESPACE={namespace} \\")
print(f"  SNP_MEASUREMENT={measurement_hex} \\")
print(f"  SNP_BOOTLOADER={reported_tcb.get('bootloader', '')} SNP_TEE_SVN={reported_tcb.get('tee', '')} \\")
print(f"  SNP_SVN={reported_tcb.get('snp', '')} SNP_MICROCODE={reported_tcb.get('microcode', '')}")
PYTHON

echo "Fetching EAR token to inspect the CPU and GPU attestation results..."
if oc exec -n "$NAMESPACE" "$PROBE_POD" -c probe -- \
     curl -sf --max-time 60 "http://127.0.0.1:8006/aa/token?token_type=kbs" \
     > "$TOKEN_FILE" 2>/dev/null && [ -s "$TOKEN_FILE" ]; then
  if ! python3 "${SCRIPT_DIR}/decode-ear-token.py" < "$TOKEN_FILE"; then
    echo "WARNING: Could not decode the EAR token; SNP measurement collection succeeded." >&2
  fi
else
  echo "WARNING: Could not fetch an EAR token; SNP measurement collection succeeded." >&2
  echo "         Check KBS/Trustee attestation and NRAS configuration for GPU appraisal." >&2
fi
