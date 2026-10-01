# nix/lib/apps.nix
# 組み立て済みの nlp から flake の apps を作る。
#
# このリポジトリ自身 (nix/flake-module.nix) も、
# flake-parts を使わない消費側 (nix/lib/mk-apps.nix) もここを通す。
# ラッパーの形が 2 箇所に分かれると、片側だけ引数の渡し方を壊す。
#
# `program` は空白を含むと実行できない。
# nix run は program 文字列を argv[0] として直接 execve するため、
# ".../bin/nlp diff" は ENOENT になる。
# app ごとに引数無しのラッパーを置き、そこから nlp へ委譲する。
{
  lib,
  pkgs,
  nlp,
  appPrefix ? "",
  defaultApp ? null,
}:
let
  commands = {
    diff = "宣言と導入済みを比較する (副作用なし)";
    switch = "宣言を今ホストへ反映する (実行した瞬間だけ動く)";
    apply = "不足しているパッケージを導入する";
    update = "パッケージマネージャーを更新してから不足分を補う";
    status = "検出したパッケージマネージャーと宣言の件数";
  };

  mkApp =
    subcommand: description:
    let
      wrapper = pkgs.writeShellApplication {
        name = "nlp-${subcommand}";
        runtimeInputs = [ nlp ];
        # 第1引数にコマンド名を固定しつつ、後ろのフラグはそのまま渡す
        # (`nix run .#apply -- --help` を効かせるため)
        text = "exec ${nlp}/bin/nlp ${subcommand} \"$@\"";
      };
    in
    {
      type = "app";
      meta.description = description;
      program = "${wrapper}/bin/nlp-${subcommand}";
    };

  named = lib.mapAttrs mkApp commands;

  # switch だけは接頭辞を付けない。アクションの瞬間は `nix run .#switch`。
  # diff などは接頭辞付きのままにして、消費側の既存 app を潰さない。
  apps =
    lib.mapAttrs' (
      name: app:
      lib.nameValuePair (if name == "switch" then name else "${appPrefix}${name}") app
    ) named;
in
{
  package = nlp;
  apps =
    apps
    // lib.optionalAttrs (defaultApp != null) {
      default =
        let
          name = if defaultApp == "switch" then defaultApp else "${appPrefix}${defaultApp}";
        in
        apps.${name};
    };
}
