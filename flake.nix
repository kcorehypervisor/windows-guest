{
  description = "Windows Server guest image recipe for Cloud Hypervisor and kcore";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          qemu
          OVMF
          OVMF-cloud-hypervisor
          cloud-hypervisor
          xorriso
          p7zip
          wimlib
          python3
          curl
          gettext
          shellcheck
          libxml2
        ];
        shellHook = ''
          export OVMF_CODE=${pkgs.OVMF.fd}/FV/OVMF.fd
          export CLOUDHV_FW=${pkgs.OVMF-cloud-hypervisor.firmware}
        '';
      };
    };
}
