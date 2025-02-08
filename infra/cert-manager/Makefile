install:
	helm repo add cert-manager https://charts.jetstack.io
	helm repo update cert-manager
	helm upgrade --install -n cert-manager --create-namespace cert-manager cert-manager/cert-manager --version 1.17.0 -f values.yml

	kubectl apply -f cluster-issuer.yml
