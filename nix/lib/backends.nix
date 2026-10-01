# nix/lib/backends.nix
# 5 つのパッケージマネージャの定義。
#
# ここで持つのは「この pm で何をするか」の純粋データだけ。
# diff エンジン (nix/lib/render.nix) はこのデータ形状に依存しないので、
# 対応 pm を増やすときはここへ 1 エントリ足すだけで済む。
#
# フィールド
#   label          表示名
#   binary         存在判定に使う実行ファイル名
#   lock           排他ロックファイルのパス (status の表示用)
#   explicit       明示的に導入されたパッケージを1行1個で stdout に出すコマンド
#                  (依存として入ったものは含めない)
#   missingQuery   宣言パッケージのうち「不足しているもの」の判定に使うコマンド
#     cmd          実行ファイル名を @PKGS@ で宣言パッケージ列に置き換えて実行する
#                  (@PKGS@ は bash の glob 文字を含まない。%s を使うと
#                   ${var//%s/...} の pattern として「任意文字列」に解釈され崩れる)
#     output       "missing" = 不足名を出力する / "satisfied" = 充足名を出力する
#     extract      各行に適用する sed スクリプト。render.nix が `p` を付ける
#   install        @PKGS@ をパッケージ列に置換して実行する導入コマンド
#   update         1行ずつ sudo を付けて実行するコマンドのリスト
#
# remove / autoremove は意図的に持たない。
# apt / dnf / yum / zypper の autoremove は、
# このツールが把握していない.packagesまで巻き込んで消すため危険。
# 宣言から消えたパッケージは unmanaged として報告するだけに留める。
{
  # ---------------------------------------------------------------------------
  # pacman (Arch Linux)
  # ---------------------------------------------------------------------------
  pacman = {
    label = "pacman";
    binary = "pacman";
    lock = "/var/lib/pacman/db.lck";
    explicit = "pacman -Qqe";

    missingQuery = {
      # pacman -T は充足済みなら無出力 + rc=0、不足があれば不足名のみ stdout + rc=127。
      # 127 は異常終了なので `set -e` / `pipefail` 下では必ず `|| true` 相当で受けること。
      cmd = pkgs: "pacman -T ${pkgs}";
      output = "missing";
      extract = "s/$//"; # 出力そのものが不足名
    };

    install = pkgs: "pacman -S --needed --noconfirm ${pkgs}";
    update = [ "pacman -Syu --noconfirm" ];
  };

  # ---------------------------------------------------------------------------
  # apt (Debian / Ubuntu)
  # ---------------------------------------------------------------------------
  apt = {
    label = "apt";
    binary = "apt-get";
    lock = "/var/lib/dpkg/lock-frontend";
    explicit = "apt-mark showmanual";

    missingQuery = {
      # --simulate は root 不要。導入済みなら Inst 行を出さないので、
      # `^Inst ` 行がそのまま不足パッケージになる (virtual package / provides を解決する)。
      cmd = pkgs: "apt-get install --simulate --no-install-recommends -o Debug::NoLocking=1 ${pkgs}";
      output = "missing";
      extract = "s/^Inst \\([^ ]*\\).*/\\1/";
    };

    # `env` を挟むのは、sudo が先頭の環境変数割り当てを
    # コマンド名と解釈して "DEBIAN_FRONTEND=...: command not found" になるためです
    install =
      pkgs: "env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${pkgs}";

    # リスト表現なのは、`sudo` を各コマンドの先頭に付けるため。
    # 1つの文字列に `&&` で繋ぐと 2 個目以降が root のまま実行される
    update = [
      "apt-get update"
      "apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade"
    ];
  };

  # ---------------------------------------------------------------------------
  # dnf (Fedora / RHEL 9+)
  # ---------------------------------------------------------------------------
  dnf = {
    label = "dnf";
    binary = "dnf";
    lock = "/var/cache/dnf/metadata_lock.pid";
    explicit = ''rpm -qa --userinstalled --qf '%{NAME}\n' '';

    missingQuery = {
      # --qf '%{NAME}\n' は導入済みなら名前を、无ければ何も出さない。
      # NAME はアーキテクチャ接尾辞を含まないので宣言名とそのまま一致する。
      cmd = pkgs: ''rpm -q --qf '%{NAME}\n' ${pkgs}'';
      output = "satisfied";
      extract = "s/$//";
    };

    install = pkgs: "dnf install -y ${pkgs}";
    update = [ "dnf upgrade -y" ];
  };

  # ---------------------------------------------------------------------------
  # zypper (openSUSE)
  # ---------------------------------------------------------------------------
  zypper = {
    label = "zypper";
    binary = "zypper";
    lock = "/run/zypp.pid";
    explicit = ''rpm -qa --userinstalled --qf '%{NAME}\n' '';

    missingQuery = {
      cmd = pkgs: ''rpm -q --qf '%{NAME}\n' ${pkgs}'';
      output = "satisfied";
      extract = "s/$//";
    };

    install = pkgs: "zypper --non-interactive install -y ${pkgs}";
    update = [ "zypper --non-interactive update" ];
  };

  # ---------------------------------------------------------------------------
  # yum (RHEL 7 / CentOS 7)
  # ---------------------------------------------------------------------------
  yum = {
    label = "yum";
    binary = "yum";
    lock = "/var/run/yum.pid";
    # RHEL 7 系の rpm には userinstalled タグがないため、
    # 明示導入と依存導入を区別できない (= unmanaged に依存も混ざる)
    explicit = ''rpm -qa --qf '%{NAME}\n' '';

    missingQuery = {
      cmd = pkgs: ''rpm -q --qf '%{NAME}\n' ${pkgs}'';
      output = "satisfied";
      extract = "s/$//";
    };

    install = pkgs: "yum install -y ${pkgs}";
    update = [ "yum update -y" ];
  };
}
