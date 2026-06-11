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
