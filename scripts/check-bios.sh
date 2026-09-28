#!/bin/bash
# Validate BIOS/firmware settings required for Confidential Containers.
# Runs checks via SSH to the node or via oc debug.
# Returns 0 if all checks pass, 1 if any fail.
#
# Usage:
#   bash check-bios.sh                  # auto-detect TEE type from CPU vendor
#   TEE_TYPE=tdx bash check-bios.sh     # force Intel TDX checks
#   TEE_TYPE=snp bash check-bios.sh     # force AMD SEV-SNP checks

TEE_TYPE=${TEE_TYPE:-""}
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

print_result() {
  local label="$1"
  local detail="$2"
  local status="$3"
  printf "  %-50s [%s]\n" "$label: $detail" "$status"
  case "$status" in
    OK)   PASS_COUNT=$((PASS_COUNT + 1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    WARN) WARN_COUNT=$((WARN_COUNT + 1)) ;;
  esac
}

run_on_node() {
  if [[ -n "$NODE_SSH" ]]; then
    ssh -q -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$NODE_SSH" "$1" 2>/dev/null
  else
    oc debug node/"$NODE_NAME" -- chroot /host bash -c "$1" 2>/dev/null
  fi
}

echo ""
echo "=== CoCo BIOS/Hardware Preflight ==="

NODE_NAME=$(oc get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$NODE_NAME" ]]; then
  echo "  ERROR: Cannot get node name. Are you logged in to OpenShift?"
  exit 1
fi

HOST_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
if ssh -q -o ConnectTimeout=3 -o StrictHostKeyChecking=no core@"$HOST_IP" true 2>/dev/null; then
  NODE_SSH="core@$HOST_IP"
fi

BIOS_VERSION=$(run_on_node "sudo dmidecode -s bios-version")
BIOS_DATE=$(run_on_node "sudo dmidecode -s bios-release-date")
CPU_VENDOR=$(run_on_node "grep -m1 vendor_id /proc/cpuinfo | awk '{print \$3}'")
CPU_FLAGS=$(run_on_node "grep -m1 flags /proc/cpuinfo")
KERNEL_LOG=$(run_on_node "sudo journalctl -k")
KERNEL_CMDLINE=$(run_on_node "cat /proc/cmdline")

echo "  CPU: ${CPU_VENDOR:-unknown}"
echo "  BIOS: ${BIOS_VERSION:-unknown} (${BIOS_DATE:-unknown})"
echo ""

if [[ -z "$TEE_TYPE" ]]; then
  case "$CPU_VENDOR" in
    GenuineIntel) TEE_TYPE="tdx" ;;
    AuthenticAMD) TEE_TYPE="snp" ;;
    *) echo "  ERROR: Unknown CPU vendor '$CPU_VENDOR', set TEE_TYPE manually"; exit 1 ;;
  esac
fi

if run_on_node "[ -d /sys/firmware/efi ]"; then
  print_result "Boot mode" "UEFI" "OK"
else
  print_result "Boot mode" "Legacy BIOS (UEFI required)" "FAIL"
fi

if echo "$CPU_FLAGS" | grep -qw "vmx\|svm"; then
  print_result "Virtualization" "CPU flags present" "OK"
else
  print_result "Virtualization" "vmx/svm not in CPU flags" "FAIL"
fi

LSMOD=$(run_on_node "lsmod")

