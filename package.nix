{
  pkgs,
  source,
  system,
  version ? "1.1.0",
}:

with pkgs;
with lib;

let
  # System-string check (not stdenv.hostPlatform): stdenv may not exist
  # for systems this nixpkgs has dropped (e.g. x86_64-darwin in 26.11),
  # and that throws at eval time.
  isLinux = hasPrefix "linux" system;
  # Node 20+ is the project requirement (nodejs_20 no longer exists in
  # nixpkgs); pnpm 11 reads the v9.0 lockfile and the repo's
  # client/pnpm-workspace.yaml already uses pnpm's `allowBuilds` map.
  nodejs = nodejs_22;

  # The `prepare` script runs `husky`, which fails outside a git checkout,
  # so strip it from the copy of client/ used for building.
  clientSrc = runCommand "nightingale-client-src" {
    nativeBuildInputs = [ jq.bin ];
  } ''
    cp -r ${source}/client $out
    chmod -R u+w $out
    jq 'del(.scripts.prepare)' $out/package.json > $out/package.json.tmp
    mv $out/package.json.tmp $out/package.json
  '';

  # React/Vite frontend bundle. Built as its own derivation so Rust-only
  # changes don't re-run the JS toolchain. The pnpmConfigHook installs
  # node_modules from pnpmDeps (offline) before buildPhase.
  frontend = stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "nightingale-frontend";
    inherit version;
    src = clientSrc;
    nativeBuildInputs = [
      pnpmConfigHook
      pnpm
      nodejs
    ];
    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      inherit pnpm;
      fetcherVersion = 4;
      hash = "sha256-z3Ew7f1Wi4ZkyxotcgX+pffcjyOIYwCKkHKPxs2X7Lc=";
    };
    buildPhase = ''
      runHook preBuild
      pnpm build
      runHook postBuild
    '';
    installPhase = ''
      mkdir -p $out
      cp -r dist $out
    '';
  });

  # buildRustCrate is deliberately not used here: it invokes rustc directly
  # and requires the full (~500 crate) dependency graph to be spelled out at
  # eval time. buildRustPackage drives real `cargo`, vendors every crate from
  # the workspace Cargo.lock, and lets us pick the app out of the workspace.
  nightingale = rustPlatform.buildRustPackage {
    pname = "nightingale";
    inherit version;
    src = source;

    # No cargo tests in the Nix build.
    doCheck = false;

    # Vendor the workspace crates from the root lockfile (src already
    # contains the lock at the same location).
    cargoLock = { lockFile = ./Cargo.lock; };

    nativeBuildInputs =
      [ cargo rustc rustPlatform.cargoSetupHook ]
      ++ lib.optionals isLinux [ pkg-config ];
    buildInputs = [
      frontend
    ]
    # Tauri v2 Linux system libraries (mirrors the CI apt-get list).
    # macOS uses the system WebKit/AvFoundation frameworks instead.
    ++ lib.optionals isLinux [
      glib
      gobject-introspection
      gtk3
      ((webkit2gtk_4_1 or webkitgtk_4_1) or webkitgtk)
      librsvg2
      libxdo
      alsa-lib
      libayatana-appindicator3
      openssl
    ];

    # Only build the desktop app; app-core/src-server/xtask are workspace
    # members we don't ship.
    cargoBuildFlags = [ "-p" "Nightingale" ];

    preBuild = ''
      # tauri-build (build.rs) verifies frontendDist, and rust-embed embeds
      # client/dist at compile time — the vite bundle must be in place first.
      mkdir -p client
      cp -r ${frontend} client/dist
    '';

    installPhase = ''
      # cargoBuildHook may build with an explicit --target, so the binary
      # ends up in target/<triple>/release/ (or plain target/release/).
      install -Dm755 $(find target -maxdepth 3 -name Nightingale -type f | head -1) $out/bin/nightingale
    '';

    meta = {
      description = "Nightingale — Karaoke from your music library";
      homepage = "https://github.com/rzru/nightingale";
      license = licenses.gpl3Only;
      platforms = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      mainProgram = "nightingale";
    };
  };
in
{
  inherit nightingale;

  # Pre-baked runtime vendor tree + activated wrapper (Linux only;
  # vendor.nix returns {} on other systems).
  vendor = (import ./vendor.nix) {
    inherit pkgs system version;
    app = nightingale;
  };
}
