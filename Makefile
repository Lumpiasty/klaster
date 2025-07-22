install-router:
	ansible-playbook ansible/playbook.yml -i ansible/hosts

gen-talos-config:
	mkdir -p talos/generated
	talosctl gen config \
		--with-secrets secrets.yaml \
		--config-patch @talos/patches/controlplane.patch \
		--config-patch @talos/patches/openebs.patch \
		--config-patch @talos/patches/openbao.patch \
		--config-patch @talos/patches/ollama.patch \
		--config-patch @talos/patches/llama.patch \
		--config-patch @talos/patches/frigate.patch \
		--config-patch @talos/patches/anapistula-delrosalae.patch \
		--output-types controlplane -o talos/generated/anapistula-delrosalae.yaml \
		homelab https://kube-api.homelab.lumpiasty.xyz:6443
	talosctl gen config --with-secrets secrets.yaml --config-patch @talos/patches/controlplane.patch --output-types worker -o talos/generated/worker.yaml homelab https://kube-api.homelab.lumpiasty.xyz:6443
	talosctl gen config --with-secrets secrets.yaml --output-types talosconfig -o talos/generated/talosconfig homelab https://kube-api.homelab.lumpiasty.xyz:6443
	talosctl config endpoint kube-api.homelab.lumpiasty.xyz

apply-talos-config:
	talosctl -n anapistula-delrosalae apply-config -f talos/generated/anapistula-delrosalae.yaml