if [[ "$TEE_TYPE" == "tdx" ]]; then
  if echo "$KERNEL_CMDLINE" | grep -q "intel_iommu=on"; then
    print_result "IOMMU" "enabled (kernel cmdline)" "OK"
  else
    print_result "IOMMU" "intel_iommu=on not in cmdline" "WARN"
  fi

  TME_STATUS=$(echo "$KERNEL_LOG" | grep "x86/tme:" | head -1)
  if echo "$TME_STATUS" | grep -q "enabled by BIOS"; then
    print_result "TME" "enabled by BIOS" "OK"
  else
    print_result "TME" "not enabled by BIOS" "FAIL"
  fi

  MKTME_STATUS=$(echo "$KERNEL_LOG" | grep "x86/mktme:" | head -2)
  MKTME_KEYS=$(echo "$MKTME_STATUS" | grep -oP '\d+ KeyIDs' | awk '{print $1}')
  if echo "$MKTME_STATUS" | grep -q "enabled by BIOS"; then
    print_result "MKTME" "enabled by BIOS (${MKTME_KEYS:-0} KeyIDs)" "OK"
  elif echo "$MKTME_STATUS" | grep -q "disabled by BIOS"; then
    print_result "MKTME" "disabled by BIOS" "FAIL"
  else
    print_result "MKTME" "not detected" "FAIL"
  fi

  if echo "$KERNEL_LOG" | grep -q "x86/mktme: No known encryption algorithm"; then
    print_result "CPU PA limit" "MKTME algorithm reports 0x0 (check LimitCPUPAto46bits)" "FAIL"
  else
    print_result "CPU PA limit" "unrestricted" "OK"
  fi

  TDX_BIOS=$(echo "$KERNEL_LOG" | grep "virt/tdx:" | head -1)
  TDX_KEYID_RANGE=$(echo "$TDX_BIOS" | grep -oP 'private KeyID range \[[0-9]+, [0-9]+\)')
  if echo "$TDX_BIOS" | grep -q "BIOS enabled"; then
    print_result "TDX" "BIOS enabled, $TDX_KEYID_RANGE" "OK"
  elif echo "$KERNEL_LOG" | grep -q "no TDX private KeyIDs"; then
    print_result "TDX" "no private KeyIDs available" "FAIL"
  else
    print_result "TDX" "not detected in kernel journal" "FAIL"
  fi

  if echo "$CPU_FLAGS" | grep -qw "sgx"; then
    print_result "SGX" "enabled (CPU flag present)" "OK"
  else
    print_result "SGX" "not detected (required for TDX attestation)" "FAIL"
  fi

  if echo "$LSMOD" | grep -q "kvm_intel"; then
    TDX_PARAM=$(run_on_node "cat /sys/module/kvm_intel/parameters/tdx 2>/dev/null")
    if [[ "$TDX_PARAM" == "Y" ]]; then
      print_result "kvm_intel" "loaded (tdx=Y)" "OK"
    else
      print_result "kvm_intel" "loaded but tdx=${TDX_PARAM:-N}" "FAIL"
    fi
  else
    if echo "$KERNEL_LOG" | grep -q "no TDX private KeyIDs"; then
      print_result "kvm_intel" "not loaded (no TDX KeyIDs — check BIOS)" "FAIL"
    else
      print_result "kvm_intel" "not loaded" "FAIL"
    fi
  fi

  TDX_MODULE=$(echo "$KERNEL_LOG" | grep "TDX module" | sed 's/.*TDX module //')
  TDX_INIT=$(echo "$KERNEL_LOG" | grep -c "tdx: module initialized")
  if [[ -n "$TDX_MODULE" ]]; then
    TDX_VER=$(echo "$TDX_MODULE" | awk -F'[, ]' '{print $1}')
    TDX_MIN="1.5.16"
    if [[ "$(printf '%s\n' "$TDX_MIN" "$TDX_VER" | sort -V | head -1)" != "$TDX_MIN" ]]; then
      print_result "TDX module" "$TDX_MODULE" "WARN"
      printf "  %-50s\n" "  (below minimum $TDX_MIN)"
    elif [[ "$TDX_INIT" -eq 0 ]]; then
      print_result "TDX module" "$TDX_MODULE (not initialized)" "WARN"
    else
      print_result "TDX module" "$TDX_MODULE" "OK"
    fi
  else
    print_result "TDX module" "not found in kernel journal" "FAIL"
  fi

elif [[ "$TEE_TYPE" == "snp" ]]; then
  if echo "$KERNEL_LOG" | grep -qi "AMD-Vi\|IOMMU"; then
    print_result "IOMMU" "AMD-Vi detected" "OK"
  else
    print_result "IOMMU" "AMD-Vi not detected" "WARN"
  fi

  SEV_INFO=$(echo "$KERNEL_LOG" | grep -i "SEV-SNP" | head -1)
  if [[ -n "$SEV_INFO" ]]; then
    print_result "SEV-SNP" "${SEV_INFO##*] }" "OK"
  else
    print_result "SEV-SNP" "not detected in kernel journal" "FAIL"
  fi

  if run_on_node "[ -e /dev/sev ]"; then
    print_result "/dev/sev" "present" "OK"
  else
    print_result "/dev/sev" "not found" "FAIL"
  fi

  if echo "$LSMOD" | grep -q "kvm_amd"; then
    print_result "kvm_amd" "loaded" "OK"
  else
    print_result "kvm_amd" "not loaded" "FAIL"
  fi
fi

echo ""
TOTAL=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))
if [[ $FAIL_COUNT -eq 0 ]]; then
  echo "  Result: PASS ($PASS_COUNT/$TOTAL checks passed, $WARN_COUNT warnings)"
else
  echo "  Result: FAIL ($PASS_COUNT/$TOTAL checks passed, $FAIL_COUNT failed, $WARN_COUNT warnings)"

  if [[ "$TEE_TYPE" == "tdx" ]]; then
    echo ""
    echo "  Required BIOS settings for Intel TDX:"
    echo "    - Total Memory Encryption (TME): Enabled"
    echo "    - Multikey Total Memory Encryption (TME-MK): Enabled"
    echo "    - Trust Domain Extension (TDX): Enabled"
    echo "    - TDX Secure Arbitration Mode Loader (SEAM Loader): Enabled"
    echo "    - TME-MT/TDX key split: Non-zero (e.g. 4)"
    echo "    - SW Guard Extensions (SGX): Enabled"
    echo "    - SGX PRM Size: 128 MB (minimum)"
    echo "    - Limit CPU PA to 46 bits: Disabled"
  fi

  exit 1
fi
