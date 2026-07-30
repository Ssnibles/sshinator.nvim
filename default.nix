{ lib, buildVimPlugin }:

buildVimPlugin {
  pname = "sshinator-nvim";
  version = "0.1.0";
  src = ./.;
}
