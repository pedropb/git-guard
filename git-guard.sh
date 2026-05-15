#!/usr/bin/env bash
set -euo pipefail

# ─── Config ───────────────────────────────────────────────────
HOOKS_DIR="$HOME/.git-hooks"
DISPATCH_DIR="$HOOKS_DIR/pre-push.d"
DISPATCH_FILE="$HOOKS_DIR/pre-push"
CHECK_FILE="$DISPATCH_DIR/10-git-guard"
LOCAL_FILE="$DISPATCH_DIR/50-local"
BACKUP_DIR="$HOME/.git-guard-backup"
VERSION="2.0.0"
# Marker used to detect git-guard-managed files (present in the dispatcher,
# the check, and v1's single-file hook).
GIT_GUARD_MARKER="git-guard pre-push"

# ─── Colors ───────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'    GREEN='\033[0;32m'   YELLOW='\033[0;33m'
  BLUE='\033[0;34m'   CYAN='\033[0;36m'    DIM='\033[0;90m'
  BOLD='\033[1m'      RESET='\033[0m'
  RED_BG='\033[41;97m'  GREEN_BG='\033[42;97m'
else
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' DIM='' BOLD='' RESET=''
  RED_BG='' GREEN_BG=''
fi

# ─── Helpers ──────────────────────────────────────────────────
header() {
  clear
  printf "${BOLD}${BLUE}"
  cat <<'EOF'
   ┌─────────────────────────────┐
   │  🛡️  git-guard              │
   │  Push protection for Git    │
   └─────────────────────────────┘
EOF
  printf "${RESET}"
  printf "${DIM}  v%s${RESET}\n\n" "$VERSION"
}

info()    { printf "  ${BLUE}▸${RESET} %s\n" "$1"; }
success() { printf "  ${GREEN}✔${RESET} %s\n" "$1"; }
warn()    { printf "  ${YELLOW}▸${RESET} %s\n" "$1"; }
error()   { printf "  ${RED}✖${RESET} %s\n" "$1"; }

divider() { printf "  ${DIM}%s${RESET}\n" "────────────────────────────────────────"; }

confirm() {
  local prompt="$1"
  printf "\n  ${BOLD}%s${RESET} ${DIM}[y/N]${RESET} " "$prompt"
  read -r -n 1 reply
  echo ""
  [[ "$reply" =~ ^[Yy]$ ]]
}

diff_line() {
  local prefix="$1" text="$2"
  case "$prefix" in
    "+") printf "  ${GREEN}+ %s${RESET}\n" "$text" ;;
    "-") printf "  ${RED}- %s${RESET}\n" "$text" ;;
    *)   printf "  ${DIM}  %s${RESET}\n" "$text" ;;
  esac
}

diff_header() {
  printf "\n  ${BOLD}%s${RESET}\n" "$1"
  divider
}

# ─── Parse args ───────────────────────────────────────────────
ALLOWED_ORGS=""

usage() {
  cat <<EOF
Usage: git-guard.sh --allow <org1,org2,...>

Options:
  --allow <orgs>   Comma-separated list of allowed GitHub orgs (required)
  --help           Show this help message
  --version        Show version

Examples:
  bash git-guard.sh --allow acme-org,acme-labs
  bash <(curl -fsSL https://raw.githubusercontent.com/pedropb/git-guard/main/git-guard.sh) --allow MyOrg
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow)  ALLOWED_ORGS="$2"; shift 2 ;;
    --help)   usage ;;
    --version) echo "git-guard v$VERSION"; exit 0 ;;
    *)        echo "Unknown option: $1"; usage ;;
  esac
done

if [[ -z "$ALLOWED_ORGS" ]]; then
  echo "Error: --allow is required"
  echo ""
  usage
fi

# Convert comma-separated to pipe-separated for regex
ORGS_PATTERN="${ALLOWED_ORGS//,/|}"
ORGS_DISPLAY="${ALLOWED_ORGS//,/, }"

# ─── State inspection ────────────────────────────────────────
get_current_hooks_path() {
  git config --global core.hooksPath 2>/dev/null || echo ""
}

is_git_guard_file() {
  local file="$1"
  [[ -f "$file" ]] && grep -q "$GIT_GUARD_MARKER" "$file" 2>/dev/null
}

