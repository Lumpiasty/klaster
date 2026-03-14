{ lib, buildGoModule, fetchFromGitHub, installShellFiles }:

buildGoModule rec {
  pname = "garm-cli";
  version = "r1380";
  garmCommit = "818a9dddccba5f2843f185e6a846770988f31fc5";

  src = fetchFromGitHub {
    owner = "cloudbase";
    repo = "garm";
    rev = garmCommit;
    hash = "sha256-CTqqabNYUMSrmnQVCWml1/vkDw+OP1uJo1KFhBSZpYY=";
  };

  subPackages = [ "cmd/garm-cli" ];

  nativeBuildInputs = [ installShellFiles ];

  vendorHash = null;

  ldflags = [
    "-s"
    "-w"
    "-X main.version=${version}"
  ];

  postInstall = ''
    # We need to set a temporary HOME for the completion scripts as workaround
    # because garm-cli tries to write config to the home directory
    # when generating the completion scripts
    export HOME="$(mktemp -d)"

    installShellCompletion --cmd garm-cli \
      --bash <($out/bin/garm-cli completion bash) \
      --fish <($out/bin/garm-cli completion fish) \
      --zsh <($out/bin/garm-cli completion zsh)
  '';

  meta = {
    description = "CLI for GitHub Actions Runner Manager";
    homepage = "https://github.com/cloudbase/garm";
    license = lib.licenses.asl20;
    mainProgram = "garm-cli";
  };
}
