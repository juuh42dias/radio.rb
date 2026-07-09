# Terminal Radio

Listen to internet radio stations in your terminal.

## Dependencies

- **Ruby** >= 2.7
- **[mpg123](https://www.mpg123.de/)** — audio playback (required)

Install mpg123:

| macOS | `brew install mpg123` |
|---|---|
| Debian/Ubuntu | `sudo apt-get install mpg123` |
| Arch Linux | `sudo pacman -S mpg123` |

## Optional Gems

For ASCII art, colors, and spinners:

```sh
bundle install
```

## Run

```sh
bundle exec ruby radio.rb
```

## Controls

| Key | Action |
|---|---|
| `Space` / `k` | Play / Pause |
| `n` / `→` | Next station |
| `p` / `←` | Previous station |
| `+` / `=` | Volume up |
| `-` / `_` | Volume down |
| `s` | Select station |
| `a` | Add station |
| `r` | Remove station |
| `l` | List stations |
| `A` | Autoplay all |
| `R` | Restore defaults |
| `q` | Quit |

Stations are persisted to `~/.terminal_radio/stations.yml`.
