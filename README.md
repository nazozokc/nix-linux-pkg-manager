# linux-pkgmanager.nix

Nix を宣言の入口として、**ネイティブの**パッケージマネージャー経由で
Linux パッケージを導入する。パッケージ自体を Nix store には置かない。

```nix
# packages/pacman.nix
[
  "man-db"
  "bash-completion"
]
```

これを `nix run` すると、`pacman` が何済みで何が足りないかを報告し、
`apply` で不足分だけ導入する。

宣言を 1 つも書きたくないときは `adopt` が雛形を出す。

```console
$ nix run .#adopt > packages/pacman.nix
```

## 対応 pm

| pm     | 実行ファイル | 不足判定                         |
| ------ | ------------ | -------------------------------- |
| pacman | `pacman`     | `pacman -T`（不足名を出力）      |
| apt    | `apt-get`    | `apt-get install --simulate`     |
| dnf    | `dnf`        | `rpm -q`（充足名を出力して反転） |
| zypper | `zypper`     | `rpm -q`                         |
| yum    | `yum`        | `rpm -q`                         |

ホストに 1 つでも見つかれば、その pm だけを使う。
`status` は 5 つ全部を一覧する。

## 使い方

```console
$ nix run .              # diff と同じ
$ nix run .#diff         # 宣言と導入済みを比較 (副作用なし)
$ nix run .#adopt        # 明示導入済みを宣言の雛形として出す (副作用なし)
$ nix run .#apply        # 不足分だけ導入する
$ nix run .#update       # pm を更新してから不足分を補う
$ nix run .#status       # 検出した pm と宣言の件数
```

`diff` と `status` は pm を一切変更しない。`apply` / `update` だけが
`sudo` を使う。`adopt` も pm を変更しない（**ファイルも書かない**）。
出力は標準出力、人が読む行と注意はすべて標準エラーへ出る。

### adopt

宣言をゼロから書く必要をなくす。既に入っているパッケージを、宣言の雛形として
標準出力に出す。`> packages/<pm>.nix` でそのままリダイレクトできる。

```console
$ nix run .#adopt > packages/apt.nix

  注意  packages/apt.nix には既に 3 件の宣言があります。
        adopt は導入済み全部を出します。上書きせず、既存宣言と共通する名前を
        消してから使ってください
```

出るのは「その pm で明示導入済み」のスナップショットで、既存宣言への差分では
ない。だから既存宣言を消してから使う形は取らない。

```console
$ nix run .#adopt

  # packages/apt.nix — apt で導入するパッケージ
  #
  # 明示導入済みパッケージをそのまま列挙しています。
  #   - ここに書くのは「システムのリソース」だけ。
  #   - 依存として入ったものは含みません。
  #   - Nix (home-manager の home.packages) 経由で入れる。ここには書かない。
  #   - 照合は `apt-get install --simulate` で行います。
  [
    "bat"
    "man-db"
  ]
```

- pm が検出しなかったものは出さない（5 pm 全部が Garett になるわけではない）
- 宣言検査が却下する名前は除外し、stderr に列挙する
  （pm の出力をそのまま宣言にすると、**評価時に落ちる宣言**を自分で作ってしまう）
- 照会が失敗したら偽の空リストは出さず、終了コード 2 で止まる
  （空の `[ ]` は「導入済み 0 件」という宣言になり、`diff` が常に「不足なし」になる）

### 出る情報

```console
$ nix run .#diff

  diff · arch · pacman

  host     arch (pacman) · 2 宣言

  installed   0
  missing     2
    - bash-completion
    - man-db
  unmanaged  11  宣言に無いが明示導入済み
    - base
    - base-devel
    ...
```

- `missing` … 宣言にあるが未導入。`apply` が入れる
- `unmanaged` … 明示導入済みだが宣言に無い。**報告のみ**、何も起きない

## 宣言の書き方

