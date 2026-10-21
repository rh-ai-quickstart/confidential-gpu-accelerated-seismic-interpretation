#!/usr/bin/env python3
"""
Decode and pretty-print the cc_init_data blob that would be embedded in a pod.

Usage: show-initdata.py <KBS_URL> <NAMESPACE> [--policy-mode dev|locked]
                        [--app-image <repo>] [--model-image <repo>]
  Reads the KBS TLS certificate PEM from stdin.

Takes the same arguments as build-initdata.py so the output exactly reflects
what 'make install' would embed in the pod annotation.
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
parser.add_argument("--policy-mode", default="locked", choices=["dev", "locked"])
parser.add_argument("--app-image", default="")
parser.add_argument("--model-image", default="")
parsed = parser.parse_args()

kbs_url         = parsed.kbs_url
namespace       = parsed.namespace
policy_mode     = parsed.policy_mode
app_image_repo  = parsed.app_image.split(":")[0] if parsed.app_image else ""
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

toml_bytes   = toml.encode()
toml_hash    = hashlib.sha256(toml_bytes).hexdigest()
mr_config_id = (hashlib.sha256(toml_bytes).digest() + bytes(16)).hex()
encoded      = base64.b64encode(gzip.compress(toml_bytes)).decode()
encoded_kb   = len(encoded) / 1024

W = 72

def rule(char="─"):
    return char * W

def header(title):
    return f"── {title} {'─' * max(0, W - len(title) - 4)}"

print(rule("═"))
print(f" INITDATA  policy-mode={policy_mode}  namespace={namespace}")
print(rule("═"))
print()

for section_name, content in [("aa.toml", aa_toml), ("cdh.toml", cdh_toml), ("policy.rego", policy_rego)]:
    print(header(section_name))
    print(content)
    print()

print(rule())
print(f"  TOML SHA-256 : {toml_hash}")
print(f"  SNP init_data: {toml_hash}")
print(f"  mr_config_id : {mr_config_id}")
print(f"  Encoded size : {encoded_kb:.1f} KB  ({len(encoded)} chars base64)")
print(rule())
