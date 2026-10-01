# nix/lib/nlp.nix
# 実行体 nlp を組み立てる。
#
# apps (nix/flake-parts/apps.nix) と tests (nix/flake-parts/checks.nix) の
# 両方から使うので、定義をこの1箇所に閉じる。
# 両方で組み立てると、テストが古いロジックを検査してしまう
{
  backends,
  declared,
  lib,
  pkgs,
}:
let
  render = import ./render.nix;
in
pkgs.writeShellApplication {
  name = "nlp";

  # 照合に使う外部コマンド。
  # pacman / apt-get / dnf / rpm / zypper / yum / sudo は意図的に
  # closure に入れない。PATH 差替えで差し替えられるようにするため
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.gnused
  ];

  text = render { inherit backends declared lib; };
}
