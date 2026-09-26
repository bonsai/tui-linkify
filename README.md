# tui-linkify

ターミナルに出てくる**フルパスとベア URL を OSC 8 リンクに変える PTY プロキシ**。
アプリ側（pi / opencode / その他）は無改造で、間に挟むだけで「URL と同じようにクリックできる」状態にする。

```
bun tui-linkify.ts -- <cmd> [args...]
```

`<cmd>` を PTY 上で起動し、stdout を横取りしてリンクを注入してから画面へ出す。表示テキストは元のまま、クリック先だけ URI になる。

クリック後は Windows 側の **`tui-linkify://` ハンドラ**が拡張子ごとの既定アプリへ振り分ける（`windows/apps.json`）。

## 対応する表記とリンク先

| 出力 | リンク先（既定 `--scheme tui-linkify`） |
|---|---|
| `/home/USER/x.md:12:3` | `tui-linkify://open?k=posix&p=%2Fhome%2FUSER%2Fx.md&d=<distro>`（`:12:3` は表示のみ、VS Code には `--goto` で渡る） |
| `~/.pi/agent/AGENTS.md` | `$HOME` 展開して同様 |
| `C:\Users\USER\x.txt` | `tui-linkify://open?k=win&p=C%3A%5CUsers%5CUSER%5Cx.txt` |
| `\\wsl.localhost\Ubuntu-24.04\home\USER\x.md` | `tui-linkify://open?k=unc&p=...` |
| `https://example.com/a/b?c=1.` | 自身（末尾の `.` はリンク外へ） |
| アプリが既に出した OSC 8 | 変更しない（ネスト防止） |

`--scheme file`（または `TUI_LINKIFY_SCHEME=file`）にすると `file://wsl.localhost/<distro>/...` を出す。この場合は Windows の既定アプリが直接使われ、下の表は効かない。

- 誤リンク除去: `and/or`, `either/other`, `1/2` は **existsSync**（Windows/UNC は `/mnt/c/...`, `/...` に写像）で落とす。`TUI_LINKIFY_NOEXISTS=1` で無効化。
- チャンク分割対策: 末尾がパス途中なら 15ms ホールドして継続分と結合（TUI は改行なしで write するため必須）。`--hold ms` で調整。
- キー入力はバイト列のまま透過（日本語 IME の UTF-8 を壊さない）。
- 幅計算に影響しない（OSC 8 はゼロ幅）。出力が再描画されない TUI でも、リンクは毎 write 時に付く。

## 使い方

```sh
bun tui-linkify.ts -- pi
bun tui-linkify.ts -- opencode
bun tui-linkify.ts --scheme file -- pi           # Windows 既定アプリに任せる
TUI_LINKIFY_DEBUG=1 bun tui-linkify.ts -- pi     # どのパスをリンクしたか stderr に出す
```

## インストール（WSL 側: shim）

```sh
sh install.sh                                  # dry run（何を書くか表示）
sh install.sh --apply                          # shim を書く（冪等・既存の非管理ファイルは触らない）
```

| 起動経路 | 何で効かせるか |
|---|---|
| `pi` / `opencode`（対話シェル） | `~/.local/share/tui-linkify/bin/{pi,opencode}` を PATH 先頭に |
| `bash -c` / non-login | 同上（shim は `bun` を絶対パスで持つ。非対話シェルは `~/.bashrc.d` を読まないため） |
| `~/.local/bin/opencode` 等の既存ラッパー | shim がそれを **pin** して呼ぶ（二重プロキシにしない） |
| herdr / tmux のペイン | 各ペインが shim を叩くので追加作業なし |

`~/.profile` の**末尾**（nvm/pnpm の前置より後）に 1 行:

```sh
export PATH="$HOME/.local/share/tui-linkify/bin:$PATH"
```

## インストール（Windows 側: `tui-linkify://` ハンドラ）

```sh
# dry run
powershell.exe -NoProfile -File "$(wslpath -w windows/install.ps1)" -DryRun
# 適用（HKCU のみ・管理者権限不要・冪等）
powershell.exe -NoProfile -File "$(wslpath -w windows/install.ps1)" -Apply
# 解除
powershell.exe -NoProfile -File "$(wslpath -w windows/install.ps1)" -Apply -Uninstall
```

- ハンドラ本体を `%USERPROFILE%\.local\bin\` にコピーし、`HKCU:\Software\Classes\tui-linkify` を作る。
- 拡張子→アプリの表は `%USERPROFILE%\.local\bin\apps.json`（`windows/apps.json` のコピー）を直接編集すれば反映される。

| 拡張子 | アプリ |
|---|---|
| `.md .txt .log .json .yaml .toml .ts .tsx .js .py .sh .ps1` ほか | VS Code（`:line:col` は `--goto`） |
| `.html .pdf .png .jpg .mp4 .csv` ほか | Windows 既定（`"default"` と書く） |
| ディレクトリ | `explorer.exe` |
| 表にない拡張子 | Windows 既定 |

## 検証（実測）

- curses の全画面 TUI でパス 2 種がリンク化、チャンク分割（改行なし write）でもリンク化
- `~` 展開、`:line:col` の URI 除外、Windows パス、UNC、ベア URL、既存 OSC 8 の非ネスト
- 日本語 IME の UTF-8 往復（バイト列透過）
- shim 経由で `pi --version` → 0.87.1 / `opencode --version` → 1.18.32（非対話 login shell, exit 0）
- **クリック経路**: `Start-Process 'tui-linkify://open?k=posix&p=...README.md'` → ハンドラのログに `app=vscode` が出て VS Code が起動（2026-09-26）

## ライセンス

MIT
