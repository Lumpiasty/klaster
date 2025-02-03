install:
	helm repo add openebs https://openebs.github.io/openebs
	helm repo update openebs
	helm upgrade -i -n openebs --create-namespace openebs openebs/openebs -f values.yml