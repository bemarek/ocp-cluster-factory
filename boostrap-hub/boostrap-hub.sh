#!/bin/bash

# --- CONFIGURATION VARIABLES ---
REPO_URL="https://github.com/bemarek/ocp-cluster-factory.git"
TARGET_BRANCH="main"

echo "=== Step 1: Installing GitOps Operator on Hub ==="
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-gitops-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-gitops-operator
  namespace: openshift-gitops-operator
spec:
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-gitops-operator
spec:
  channel: latest
  installPlanApproval: Automatic
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "=== Waiting for the default ArgoCD instance to be initialized ==="
# After installation, GitOps Operator creates the openshift-gitops namespace and built-in ServiceAccount
while ! oc get sa openshift-gitops-argocd-application-controller -n openshift-gitops >/dev/null 2>&1; do
  echo "Waiting for the ArgoCD controller ServiceAccount to be created..."
  sleep 10
done

echo "=== Step 2: Elevating ArgoCD privileges (granting cluster-admin role) ==="
# Grant permissions allowing ArgoCD to manage cluster-scoped objects on the Hub
oc adm policy add-cluster-role-to-user --rolebinding-name="openshift-gitops-cluster-admin" cluster-admin -z openshift-gitops-argocd-application-controller -n openshift-gitops

echo "=== Step 3: Configuring Hub as the Principal for future Agents ==="
# Patch the default ArgoCD instance to enable the Principal component
# We do not define sourceNamespaces yet, as we don't have any remote agents registered
oc patch argocd openshift-gitops -n openshift-gitops --type=merge -p='{
  "spec": {
    "argoCDAgent": {
      "principal": {
        "enabled": true
      }
    }
  }
}'

echo "=== Step 4: Registering the local Hub cluster explicitly ==="
# Create a Secret to expose the local in-cluster environment to the Cluster generator
oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: in-cluster-secret
  namespace: openshift-gitops
  labels:
    # Mandatory label for ArgoCD to recognize this secret as a cluster definition
    argocd.argoproj.io/secret-type: cluster
    # Custom label used by our local ApplicationSet selector
    environment: hub
type: Opaque
stringData:
  name: in-cluster
  server: https://kubernetes.default.svc
EOF

echo "=== Step 5: Deploying the ApplicationSet for the Hub configuration ==="
# Deploy the ApplicationSet that targets ONLY the local Hub cluster
oc apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: hub-config-appset
  namespace: openshift-gitops
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
  - clusters:
      selector:
        matchLabels:
          # Target only the local cluster labeled with 'environment: hub'
          environment: hub
  template:
    metadata:
      name: 'cfg-{{.name}}'
      # The Application for the Hub lives in the default control plane namespace
      namespace: openshift-gitops
    spec:
      project: default
      source:
        repoURL: '${REPO_URL}'
        targetRevision: '${TARGET_BRANCH}'
        path: 'overlays/{{.name}}'
      destination:
        server: '{{.server}}'
        namespace: openshift-gitops
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
        - CreateNamespace=true
EOF

echo "=== Hub Bootstrap process completed successfully! ==="