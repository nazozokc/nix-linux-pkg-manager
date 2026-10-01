# nix/lib/render.nix
# 宣言 (packages/*.nix) + backend 定義 (nix/lib/backends.nix) から
# 実行する bash を1本の文字列として生成する。
#
# 設計上の要点
#   - 宣言は Nix 側。`nix eval` / `nix flake check` は pure 評価のまま通る
#   - 「導入済みか」の照合は実行時 bash。installed 一覧を Nix 側で読むと
#     `builtins.readFile` が必要になり pure 評価が壊れるため、ここには置かない
#   - diff エンジンは backend のデータ形状に依存しない。
#     対応 pm を増やしてもこのファイルは変わらない
#
# shell 変数へ埋め込む値の制約:
#   - シングルクォートで囲まない。backend.nix 側（pacman/dnf の
#     `rpm --qf '%{NAME}\n'` 等）がシングルクォートを含むため、
#     ダブルクォートで囲む
#   - 値に `$` とバッククォートを含めない（含ませると生成した
#     スクリプトで変数展開が走る）
#   - パッケージ列の差し込み位置は `@PKGS@` を使う。`%s` は
#     bash の pattern substitution で「任意文字列」.glob として
#     解釈され、変数全体が置き換わってしまう
{
  lib,
  declared,
  backends,
}:

let
  pms = lib.attrNames backends;

  # 宣言を空白区切りの1行に畳む
  renderDeclared =
    pm:
    let
      list = declared.${pm} or [ ];
    in
    lib.concatStringsSep " " (lib.filter (p: p != "" && !(lib.hasInfix "\n" p)) list);

  # backend 1件 -> 連想配列への代入
  renderBackend =
    pm:
    let
      b = backends.${pm};
    in
    ''
      PM_LABEL[${pm}]="${b.label}"
      PM_BINARY[${pm}]="${b.binary}"
      PM_LOCK[${pm}]="${b.lock}"
      PM_EXPLICIT[${pm}]="${b.explicit}"
      PM_MISSING[${pm}]="${b.missingQuery.cmd "@PKGS@"}"
      PM_MISSING_OUTPUT[${pm}]="${b.missingQuery.output}"
      PM_MISSING_PARSE[${pm}]="${b.missingQuery.extract}"
      PM_INSTALL[${pm}]="${b.install "@PKGS@"}"
      PM_UPDATE[${pm}]="${lib.concatStringsSep "\n" b.update}"
      DECLARED[${pm}]="${renderDeclared pm}"
    '';
in

