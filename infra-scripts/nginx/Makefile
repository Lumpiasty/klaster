install:
	helm repo add nginx https://helm.nginx.com/stable
	helm repo update nginx
	helm upgrade --install -n nginx-ingress-controller --create-namespace nginx-ingress nginx/nginx-ingress --version 2.0.1 -f values.yaml
