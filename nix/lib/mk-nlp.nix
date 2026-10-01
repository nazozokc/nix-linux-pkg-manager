# nix/lib/mk-nlp.nix
# 配布用の公開関数。
#
# 他の flake から宣言を差し込んで nlp を組み立てる:
#
#   packages.<system>.default = inputs.nlp.lib.mkNlp {
#     inherit pkgs;
#     declared = {
#       pacman = [ "man-db" "bash-completion" ];
#       apt = [ "man-db" "bat" ];
#     };
#   };
#
# なぜ input 属性ではなく関数なのか:
# flake の input に許されるのは url / follows / inputs だけで、
# `declared = { ... }` を渡すと
#   error: flake input attribute 'declared' is a thunk while a string,
#   Boolean, or integer is expected
# で弾かれる。宣言は「値」なので input には載らず、関数で渡すのが正解。
{ lib, backends }:
{ pkgs, declared }:
let
  pms = lib.attrNames backends;

  # 宣言していない pm は空リスト。diff は「宣言なし」と出すので、
  # 意図しないパッケージは導入されない
  filled = lib.genAttrs pms (pm: declared.${pm} or [ ]);

  # 未知の pm 名を黙って無視すると、その宣言が永遠に効かないまま
  # 「不足なし」と嘘をつく。宣言時点で落とす
  unknown = lib.filter (pm: !(lib.elem pm pms)) (lib.attrNames declared);

  # リストでない値を黙って string 化すると、1要素の宣言が
  # "foo" ではなく 1 つの文字列扱いになる。黙って壊さず落とす
  notList = lib.filter (pm: !(lib.isList filled.${pm})) pms;
in
if unknown != [ ] then
  throw ''
    nlp: 未知のパッケージマネージャー: ${lib.concatStringsSep ", " unknown}
    利用できるのは: ${lib.concatStringsSep ", " pms}
  ''
else if notList != [ ] then
  throw ''
    nlp: 宣言は文字列のリストで書いてください: ${lib.concatStringsSep ", " notList}
  ''
else
  import ./nlp.nix {
    inherit lib backends pkgs;
    declared = filled;
  }
