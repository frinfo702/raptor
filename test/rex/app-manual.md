# Raptor app: attach and persist (manual check)

Quitting Raptor detaches from the rap server, which keeps every session and
its programs running. Relaunching attaches again. This script checks that by
hand, on the default server socket.

Build first (Zig 0.17 comes from the nix dev shell):

```sh
direnv exec . zig build      # or: nix develop -c zig build
APP=macos/build/Debug/Raptor.app
RAP=zig-out/bin/rap          # panes don't have rap on PATH yet
```

Rebuild after every checkout: an older `$APP` runs older code, and the
server keeps running whichever `rap` started it (`$RAP server stop` first).
The script needs `htop` and `nvim` on your PATH (`brew install htop neovim`);
`rap run` refuses a program it can't find.

Start with no server running (`$RAP ls` exits 4), or note which sessions
already exist.

1. **Launch and get a shell.** Open `$APP` from the Finder or Dock (the app
   attaches when it first becomes active). One window opens with one tab and
   a shell. In it, make some scrollback:

   ```sh
   seq 1 500 | sed 's/^/tab1 scrollback /'
   ```

2. **htop in tab 2, nvim in tab 3.** From any terminal:

   ```sh
   $RAP run -- htop
   printf 'saved line\n' > /tmp/raptor-note.txt
   $RAP run -- nvim /tmp/raptor-note.txt
   ```

   Each shows up as a new tab in the window. In nvim, type
   `ounsaved edit` and press Escape, without saving. (Use a new file name each
   run: a swap file left by an earlier nvim makes nvim prompt first.)

3. **Quit with ⌘Q.** No confirmation appears and the app exits.

4. **The session lives on.** `$RAP ls` shows the session with 3 windows and
   3 blocks. `$RAP capture -w 3` still shows `unsaved edit`.

5. **Relaunch** the same way. The same window comes back with the same three
   tabs, on the tab that was active:
   - tab 2: htop is still updating (its clock and CPU bars move);
   - tab 3: the nvim buffer still has `unsaved edit`;
   - tab 1: scroll up (⌘Home): `tab1 scrollback 1` is there.

6. **Closing detaches, closing a tab kills.** Close the window with the red
   button: `$RAP ls` still lists the session. Relaunch, then close tab 2 with
   its ×: Raptor asks first because htop is running, and after you confirm,
   `$RAP ls` shows 2 windows.

Clean up with `$RAP kill <session>`; the server exits 30 s after its last
session and client are gone.

The XCTest `RaptorSmokeTests` covers launch and attach automatically:

```sh
cd macos && xcodebuild test -scheme Ghostty -skip-testing GhosttyUITests \
    -only-testing GhosttyTests/RaptorSmokeTests
```

`test/rex/frame-compare.sh` checks the title bar and splits against Rex's
reference frames (title bar height, tab pill size, theme token colours) and
writes side-by-side images to its output directory.
