# nix/flake-parts/checks.nix
# 壊れないための仕組み。3 つの層で守る。
#
#   checks.eval         宣言の検証 (nix/lib/declared.nix) を評価時に試す。
#                       評価時に落とす設計が本当に落ちるかを固定する
#   checks.shellcheck   生成前のソース (nix/lib/script/*.sh) を lint する。
#                       連結後の lint は writeShellApplication が担う
#   checks.fake-path    5 pm すべての経路を、1 台の Arch 上で検証する
#
# ホストに apt / dnf / zypper / yum は無いので、これらは実機では絶対に
# テストできない。PATH を差し替えてスタブを解決させることで、
# 生成されるコマンドと差分計算だけを検証する。
# (パッケージの実際の導入・更新は行わない。sudo も呼ばない)
{
  backends,
  check,
  declared,
  ...
}:
{
  perSystem =
    { lib, pkgs, ... }:
    let
      # apps.nix と必ず同じものを検査する
      nlp = import ../lib/nlp.nix {
        inherit
          backends
          declared
          lib
          pkgs
          ;
      };

      # 宣言の検証 (nix/lib/declared.nix) を意図的に飛ばして作った nlp。
      #
      # 宣言が「1 枚目の防御 (評価時に落とす)」を通り過ぎた場合でも、
      # 「2 枚目の防御 (単一引用符埋め込み + eval 不使用)」で
      # 実行が起きないことを tests/fake-path/run が実測する
      hostileNlp = import ../lib/nlp.nix {
        inherit
          backends
          lib
          pkgs
          ;
        # 宣言に意図的に悪い名前が入っているので、
        # shellcheck の SC2016 (単一引用符 = 展開されない) だけを黙らせる
        excludeShellChecks = [ "SC2016" ];
        declared = {
          # 宣言の検証を通らない名前だけを集める。
          # これらが「1 個の引数として」pm へ渡ることと、
          # コマンドとして実行されないことを確認する
          pacman = [
            "\$(touch PWNED)"
            "a b"
            "'quoted'"
            "x; touch PWNED"
            "*"
          ];
        };
      };

      # mkDerivation ではなく runCommand を使う。
      # stdenv では checkPhase が installPhase より先に走るため、
      # installPhase で作ったディレクトリを cd できない
      fakePathHarness =
        pkgs.runCommand "fake-path-harness"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.coreutils
              pkgs.gnugrep
            ];
          }
          ''
            cp -r ${../../tests/fake-path} src
            # store からコピーしたファイルは 444 なので書き換え権限を戻す
            chmod -R u+w src
            chmod +x src/stub src/run

              # サンドボックスには /usr/bin/env も /bin/sh も同じ名前では無いので、
              # shebang を nixpkgs の実装へ差し替える。
              # stub は POSIX sh として書いているので bash で走らせても問題ない
              sed -i "1s|^#!.*|#!${pkgs.bash}/bin/bash|" src/run src/stub

              cd src

                # harness は nlp を呼ぶたびにスタブだけの PATH を組み立てるので、
                # ここでは harness 自身が必要とする mktemp / grep だけ用意する。
                # nlp は writeShellApplication が自前で PATH を作るので
                # ここに含める必要は無い
                PATH="${pkgs.coreutils}/bin:${pkgs.gnugrep}/bin:$PATH" \
                  NLP=${nlp}/bin/nlp \
                  NLP_HOSTILE=${hostileNlp}/bin/nlp \
                  ./run

                touch $out
          '';

      # 生成前のソースを lint する。
      # 各ファイルは「1 つの責務だけを持つ」ので、連結後にしか
      # 気づけない「ファイル境界をまたぐ変数参照」を_sources_ で拾える
      shellcheck =
        pkgs.runCommand "script-shellcheck"
          {
            nativeBuildInputs = [
              pkgs.shellcheck
              pkgs.coreutils
            ];
          }
          ''
            cd ${../lib/script}
            shellcheck --severity=style *.sh
            echo "  shellcheck: $(ls *.sh | wc -l) ファイル" >&2
            echo ok > "$out"
          '';

      # 宣言の検証を評価時に試す。1 つでも通るはずのものが落ちたら失敗
      evalCheck =
        let
          cases = import ../../tests/eval/cases.nix {
            inherit check lib;
          };
        in
        pkgs.runCommand "declared-eval-check"
          {
            nativeBuildInputs = [
              pkgs.coreutils
            ];
            inherit (cases) report summary;
          }
          ''
            printf '%s\n' "$report" > report.txt
            printf '  %s\n' "$summary"
            if grep -q '^FAIL' report.txt; then
              cat report.txt >&2
              exit 1
            fi
            echo ok > "$out"
          '';
    in
    {
      checks = {
        eval = evalCheck;
        fake-path = fakePathHarness;
        inherit shellcheck;
      };
    };
}
