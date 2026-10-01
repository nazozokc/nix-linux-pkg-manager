# nix/flake-module.nix
# 消費側の flake に import する flake-parts モジュール。
#
#   imports = [ inputs.nix-linux-pkg-manager.flakeModules.default ];
#   nlp.declared.pacman = [ "man-db" "bash-completion" ];
#
# 評価すると packages.nlp と apps.nlp-diff / nlp-apply / nlp-update / nlp-status
# が出る。導入そのものは sudo が要るホスト操作なので、評価や build では走らない。
# `nix run .#nlp-apply` が、この flake の宣言を焼き込んだ実行体になる。
#
# オプションは flake 直下に置く。宣言は system ではなくホストの pm の話なので、
# perSystem に分けても増える情報がない。
{
  config,
  lib,
  ...
}:
let
  backends = import ./lib/backends.nix;
  inherit (import ./lib/declared.nix { inherit lib backends; }) validate;
  mkNlp = import ./lib/mk-nlp.nix { inherit lib backends validate; };

  commandNames = [
    "diff"
    "apply"
    "update"
    "status"
  ];
in
{
  options.nlp = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        false にすると packages.nlp と apps を出さない。
        モジュールを import しただけで出力を足したくないときの逃げ道。
      '';
    };

    declared = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
      example = {
        pacman = [
          "man-db"
          "bash-completion"
        ];
        apt = [ "bat" ];
      };
      description = ''
        パッケージマネージャー名からパッケージ名リストへの宣言。
        書いた pm だけを使う。書かなかった pm は空リストとして扱う。
        未知の pm 名と、pm が受理できないパッケージ名は評価時に落ちる。
      '';
    };

    appPrefix = lib.mkOption {
      type = lib.types.str;
      default = "nlp-";
      example = "nlp-";
      description = ''
        生成する app 名の接頭辞。
        既定の `nlp-` は、消費側がもともと持っている `apps.diff` を潰さないため。
        空文字にすると `diff` / `apply` / `update` / `status` になる。
      '';
    };

    defaultApp = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum commandNames);
      default = null;
      example = "diff";
      description = ''
        設定すると `apps.default` をそのコマンドにする。
        消費側の `apps.default` を勝手に奪わないよう、既定は null。
      '';
    };
  };

  config.perSystem =
    { pkgs, ... }:
    let
      built = import ./lib/apps.nix {
        inherit lib pkgs;
        nlp = mkNlp {
          inherit pkgs;
          inherit (config.nlp) declared;
        };
        inherit (config.nlp) appPrefix defaultApp;
      };
    in
    {
      # perSystem のモジュールとして返す。mkIf をモジュール全体に掛けると
      # flake-parts の deferredModule が option 定義と取り違えるので、
      # config だけを条件にする
      config = lib.mkIf config.nlp.enable {
        packages.nlp = built.package;
        apps = built.apps;
      };
    };
}
