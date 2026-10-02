# nix/home-manager-module.nix
# 消費側の home-manager 設定に import する。
#
#   imports = [ inputs.nix-linux-pkg-manager.flakeModules.home-manager ];
#   programs.nlp = {
#     enable = true;
#     declared.pacman = ./packages/pacman.nix;
#   };
#
# やるのは「宣言を焼き込んだ nlp を home.packages に載せる」だけ。
#
# apply / update は sudo が要るので activation では走らせない。
# パスワード入力を activation の中に挟むと、非対話の switch や CI で必ず詰まる。
# 運用は「switch のあとに `nlp apply` を手で打つ」で固定する。
# いつ走らせるかは消費側の都合なので、ここでは決めない
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.nlp;

  backends = import ./lib/backends.nix;

  # 検査は flake-parts 版と同じものを通す
  declaredCheck = import ./lib/declared.nix { inherit lib backends; };
  inherit (declaredCheck) validate;

  mkNlp = import ./lib/mk-nlp.nix { inherit lib backends validate; };

  # 宣言を焼き込んだ実行体。enable = false のときはこの thunk は触られない
  # (config 側が mkIf で包んでいるため)
  package = mkNlp {
    inherit pkgs;
    inherit (cfg) declared;
  };
in
{
  options.programs.nlp = {
    enable = lib.mkEnableOption "宣言を焼き込んだ nlp を home.packages に載せる";

    declared = lib.mkOption {
      # リストでもファイルでも書ける。nix/lib/declared.nix が import する
      type = lib.types.attrsOf (lib.types.either (lib.types.listOf lib.types.str) lib.types.path);
      default = { };
      example = {
        pacman = ./packages/pacman.nix;
        apt = [
          "man-db"
          "bash-completion"
        ];
      };
      description = ''
        パッケージマネージャー名からパッケージ名リストへの宣言。
        リストでもファイルでも書ける。ファイルは評価時に import され、
        中身がリストでなければ評価時に落ちる。
        書いた pm だけを使う。書かなかった pm は空リストとして扱う。
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = package;
      defaultText = lib.literalExpression "nlp (nlp.declared を焼き込んだ実行体)";
      description = ''
        home.packages に載せる実行体。
        宣言はそのままに、本体だけ差し替えたいときに指定する。
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # pacman / apt / dnf / zypper / yum は Linux のツール。
    # darwin の home-manager には載せない (evaluation にも意味がない)
    home.packages = lib.mkIf pkgs.stdenv.hostPlatform.isLinux [ cfg.package ];
  };
}
