# nix/flake-parts/checks.nix
# checks.fake-path — 5 pm すべての経路を、1台の Arch 上で検証する
#
# ホストに apt / dnf / zypper / yum は無いので、これらは実機では絶対に
# テストできない。PATH を差し替えてスタブを解決させることで、
# 生成されるコマンドと差分計算だけを検証する。
# (パッケージの実際の導入・更新は行わない。sudo も呼ばない)
{ backends, declared, ... }:
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

      # mkDerivation ではなく runCommand を使う。
      # stdenv では checkPhase が installPhase より先に走るため、
      # installPhase で作ったディレクトリを cd できない
      harness =
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
              # shebang を nixpkgs 提供的実装へ差し替える。
              # stub は POSIX sh として書いているので bash で走らせても問題ない
              sed -i "1s|^#!.*|#!${pkgs.bash}/bin/bash|" src/run src/stub

              cd src

                # harness は nlp を呼ぶたびにスタブだけの PATH を組み立てるので、
                # ここでは harness 自身が必要とする mktemp / grep だけ用意する。
                # nlp は writeShellApplication が自前で PATH を作るので
                # ここに含める必要は無い
                PATH="${pkgs.coreutils}/bin:${pkgs.gnugrep}/bin:$PATH" \
                  NLP=${nlp}/bin/nlp \
                  ./run

                touch $out
          '';
    in
    {
      checks.fake-path = harness;
    };
}
