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
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay, eyecite-src, reporters-db-src, courts-db-src }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = zig-overlay.packages.${system}."0.16.0";
        isDarwin = pkgs.stdenv.isDarwin;

        darwinInputs = pkgs.lib.optionals isDarwin [
          pkgs.darwin.cctools
          pkgs.apple-sdk
        ];

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
            zig build --prefix $out -Doptimize=${optimizeMode}
          '';

          dontInstall = true;
          dontFixup = true;
        };
      in {
        packages.default = mkIncitez "ReleaseFast";
        packages.debug = mkIncitez "Debug";
        # Oracle env for corpus extraction + differential testing (test-time only)
        packages.eyecite-env = eyecitePython;

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
            ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
              zig build test-compile
              DL="$(cat ${pkgs.stdenv.cc}/nix-support/dynamic-linker)"
              for d in .zig-cache zig-out; do
                [ -d "$d" ] || continue
                for f in $(find "$d" -type f -perm -u+x); do
                  patchelf --set-interpreter "$DL" "$f" 2>/dev/null || true
                done
              done
            ''}
            timeout 600 zig build test || {
              echo "Tests timed out or failed after 10 minutes"
              exit 1
            }
          '';

          installPhase = ''
            mkdir -p $out
            echo "tests passed" > $out/result
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
            echo "incitez dev shell"
            echo "  zig:          $(zig version)"
            echo "  eyecite:      ${eyecite-src}"
            echo "  reporters-db: ${reporters-db-src}"
            echo "  courts-db:    ${courts-db-src}"
          '';
        };
      }
    );
}
