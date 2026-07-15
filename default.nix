{ pkgs ? import <nixpkgs> {} }:

let
  sshinator-bin = pkgs.buildGoModule {
    pname = "sshinator";
    version = "0.1.0";
    src = ./.;

    vendorHash = null;
    proxyVendor = true;

    subPackages = [ "cmd/sshinator" ];

    meta = with pkgs.lib; {
      description = "SSH connection manager and mounter for Neovim";
      license = licenses.mit;
      mainProgram = "sshinator";
      platforms = platforms.linux;
    };
  };
in
pkgs.vimUtils.buildVimPlugin {
  pname = "sshinator.nvim";
  version = "0.1.0";
  src = ./.;

  dependencies = [ pkgs.sshfs ];

  postInstall = ''
    mkdir -p $target/bin
    ln -s ${sshinator-bin}/bin/sshinator $target/bin/sshinator
  '';

  meta = with pkgs.lib; {
    description = "Neovim Remote SSH plugin with Go backend";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
