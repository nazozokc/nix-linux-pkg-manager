# nix/lib/declared.nix
# 宣言 (packages/<pm>.nix / lib.mkNlp に渡す declared) の検査。
#
# なぜここで落とすのか
#   宣言は実行時のスクリプトに文字列として埋め込まれる。埋め込み自体は
#   単一引用符リテラルとして行うので、値の解釈は安全だ。ただしその値を
#   IFS で分割して pm の引数にするので、
#
#     - 空白を含む名前は 1 個が複数の引数に裂け、宣言件数も照合結果も嘘になる
#     - 制御文字や DEL を含む名前は出力と対比できなくなる
#
#   黙って直す実装 (空文字を落とす / 空白で分割する) は、
#   いちばん危ないのは「不足なし」に見えてしまうこと。だから評価時に落とす。
#
# ここで確かめるのは「形の正しさ」までで、pm がその名前を持っているかは見ない。
# 実在しない名前は apt の E: や pacman の終了コードで実行時に落とす
# (nix/lib/script/30-query.sh の query_failed)。
#
# 検査と throw を分ける理由
#   Nix 2.35 の builtins.tryEval は、throw したときのメッセージを読めない
#   (r.value を触ると同じ例外が再送出される)。 throw で検査すると
#   「落ちた」ことしか分からず、テストも 1 ケースごとに 1 プロセスになる。
#   そこで problems は「問題を文字列のリストで返す」だけの純関数にして、
#   validate がそれを throw に変換する。全部まとめて報告できるし、
#   テストは Nix 式の中でそのまま比較できる
{ lib, backends }:

let
  pms = lib.attrNames backends;

  # pm が受理するパッケージ名の形。
  # 素の英数字と . + - _ : だけを許す。空白 / $ / ; / ` / glob 文字はすべて弾く。
  #
  # 通る名前: gcc-c++ python3.11 lib32-gtk3 nvidia-550xx-dkms java-17-openjdk
  # 弾く名前: "ripgrep; rm -rf /" "a b" "$(id)" "foo bar"
  namePattern = "^[A-Za-z0-9][A-Za-z0-9+._:-]*$";

  where = pm: "packages/${pm}.nix";

  # 1 個の宣言の検査結果。問題が無ければ空リスト
  entryProblems =
    pm: entry:
    if !lib.isString entry then
      [
        ''
          nlp: ${where pm} の宣言は文字列で書いてください
          実際: ${lib.typeOf entry}
        ''
      ]
    else if entry == "" then
      [
        ''
          nlp: ${where pm} の宣言に空文字列は書けません
          空の名前を黙って落とすと宣言件数が狂うので掉落させる
        ''
      ]
    else if !(builtins.match namePattern entry != null) then
      [
        ''
          nlp: ${where pm} の宣言に pm が受理できないパッケージ名があります
          名前: "${entry}"
          使える文字: 英数字と . + - _ :
          注意: 空白・$・;・`・glob 文字を含む名前は、引数の区切りや
                shell の構文として解釈され照合結果が変わります
        ''
      ]
    else
      [ ];
in
rec {
  # 宣言全体の検査結果を文字列のリストで返す。throw はしない
  problems =
    declared:
    if !lib.isAttrs declared then
      [
        ''
          nlp: declared はパッケージマネージャーごとのリスト attrset で書いてください
          実際: ${lib.typeOf declared}
        ''
      ]
    else
      let
        names = lib.attrNames declared;

        # 未知の pm 名を黙って無視すると、その宣言は永遠に効かないまま
        # 「不足なし」と嘘をつく
        unknown = lib.filter (pm: !(lib.elem pm pms)) names;

        notList = lib.filter (pm: !(lib.isList declared.${pm} or [ ])) names;

        # 要素まで見るのは「宣言されていて、かつリストである pm」だけ。
        # pms をそのまま回すと、宣言に無い pm で declared.${pm} が
        # 属性不存在になって落ちる
        listable = lib.filter (pm: !(lib.elem pm notList)) names;

        # 入れ子は 2 段: imap1 が「pm ごとのリスト」、その中身が
        # 「要素ごとのリスト」。lib.concatLists は 1 段しか平坦化しないので
        # 2 回呼ぶ。忘れると problems の要素がリストのまま残って、
        # 文字列として連結しようとしたところで落ちる
        listProblems = lib.concatLists (
          map (
            pm:
            lib.concatLists (
              lib.imap1 (
                idx: entry: (map (m: "  ${toString idx} 番目: ${m}") (entryProblems pm entry))
              ) declared.${pm}
            )
          ) listable
        );
      in
      (
        if unknown != [ ] then
          [
            ''
              nlp: 未知のパッケージマネージャー: ${lib.concatStringsSep ", " unknown}
              利用できるのは: ${lib.concatStringsSep ", " pms}
            ''
          ]
        else
          [ ]
      )
      ++ (
        if notList != [ ] then
          map (pm: ''
            nlp: ${where pm} の宣言はリストで書いてください
            実際: ${lib.typeOf declared.${pm}}
          '') notList
        else
          [ ]
      )
      ++ listProblems;

  # 検査結果。normalized は宣言を pm ごとに揃えたもの
  # (書かなかった pm は空リスト。diff が「宣言なし」と出す)
  #
  # lib.mapAttrs ではなく lib.genAttrs pms を使う。
  # mapAttrs だと宣言が無い pm が落ちて、差分計算の前提が崩れる
  check =
    declared:
    let
      errs = problems declared;
    in
    {
      ok = errs == [ ];
      errors = errs;
      normalized = lib.genAttrs pms (
        pm:
        # 重複は黙って 1 個に落とす。宣言件数の表示が狂うのを防ぐ
        lib.unique (declared.${pm} or [ ])
      );
    };

  # 検査して、問題があればまとめて throw する。
  # 問題がなければ正規化した宣言を返す
  validate =
    declared:
    let
      c = check declared;
    in
    if c.ok then c.normalized else throw (lib.concatStringsSep "\n" c.errors);
}
