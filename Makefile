CONTAINER_TOOL ?= podman
REGISTRY       ?= quay.io/rh-ai-quickstart
QUAY_REPO      ?= conf-gpu-accel-seismic-interp-deepseismic-model

BASE_VERSION           := 0.2.0
MODEL_CAR_BASE_VERSION := 0.1.0
GIT_BRANCH             := $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

ifeq ($(origin QUAY_TAG),undefined)
  ifeq ($(GIT_BRANCH),main)
    QUAY_TAG := $(MODEL_CAR_BASE_VERSION)
  else
    QUAY_TAG := $(MODEL_CAR_BASE_VERSION)-dev
  endif
endif

MODEL_IMG      ?= $(REGISTRY)/$(QUAY_REPO):$(QUAY_TAG)

APP_QUAY_REPO  ?= conf-gpu-accel-seismic-interp-deepseismic-app

ifeq ($(origin APP_TAG),undefined)
  ifeq ($(GIT_BRANCH),main)
    APP_TAG := $(BASE_VERSION)
  else
    APP_TAG := $(BASE_VERSION)-dev
  endif
endif

APP_IMG        ?= $(REGISTRY)/$(APP_QUAY_REPO):$(APP_TAG)
MODEL_OWNER_COSIGN_KEY ?= model-owner-verification-keys/cosign.key
NRAS_API_KEY        ?=
INTEL_API_KEY       ?=
RUNTIME_CLASS       ?= nvidia
KATA_RUNTIME_CLASS    ?= kata-cc-nvidia-gpu
POLICY_MODE           ?= locked
# TDX infrastructure reference values for OSC 1.13.0 / kata-cc-nvidia-gpu.
# Re-run scripts/collect-tdx-measurements.sh and update these after an OSC upgrade.
TDX_MR_SEAM      ?=
TDX_TD_ATTRIBUTES ?= 0000001000000000
TDX_MR_TD        ?= 27fb849fb05653add8be4b8c5b2793e66d1e25773a5c6f80dabbc10a5cb18bc40b7d5caaaf299e3a200f7018cdaa6f74
TDX_XFAM         ?= e702060000000000
TDX_RTMR_0       ?= 01cbbe9a7adb5f1f9459085d6f9f4bd02a5bf5352a8287b4ba963b35bc3f022c571fde23d04cb485acb4733f09b53493
TDX_RTMR_1       ?= 93a576941cfe92d6427106944e475e96b702d1049975b6c64512345857d69dbab8d14c5f3dc88931cc582c9974fae8cc
TDX_RTMR_2       ?= e882c8d18de74cc30d506d56962e5d3eb33c98e6c25f0329857c29f03a48fb17b6c6b1e2acc4741b305a6656a5f7d6c9
TDX_RTMR_3       ?= 000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000

# Space-separated list of node names to label nvidia.com/gpu.workload.config=vm-passthrough.
# Nodes in this list stop advertising nvidia.com/gpu and instead advertise nvidia.com/pgpu.
# Unlabeled GPU nodes continue serving standard CUDA workloads unchanged.
# Example: GPU_PASSTHROUGH_NODES="worker-0 worker-1"
GPU_PASSTHROUGH_NODES ?=
APP_IMAGE_REPO       = $(shell echo $(APP_IMG) | cut -d: -f1)
MODEL_IMAGE_REPO     = $(shell echo $(MODEL_IMG) | cut -d: -f1)
KBS_URL             ?= https://$(shell oc get route kbs-route \
                          -n trustee-operator-system \
                          -o jsonpath='{.spec.host}' 2>/dev/null)

NAMESPACE      ?= default
JOBSET_NAME    ?= deepseismic-dutchf3-training
NUM_WORKERS    ?= 1
EPOCHS             ?= 30
BATCH_SIZE         ?= 8
N_SAMPLES          ?= 15

MAKEFLAGS += --no-print-directory


define build_image
	@echo "Building $(1)..."
	$(CONTAINER_TOOL) build -f $(2) -t $(1) .
	@echo "Successfully built $(1)"
endef

define push_image
	@echo "Pushing $(1)..."
	$(CONTAINER_TOOL) push $(1)
	@echo "Successfully pushed $(1)"
endef

.PHONY: help
help:
	@echo "Available targets:"
	@echo ""
	@echo "  Training:"
	@echo "    submit-training  - Create PVC, ConfigMap, and JobSet to train on Dutch F3"
	@echo "    training-status  - Show status of training pods and jobs"
	@echo "    training-logs    - Follow logs from all training workers"
	@echo "    delete-training  - Remove the JobSet and ConfigMap (keeps PVC/data)"
	@echo "    training-cleanup - delete-training + delete PVC (full reset for a fresh training run)"
	@echo "    get-model              - Copy dutchf3_unet_final.pth from PVC to ./model-creation/model-weights/"
	@echo "    validate-model         - Run inference on Dutch F3 test sections, save PNGs to PVC"
	@echo "    get-validation-results - Copy validation PNGs from PVC to local directory"
	@echo "    extract-samples        - Extract N_SAMPLES inline slices from F3 data → ./samples/*.npy"
	@echo "    run-inference          - Classify ./samples/*.npy on GPU, copy PNGs to ./results/"
	@echo ""
	@echo "  Model Pipeline:"
	@echo "    build-modelcar   - AES-256-CBC encrypt the weights and build the ModelCar OCI image"
	@echo "    push-modelcar    - Push the ModelCar image to the registry"
	@echo ""
	@echo "  Application:"
	@echo "    check-ui         - Preview the Gradio UI locally using uv (no model required)"
	@echo "    build-app        - Build the Gradio application container image"
	@echo "    push-app         - Push the application image to the registry"
	@echo ""
	@echo "  Prerequisites:"
	@echo "    check-prereqs    - Verify OpenShift version, CPU TEE support, required operators,"
	@echo "                       kernel parameters, and local tools (oc, helm, cosign, etc.)"
	@echo "    status-check     - Show cluster-wide CoCo status: nodes, BIOS preflight, operators,"
	@echo "                       runtime classes, NFD labels, MCP state, and problem pods"
	@echo ""
	@echo "  Attestation (cluster-admin, run once per cluster before install):"
	@echo "    setup-intel-tee          - Apply Intel TDX + IOMMU kernel parameters, reboot, verify TDX active"
	@echo "                               Run after enabling TDX in server BIOS (see README)"
	@echo "    setup-amd-tee            - Apply AMD IOMMU kernel parameters, reboot, verify SEV-SNP active"
	@echo "                               Run after enabling SNP in server BIOS (see README)"
	@echo "    setup-kata               - Install NFD + NodeFeatureRule, then OSC + KataConfig"
	@echo "                               Verifies TEE node label and kata-cc runtimeClass"
	@echo "                               Requires setup-intel-tee or setup-amd-tee to have completed first"
	@echo "                               Optionally labels GPU nodes: GPU_PASSTHROUGH_NODES=\"node1 node2\""
	@echo "    setup-gpu-passthrough    - Label GPU node(s) for kata VM passthrough without re-running setup-kata"
	@echo "                               Requires GPU_PASSTHROUGH_NODES=\"<node1> <node2>\""
	@echo "                               Safe to run repeatedly — idempotent"
	@echo "    setup-cc-gpu             - Configure GPU Operator for confidential computing mode"
	@echo "                               Patches ClusterPolicy: ccManager on, driver/toolkit/devicePlugin off,"
	@echo "                               vfioManager on; auto-detects NVSwitch nodes for BIND_NVSWITCHES"
	@echo "                               Requires setup-kata to have completed first"
	@echo "    verify-gpu-passthrough   - Check ClusterPolicy settings, node labels, VFIO/sandbox pods,"
	@echo "                               and pgpu allocatable resources for kata GPU passthrough"
	@echo "    rescan-gpus              - Restart nvidia-kata-sandbox-device-plugin pod(s) to force a fresh"
	@echo "                               vfio-pci device scan — fixes pgpu showing 0 when the plugin started"
	@echo "                               before vfio-manager finished rebinding the GPU(s)"
	@echo "    validate-node-labels     - Print required node labels for kata-cc-nvidia-gpu on all GPU nodes"
	@echo "                               Shows TEE label, CC mode state, vfio-manager, cc-manager status"
	@echo "    setup-dcap               - Deploy Intel SGX Device Plugin and Intel TDX DCAP Operator (QGS + PCCS)"
	@echo "                               Required for TDX attestation: QGS listens on vsock port 4050 so"
	@echo "                               CDH inside kata VMs can generate attestation quotes"
	@echo "                               Requires INTEL_API_KEY from api.portal.trustedservices.intel.com"
	@echo "                               Requires setup-kata to have completed first"
	@echo "    verify-dcap              - Check DCAP operator CSVs, TdxQuoteGenerationService CR, and QGS pod status"
	@echo "    setup-trustee-in-cluster - Install Trustee KBS operator and configure attestation policy"
	@echo "                               Requires setup-dcap to have completed first (Intel TDX only)"
	@echo "    collect-tdx-measurements - Launch a temporary kata probe pod and collect TDX hardware"
	@echo "                               measurements (mr_td, xfam, rtmr_0-3, td_attributes, mr_seam)"
	@echo "                               Paste the printed Makefile variables here; re-run after OSC upgrades"
	@echo "                               (requires NAMESPACE; uses KATA_RUNTIME_CLASS)"
	@echo "    set-rvps-values          - Compute and register mr_config_id and TDX hardware measurements in RVPS;"
	@echo "                               restarts Trustee to pick up the updated configmap"
	@echo "                               (requires NAMESPACE; export TDX_MR_TD/XFAM/RTMR_* for full attestation)"
	@echo "    register-secrets-with-kbs - Register model key, cosign key, and image policy with KBS"
	@echo "                               via kbsSecretResources (requires NAMESPACE, MODEL_ENCRYPTION_KEY,"
	@echo "                               model-owner-verification-keys/cosign.pub)"
	@echo "    patch-cpu-policy-initdata       - Add initdata binding to the CPU attestation policy (mr_config_id check); restarts Trustee"
	@echo "    patch-cpu-policy-firmwarelevel         - Apply the quickstart CPU attestation policy (date-based TCB check instead"
	@echo "                               of requiring UpToDate TCB status); restarts Trustee"
	@echo "    setup-attestation        - Convenience target: runs set-rvps-values then register-secrets-with-kbs"
	@echo "    validate-trustee-certificate - Verify the cert in trusteeconfig-https-cert-secret matches what"
	@echo "                               KBS is currently serving; fails if cert-manager has rotated the cert"
	@echo "                               since the last 'make install' (which would break TLS in the kata VM)"
	@echo "    show-initdata            - Print the decoded initdata that would be embedded in the pod:"
	@echo "                               aa.toml, cdh.toml, policy.rego, SHA-256, and mr_config_id"
	@echo "                               (requires NAMESPACE; uses POLICY_MODE, APP_IMG, MODEL_IMG)"
	@echo "    show-rvps                - Print RVPS reference values: what would be registered by"
	@echo "                               set-rvps-values vs what is currently in the ConfigMap"
	@echo "                               (requires NAMESPACE; export TDX_MR_TD/XFAM/RTMR_1/RTMR_2)"
	@echo "    clear-rvps               - Remove all registered RVPS reference values and restart Trustee"
	@echo "                               WARNING: attestation will fail for all pods until re-registered"
	@echo "    trustee-logs             - Show the last 100 log lines from the Trustee deployment"
	@echo "    debug-attestation        - Start a temporary kata pod, fetch the live EAR token from CDH,"
	@echo "                               and decode trust claims (executables/hardware/configuration per submod)"
	@echo "                               highlighting any non-affirming values that cause PolicyDeny"
	@echo "                               (requires NAMESPACE and seismic-app deployment to exist)"
	@echo ""
	@echo "  Deploy:"
	@echo "    install          - Install the app to the cluster via Helm (requires NAMESPACE;"
	@echo "                       fetches KBS cert from cluster and builds initdata blob automatically)"
	@echo "    uninstall        - Uninstall the app from the cluster"
	@echo "    clean-terminating-pods - Stop kata sandboxes and QEMU processes for pods stuck"
	@echo "                       in Terminating, then force-delete their pod records (requires NAMESPACE)"
	@echo ""
	@echo "  Signing (model owner — run when publishing a custom model or app image):"
	@echo "    generate-model-owner-keys         - Generate a cosign key pair in model-owner-verification-keys/"
	@echo "    sign-modelcar                     - Sign the pushed ModelCar image with the model owner key"
	@echo "    model-owner-sign-app-container    - Sign the pushed application image with the model owner key"
	@echo ""
	@echo "Configuration (set via environment variables or make arguments):"
	@echo ""
	@echo "  NAMESPACE              - OpenShift namespace for training and app deployment (default: default)"
	@echo "  JOBSET_NAME            - Name of the training JobSet (default: deepseismic-dutchf3-training)"
	@echo "  NUM_WORKERS            - Number of distributed training workers (default: 2)"
	@echo "  EPOCHS                 - Training epochs (default: 30)"
	@echo "  BATCH_SIZE             - Per-worker batch size (default: 8)"
	@echo "  CONTAINER_TOOL         - Container tool (default: podman)"
	@echo "  REGISTRY               - Registry prefix (default: quay.io/rh-ai-quickstart)"
	@echo "  QUAY_REPO              - Repository name (default: conf-gpu-accel-seismic-interp-deepseismic-model)"
	@echo "  QUAY_TAG               - ModelCar image tag (auto: $(MODEL_CAR_BASE_VERSION) on main, $(MODEL_CAR_BASE_VERSION)-dev elsewhere; override with QUAY_TAG=...)"
	@echo "  MODEL_IMG              - Full image ref (default: \$${REGISTRY}/\$${QUAY_REPO}:\$${QUAY_TAG})"
	@echo "  MODEL_ENCRYPTION_KEY   - AES-256-CBC key (required for build-modelcar and setup-attestation)"
	@echo "  KATA_RUNTIME_CLASS     - kata runtimeClass for install (default: kata-cc-nvidia-gpu)"
	@echo "  TDX_MR_TD              - TDX hardware measurements (stable per OSC version)."
	@echo "  TDX_XFAM               -   Collect with: scripts/collect-tdx-measurements.sh"
	@echo "  TDX_RTMR_0             -   Export the printed values before running setup-attestation."
	@echo "  TDX_RTMR_1             -   Required: TDX_MR_TD TDX_XFAM TDX_RTMR_0 TDX_RTMR_1 TDX_RTMR_2"
	@echo "  TDX_RTMR_2             -   Optional: TDX_RTMR_3 TDX_TD_ATTRIBUTES TDX_MR_SEAM"
	@echo "  TDX_RTMR_3             -   Without the required set, attestation fails after 'make install'."
	@echo "  TDX_TD_ATTRIBUTES      -"
	@echo "  TDX_MR_SEAM            -"
	@echo "  GPU_PASSTHROUGH_NODES  - Space-separated node names to label for kata VM passthrough during setup-kata."
	@echo "                           Labeled nodes stop advertising nvidia.com/gpu and advertise nvidia.com/pgpu instead."
	@echo "                           Unlabeled GPU nodes continue serving standard CUDA workloads unchanged."
	@echo "                           Example: make setup-kata GPU_PASSTHROUGH_NODES=\"worker-0 worker-1\""
	@echo "  KBS_URL                - KBS external route URL (default: auto-detected; used for reference only — initdata uses the internal ClusterIP URL to avoid IPv6 routing issues)"
	@echo "  MODEL_OWNER_COSIGN_KEY - Path to model owner signing key (default: model-owner-verification-keys/cosign.key)"
	@echo "  NRAS_API_KEY           - NVIDIA NGC personal API key for NRAS GPU attestation."
	@echo "                           Create at ngc.nvidia.com: click your name -> Account Settings -> Generate API Key"
	@echo "                           Select 'Public API Endpoints' under Services Included."
	@echo "                           Passed to setup-trustee-in-cluster to create the nras-api-key Secret."
	@echo "  INTEL_API_KEY          - Intel PCS API key for PCCS certificate caching (Intel TDX only)."
	@echo "                           Get a free key at https://api.portal.trustedservices.intel.com/"
	@echo "                           Required for setup-dcap."
	@echo "  N_SAMPLES              - Inline slices to extract as sample inputs (default: 15)"
	@echo "  APP_QUAY_REPO          - App repository name (default: conf-gpu-accel-seismic-interp-deepseismic-app)"
	@echo "  APP_TAG                - App image tag (auto: $(BASE_VERSION) on main, $(BASE_VERSION)-dev elsewhere)"
	@echo "  APP_IMG                - Full app image ref (default: \$${REGISTRY}/\$${APP_QUAY_REPO}:\$${APP_TAG})"

