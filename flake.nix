{
    inputs = {
        nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

        # Only to ease updating flake.lock, flake-compat is used by shell.nix
        flake-compat.url = https://flakehub.com/f/edolstra/flake-compat/1.1.0.tar.gz;
    };

    outputs = { self, nixpkgs, ... }: let 
        system = "x86_64-linux";
    in {
        devShells."${system}".default =
        let
            pkgs = import nixpkgs {
                inherit system;
            };
        in
            pkgs.mkShell {
                packages = with pkgs; [
                    vim gnumake
                    talosctl cilium-cli
                    kubectl kubectx k9s kubernetes-helm
                    ansible
                ];
                
                shellHook = ''
                # Get completions working
                source ${pkgs.bash-completion}/share/bash-completion/bash_completion

                export TALOSCONFIG=$(pwd)/talos/generated/talosconfig
                export EDITOR=vim
                '';
            };
    };
}