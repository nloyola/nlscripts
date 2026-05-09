# Linux Scripts Validation

Validated on 2026-05-09.

## What changed

- Kept active scripts as real files at the project root, preserving original paths for existing links such as `~/.local/bin/foo -> /home/nelson/src/nelson/nlscripts/foo`.
- Organized inactive scripts into:
  - `legacy/` — scripts that may still be useful but depend on old services, local paths, or missing packages.
  - `archive/` — retired/vendor/obsolete scripts kept for reference.
- Added root-level compatibility symlinks for `legacy/` and `archive/` scripts.
- Modernized shebangs to use `/usr/bin/env` where practical.
- Converted CRLF line endings to LF, except Windows batch files.
- Replaced old `mencoder` workflows:
  - `makeavi` now uses `ffmpeg` and defaults to H.264/AAC MP4 output.
  - `flv2avi` now uses `ffmpeg`.
- Retired obsolete launchers with explicit messages:
  - `archive/azureus`
  - `archive/xp_firebird`
  - `archive/xp_mozilla`
  - `archive/xp_thunderbird`

## Validation performed

Syntax checks were run with available interpreters:

- `bash -n`
- `sh -n`
- `perl -c`
- `php -l`

`tcsh` and `expect` are not installed on this machine, so those scripts were not fully syntax-checked.

## Current known dependency failures

These scripts failed `perl -c` only because required Perl modules are not installed locally:

| Script | Missing module |
| --- | --- |
| `imagerename` | `Image::ExifTool` |
| `legacy/chkmail` | `Mail::POP3Client` |
| `legacy/fdbrip` | `CDDB` |
| `legacy/freedbget` | `CDDB` |
| `legacy/lotto.pl` | `Date::Manip` |
| `legacy/mail_file` | `Mail::Sendmail` |
| `legacy/movies.pl` | `IMDB::Film` |
| `legacy/papersdb_git_pull` | `Expect` |
| `legacy/send_config` | `Mail::Sendmail` |
| `archive/papersdb_cvs_update` | `Expect` |
| `archive/xcmd` | `Expect` |

Suggested Debian/Ubuntu packages:

```sh
sudo apt install \
  libimage-exiftool-perl \
  libmail-pop3client-perl \
  libcddb-perl \
  libdate-manip-perl \
  libmail-sendmail-perl \
  libexpect-perl
```

`IMDB::Film` may need to be installed from CPAN if it is not available from your distribution.

## Remaining skipped checks

- `archive/config_tar` requires `tcsh`.
- `archive/uploadftp` requires `expect`.

## Notes

- `archive/rxvt.bat` intentionally keeps CRLF/Windows semantics.
- Scripts in `legacy/` and `archive/` may still contain hardcoded local paths, old protocols, or old tools such as Perforce, CVS, telnet, ftp, rsh, Xprint, XEmacs, Azureus, or ccxstream.