.PHONY: check-prereqs
check-prereqs:
	@PASS=0; FAIL=0; WARN=0; \
	ok()   { echo "  [PASS] $$1"; PASS=$$((PASS+1)); }; \
	fail() { echo "  [FAIL] $$1"; FAIL=$$((FAIL+1)); }; \
	warn() { echo "  [WARN] $$1"; WARN=$$((WARN+1)); }; \
	\
	echo ""; \
	echo "=== Local tools ==="; \
	for tool in oc helm cosign openssl curl base64 python3; do \
	    if command -v $$tool >/dev/null 2>&1; then \
	        ok "$$tool found: $$(command -v $$tool)"; \
	    elif [ "$$tool" = "cosign" ]; then \
	        warn "cosign not found — install it before signing model or application images"; \
	    else \
	        fail "$$tool not found — install it before continuing"; \
	    fi; \
	done; \
	\
	echo ""; \
	echo "=== OpenShift cluster ==="; \
	if ! oc whoami >/dev/null 2>&1; then \
	    fail "Not logged in to OpenShift — run 'oc login' first"; \
	    echo ""; \
	    echo "Cannot check cluster requirements without an active login. Exiting."; \
	    exit 1; \
	fi; \
	ok "Logged in as: $$(oc whoami)"; \
	\
	OCP_VERSION=$$(oc get clusterversion version \
	    -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown"); \
	REQUIRED="4.21.24"; \
	if [ "$$OCP_VERSION" = "unknown" ]; then \
	    fail "Could not determine OpenShift version"; \
	else \
	    NEWER=$$(printf '%s\n%s\n' "$$REQUIRED" "$$OCP_VERSION" | sort -V | tail -1); \
	    if [ "$$NEWER" = "$$OCP_VERSION" ] && [ "$$OCP_VERSION" != "$$REQUIRED" ]; then \
	        ok "OpenShift version $$OCP_VERSION >= $$REQUIRED"; \
	    elif [ "$$OCP_VERSION" = "$$REQUIRED" ]; then \
	        ok "OpenShift version $$OCP_VERSION == $$REQUIRED"; \
	    else \
	        fail "OpenShift version $$OCP_VERSION < $$REQUIRED (required for OSC 1.13 confidential containers with GPU)"; \
	    fi; \
	fi; \
	\
	if oc auth can-i create machineconfig >/dev/null 2>&1; then \
	    ok "cluster-admin: can create MachineConfig"; \
	else \
	    fail "Insufficient permissions — cluster-admin role required"; \
	fi; \
	\
	NODE_ARCH=$$(oc get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null); \
	if [ "$$NODE_ARCH" = "amd64" ]; then \
	    ok "Node architecture: x86_64 (amd64)"; \
	else \
	    fail "Node architecture: $$NODE_ARCH — confidential containers require x86_64"; \
	fi; \
	\
	echo ""; \
	echo "=== CPU TEE capability ==="; \
	NODE_NAME=$$(oc get nodes -o jsonpath='{.items[0].metadata.name}'); \
	echo "  Checking kernel journal on $$NODE_NAME (spawns a debug pod — takes ~30s)..."; \
	oc debug node/$$NODE_NAME -- chroot /host journalctl -k 2>/dev/null \
	    | grep -iE 'tdx|sev.snp|sme' > /tmp/tee-kernel-log-check.txt 2>/dev/null || true; \
	if grep -qi "tdx" /tmp/tee-kernel-log-check.txt; then \
	    if grep -q "BIOS enabled" /tmp/tee-kernel-log-check.txt; then \
	        ok "Intel TDX: BIOS enabled — $$(grep 'BIOS enabled' /tmp/tee-kernel-log-check.txt | tail -1 | sed 's/.*tdx: //')"; \
	    fi; \
	    if grep -q "initialization failed: Hibernation" /tmp/tee-kernel-log-check.txt; then \
	        fail "Intel TDX: kernel init blocked by hibernation — run: make setup-intel-tee (adds nohibernate kernel arg)"; \
	    elif grep -qi "tdx.*initialized\|initialized.*tdx\|module initialized" /tmp/tee-kernel-log-check.txt; then \
	        ok "Intel TDX: kernel initialized — TDX active"; \
	        if oc get node "$$NODE_NAME" -o jsonpath='{.metadata.labels}' 2>/dev/null \
	                | grep -q 'intel\.feature\.node\.kubernetes\.io/tdx'; then \
	            ok "Intel TDX: NFD label intel.feature.node.kubernetes.io/tdx confirmed"; \
	        else \
	            warn "Intel TDX: active in kernel but NFD label not yet set — run: make setup-intel-tee"; \
	        fi; \
	    else \
	        warn "Intel TDX: BIOS enabled but kernel status unclear — check: oc debug node/$$NODE_NAME -- chroot /host journalctl -k | grep -i tdx"; \
	    fi; \
	elif grep -qi "sev.snp.*enabled\|snp.*active" /tmp/tee-kernel-log-check.txt; then \
	    ok "AMD SEV-SNP: enabled in kernel"; \
	    if oc get node "$$NODE_NAME" -o jsonpath='{.metadata.labels}' 2>/dev/null \
	            | grep -q 'amd\.feature\.node\.kubernetes\.io/snp'; then \
	        ok "AMD SEV-SNP: NFD label amd.feature.node.kubernetes.io/snp confirmed"; \
	    else \
	        warn "AMD SEV-SNP: active in kernel but NFD label not yet set — run: make setup-amd-tee"; \
	    fi; \
	else \
	    fail "No TDX or SEV-SNP found in kernel journal — enable TEE in server BIOS (see README hardware prerequisites)"; \
	fi; \
	rm -f /tmp/tee-kernel-log-check.txt; \
	\
	echo ""; \
	echo "=== Required operators ==="; \
	if oc get csv -n openshift-cert-manager-operator 2>/dev/null | grep -q "Succeeded"; then \
	    ok "cert-manager operator: installed"; \
	elif oc get csv -A 2>/dev/null | grep -qi "cert-manager.*Succeeded"; then \
	    ok "cert-manager operator: installed (non-standard namespace)"; \
	else \
	    fail "cert-manager operator not found — required for KBS TLS certificates"; \
	fi; \
	\
	if oc get csv -n nvidia-gpu-operator 2>/dev/null | grep -q "gpu-operator.*Succeeded"; then \
	    ok "NVIDIA GPU Operator: installed"; \
	else \
	    warn "NVIDIA GPU Operator not found — kata-cc-nvidia-gpu runtimeClass will not be created"; \
	fi; \
	\
	if oc get csv -n openshift-nfd 2>/dev/null | grep -q "nfd.*Succeeded"; then \
	    ok "Node Feature Discovery: installed"; \
	else \
	    warn "Node Feature Discovery not installed — run make setup-kata"; \
	fi; \
	\
	if oc get csv -n openshift-sandboxed-containers-operator 2>/dev/null \
	        | grep -q "sandboxed-containers.*Succeeded"; then \
	    ok "OpenShift Sandboxed Containers: installed"; \
	else \
	    warn "OpenShift Sandboxed Containers not installed — run make setup-trustee-in-cluster"; \
	fi; \
	\
	if oc get csv -n trustee-operator-system 2>/dev/null | grep -q "trustee-operator.*Succeeded"; then \
	    ok "Trustee operator: installed"; \
	else \
	    warn "Trustee operator not installed — run make setup-trustee-in-cluster"; \
	fi; \
	\
	echo ""; \
	echo "=== TEE kernel parameters (MachineConfigs) ==="; \
	if oc get mc 99-enable-intel-tdx --ignore-not-found 2>/dev/null | grep -q .; then \
	    ok "MachineConfig 99-enable-intel-tdx present (kvm_intel.tdx=1 + vsock-loopback)"; \
	else \
	    warn "MachineConfig 99-enable-intel-tdx not found — run: make setup-intel-tee"; \
	fi; \
	if oc get mc 100-iommu-kernel-args --ignore-not-found 2>/dev/null | grep -q .; then \
	    ok "MachineConfig 100-iommu-kernel-args present (intel_iommu/amd_iommu=on iommu=pt)"; \
	else \
	    warn "MachineConfig 100-iommu-kernel-args not found — run: make setup-intel-tee or setup-amd-tee"; \
	fi; \
	\
	echo ""; \
	echo "=== Intel DCAP (TDX quote generation) ==="; \
	if oc get csv -n intel-dcap 2>/dev/null \
	        | grep -q "intel-device-plugins-operator.*Succeeded"; then \
	    ok "Intel Device Plugin Operator: installed"; \
	else \
	    warn "Intel Device Plugin Operator not found — run: make setup-dcap INTEL_API_KEY=<key> (Intel TDX only)"; \
	fi; \
	if oc get csv -n intel-dcap 2>/dev/null \
	        | grep -q "intel-tdx-dcap-operator.*Succeeded"; then \
	    ok "Intel TDX DCAP Operator: installed"; \
	else \
	    warn "Intel TDX DCAP Operator not found — run: make setup-dcap INTEL_API_KEY=<key> (Intel TDX only)"; \
	fi; \
	if oc get tdxquotegenerationservices.trustedservices.intel.com intel-tdx-dcap -n intel-dcap \
	        --ignore-not-found 2>/dev/null | grep -q .; then \
	    QGS_RUNNING=$$(oc get pods -n intel-dcap 2>/dev/null \
	        | grep "intel-tdx-dcap-qgs" | grep -c "Running" || echo "0"); \
	    if [ "$$QGS_RUNNING" -gt 0 ]; then \
	        ok "TdxQuoteGenerationService: $$QGS_RUNNING QGS pod(s) running"; \
	    else \
	        warn "TdxQuoteGenerationService CR exists but no QGS pods running — check: oc get pods -n intel-dcap"; \
	    fi; \
	else \
	    warn "TdxQuoteGenerationService not found — run: make setup-dcap INTEL_API_KEY=<key> (Intel TDX only)"; \
	fi; \
	\
	echo ""; \
	echo "=== Summary ==="; \
	echo "  PASS: $$PASS   FAIL: $$FAIL   WARN: $$WARN"; \
	echo ""; \
	if [ "$$FAIL" -gt 0 ]; then \
	    echo "  One or more required prerequisites are missing. Fix FAIL items before proceeding."; \
	    exit 1; \
	elif [ "$$WARN" -gt 0 ]; then \
	    echo "  Prerequisites met. WARN items are expected at this stage — see setup targets above."; \
	else \
	    echo "  All prerequisites satisfied."; \
	fi

.PHONY: status-check
status-check:
	@bash scripts/status.sh

.PHONY: build-modelcar
build-modelcar:
	@[ -n "$$MODEL_ENCRYPTION_KEY" ] || (echo "Error: MODEL_ENCRYPTION_KEY is not set"; exit 1)
	@[ -f model-creation/model-weights/dutchf3_unet_final.pth ] || \
		(echo "Error: model-creation/model-weights/dutchf3_unet_final.pth not found — run 'make get-model NAMESPACE=...' first"; exit 1)
	@echo "Building $(MODEL_IMG) (encryption runs inside the build)..."
	$(CONTAINER_TOOL) build -f Containerfile.modelcar \
		--secret id=model_key,env=MODEL_ENCRYPTION_KEY \
		-t $(MODEL_IMG) .
	@echo "Successfully built $(MODEL_IMG)"

.PHONY: push-modelcar
push-modelcar:
	$(call push_image,$(MODEL_IMG))

.PHONY: submit-training
submit-training:
	@[ -n "$$NAMESPACE" ] || (echo "Error: NAMESPACE is not set"; exit 1)
	@echo "Submitting training job '$(JOBSET_NAME)' to namespace '$(NAMESPACE)'..."
	oc apply -n $(NAMESPACE) -f model-creation/training/pvc.yaml
	oc create configmap $(JOBSET_NAME)-script -n $(NAMESPACE) \
		--from-file=train.py=model-creation/training/train.py \
		--dry-run=client -o yaml | oc apply -n $(NAMESPACE) -f -
	JOBSET_NAME=$(JOBSET_NAME) NUM_WORKERS=$(NUM_WORKERS) EPOCHS=$(EPOCHS) BATCH_SIZE=$(BATCH_SIZE) \
		envsubst '$${JOBSET_NAME} $${NUM_WORKERS} $${EPOCHS} $${BATCH_SIZE}' < model-creation/training/jobset.yaml | oc apply -n $(NAMESPACE) -f -
	@echo "Job submitted. Monitor with: make training-logs NAMESPACE=$(NAMESPACE)"

.PHONY: training-status
training-status:
	oc get jobset,job,pod -n $(NAMESPACE) -l jobset.sigs.k8s.io/jobset-name=$(JOBSET_NAME)

.PHONY: training-logs
training-logs:
	oc logs -n $(NAMESPACE) -l jobset.sigs.k8s.io/jobset-name=$(JOBSET_NAME) \
		--prefix --follow --max-log-requests=4

.PHONY: validate-model
validate-model:
	@echo "Submitting validation job to namespace '$(NAMESPACE)'..."
	oc create configmap deepseismic-validate-script -n $(NAMESPACE) \
		--from-file=validate.py=model-creation/training/validate.py \
		--dry-run=client -o yaml | oc apply -n $(NAMESPACE) -f -
	oc run deepseismic-validate -n $(NAMESPACE) --restart=Never \
		--image=registry.redhat.io/rhoai/odh-training-cuda128-torch28-py312-rhel9:v3.0 \
		--overrides='{"spec":{"tolerations":[{"effect":"NoSchedule","key":"g5-gpu","operator":"Exists"}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"deepseismic-training-data"}},{"name":"script","configMap":{"name":"deepseismic-validate-script"}}],"containers":[{"name":"validate","image":"registry.redhat.io/rhoai/odh-training-cuda128-torch28-py312-rhel9:v3.0","command":["/opt/app-root/bin/python3","/workspace/validate.py"],"volumeMounts":[{"name":"data","mountPath":"/data"},{"name":"script","mountPath":"/workspace"}],"resources":{"limits":{"cpu":"4","memory":"16Gi","nvidia.com/gpu":"1"},"requests":{"cpu":"4","memory":"16Gi","nvidia.com/gpu":"1"}}}]}}'
	@echo "Waiting for validation to complete..."
	oc wait pod/deepseismic-validate -n $(NAMESPACE) --for=condition=Ready --timeout=120s
	oc logs -n $(NAMESPACE) deepseismic-validate --follow
	oc delete pod deepseismic-validate -n $(NAMESPACE)
	oc delete configmap deepseismic-validate-script -n $(NAMESPACE)
	@echo "Copying validation results..."
	oc run model-copy -n $(NAMESPACE) --image=registry.access.redhat.com/ubi9/ubi:latest --restart=Never \
		--overrides='{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"deepseismic-training-data"}}],"containers":[{"name":"model-copy","image":"registry.access.redhat.com/ubi9/ubi:latest","command":["sleep","120"],"volumeMounts":[{"name":"data","mountPath":"/data"}],"resources":{"requests":{"cpu":"100m","memory":"128Mi"}}}]}}'
	oc wait pod/model-copy -n $(NAMESPACE) --for=condition=Ready --timeout=60s
	oc cp $(NAMESPACE)/model-copy:/data/checkpoints/validation_test1.png ./validation_test1.png 2>/dev/null || true
	oc cp $(NAMESPACE)/model-copy:/data/checkpoints/validation_test2.png ./validation_test2.png 2>/dev/null || true
	oc delete pod model-copy -n $(NAMESPACE)
	@echo "Saved validation_test1.png and validation_test2.png"

.PHONY: get-validation-results
get-validation-results:
	@echo "Copying validation PNGs from PVC..."
	oc run model-copy -n $(NAMESPACE) --image=registry.access.redhat.com/ubi9/ubi:latest --restart=Never \
		--overrides='{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"deepseismic-training-data"}}],"containers":[{"name":"model-copy","image":"registry.access.redhat.com/ubi9/ubi:latest","command":["sleep","120"],"volumeMounts":[{"name":"data","mountPath":"/data"}],"resources":{"requests":{"cpu":"100m","memory":"128Mi"}}}]}}'
	oc wait pod/model-copy -n $(NAMESPACE) --for=condition=Ready --timeout=60s
	oc cp $(NAMESPACE)/model-copy:/data/checkpoints/validation_test1.png ./validation_test1.png 2>/dev/null || true
	oc cp $(NAMESPACE)/model-copy:/data/checkpoints/validation_test2.png ./validation_test2.png 2>/dev/null || true
	oc delete pod model-copy -n $(NAMESPACE)
	@echo "Saved validation_test1.png and validation_test2.png"

.PHONY: get-model
get-model:
	@echo "Copying dutchf3_unet_final.pth from PVC to ./model-creation/model-weights/ ..."
	@mkdir -p ./model-creation/model-weights
	oc run model-copy -n $(NAMESPACE) --image=registry.access.redhat.com/ubi9/ubi:latest --restart=Never \
		--overrides='{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"deepseismic-training-data"}}],"containers":[{"name":"model-copy","image":"registry.access.redhat.com/ubi9/ubi:latest","command":["sleep","120"],"volumeMounts":[{"name":"data","mountPath":"/data"}],"resources":{"requests":{"cpu":"100m","memory":"128Mi"}}}]}}'
	oc wait pod/model-copy -n $(NAMESPACE) --for=condition=Ready --timeout=60s
	oc exec -n $(NAMESPACE) model-copy -- tar cz -C /data/checkpoints dutchf3_unet_final.pth | tar xz -C ./model-creation/model-weights/
	oc delete pod model-copy -n $(NAMESPACE)
	@echo "Saved to ./model-creation/model-weights/dutchf3_unet_final.pth"

.PHONY: delete-training
delete-training:
	oc delete jobset $(JOBSET_NAME) -n $(NAMESPACE) --ignore-not-found
	oc delete configmap $(JOBSET_NAME)-script -n $(NAMESPACE) --ignore-not-found

.PHONY: training-cleanup
training-cleanup: delete-training
	oc delete pod model-copy deepseismic-validate deepseismic-extract \
		deepseismic-inference inference-upload \
		-n $(NAMESPACE) --ignore-not-found
	oc delete pvc deepseismic-training-data -n $(NAMESPACE) --ignore-not-found
	@echo "PVC deepseismic-training-data deleted — run 'make submit-training' to start fresh"

.PHONY: extract-samples
extract-samples:
	@echo "Extracting $(N_SAMPLES) sample sections from F3 training data..."
	oc create configmap deepseismic-extract-script -n $(NAMESPACE) \
		--from-file=extract_samples.py=model-creation/training/extract_samples.py \
		--dry-run=client -o yaml | oc apply -n $(NAMESPACE) -f -
	oc run deepseismic-extract -n $(NAMESPACE) --restart=Never \
		--image=registry.redhat.io/rhoai/odh-training-cuda128-torch28-py312-rhel9:v3.0 \
		--overrides='{"spec":{"tolerations":[{"effect":"NoSchedule","key":"g5-gpu","operator":"Exists"}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"deepseismic-training-data"}},{"name":"script","configMap":{"name":"deepseismic-extract-script"}}],"containers":[{"name":"extract","image":"registry.redhat.io/rhoai/odh-training-cuda128-torch28-py312-rhel9:v3.0","command":["/opt/app-root/bin/python3","/workspace/extract_samples.py"],"env":[{"name":"N_SAMPLES","value":"$(N_SAMPLES)"}],"volumeMounts":[{"name":"data","mountPath":"/data"},{"name":"script","mountPath":"/workspace"}],"resources":{"requests":{"cpu":"2","memory":"8Gi"},"limits":{"cpu":"2","memory":"8Gi"}}}]}}'
	oc wait pod/deepseismic-extract -n $(NAMESPACE) --for=condition=Ready --timeout=60s
	oc logs -n $(NAMESPACE) deepseismic-extract --follow
	oc delete pod deepseismic-extract -n $(NAMESPACE) --ignore-not-found
	oc delete configmap deepseismic-extract-script -n $(NAMESPACE) --ignore-not-found
	@echo "Copying samples to ./samples/ ..."
	oc run model-copy -n $(NAMESPACE) --image=registry.access.redhat.com/ubi9/ubi:latest --restart=Never \
		--overrides='{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"deepseismic-training-data"}}],"containers":[{"name":"model-copy","image":"registry.access.redhat.com/ubi9/ubi:latest","command":["sleep","120"],"volumeMounts":[{"name":"data","mountPath":"/data"}],"resources":{"requests":{"cpu":"100m","memory":"128Mi"}}}]}}'
	oc wait pod/model-copy -n $(NAMESPACE) --for=condition=Ready --timeout=60s
	mkdir -p ./samples
	oc exec -n $(NAMESPACE) model-copy -- tar cz -C /data/checkpoints samples | tar xz --strip-components=1 -C ./samples/
	oc delete pod model-copy -n $(NAMESPACE)
	@echo "$(N_SAMPLES) .npy files saved to ./samples/"

.PHONY: run-inference
run-inference:
	@[ -d samples ] && [ -n "$$(ls samples/*.npy 2>/dev/null)" ] || \
		(echo "Error: ./samples/*.npy not found — run 'make extract-samples NAMESPACE=$(NAMESPACE)' first"; exit 1)
	@echo "Uploading samples and running inference on GPU..."
	oc run inference-upload -n $(NAMESPACE) --image=registry.access.redhat.com/ubi9/ubi:latest --restart=Never \
		--overrides='{"spec":{"tolerations":[{"effect":"NoSchedule","key":"g5-gpu","operator":"Exists"}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"deepseismic-training-data"}}],"containers":[{"name":"inference-upload","image":"registry.access.redhat.com/ubi9/ubi:latest","command":["sleep","120"],"volumeMounts":[{"name":"data","mountPath":"/data"}],"resources":{"requests":{"cpu":"100m","memory":"128Mi"}}}]}}'
	oc wait pod/inference-upload -n $(NAMESPACE) --for=condition=Ready --timeout=60s
	tar cz -C ./ samples | oc exec -i -n $(NAMESPACE) inference-upload -- tar xz -C /data/checkpoints/
	oc delete pod inference-upload -n $(NAMESPACE)
	oc create configmap deepseismic-inference-script -n $(NAMESPACE) \
		--from-file=run_inference.py=model-creation/training/run_inference.py \
		--dry-run=client -o yaml | oc apply -n $(NAMESPACE) -f -
	oc run deepseismic-inference -n $(NAMESPACE) --restart=Never \
		--image=registry.redhat.io/rhoai/odh-training-cuda128-torch28-py312-rhel9:v3.0 \
		--overrides='{"spec":{"tolerations":[{"effect":"NoSchedule","key":"g5-gpu","operator":"Exists"}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"deepseismic-training-data"}},{"name":"script","configMap":{"name":"deepseismic-inference-script"}}],"containers":[{"name":"inference","image":"registry.redhat.io/rhoai/odh-training-cuda128-torch28-py312-rhel9:v3.0","command":["/opt/app-root/bin/python3","/workspace/run_inference.py"],"volumeMounts":[{"name":"data","mountPath":"/data"},{"name":"script","mountPath":"/workspace"}],"resources":{"limits":{"cpu":"4","memory":"16Gi","nvidia.com/gpu":"1"},"requests":{"cpu":"4","memory":"16Gi","nvidia.com/gpu":"1"}}}]}}'
	oc wait pod/deepseismic-inference -n $(NAMESPACE) --for=condition=Ready --timeout=120s
	oc logs -n $(NAMESPACE) deepseismic-inference --follow
	oc delete pod deepseismic-inference -n $(NAMESPACE) --ignore-not-found
	oc delete configmap deepseismic-inference-script -n $(NAMESPACE) --ignore-not-found
	@echo "Copying results to ./results/ ..."
	oc run model-copy -n $(NAMESPACE) --image=registry.access.redhat.com/ubi9/ubi:latest --restart=Never \
		--overrides='{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"deepseismic-training-data"}}],"containers":[{"name":"model-copy","image":"registry.access.redhat.com/ubi9/ubi:latest","command":["sleep","120"],"volumeMounts":[{"name":"data","mountPath":"/data"}],"resources":{"requests":{"cpu":"100m","memory":"128Mi"}}}]}}'
	oc wait pod/model-copy -n $(NAMESPACE) --for=condition=Ready --timeout=60s
	mkdir -p ./results
	oc exec -n $(NAMESPACE) model-copy -- tar cz -C /data/checkpoints results | tar xz --strip-components=1 -C ./results/
	oc delete pod model-copy -n $(NAMESPACE)
	@echo "Classification results saved to ./results/"

.PHONY: generate-model-owner-keys
generate-model-owner-keys:
	mkdir -p model-owner-verification-keys
	cosign generate-key-pair --output-key-prefix model-owner-verification-keys/cosign
	@echo "model-owner-verification-keys/cosign.key and cosign.pub generated — keep cosign.key private, never commit it"

.PHONY: sign-modelcar
sign-modelcar:
	@[ -f "$(MODEL_OWNER_COSIGN_KEY)" ] || (echo "Error: $(MODEL_OWNER_COSIGN_KEY) not found — run 'make generate-model-owner-keys' first"; exit 1)
	cosign sign --new-bundle-format=false --use-signing-config=false --tlog-upload=false --key $(MODEL_OWNER_COSIGN_KEY) $(MODEL_IMG)
	@echo "Successfully signed $(MODEL_IMG)"

.PHONY: check-ui
check-ui:
	uv run serving/app_dev.py

.PHONY: build-app
build-app:
	@echo "Building $(APP_IMG) ..."
	$(CONTAINER_TOOL) build -f Containerfile.app -t $(APP_IMG) .
	@echo "Successfully built $(APP_IMG)"

.PHONY: push-app
push-app:
	$(call push_image,$(APP_IMG))

.PHONY: model-owner-sign-app-container
model-owner-sign-app-container:
	@[ -f "$(MODEL_OWNER_COSIGN_KEY)" ] || (echo "Error: $(MODEL_OWNER_COSIGN_KEY) not found — run 'make generate-model-owner-keys' first"; exit 1)
	cosign sign --new-bundle-format=false --use-signing-config=false --tlog-upload=false --key $(MODEL_OWNER_COSIGN_KEY) $(APP_IMG)
	@echo "Successfully signed $(APP_IMG)"

.PHONY: install
install:
	@[ -n "$$NAMESPACE" ] || (echo "Error: NAMESPACE is not set"; exit 1)
	@set -e; \
	oc get route kbs-route -n trustee-operator-system >/dev/null 2>&1 || { \
	    echo "Error: KBS route not found — run make setup-trustee-in-cluster first"; exit 1; \
	}; \
	KBS_SVC_URL="https://kbs-service.trustee-operator-system.svc.cluster.local:8080"; \
	echo "Building initdata blob (KBS URL: $$KBS_SVC_URL)..."; \
	INITDATA=$$(oc get secret trusteeconfig-https-cert-secret -n trustee-operator-system \
	    -o jsonpath='{.data.certificate}' | base64 -d \
	    | python3 scripts/build-initdata.py "$$KBS_SVC_URL" "$(NAMESPACE)" \
	        --policy-mode $(POLICY_MODE) \
	        --app-image $(APP_IMG) \
	        --model-image $(MODEL_IMG)); \
	helm upgrade --install seismic-app helm/ \
	    -n $(NAMESPACE) \
	    --set app.image=$(APP_IMG) \
	    --set modelcar.image=$(MODEL_IMG) \
	    --set runtimeClassName=$(KATA_RUNTIME_CLASS) \
	    --set-string initdata="$$INITDATA"
	@echo "Deployed. Get the URL with: oc get route seismic-app -n $(NAMESPACE)"

.PHONY: uninstall
uninstall:
	helm uninstall seismic-app -n $(NAMESPACE) --ignore-not-found
	@echo "seismic-app uninstalled from $(NAMESPACE)"

.PHONY: test
test:
	@[ -n "$$NAMESPACE" ] || (echo "Error: NAMESPACE is not set"; exit 1)
	@set -e; \
	if [ "$(INSTALL)" = "1" ]; then \
	    echo "=== test: make install ==="; \
	    $(MAKE) install NAMESPACE=$(NAMESPACE); \
	else \
	    echo "=== test: INSTALL not set, assuming seismic-app is already deployed ==="; \
	fi; \
	echo "Waiting for seismic-app pod to be Running and Ready..."; \
	POD_READY=false; \
	DEADLINE=$$(( $$(date +%s) + 900 )); \
	while [ $$(date +%s) -lt $$DEADLINE ]; do \
	    LINE=$$(oc get pods -n $(NAMESPACE) --no-headers 2>/dev/null | grep '^seismic-app' | head -1); \
	    if [ -n "$$LINE" ]; then \
	        READY=$$(echo "$$LINE" | awk '{print $$2}'); \
	        STATUS=$$(echo "$$LINE" | awk '{print $$3}'); \
	        READY_N=$${READY%%/*}; TOTAL_N=$${READY#*/}; \
	        if [ "$$STATUS" = "Running" ] && [ -n "$$READY_N" ] && [ "$$READY_N" = "$$TOTAL_N" ]; then \
	            POD_READY=true; break; \
	        fi; \
	    fi; \
	    sleep 5; \
	done; \
	if [ "$$POD_READY" != "true" ]; then \
	    echo "ERROR: seismic-app pod did not become Running/Ready within 10 min."; \
	    oc get pods -n $(NAMESPACE); \
	    exit 1; \
	fi; \
	echo "Pod is up."; \
	HOST=$$(oc get route seismic-app -n $(NAMESPACE) -o jsonpath='{.spec.host}' 2>/dev/null); \
	if [ -z "$$HOST" ]; then \
	    echo "ERROR: could not resolve route host for seismic-app -n $(NAMESPACE)."; \
	    exit 1; \
	fi; \
	echo "=== test: UI smoke test against https://$$HOST ==="; \
	PLAYWRIGHT_BROWSERS_PATH="$(CURDIR)/test/playwright/bin"; \
	export PLAYWRIGHT_BROWSERS_PATH; \
	if [ -z "$$(ls -A "$$PLAYWRIGHT_BROWSERS_PATH" 2>/dev/null)" ]; then \
	    echo "Playwright browser binaries not found — installing into $$PLAYWRIGHT_BROWSERS_PATH ..."; \
	    mkdir -p "$$PLAYWRIGHT_BROWSERS_PATH"; \
	    uv run --with playwright playwright install chromium; \
	else \
	    echo "Playwright browser binaries already present in $$PLAYWRIGHT_BROWSERS_PATH — skipping install."; \
	fi; \
	uv run test/scripts/test-ui-e2e.py \
	    --url "https://$$HOST" \
	    --sample samples/f3_inline_019.npy \
	    --screenshot test/results/seismic-ui-result.png \
	    --sample2 samples/f3_inline_038.npy \
	    --screenshot2 test/results/seismic-ui-result-2.png; \
	if [ "$(INSTALL)" != "1" ]; then \
	    echo "=== test: INSTALL not set, skipping make uninstall ==="; \
	else \
	    echo "=== test: make uninstall ==="; \
	    $(MAKE) uninstall NAMESPACE=$(NAMESPACE); \
	    echo "Waiting for seismic-app pod(s) to terminate..."; \
	    CLEARED=false; \
	    DEADLINE=$$(( $$(date +%s) + 300 )); \
	    while [ $$(date +%s) -lt $$DEADLINE ]; do \
	        COUNT=$$(oc get pods -n $(NAMESPACE) --no-headers 2>/dev/null | grep '^seismic-app' | wc -l); \
	        if [ "$$COUNT" -eq 0 ]; then CLEARED=true; break; fi; \
	        sleep 5; \
	    done; \
	    if [ "$$CLEARED" != "true" ]; then \
	        echo "ERROR: seismic-app pod(s) did not terminate within 5 min."; \
	        oc get pods -n $(NAMESPACE); \
	        exit 1; \
	    fi; \
	fi; \
	echo "=== test PASSED — screenshots: test/results/seismic-ui-result.png, test/results/seismic-ui-result-2.png ==="

.PHONY: clean-terminating-pods
clean-terminating-pods:
	@[ -n "$$NAMESPACE" ] || (echo "Error: NAMESPACE is not set"; exit 1)
	bash scripts/cleanup-terminating-pods.sh "$(NAMESPACE)"

.PHONY: setup-intel-tee
setup-intel-tee:
	@set -e; \
	echo "=== setup-intel-tee: Intel TDX kernel parameters ==="; \
	PURE_WORKERS=$$(oc get nodes -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/master' \
	    --no-headers 2>/dev/null | wc -l | tr -d ' '); \
	if [ "$$PURE_WORKERS" != "0" ]; then \
	    echo "WARNING: Multi-node cluster detected."; \
	    echo "         MachineConfigs target master role by default — for worker nodes running kata,"; \
	    echo "         edit helm/osc/templates/tdx-machine-config.yaml and"; \
	    echo "         helm/osc/templates/iommu-machine-config.yaml to set role: worker, then apply manually."; \
	else \
	    NEEDS_REBOOT=false; \
	    if oc get mc 99-enable-intel-tdx --ignore-not-found 2>/dev/null | grep -q .; then \
	        echo "WARNING: TDX MachineConfig already exists, skipping."; \
	    else \
	        oc apply -f helm/osc/templates/tdx-machine-config.yaml; \
	        NEEDS_REBOOT=true; \
	    fi; \
	    if oc get mc 100-iommu-kernel-args --ignore-not-found 2>/dev/null | grep -q .; then \
	        echo "WARNING: IOMMU MachineConfig already exists, skipping."; \
	    else \
	        oc apply -f helm/osc/templates/iommu-machine-config.yaml; \
	        NEEDS_REBOOT=true; \
	    fi; \
	    if [ "$$NEEDS_REBOOT" = "true" ]; then \
	        echo "WARNING: Node will now reboot to apply kernel parameters (~10 min)."; \
	        echo "         API server will be briefly unreachable during the reboot."; \
	        sleep 30; \
	        DEADLINE=$$(( $$(date +%s) + 1200 )); \
	        until oc get mcp master --no-headers 2>/dev/null \
	                | awk '{print $$3,$$4,$$5}' | grep -q "True False False"; do \
	            if [ $$(date +%s) -ge $$DEADLINE ]; then \
	                echo "ERROR: master MCP did not complete reboot in 20 min."; \
	                echo "       Run: oc get mcp master && oc get nodes"; \
	                exit 1; \
	            fi; \
	            sleep 15; \
	        done; \
	        echo "Node reboot complete."; \
	    fi; \
	fi; \
	echo "Verifying TDX is active in kernel (spawning debug pod — ~30s)..."; \
	NODE_NAME=$$(oc get nodes -o jsonpath='{.items[0].metadata.name}'); \
	oc debug node/$$NODE_NAME -- chroot /host journalctl -k 2>/dev/null \
	    | grep -i tdx > /tmp/tdx-verify.txt || true; \
	if grep -q "BIOS enabled" /tmp/tdx-verify.txt && \
	        ! grep -q "initialization failed" /tmp/tdx-verify.txt; then \
	    echo "TDX active: $$(grep 'BIOS enabled' /tmp/tdx-verify.txt | tail -1 | sed 's/.*tdx: //')"; \
	    rm -f /tmp/tdx-verify.txt; \
	    echo "=== setup-intel-tee complete — run make setup-kata next ==="; \
	elif grep -q "initialization failed: Hibernation" /tmp/tdx-verify.txt; then \
	    echo "ERROR: TDX BIOS enabled but kernel init blocked by hibernation."; \
	    echo "       The nohibernate kernel arg should have been applied — check:"; \
	    echo "         oc get mc 99-enable-intel-tdx -o jsonpath='{.spec.kernelArguments}'"; \
	    rm -f /tmp/tdx-verify.txt; \
	    exit 1; \
	else \
	    echo "ERROR: TDX not active in kernel — check BIOS settings (see README hardware prerequisites)."; \
	    rm -f /tmp/tdx-verify.txt; \
	    exit 1; \
	fi

.PHONY: setup-amd-tee
setup-amd-tee:
	@set -e; \
	echo "=== setup-amd-tee: AMD SEV-SNP IOMMU parameters ==="; \
	PURE_WORKERS=$$(oc get nodes -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/master' \
	    --no-headers 2>/dev/null | wc -l | tr -d ' '); \
	if [ "$$PURE_WORKERS" != "0" ]; then \
	    echo "WARNING: Multi-node cluster detected."; \
	    echo "         IOMMU MachineConfig targets master role by default — for worker nodes running kata,"; \
	    echo "         edit helm/osc/templates/iommu-machine-config.yaml to set role: worker, then apply manually."; \
	else \
	    if oc get mc 100-iommu-kernel-args --ignore-not-found 2>/dev/null | grep -q .; then \
	        echo "WARNING: IOMMU MachineConfig already exists, skipping."; \
	    else \
	        oc apply -f helm/osc/templates/iommu-machine-config.yaml; \
	        echo "WARNING: Node will now reboot to apply IOMMU parameters (~10 min)."; \
	        echo "         API server will be briefly unreachable during the reboot."; \
	        sleep 30; \
	        DEADLINE=$$(( $$(date +%s) + 1200 )); \
	        until oc get mcp master --no-headers 2>/dev/null \
	                | awk '{print $$3,$$4,$$5}' | grep -q "True False False"; do \
	            if [ $$(date +%s) -ge $$DEADLINE ]; then \
	                echo "ERROR: master MCP did not complete reboot in 20 min."; \
	                echo "       Run: oc get mcp master && oc get nodes"; \
	                exit 1; \
	            fi; \
	            sleep 15; \
	        done; \
	        echo "Node reboot complete."; \
	    fi; \
	fi; \
	echo "Verifying SEV-SNP is active in kernel (spawning debug pod — ~30s)..."; \
	NODE_NAME=$$(oc get nodes -o jsonpath='{.items[0].metadata.name}'); \
	oc debug node/$$NODE_NAME -- chroot /host journalctl -k 2>/dev/null \
	    | grep -iE "sev.snp|sev snp" > /tmp/snp-verify.txt || true; \
	if grep -qi "snp" /tmp/snp-verify.txt; then \
	    echo "SEV-SNP active: $$(grep -i snp /tmp/snp-verify.txt | tail -1 | sed 's/.*\] //')"; \
	    rm -f /tmp/snp-verify.txt; \
	    echo "=== setup-amd-tee complete — run make setup-kata next ==="; \
	else \
	    echo "ERROR: SEV-SNP not detected in kernel journal."; \
	    echo "       Verify BIOS settings — SEV-SNP must be enabled in server firmware (see README)."; \
	    rm -f /tmp/snp-verify.txt; \
	    exit 1; \
	fi

.PHONY: setup-kata
setup-kata:
	@set -e; \
	echo "=== setup-kata: Node Feature Discovery and OpenShift Sandboxed Containers ==="; \
	echo "=== Pre-flight checks ==="; \
	if ! oc get csv -n nvidia-gpu-operator 2>/dev/null \
	        | grep -q "gpu-operator.*Succeeded"; then \
	    echo "ERROR: NVIDIA GPU Operator not found (namespace: nvidia-gpu-operator)."; \
	    echo "       Install it via OperatorHub before running this target."; \
	    exit 1; \
	fi; \
	echo "GPU Operator: OK"; \
	if ! oc get mc 100-iommu-kernel-args --ignore-not-found 2>/dev/null | grep -q .; then \
	    echo "ERROR: IOMMU MachineConfig not found."; \
	    echo "       Run make setup-intel-tee (Intel) or make setup-amd-tee (AMD) first."; \
	    exit 1; \
	fi; \
	echo "TEE MachineConfig: OK"; \
	\
	echo "=== Step 1: Node Feature Discovery ==="; \
	if oc get csv -n openshift-nfd 2>/dev/null \
	        | grep -q "nfd.*Succeeded"; then \
	    echo "WARNING: NFD operator already installed, skipping."; \
	else \
	    echo "Installing Node Feature Discovery operator..."; \
	    oc apply -f helm/osc/templates/nfd-namespace.yaml; \
	    oc apply -f helm/osc/templates/nfd-operatorgroup.yaml; \
	    oc apply -f helm/osc/templates/nfd-subscription.yaml; \
	    until oc get csv -n openshift-nfd 2>/dev/null \
	            | grep -q "nfd.*Succeeded"; do sleep 10; done; \
	    echo "NFD operator ready."; \
	fi; \
	if oc get nodefeaturediscovery -n openshift-nfd \
	        --ignore-not-found 2>/dev/null | grep -q .; then \
	    echo "WARNING: NodeFeatureDiscovery CR already exists, skipping."; \
	else \
	    oc apply -f helm/osc/templates/nfd-instance.yaml; \
	fi; \
	echo "Waiting for NFD worker pods to be ready..."; \
	oc rollout status daemonset/nfd-worker -n openshift-nfd --timeout=5m 2>/dev/null || true; \
	if oc get nodefeaturerule tdx-features -n openshift-nfd \
	        --ignore-not-found 2>/dev/null | grep -q .; then \
	    echo "WARNING: NodeFeatureRule tdx-features already exists, skipping."; \
	else \
	    oc apply -f helm/osc/templates/node-feature-rule.yaml; \
	    echo "NodeFeatureRule applied."; \
	fi; \
	echo "Verifying TEE node label (waiting up to 2 min for NFD to reconcile)..."; \
	TEE_LABEL=""; \
	DEADLINE=$$(( $$(date +%s) + 120 )); \
	while [ $$(date +%s) -lt $$DEADLINE ]; do \
	    if oc get node -o jsonpath='{.items[*].metadata.labels}' 2>/dev/null \
	            | grep -q "intel.feature.node.kubernetes.io/tdx"; then \
	        TEE_LABEL="intel.feature.node.kubernetes.io/tdx"; break; \
	    elif oc get node -o jsonpath='{.items[*].metadata.labels}' 2>/dev/null \
	            | grep -q "amd.feature.node.kubernetes.io/snp"; then \
	        TEE_LABEL="amd.feature.node.kubernetes.io/snp"; break; \
	    fi; \
	    sleep 10; \
	done; \
	if [ -n "$$TEE_LABEL" ]; then \
	    echo "TEE label detected: $$TEE_LABEL"; \
	else \
	    echo "ERROR: No TEE label found (intel.feature.node.kubernetes.io/tdx or amd.feature.node.kubernetes.io/snp) after 2 min."; \
	    echo "       Ensure BIOS TDX/SNP is enabled and setup-intel-tee/setup-amd-tee completed successfully."; \
	    exit 1; \
	fi; \
	\
	echo "=== Step 2: OpenShift Sandboxed Containers ==="; \
	if oc get csv -n openshift-sandboxed-containers-operator 2>/dev/null \
	        | grep -q "sandboxed-containers.*Succeeded"; then \
	    echo "WARNING: OSC operator already installed, skipping."; \
	else \
	    echo "Installing OpenShift Sandboxed Containers operator..."; \
	    oc apply -f helm/osc/templates/osc-namespace.yaml; \
	    oc apply -f helm/osc/templates/osc-operatorgroup.yaml; \
	    oc apply -f helm/osc/templates/osc-subscription.yaml; \
	    until oc get installplan -n openshift-sandboxed-containers-operator \
	            --ignore-not-found 2>/dev/null | grep -q .; do sleep 5; done; \
	    INSTALL_PLAN=$$(oc get installplan \
	        -n openshift-sandboxed-containers-operator \
	        -o jsonpath='{.items[0].metadata.name}'); \
	    oc patch installplan $$INSTALL_PLAN \
	        -n openshift-sandboxed-containers-operator \
	        --type merge --patch '{"spec":{"approved":true}}'; \
	    until oc get csv -n openshift-sandboxed-containers-operator 2>/dev/null \
	            | grep -q "sandboxed-containers.*Succeeded"; do sleep 10; done; \
	    echo "OSC operator ready."; \
	fi; \
	if oc get configmap osc-feature-gates \
	        -n openshift-sandboxed-containers-operator \
	        --ignore-not-found 2>/dev/null | grep -q .; then \
	    echo "WARNING: osc-feature-gates ConfigMap already exists, skipping."; \
	else \
	    oc apply -f helm/osc/templates/01-osc-feature-gates.yaml; \
	fi; \
	if oc get kataconfig --ignore-not-found 2>/dev/null | grep -q .; then \
	    echo "WARNING: KataConfig already exists, skipping."; \
	    KATA_CHANGED=false; \
	else \
	    PURE_WORKERS=$$(oc get nodes -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/master' \
	        --no-headers 2>/dev/null | wc -l | tr -d ' '); \
	    if [ "$$PURE_WORKERS" = "0" ]; then \
	        echo "WARNING: Single-node cluster — using master-pool KataConfig (node will reboot ~10 min)."; \
	        oc apply -f helm/osc/templates/kataconfig-sno.yaml; \
	    else \
	        echo "WARNING: Multi-node cluster — using default KataConfig (nodes reboot in sequence)."; \
	        oc apply -f helm/osc/templates/kataconfig.yaml; \
	    fi; \
	    KATA_CHANGED=true; \
	fi; \
	PURE_WORKERS=$$(oc get nodes -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/master' \
	    --no-headers 2>/dev/null | wc -l | tr -d ' '); \
	if [ "$$PURE_WORKERS" = "0" ]; then KATA_MCP=master; else KATA_MCP=kata-oc; fi; \
	echo "Waiting for MachineConfigPool $$KATA_MCP rollout (up to 45 min)..."; \
	if [ "$$KATA_CHANGED" = "true" ]; then SEEN_UPDATING=false; else SEEN_UPDATING=true; fi; \
	DEADLINE=$$(( $$(date +%s) + 2700 )); \
	while [ $$(date +%s) -lt $$DEADLINE ]; do \
	    STATUS=$$(oc get mcp $$KATA_MCP --no-headers 2>/dev/null | awk '{print $$3,$$4,$$5}'); \
	    if [ "$$STATUS" != "True False False" ]; then SEEN_UPDATING=true; fi; \
	    if [ "$$SEEN_UPDATING" = "true" ] && [ "$$STATUS" = "True False False" ]; then \
	        echo "MachineConfigPool $$KATA_MCP is updated."; break; \
	    fi; \
	    sleep 10; \
	done; \
	if [ $$(date +%s) -ge $$DEADLINE ]; then \
	    echo "ERROR: MachineConfigPool $$KATA_MCP did not complete in 45 min."; \
	    echo "       Run: oc get mcp && oc get nodes"; \
	    exit 1; \
	fi; \
	echo "Waiting for kata-cc runtimeClass (up to 15 min)..."; \
	DEADLINE=$$(( $$(date +%s) + 900 )); \
	until oc get runtimeclass kata-cc 2>/dev/null; do \
	    if [ $$(date +%s) -ge $$DEADLINE ]; then \
	        echo "ERROR: kata-cc runtimeClass not found after 15 min."; exit 1; \
	    fi; \
	    sleep 30; \
	done; \
	echo "Waiting for kata-cc-nvidia-gpu runtimeClass (up to 15 min)..."; \
	DEADLINE=$$(( $$(date +%s) + 900 )); \
	until oc get runtimeclass kata-cc-nvidia-gpu 2>/dev/null; do \
	    if [ $$(date +%s) -ge $$DEADLINE ]; then \
	        echo "ERROR: kata-cc-nvidia-gpu not found after 15 min."; \
	        echo "       Verify GPU Operator ClusterPolicy is healthy."; exit 1; \
	    fi; \
	    sleep 30; \
	done; \
	echo "kata-cc-nvidia-gpu runtimeClass is ready."; \
	echo "Configuring NVIDIA GPU Operator for kata VM passthrough (sandbox workloads)..."; \
	oc patch clusterpolicy gpu-cluster-policy \
	    --type merge \
	    -p '{"spec":{"sandboxWorkloads":{"enabled":true,"defaultWorkload":"container","mode":"kata"}}}'; \
	echo "GPU nodes available in this cluster:"; \
	oc get nodes -l nvidia.com/gpu.present=true \
	    -o custom-columns=NAME:.metadata.name,WORKLOAD:.metadata.labels."nvidia\.com/gpu\.workload\.config" \
	    --no-headers; \
	PASSTHROUGH_NODES="$(GPU_PASSTHROUGH_NODES)"; \
	if [ -z "$$PASSTHROUGH_NODES" ]; then \
	    echo ""; \
	    echo "WARNING: GPU_PASSTHROUGH_NODES is not set — no nodes will be labeled for VM passthrough."; \
	    echo "         Nodes labeled vm-passthrough stop advertising nvidia.com/gpu and only"; \
	    echo "         advertise nvidia.com/pgpu. Unlabeled nodes are unaffected."; \
	    echo "         To label node(s) without re-running the full setup, use:"; \
	    echo "           make setup-gpu-passthrough GPU_PASSTHROUGH_NODES=\"<node1> <node2>\""; \
	else \
	    for NODE in $$PASSTHROUGH_NODES; do \
	        if oc get node "$$NODE" &>/dev/null; then \
	            oc label node "$$NODE" nvidia.com/gpu.workload.config=vm-passthrough --overwrite; \
	            echo "Node $$NODE labeled for VM passthrough."; \
	        else \
	            echo "WARNING: Node '$$NODE' not found — skipping."; \
	        fi; \
	    done; \
	fi; \
	echo "Applying KubeletConfig to extend container-creation timeout for kata guest-pull..."; \
	PURE_WORKERS=$$(oc get nodes -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/master' \
	    --no-headers 2>/dev/null | wc -l | tr -d ' '); \
	if [ "$$PURE_WORKERS" = "0" ]; then \
	    KUBELET_APPLY_OUT=$$(oc apply -f helm/osc/templates/kubelet-config-sno.yaml); \
	    KUBELET_MCP=master; \
	else \
	    KUBELET_APPLY_OUT=$$(oc apply -f helm/osc/templates/kubelet-config.yaml); \
	    KUBELET_MCP=worker; \
	fi; \
	echo "$$KUBELET_APPLY_OUT"; \
	if echo "$$KUBELET_APPLY_OUT" | grep -q unchanged; then KUBELET_CHANGED=false; else KUBELET_CHANGED=true; fi; \
	echo "KubeletConfig applied — waiting for MachineConfigPool $$KUBELET_MCP rollout (up to 45 min)..."; \
	if [ "$$KUBELET_CHANGED" = "true" ]; then SEEN_UPDATING=false; else SEEN_UPDATING=true; fi; \
	DEADLINE=$$(( $$(date +%s) + 2700 )); \
	while [ $$(date +%s) -lt $$DEADLINE ]; do \
	    STATUS=$$(oc get mcp $$KUBELET_MCP --no-headers 2>/dev/null | awk '{print $$3,$$4,$$5}'); \
	    if [ "$$STATUS" != "True False False" ]; then SEEN_UPDATING=true; fi; \
	    if [ "$$SEEN_UPDATING" = "true" ] && [ "$$STATUS" = "True False False" ]; then \
	        echo "MachineConfigPool $$KUBELET_MCP is updated."; break; \
	    fi; \
	    sleep 10; \
	done; \
	if [ $$(date +%s) -ge $$DEADLINE ]; then \
	    echo "ERROR: MachineConfigPool $$KUBELET_MCP did not complete in 45 min."; \
	    echo "       Run: oc get mcp && oc get nodes"; \
	    exit 1; \
	fi; \
	echo "=== setup-kata complete — run make setup-cc-gpu next ==="

.PHONY: setup-gpu-passthrough
setup-gpu-passthrough:
	@set -e; \
	echo "=== GPU passthrough node labeling ==="; \
	echo "GPU nodes available in this cluster:"; \
	oc get nodes -l nvidia.com/gpu.present=true \
	    -o custom-columns=NAME:.metadata.name,WORKLOAD:.metadata.labels."nvidia\.com/gpu\.workload\.config" \
	    --no-headers; \
	echo "Patching ClusterPolicy for sandbox workloads (idempotent)..."; \
	oc patch clusterpolicy gpu-cluster-policy \
	    --type merge \
	    -p '{"spec":{"sandboxWorkloads":{"enabled":true,"defaultWorkload":"container","mode":"kata"}}}'; \
	PASSTHROUGH_NODES="$(GPU_PASSTHROUGH_NODES)"; \
	if [ -z "$$PASSTHROUGH_NODES" ]; then \
	    echo "ERROR: GPU_PASSTHROUGH_NODES is not set."; \
	    echo "       Usage: make setup-gpu-passthrough GPU_PASSTHROUGH_NODES=\"<node1> <node2>\""; \
	    echo "       Run 'make setup-gpu-passthrough' without the variable to list available nodes."; \
	    exit 1; \
	fi; \
	for NODE in $$PASSTHROUGH_NODES; do \
	    if oc get node "$$NODE" &>/dev/null; then \
	        oc label node "$$NODE" nvidia.com/gpu.workload.config=vm-passthrough --overwrite; \
	        echo "Node $$NODE labeled for VM passthrough."; \
	    else \
	        echo "WARNING: Node '$$NODE' not found — skipping."; \
	    fi; \
	done; \
	echo ""; \
	echo "Nodes labeled vm-passthrough will stop advertising nvidia.com/gpu"; \
	echo "and advertise nvidia.com/pgpu once the Sandbox Device Plugin restarts."; \
	echo "Verify with: oc get node <node> -o jsonpath='{.status.allocatable}'"

.PHONY: setup-cc-gpu
setup-cc-gpu:
	@set -e; \
	echo "=== setup-cc-gpu: Configure GPU Operator for confidential containers ==="; \
	echo "=== Pre-flight checks ==="; \
	if ! oc get csv -n nvidia-gpu-operator 2>/dev/null \
	        | grep -q "gpu-operator.*Succeeded"; then \
	    echo "ERROR: NVIDIA GPU Operator not found (namespace: nvidia-gpu-operator)."; \
	    echo "       Install it via OperatorHub before running this target."; \
	    exit 1; \
	fi; \
	echo "GPU Operator: OK"; \
	if ! oc get runtimeclass kata-cc-nvidia-gpu 2>/dev/null | grep -q .; then \
	    echo "ERROR: kata-cc-nvidia-gpu runtimeClass not found."; \
	    echo "       Run make setup-kata first."; \
	    exit 1; \
	fi; \
	echo "kata-cc-nvidia-gpu runtimeClass: OK"; \
	\
	echo "=== Patching ClusterPolicy for confidential computing mode ==="; \
	echo "  ccManager: enabled=true, defaultMode=on"; \
	echo "  driver/toolkit/devicePlugin: enabled=false (run inside kata guest VM)"; \
	oc patch clusterpolicy gpu-cluster-policy --type merge \
	    -p '{"spec":{"ccManager":{"enabled":true,"defaultMode":"on"},"driver":{"enabled":false},"toolkit":{"enabled":false},"devicePlugin":{"enabled":false}}}'; \
	\
	echo "Checking for NVLink/SXM GPU nodes (nvidia.com/gpu.deploy.nvsm label)..."; \
	NVSWITCH_COUNT=$$(oc get nodes -l 'nvidia.com/gpu.deploy.nvsm' --no-headers 2>/dev/null \
	    | wc -l | tr -d ' '); \
	if [ "$$NVSWITCH_COUNT" -gt 0 ]; then \
	    echo "  NVSwitch node(s) detected — enabling vfioManager with BIND_NVSWITCHES=true"; \
	    oc patch clusterpolicy gpu-cluster-policy --type=merge \
	        -p '{"spec":{"vfioManager":{"enabled":true,"env":[{"name":"BIND_NVSWITCHES","value":"true"}]}}}'; \
	else \
	    echo "  No NVSwitch nodes detected — enabling vfioManager without BIND_NVSWITCHES"; \
	    oc patch clusterpolicy gpu-cluster-policy --type=merge \
	        -p '{"spec":{"vfioManager":{"enabled":true}}}'; \
	fi; \
	\
	echo "Waiting for GPU Operator to reconcile (up to 10 min)..."; \
	echo "  nvidia-driver-daemonset will be removed; cc-manager and vfio-manager will start"; \
	DEADLINE=$$(( $$(date +%s) + 600 )); \
	while [ $$(date +%s) -lt $$DEADLINE ]; do \
	    DRIVER_DS=$$(oc get daemonset -n nvidia-gpu-operator \
	        nvidia-driver-daemonset --ignore-not-found --no-headers 2>/dev/null \
	        | wc -l | tr -d ' '); \
	    CC_RUNNING=$$(oc get pods -n nvidia-gpu-operator --no-headers 2>/dev/null \
	        | grep cc-manager | grep Running | wc -l | tr -d ' '); \
	    VFIO_RUNNING=$$(oc get pods -n nvidia-gpu-operator --no-headers 2>/dev/null \
	        | grep vfio-manager | grep Running | wc -l | tr -d ' '); \
	    if [ "$$DRIVER_DS" = "0" ] && [ "$$CC_RUNNING" -gt 0 ] && [ "$$VFIO_RUNNING" -gt 0 ]; then \
	        echo "  GPU Operator reconciled: driver removed, cc-manager and vfio-manager running."; \
	        break; \
	    fi; \
	    printf "  driver-daemonset: %s  cc-manager running: %s  vfio-manager running: %s\n" \
	        "$$DRIVER_DS" "$$CC_RUNNING" "$$VFIO_RUNNING"; \
	    sleep 20; \
	done; \
	if [ $$(date +%s) -ge $$DEADLINE ]; then \
	    echo "ERROR: GPU Operator did not reconcile in 10 min."; \
	    echo "       Check: oc get pods -n nvidia-gpu-operator"; \
	    echo "       Logs:  oc logs -n nvidia-gpu-operator deploy/gpu-operator --tail=30"; \
	    exit 1; \
	fi; \
	\
	echo ""; \
	echo "=== Verifying CC mode labels on GPU nodes ==="; \
	GPU_NODES=$$(oc get nodes -l nvidia.com/gpu.present=true \
	    --no-headers 2>/dev/null | awk '{print $$1}'); \
	for GPU_NODE in $$GPU_NODES; do \
	    echo ""; \
	    echo "  Node: $$GPU_NODE"; \
	    for LABEL in \
	        "nvidia.com/gpu.deploy.vfio-manager" \
	        "nvidia.com/gpu.deploy.kata-sandbox-device-plugin" \
	        "nvidia.com/cc.mode.state" \
	        "nvidia.com/cc.ready.state" \
	        "nvidia.com/gpu.deploy.cc-manager"; do \
	        VAL=$$(oc get node "$$GPU_NODE" \
	            -o jsonpath="{.metadata.labels['$$LABEL']}" 2>/dev/null || true); \
	        if [ -n "$$VAL" ]; then \
	            echo "  ✓ $$LABEL: $$VAL"; \
	        else \
	            echo "  ✗ $$LABEL: (MISSING)"; \
	        fi; \
	    done; \
	done; \
	\
	echo ""; \
	echo "=== setup-cc-gpu complete ==="; \
	echo "If cc.mode.state is 'on' and cc.ready.state is 'true', GPU is ready for kata CC workloads."; \
	echo "Run make setup-dcap next (Intel TDX), or make setup-trustee-in-cluster if DCAP is already configured."

.PHONY: verify-gpu-passthrough
verify-gpu-passthrough:
	@PASS=0; FAIL=0; WARN=0; \
	ok()   { echo "  [PASS] $$1"; PASS=$$((PASS+1)); }; \
	fail() { echo "  [FAIL] $$1"; FAIL=$$((FAIL+1)); }; \
	warn() { echo "  [WARN] $$1"; WARN=$$((WARN+1)); }; \
	\
	echo ""; \
	echo "=== ClusterPolicy settings ==="; \
	CP_TMPFILE=$$(mktemp); \
	oc get clusterpolicy gpu-cluster-policy -o json > "$$CP_TMPFILE" 2>/dev/null || true; \
	if [ ! -s "$$CP_TMPFILE" ]; then \
	    fail "ClusterPolicy gpu-cluster-policy not found"; \
	    echo "       Hint: install the NVIDIA GPU Operator via OperatorHub first."; \
	else \
	    SW_ENABLED=$$(python3 -c "import json,sys; d=json.loads(open(sys.argv[1]).read(), strict=False); print(str(d.get('spec',{}).get('sandboxWorkloads',{}).get('enabled',False)).lower())" "$$CP_TMPFILE"); \
	    if [ "$$SW_ENABLED" = "true" ]; then \
	        ok "sandboxWorkloads.enabled = true"; \
	    else \
	        fail "sandboxWorkloads.enabled is not true"; \
	        echo "       Hint: run: make setup-gpu-passthrough GPU_PASSTHROUGH_NODES=\"<node1> <node2>\""; \
	    fi; \
	    \
	    VFIO_ENABLED=$$(python3 -c "import json,sys; d=json.loads(open(sys.argv[1]).read(), strict=False); print(str(d.get('spec',{}).get('vfioManager',{}).get('enabled',False)).lower())" "$$CP_TMPFILE"); \
	    if [ "$$VFIO_ENABLED" = "true" ]; then \
	        ok "vfioManager.enabled = true"; \
	    else \
	        fail "vfioManager.enabled is not true — VFIO manager must be enabled for GPU passthrough"; \
	        echo "       Hint: oc patch clusterpolicy gpu-cluster-policy --type merge -p '{\"spec\":{\"vfioManager\":{\"enabled\":true}}}'"; \
	    fi; \
	    \
	    CC_ENABLED=$$(python3 -c "import json,sys; d=json.loads(open(sys.argv[1]).read(), strict=False); print(str(d.get('spec',{}).get('ccManager',{}).get('enabled',False)).lower())" "$$CP_TMPFILE"); \
	    if [ "$$CC_ENABLED" = "true" ]; then \
	        ok "ccManager.enabled = true"; \
	    else \
	        fail "ccManager.enabled is not true — CC manager is required for confidential containers"; \
	        echo "       Hint: oc patch clusterpolicy gpu-cluster-policy --type merge -p '{\"spec\":{\"ccManager\":{\"enabled\":true}}}'"; \
	    fi; \
	    \
	    DP_ENABLED=$$(python3 -c "import json,sys; d=json.loads(open(sys.argv[1]).read(), strict=False); print(str(d.get('spec',{}).get('devicePlugin',{}).get('enabled',True)).lower())" "$$CP_TMPFILE"); \
	    if [ "$$DP_ENABLED" = "false" ]; then \
	        ok "devicePlugin.enabled = false"; \
	    else \
	        fail "devicePlugin.enabled is true — must be false (conflicts with sandbox device plugin)"; \
	        echo "       Hint: oc patch clusterpolicy gpu-cluster-policy --type merge -p '{\"spec\":{\"devicePlugin\":{\"enabled\":false}}}'"; \
	    fi; \
	    \
	    DRV_ENABLED=$$(python3 -c "import json,sys; d=json.loads(open(sys.argv[1]).read(), strict=False); print(str(d.get('spec',{}).get('driver',{}).get('enabled',True)).lower())" "$$CP_TMPFILE"); \
	    if [ "$$DRV_ENABLED" = "false" ]; then \
	        ok "driver.enabled = false"; \
	    else \
	        fail "driver.enabled is true — must be false (driver runs inside kata VM, not on host)"; \
	        echo "       Hint: oc patch clusterpolicy gpu-cluster-policy --type merge -p '{\"spec\":{\"driver\":{\"enabled\":false}}}'"; \
	    fi; \
	    \
	    TK_ENABLED=$$(python3 -c "import json,sys; d=json.loads(open(sys.argv[1]).read(), strict=False); print(str(d.get('spec',{}).get('toolkit',{}).get('enabled',True)).lower())" "$$CP_TMPFILE"); \
	    if [ "$$TK_ENABLED" = "false" ]; then \
	        ok "toolkit.enabled = false"; \
	    else \
	        fail "toolkit.enabled is true — must be false (not needed for passthrough)"; \
	        echo "       Hint: oc patch clusterpolicy gpu-cluster-policy --type merge -p '{\"spec\":{\"toolkit\":{\"enabled\":false}}}'"; \
	    fi; \
	fi; \
	rm -f "$$CP_TMPFILE"; \
	\
	echo ""; \
	echo "=== Node labels ==="; \
	GPU_NODES=$$(oc get nodes -l nvidia.com/gpu.present=true \
	    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); \
	if [ -z "$$GPU_NODES" ]; then \
	    fail "No nodes with nvidia.com/gpu.present=true found"; \
	else \
	    for NODE in $$GPU_NODES; do \
	        WL_CONFIG=$$(oc get node "$$NODE" \
	            -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.workload\.config}' 2>/dev/null); \
	        if [ "$$WL_CONFIG" = "vm-passthrough" ]; then \
	            ok "$$NODE: nvidia.com/gpu.workload.config=vm-passthrough"; \
	        elif [ -n "$$WL_CONFIG" ]; then \
	            warn "$$NODE: nvidia.com/gpu.workload.config=$$WL_CONFIG (expected vm-passthrough)"; \
	            echo "       Hint: make setup-gpu-passthrough GPU_PASSTHROUGH_NODES=\"$$NODE\""; \
	        else \
	            fail "$$NODE: nvidia.com/gpu.workload.config label not set"; \
	            echo "       Hint: make setup-gpu-passthrough GPU_PASSTHROUGH_NODES=\"$$NODE\""; \
	        fi; \
	    done; \
	fi; \
	\
	echo ""; \
	echo "=== Key pods (nvidia-gpu-operator namespace) ==="; \
	VFIO_PODS=$$(oc get pods -n nvidia-gpu-operator 2>/dev/null \
	    | grep -i "vfio-manager" | grep -c "Running" || true); \
	[ -z "$$VFIO_PODS" ] && VFIO_PODS=0; \
	if [ "$$VFIO_PODS" -gt 0 ]; then \
	    ok "VFIO manager: $$VFIO_PODS pod(s) Running"; \
	else \
	    fail "VFIO manager: no Running pods"; \
	    echo "       Hint: oc get pods -n nvidia-gpu-operator | grep vfio"; \
	    echo "              If missing, verify driver.enabled=false in ClusterPolicy."; \
	fi; \
	\
	SDP_PODS=$$(oc get pods -n nvidia-gpu-operator 2>/dev/null \
	    | grep -i "sandbox-device-plugin" | grep -c "Running" || true); \
	[ -z "$$SDP_PODS" ] && SDP_PODS=0; \
	if [ "$$SDP_PODS" -gt 0 ]; then \
	    ok "Sandbox device plugin: $$SDP_PODS pod(s) Running"; \
	else \
	    fail "Sandbox device plugin: no Running pods — nvidia.com/pgpu will not be advertised"; \
	    echo "       Hint: oc get pods -n nvidia-gpu-operator | grep sandbox"; \
	fi; \
	\
	CC_PODS=$$(oc get pods -n nvidia-gpu-operator 2>/dev/null \
	    | grep -i "cc-manager" | grep -c "Running" || true); \
	[ -z "$$CC_PODS" ] && CC_PODS=0; \
	if [ "$$CC_PODS" -gt 0 ]; then \
	    ok "CC manager: $$CC_PODS pod(s) Running"; \
	else \
	    warn "CC manager: no Running pods — needed for GPU attestation inside kata VM"; \
	    echo "       Hint: oc get pods -n nvidia-gpu-operator | grep cc-manager"; \
	fi; \
	\
	echo ""; \
	echo "=== pgpu allocatable resources ==="; \
	PGPU_FOUND=false; \
	for NODE in $$GPU_NODES; do \
	    WL_CONFIG=$$(oc get node "$$NODE" \
	        -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.workload\.config}' 2>/dev/null); \
	    if [ "$$WL_CONFIG" = "vm-passthrough" ]; then \
	        PGPU_COUNT=$$(oc get node "$$NODE" \
	            -o jsonpath='{.status.allocatable.nvidia\.com/pgpu}' 2>/dev/null); \
	        if [ -n "$$PGPU_COUNT" ] && [ "$$PGPU_COUNT" != "0" ]; then \
	            ok "$$NODE: nvidia.com/pgpu = $$PGPU_COUNT allocatable"; \
	            PGPU_FOUND=true; \
	        else \
	            fail "$$NODE: nvidia.com/pgpu is 0 or not reported"; \
	            echo "       Hint: sandbox device plugin may not be running or has not re-registered."; \
	            echo "              oc get pods -n nvidia-gpu-operator | grep sandbox-device-plugin"; \
	        fi; \
	    fi; \
	done; \
	if [ "$$PGPU_FOUND" = "false" ] && [ -n "$$GPU_NODES" ]; then \
	    fail "No nodes have nvidia.com/pgpu allocatable — pods requesting pgpu will stay Pending"; \
	    echo "       Hint: make setup-gpu-passthrough GPU_PASSTHROUGH_NODES=\"<node1> <node2>\""; \
	fi; \
	\
	echo ""; \
	echo "=== Summary ==="; \
	echo "  PASS: $$PASS   FAIL: $$FAIL   WARN: $$WARN"; \
	echo ""; \
	if [ "$$FAIL" -gt 0 ]; then \
	    echo "  GPU passthrough is NOT correctly configured. Fix FAIL items above."; \
	    exit 1; \
	elif [ "$$WARN" -gt 0 ]; then \
	    echo "  GPU passthrough is mostly configured. Review WARN items above."; \
	else \
	    echo "  GPU passthrough is correctly configured. Ready for: make install"; \
	fi

.PHONY: rescan-gpus
rescan-gpus:
	@set -e; \
	PODS=$$(oc get pods -n nvidia-gpu-operator --no-headers 2>/dev/null \
	    | grep '^nvidia-kata-sandbox-device-plugin-daemonset-' | awk '{print $$1}'); \
	if [ -z "$$PODS" ]; then \
	    echo "WARNING: no nvidia-kata-sandbox-device-plugin-daemonset pods found in nvidia-gpu-operator — nothing to rescan."; \
	    exit 0; \
	fi; \
	TOTAL=$$(echo "$$PODS" | wc -l); \
	echo "Deleting $$TOTAL sandbox device plugin pod(s) to force a fresh vfio-pci device scan:"; \
	echo "$$PODS"; \
	oc delete pod -n nvidia-gpu-operator $$PODS; \
	echo "Waiting up to 2 min for replacement pod(s) to be Running..."; \
	READY=false; \
	DEADLINE=$$(( $$(date +%s) + 120 )); \
	while [ $$(date +%s) -lt $$DEADLINE ]; do \
	    READY_COUNT=$$(oc get pods -n nvidia-gpu-operator --no-headers 2>/dev/null \
	        | grep '^nvidia-kata-sandbox-device-plugin-daemonset-' | grep ' Running ' | wc -l); \
	    if [ "$$READY_COUNT" -ge "$$TOTAL" ]; then READY=true; break; fi; \
	    sleep 5; \
	done; \
	if [ "$$READY" != "true" ]; then \
	    echo "ERROR: replacement pod(s) did not reach Running within 2 min."; \
	    oc get pods -n nvidia-gpu-operator | grep sandbox; \
	    exit 1; \
	fi; \
	echo "=== rescan-gpus complete ==="; \
	echo "Verify with: oc get node <node> -o jsonpath='{.status.allocatable}' | python3 -c \"import json,sys; a=json.load(sys.stdin); print({k:v for k,v in a.items() if 'nvidia' in k})\""

.PHONY: validate-node-labels
validate-node-labels:
	@set -e; \
	echo "=== Node label validation for kata-cc-nvidia-gpu ==="; \
	GPU_NODES=$$(oc get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | awk '{print $$1}'); \
	if [ -z "$$GPU_NODES" ]; then \
	    echo "No nodes with nvidia.com/gpu.present=true found."; exit 1; \
	fi; \
	for GPU_NODE in $$GPU_NODES; do \
	    echo ""; \
	    oc get node "$$GPU_NODE" -o json | python3 scripts/validate-node-labels.py; \
	done

.PHONY: setup-dcap
setup-dcap:
	@[ -n "$(INTEL_API_KEY)" ] || { \
	    echo "Error: INTEL_API_KEY is not set."; \
	    echo "       Get a free API key at https://api.portal.trustedservices.intel.com/"; \
	    echo "       Then run: make setup-dcap INTEL_API_KEY=<your-key>"; \
	    exit 1; \
	}
	@set -e; \
	echo "=== setup-dcap: Intel SGX Device Plugin and Intel TDX DCAP Operator ==="; \
	\
	echo "=== Step 1: intel-dcap namespace ==="; \
	if oc get namespace intel-dcap --ignore-not-found 2>/dev/null | grep -q .; then \
	    echo "WARNING: namespace intel-dcap already exists, skipping."; \
	else \
	    oc apply -f helm/osc/templates/intel-dcap-namespace.yaml; \
	fi; \
	\
	echo "=== Step 1a: Intel Device Plugin Operator ==="; \
	if oc get csv -n intel-dcap 2>/dev/null \
	        | grep -q "intel-device-plugins-operator.*Succeeded"; then \
	    echo "WARNING: Intel Device Plugin Operator already installed, skipping."; \
	else \
	    echo "Installing Intel Device Plugin Operator..."; \
	    oc apply -f helm/osc/templates/intel-dcap-dpo-operatorgroup.yaml; \
	    oc apply -f helm/osc/templates/intel-dcap-dpo-subscription.yaml; \
	    until oc get installplan -n intel-dcap \
	            --ignore-not-found 2>/dev/null | grep -q .; do sleep 5; done; \
	    INSTALL_PLAN=$$(oc get installplan -n intel-dcap \
	        -o jsonpath='{.items[0].metadata.name}'); \
	    oc patch installplan $$INSTALL_PLAN -n intel-dcap \
	        --type merge --patch '{"spec":{"approved":true}}'; \
	    until oc get csv -n intel-dcap 2>/dev/null \
	            | grep -q "intel-device-plugins-operator.*Succeeded"; do sleep 10; done; \
	    echo "Intel Device Plugin Operator ready."; \
	fi; \
	\
	echo "=== Step 2: SGX Device Plugin ==="; \
	if oc get sgxdeviceplugin sgxdeviceplugin-sample \
	        --ignore-not-found 2>/dev/null | grep -q .; then \
	    echo "WARNING: SgxDevicePlugin already exists, skipping."; \
	else \
	    oc apply -f helm/osc/templates/intel-dcap-sgx-plugin.yaml; \
	    echo "SGX Device Plugin CR applied — waiting for DaemonSet on SGX nodes..."; \
	    sleep 10; \
	fi; \
	\
	echo "=== Step 3: Intel PCS API key Secret ==="; \
	if oc get secret intel-pcs-api-key -n intel-dcap \
	        --ignore-not-found 2>/dev/null | grep -q .; then \
	    echo "WARNING: intel-pcs-api-key Secret already exists, skipping."; \
	else \
	    oc create secret generic intel-pcs-api-key \
	        -n intel-dcap \
	        --from-literal=api-key="$(INTEL_API_KEY)"; \
	    echo "intel-pcs-api-key Secret created."; \
	fi; \
	\
	echo "=== Step 4: Intel TDX DCAP Operator ==="; \
	if oc get csv -n intel-dcap 2>/dev/null \
	        | grep -q "intel-tdx-dcap-operator.*Succeeded"; then \
	    echo "WARNING: Intel TDX DCAP Operator already installed, skipping."; \
	else \
	    echo "Installing Intel TDX DCAP Operator..."; \
	    oc apply -f helm/osc/templates/intel-dcap-tdxqgs-subscription.yaml; \
	    echo "Waiting for DCAP InstallPlan..."; \
	    until oc get installplan -n intel-dcap -o jsonpath='{.items[*].spec.clusterServiceVersionNames[*]}' 2>/dev/null \
	            | grep -q "intel-tdx-dcap-operator"; do sleep 5; done; \
	    DCAP_INSTALL_PLAN=$$(oc get installplan -n intel-dcap -o json \
	        | python3 -c "import sys,json; items=json.load(sys.stdin)['items']; print(next(ip['metadata']['name'] for ip in items if 'intel-tdx-dcap-operator' in ' '.join(ip['spec'].get('clusterServiceVersionNames',[]))))"); \
	    oc patch installplan "$$DCAP_INSTALL_PLAN" -n intel-dcap \
	        --type merge --patch '{"spec":{"approved":true}}'; \
	    until oc get csv -n intel-dcap 2>/dev/null \
	            | grep -q "intel-tdx-dcap-operator.*Succeeded"; do sleep 10; done; \
	    echo "Intel TDX DCAP Operator ready."; \
	fi; \
	\
	echo "=== Step 4a: SCC for intel-tdx-dcap service account ==="; \
	oc adm policy add-scc-to-user privileged -z intel-tdx-dcap -n intel-dcap; \
	\
	echo "=== Step 5: TdxQuoteGenerationService CR ==="; \
	if oc get tdxquotegenerationservices.trustedservices.intel.com intel-tdx-dcap -n intel-dcap \
	        --ignore-not-found 2>/dev/null | grep -q .; then \
	    echo "WARNING: TdxQuoteGenerationService intel-tdx-dcap already exists, skipping."; \
	else \
	    oc apply -f helm/osc/templates/intel-dcap-tdxqgs-cr.yaml; \
	    echo "Waiting for QGS pod(s) to be ready on TDX nodes (up to 5 min)..."; \
	    DEADLINE=$$(( $$(date +%s) + 300 )); \
	    until oc get pods -n intel-dcap 2>/dev/null | grep intel-tdx-dcap-qgs | grep -q Running; do \
	        if [ $$(date +%s) -ge $$DEADLINE ]; then \
	            echo "WARNING: QGS pod not yet ready — check: oc get pods -n intel-dcap | grep intel-tdx-dcap-qgs"; \
	            echo "         Common cause: SGX resources not yet available (Intel Device Plugin still starting)."; \
	            echo "         Re-run setup-dcap once pods are running."; \
	            break; \
	        fi; \
	        sleep 10; \
	    done; \
	fi; \
	\
	echo "DCAP stack status:"; \
	oc get pods -n intel-dcap | grep intel-tdx-dcap-qgs || echo "(no intel-tdx-dcap-qgs pod yet)"; \
	oc get tdxquotegenerationservices.trustedservices.intel.com -n intel-dcap --ignore-not-found 2>/dev/null || true; \
	echo "=== setup-dcap complete — run make setup-trustee-in-cluster next ==="

.PHONY: verify-dcap
verify-dcap:
	@echo "=== Intel Device Plugin Operator ==="
	@oc get csv -n intel-dcap 2>/dev/null | grep intel-device-plugins-operator || echo "  Not found"
	@echo ""
	@echo "=== Intel TDX DCAP Operator ==="
	@oc get csv -n intel-dcap 2>/dev/null | grep intel-tdx-dcap-operator || echo "  Not found"
	@echo ""
	@echo "=== TdxQuoteGenerationService CR ==="
	@oc get tdxquotegenerationservices.trustedservices.intel.com -n intel-dcap 2>/dev/null || echo "  Not found"
	@echo ""
	@echo "=== QGS pod ==="
	@oc get pods -n intel-dcap 2>/dev/null | grep intel-tdx-dcap-qgs || echo "  Not found"

.PHONY: setup-trustee-in-cluster
setup-trustee-in-cluster:
	@set -e; \
	echo "=== Pre-flight checks ==="; \
	if ! oc get runtimeclass kata-cc 2>/dev/null | grep -q kata-cc; then \
	    echo "ERROR: kata-cc runtimeClass not found."; \
	    echo "       Run make setup-kata first."; \
	    exit 1; \
	fi; \
	echo "kata-cc runtimeClass: OK"; \
	\
	echo "=== Step 1: Trustee operator ==="; \
	if oc get csv -n trustee-operator-system 2>/dev/null \
	        | grep -q "trustee-operator.*Succeeded"; then \
	    echo "WARNING: Trustee operator already installed, skipping."; \
	else \
	    echo "Installing Trustee operator..."; \
	    oc apply -f helm/trustee/templates/trustee-namespace.yaml; \
	    oc apply -f helm/trustee/templates/trustee-operatorgroup.yaml; \
	    oc apply -f helm/trustee/templates/trustee-subscription.yaml; \
	    until oc get installplan -n trustee-operator-system \
	            --ignore-not-found 2>/dev/null | grep -q .; do sleep 5; done; \
	    INSTALL_PLAN=$$(oc get installplan -n trustee-operator-system \
	        -o jsonpath='{.items[0].metadata.name}'); \
	    oc patch installplan $$INSTALL_PLAN -n trustee-operator-system \
	        --type merge --patch '{"spec":{"approved":true}}'; \
	    until oc get csv -n trustee-operator-system 2>/dev/null \
	            | grep -q "trustee-operator.*Succeeded"; do sleep 10; done; \
	    echo "Trustee operator ready."; \
	fi; \
	\
	echo "=== Step 1a: cert-manager Issuer and TLS Certificates ==="; \
	if oc get secret trustee-tls-cert -n trustee-operator-system \
	        --ignore-not-found 2>/dev/null | grep -q .; then \
	    echo "WARNING: trustee-tls-cert Secret already exists, skipping cert creation."; \
	else \
	    bash scripts/apply-kbs-certs.sh; \
	fi; \
	\
	echo "=== Step 1b: NRAS API key (required for GPU CC attestation) ==="; \
	if [ -n "$(NRAS_API_KEY)" ]; then \
	    if oc get secret nras-api-key -n trustee-operator-system \
	            --ignore-not-found 2>/dev/null | grep -q .; then \
	        echo "WARNING: nras-api-key Secret already exists, skipping."; \
	    else \
	        oc create secret generic nras-api-key \
	            -n trustee-operator-system \
	            --from-literal=apiKey="$(NRAS_API_KEY)"; \
	        echo "nras-api-key Secret created."; \
	    fi; \
	else \
	    echo "WARNING: NRAS_API_KEY not set — GPU CC attestation will not be verified."; \
	    echo "         Create a personal NGC API key at https://ngc.nvidia.com:"; \
	    echo "           Click your name -> Account Settings -> Generate API Key"; \
	    echo "           Select 'Public API Endpoints' under Services Included."; \
	    echo "         Then re-run:"; \
	    echo "           make setup-trustee-in-cluster NRAS_API_KEY=<your-sak>"; \
	    echo "         The attestation policy enforces GPU CC mode — pods will fail attestation"; \
	    echo "         if the Trustee AS cannot contact NRAS to verify the GPU CC report."; \
	fi; \
	\
	echo "=== Step 2: TrusteeConfig (operator manages KbsConfig, policies, and RVPS configmap) ==="; \
	if oc get trusteeconfig -n trustee-operator-system \
	        --ignore-not-found 2>/dev/null | grep -q .; then \
	    echo "WARNING: TrusteeConfig already exists — KBS already deployed, skipping."; \
	else \
	    oc apply -f helm/trustee/templates/trustee-config.yaml; \
	    echo "Waiting for trustee-deployment to be created by the operator..."; \
	    DEADLINE=$$(( $$(date +%s) + 300 )); \
	    until oc get deployment trustee-deployment -n trustee-operator-system \
	            --ignore-not-found 2>/dev/null | grep -q .; do \
	        if [ $$(date +%s) -ge $$DEADLINE ]; then \
	            echo "ERROR: trustee-deployment not created after 5 min — check operator logs."; \
	            exit 1; \
	        fi; \
	        sleep 5; \
	    done; \
	    oc rollout status deployment/trustee-deployment \
	        -n trustee-operator-system --timeout=5m; \
	fi; \
	\
	echo "KBS route: $$(oc get route kbs-route \
	    -n trustee-operator-system -o jsonpath='{.spec.host}')"; \
	echo "=== setup-trustee-in-cluster complete ==="

.PHONY: collect-tdx-measurements
collect-tdx-measurements:
	@[ -n "$$NAMESPACE" ] || (echo "Error: NAMESPACE is not set"; exit 1)
	bash scripts/collect-tdx-measurements.sh "$(NAMESPACE)" "$(KATA_RUNTIME_CLASS)"

.PHONY: set-rvps-values
set-rvps-values:
	@[ -n "$$NAMESPACE" ] || (echo "Error: NAMESPACE is not set"; exit 1)
	@if [ -z "$(TDX_MR_TD)" ]; then \
	    echo "WARNING: TDX hardware measurements are not set."; \
	    echo "         Only mr_config_id will be registered — attestation will fail until"; \
	    echo "         you run scripts/collect-tdx-measurements.sh, export the printed"; \
	    echo "         values, and re-run 'make set-rvps-values'."; \
	    echo "         Required: TDX_MR_TD TDX_XFAM TDX_RTMR_0 TDX_RTMR_1 TDX_RTMR_2"; \
	    echo "         Optional: TDX_RTMR_3 TDX_TD_ATTRIBUTES TDX_MR_SEAM"; \
	fi
	@echo "Computing mr_config_id (initdata configuration binding) for namespace $(NAMESPACE)..."
	@set -e; \
	KBS_CERT=$$(oc get secret trusteeconfig-https-cert-secret -n trustee-operator-system \
	    -o jsonpath='{.data.certificate}' | base64 -d); \
	MR_CONFIG_ID=$$(echo "$$KBS_CERT" | python3 scripts/build-initdata.py "https://kbs-service.trustee-operator-system.svc.cluster.local:8080" "$(NAMESPACE)" --mr-config-id \
	    --policy-mode $(POLICY_MODE) \
	    --app-image $(APP_IMG) \
	    --model-image $(MODEL_IMG)); \
	echo "mr_config_id: $$MR_CONFIG_ID"; \
	[ -n "$(TDX_MR_SEAM)" ]       && echo "mr_seam:       $(TDX_MR_SEAM)"       || true; \
	[ -n "$(TDX_TD_ATTRIBUTES)" ] && echo "td_attributes: $(TDX_TD_ATTRIBUTES)" || true; \
	[ -n "$(TDX_MR_TD)" ]         && echo "mr_td:         $(TDX_MR_TD)"         || true; \
	[ -n "$(TDX_XFAM)" ]          && echo "xfam:          $(TDX_XFAM)"          || true; \
	[ -n "$(TDX_RTMR_0)" ]        && echo "rtmr_0:        $(TDX_RTMR_0)"        || true; \
	[ -n "$(TDX_RTMR_1)" ]        && echo "rtmr_1:        $(TDX_RTMR_1)"        || true; \
	[ -n "$(TDX_RTMR_2)" ]        && echo "rtmr_2:        $(TDX_RTMR_2)"        || true; \
	[ -n "$(TDX_RTMR_3)" ]        && echo "rtmr_3:        $(TDX_RTMR_3)"        || true; \
	CURRENT_REF=$$(oc get configmap trusteeconfig-rvps-reference-values \
	    -n trustee-operator-system \
	    -o jsonpath='{.data.reference_value}' 2>/dev/null || echo '{}'); \
	NEW_REF=$$(TDX_MR_SEAM="$(TDX_MR_SEAM)" TDX_TD_ATTRIBUTES="$(TDX_TD_ATTRIBUTES)" \
	    TDX_MR_TD="$(TDX_MR_TD)" TDX_XFAM="$(TDX_XFAM)" \
	    TDX_RTMR_0="$(TDX_RTMR_0)" TDX_RTMR_1="$(TDX_RTMR_1)" \
	    TDX_RTMR_2="$(TDX_RTMR_2)" TDX_RTMR_3="$(TDX_RTMR_3)" \
	    python3 scripts/update-rvps.py "$$CURRENT_REF" "$$MR_CONFIG_ID"); \
	PATCH=$$(echo "$$NEW_REF" | python3 -c 'import json,sys; print(json.dumps({"data":{"reference_value":sys.stdin.read().strip()}}))'); \
	oc patch configmap trusteeconfig-rvps-reference-values \
	    -n trustee-operator-system \
	    --type merge \
	    -p "$$PATCH"
	@echo "Restarting Trustee to pick up the updated RVPS configmap..."
	@oc rollout restart deployment/trustee-deployment -n trustee-operator-system
	@oc rollout status deployment/trustee-deployment -n trustee-operator-system --timeout=2m
	@echo "RVPS reference values registered for namespace $(NAMESPACE)."

.PHONY: register-secrets-with-kbs
register-secrets-with-kbs:
	@[ -n "$$NAMESPACE" ] || (echo "Error: NAMESPACE is not set"; exit 1)
	@[ -n "$$MODEL_ENCRYPTION_KEY" ] || (echo "Error: MODEL_ENCRYPTION_KEY is not set"; exit 1)
	@[ -f model-owner-verification-keys/cosign.pub ] || (echo "Error: model-owner-verification-keys/cosign.pub not found — run 'make generate-model-owner-keys' first"; exit 1)
	@echo "Registering KBS secrets for namespace $(NAMESPACE) via kbsSecretResources..."
	@set -e; \
	POLICY=$$(printf '{"default":[{"type":"reject"}],"transports":{"docker":{"%s":[{"type":"sigstoreSigned","keyPath":"kbs:///default/%s/cosign-key"}],"%s":[{"type":"sigstoreSigned","keyPath":"kbs:///default/%s/cosign-key"}]}}}' \
	    "$(APP_IMAGE_REPO)" "$(NAMESPACE)" "$(MODEL_IMAGE_REPO)" "$(NAMESPACE)"); \
	oc create secret generic "$(NAMESPACE)" \
	    -n trustee-operator-system \
	    --from-literal=model-key="$(MODEL_ENCRYPTION_KEY)" \
	    --from-file=cosign-key=model-owner-verification-keys/cosign.pub \
	    --from-literal=image-policy="$$POLICY" \
	    --dry-run=client -o yaml | oc apply -f -; \
	RESOURCES=$$(oc get kbsconfig trusteeconfig-kbs-config -n trustee-operator-system \
	    -o json | python3 -c "import json,sys; cfg=json.load(sys.stdin); lst=cfg.get('spec',{}).get('kbsSecretResources',[]) or []; ns=sys.argv[1]; lst.append(ns) if ns not in lst else None; print(json.dumps(lst))" "$(NAMESPACE)"); \
	oc patch kbsconfig trusteeconfig-kbs-config \
	    -n trustee-operator-system \
	    --type merge \
	    -p "{\"spec\":{\"kbsSecretResources\":$$RESOURCES}}"
	@echo "Restarting Trustee to pick up the updated KBS secrets..."
	@oc rollout restart deployment/trustee-deployment -n trustee-operator-system
	@oc rollout status deployment/trustee-deployment -n trustee-operator-system --timeout=2m
	@echo "KBS secrets registered for namespace $(NAMESPACE)."

.PHONY: setup-attestation
setup-attestation: set-rvps-values register-secrets-with-kbs

.PHONY: patch-cpu-policy-initdata
patch-cpu-policy-initdata:
	@python3 attestation-policies/patch-cpu-mr-config-id.py | oc apply -f -
	@echo "Restarting Trustee to pick up the updated CPU attestation policy..."
	@oc rollout restart deployment/trustee-deployment -n trustee-operator-system
	@oc rollout status deployment/trustee-deployment -n trustee-operator-system --timeout=2m
	@echo "CPU attestation policy patched to enforce initdata validation."

.PHONY: patch-cpu-policy-firmwarelevel
patch-cpu-policy-firmwarelevel:
	@python3 attestation-policies/patch-cpu-tcb-date.py | oc apply -f -
	@echo "Restarting Trustee to pick up the updated CPU attestation policy..."
	@oc rollout restart deployment/trustee-deployment -n trustee-operator-system
	@oc rollout status deployment/trustee-deployment -n trustee-operator-system --timeout=2m
	@echo "CPU attestation policy patched."

.PHONY: show-initdata
show-initdata:
	@[ -n "$$NAMESPACE" ] || (echo "Error: NAMESPACE is not set"; exit 1)
	@set -e; \
	oc get secret trusteeconfig-https-cert-secret -n trustee-operator-system >/dev/null 2>&1 || { \
	    echo "Error: trusteeconfig-https-cert-secret not found — run make setup-trustee-in-cluster first"; exit 1; \
	}; \
	KBS_SVC_URL="https://kbs-service.trustee-operator-system.svc.cluster.local:8080"; \
	oc get secret trusteeconfig-https-cert-secret -n trustee-operator-system \
	    -o jsonpath='{.data.certificate}' | base64 -d \
	    | python3 scripts/show-initdata.py "$$KBS_SVC_URL" "$(NAMESPACE)" \
	        --policy-mode $(POLICY_MODE) \
	        --app-image $(APP_IMG) \
	        --model-image $(MODEL_IMG)

.PHONY: clear-rvps
clear-rvps:
	@echo "WARNING: This will remove all RVPS reference values. Attestation will fail for all"
	@echo "         pods until 'make set-rvps-values' is run again. Press Ctrl-C to abort."
	@sleep 5
	@oc patch configmap trusteeconfig-rvps-reference-values \
	    -n trustee-operator-system \
	    --type merge \
	    -p '{"data":{"reference_value":"{}"}}'
	@oc rollout restart deployment/trustee-deployment -n trustee-operator-system
	@oc rollout status deployment/trustee-deployment -n trustee-operator-system --timeout=2m
	@echo "RVPS reference values cleared."

.PHONY: show-rvps
show-rvps:
	@[ -n "$$NAMESPACE" ] || (echo "Error: NAMESPACE is not set"; exit 1)
	@set -e; \
	oc get secret trusteeconfig-https-cert-secret -n trustee-operator-system >/dev/null 2>&1 || { \
	    echo "Error: trusteeconfig-https-cert-secret not found — run make setup-trustee-in-cluster first"; exit 1; \
	}; \
	KBS_SVC_URL="https://kbs-service.trustee-operator-system.svc.cluster.local:8080"; \
	MR_CONFIG_ID=$$(oc get secret trusteeconfig-https-cert-secret -n trustee-operator-system \
	    -o jsonpath='{.data.certificate}' | base64 -d \
	    | python3 scripts/build-initdata.py "$$KBS_SVC_URL" "$(NAMESPACE)" --mr-config-id \
	        --policy-mode $(POLICY_MODE) \
	        --app-image $(APP_IMG) \
	        --model-image $(MODEL_IMG)); \
	CURRENT=$$(oc get configmap trusteeconfig-rvps-reference-values \
	    -n trustee-operator-system \
	    -o jsonpath='{.data.reference_value}' 2>/dev/null || echo '{}'); \
	TDX_MR_SEAM="$(TDX_MR_SEAM)" TDX_TD_ATTRIBUTES="$(TDX_TD_ATTRIBUTES)" \
	TDX_MR_TD="$(TDX_MR_TD)" TDX_XFAM="$(TDX_XFAM)" \
	TDX_RTMR_0="$(TDX_RTMR_0)" TDX_RTMR_1="$(TDX_RTMR_1)" \
	TDX_RTMR_2="$(TDX_RTMR_2)" TDX_RTMR_3="$(TDX_RTMR_3)" \
	python3 scripts/show-rvps.py "$$MR_CONFIG_ID" "$$CURRENT"

.PHONY: trustee-logs
trustee-logs:
	@oc logs -n trustee-operator-system deployment/trustee-deployment --tail=100

.PHONY: debug-attestation
debug-attestation:
	@[ -n "$$NAMESPACE" ] || (echo "Error: NAMESPACE is not set"; exit 1)
	@set -e; \
	echo "=== Attestation Debug: namespace=$(NAMESPACE) ==="; \
	INITDATA=$$(oc get deployment seismic-app -n $(NAMESPACE) \
	    -o jsonpath='{.spec.template.metadata.annotations.io\.katacontainers\.config\.hypervisor\.cc_init_data}' \
	    2>/dev/null); \
	[ -n "$$INITDATA" ] || { \
	    echo "ERROR: seismic-app deployment not found in namespace $(NAMESPACE)."; \
	    echo "       Run 'make install NAMESPACE=$(NAMESPACE)' first."; \
	    exit 1; \
	}; \
	POD_NAME=$$(oc get pod -n $(NAMESPACE) -l app.kubernetes.io/name=seismic-app \
	    -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null \
	    | awk '{print $$1}'); \
	if [ -n "$$POD_NAME" ]; then \
	    echo "Using running seismic-app pod: $$POD_NAME"; \
	    echo "Fetching EAR token..."; \
	    oc exec -n $(NAMESPACE) $$POD_NAME -- \
	        curl -s --max-time 30 "http://127.0.0.1:8006/aa/token?token_type=kbs" \
	        | python3 scripts/decode-ear-token.py \
	            --mr-td "$(TDX_MR_TD)" --xfam "$(TDX_XFAM)" \
	            --rtmr-1 "$(TDX_RTMR_1)" --rtmr-2 "$(TDX_RTMR_2)"; \
	else \
	    POD_NAME="ear-debug-$$$$"; \
	    echo "No running seismic-app pod found. Starting debug pod $$POD_NAME (kata VM boot takes ~60s)..."; \
	    oc run $$POD_NAME -n $(NAMESPACE) --restart=Never \
	        --image=registry.access.redhat.com/ubi9/ubi-minimal:latest \
	        --overrides="{\"metadata\":{\"annotations\":{\"io.katacontainers.config.hypervisor.cc_init_data\":\"$$INITDATA\",\"io.katacontainers.config.hypervisor.kernel_params\":\"agent.guest_components_rest_api=all\"}},\"spec\":{\"runtimeClassName\":\"$(KATA_RUNTIME_CLASS)\",\"containers\":[{\"name\":\"$$POD_NAME\",\"image\":\"registry.access.redhat.com/ubi9/ubi-minimal:latest\",\"resources\":{\"limits\":{\"nvidia.com/pgpu\":\"1\"},\"requests\":{\"nvidia.com/pgpu\":\"1\"}}}]}}" \
	        -- sleep 300 \
	        || { oc delete pod $$POD_NAME -n $(NAMESPACE) --ignore-not-found; exit 1; }; \
	    oc wait pod/$$POD_NAME -n $(NAMESPACE) --for=condition=Ready --timeout=5m \
	        || { echo "ERROR: pod did not become ready"; oc delete pod $$POD_NAME -n $(NAMESPACE) --ignore-not-found; exit 1; }; \
	    echo "Waiting for CDH to initialize (up to 3m)..."; \
	    DEADLINE=$$(( $$(date +%s) + 180 )); \
	    until LAST_RESPONSE=$$(oc exec -n $(NAMESPACE) $$POD_NAME -- \
	            curl -s "http://127.0.0.1:8006/aa/token?token_type=kbs") \
	            && echo "$$LAST_RESPONSE" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; do \
	        if [ $$(date +%s) -ge $$DEADLINE ]; then \
	            echo "ERROR: CDH did not become ready within 3 minutes."; \
	            echo "Last CDH response: $$LAST_RESPONSE"; \
	            oc delete pod $$POD_NAME -n $(NAMESPACE) --ignore-not-found; \
	            exit 1; \
	        fi; \
	        printf "."; sleep 5; \
	    done; \
	    echo ""; \
	    echo "Fetching EAR token..."; \
	    oc exec -n $(NAMESPACE) $$POD_NAME -- \
	        curl -s --max-time 30 "http://127.0.0.1:8006/aa/token?token_type=kbs" \
	        | python3 scripts/decode-ear-token.py \
	            --mr-td "$(TDX_MR_TD)" --xfam "$(TDX_XFAM)" \
	            --rtmr-1 "$(TDX_RTMR_1)" --rtmr-2 "$(TDX_RTMR_2)"; \
	    oc delete pod $$POD_NAME -n $(NAMESPACE) --ignore-not-found; \
	    echo "Debug pod deleted."; \
	fi

.PHONY: validate-trustee-certificate
validate-trustee-certificate:
	@echo "Checking Trustee certificate consistency..."
	@set -e; \
	KBS_ROUTE=$$(oc get route kbs-route -n trustee-operator-system \
	    -o jsonpath='{.spec.host}' 2>/dev/null); \
	[ -n "$$KBS_ROUTE" ] || { \
	    echo "ERROR: kbs-route not found — run make setup-trustee-in-cluster first"; exit 1; \
	}; \
	SECRET_CERT=$$(oc get secret trusteeconfig-https-cert-secret -n trustee-operator-system \
	    -o jsonpath='{.data.certificate}' 2>/dev/null | base64 -d); \
	[ -n "$$SECRET_CERT" ] || { \
	    echo "ERROR: trusteeconfig-https-cert-secret not found or empty"; exit 1; \
	}; \
	SECRET_FP=$$(echo "$$SECRET_CERT" \
	    | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2); \
	SERVED_FP=$$(echo \
	    | openssl s_client -connect "$$KBS_ROUTE:443" -servername "$$KBS_ROUTE" 2>/dev/null \
	    | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2); \
	echo "  Secret cert (trusteeconfig-https-cert-secret): $$SECRET_FP"; \
	echo "  Served cert ($$KBS_ROUTE:443):                 $$SERVED_FP"; \
	if [ "$$SECRET_FP" = "$$SERVED_FP" ]; then \
	    echo "OK: certificates match — initdata will use the correct cert"; \
	else \
	    echo "MISMATCH: the secret and served certs differ."; \
	    echo "  Cause: cert-manager may have rotated the certificate after 'make install' last ran."; \
	    echo "  Fix:   run 'make install' to rebuild initdata with the current cert, then redeploy."; \
	    exit 1; \
	fi
