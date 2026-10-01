# nix-linux-pkg-manager 設計

nix で Linux のパッケージマネージャー (pacman / apt / dnf / zypper / yum) を
宣言的に管理する。パッケージ自体は各 pm が持つものを使い、Nix は宣言と実行だけを担う。

- このリポジトリの宣言: `packages/<pm>.nix`
- 消費側の宣言: flake の `nlp.declared`（`flakeModules.default`）
- 実行: 評価では走らない。消費側は `nix run .#switch` した瞬間だけ反映する
  （見るだけなら `.#nlp-diff`。このリポジトリ自身は `.#diff` / `.#apply` も残す）

## ファイル構成

```
flake.nix               配線のみ (inputs / systems / imports / 宣言の検査)

packages/<pm>.nix       pm ごとの宣言 (素のリスト)

nix/lib/backends.nix    5 pm の純粋データ定義
nix/lib/declared.nix    宣言の検査 (問題を文字列のリストで返す + throw)
nix/lib/render.nix      ソース連結 + bash の単一引用符リテラル生成
nix/lib/nlp.nix         実行体 nlp の定義 (apps / checks が共有)
nix/lib/mk-nlp.nix      他 flake 向けの公開ラッパ (derivation だけ)
nix/lib/mk-apps.nix     他 flake 向けの公開ラッパ (package + apps)
nix/lib/apps.nix        実行体から app ラッパーを作る

nix/flake-module.nix    消費側が import する flake-parts モジュール

nix/lib/script/         実行体の中身。1 ファイル 1 責務
  10-runtime.sh           set / 色 / trap / 小さな道具
  20-registry.sh          backend 定義と宣言の器 (nix が埋め込む)
  30-query.sh             宣言と導入済みの照合
  40-detect.sh            ホスト判定
  50-report.sh            出力整形
  60-commands.sh          diff / apply / update / status
  90-main.sh              引数解釈と入口

nix/flake-parts/
  checks.nix             eval / shellcheck / fake-path
  treefmt.nix

tests/eval/cases.nix    宣言検査の受理・却下ケース (Nix の式)
tests/fake-path/        スタブ実行ファイル + ハーネス
```

`packages/<pm>.nix` は素のリスト。

```nix
[
  "ripgrep"
  "jq"
]
```

## 責務の境界

3 層に分ける。層をまたいでロジックを書かない。

| 層              | 場所                   | 何を置くか                                              |
| --------------- | ---------------------- | ------------------------------------------------------- |
| 宣言 (評価時)   | `nix/lib/declared.nix` | 形の検査。エラーは文言まで揃える                        |
| backend 定義    | `nix/lib/backends.nix` | コマンド文字列と判定規則。**ロジックを 1 行も書かない** |
| 実行体 (実行時) | `nix/lib/script/*.sh`  | 照合・表示・権限。**pm 名を一切書かない**               |

この分離が実際に効いた場面:

- pm を足すのは `backends.nix` への 1 エントリ追加だけで済む。
  script 側に `if [ "$pm" = ... ]` を書かないので、pm を増やしても
  実行体の分岐が増えない。
- 宣言検査は「宣言が書けない状態」をビルド前に落とす。実行体の相談に
  ならないので、実行時のエラーメッセージが短くて済む。

## 消費側の配線

flake の input に置けるのは url / follows / inputs だけなので、宣言は input に書けない。
消費側は `flakeModules.default` を import し、`nlp.declared` にリストを書く。
モジュールは評価時に `packages.nlp` と `apps.nlp-*` を出す。

このリポジトリ自身も同じモジュールを通す。`nlp.appPrefix = ""` と
`nlp.defaultApp = "diff"` だけ消費側と違い、`nix run .#diff` を維持する。

導入はホストの pm と sudo が要る。評価や `nix build` では走らせない。
走らせる入口は、宣言を焼き込んだ app だけ。

## 生成方法

`render.nix` は 2 つの仕事だけをする。

1. `nix/lib/script/*.sh` を順番に連結する
2. `@@REGISTRY@@` を backend 定義と宣言で埋める

埋め込みは**必ず bash の単一引用符リテラル**にする。

```bash
DECLARED[pacman]='man-db
bash-completion'
```

単一引用符の中では変数展開もコマンド置換も起きない。宣言に `$` や
空白や改行が混ざっても「値」として保たれる。

## 検査

`nix/lib/declared.nix` は `problems` / `check` / `validate` の 3 つを返す。

- `problems` … 問題を文字列のリストで返すだけ。throw しない
- `check` … `{ ok, errors, normalized }`
- `validate` … 問題をまとめて throw する

検査と throw を分けた理由は 2 つ。

- Nix 2.35 の `builtins.tryEval` は throw したときのメッセージを読めない。
  `r.value` を触ると同じ例外が再送出される。検査を純関数にしておけば
  テストは Nix 式の中で文言まで比較できる。
- 問題を全部集めてから throw できるので、最初の 1 件で止まらない。

受理するパッケージ名の形は `^[A-Za-z0-9][A-Za-z0-9+._:-]*$`。

