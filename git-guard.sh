#!/usr/bin/env bash
set -euo pipefail

# ─── Config ───────────────────────────────────────────────────
HOOKS_DIR="$HOME/.git-hooks"
BACKUP_DIR="$HOME/.git-guard-backup"
VERSION="1.0.0"

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

# Show a colored diff block
# Usage: diff_line "+" "green text"  or  diff_line "-" "red text"  or  diff_line " " "dim text"
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

get_current_hook_content() {
  local hooks_path
  hooks_path=$(get_current_hooks_path)
  if [[ -n "$hooks_path" ]] && [[ -f "$hooks_path/pre-push" ]]; then
    cat "$hooks_path/pre-push"
  fi
}

is_installed() {
  local hooks_path
  hooks_path=$(get_current_hooks_path)
  [[ "$hooks_path" == "$HOOKS_DIR" ]] && [[ -f "$HOOKS_DIR/pre-push" ]]
}

generate_hook() {
  cat <<HOOK
#!/usr/bin/env bash
# git-guard pre-push hook — https://github.com/pedropb/git-guard
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
    echo "  If this is intentional: git push --no-verify"
    echo ""
    exit 1
  fi
fi

exit 0
HOOK
}

# ─── Diff display ────────────────────────────────────────────
show_install_diff() {
  local current_path current_hook new_hook

  current_path=$(get_current_hooks_path)
  current_hook=$(get_current_hook_content)
  new_hook=$(generate_hook)

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

  # --- pre-push hook ---
  diff_header "$HOOKS_DIR/pre-push"
  if [[ -z "$current_hook" ]]; then
    while IFS= read -r line; do
      diff_line "+" "$line"
    done <<< "$new_hook"
  elif [[ "$current_hook" == "$new_hook" ]]; then
    info "Hook is already up to date (no change)"
  else
    while IFS= read -r line; do
      diff_line "-" "$line"
    done <<< "$current_hook"
    echo ""
    while IFS= read -r line; do
      diff_line "+" "$line"
    done <<< "$new_hook"
  fi

  # --- backup ---
  if [[ -n "$current_path" ]] || [[ -n "$current_hook" ]]; then
    diff_header "Backup"
    diff_line "+" "Snapshot saved to $BACKUP_DIR/"
  fi
}

show_uninstall_diff() {
  local current_path
  current_path=$(get_current_hooks_path)

  diff_header "~/.gitconfig  →  core.hooksPath"
  if [[ -n "$current_path" ]]; then
    diff_line "-" "core.hooksPath = $current_path"
  else
    info "core.hooksPath is not set (nothing to change)"
  fi

  if [[ -d "$HOOKS_DIR" ]]; then
    diff_header "$HOOKS_DIR/"
    for f in "$HOOKS_DIR"/*; do
      [[ -f "$f" ]] && diff_line "-" "$(basename "$f")"
    done
    diff_line "-" "(directory removed)"
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

  # Snapshot
  local timestamp
  timestamp=$(date +%Y%m%d_%H%M%S)
  mkdir -p "$BACKUP_DIR"

  {
    echo "git-guard pre-install snapshot"
    echo "timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "user: $(whoami)"
    echo "allowed_orgs: $ORGS_DISPLAY"
    echo ""
    echo "core.hooksPath = $(get_current_hooks_path || echo '<not set>')"
    echo ""
    local existing_hook
    existing_hook=$(get_current_hook_content)
    if [[ -n "$existing_hook" ]]; then
      echo "=== previous pre-push hook ==="
      echo "$existing_hook"
    fi
  } > "$BACKUP_DIR/pre-install-$timestamp.txt"

  # Backup existing hooks dir
  local current_path
  current_path=$(get_current_hooks_path)
  if [[ -n "$current_path" ]] && [[ -d "$current_path" ]] && [[ "$current_path" != "$HOOKS_DIR" ]]; then
    cp -r "$current_path" "$BACKUP_DIR/hooks-$timestamp"
    success "Backed up $current_path"
  fi

  # Write hook
  mkdir -p "$HOOKS_DIR"
  generate_hook > "$HOOKS_DIR/pre-push"
  chmod +x "$HOOKS_DIR/pre-push"
  success "Wrote $HOOKS_DIR/pre-push"

  # Set git config
  git config --global core.hooksPath "$HOOKS_DIR"
  success "Set core.hooksPath = $HOOKS_DIR"

  # Verify
  echo ""
  if is_installed; then
    printf "  ${GREEN_BG} INSTALLED ${RESET}\n"
    echo ""
    info "Backup:  $BACKUP_DIR/pre-install-$timestamp.txt"
    info "Bypass:  git push --no-verify"
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

  if ! is_installed && [[ -z "$(get_current_hooks_path)" ]] && [[ ! -d "$HOOKS_DIR" ]]; then
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

  if [[ -d "$HOOKS_DIR" ]]; then
    rm -rf "$HOOKS_DIR"
    success "Removed $HOOKS_DIR"
  fi

  if [[ -n "$(get_current_hooks_path)" ]]; then
    git config --global --unset core.hooksPath
    success "Unset core.hooksPath"
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

  # Show current status
  if is_installed; then
    printf "  ${GREEN}●${RESET} git-guard is ${GREEN}installed${RESET}\n"
    info "Hooks path: $(get_current_hooks_path)"
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
