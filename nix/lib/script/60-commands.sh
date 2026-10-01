# shellcheck shell=bash
# nix/lib/script/60-commands.sh — 4 つのサブコマンド
#
# 責務は「どのサブコマンドが何をするか」だけ。
# 照合は 30-query.sh、pm データは 20-registry.sh、整形は 50-report.sh。
#
# root 権限の扱い
#   ここが root 実行の唯一の場所。sudo がないときに素のコマンドへ
#   フォールバックしない。黙って非 root で入れるほうが事故になるため、
#   足りないならそのまま落とす

# パスワード入力を 1 回にまとめる。先に成否を確認してから本体に進む
sudo_prelude() {
  if ! command -v sudo >/dev/null 2>&1; then
    die "sudo が見つかりません。root で実行するコマンドには使えません" 1
  fi
  sudo -v || die "sudo の認証に失敗しました" 1
}

# root で 1 本のコマンドを実行する
run_root() { # <argv...>
  sudo "$@"
}

# install コマンドのテンプレートを argv に展開する (NUL 区切りで返す)。
# テンプレート中の @PKGS@ を、パッケージ名を並べた列に差し替える。
#
# 文字列として置換してから再度分割する実装は使わない。
# パッケージ名に空白や glob が混ざると引数がズレ、
# どこかで eval を使う羽目になれば任意コマンドが走るため、
# argv のまま組み立てて NUL 区切りで返す
install_argv() { # <template> <package>...
  local -a tmpl=()
  local token

  read -ra tmpl <<<"${1:-}"
  shift || true
  [ "${#tmpl[@]}" -gt 0 ] || return 1

  for token in "${tmpl[@]}"; do
    if [ "$token" = "@PKGS@" ]; then
      if [ "$#" -gt 0 ]; then
        printf '%s\0' "$@"
      fi
    else
      printf '%s\0' "$token"
    fi
  done
}

# 不足分を数えて表示する
print_counts() { # <missing> <installed> <unmanaged>
  local missing="$1" installed="$2" unmanaged="$3"

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

# 宣言と導入済みを比較する (副作用なし)
do_diff() { # <pm>
  local pm="$1"
  local missing unmanaged installed n_declared

  if [ -z "${DECLARED[$pm]}" ]; then
    printf '  %s%s は宣言なし%s (packages/%s.nix)\n' "$C_Y" "$pm" "$C_0" "$pm"
    return 0
  fi

  missing="$(missing_of "$pm")" || return 2
  unmanaged="$(comm -13 <(declared_of "$pm") <(explicit_of "$pm"))"
  n_declared="$(count_lines "$(declared_of "$pm")")"
  # 不足名は宣言の要素なので、宣言との交集を数える。
  # 単純に引き算すると、判定が壊れたときに負の installed が出る
  # installed = 宣言 - 不足 (集合差)。
  # 引き算ではなく集合差で数える。判定が壊れたときに負の installed が出ない
  installed="$(comm -23 <(declared_of "$pm") <(printf '%s\n' "$missing") | count_stdin)"

  printf '\n  %shost%s     %s (%s) %s· %s 宣言%s\n' "$C_B" "$C_0" "$(host_id)" \
    "${PM_LABEL[$pm]}" "$C_D" "$n_declared" "$C_0"
  printf '\n'
  print_counts "$missing" "$installed" "$unmanaged"
}

# 不足分を導入する
do_apply() { # <pm>
  local pm="$1" missing
  local -a argv=() names=()

  missing="$(missing_of "$pm")" || return 2

  if [ -z "$missing" ]; then
    printf '  %s不足なし%s (何もしません)\n' "$C_G" "$C_0"
    return 0
  fi

  # 不足名を「1 個 = 1 引数」で install の argv に組み立てる。
  # 空白区切りの文字列に畳むと空白を含む名前が裂ける
  mapfile -d '' -t names < <(lines_to_argv "$missing")
  mapfile -d '' -t argv < <(install_argv "${PM_INSTALL[$pm]}" ${names[@]+"${names[@]}"})
  if [ "${#argv[@]}" -eq 0 ]; then
    die "$pm の install コマンドを生成できません" 1
  fi

  printf '  %s導入%s\n' "$C_B" "$C_0"
  print_list 50 "$missing"
  print_cmd "${argv[@]}"

  sudo_prelude
  run_root "${argv[@]}"
}

# pm 自身を更新してから不足分を補う
#
# update は 1 コマンドずつ sudo を付ける。
# `&&` で 1 本に繋いで sudo を前置すると、2 本目以降が root でないまま走る
do_update() { # <pm>
  local pm="$1" line
  local -a argv=()

  sudo_prelude

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    read -ra argv <<<"$line"
    [ "${#argv[@]}" -gt 0 ] || continue
    printf '  %supdate%s  ' "$C_B" "$C_0"
    print_cmd "${argv[@]}"
    run_root "${argv[@]}"
  done <<<"${PM_UPDATE[$pm]}"

  printf '\n'
  do_apply "$pm"
}

# 検出結果と宣言の件数だけを報告する (副作用なし)
#
# binary 列は `pacman@/usr/bin/pacman` のようにパスが入るため、
# 列幅は表示前に実測して決める
do_status() { # <pm>
  local pm binary declared_count lock_state col w=8 i=0
  local -a binaries=() founds=()

  # 表示の前に binary 列の幅を決める。`pacman@/usr/bin/pacman` のように
  # パスが入るので、固定幅では pm によって桁がずれる
  for pm in "${PM_ORDER[@]}"; do
    if command -v "${PM_BINARY[$pm]}" >/dev/null 2>&1; then
      binaries+=("${PM_BINARY[$pm]}@$(command -v "${PM_BINARY[$pm]}")")
      founds+=("yes")
    else
      binaries+=("(not found)")
      founds+=("no")
    fi
    if [ "${#binaries[-1]}" -gt "$w" ]; then
      w="${#binaries[-1]}"
    fi
  done

  printf '\n  %spm%s       %sbinary%s%*s  %sdeclared%s  %slock%s\n' \
    "$C_B" "$C_0" "$C_D" "$C_0" $((w - 8)) "" "$C_D" "$C_0" "$C_D" "$C_0"

  for pm in "${PM_ORDER[@]}"; do
    binary="${binaries[$i]}"
    declared_count="$(count_lines "$(declared_of "$pm")")"

    if [ "${founds[$i]}" = "yes" ]; then
      col="$C_G"
      if [ -e "${PM_LOCK[$pm]}" ]; then
        lock_state="$C_Y held$C_0"
      else
        lock_state="free"
      fi
    else
      col="$C_D"
      lock_state="$C_D-$C_0"
    fi
    i=$((i + 1))

    printf '    %s%-9s%s %-*s %8s  %s\n' \
      "$col" "$pm" "$C_0" "$w" "$binary" "$declared_count" "$lock_state"
  done
  printf '\n'
}
