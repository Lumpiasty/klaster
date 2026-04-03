{ pkgs, lib, config, inputs, ... }:

let
  # Python with hvac package
  python = pkgs.python313.withPackages (python-pkgs: with python-pkgs; [
    hvac
    librouteros
  ]);

  garm-cli = pkgs.callPackage ./nix/garm-cli.nix { };
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
    fluxcd
    restic
    openbao
    pv-migrate
    mermaid-cli
    (
      # Wrapping opencode to set the OPENCODE_ENABLE_EXA environment variable
      runCommand "opencode" {
        buildInputs = [ makeWrapper ];
      } ''
        mkdir -p $out/bin
        makeWrapper ${pkgs.opencode}/bin/opencode $out/bin/opencode \
          --set OPENCODE_ENABLE_EXA "1"
        ''
    )
    garm-cli
    tea
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

  languages.ansible.enable = true;
  # TODO: automatically manage collections from ansible/requirements.yml
  # For now, we need to manually install them with `ansible-galaxy collection install -r ansible/requirements.yml`
  # This is not implemented in devenv
}