`packages/<pm>.nix` に素のリストを書くだけ。パッケージ名は、その pm が
受理する名前で書く。同じ用途でも pm をまたぐと名前が違うことがある。
消費側の flake から使うときも、このファイルを `declared` に渡す形になる
（[他の flake から使う](#他の-flake-から使う)）。

| 用途     | pacman            | apt               | dnf               | zypper / yum      |
| -------- | ----------------- | ----------------- | ----------------- | ----------------- |
| man page | `man-db`          | `man-db`          | `man-pages`       | `man`             |
| 補完     | `bash-completion` | `bash-completion` | `bash-completion` | `bash-completion` |

### 書けない名前

パッケージ名は `英数字と . + - _ :` だけを使います。
空白や `$` / `;` / `\`` / glob 文字を含む名前は**評価時にエラー**になる。

```console
$ nix run .
error: nlp: declared.pacman (/nix/store/…-source/packages/pacman.nix) の宣言に
       pm が受理できないパッケージ名があります
       名前: "ripgrep; rm -rf /"
       使える文字: 英数字と . + - _ :
```

インラインで書いた場合は `declared.pacman` とだけ出るので、
どの pm のどの宣言が悪いのかがそのまま分かる。

黙って直さない。空白を含む名前は引数の区切りに裂け、宣言に無い名前を
黙って落とすと「不足なし」に見える。どちらも嘘になるので、黙って直すより落とす。

| 名前                        | 判定           |
| --------------------------- | -------------- |
| `gcc-c++` `python3.11`      | 受理           |
| `lib32-gtk3` `perl-Foo_bar` | 受理           |
| `a b` `ripgrep; rm -rf /`   | 評価時にエラー |
| `x$(id)` `x\`id\``          | 評価時にエラー |
| `*` `-rf` `foo\tbar`        | 評価時にエラー |

`nix run .` は `packages/<pm>.nix` の宣言を読み、`nlp` を組み立てる前に
この検査を通す。**コマンドを 1 度も実行する前に**落とす。

この規則は宣言検査と `adopt` で同じ定義を使う。`adopt` が pm の出力を
そのまま宣言へ書くと、`nix run .` が評価時に落ちるのは自分で作った
宣言が原因になってしまう。だから `adopt` 側でも却下される名前を外す。

宣言に**存在しない名前**(形は正しいが pm が持っていないもの)を混ぜた場合は
評価時に落ちないので、実行時に落とす。`nlp` は照合コマンドの終了コードと
stderr を pm ごとに判定し、答えが壊れていれば終了コード 2 で止まる。

```console
  apt: 照合コマンドが異常です (rc=100)
  宣言に実在しないパッケージ名があるか、pm が実行できない状態
    E: Unable to locate package opencode
```

pm ごとに 1 ファイルなので、対象をまたぐ宣言は素直に書ける。

## 他の flake から使う

このリポジトリは flake input として取り込み、消費側の flake で宣言する。
実行体はその評価で組み立てられる。導入そのものはホストの pm と `sudo` が要るので、
`nix build` や評価の途中では走らない。`nix run .#nlp-apply` が、その flake の宣言で動く。

### flake-parts

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";

    linux-pkgmanager.nix = {
      url = "github:nazozokc/linux-pkgmanager.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.linux-pkgmanager.nix.flakeModules.default ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      # 宣言は flake の設定。packages/*.nix を消費側に置かない
      nlp.declared = {
        # 1 pm = 1 ファイルに分けるときは、パスをそのまま書く。
        # このリポジトリ自身の packages/<pm>.nix と同じ形
        pacman = ./packages/pacman.nix;
        apt = [
          "man-db"
          "bat"
        ];
      };
    };
}
```

`declared` の値はリストでもパスでもよい。パスは評価時に `import` され、
中身がリストでなければ評価時に落ちる。混在も許す（pm ごとに 1 つの値）。

```nix
{
  # packages/pacman.nix
  [
    "man-db"
    "bash-completion"
  ]
}
```

このツールが出すのは実行体だけ。いつ動かすかは消費側の config が決める。
評価しただけではホストの pm は動かない。

```nix
# たとえば自分の flake で switch という名前に載せる。名前はユーザー側の都合。
apps.switch = config.apps.nlp-apply;
```

```console
$ nix run .#nlp-diff     # 宣言と導入済みを比較 (副作用なし)
$ nix run .#nlp-adopt    # 明示導入済みを宣言の雛形として出す (副作用なし)
$ nix run .#nlp-apply    # 不足分だけ導入する
$ nix run .#nlp-update   # pm を更新してから不足分を補う
$ nix run .#nlp-status   # 検出した pm と宣言の件数
```

`nlp-` は消費側がもともと持っている `apps.diff` を潰さないための接頭辞。
空にしたいときは `nlp.appPrefix = ""`。`nix run .` を diff にしたいときは
`nlp.defaultApp = "diff"`。

`declared` は部分指定でよい。書いた pm だけを使い、書かなかった pm は
空リスト（`diff` は「宣言なし」と表示）になる。

### home-manager

home-manager には `flakeModules.home-manager` を置く。出るのは
`home.packages` に載る nlp だけで、apps は出さない。

```nix
{
  imports = [ inputs.linux-pkgmanager.nix.flakeModules.home-manager ];

  programs.nlp = {
    enable = true;
    declared.pacman = ./packages/pacman.nix;
  };
}
```

```console
$ home-manager switch   # nlp が PATH に入るだけ
$ nlp diff              # 宣言と導入済みを比較 (副作用なし)
$ nlp adopt             # 明示導入済みを宣言の雛形として出す (副作用なし)
$ nlp apply             # 不足分だけ導入する (switch のあと手動)
```

`enable` を `false` にすると `home.packages` に入らない。`apply` / `update` は
`sudo` が要るので **activation では走らせない。** パスワード入力を
activation に挟むと、非対話の `switch` や CI で必ず詰まる。
運用は「switch のあとに `nlp apply`」で固定する。

`flakeModules.default` と `flakeModules.home-manager` はどちらも `imports` に置く
ものだが、同じ config に 2 つ入れてはならない。どちらか 1 つを選ぶ。

### flake-parts を使わない場合

`lib.mkApps` が実行体と app 一式を返す。宣言の検査は同じものを通る。

```nix
outputs =
  { nixpkgs, linux-pkgmanager.nix, ... }:
  let
    systems = [ "x86_64-linux" ];
    each = system:
      linux-pkgmanager.nix.lib.mkApps {
        pkgs = nixpkgs.legacyPackages.${system};
        declared.pacman = [
          "man-db"
          "bash-completion"
        ];
      };
  in
  {
    packages = nixpkgs.lib.genAttrs systems (system: {
      nlp = (each system).package;
    });
    apps = nixpkgs.lib.genAttrs systems (system: (each system).apps);
  };
