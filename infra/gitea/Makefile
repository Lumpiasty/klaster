install:
	helm repo add gitea-charts https://dl.gitea.com/charts/
	helm repo update gitea-charts
	helm upgrade --install -n gitea --create-namespace gitea gitea-charts/gitea --version 10.6.0 -f values.yml
