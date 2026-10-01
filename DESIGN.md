# nix-linux-packages 設計

nix で Linux のパッケージマネージャー (pacman / apt / dnf / zypper / yum) を
宣言的に管理する。パッケージ自体は各 pm が持つものを使い、Nix は宣言と実行だけを担う。

- 宣言: `packages/<pm>.nix`
- 実行: `nix run .#diff` / `.#apply` / `.#update` / `.#status`

## ファイル構成

```
flake.nix            配線のみ (inputs / systems / imports)
packages/pacman.nix  pacman の宣言
packages/apt.nix     apt の宣言
packages/dnf.nix     dnf の宣言
packages/zypper.nix  zypper の宣言
packages/yum.nix     yum の宣言
nix/lib/backends.nix 5 pm の純粋データ定義
nix/lib/render.nix   宣言 + backend -> bash 生成
nix/parts/apps.nix   apps.{default=diff, apply, update, status}
nix/parts/treefmt.nix
tests/fake-path/     スタブ実行ファイル + ハーネス
```

`packages/<pm>.nix` は素のリスト。

```nix
[
  "ripgrep"
  "jq"
]
```

## 設計判断

**宣言だけを Nix に載せ、状態照合は実行時スクリプトが担う。**
インストール済み一覧を Nix 側で読もうとすると `builtins.readFile` が必要になり
pure 評価が壊れる。宣言は pure、diff は bash。

**backend は純粋データ。**
5 pm の差分は「明示導入済み一覧の出し方」「install 引数」「update の意味」だけで、
diff エンジンは完全に共通。pm を増やすときの変更点は backend 1 エントリに閉じる。

**`missing` は「不足パッケージ名を出力するコマンド」として抽象化する。**

| pm     | explicit                                  | missing                      | install                                      | update                            |
| ------ | ----------------------------------------- | ---------------------------- | -------------------------------------------- | --------------------------------- |
| pacman | `pacman -Qqe`                             | `pacman -T`                  | `pacman -S --needed --noconfirm`             | `pacman -Syu --noconfirm`         |
| apt    | `apt-mark showmanual`                     | `apt-get install --simulate` | `apt-get install -y --no-install-recommends` | `apt-get update` + `full-upgrade` |
| dnf    | `dnf list -C --installed --userinstalled` | `dnf list -C --installed`    | `dnf install -y`                             | `dnf upgrade -y`                  |
| zypper | `rpm -qa --userinstalled`                 | `rpm -q`                     | `zypper --non-interactive install -y`        | `zypper --non-interactive up`     |
| yum    | `rpm -qa`                                 | `rpm -q`                     | `yum install -y`                             | `yum update -y`                   |

`apt-get install --simulate` は「導入済みなら Already newest、無いなら Installed」
を出力するので、その行の有無で判定する。`dnf` は `-C` で metadata 更新を避ける。

## コマンド

| app      | 副作用 | 内容                                                                      |
| -------- | ------ | ------------------------------------------------------------------------- |
| `diff`   | なし   | default。ホスト pm を検出し declared / installed / missing / 未宣言を表示 |
| `apply`  | あり   | missing を install                                                        |
| `update` | あり   | pm update を実行し、続けて missing を補充                                 |
| `status` | なし   | pm 検出結果・lock 保持・宣言件数                                          |

**削除はしない。** 宣言から消えたパッケージは報告のみ。apt / dnf / yum / zypper の
autoremove は他パッケージごと巻き込むため、`remove` コマンドは backend に持たせない。

## 権限

スクリプト内で `sudo` を呼ぶ。`apply` / `update` は先頭で `sudo -v` を実行し、
パスワード入力を 1 回にまとめる。

## 検証

ホストは Arch なので apt / dnf / zypper / yum は実機検証できない。

- `tests/fake-path/` に引数と呼び出し順を echo して終了するスタブ実行ファイルを置き、
  `--path` フラグで `PATH` を差し替えて 5 backend すべてのコマンド生成と diff ロジックを検証する
- `nix flake check --all-systems --no-build`
- `nix fmt -- --ci` / `statix check` / `deadnix --fail`
- pacman の実機確認: `.#diff` と `.#status` は副作用ゼロ

## スコープ外

- 第三者 apt リポジトリ / GPG キー
- AUR
- .deb / .rpm の URL 直指定
- バージョン固定、`ignore` / `hold`
- 宣言を CLI から書き換える `add` コマンド
