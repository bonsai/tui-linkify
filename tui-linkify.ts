#!/usr/bin/env bun
// tui-linkify — PTY proxy that turns paths and bare URLs in terminal output into
// OSC 8 hyperlinks. The TUI app itself is left untouched, so one tool covers pi,
// opencode, and anything else that runs in the terminal.
//
//   WSL/Linux path      /home/sexy/x.md      -> file://wsl.localhost/<distro>/home/sexy/x.md
//   home path           ~/.pi/agent/x.md    -> expanded before linking
//   with line/col       /home/sexy/x.ts:12:3 -> link keeps the display text, URI drops :12:3
//   Windows path        C:\Users\dance\x.txt -> file:///C:/Users/dance/x.txt
//   UNC path            \\wsl.localhost\Ubuntu-24.04\home\sexy\x.md -> file://wsl.localhost/...
//   bare URL            https://example.com/x -> linked to itself
//   existing OSC 8 from the app is never nested
//
// usage: tui-linkify [--host HOST] [--no-exists] [--min-segments N] [--hold ms] -- <cmd> [args...]
//
// env:
//   TUI_LINKIFY_HOST        URI authority for WSL/Linux paths (empty string = plain file:///)
//                           default: wsl.localhost/$WSL_DISTRO_NAME when running under WSL
//   TUI_LINKIFY_NOEXISTS=1  skip the on-disk existence check (link everything that looks like a path)
//   TUI_LINKIFY_DEBUG=1     log each linked / skipped candidate to stderr

import { existsSync } from "node:fs";

const argv = process.argv.slice(2);
const defaultHost = process.env.WSL_DISTRO_NAME ? `wsl.localhost/${process.env.WSL_DISTRO_NAME}` : "";
const opts = {
  host: process.env.TUI_LINKIFY_HOST ?? defaultHost,
  exists: !process.env.TUI_LINKIFY_NOEXISTS,
  minSegments: 2,
  hold: 15,
  debug: process.env.TUI_LINKIFY_DEBUG === "1",
};
const cmd: string[] = [];
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--") { cmd.push(...argv.slice(i + 1)); break; }
  if (a === "--host") { opts.host = argv[++i] ?? ""; continue; }
  if (a === "--no-exists") { opts.exists = false; continue; }
  if (a === "--min-segments") { opts.minSegments = Number(argv[++i] ?? 2); continue; }
  if (a === "--hold") { opts.hold = Number(argv[++i] ?? 15); continue; }
  cmd.push(a);
}
if (cmd.length === 0) {
  process.stderr.write("usage: tui-linkify [options] -- <cmd> [args...]\n");
  process.exit(2);
}

const HOME = process.env.HOME ?? "";
const OSC8 = "\x1b]8;;";
const BEL = "\x07";
const SEG = "[A-Za-z0-9._@+~-]+";
const ESC = "\\x1b\\][\\s\\S]*?(?:\\x07|\\x1b\\\\)|\\x1b\\[[0-9;?]*[ -/]*[@-~]|\\x1b[@-Z\\\\-_]";
const URL = "https?://[^\\s\"'`<>\\[\\]()、。「」]+";
const UNC = "\\\\\\\\[A-Za-z0-9._$-]+\\\\[^\\\\\\s\"'`<>|]+(?:\\\\[^\\\\\\s\"'`<>|]+)+";
const WIN = "[A-Za-z]:[\\\\/](?:[^\\\\/:*?\"<>|\\s]+[\\\\/])*[^\\\\/:*?\"<>|\\s]+";
const POSIX = `(?:~|/)(?:${SEG})?(?:/${SEG})+(?::\\d+(?::\\d+)?)?`;
const TOKEN = new RegExp(
  `(${ESC})|(${URL})|(?<![\\w./:~-])(${UNC})|(?<![\\w./:~-])(${WIN})|(?<![\\w./:~-])(${POSIX})`,
  "g",
);
// trailing run that may still be continued by the next write
const TAIL_RUN = /[A-Za-z0-9._@+~/\\:-]+$/;

const existsCache = new Map<string, boolean>();
function cached(p: string): boolean {
  const hit = existsCache.get(p);
  if (hit !== undefined) return hit;
  let ok = false;
  try { ok = existsSync(p); } catch { ok = false; }
  if (existsCache.size > 4000) existsCache.clear();
  existsCache.set(p, ok);
  return ok;
}

const enc = (p: string) => p.split("/").map(encodeURIComponent).join("/").replace(/%3A/g, ":");

