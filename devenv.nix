{ pkgs, lib, config, inputs, ... }:

let
  # Python with hvac package
  python = pkgs.python313.withPackages (python-pkgs: with python-pkgs; [
    hvac
  ]);
in
{
  # Overlays - apply krew2nix to get kubectl with krew support
  overlays = [
    inputs.krew2nix.overlay
  ];

  # Environment variables
  env = {
    GREET = "devenv";
    TALOSCONFIG = "${config.devenv.root}/talos/generated/talosconfig";
    EDITOR = "vim";
    RESTIC_REPOSITORY = "s3:https://s3.eu-central-003.backblazeb2.com/lumpiasty-backups";
    VAULT_ADDR = "https://openbao.lumpiasty.xyz:8200";
    PATH = "${config.devenv.root}/utils:${pkgs.coreutils}/bin";
    PYTHON_BIN = "${python}/bin/python";
    KUBECONFIG = "${config.devenv.root}/talos/generated/kubeconfig";
  };

  # Packages
  packages = with pkgs; [
    python
    vim gnumake
    talosctl cilium-cli
    kubectx k9s kubernetes-helm
    (kubectl.withKrewPlugins (plugins: with plugins; [
      mayastor
      openebs
      browse-pvc
    ]))
    ansible
    fluxcd
    restic
    openbao
    pv-migrate
  ];

  # Scripts
  scripts.hello.exec = ''
    echo hello from $GREET
  '';

  # Shell hooks
  enterShell = ''
    source ${pkgs.bash-completion}/share/bash-completion/bash_completion
    echo "Environment ready!"
  '';

  # Tests
  enterTest = ''
    echo "Running tests"
    git --version | grep --color=auto "${pkgs.git.version}"
  '';
}
