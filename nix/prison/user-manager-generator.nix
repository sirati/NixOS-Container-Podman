{ pkgs, lib, prisons }:
let
  users = lib.unique (map (p: p.user) (builtins.attrValues prisons));
in pkgs.runCommand "prison-user-managers" {
  nativeBuildInputs = [ pkgs.rustc pkgs.stdenv.cc ];
  PRISON_USERS_FILE = pkgs.writeText "prison-user-accounts" (lib.concatStringsSep "\n" users);
} ''
  rustc --edition=2024 --test ${./user-manager-generator.rs} -o tests
  ./tests
  mkdir -p "$out/bin"
  rustc --edition=2024 -O ${./user-manager-generator.rs} -o "$out/bin/prison-user-managers"
''
