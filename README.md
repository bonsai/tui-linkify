# tui-linkify

ターミナルに出てくる**フルパスとベア URL を OSC 8 リンクに変える PTY プロキシ**。
アプリ側（pi / opencode / その他）は無改造で、間に挟むだけで「URL と同じようにクリックできる」状態にする。

```
bun tui-linkify.ts -- <cmd> [args...]
```

`<cmd>` を PTY 上で起動し、stdout を横取りしてリンクを注入してから画面へ出す。表示テキストは元のまま、クリック先だけ URI になる。

## 対応する表記

| 出力 | リンク先 |
|---|---|
| `/home/USER/x.md:12:3` | `file://wsl.localhost/<distro>/home/USER/x.md`（`:12:3` は表示のみ） |
| `~/.pi/agent/AGENTS.md` | `$HOME` 展開して同様 |
| `C:\Users\USER\x.txt` | `file:///C:/Users/USER/x.txt` |
| `\\wsl.localhost\Ubuntu-24.04\home\USER\x.md` | `file://wsl.localhost/Ubuntu-24.04/home/USER/x.md` |
| `https://example.com/a/b?c=1.` | 自身（末尾の `.` はリンク外へ） |
| アプリが既に出した OSC 8 | 変更しない（ネスト防止） |

- 誤リンク除去: `and/or`, `either/other`, `1/2` は **existsSync**（Windows/UNC は `/mnt/c/...`, `/...` に写像）で落とす。`TUI_LINKIFY_NOEXISTS=1` で無効化。
- チャンク分割対策: 末尾がパス途中なら 15ms ホールドして継続分と結合（TUI は改行なしで write するため必須）。`--hold ms` で調整。
- キー入力はバイト列のまま透過（日本語 IME の UTF-8 を壊さない）。
- 幅計算に影響しない（OSC 8 はゼロ幅）。出力が再描画されない TUI でも、リンクは毎 write 時に付く。

## 使い方

```sh
bun tui-linkify.ts -- pi
bun tui-linkify.ts -- opencode
bun tui-linkify.ts --host "" -- bash          # Linux 側ターミナル: file:///home/... にする
TUI_LINKIFY_DEBUG=1 bun tui-linkify.ts -- pi  # どのパスをリンクしたか stderr に出す
```

## インストール（shim を書く）

```sh
sh install.sh                                  # dry run（何を書くか表示）
sh install.sh --apply                          # WSL 側の shim + PATH 追記案を表示
sh install.sh --apply --windows --win-dir '<DIR>'   # Windows .cmd の雛形も表示（PATH は触らない）
```

| 起動経路 | 何で効かせるか |
|---|---|
| `pi` / `opencode`（対話シェル） | `~/.local/share/tui-linkify/bin/{pi,opencode}` を PATH 先頭に置く |
| `bash -c` / non-login | 同上（shim は bun を絶対パスで持つので PATH 依存なし） |
| `~/.local/bin/opencode` 等の既存ラッパー | shim がそれを **pin** して呼ぶ（二重プロキシにしない） |
| PowerShell ランチャー（`wsl -e bash -c`） | ランチャー内のコマンドを shim の絶対パスに変更 |
| Windows 版 opencode（`.cmd`） | `bun \\wsl.localhost\<distro>\...\tui-linkify.ts -- <real> %*` |
| herdr / tmux のペイン | 各ペインが shim を叩くので追加作業なし |

`~/.profile` の**末尾**（nvm/pnpm の前置より後）に 1 行:

```sh
export PATH="$HOME/.local/share/tui-linkify/bin:$PATH"
```

shim は自分自身を PATH から外してから `command -v` するため再帰しない。既存ファイルは上書きせず、内容が変わるときだけ書き換える（冪等）。

## 検証（実測）

- curses の全画面 TUI でパス 2 種がリンク化、チャンク分割（改行なし write）でもリンク化
- `~` 展開、`:line:col` の URI 除外、Windows パス、UNC、ベア URL、既存 OSC 8 の非ネスト
- 日本語 IME の UTF-8 往復（バイト列透過）
- shim 経由で `pi --version` → 0.87.1 / `opencode --version` → 1.18.32

未検証: クリック時の `file://` 解決（Windows Terminal → 既定アプリ）。既定は `file://wsl.localhost/<distro>/...`。Linux 側ターミナルなら `TUI_LINKIFY_HOST=` で `file:///home/...` にする。

## ライセンス

MIT
