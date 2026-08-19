{
  description = "Nightingale — Karaoke from your music library";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # x86_64-darwin is deliberately absent: nixpkgs 26.11 dropped it, and
      # touching stdenv for a dropped system throws at eval time. (Adding it
      # back later is a one-line change once the pinned nixpkgs supports it.)
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
    in
    {
      packages = nixpkgs.lib.genAttrs systems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          built = (import ./package.nix) {
            inherit pkgs system;
            source = self.sourceInfo.outPath;
            version = "1.1.0";
          };
          nightingale = built.nightingale;
          vendor = built.vendor;
          bundled = {
            # App + pre-baked vendor tree activation (wrapper).
            nightingaleBundled = vendor.nightingaleBundled;
            # The bare pre-baked vendor tree (python/venv/uv).
            nightingaleVendor = vendor.vendorBake;
          };
        in
        {
          inherit nightingale;
          default = nightingale;
          bundled = vendor.nightingaleBundled;
        }
      );
    };

}
