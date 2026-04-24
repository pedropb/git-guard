# 🛡️ git-guard

**Push protection for Git.** Blocks `git push` to GitHub orgs not in your allowlist — so you never accidentally push to the wrong organization.

## Why

One bad `git push` to a personal fork or the wrong org can leak proprietary code. git-guard installs a global `pre-push` hook that catches this before it happens.

- ✅ Allows pushes to your approved GitHub orgs
- 🚫 Blocks everything else with a clear error
- 🔓 Bypass with `git push --no-verify` when intentional

## Install

**One-liner** (recommended):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/pedropb/git-guard/main/git-guard.sh) --allow MyCompany,acme-org
```

**Local clone:**

```bash
git clone https://github.com/pedropb/git-guard.git
cd git-guard
bash git-guard.sh --allow MyCompany,acme-org
```

The installer shows a diff of every change and asks for confirmation before writing anything.

## Usage

```bash
# Install — allow pushes to two orgs
bash git-guard.sh --allow MyCompany,acme-org

# The interactive menu lets you install or uninstall
# Choose 1 to install, 2 to uninstall, q to quit
```

### What a blocked push looks like

```
🚫 PUSH BLOCKED by git-guard

  Remote:  git@github.com:some-other-org/repo.git
  Org:     some-other-org
  Allowed: MyCompany, acme-org

  If this is intentional: git push --no-verify
```

### Bypass

```bash
git push --no-verify
```

## How it works

1. Sets `core.hooksPath` in `~/.gitconfig` to `~/.git-hooks/`
2. Writes a `pre-push` hook that extracts the org from the remote URL
3. Compares the org against your allowlist (case-insensitive)
4. Blocks the push if the org isn't allowed

**Files touched:**

| Path | What |
|---|---|
| `~/.gitconfig` | Sets `core.hooksPath = ~/.git-hooks` |
| `~/.git-hooks/pre-push` | The guard hook |
| `~/.git-guard-backup/` | Pre-install snapshots (for rollback) |

## Uninstall

Run the script again and choose **2 (Uninstall)** from the menu. It removes the hook directory and unsets `core.hooksPath`. Backups are kept at `~/.git-guard-backup/`.

## FAQ

**Does this affect non-GitHub remotes?**
No. The hook only inspects URLs containing `github.com`. Pushes to GitLab, Bitbucket, etc. pass through untouched.

**What if I already have a `core.hooksPath` set?**
The installer backs up your existing hooks directory and config before overwriting. Check `~/.git-guard-backup/` if you need to restore.

**Does this work with per-repo hooks?**
`core.hooksPath` overrides per-repo `.git/hooks/`. If you rely on repo-local hooks, you'll need to call them from the global hook or use a hook manager.

**Can I add more orgs later?**
Re-run the installer with the full list. It will show the diff and update the hook.

## License

[MIT](LICENSE) © Pedro Baracho
