# tui-linkify

ターミナルに出てくる**フルパスとベア URL を OSC 8 リンクに変える PTY プロキシ**。
アプリ側（pi / opencode / その他）は無改造で、間に挟むだけで「URL と同じようにクリックできる」状態にする。

```
bun tui-linkify.ts -- <cmd> [args...]
```

`<cmd>` を PTY 上で起動し、stdout を横取りしてリンクを注入してから画面へ出す。表示テキストは元のまま、クリック先だけ URI になる。クリック後は Windows 側の **`tui-linkify://` ハンドラ**が拡張子ごとの既定アプリへ振り分ける。

- 対象: pi, opencode, Tmux/herdr のペイン, その他 PTY 上の任意の CLI
- 依存: `bun` のみ（Node/npm 不要）
- ライセンス: MIT

---

## 目次

1. [何が嬉しいか](#何が嬉しいか)
2. [対応する表記とリンク先](#対応する表記とリンク先)
3. [使い方（単体）](#使い方単体)
4. [インストール: WSL/Linux 側](#インストール-wsllinux-側)
5. [インストール: Windows 側（`tui-linkify://` ハンドラ）](#インストール-windows-側tui-linkify-ハンドラ)
6. [拡張子 → 既定アプリ表](#拡張子--既定アプリ表)
7. [全起動経路の配線一覧](#全起動経路の配線一覧)
8. [ランチャ（PowerShell）経由](#ランチャpowershell経由)
9. [Windows 版アプリから使う](#windows-版アプリから使う)
10. [検証済みの範囲](#検証済みの範囲)
11. [困ったとき](#困ったとき)
12. [アンインストール](#アンインストール)
13. [仕組み](#仕組み)
14. [リポジトリ構成](#リポジトリ構成)

---

## 何が嬉しいか

TUI（pi / opencode など）は、URL はターミナルがクリック可能にしてくれるが、**ファイルパスはただの文字列**のまま。長い絶対パスを目で追い、別のシェルで開く、という手間が残る。

tui-linkify を挟むと:

- `/home/sexy/tui-linkify/README.md` が**そのままクリックできる**
- クリック先は `README.md` を開くのに適したアプリ（VS Code / 既定ビューア / explorer など）
- `src/main.ts:42:7` のように行番号付きでも、**VS Code の `--goto` でその行に飛ぶ**
- 長い URL を画面に出さなくて済む（表示はパスのまま、URI は隠れる）

アプリの改修・再ビルドは不要。プロキシを 1 枚挟むだけ。

## 対応する表記とリンク先

既定（`--scheme tui-linkify`）:

| 出力例 | リンク先 |
|---|---|
| `/home/USER/x.md:12:3` | `tui-linkify://open?k=posix&p=%2Fhome%2FUSER%2Fx.md&d=<distro>` |
| `~/.pi/agent/AGENTS.md` | `$HOME` を展開して同様（表示は `~` のまま） |
| `C:\Users\USER\x.txt` | `tui-linkify://open?k=win&p=C%3A%5CUsers%5CUSER%5Cx.txt` |
| `\\wsl.localhost\Ubuntu-24.04\home\USER\x.md` | `tui-linkify://open?k=unc&p=...` |
| `https://example.com/a/b?c=1.` | 自身（末尾の `.` はリンクの外へ出す） |
| アプリが既に出した OSC 8 | 変更しない（ネストしない） |
| `and/or`, `either/other`, `1/2` | リンクしない（実在チェックで除外） |

`--scheme file`（または `TUI_LINKIFY_SCHEME=file`）にすると `file://wsl.localhost/<distro>/...` を出す。この場合は Windows の既定アプリが直接使われ、下の表は効かない。

- `:line:col` はリンク先 URI からは落とし、VS Code には `--goto <path>:<line>:<col>` として渡す。
- 実在チェック: `existsSync`（Windows パスは `/mnt/c/...`、UNC は `/...` に写像）。`TUI_LINKIFY_NOEXISTS=1` で無効化。
- チャンク分割: TUI は改行なしで write するため、末尾がパス途中なら 15ms 待って継続分と結合する（`--hold ms`）。
- 幅計算に影響しない（OSC 8 はゼロ幅）。差分再描画の TUI でもリンクは毎 write 時に付く。

## 使い方（単体）

```sh
bun tui-linkify.ts -- pi                         # pi をリンク対応で起動
bun tui-linkify.ts -- opencode                   # opencode をリンク対応で起動
bun tui-linkify.ts -- bash                       # 任意のシェル/CLI
bun tui-linkify.ts --scheme file -- pi           # file:// を出して Windows 既定アプリに任せる
bun tui-linkify.ts --host "" -- bash             # Linux 側ターミナル向け（file:///home/... ）
TUI_LINKIFY_DEBUG=1 bun tui-linkify.ts -- pi     # どのパスをリンクしたか stderr に出す
```

### オプション / 環境変数

| オプション | 環境変数 | 既定 | 意味 |
|---|---|---|---|
| `--scheme <name>` | `TUI_LINKIFY_SCHEME` | `tui-linkify` | `tui-linkify` or `file` |
| `--distro <name>` | `TUI_LINKIFY_DISTRO` | `$WSL_DISTRO_NAME` | `?d=` に載せるディストロ名 |
| `--host <authority>` | `TUI_LINKIFY_HOST` | `wsl.localhost/$WSL_DISTRO_NAME` | `--scheme file` のときの URI 権威。空文字で `file:///home/...` |
| `--hold <ms>` | — | `15` | パス途中で切れた write を待つ時間 |
| `--min-segments <n>` | — | `2` | リンクする最小のパス階層数 |
| `--no-exists` | `TUI_LINKIFY_NOEXISTS=1` | 実在チェックする | 実在チェックを無効化 |
| — | `TUI_LINKIFY_DEBUG=1` | 無効 | `link(...)` / `skip (missing)` を stderr に出す |

## インストール: WSL/Linux 側

### 1. shim を書く

```sh
sh install.sh                # dry run（何を書くか表示するだけ）
sh install.sh --apply        # shim を書く（冪等・既存の非管理ファイルは触らない）
```

書き込まれるもの:

| パス | 役割 |
|---|---|
| `~/.local/bin/tui-linkify` | 起動コマンド（`bun <entry> "$@"`） |
| `~/.local/share/tui-linkify/bin/pi` | `pi` をプロキシ経由で起動する shim |
| `~/.local/share/tui-linkify/bin/opencode` | `opencode` 用の shim |

- shim は `bun` を**絶対パス**で保持する。非対話シェルは `~/.bashrc.d` を読まないため `~/.bun/bin` が PATH に無い（実測で踏んだ罠）。
- 既存の `~/.local/bin/opencode`（自前のクォータ連動ラッパー等）は**上書きしない**。shim がそれを pin して呼ぶので、二重プロキシにも既存ロジックの破壊にもならない。
- shim は自分自身のディレクトリを PATH から外してから `command -v` するため再帰しない。

### 2. PATH に shim ディレクトリを先頭で入れる

`~/.profile` の**末尾**（nvm / pnpm / mise を前置した後）に 1 行:

```sh
export PATH="$HOME/.local/share/tui-linkify/bin:$PATH"
```

`~/.bashrc.d/*.sh` への追記では効かない（`.profile` が先に `.bashrc` を読み、その後で nvm/pnpm を前置するため）。`~/.local/bin` 自体を先頭にしないのは、そこに `node` / `npm` / `deno` / `uv` があり、他を隠してしまうから。

## インストール: Windows 側（`tui-linkify://` ハンドラ）

```sh
powershell.exe -NoProfile -File "$(wslpath -w windows/install.ps1)" -DryRun   # 計画表示
powershell.exe -NoProfile -File "$(wslpath -w windows/install.ps1)" -Apply    # 適用
powershell.exe -NoProfile -File "$(wslpath -w windows/install.ps1)" -Apply -Uninstall  # 解除
```

行われること:

1. `windows/tui-linkify-open.ps1` と `windows/apps.json` を `%USERPROFILE%\.local\bin\` にコピー
2. `HKCU:\Software\Classes\tui-linkify` を登録（**HKCU のみ・管理者権限不要**）

```
(default)      = URL:tui-linkify Protocol
URL Protocol   = (空)
shell\open\command\(default) =
  powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Users\<you>\.local\bin\tui-linkify-open.ps1" "%1"
```

3. ユーザー環境変数 `TUI_LINKIFY_DISTRO` を設定（`?d=` 無しのリンク用フォールバック）

手動テスト:

```sh
# どのアプリで開くかだけ確認
powershell.exe -NoProfile -File 'C:\Users\dance\.local\bin\tui-linkify-open.ps1' -DryRun 'tui-linkify://open?k=posix&p=%2Fhome%2Fsexy%2F.bashrc'

# 実際に開く（レジストリ経由の end-to-end）
powershell.exe -NoProfile -Command "Start-Process 'tui-linkify://open?k=posix&p=%2Fhome%2Fsexy%2Ftui-linkify%2FREADME.md&d=Ubuntu-24.04'"
```

ハンドラの動作ログ: `%TEMP%\tui-linkify-open.log`（`uri=... ext=... app=... -> command`）

## 拡張子 → 既定アプリ表

`windows/apps.json`（Windows 側では `%USERPROFILE%\.local\bin\apps.json`）:

```json
{
  "apps": {
    "vscode": "C:\\Users\\dance\\AppData\\Local\\Programs\\Microsoft VS Code\\Code.exe",
    "explorer": "C:\\Windows\\explorer.exe",
    "default": ""
  },
  "byExt": {
    ".md": "vscode",
    ".ts": "vscode",
    ".py": "vscode",
    ".html": "default",
    ".png": "default",
    ".mp4": "default",
    "dir": "explorer"
  }
}
```

- `byExt` の値は `apps` の名前、または実行ファイルの絶対パスを直接書いてもよい。
- `"default"`（= 空文字）は **Windows の既定アプリ**で開く。
- `dir` はディレクトリ用の特別キー。
- `byExt` に無い拡張子は Windows 既定。
- 表を編集したら Windows 側へ再コピーする:

```sh
powershell.exe -NoProfile -File "$(wslpath -w windows/install.ps1)" -Apply
```

既定の割り当て:

| 拡張子 | アプリ |
|---|---|
| `.md .markdown .txt .log .json .jsonl .yaml .yml .toml .ini .ts .tsx .js .mjs .py .go .rs .sh .ps1 .css` | VS Code（`:line:col` は `--goto`） |
| `.html .pdf .png .jpg .jpeg .gif .webp .svg .mp4 .webm .mkv .mp3 .wav .xlsx .docx .csv` | Windows 既定（`"default"`） |
| ディレクトリ | `explorer.exe` |

WSL パスはハンドラが `\\wsl.localhost\<distro>\home\...` に変換してからアプリへ渡す（VS Code も explorer も UNC を解釈できる）。

## 全起動経路の配線一覧

| 起動経路 | 何で効かせるか | 状態 |
|---|---|---|
| `pi` / `opencode`（対話シェル） | `~/.local/share/tui-linkify/bin` を PATH 先頭に | 自動（`install.sh --apply` + PATH 1 行） |
| `bash -c` / non-login | 同上（shim が `bun` を絶対パスで保持） | 自動 |
| `~/.local/bin/opencode` 等の既存ラッパー | shim が pin して呼ぶ | 自動 |
| herdr / tmux のペイン | 各ペインが shim を叩く | 追加作業なし |
| Windows PowerShell ランチャー（`wsl -e bash -c`） | ランチャー内のコマンドを shim の絶対パスに変更 | **適用済み**（`bonsai/opencode-launcher-win` の .ps1 / .cmd） |
| Windows 版 opencode（`.cmd`） | Windows 側 `.cmd` shim から `bun` で tui-linkify.ts を起動 | 下記 |

`wsl -e bash -c "opencode ..."` は **PATH を通らない**（非対話なので `~/.profile` も `~/.bashrc.d` も読まれない）。ランチャー側を絶対パスにする:

```
- wsl -e bash -c "opencode $($args -join ' ')"
+ wsl -e bash -c "/home/sexy/.local/share/tui-linkify/bin/opencode $($args -join ' ')"
```

## ランチャ（PowerShell）経由

`bonsai/opencode-launcher-win` は適用済み（`.ps1` / `.cmd` の WSL 分岐が shim の絶対パスを呼ぶ）。実測: `wsl -e bash -c ".../opencode --version"` → 1.18.32。

他ランチャーを足す場合は同じ形にする:

```powershell
# opencode-launcher.ps1（WSL 分岐）
wsl -e bash -c "/home/<user>/.local/share/tui-linkify/bin/opencode -s $Session"
```

- Windows 分岐（`C:\Users\<you>\.bun\bin\opencode.cmd`）を使うなら、Windows 側 `.cmd` shim も用意する:

```bat
@echo off
bun "\\wsl.localhost\Ubuntu-24.04\home\sexy\tui-linkify\tui-linkify.ts" -- "%USERPROFILE%\.bun\bin\opencode.cmd" %*
```

- Windows 側で `bun` が PATH に無い場合は絶対パス（例 `C:\Users\<you>\.bun\bin\bun.exe`）にする。
- Windows PATH は自動では触らない。shim を置いたディレクトリを自分で PATH に入れる。

## Windows 版アプリから使う

`tui-linkify.ts` は WSL 側にあるので、Windows の bun からは UNC で読む:

```powershell
bun "\\wsl.localhost\Ubuntu-24.04\home\sexy\tui-linkify\tui-linkify.ts" -- "C:\path\to\app.exe" args...
```

## 検証済みの範囲

| 項目 | 結果 |
|---|---|
| curses 全画面 TUI でパスがリンク化 | OK（2 種のパス） |
| 改行なし write（チャンク分割）でもリンク化 | OK（15ms ホールド） |
| `~` 展開 / `:line:col` の URI 除外 | OK |
| Windows パス / UNC / ベア URL | OK |
| アプリが既に出した OSC 8 をネストしない | OK |
| 日本語 IME の UTF-8 往復 | OK（バイト列透過。当初 `toString("binary")` で二重エンコードしていたのを修正） |
| 誤リンク除去（`and/or`, `1/2`） | OK（existsSync） |
| shim 経由 `pi --version` / `opencode --version` | 0.87.1 / 1.18.32（非対話 login shell, exit 0） |
| `tui-linkify://` 登録 → クリック相当の `Start-Process` | ハンドラログに `app=vscode`、VS Code 起動 |
| ディレクトリ → explorer / 未登録拡張子 → Windows 既定 | OK（dry-run で確認） |

未検証: 実際のマウスクリック（Windows Terminal 等）での体感確認。ハンドラ自体は `Start-Process` 経由で end-to-end 確認済み。

## 困ったとき

| 症状 | 原因と対処 |
|---|---|
| `tui-linkify: bun not found` | shim に埋め込んだ `bun` の絶対パスが古い。`install.sh --apply` を再実行 |
| リンクにならない | ターミナルが OSC 8 非対応（表示は壊れない）。Windows Terminal は対応。`TUI_LINKIFY_DEBUG=1` でリンク判定を確認 |
| クリックしても何も起きない | ハンドラ未登録。`windows/install.ps1 -Apply` と `%TEMP%\tui-linkify-open.log` を確認 |
| クリックで「アプリを選択」ダイアログ | `apps.json` でその拡張子が `"default"` になっている。`vscode` 等を割り当てる |
| 意図しないアプリで開く | `%USERPROFILE%\.local\bin\apps.json` を編集 → `install.ps1 -Apply` |
| リンクが変な所を指す | 実在しないパスをリンクした。`--min-segments` を増やす / `TUI_LINKIFY_NOEXISTS` を外す |
| パスの表示が遅れる | `--hold 0` にする（分割 write のパスはリンクされなくなる） |
| Linux 側ターミナル（WSLg 等）で開けない | `--scheme file --host ""` にする（`file:///home/...`） |
| 別ディストロ | `windows/install.ps1 -Apply -Distro <name>` または `--distro` |

## アンインストール

```sh
# WSL 側
rm -f ~/.local/bin/tui-linkify
rm -rf ~/.local/share/tui-linkify
# ~/.profile の PATH 行を消す

# Windows 側
powershell.exe -NoProfile -File "$(wslpath -w windows/install.ps1)" -Apply -Uninstall
```

## 仕組み

1. `Bun.spawn(cmd, { terminal: { … } })` で子プロセスを PTY 上に起動する（TUI が TTY を要求するため必須）。
2. 子の stdout チャンクを UTF-8 ストリームデコードし、**エスケープ列とパス/URL に分解**してから、パス部分だけを `OSC 8` で包む。エスケープ列には触らない。
3. アプリが既に開いている OSC 8 の内側はスキップする（ネスト防止）。
4. 末尾がパス途中なら一時的に保留し、次の write と結合する（保留中は後続 write も待つので順序は崩れない）。
5. キー入力は `Uint8Array` のまま PTY へ流す（文字列化しない = UTF-8 を壊さない）。リサイズは `process.stdout.on("resize")` から PTY へ伝える。
6. クリック時は Windows が登録済みの `tui-linkify://` を起動し、`tui-linkify-open.ps1` が `apps.json` を見てアプリを決める。

## リポジトリ構成

```
tui-linkify.ts                 プロキシ本体（bun 単体・依存ゼロ）
install.sh                     WSL 側 shim のインストーラ（dry-run 既定・冪等）
windows/tui-linkify-open.ps1   tui-linkify:// プロトコルハンドラ
windows/apps.json              拡張子 → 既定アプリ表
windows/install.ps1            ハンドラの登録/解除（HKCU のみ）
README.md / LICENSE            MIT
```

## ライセンス

MIT — [LICENSE](LICENSE)
