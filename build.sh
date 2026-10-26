#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"

echo "==> [build] Starting OpenShift Virtualization setup"
echo "    RESOURCEGROUP=${RESOURCEGROUP}"
echo "    CLUSTER=${CLUSTER}"

# Check for required tools
echo "==> [build] Checking required tools (oc, jq, yq)..."
required_tools=(oc jq yq)
missing=()

for tool in "${required_tools[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing+=("$tool")
  fi
done

if (( ${#missing[@]} > 0 )); then
  echo "ERROR: Missing required tools: ${missing[*]}" >&2
  echo "Install them and re-run this script." >&2
  exit 1
fi
echo "    All required tools found."

# Create scratch directory
SCRATCH_DIR="$(pwd)/scratch"
echo "==> [build] Ensuring scratch directory exists: ${SCRATCH_DIR}"
if [[ ! -d "$SCRATCH_DIR" ]]; then
  mkdir -p "$SCRATCH_DIR"
  echo "    Created ${SCRATCH_DIR}"
else
  echo "    Already exists."
fi

# get cluster API logged in
echo "==> [build] Fetching ARO API server URL..."
apiServer=$(az aro show --resource-group "$RESOURCEGROUP" --name "$CLUSTER" --query apiserverProfile.url --output tsv)
echo "    API server: ${apiServer}"

echo "==> [build] Fetching kubeadmin credentials..."
kubevar=$(az aro list-credentials --name "$CLUSTER" --resource-group "$RESOURCEGROUP" --query kubeadminPassword --output tsv)

echo "==> [build] Logging in to cluster with oc..."
oc login "$apiServer" --username kubeadmin --password "$kubevar"
kubevar=""
echo "    Logged in as: $(oc whoami)"

# its easier to install netapp before virt
echo "==> [build] Running netapp.sh (Azure NetApp Files + Trident)..."
"${SCRIPT_DIR}/netapp.sh"
echo "==> [build] netapp.sh completed successfully."

# add machine set for virt
export SCRATCH_DIR
export ARO_BOOST_INSTANCE="Standard_D8s_v5"
export VIRT_MACHINESET_NAME="virt-machine-set"

echo "==> [build] Creating virt machinesets (instance type: ${ARO_BOOST_INSTANCE})..."
for MACHINESET_NAME in $(oc get machineset -n openshift-machine-api -o json | jq -r '.items[].metadata.name'); do
  # Only clone worker machinesets; skip existing virt clones
  if [[ "${MACHINESET_NAME}" != *"-worker"* ]]; then
    echo "    Skipping ${MACHINESET_NAME} (not a worker machineset)"
    continue
  fi

  VIRT_NAME=$(echo "${MACHINESET_NAME}" | sed "s/.*-worker/${VIRT_MACHINESET_NAME}/")

  if oc get machineset "${VIRT_NAME}" -n openshift-machine-api >/dev/null 2>&1; then
    echo "    Skipping ${VIRT_NAME} (already exists)"
    continue
  fi

  echo "    Cloning machineset ${MACHINESET_NAME} -> ${VIRT_NAME}"
  oc get machineset "${MACHINESET_NAME}" -n openshift-machine-api -o yaml | \
  yq e ".metadata.name = \"${VIRT_NAME}\" | \
          .spec.selector.matchLabels.\"machine.openshift.io/cluster-api-machineset\" = \"${VIRT_NAME}\" | \
          .spec.template.metadata.labels.\"machine.openshift.io/cluster-api-machineset\" = \"${VIRT_NAME}\" | \
          .spec.template.spec.providerSpec.value.vmSize = \"${ARO_BOOST_INSTANCE}\"" - > "${SCRATCH_DIR}/${VIRT_NAME}.yaml"
  oc apply -f "${SCRATCH_DIR}/${VIRT_NAME}.yaml"
  echo "    Applied ${SCRATCH_DIR}/${VIRT_NAME}.yaml"
done
echo "    Virt machinesets applied."

# Install virt operators
echo "==> [build] Installing OpenShift Virtualization operator (namespace, OperatorGroup, Subscription)..."
cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cnv
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
    - openshift-cnv
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hco-operatorhub
  namespace: openshift-cnv
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: kubevirt-hyperconverged
  channel: "stable"
EOF
echo "    Subscription applied."

# echo "==> [build] Waiting for OpenShift Virtualization operator to install (timeout: 600s)..."
# TIMEOUT=600
# ELAPSED=0
# while true; do
#   PHASE=$(oc get csv -n openshift-cnv -l operators.coreos.com/hco-operatorhub.openshift-cnv -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
#   if [[ "$PHASE" == "Succeeded" ]]; then
#     echo "    OpenShift Virtualization operator installed (phase: Succeeded)."
#     break
#   fi
#   if (( ELAPSED >= TIMEOUT )); then
#     echo "ERROR: Timeout waiting for OpenShift Virtualization operator (last phase: ${PHASE:-none})" >&2
#     exit 1
#   fi
#   echo "    Operator phase: ${PHASE:-pending} (${ELAPSED}s/${TIMEOUT}s)..."
#   sleep 15
#   (( ELAPSED += 15 ))
# done

echo "==> [build] Applying HyperConverged CR..."
cat << EOF | oc apply -f -
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  annotations:
    deployOVS: 'false'
  namespace: openshift-cnv
spec:
  enableCommonBootImageImport: true
  virtualMachineOptions:
    disableFreePageReporting: false
    disableSerialConsoleLog: false
  higherWorkloadDensity:
    memoryOvercommitPercentage: 100
  liveMigrationConfig:
    allowAutoConverge: false
    allowPostCopy: false
    completionTimeoutPerGiB: 150
    parallelMigrationsPerCluster: 5
    parallelOutboundMigrationsPerNode: 2
    progressTimeout: 150
  certConfig:
    ca:
      duration: 48h0m0s
      renewBefore: 24h0m0s
    server:
      duration: 24h0m0s
      renewBefore: 12h0m0s
  enableApplicationAwareQuota: false
  applicationAwareConfig:
    allowApplicationAwareClusterResourceQuota: false
    vmiCalcConfigName: DedicatedVirtualResources
  featureGates:
    downwardMetrics: false
    disableMDevConfiguration: false
    deployKubeSecondaryDNS: false
    alignCPUs: false
    persistentReservation: false
  workloadUpdateStrategy:
    batchEvictionInterval: 1m0s
    batchEvictionSize: 10
    workloadUpdateMethods:
      - LiveMigrate
  deployVmConsoleProxy: false
  uninstallStrategy: BlockUninstallIfWorkloadsExist
  resourceRequirements:
    vmiCPUAllocationRatio: 10
EOF
echo "    HyperConverged CR applied."

echo "==> [build] Done. OpenShift Virtualization setup complete."