# Returns the existing pre-push at the current hooksPath IF it's not git-guard's.
# This is the user's own hook that we want to migrate.
get_existing_user_pre_push() {
  local hooks_path
  hooks_path=$(get_current_hooks_path)
  [[ -z "$hooks_path" ]] && return 0
  local pp="$hooks_path/pre-push"
  if [[ -f "$pp" ]] && ! is_git_guard_file "$pp"; then
    cat "$pp"
  fi
}

# Lists files at the current hooksPath that are not pre-push and not git-guard's,
# so we can preserve them when we take over core.hooksPath.
list_other_hooks_to_preserve() {
  local hooks_path
  hooks_path=$(get_current_hooks_path)
  [[ -z "$hooks_path" ]] && return 0
  [[ ! -d "$hooks_path" ]] && return 0
  [[ "$hooks_path" == "$HOOKS_DIR" ]] && return 0  # already ours
  local f name
  for f in "$hooks_path"/*; do
    [[ -f "$f" ]] || continue
    name=$(basename "$f")
    [[ "$name" == "pre-push" ]] && continue        # handled separately
    [[ "$name" == "pre-push.d" ]] && continue
    is_git_guard_file "$f" && continue
    echo "$f"
  done
}

is_installed() {
  local hooks_path
  hooks_path=$(get_current_hooks_path)
  [[ "$hooks_path" == "$HOOKS_DIR" ]] && [[ -f "$CHECK_FILE" ]]
}

# ─── Hook generation ─────────────────────────────────────────
generate_check() {
  cat <<HOOK
#!/usr/bin/env bash
# git-guard pre-push check — https://github.com/pedropb/git-guard
# Blocks pushes to GitHub orgs not in the allowlist.

REMOTE_URL="\$2"
ALLOWED_ORGS="${ORGS_PATTERN}"

if echo "\$REMOTE_URL" | grep -qiE 'github\\.com'; then
  ORG=\$(echo "\$REMOTE_URL" | sed -E 's#.*github\\.com[:/]([^/]+)/.*#\\1#')

  if ! echo "\$ORG" | grep -qiE "^(\${ALLOWED_ORGS})\$"; then
    echo ""
    echo "🚫 PUSH BLOCKED by git-guard"
    echo ""
    echo "  Remote:  \$REMOTE_URL"
    echo "  Org:     \$ORG"
    echo "  Allowed: \${ALLOWED_ORGS//|/, }"
    echo ""
    echo "  If you are an AI agent confirm with the user if they want to proceed before using git push --no-verify"
    echo ""
    exit 1
  fi
fi

exit 0
HOOK
}

generate_dispatcher() {
  cat <<'DISPATCHER'
#!/usr/bin/env bash
# git-guard pre-push dispatcher — https://github.com/pedropb/git-guard
# Runs every executable in pre-push.d/ in lexical order.
# Each sub-hook receives the same args ($1=remote name, $2=remote URL)
# and the same stdin (ref update lines) as a normal pre-push hook.
# First non-zero exit blocks the push.

set -u

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)/pre-push.d"
[[ -d "$HOOK_DIR" ]] || exit 0

# stdin can only be read once, so capture it and replay for each sub-hook.
STDIN_FILE="$(mktemp -t git-guard-prepush.XXXXXX)"
trap 'rm -f "$STDIN_FILE"' EXIT
cat > "$STDIN_FILE"

shopt -s nullglob
for hook in "$HOOK_DIR"/*; do
  [[ -f "$hook" && -x "$hook" ]] || continue
  case "$(basename "$hook")" in
    *.disabled|*.sample|*.bak|.*) continue ;;
  esac
  "$hook" "$@" < "$STDIN_FILE"
  status=$?
  if [[ $status -ne 0 ]]; then
    exit $status
  fi
done

exit 0
DISPATCHER
}

# ─── Diff display ────────────────────────────────────────────
show_install_diff() {
  local current_path existing_user_hook current_check current_dispatcher
  local new_check new_dispatcher other_hooks

  current_path=$(get_current_hooks_path)
  existing_user_hook=$(get_existing_user_pre_push)
  new_check=$(generate_check)
  new_dispatcher=$(generate_dispatcher)

  current_check=""
  [[ -f "$CHECK_FILE" ]] && current_check=$(cat "$CHECK_FILE")
  current_dispatcher=""
  if [[ -f "$DISPATCH_FILE" ]] && is_git_guard_file "$DISPATCH_FILE"; then
    current_dispatcher=$(cat "$DISPATCH_FILE")
  fi

  # --- core.hooksPath ---
  diff_header "~/.gitconfig  →  core.hooksPath"
  if [[ -z "$current_path" ]]; then
    diff_line "+" "core.hooksPath = $HOOKS_DIR"
  elif [[ "$current_path" == "$HOOKS_DIR" ]]; then
    diff_line " " "core.hooksPath = $HOOKS_DIR  (no change)"
  else
    diff_line "-" "core.hooksPath = $current_path"
    diff_line "+" "core.hooksPath = $HOOKS_DIR"
  fi

  # --- dispatcher ---
  diff_header "$DISPATCH_FILE  (dispatcher)"
  if [[ -z "$current_dispatcher" ]]; then
    diff_line "+" "Install dispatcher (runs every executable in pre-push.d/)"
  elif [[ "$current_dispatcher" == "$new_dispatcher" ]]; then
    info "Dispatcher is up to date (no change)"
  else
    diff_line "-" "Existing git-guard dispatcher"
    diff_line "+" "Updated dispatcher"
  fi

  # --- git-guard check ---
  diff_header "$CHECK_FILE"
  if [[ -z "$current_check" ]]; then
    while IFS= read -r line; do
      diff_line "+" "$line"
    done <<< "$new_check"
  elif [[ "$current_check" == "$new_check" ]]; then
    info "git-guard check is up to date (no change)"
  else
    while IFS= read -r line; do
      diff_line "-" "$line"
    done <<< "$current_check"
    echo ""
    while IFS= read -r line; do
      diff_line "+" "$line"
    done <<< "$new_check"
  fi

  # --- migrated user pre-push ---
  if [[ -n "$existing_user_hook" ]]; then
    diff_header "$LOCAL_FILE  (migrated from $current_path/pre-push)"
    diff_line "+" "Your existing pre-push will run AFTER the git-guard check."
    diff_line "+" "Preview (first 5 lines):"
    head -5 <<< "$existing_user_hook" | while IFS= read -r line; do
      diff_line "+" "    $line"
    done
  fi

  # --- other hook types to preserve ---
  other_hooks=$(list_other_hooks_to_preserve)
  if [[ -n "$other_hooks" ]]; then
    diff_header "Other hooks copied from $current_path"
    while IFS= read -r f; do
      diff_line "+" "$HOOKS_DIR/$(basename "$f")"
    done <<< "$other_hooks"
  fi

  # --- backup ---
  if [[ -n "$current_path" ]] || [[ -n "$existing_user_hook" ]]; then
    diff_header "Backup"
    diff_line "+" "Snapshot saved to $BACKUP_DIR/"
  fi

  # --- per-repo warning ---
  diff_header "Note"
  diff_line " " "Setting core.hooksPath disables per-repo .git/hooks/* for repos that"
  diff_line " " "do not set core.hooksPath locally. Tools like husky/lefthook/pre-commit"
  diff_line " " "set it per-repo and will keep working. Hand-written .git/hooks/* in"
  diff_line " " "individual repos will stop running — git-guard cannot detect those."
}

show_uninstall_diff() {
  local current_path leftover_dispatch=() leftover_other=() f
  current_path=$(get_current_hooks_path)

  diff_header "$CHECK_FILE"
  if [[ -f "$CHECK_FILE" ]]; then
    diff_line "-" "Remove git-guard check"
  else
    info "Not present (nothing to remove)"
  fi

  # What would remain in pre-push.d/ after we remove the check?
  if [[ -d "$DISPATCH_DIR" ]]; then
    for f in "$DISPATCH_DIR"/*; do
      [[ -f "$f" ]] || continue
      [[ "$f" == "$CHECK_FILE" ]] && continue
      leftover_dispatch+=("$f")
    done
  fi

  # What other hook types live alongside the dispatcher?
  if [[ -d "$HOOKS_DIR" ]]; then
    for f in "$HOOKS_DIR"/*; do
      [[ -f "$f" ]] || continue
      [[ "$f" == "$DISPATCH_FILE" ]] && continue
      leftover_other+=("$f")
    done
  fi

  if [[ ${#leftover_dispatch[@]} -eq 0 ]]; then
    diff_header "$DISPATCH_FILE  (dispatcher)"
    [[ -f "$DISPATCH_FILE" ]] && diff_line "-" "Remove dispatcher (no other hooks in pre-push.d/)"
    [[ -d "$DISPATCH_DIR" ]] && diff_line "-" "Remove $DISPATCH_DIR/"
  else
    diff_header "$DISPATCH_DIR/  (kept — other hooks present)"
    for f in "${leftover_dispatch[@]}"; do
      diff_line " " "$f"
    done
  fi

  if [[ ${#leftover_dispatch[@]} -eq 0 ]] && [[ ${#leftover_other[@]} -eq 0 ]]; then
    diff_header "$HOOKS_DIR/  and  ~/.gitconfig"
    [[ -d "$HOOKS_DIR" ]] && diff_line "-" "Remove $HOOKS_DIR/"
    [[ -n "$current_path" ]] && diff_line "-" "Unset core.hooksPath (was $current_path)"
  else
    diff_header "$HOOKS_DIR/  (kept — other hooks present)"
    for f in "${leftover_other[@]}"; do
      diff_line " " "$f"
    done
    diff_line " " "core.hooksPath stays = $current_path"
  fi
}

# ─── Install ──────────────────────────────────────────────────
do_install() {
  header
  printf "  ${BOLD}Install git-guard${RESET}\n"
  printf "  ${DIM}Allowed orgs: %s${RESET}\n" "$ORGS_DISPLAY"
  divider

  show_install_diff

  if ! confirm "Apply these changes?"; then
    echo ""
    warn "Aborted. Nothing was changed."
    return
  fi

  echo ""

  # --- Capture state BEFORE making any changes ---
  local current_path user_pre_push other_hooks timestamp
  current_path=$(get_current_hooks_path)
  user_pre_push=$(get_existing_user_pre_push)
  other_hooks=$(list_other_hooks_to_preserve)
  timestamp=$(date +%Y%m%d_%H%M%S)

  # --- Snapshot ---
  mkdir -p "$BACKUP_DIR"
  {
    echo "git-guard pre-install snapshot"
    echo "timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "user: $(whoami)"
    echo "allowed_orgs: $ORGS_DISPLAY"
    echo ""
    echo "core.hooksPath = ${current_path:-<not set>}"
    echo ""
    if [[ -n "$user_pre_push" ]]; then
      echo "=== previous (non-git-guard) pre-push hook ==="
      echo "$user_pre_push"
    fi
  } > "$BACKUP_DIR/pre-install-$timestamp.txt"

  if [[ -n "$current_path" ]] && [[ -d "$current_path" ]] && [[ "$current_path" != "$HOOKS_DIR" ]]; then
    cp -r "$current_path" "$BACKUP_DIR/hooks-$timestamp"
    success "Backed up $current_path  →  $BACKUP_DIR/hooks-$timestamp"
  fi

  # --- Build the new layout ---
  mkdir -p "$DISPATCH_DIR"

  generate_dispatcher > "$DISPATCH_FILE"
  chmod +x "$DISPATCH_FILE"
  success "Wrote dispatcher: $DISPATCH_FILE"

  generate_check > "$CHECK_FILE"
  chmod +x "$CHECK_FILE"
  success "Wrote git-guard check: $CHECK_FILE"

  # Migrate user's existing pre-push (if any) to run after git-guard
  if [[ -n "$user_pre_push" ]]; then
    printf "%s\n" "$user_pre_push" > "$LOCAL_FILE"
    chmod +x "$LOCAL_FILE"
    success "Migrated existing pre-push  →  $LOCAL_FILE"
  fi

  # Preserve other hook types from the previous hooksPath
  if [[ -n "$other_hooks" ]]; then
    while IFS= read -r f; do
      local dest="$HOOKS_DIR/$(basename "$f")"
      if [[ ! -e "$dest" ]]; then
        cp "$f" "$dest"
        chmod +x "$dest"
        success "Preserved $(basename "$f")  →  $dest"
      fi
    done <<< "$other_hooks"
  fi

  # --- Switch git over ---
  git config --global core.hooksPath "$HOOKS_DIR"
  success "Set core.hooksPath = $HOOKS_DIR"

  # --- Verify ---
  echo ""
  if is_installed; then
    printf "  ${GREEN_BG} INSTALLED ${RESET}\n"
    echo ""
    info "Backup:  $BACKUP_DIR/pre-install-$timestamp.txt"
    info "Bypass:  git push --no-verify"
    if [[ -n "$user_pre_push" ]]; then
      info "Your previous pre-push hook will run after the git-guard check."
    fi
  else
    printf "  ${RED_BG} FAILED ${RESET}\n"
    error "Installation could not be verified."
  fi
}

# ─── Uninstall ────────────────────────────────────────────────
do_uninstall() {
  header
  printf "  ${BOLD}Uninstall git-guard${RESET}\n"
  divider

  if [[ ! -f "$CHECK_FILE" ]] && [[ ! -d "$HOOKS_DIR" ]] && [[ -z "$(get_current_hooks_path)" ]]; then
    info "git-guard is not installed. Nothing to do."
    return
  fi

  show_uninstall_diff

  if ! confirm "Apply these changes?"; then
    echo ""
    warn "Aborted. Nothing was changed."
    return
  fi

  echo ""

  # Remove just the git-guard check.
  if [[ -f "$CHECK_FILE" ]]; then
    rm -f "$CHECK_FILE"
    success "Removed $CHECK_FILE"
  fi

  # If pre-push.d/ is now empty, remove the dispatcher and the dir.
  local other_in_dispatch=0
  if [[ -d "$DISPATCH_DIR" ]]; then
    shopt -s nullglob
    local d_files=("$DISPATCH_DIR"/*)
    shopt -u nullglob
    other_in_dispatch=${#d_files[@]}
  fi

  if [[ $other_in_dispatch -eq 0 ]]; then
    if [[ -f "$DISPATCH_FILE" ]]; then
      rm -f "$DISPATCH_FILE"
      success "Removed dispatcher: $DISPATCH_FILE"
    fi
    if [[ -d "$DISPATCH_DIR" ]]; then
      rmdir "$DISPATCH_DIR" 2>/dev/null && success "Removed $DISPATCH_DIR"
    fi
  fi

  # Count anything left in HOOKS_DIR (other hook types, lingering dispatcher, etc.)
  local other_in_hooks=0
  if [[ -d "$HOOKS_DIR" ]]; then
    shopt -s nullglob dotglob
    local h_files=("$HOOKS_DIR"/*)
    shopt -u nullglob dotglob
    other_in_hooks=${#h_files[@]}
  fi

  if [[ $other_in_hooks -eq 0 ]]; then
    if [[ -d "$HOOKS_DIR" ]]; then
      rmdir "$HOOKS_DIR" 2>/dev/null && success "Removed $HOOKS_DIR"
    fi
    if [[ -n "$(get_current_hooks_path)" ]]; then
      git config --global --unset core.hooksPath
      success "Unset core.hooksPath"
    fi
  else
    info "Kept $HOOKS_DIR/ and core.hooksPath in place (other hooks still present)."
  fi

  echo ""
  printf "  ${GREEN_BG} REMOVED ${RESET}\n"
  echo ""
  if [[ -d "$BACKUP_DIR" ]]; then
    info "Backups kept at $BACKUP_DIR/"
  fi
}

# ─── Main menu ────────────────────────────────────────────────
main() {
  header

  if is_installed; then
    printf "  ${GREEN}●${RESET} git-guard is ${GREEN}installed${RESET}\n"
    info "Hooks path:   $(get_current_hooks_path)"
    info "Allowed orgs: $ORGS_DISPLAY"
  else
    local current_path
    current_path=$(get_current_hooks_path)
    if [[ -n "$current_path" ]]; then
      printf "  ${YELLOW}●${RESET} git-guard is ${YELLOW}not installed${RESET} (core.hooksPath = $current_path)\n"
    else
      printf "  ${DIM}●${RESET} git-guard is ${DIM}not installed${RESET}\n"
    fi
  fi

  echo ""
  divider
  echo ""
  printf "  ${BOLD}1${RESET}  Install\n"
  printf "  ${BOLD}2${RESET}  Uninstall\n"
  printf "  ${BOLD}q${RESET}  Quit\n"
  echo ""
  printf "  ${BOLD}Choose:${RESET} "
  read -r -n 1 choice
  echo ""

  case "$choice" in
    1) do_install ;;
    2) do_uninstall ;;
    q|Q) echo ""; info "Bye."; exit 0 ;;
    *) error "Invalid choice."; exit 1 ;;
  esac
}

main
