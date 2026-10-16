# app-runner, built with plain rustc like nix/prison/user-manager-generator.nix.
# The unit tests run as part of the build, so a runner that mishandles a plan
# or a hostile path never reaches a store path anyone launches an app from.
{ pkgs }:

pkgs.runCommand "app-runner"
  {
    nativeBuildInputs = [
      pkgs.rustc
      pkgs.stdenv.cc
    ];
  }
  ''
    rustc --edition=2024 -D warnings --test ${./runner.rs} -o tests
    ./tests
    mkdir -p "$out/bin"
    rustc --edition=2024 -D warnings -O ${./runner.rs} -o "$out/bin/app-runner"
  ''
