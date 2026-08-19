{ pkgs, app, system, version ? "1.1.0" }:

# Pre-baked copy of the app's runtime "vendor" tree (the thing the app
# normally downloads on first launch, see app-core/src/vendor.rs).
#
# This mirrors the CPU branch of the bootstrap exactly, so a vendor dir
# populated from this derivation makes every download/install step a no-op
# at first launch:
#
#   $out/python   nixpkgs CPython 3.10           (uv is told never to download one)
#   $out/venv     venv with the full ML stack    (`uv venv` + `uv pip install ...`)
#   $out/uv       the uv binary itself
#
# ffmpeg is NOT baked here: the wrapper symlinks nixpkgs' ffmpeg into the
# vendor dir (closure stays in the store; avoids pinning hashes of a
# constantly-updating "latest" tarball).
#
# Deliberately does NOT write `vendor/.ready` or `vendor/analyzer/`: those
# can only come from the binary (embedded analyzer scripts) and the app's
# own setup flow. First launch therefore still runs the setup UI, but every
# network step no-ops instantly.
#
# Deviation from upstream behavior: torch/torchaudio are installed from the
# PyTorch CPU index instead of PyPI's default (CUDA-bundled) wheels. The
# app never passes the CPU index on Linux, so upstream ends up with the
# multi-GB CUDA build even on CPU machines; the CPU wheels run identically
# for CPU inference and keep this derivation ~3 GB smaller.
#
# Linux only (the app's vendor bootstrap + uv-managed CPython target Linux
# here).

with pkgs;
with lib;

