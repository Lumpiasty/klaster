{
    inputs = {
        nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

        # Only to ease updating flake.lock, flake-compat is used by shell.nix
        flake-compat.url = https://flakehub.com/f/edolstra/flake-compat/1.1.0.tar.gz;

        # Allows us to install krew plugins
        krew2nix.url = "github:a1994sc/krew2nix";
        krew2nix.inputs.nixpkgs.follows = "nixpkgs";
    };

    outputs = { self, nixpkgs, krew2nix, ... }: let 
        system = "x86_64-linux";
    in {
        devShells."${system}".default =
        let
            pkgs = import nixpkgs {
                overlays = [ krew2nix.overlay ];
                inherit system;
            };
            python = (pkgs.python313.withPackages (python-pkgs: with python-pkgs; [
                hvac
            ]));
        in
            pkgs.mkShell {
                packages = with pkgs; [
                    python
                    vim gnumake
                    talosctl cilium-cli
                    kubectx k9s kubernetes-helm
                    (kubectl.withKrewPlugins (plugins: with plugins; [
                        mayastor
                        openebs
                    ]))
                    ansible
                    fluxcd
                    restic
                    openbao
                ];
                
                shellHook = ''
                # Get completions working
                source ${pkgs.bash-completion}/share/bash-completion/bash_completion

                export TALOSCONFIG=$(pwd)/talos/generated/talosconfig
                export EDITOR=vim

                export RESTIC_REPOSITORY=s3:https://s3.eu-central-003.backblazeb2.com/lumpiasty-backups
                # export AWS_ACCESS_KEY_ID=?
                # export AWS_SECRET_ACCESS_KEY=?
                # export RESTIC_PASSWORD=?
                export VAULT_ADDR=https://openbao.lumpiasty.xyz:8200

                # Add scripts from utils subdir
                export PATH="$PATH:$(pwd)/utils"

                export PYTHON_BIN=${python}/bin/python
                '';
            };
    };
}