/** local filesystem path to test with existsSync (Windows / UNC mapped into WSL) */
function localPath(kind: "posix" | "win" | "unc", raw: string): string | undefined {
  if (kind === "posix") return raw.startsWith("~") ? HOME + raw.slice(1) : raw;
  if (kind === "win") return "/mnt/" + raw[0].toLowerCase() + "/" + raw.slice(2).replace(/\\/g, "/").replace(/^\//, "");
  const m = /^\\\\([^\\]+)\\([^\\]+)\\(.*)$/.exec(raw);
  if (!m) return undefined;
  const [, authority, share, rest] = m;
  if (authority.toLowerCase().startsWith("wsl")) return "/" + rest.replace(/\\/g, "/");
  return "/mnt/" + share.toLowerCase() + "/" + rest.replace(/\\/g, "/").replace(/^\//, "");
}

function uri(kind: "posix" | "win" | "unc", raw: string): string | undefined {
  if (kind === "posix") {
    const p = raw.startsWith("~") ? HOME + raw.slice(1) : raw;
    return opts.host ? `file://${opts.host}${enc(p.replace(/^\//, "/"))}` : `file://${enc(p)}`;
  }
  if (kind === "win") return `file:///${enc(raw.replace(/\\/g, "/").replace(/^([A-Za-z]):/, "$1:"))}`;
  const m = /^\\\\([^\\]+)\\(.*)$/.exec(raw);
  if (!m) return undefined;
  return `file://${m[1]}${enc("/" + m[2].replace(/\\/g, "/"))}`;
}

function transform(chunk: string, allowTail: boolean): string {
  const tail = TAIL_RUN.exec(chunk)?.[0] ?? "";
  const tailOpen = !allowTail && /[\\/]/.test(tail) && !/[\n\r]$/.test(chunk);
  let inLink = false;
  return chunk.replace(
    TOKEN,
    (all, esc?: string, url?: string, unc?: string, win?: string, posix?: string) => {
      if (esc !== undefined) {
        if (esc.startsWith(OSC8)) inLink = esc !== `${OSC8}${BEL}`;
        return all;
      }
      if (inLink) return all;
      if (url !== undefined) {
        const trimmed = url.replace(/[.,;:!?)\]]+$/, "");
        if (trimmed.length <= 8) return all;
        const suffix = all.slice(trimmed.length);
        if (opts.debug) console.error(`link(url): ${trimmed}`);
        return `${OSC8}${trimmed}${BEL}${trimmed}${OSC8}${BEL}${suffix}`;
      }
      const kind: "win" | "unc" | "posix" | undefined =
        unc !== undefined ? "unc" : win !== undefined ? "win" : posix !== undefined ? "posix" : undefined;
      if (kind === undefined) return all;
      const raw = (unc ?? win ?? posix)!;
      if (tailOpen && chunk.endsWith(raw)) return all;
      const body = kind === "posix" ? raw.replace(/:\d+(?::\d+)?$/, "") : raw;
      if (kind === "posix" && body.split("/").length - 1 < opts.minSegments) return all;
      if (opts.exists) {
        const local = localPath(kind, body);
        if (local === undefined || !cached(local)) {
          if (opts.debug) console.error(`skip (missing): ${local ?? body}`);
          return all;
        }
      }
      const target = uri(kind, body);
      if (!target) return all;
      if (opts.debug) console.error(`link(${kind}): ${target}`);
      return `${OSC8}${target}${BEL}${all}${OSC8}${BEL}`;
    },
  );
}

const decoder = new TextDecoder("utf-8");
let pending = "";
let timer: ReturnType<typeof setTimeout> | null = null;

function emit(allowTail: boolean) {
  if (timer !== null) { clearTimeout(timer); timer = null; }
  if (!pending) return;
  const out = transform(pending, allowTail);
  pending = "";
  if (out) process.stdout.write(out);
}

const child = Bun.spawn(cmd, {
  terminal: {
    cols: process.stdout.columns || 80,
    rows: process.stdout.rows || 24,
    data(_t, chunk) {
      pending += decoder.decode(chunk, { stream: true });
      const tail = TAIL_RUN.exec(pending)?.[0] ?? "";
      if (/[\\/]/.test(tail) && !/[\n\r]$/.test(pending)) {
        if (timer === null) timer = setTimeout(() => emit(true), opts.hold);
        return;
      }
      emit(false);
    },
  },
  env: process.env,
});

const terminal = child.terminal as unknown as {
  write(s: string | Uint8Array): void;
  resize(c: number, r: number): void;
};

if (process.stdin.isTTY) { try { process.stdin.setRawMode(true); } catch {} }
process.stdin.resume();
process.stdin.on("data", (d: Buffer) => terminal.write(d as unknown as string));
process.stdin.on("end", () => { try { terminal.write("\x04"); } catch {} });
process.stdout.on("resize", () => terminal.resize(process.stdout.columns || 80, process.stdout.rows || 24));

const code = await child.exited;
emit(true);
if (process.stdin.isTTY) { try { process.stdin.setRawMode(false); } catch {} }
process.stdout.write(`${OSC8}${BEL}`);
process.exit(code);