let
  # System-string check (not stdenv.hostPlatform): stdenv may not exist
  # for systems this nixpkgs has dropped, and that throws at eval time.
  isLinux = hasPrefix "linux" system;

  # Same package set as step_install_packages (non-legacy, non-CUDA),
  # minus torch/torchaudio (installed separately from the CPU index below).
  packages = [
    "demucs>=4.0.0"
    "whisperx>=3.3.0"
    "soundfile"
    "huggingface_hub>=0.27.0"
    "audio-separator>=0.25"
    "onnx-asr>=0.5.0"
    "onnxruntime>=1.17"
    "fugashi[unidic-lite]>=1.3"
    "pykakasi>=2.3"
    "jieba>=0.42"
    "pypinyin>=0.50"
    "ToJyutping>=3.0"
    "hangul-romanize>=0.1.0"
    "nagisa>=0.2.11"
    "soynlp>=0.0.493"
  ];

  # PyPI wheels (torch, numpy, ...) dlopen system libraries at runtime;
  # NixOS has no global /usr/lib, so the wrapper gives the app process a
  # makeLibraryPath (the wiki-recommended pattern; no nix-ld needed). If an
  # import ever fails with "ImportError: libX.so: cannot open", add that
  # library here.
  wheelLibs = [
    pkgs.glibc
    pkgs.glibc.locales
    pkgs.stdenv.cc.lib
    pkgs.zlib
    pkgs.libffi
    pkgs.openssl_3
    pkgs.gmp
    pkgs.bzip2
    pkgs.xz
  ];

  # Pinned exactly like the app (Qwen3-ASR integration from transformers
  # main, installed last so it wins over anything else that pins
  # transformers).
  transformersPin =
    "transformers @ git+https://github.com/huggingface/transformers"
    + "@967203924487e8e9f64a2d825fc4e1bdbec3f518";

  vendorBake =
    stdenvNoCC.mkDerivation {
      pname = "nightingale-vendor";
      inherit version;
      nativeBuildInputs = [ uv git python310 ];
      dontBuild = true;
      dontUnpack = true;

      installPhase = ''
        runHook preInstall

        # $HOME is read-only in the sandbox; uv needs a writable cache dir.
        export UV_CACHE_DIR="$TMPDIR/uv-cache"
        # The sandbox strips SSL_CERT_FILE; allow uv's hosts without certs.
        export UV_INSECURE_HOSTS="pypi.org,files.pythonhosted.org,download.pytorch.org,github.com,codeload.github.com"
        # git (transformers fetch) has the same cert problem.
        export GIT_SSL_NO_VERIFY=1
        # Never let uv download a managed CPython: the sandbox has no
        # /bin/sh for uv's libc detection, and nixpkgs' python310 is the
        # Nix-native interpreter (per nixpkgs' own uv package docs).
        export UV_PYTHON_DOWNLOADS=never

        # Step: vendor python = nixpkgs CPython 3.10 (a real directory so
        # the app's walk for a python3.10 file succeeds; the wrapper
        # copies this tree into the user's vendor dir).
        cp -r ${python310} $out/python

        # Step: venv on top of it.
        uv venv $out/venv --python $out/python/bin/python3.10

        # Step: build deps, then torch from the CPU index, then the rest
        # from PyPI (torch already satisfied, so PyPI's CUDA wheels are
        # not pulled in), then the pinned transformers.
        uv pip install --python $out/venv/bin/python cython setuptools
        uv pip install --python $out/venv/bin/python \
          --index-url https://download.pytorch.org/whl/cpu \
          torch torchaudio
        uv pip install --python $out/venv/bin/python \
          ${concatMapStrings (p: "'${p}' ") packages}
        uv pip install --python $out/venv/bin/python \
          --reinstall-package transformers '${transformersPin}'

        # Step: the uv binary the app would have downloaded.
        install -Dm755 ${uv}/bin/uv $out/uv

        runHook postInstall
      '';
    };

  # The app with activation: on first run the wrapper materializes
  # ~/.nightingale/vendor from vendorBake (python copied, venv symlinked
  # for the multi-GB tree; ffmpeg and uv as real files). Keep this package in
  # your Nix profile: the vendor dir contains symlinks into the store, so
  # vendorBake must remain a GC root (it is, transitively, while this
  # package is referenced).
  nightingaleBundled =
    stdenvNoCC.mkDerivation {
      pname = "nightingale-bundled";
      inherit version;
      dontUnpack = true;

      installPhase = ''
        mkdir -p $out/bin
        cat > $out/bin/nightingale <<'EOF'
#!/usr/bin/env -S bash -e
VENDOR="$HOME/.nightingale/vendor"
if [ ! -e "$VENDOR/ffmpeg" ]; then
  mkdir -p "$VENDOR"
  # python is copied (the app directory-walks it, and WalkDir won't descend
  # into a symlink); venv is the multi-GB tree and is never walked, so it
  # stays a symlink into the store.
  cp -a __VENDOR_BAKE__/python "$VENDOR/python"
  ln -s __VENDOR_BAKE__/venv "$VENDOR/venv"
  ln -s __FFMPEG__ "$VENDOR/ffmpeg"
  install -Dm755 __VENDOR_BAKE__/uv "$VENDOR/uv"
fi
if [ -n "''${LD_LIBRARY_PATH:-}" ]; then
  export LD_LIBRARY_PATH="__WHEEL_LIBS__''$LD_LIBRARY_PATH"
else
  export LD_LIBRARY_PATH="__WHEEL_LIBS__"
fi
exec __APP__ "$@"
EOF
        sed -i \
          -e "s|__VENDOR_BAKE__|${vendorBake}|g" \
          -e "s|__FFMPEG__|${ffmpeg}/bin/ffmpeg|g" \
          -e "s|__APP__|${app}/bin/nightingale|g" \
          -e "s|__WHEEL_LIBS__|${lib.makeLibraryPath wheelLibs}|g" \
          $out/bin/nightingale
        chmod +x $out/bin/nightingale
      '';

      meta = {
        description =
          "Nightingale with the runtime ML vendor tree pre-baked (no first-launch downloads)";
        homepage = "https://github.com/rzru/nightingale";
        license = licenses.gpl3Only;
        mainProgram = "nightingale";
        platforms = [ "x86_64-linux" "aarch64-linux" ];
      };
    };
in
{ inherit vendorBake nightingaleBundled; }
