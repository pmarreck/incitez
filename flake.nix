{
  description = "incitez — legal citation extraction engine (eyecite-compatible) in Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Pinned upstream sources (non-flake): the differential oracle and the
    # citation databases we vendor from. flake.lock IS the pin.
    eyecite-src = {
      url = "github:freelawproject/eyecite";
      flake = false;
    };
    reporters-db-src = {
      url = "github:freelawproject/reporters-db";
      flake = false;
    };
    courts-db-src = {
      url = "github:freelawproject/courts-db";
      flake = false;
    };
    # Peter's PCRE2 fork — alternate regex-engine code path for the
    # dual-engine comparison harness (vm vs pcre2 vs python oracle).
    pcre2-src = {
      # git+submodules: JIT requires the sljit submodule, absent from
      # GitHub tarball fetches
      url = "git+https://github.com/pmarreck/pcre2?submodules=1";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay, eyecite-src, reporters-db-src, courts-db-src, pcre2-src }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = zig-overlay.packages.${system}."0.16.0";
        isDarwin = pkgs.stdenv.isDarwin;

        darwinInputs = pkgs.lib.optionals isDarwin [
          pkgs.darwin.cctools
          pkgs.apple-sdk
        ];

        # Static PCRE2 (8-bit, JIT) from Peter's fork, for the alternate
        # engine path. CMake build straight from the git tree.
        pcre2 = pkgs.stdenv.mkDerivation {
          pname = "pcre2-static";
          version = "fork";
          src = pcre2-src;
          nativeBuildInputs = [ pkgs.cmake ];
          cmakeFlags = [
            "-DBUILD_SHARED_LIBS=OFF"
            "-DPCRE2_SUPPORT_JIT=ON"
            "-DPCRE2_BUILD_PCRE2GREP=OFF"
            "-DPCRE2_BUILD_TESTS=OFF"
            # absolute install dirs: pcre2's pkgconfig templates otherwise
            # trip nixpkgs' broken-cmake-paths check (nixpkgs#144170)
            "-DCMAKE_INSTALL_LIBDIR=${placeholder "out"}/lib"
            "-DCMAKE_INSTALL_INCLUDEDIR=${placeholder "out"}/include"
          ];
          # We consume lib/libpcre2-8.a + include/ directly; the generated
          # pkgconfig/scripts double-join prefixes (nixpkgs#144170) and the
          # docs are dead weight — drop them rather than patch them.
          postInstall = ''
            rm -rf $out/lib/pkgconfig $out/bin $out/share $out/lib/cmake
          '';
        };

        # ── Pinned eyecite as the differential oracle ────────────────────
        # Test-time only; never ships in the binary. The one justified
        # exception to the no-Python rule: there is no other oracle of
        # comparable authority for citation extraction.
        py = pkgs.python3Packages;

        fast-diff-match-patch = py.buildPythonPackage rec {
          pname = "fast_diff_match_patch";
          version = "2.1.0";
          pyproject = true;
          src = py.fetchPypi {
            inherit pname version;
            hash = "sha256-rEAte/8EqE82PMW/qUhQm8TvhELG691WTETcOWE77EA=";
          };
          build-system = [ py.setuptools ];
          doCheck = false;
        };

        reporters-db-py = py.buildPythonPackage {
          pname = "reporters-db";
          version = "3.2.65";
          pyproject = true;
          src = reporters-db-src;
          build-system = [ py.setuptools ];
          doCheck = false;
        };

        courts-db-py = py.buildPythonPackage {
          pname = "courts-db";
          version = "0.10.27";
          pyproject = true;
          src = courts-db-src;
          build-system = [ py.setuptools ];
          doCheck = false;
        };

        eyecite = py.buildPythonPackage {
          pname = "eyecite";
          version = "2.7.6";
          pyproject = true;
          src = eyecite-src;
          build-system = [ py.setuptools ];
          dependencies = [
            courts-db-py
            reporters-db-py
            fast-diff-match-patch
            py.lxml
            py.pyahocorasick
            py.regex
          ];
          doCheck = false;
        };

        eyecitePython = pkgs.python3.withPackages (_: [ eyecite ]);

        darwinIncludeHook = pkgs.lib.optionalString isDarwin ''
          export C_INCLUDE_PATH="${pkgs.apple-sdk}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include''${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
        '';

        mkIncitez = optimizeMode: pkgs.stdenv.mkDerivation {
          pname = "incitez";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = [ zig ] ++ darwinInputs;

          dontConfigure = true;

          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p $ZIG_GLOBAL_CACHE_DIR
            ${darwinIncludeHook}
            zig build --prefix $out -Doptimize=${optimizeMode} -Dpcre2-prefix=${pcre2}
          '';

          dontInstall = true;
          dontFixup = true;
        };
      in {
        packages.default = mkIncitez "ReleaseFast";
        packages.debug = mkIncitez "Debug";
        # Oracle env for corpus extraction + differential testing (test-time only)
        packages.eyecite-env = eyecitePython;
        # Exposed for direct builds/debugging of the engine dependency
        packages.pcre2 = pcre2;

        checks.test = pkgs.stdenv.mkDerivation {
          pname = "incitez-test";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = [ zig ]
            ++ darwinInputs
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.patchelf ];

          dontConfigure = true;

          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p $ZIG_GLOBAL_CACHE_DIR
            ${darwinIncludeHook}
            # On Linux, Zig with link_libc bakes the FHS dynamic-linker path
            # into binaries, which does not exist in the Nix sandbox. Compile
            # the test binaries first, patchelf them, then run the test step
            # which reuses the cached (now patched) artifacts.
            export PCRE2_PREFIX=${pcre2}
            ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
              zig build test-compile -Dpcre2-prefix=${pcre2}
              DL="$(cat ${pkgs.stdenv.cc}/nix-support/dynamic-linker)"
              for d in .zig-cache zig-out; do
                [ -d "$d" ] || continue
                for f in $(find "$d" -type f -perm -u+x); do
                  patchelf --set-interpreter "$DL" "$f" 2>/dev/null || true
                done
              done
            ''}
            timeout 600 zig build test -Dpcre2-prefix=${pcre2} || {
              echo "Tests timed out or failed after 10 minutes"
              exit 1
            }
          '';

          installPhase = ''
            mkdir -p $out
            echo "tests passed" > $out/result
          '';
        };

        # Differential gate vs the pinned eyecite oracle, in CI. No network:
        # eyecitePython and the corpora are all store paths / src files.
        checks.differential = pkgs.stdenv.mkDerivation {
          pname = "incitez-differential";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = [ zig eyecitePython ]
            ++ darwinInputs
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.patchelf ];

          dontConfigure = true;

          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p $ZIG_GLOBAL_CACHE_DIR
            ${darwinIncludeHook}
            zig build -Doptimize=ReleaseFast -Dpcre2-prefix=${pcre2}
            ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
              DL="$(cat ${pkgs.stdenv.cc}/nix-support/dynamic-linker)"
              for f in $(find zig-out -type f -perm -u+x); do
                patchelf --set-interpreter "$DL" "$f" 2>/dev/null || true
              done
            ''}
            python tools/diff_oracle.py build-texts \
              tests/corpus/eyecite_corpus.json \
              tests/corpus/eyecite_resolve_corpus.json \
              $TMPDIR/texts.json
            zig-out/bin/incitez-diffdump $TMPDIR/texts.json > $TMPDIR/dump.json
            python tools/diff_oracle.py compare \
              $TMPDIR/texts.json $TMPDIR/dump.json tests/expected_divergences.json
          '';

          installPhase = ''
            mkdir -p $out
            echo "differential gate passed" > $out/result
          '';
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            zig
            pkgs.hyperfine
            pkgs.jq
          ];

          # Source-analysis convenience: where the pinned upstream sources live.
          shellHook = ''
            export PCRE2_PREFIX="${pcre2}"
            echo "incitez dev shell"
            echo "  zig:          $(zig version)"
            echo "  eyecite:      ${eyecite-src}"
            echo "  reporters-db: ${reporters-db-src}"
            echo "  courts-db:    ${courts-db-src}"
            echo "  pcre2:        ${pcre2}"
          '';
        };
      }
    );
}
