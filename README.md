# nix-linux-packages

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
$ nix run .#apply        # 不足分だけ導入する
$ nix run .#update       # pm を更新してから不足分を補う
$ nix run .#status       # 検出した pm と宣言の件数
```

`diff` と `status` は pm を一切変更しない。`apply` / `update` だけが
`sudo` を使う。

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

| 用途     | pacman            | apt               | dnf               | zypper / yum      |
| -------- | ----------------- | ----------------- | ----------------- | ----------------- |
| man page | `man-db`          | `man-db`          | `man-pages`       | `man`             |
| 補完     | `bash-completion` | `bash-completion` | `bash-completion` | `bash-completion` |

宣言に**存在しない名前**を1つ混ぜると、pm が異常終了して照合結果が空に
なる。`nlp` は stderr の `E:` / `error:` を検出して終了コード 2 で止まる
ので、黙って「不足なし」には見えない。

pm ごとに 1 ファイルなので、対象をまたぐ宣言は素直に書ける。

## 他の flake から使う

このリポジトリは flake input として取り込める。宣言は
`lib.mkNlp` に渡す。

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nix-linux-packages = {
      url = "github:nazozokc/nix-linux-packages";
      # 消費側の nixpkgs を使い回す (nixpkgs を二重に引かなくなる)
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, nix-linux-packages, ... }:
    let
      systems = [ "x86_64-linux" ];
    in {
      packages = nixpkgs.lib.genAttrs systems (
        system:
        {
          default = nix-linux-packages.lib.mkNlp {
            pkgs = nixpkgs.legacyPackages.${system};
            declared = {
              pacman = [
                "man-db"
                "bash-completion"
              ];
            };
          };
        }
      );
    };
}
```

`declared` は部分指定でよい。書いた pm だけを使い、書かなかった pm は
空リスト（`diff` は「宣言なし」と表示）になる。

宣言に**存在しない名前**を1つ混ぜると、pm が異常終了して照合結果が空に
なる。`nlp` は stderr の `E:` / `error:` を検出して終了コード 2 で止まる
ので、黙って「不足なし」には見えない。同じ理由で、未知の pm 名と
リストでない宣言も `mkNlp` が評価時に落とす。

```console
$ nix run .
```

### なぜ input 属性ではなく関数なのか

flake の input に置けるのは `url` / `follows` / `inputs` だけ。`declared` を
input に書くと弾かれる。

```console
$ nix eval .
error: flake input attribute 'declared' is a thunk while a string,
Boolean, or integer is expected
```

宣言は「値」であり input の位置づけに合わないので、`lib.mkNlp` として
公開する形にした。

公開しているもの:

| output                  | 内容                                           |
| ----------------------- | ---------------------------------------------- |
| `lib.mkNlp`             | 宣言を受け取って nlp の derivation を返す関数  |
| `lib.pms`               | 対応している pm 名の一覧                       |
| `lib.backends`          | pm ごとのコマンド定義（純データ）              |
| `packages.<system>.nlp` | このリポジトリの `packages/*.nix` で組んだ nlp |
| `apps.<system>.*`       | `diff` / `apply` / `update` / `status`         |

`apps` はこのリポジトリの宣言を焼き込んだものだから、消費側では
`lib.mkNlp` の derivation を直接 run する。

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

`checks.fake-path` は `tests/fake-path/` のスタブで pm コマンドを差し替え、
5 pm すべてのコマンド生成と差分計算だけを検証する。
1 台の Arch 上で apt / dnf / zypper / yum の経路まで通せる。

設計の詳細は [DESIGN.md](./DESIGN.md) を参照。
