{
  description = "nix で Linux のパッケージマネージャー (pacman / apt / dnf / zypper / yum) を宣言的に管理する";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # flake を複数モジュールに分割するためのフレームワーク
    flake-parts.url = "github:hercules-ci/flake-parts";

    # nix fmt (treefmt-nix)
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      nixpkgs,
      flake-parts,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      # 5 pm の定義 (nix/lib/backends.nix)
      backends = import ./nix/lib/backends.nix;

      pms = lib.attrNames backends;

      # このリポジトリ自身の宣言 (packages/<pm>.nix)。
      # 単体で `nix run .#diff` を実行するときのもの
      declared = lib.genAttrs pms (pm: import ./packages/${pm}.nix);
    in
    {
      # 配布用の公開 API。
      # 他の flake はここ経由で自分の宣言を差し込む (nix/lib/mk-nlp.nix)
      lib = {
        inherit backends pms;
        mkNlp = import ./nix/lib/mk-nlp.nix { inherit lib backends; };
      };
    }
    // flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        ./nix/flake-parts/apps.nix
        ./nix/flake-parts/checks.nix
        ./nix/flake-parts/treefmt.nix
      ];

      # 実行対象は Linux のみ。
      # pacman / apt / dnf / zypper / yum は Linux のツールなので、
      # darwin を systems に入れても評価する価値がない
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      # app / treefmt から参照する値
      _module.args = {
        inherit backends declared;
      };
    };
}
