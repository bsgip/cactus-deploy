#!/bin/bash

echo "Pre-loading docker images across all nodes."
microk8s kubectl -n teststack-templates apply -f cactus-teststack-imagepuller.yaml

if ! microk8s kubectl -n teststack-templates rollout status daemonset/cactus-teststack-imagepuller --timeout=5m; then
  echo "Rollout of docker images across nodes failed (or timed out)"
  exit 1
fi


echo "Applying latest changes"
set -e
microk8s kubectl -n test-orchestration delete -f cactus-orchestrator.yaml && microk8s kubectl -n test-orchestration apply -f cactus-orchestrator.yaml
microk8s kubectl -n test-orchestration delete -f cactus-ui.yaml && microk8s kubectl -n test-orchestration apply -f cactus-ui.yaml
microk8s kubectl -n test-orchestration apply -f cactus-client-notifications.yaml
microk8s kubectl -n teststack-templates apply -f cactus-teststack-v12.yaml
microk8s kubectl -n teststack-templates apply -f cactus-teststack-v13.yaml
microk8s kubectl -n teststack-templates apply -f cactus-teststack-v13-beta-storage.yaml


echo "Update complete"
exit 0