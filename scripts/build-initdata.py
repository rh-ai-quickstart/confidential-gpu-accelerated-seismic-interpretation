#!/usr/bin/env python3
"""
Build the cc_init_data blob for the kata VM.

Usage: build-initdata.py <KBS_URL> <NAMESPACE> [--mr-config-id]
                         [--init-data-hash]
                         [--policy-mode dev|locked]
                         [--app-image <repo>] [--model-image <repo>]
  Reads the KBS TLS certificate PEM from stdin.
  Default: prints the gzip+base64-encoded initdata TOML to stdout.
  --mr-config-id: prints the TDX mr_config_id hex value to stdout instead.
  --init-data-hash: prints the SHA-256 digest used as AMD SNP HOST_DATA.
  --policy-mode: selects scripts/policy-dev.rego or scripts/policy-locked.rego
                 (default: locked)
  --app-image / --model-image: image repo prefixes substituted into the locked
                 policy (required when --policy-mode=locked)

The initdata TOML contains three keys (aa.toml, cdh.toml, policy.rego).
Its SHA-256 hash is included in the TEE attestation report when hardware TEE
is present, binding the pod's KBS endpoint and image policy to the hardware
measurement.  On the dev cluster (no TEE) the hash is computed but not bound
to hardware; the binding activates when the pod moves to the bare metal cluster.

mr_config_id is the TDX hardware register that binds the quote to the initdata:
  SHA256(initdata_toml_bytes) zero-padded to 48 bytes (96 hex chars)
The Kata runtime places this value into the TDX quote's mr_config_id field.
Registering it in RVPS and checking it in the attestation policy prevents a pod
with different initdata (e.g. without the exec-deny policy) from receiving the key.
"""
import argparse
import base64
import gzip
import hashlib
import os
import sys

parser = argparse.ArgumentParser()
parser.add_argument("kbs_url")
parser.add_argument("namespace")
hash_group = parser.add_mutually_exclusive_group()
hash_group.add_argument("--mr-config-id", action="store_true")
hash_group.add_argument("--init-data-hash", action="store_true")
parser.add_argument("--policy-mode", default="locked", choices=["dev", "locked"])
parser.add_argument("--app-image", default="")
parser.add_argument("--model-image", default="")
parsed = parser.parse_args()

mr_config_id_only = parsed.mr_config_id
kbs_url = parsed.kbs_url
namespace = parsed.namespace
policy_mode = parsed.policy_mode
app_image_repo = parsed.app_image.split(":")[0] if parsed.app_image else ""
model_image_repo = parsed.model_image.split(":")[0] if parsed.model_image else ""

if policy_mode == "locked" and (not app_image_repo or not model_image_repo):
    print("Error: --app-image and --model-image are required when --policy-mode=locked", file=sys.stderr)
    sys.exit(1)

script_dir = os.path.dirname(os.path.abspath(__file__))
policy_file = os.path.join(script_dir, "..", "policies", f"policy-{policy_mode}.rego")
with open(policy_file) as f:
    policy_rego = f.read()

if policy_mode == "locked":
    policy_rego = policy_rego.replace("{app_image_repo}", app_image_repo)
    policy_rego = policy_rego.replace("{model_image_repo}", model_image_repo)

kbs_cert = sys.stdin.read().strip()

aa_toml = f"""\
[token_configs]
[token_configs.coco_as]
url = "{kbs_url}"

[token_configs.kbs]
url = "{kbs_url}"
cert = \"\"\"
{kbs_cert}
\"\"\"\
"""

cdh_toml = f"""\
socket = 'unix:///run/confidential-containers/cdh.sock'
credentials = []

[kbc]
name = "cc_kbc"
url = "{kbs_url}"
kbs_cert = \"\"\"
{kbs_cert}
\"\"\"

[image]
image_security_policy_uri = 'kbs:///default/{namespace}/image-policy'\
"""

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

toml_bytes = toml.encode()

toml_hash = hashlib.sha256(toml_bytes).digest()
if parsed.init_data_hash:
    print(toml_hash.hex(), end="")
elif mr_config_id_only:
    mr_config_id = (toml_hash + bytes(16)).hex()       # zero-pad to 48 bytes = 96 hex chars
    print(mr_config_id, end="")
else:
    print(base64.b64encode(gzip.compress(toml_bytes)).decode(), end="")