```

実行体だけ欲しいときは、これまで通り `lib.mkNlp` が derivation を返す。

宣言に**存在しない名前**を1つ混ぜると、pm が異常終了して照合結果が空に
なる。`nlp` は stderr の `E:` / `error:` を検出して終了コード 2 で止まる
ので、黙って「不足なし」には見えない。同じ理由で、未知の pm 名と
リストでない宣言も評価時に落とす。

### なぜ input 属性ではなく option なのか

flake の input に置けるのは `url` / `follows` / `inputs` だけ。`declared` を
input に書くと弾かれる。

```console
$ nix eval .
error: flake input attribute 'declared' is a thunk while a string,
Boolean, or integer is expected
```

宣言は「値」なので input には載せず、flake の option（または `lib.mkApps` の引数）
として渡す。

公開しているもの:

| output                      | 内容                                                                                |
| --------------------------- | ----------------------------------------------------------------------------------- |
| `flakeModules.default`      | flake-parts モジュール。`nlp.declared` から apps を出す                             |
| `flakeModules.home-manager` | home-manager モジュール。`programs.nlp.declared` から `home.packages` へ nlp を出す |
| `lib.mkApps`                | 宣言から `{ package, apps }` を返す関数                                             |
| `lib.mkNlp`                 | 宣言を受け取って nlp の derivation を返す関数                                       |
| `lib.pms`                   | 対応している pm 名の一覧                                                            |
| `lib.backends`              | pm ごとのコマンド定義（純データ）                                                   |
| `lib.validate`              | 宣言を検査して、通らなければ throw する関数                                         |
| `lib.check`                 | 検査だけする。問題を文字列のリストで返す                                            |
| `packages.<system>.nlp`     | その flake の宣言で組んだ nlp                                                       |
| `apps.<system>.*`           | `diff` / `adopt` / `apply` / `update` / `status`                                    |

このリポジトリ自身の `apps` は接頭辞なし（`nix run .#diff`）。
消費側のモジュールは既定で `nlp-diff` のように接頭辞を付ける。

