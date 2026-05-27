# Setup
Instalation of Openshift GitOPS operator

```
$ oc apply -k setup/operator-gitops
```

# Init
Initialization of Cluster Factory ArgoCD Application (cluster-factory-root), which points to ./boostrap/appsets/ where each cluster should have its dedicated ApplicationSet pointing in turn to appropriate overlay directory.

```
oc apply -d init/
```





