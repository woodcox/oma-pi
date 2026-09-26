# Set the global git identity (user.name / user.email)
git-id() {
  local current_name current_email name email

  current_name="$(git config --global user.name 2>/dev/null || true)"
  current_email="$(git config --global user.email 2>/dev/null || true)"

  name="$(gum input --prompt "Git user name: " --placeholder "${current_name:-Your Name}" || true)"
  if [[ -z $name ]]; then
    echo "Cancelled, git identity unchanged"
    return 1
  fi

  email="$(gum input --prompt "Git email: " --placeholder "${current_email:-you@example.com}" || true)"
  if [[ -z $email ]]; then
    echo "Cancelled, git identity unchanged"
    return 1
  fi

  if [[ ! $email =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    echo "Not a valid email address: $email"
    return 1
  fi

  if ! git config --global user.name "$name"; then
    echo "Failed to set git user.name" >&2
    return 1
  fi

  if ! git config --global user.email "$email"; then
    echo "Failed to set git user.email" >&2
    return 1
  fi

  echo "✓ Git identity set to $name <$email>"
}