''
    # ===================================================================
    # nix-linux-packages — 生成された実行体 (nix/lib/render.nix が生成)
    #
    #   - 宣言と backend 定義は Nix が評価して埋め込んだ静的な値
    #   - 導入済みの照合と diff 計算はここ (実行時) で行う
    # ===================================================================
    set -euo pipefail
  # 分割を意図して使うため、グロブ展開を切る
  set -f

    if [ -t 1 ] && [ -z "''${NO_COLOR:-}" ]; then
      C_B=$'\033[1m'
      C_D=$'\033[2m'
      C_R=$'\033[31m'
      C_G=$'\033[32m'
      C_Y=$'\033[33m'
      C_0=$'\033[0m'
    else
      C_B=""
      C_D=""
      C_R=""
      C_G=""
      C_Y=""
      C_0=""
    fi

    usage() {
      cat <<'USAGE'
    nix-linux-packages — 宣言的に Linux のパッケージマネージャーを扱う

    usage: nix run .#<command>

      diff     宣言と導入済みを比較する (default / 副作用なし)
      apply    不足しているパッケージを導入する
      update   パッケージマネージャーを更新してから不足分を補う
      status   検出したパッケージマネージャーと宣言の件数
  USAGE
    }

    # -------------------------------------------------------------------
    # 宣言と backend 定義 (Nix が埋め込む)
    # -------------------------------------------------------------------
    declare -A PM_LABEL PM_BINARY PM_LOCK PM_EXPLICIT
    declare -A PM_MISSING PM_MISSING_OUTPUT PM_MISSING_PARSE
    declare -A PM_INSTALL PM_UPDATE DECLARED

    PM_ORDER='${lib.concatStringsSep " " pms}'
    ${lib.concatMapStringsSep "\n" renderBackend pms}

    # -------------------------------------------------------------------
    # 照合ロジック (pm 非依存)
    # -------------------------------------------------------------------

  # 宣言パッケージを1行1個・ソート済みで出力する
  declared_of() {
    local s="''${DECLARED[$1]}"
    [ -n "$s" ] || return 0
    # 分割が目的 (空白区切り)。shellcheck disable は意図的な wordsplitting
    # shellcheck disable=SC2086
    printf '%s\n' $s | sort -u
  }

  # 空白区切りのコマンド文字列を配列に分解して実行する。
  #
  # eval を使わないのが要点。eval だと rpm --qf '%{NAME}\n' の
  # ''${NAME} が空の変数として展開され、`%{NAME}` が `%` だけになる
  # (dnf / zypper / yum の照合が全部壊れる)
  run_query() {
    local cmd="$1" extra="''${2:-}"
    local -a argv=()
    local -a extra_argv=()
    read -ra argv <<<"$cmd"
    [ "''${#argv[@]}" -gt 0 ] || return 0
    if [ -n "$extra" ]; then
      read -ra extra_argv <<<"$extra"
      argv+=("''${extra_argv[@]}")
    fi
    "''${argv[@]}"
  }

  # 明示的に導入されたパッケージを1行1個・ソート済みで出力する
  # (依存として入ったものは含めない)
  explicit_of() {
    run_query "''${PM_EXPLICIT[$1]}" 2>/dev/null | sed '/^[[:space:]]*$/d' | sort -u
  }

  # 不足パッケージを1行1個・ソート済みで出力する
  #
  # 照合コマンドの stderr にエラー行があれば rc=2 で異常終了する。
  # これが無いと、宣言に存在しないパッケージ名が1つ混ざっただけで
  # apt が E: で異常終了し Inst 行が1行も出ないまま
  # 「不足なし」に見えてしまう (偽陰性)
  missing_of() {
    local pm="$1" cmd raw out err

    # @PKGS@ は TOKEN として残っているので落とし、宣言列は extra として渡す
    cmd="''${PM_MISSING[$pm]//@PKGS@/}"

    err="$(mktemp)"

    # pacman -T は不足があると rc=127 で終わる。
    # 管道の終了コードは sed なので set -e では落ちないが、
    # 将来の pipefail 追加に備えて失敗しても必ず受理する
    raw="$(run_query "$cmd" "$(declared_of "$pm" | tr '\n' ' ')" 2>"$err" || true)"

    # apt は不足が無くても "NOTE: This is only a simulation!" を stderr に出すので、
    # stderr が空かどうかではなくエラー行があるかどうかを見る
    if grep -qE '^(E|error):|^Unable to locate package|^No package matching' "$err"; then
      printf '\n  %s%s: 照合コマンドがエラー。宣言に実在しないパッケージ名があります%s\n' \
        "$C_R" "$pm" "$C_0" >&2
      sed 's/^/    /' "$err" >&2
      rm -f "$err"
      return 2
    fi
    rm -f "$err"

    out="$(
      printf '%s\n' "$raw" \
        | sed -n "''${PM_MISSING_PARSE[$pm]}p" \
        | sed '/^[[:space:]]*$/d' \
        | sort -u
    )"

      case "''${PM_MISSING_OUTPUT[$pm]}" in
        satisfied)
          # 充足名を引くと不足名になる。
          # 充足名が空なら宣言全体が不足
          if [ -z "$out" ]; then
            declared_of "$pm"
            return 0
          fi
          comm -23 <(declared_of "$pm") <(printf '%s\n' "$out")
          ;;
        *)
          printf '%s\n' "$out"
          ;;
      esac
    }

  # -------------------------------------------------------------------
  # 表示
  # -------------------------------------------------------------------
    count_lines() {
      printf '%s' "$1" | grep -c . || true
    }

    print_list() {
      local limit="$1" body="$2" n
      n="$(count_lines "$body")"
      [ "$n" -gt 0 ] || return 0
      if [ "$n" -gt "$limit" ]; then
        printf '%s\n' "$body" | head -n "$limit" | sed 's/^/    - /'
        printf '    %s... 他 %s 個%s\n' "$C_D" "$((n - limit))" "$C_0"
      else
        printf '%s\n' "$body" | sed 's/^/    - /'
      fi
    }

    # -------------------------------------------------------------------
    # pm の検出
    # -------------------------------------------------------------------
    detect_pm() {
      local pm
      for pm in $PM_ORDER; do
        if command -v "''${PM_BINARY[$pm]}" >/dev/null 2>&1; then
          printf '%s\n' "$pm"
          return 0
        fi
      done
      return 1
    }

  host_id() {
    local id=""
    if [ -r /etc/os-release ]; then
      # shellcheck disable=SC1091  # /etc/os-release は実行環境にしか無い
      id="$(. /etc/os-release 2>/dev/null && printf '%s' "''${ID:-}")"
    fi
    printf '%s' "''${id:-unknown}"
  }

    # -------------------------------------------------------------------
    # コマンド
    # -------------------------------------------------------------------

    # 宣言と導入済みを比較する (副作用なし)
    do_diff() {
      local pm="$1"
      local missing unmanaged installed n_declared

      if [ -z "''${DECLARED[$pm]}" ]; then
        printf '  %s%s は宣言なし%s (packages/%s.nix)\n' "$C_Y" "$pm" "$C_0" "$pm"
        return 0
      fi

      missing="$(missing_of "$pm")" || return 2
      unmanaged="$(comm -13 <(declared_of "$pm") <(explicit_of "$pm"))"
      n_declared="$(count_lines "$(declared_of "$pm")")"
      installed="$((n_declared - $(count_lines "$missing")))"

    printf '\n  %shost%s     %s (%s) %s· %s 宣言%s\n' "$C_B" "$C_0" "$(host_id)" \
      "''${PM_LABEL[$pm]}" "$C_D" "$n_declared" "$C_0"
    printf '\n'

      printf '  installed %s%3d%s\n' "$C_D" "$installed" "$C_0"
      printf '  missing   %s%3d%s\n' \
        "$([ -n "$missing" ] && printf '%s' "$C_Y" || printf '%s' "$C_G")" \
        "$(count_lines "$missing")" "$C_0"
      print_list 20 "$missing"

      printf '  unmanaged %s%3d%s  %s宣言に無いが明示導入済み%s\n' \
        "$C_D" "$(count_lines "$unmanaged")" "$C_0" "$C_D" "$C_0"
      print_list 10 "$unmanaged"
      printf '\n'
    }

  # 不足分を導入する
  do_apply() {
    local pm="$1" missing pkgs install_cmd
    missing="$(missing_of "$pm")" || return 2

    if [ -z "$missing" ]; then
      printf '  %s不足なし%s (何もしません)\n' "$C_G" "$C_0"
      return 0
    fi

    # 不足は1行1個で返る。コマンド列へ差し込む前に空白区切りへ畳む。
    # 畳まないと嵌入した改行が eval でコマンド区切りになり、
    # 2個目以降がコマンドとして実行される
    pkgs="$(printf '%s' "$missing" | tr '\n' ' ')"
    install_cmd="''${PM_INSTALL[$pm]//@PKGS@/$pkgs}"

    printf '  %s導入%s\n' "$C_B" "$C_0"
    print_list 50 "$missing"
    printf '  %ssudo %s%s\n' "$C_D" "$install_cmd" "$C_0"

    sudo -v
    # パッケージ列は空白区切りに分割して渡す (意図的)
    eval "sudo $install_cmd"
  }

    # pm 自身を更新してから不足分を補う
    #
    # update は1コマンドずつ sudo を付ける。
    # `&&` で1本に繋いで sudo を前置すると、2個目以降が root でないまま走る
    do_update() {
      local pm="$1" c
      sudo -v
      while IFS= read -r c; do
        [ -n "$c" ] || continue
        printf '  %supdate%s  %ssudo %s%s\n' "$C_B" "$C_0" "$C_D" "$c" "$C_0"
        eval "sudo $c"
      done <<<"''${PM_UPDATE[$pm]}"
      printf '\n'
      do_apply "$pm"
    }

    # 検出結果と宣言の件数だけを報告する (副作用なし)
    #
    # binary カラムは full path が入るので幅に余裕を持たせる。
    # 色エスケープを %-Ns の中に入れると幅計算が壊れるので、
    # 整形は全部済ませてから色を付ける
    do_status() {
      local pm binary col declared_count lock_state

      printf '\n  %spm%s         %sbinary%s                  %sdeclared%s  %slock%s\n' \
        "$C_B" "$C_0" "$C_D" "$C_0" "$C_D" "$C_0" "$C_D" "$C_0"

      for pm in $PM_ORDER; do
        binary="''${PM_BINARY[$pm]}"
        declared_count="$(count_lines "$(declared_of "$pm")")"

        if command -v "$binary" >/dev/null 2>&1; then
          col="$C_G"
          binary="$binary@$(command -v "$binary")"
          if [ -e "''${PM_LOCK[$pm]}" ]; then
            lock_state="$C_Y held$C_0"
          else
            lock_state="free"
          fi
        else
          col="$C_D"
          binary="(not found)"
          lock_state="$C_D-$C_0"
        fi

        printf '    %s%-9s%s %-24s %8s  %s\n' \
          "$col" "$pm" "$C_0" \
          "$binary" \
          "$declared_count" \
          "$lock_state"
      done
      printf '\n'
    }

    # -------------------------------------------------------------------
    # 入口
    # -------------------------------------------------------------------
    cmd="''${1:-diff}"

    # app ラッパーは第1引数にコマンド名を固定するため、
    # `nix run .#diff -- --help` のように後ろに付いたフラグも受け取る
    for arg in "$@"; do
      case "$arg" in
        -h | --help | help)
          usage
          exit 0
          ;;
      esac
    done

    case "$cmd" in
      diff | apply | update | status)
        ;;
      -h | --help | help)
        usage
        exit 0
        ;;
      *)
        printf '  %sunknown command%s: %s\n\n' "$C_R" "$C_0" "$cmd" >&2
        usage >&2
        exit 2
        ;;
    esac

    if ! pm="$(detect_pm)"; then
      printf '  %s%s を確認できるパッケージマネージャーがありません%s\n' \
        "$C_R" "$PM_ORDER" "$C_0" >&2
      exit 1
    fi

    printf '  %s%s · %s · %s%s\n' "$C_D" "$cmd" "$(host_id)" "''${PM_LABEL[$pm]}" "$C_0"

    case "$cmd" in
      diff) do_diff "$pm" ;;
      apply) do_apply "$pm" ;;
      update) do_update "$pm" ;;
      status) do_status "$pm" ;;
    esac
''
