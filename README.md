<h1>
<p align="center">
  <img src="./logo.png" alt="Logo" width="128">
  <br>zmx
</h1>
<p align="center">
  Session attach/detach for the terminal.
  <br />
  <a href="https://zmx.sh">Docs</a>
  ·
  <a href="https://bower.sh/you-might-not-need-tmux">You might not need tmux</a>
  ·
  Sponsored by <a href="https://pico.sh">pico.sh</a>
</p>

## features

- Persist terminal shell sessions
- Ability to attach and detach from a shell session without it being killed
- Native terminal scrollback
- Multiple clients can connect to the same session
- Re-attaching to a session restores previous terminal state and output
- Send commands to a session without attaching to it
- Print scrollback history of a terminal session in plain text
- Works on mac and linux
- Use `zmx` as a zig package
- This project does **NOT** provide windows, tabs, or splits

## demos

- [zmx - intro](https://youtu.be/UIXj0_rhPgI)
- [zmx - ai portal](https://youtu.be/CV3skPYHP4Q)

## docs

Full documentation is available at **[https://zmx.sh](https://zmx.sh)**:

- [Install & Usage](https://zmx.sh/getting-started)
- [Shell Integration](https://zmx.sh/shell-integration)
- [SSH Workflow](https://zmx.sh/ssh)
- [Zig Package](https://zmx.sh/zig-package)
- [Configuration & Debugging](https://zmx.sh/configuration)
- [Architecture & Philosophy](https://zmx.sh/architecture)
- [Community Tools](https://zmx.sh/community)

## build

Requires Zig `v0.17.0`:

```bash
# Build debug binary (./zig-out/bin/zmx)
zig build

# Install release binary to ~/.local/bin
zig build -Doptimize=ReleaseSafe --prefix ~/.local
```

See [CONTRIBUTING.md](./CONTRIBUTING.md) for testing, local debugging, and contribution guidelines.

## screen and scrollback capture

`zmx history --screen <name>` prints only the active screen, and
`zmx history --scrollback N <name>` adds up to `N` rows of scrollback above it.
Both work with `--vt` and `--html`. The daemon selects the rows before
formatting them, so a tool that polls a session's current state no longer
receives and discards the whole history. Alternate screens have no scrollback,
so they always return just the screen. Sessions whose daemon predates this
feature keep serving plain `history`; the scoped flags report that the daemon
is too old.

## Ghostex private OSC sequences and `zmx grid`

This fork carries Ghostex-only behavior layered on the attach protocol. An
attach client consumes these in-band sequences from its stdin (they are never
forwarded to the pty) and turns them into IPC messages; the canonical parser is
`appendClientInputMessages` in `src/loop.zig`.

- `ESC ] 1337 ; ZMX_REFRESH BEL`: repaint this client; leadership-neutral.
- `ESC ] 1337 ; ZMX_VISIBLE=<rows>,<cols> BEL`: terminal on screen at this size.
- `ESC ] 1337 ; ZMX_CHAT=<rows>,<cols> BEL`: chat on screen, claiming a wide resting grid.
- `ESC ] 1337 ; ZMX_HIDDEN=<rows>,<cols> BEL`: parked for any other reason, no chat claim.

Only a visible terminal may size the PTY, with the most recently active client
winning. A fresh attach and user input count as visible. With no visible client,
a chat claim widens the grid to at least `RESTING_GRID_COLS` (200), using the
freshest parked client's rows. Without either claim, the grid stays unchanged.
Dropping a chat claim never narrows an unattended grid. Headless sessions start
at 50x200. Background or non-selected chat tabs hold no claim.

Both non-visible states pin their local emulator to 200 columns because another
client's chat claim may widen the daemon. Once visibility is announced, all
subsequent grid changes must use visibility OSCs; bare SIGWINCH/Resize is ignored
for that client so local parking cannot race ahead and widen the shared PTY.
Plain attach clients continue to size through SIGWINCH. `zmx send` never changes leadership.
`zmx grid <name>` prints the grid, leader, resting size, `chat_claim`, and each
client's `state` (`visible`, `chat`, `parked`) as JSON.
