let
  moz_overlay = import (builtins.fetchTarball https://github.com/mozilla/nixpkgs-mozilla/archive/master.tar.gz);
  nixpkgs = import <nixpkgs> {
    overlays = [ moz_overlay ];
  };

  date = "2018-12-26";
  wasmTarget = "wasm32-unknown-unknown";

  rust-build = (nixpkgs.rustChannelOfTargets "nightly" date [ wasmTarget ]);

  nodejs-8_13 = nixpkgs.nodejs-8_x.overrideAttrs(oldAttrs: rec {
    name = "nodejs-${version}";
    version = "8.13.0";
    src = nixpkgs.fetchurl {
      url = "https://nodejs.org/dist/v${version}/node-v${version}.tar.xz";
      sha256 = "1qidcj4smxsz3pmamg3czgk6hlbw71yw537h2jfk7iinlds99a9a";
    };
  });

  hc-flush-cargo-registry = nixpkgs.writeShellScriptBin "hc-flush-cargo-registry"
  ''
   rm -rf ~/.cargo/registry;
   rm -rf ~/.cargo/git;
  '';

  hc-install-node-container = nixpkgs.writeShellScriptBin "hc-install-node-container"
  ''
   . ./scripts/build_nodejs_container.sh;
  '';

  hc-install-tarpaulin = nixpkgs.writeShellScriptBin "hc-install-tarpaulin"
  ''
   if ! cargo --list | grep --quiet tarpaulin;
   then
    RUSTFLAGS="--cfg procmacro2_semver_exempt" cargo install --vers 0.6.11 cargo-tarpaulin;
   fi;
  '';
  hc-tarpaulin = nixpkgs.writeShellScriptBin "hc-tarpaulin"
  ''
   CARGO_TARGET_DIR=/tmp/tarpaulin cargo tarpaulin \
    --all \
    --verbose \
    --release \
    --forward \
    --ignore-panics \
    --ignore-tests \
    --timeout 5 \
    --out Xml \
    -e holochain_core_api_c_binding \
    -e hdk \
    -e hc \
    -e holochain_core_types_derive \
    ;
  '';

  hc-install-cmd = nixpkgs.writeShellScriptBin "hc-install-cmd" "cargo build -p hc --release && cargo install -f --path cmd";
  hc-test-cmd = nixpkgs.writeShellScriptBin "hc-test-cmd" "cd cmd && cargo test";
  hc-test-app-spec = nixpkgs.writeShellScriptBin "hc-test-app-spec" "cd app_spec && . build_and_test.sh";

  hc-fmt = nixpkgs.writeShellScriptBin "hc-fmt" "cargo fmt";
  hc-fmt-check = nixpkgs.writeShellScriptBin "hc-fmt-check" "cargo fmt -- --check";

  # runs all standard tests and reports code coverage
  hc-codecov = nixpkgs.writeShellScriptBin "hc-codecov"
  ''
   hc-build-wasm && \
   hc-install-tarpaulin && \
   hc-tarpaulin && \
   bash <(curl -s https://codecov.io/bash);
  '';

  # simulates all supported ci tests in a local circle ci environment
  ci = nixpkgs.writeShellScriptBin "ci"
  ''
   circleci-cli local execute
  '';

  build-wasm = wasm-path:
  ''
   export WASM_PATH=${wasm-path}/
   cargo build --release --target wasm32-unknown-unknown --manifest-path "$WASM_PATH"Cargo.toml --target-dir "$HC_TARGET_PREFIX""$WASM_PATH"target;
  '';
  wasm-paths = [
   "hdk-rust/wasm-test"
   "wasm_utils/wasm-test/integration-test"
   "container_api/wasm-test"
   "container_api/test-bridge-caller"
   "core/src/nucleus/actions/wasm-test"
  ];
  hc-build-wasm = nixpkgs.writeShellScriptBin "hc-build-wasm"
  ''
   ${nixpkgs.lib.concatMapStrings (path: build-wasm path) wasm-paths}
  '';
  hc-test = nixpkgs.writeShellScriptBin "hc-test"
  ''
   hc-build-wasm
   cargo test --all --release --target-dir "$HC_TARGET_PREFIX"target;
  '';

in
with nixpkgs;
stdenv.mkDerivation rec {
  name = "holochain-rust-environment";

  buildInputs = [

    # https://github.com/NixOS/nixpkgs/blob/master/doc/languages-frameworks/rust.section.md
    binutils gcc gnumake openssl pkgconfig coreutils
    # carnix

    cmake
    python
    pkgconfig
    rust-build

    nodejs-8_13
    yarn

    hc-flush-cargo-registry

    hc-build-wasm
    hc-test

    hc-install-tarpaulin
    hc-tarpaulin

    hc-install-cmd
    hc-install-node-container

    hc-test-cmd
    hc-test-app-spec

    hc-fmt
    hc-fmt-check

    zeromq4

    # dev tooling
    git

    # curl needed to push to codecov
    curl
    docker
    circleci-cli
    hc-codecov
    ci
  ];

  # https://github.com/rust-unofficial/patterns/blob/master/anti_patterns/deny-warnings.md
  # https://llogiq.github.io/2017/06/01/perf-pitfalls.html
  RUSTFLAGS = "-D warnings -Z external-macro-backtrace -Z thinlto -C codegen-units=16 -C opt-level=z";
  CARGO_INCREMENTAL = "1";
  # https://github.com/rust-lang/cargo/issues/4961#issuecomment-359189913
  # RUST_LOG = "info";

  # non-nixos OS can have a "dirty" setup with rustup installed for the current
  # user.
  # `nix-shell` can inherit this e.g. through sourcing `.bashrc`.
  # even `nix-shell --pure` will still source some files and inherit paths.
  # for those users we can at least give the OS a clue that we want our pinned
  # rust version through this environment variable.
  # https://github.com/rust-lang/rustup.rs#environment-variables
  # https://github.com/NixOS/nix/issues/903
  RUSTUP_TOOLCHAIN = "nightly-${date}";

  HC_TARGET_PREFIX = "/tmp/holochain/";
  # CARGO_TARGET_DIR = "${HC_TARGET_PREFIX}target";

  shellHook = ''
   # needed for install cmd and tarpaulin
   export PATH=$PATH:~/.cargo/bin;
  '';
}