## 削除をしない理由

apt / dnf / yum / zypper の `autoremove` は、このツールが把握していない
`.packages` まで巻き込んで消す。宣言から外したパッケージが
`autoremove` の対象になると、意図していないものが消える。

だから **削除系のコマンドは一切持たない。**
宣言から外したパッケージは `unmanaged` に現れるので、放置するかどうかは
自分で決める。

## 開発

```console
$ nix flake check --all-systems   # 5 pm すべての経路を検証
$ nix fmt                          # nixfmt / shfmt / statix / deadnix / prettier
```

4 層で守る。

| check               | 何を見る                                                                   |
| ------------------- | -------------------------------------------------------------------------- |
| `checks.eval`       | 宣言の検査が実際に落ちるかを、受理・却下ケースで固定する                   |
| `checks.shellcheck` | 連結前の `nix/lib/script/*.sh` を lint する                                |
| `checks.fake-path`  | 5 pm すべてのコマンド生成と差分計算を、PATH 差し替えで実測する             |
| `checks.consumer`   | 公開 API を入力に載せた消費側 flake を実際に評価して、出た apps を起動する |

`checks.fake-path` は `tests/fake-path/` のスタブで pm コマンドを差し替える。
ホストに 1 つしかない pm でも、apt / dnf / zypper / yum の経路まで通せる
(パッケージの実際の導入・更新は行わない。`sudo` も呼ばない)。

さらに検査を意図的に飛ばした nlp も作らせ、`$(touch PWNED)` のような宣言から
コマンドが実行されないことを測っている。宣言検査が 1 枚落としても
実行されないことを固定するため。

`checks.consumer` は `tests/consumer/module.nix` を入力に載せた消費側 flake
として評価する。`lib.evalModules` で再現すると `perSystem` の型と
`apps` / `packages` の転置を自分で作ることになり、公開 API の経路とは
別のものを作ってしまう。生成された `nlp-diff` の実物はビルドして起動し、
pm 未検出で止まることまで見る。

設計の詳細は [DESIGN.md](./DESIGN.md) を参照。

### CI

`.github/workflows/ci.yaml` は matrix を flake から組み立てる。
`githubActions` output が唯一の出典で、workflow には check 名を書かない。

```console
$ nix eval --json .#githubActions.matrix.include | jq '.[0]'
{
  "attr": "checks.aarch64-linux.\"consumer\"",
  "name": "consumer",
  "os": [
    "ubuntu-24.04-arm"
  ],
  "system": "aarch64-linux"
}
```

- `nix-github-actions` の `mkGithubMatrix` が check 名と runner を pairing する
- `attrPrefix = "checks"` なので `checks.<system>.<name>` をそのまま使う
- 対象は `x86_64-linux` と `aarch64-linux`
- `treefmt` も含め、matrix は check × system の組で埋まる（5 × 2 = 10）

`attr` には `-` を含む名前が引用符つきで入る（`fake-path` → `"fake-path"`）。
workflow では env 経由で渡して、shell の引用規則に依存させないようにしている。

check を 1 つ足したときは matrix が自動で増える。workflow を編集しなくてよい。

`.github/dependabot.yml` で nixpkgs は日次、GitHub Actions は週次で更新する。
nixpkgs を上げた途端に全部赤にならないよう、依存ごとにグループを割って
1 PR にまとめる。
