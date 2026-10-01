# nix/flake-parts/apps.nix
# apps.default / diff / apply / update / status
#
# 実行体は nix/lib/render.nix が生成した1本のスクリプト (nlp)。
# app 側はその引数にコマンド名を渡すだけ。
# (差分ロジックは app ではなく render.nix 側にある)
#
# `program` は空白を含むと実行できない。
# nix run は program 文字列を argv[0] として直接 execve するため、
# ".../bin/nlp diff" はENOENT になる。
# → app ごとに引数無しのラッパー(app 名だけを持つスクリプト)を置き、
#   そこから nlp へ委譲する。shellcheck の実行も1回で済む。
{ backends, declared, ... }:
{
  perSystem =
    { lib, pkgs, ... }:
    let
      nlp = import ../lib/nlp.nix {
        inherit
          backends
          declared
          lib
          pkgs
          ;
      };

      mkApp =
        description: subcommand:
        let
          wrapper = pkgs.writeShellApplication {
            name = "nlp-${subcommand}";
            runtimeInputs = [ nlp ];
            # 第1引数にコマンド名を固定しつつ、后面的フラグはそのまま渡す
            # (`nix run .#apply -- --help` を効かせるため)
            text = "exec ${nlp}/bin/nlp ${subcommand} \"$@\"";
          };
        in
        {
          type = "app";
          meta.description = description;
          program = "${wrapper}/bin/nlp-${subcommand}";
        };
    in
    {
      # apps が包む共有バイナリ。引数でコマンドを選ぶので、
      # スクリプトから直接叩きたいときやテストから使うときはこれを見る
      packages.nlp = nlp;

      apps = {
        # 副作用のない diff を既定にする
        default = mkApp "宣言と導入済みを比較する (副作用なし)" "diff";
        diff = mkApp "宣言と導入済みを比較する (副作用なし)" "diff";
        apply = mkApp "不足しているパッケージを導入する" "apply";
        update = mkApp "パッケージマネージャーを更新してから不足分を補う" "update";
        status = mkApp "検出したパッケージマネージャーと宣言の件数" "status";
      };
    };
}
