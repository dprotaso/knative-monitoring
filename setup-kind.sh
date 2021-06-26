#!/bin/bash

set -e

echo Setting up Kubernetes
kind delete cluster
kind create cluster

echo Setting up MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/master/manifests/namespace.yaml
kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/master/manifests/metallb.yaml

docker network inspect -f '{{.IPAM.Config}}' kind
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - 172.18.255.200-172.18.255.250
EOF

echo Setting up Prometheus K8s Stack
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install promstack -f values.yaml prometheus-community/kube-prometheus-stack

echo Setting up Serving
kubectl apply -f https://github.com/knative/serving/releases/download/v0.23.1/serving-crds.yaml
kubectl apply -f https://github.com/knative/serving/releases/download/v0.23.1/serving-core.yaml

echo Setting up Kourier
kubectl apply -f https://github.com/knative-sandbox/net-kourier/releases/download/v0.23.0/kourier.yaml
kubectl patch configmap/config-network \
  --namespace knative-serving \
  --type merge \
  --patch '{"data":{"ingress.class":"kourier.ingress.networking.knative.dev"}}'

echo Setting up Prometheus Monitors
kubectl apply -f prometheus/monitors.yaml

# Dunno why it takes so long for the webhook service to be ready
# in KinD
sleep 60

echo Creating Fixture
cat <<EOF | kubectl apply -f -
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  annotations: {}
  name: helloworld-go
spec:
  template:
    spec:
      containers:
      - image: gcr.io/knative-samples/helloworld-go
EOF

kubectl wait --for=condition=Ready=true ksvc/helloworld-go --timeout=60s

echo Hitting endpoint for the next 10 seconds
docker run --rm -i --network=kind peterevans/vegeta sh -c \
"echo 'GET http://172.18.255.200' | vegeta attack -header 'Host: helloworld-go.default.example.com' -rate=10 -duration=10s | vegeta report"
