# nlscripts

Personal Linux script collection.

## Layout

- Project root — active scripts, kept at their original paths so existing links such as `~/.local/bin/foo -> /home/nelson/src/nelson/nlscripts/foo` continue to work.
- `legacy/` — scripts that may still be useful but need old tools, local paths, or optional dependencies.
- `archive/` — obsolete/vendor/Windows/infrastructure-specific scripts kept for reference.

See `VALIDATION.md` for the validation report and dependency notes.

## Compatibility symlinks

The repository root also keeps compatibility symlinks for `legacy/` and `archive/` scripts. Active scripts are real files at the root.

## Using scripts

Add the repository root to your `PATH`, for example:

```sh
export PATH="$HOME/src/nelson/nlscripts:$PATH"
```