```nix
# 受理: gcc-c++ python3.11 lib32-gtk3 nvidia-550xx-dkms java-17-openjdk
# 却下: "a b" "$(id)" "ripgrep; rm -rf /" "*" "-rf" "x`id`"
```

空白を含む名前は IFS で分割された時点で複数の引数に裂け、宣言件数も照合結果も
嘘になる。だから評価時に落とす。

**Nix の遅延評価には注意が必要。** attrset を返しただけでは中身が未評価で、
中の `throw` が 1 度も走らない。宣言が 1 個だけ悪いと `lib.unique` も比較を
省略するので (内側が空になり)、特に危険。`validate` は最後に
`builtins.deepSeq` を通してから返す。

## 実行体

`nix/lib/script/*.sh` を連結したものが 1 本のスクリプトになる。
`writeShellApplication` がシェバングを足し、`shellcheck` を通してからビルドする。

- `eval` は**どこにも書かない**。文字列を組み立てて shell に評価させる経路が
  1 つでも残ると、そこが任意コマンド実行になる
- 宣言から pm への引数は、空白区切りの文字列に畳まず**改行で切って argv にする**。
  `mapfile -d '' -t arr < <(lines_to_argv "$text")` を使う
- `set -euo pipefail` / `set -f` / `LC_ALL=C` を最初に入れる
- `@@REGISTRY@@` の配列はファイル境界をまたいで使われる。単体 lint では
  SC2034 (未使用) に見えるので `20-registry.sh` 側で黙っている

## backend 定義

5 pm の差分は「明示導入済み一覧の出し方」「install 引数」「update の意味」
「不足判定コマンド」「答えの解釈」だけで、照合エンジンは完全に共通。

| pm     | explicit                                  | missing                      | install                                      | update                            |
| ------ | ----------------------------------------- | ---------------------------- | -------------------------------------------- | --------------------------------- |
| pacman | `pacman -Qqe`                             | `pacman -T`                  | `pacman -S --needed --noconfirm`             | `pacman -Syu --noconfirm`         |
| apt    | `apt-mark showmanual`                     | `apt-get install --simulate` | `apt-get install -y --no-install-recommends` | `apt-get update` + `full-upgrade` |
| dnf    | `dnf list -C --installed --userinstalled` | `dnf list -C --installed`    | `dnf install -y`                             | `dnf upgrade -y`                  |
| zypper | `rpm -qa --userinstalled`                 | `rpm -q`                     | `zypper --non-interactive install -y`        | `zypper --non-interactive up`     |
| yum    | `rpm -qa`                                 | `rpm -q`                     | `yum install -y`                             | `yum update -y`                   |

`apt-get install --simulate` は「導入済みなら Already newest、無いなら Installed」
を出力するので、その行の有無で判定する。`dnf` は `-C` で metadata 更新を避ける。
yum の明示導入判定に `userinstalled` を使わないのは、RHEL 7 の yum には無い option。

### 答えの解釈

不足判定コマンドは backend ごとに終了コードと stderr の癖が違う。
`okCodes` と `error` の 2 つで判定する。

| pm     | `okCodes` | `error` の例                            |
| ------ | --------- | --------------------------------------- |
| pacman | `0 127`   | `could not\|failed\|error: (?!package)` |
| apt    | `0`       | `^E: `                                  |
| rpm 系 | `0 1`     | `^(error\|not installed\|No such file)` |

`okCodes` を見ないと、不足が 1 つあるだけで pacman (127) や rpm (1) が
異常終了と誤判定され、照合結果が全部落ちる。

`error` を「`error:` が全部」で書くと逆に壊れる。pacman は不足があるだけで
`error: package 'x' was not found` を stderr に出すので、そのまますると
不足があるだけで全景が落ち、「不足なし」に見えてしまう。

`missingOf` が答えを壊者と判断したときは終了コード 2 で止める。
この判定が無いと、宣言に存在しない名前が 1 つ混ざっただけで apt が `E:` を
出して異常終了し、`Inst` 行が 1 行も出ないまま「不足なし」になる (偽陰性)。

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
パスワード入力を 1 回にまとめる。`sudo` が無い環境では、`touch` 等の副次効果を
起こさず終了する。

## 検証

3 層で守る。

| check               | 何を見る                                                     |
| ------------------- | ------------------------------------------------------------ |
| `checks.eval`       | 宣言検査が本当に落ちるか。受理・却下ケースを文言ごと比較する |
| `checks.shellcheck` | 連結前のソースをファイル単位で lint                          |
| `checks.fake-path`  | 5 pm すべてのコマンド生成と照合を、PATH 差し替えで実測する   |

`checks.fake-path` は `tests/fake-path/` のスタブで pm コマンドを差し替える。
ホストは Arch なので apt / dnf / zypper / yum は実機検証できないが、
PATH を差し替えれば 1 台の Arch 上で 5 pm すべての経路を通せる
(パッケージの実際の導入・更新は行わない)。

さらに `checks.fake-path` には **hostile 版 nlp** も渡す。宣言検査を
意図的に飛ばして作った nlp で、`$(touch PWNED)` や `x; touch PWNED` や
空白を含む名前を含む宣言からコマンド実行が起きないことを測る。
検査を 1 枚落としても実行されないこと (2 枚目の防御) を固定する。
