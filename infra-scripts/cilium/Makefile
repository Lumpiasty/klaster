install:
	helm repo add cilium https://helm.cilium.io/
	helm repo update cilium
	helm upgrade --install -n kube-system cilium cilium/cilium --version 1.16.6 -f values.yml
	kubectl apply -f loadbalancer-ippool.yml -f bgp-cluster-config.yml
