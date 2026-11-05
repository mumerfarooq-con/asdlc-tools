# shared/

Files used by both plugins, `ovo` and `asdlc`. Nothing here is a plugin of its own.

- **How a plugin gets a file:** a relative symlink inside the plugin points here, for example
  `plugins/asdlc/scripts/impact-core.sh -> ../../../shared/scripts/impact-core.sh`.
  Claude Code copies the file into the plugin at install, so an installed plugin has a real file
  next to its other scripts and no `shared/` directory at all.
- **Never reference this directory at runtime** (`../shared`, or any path outside the plugin).
  Scripts find a shared file next to themselves, through the link. The hygiene tests check that
  every link in `plugins/` resolves inside this directory.
- **A change here changes both plugins:** bump both versions and add both changelog entries.
- **Windows:** clone with `git config core.symlinks true`, or the links check out as text files.
