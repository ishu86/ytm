# ytm

Play YouTube Music, YouTube videos, and local audio in a macOS terminal. Search, queue, and control playback with the keyboard or mouse. **For You** ranks tracks on your Mac using likes, listens, and skips.

![ytm searching, queueing and playing music in a terminal](assets/demo.gif)

## Install with a coding agent

Paste this into Claude Code, Codex, Cursor, or any coding agent:

```text
Install ytm (https://github.com/ishu86/ytm) on my Mac. Check that macOS is 14 or later and that the Xcode Command Line Tools are installed and up to date; if not, run xcode-select --install and wait for me to finish it. If Homebrew is missing, install it from https://brew.sh. Then run brew install ishu86/ytm/ytm and confirm it works with ytm --help. Tell me to run ytm to open the player.
```

## Install with Homebrew

On macOS 14 or later:

```sh
brew install ishu86/ytm/ytm
ytm
```

## Run from source

On macOS 14 or later, install Apple's Command Line Tools with `xcode-select --install` and install the dependencies with Homebrew:

```sh
brew install uv yt-dlp jq
./ytm
```

The first run builds the native player. Install `mpv` for the optional `ytm play` fallback when the native player can't open a source.

Run `./ytm --help` for command-line shortcuts. For example, `./ytm song 'artist and title'` searches directly, and `./ytm play 'URL or file path'` opens a source. To run `ytm` from anywhere, symlink the launcher into a directory on your `PATH` and keep the checkout in place.

## Data and network

Search, streaming, and first-time related-track lookups use YouTube's services. Listening history and rankings stay in a local SQLite database under `${XDG_STATE_HOME:-~/.local/state}/ytm`. No account, model, or background service is required.

Licensed under the [MIT License](LICENSE).
