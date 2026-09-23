{
  description = "xdplab — BGP-underlay Kubernetes homelab for XDP experimentation";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forEachSystem = nixpkgs.lib.genAttrs systems;
    in {
      devShells = forEachSystem (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = pkgs.mkShell {
            nativeBuildInputs = with pkgs; [
              # Task runner
              go-task

              # Go (clab/coil's Taskfile builds gencert from Coil's source tree)
              go

              # Kubernetes (clab/ -- kind + containerlab, see clab/DESIGN.md)
              kubernetes-helm
              kind
              kustomize
              kubectl
              cilium-cli
              hubble

              # Utilities
              yq-go
              jq
            ];
          };
        }
      );
    };
}
