#!/usr/bin/env bash
set -euo pipefail
set +x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RELEASE_ENV_FILE="$PROJECT_DIR/.release.env"

repository="${OPENWRITR_REPOSITORY:-trsdn/OpenWritr}"
team_id="${APPLE_TEAM_ID:-G69Z5BNY97}"
profile="${NOTARY_PROFILE:-OpenWritr}"

apple_id=""
apple_app_password=""
apple_app_password_confirmation=""
dialog_result=""
secret_names=""
gui_mode=false

cleanup_secrets() {
  apple_id=""
  apple_app_password=""
  apple_app_password_confirmation=""
  dialog_result=""
  unset apple_id apple_app_password apple_app_password_confirmation dialog_result APPLE_APP_PASSWORD
}

handle_signal() {
  local status="$1"
  cleanup_secrets
  trap - EXIT HUP INT TERM
  exit "$status"
}

trap cleanup_secrets EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

unset APPLE_APP_PASSWORD
export GH_PROMPT_DISABLED=1
unset GH_DEBUG

usage() {
  cat <<'EOF'
Usage: scripts/setup_notarization.sh [options]

Configure GitHub Actions notarization secrets and a local notarytool profile.

Options:
  --repo OWNER/REPO   GitHub repository (default: trsdn/OpenWritr)
  --team-id ID        Apple Developer team ID (default: G69Z5BNY97)
  --profile NAME      Local notarytool profile (default: OpenWritr)
  --gui               Read credentials from secure macOS dialogs (no TTY needed)
  -h, --help          Show this help

Environment overrides:
  OPENWRITR_REPOSITORY, APPLE_TEAM_ID, NOTARY_PROFILE

By default, credentials are read from an interactive terminal. With --gui,
the Apple ID and hidden app-specific password are read from macOS dialogs.
EOF
}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ "$#" -ge 2 && -n "$2" ]] || die "--repo requires OWNER/REPO."
      repository="$2"
      shift 2
      ;;
    --repo=*)
      repository="${1#*=}"
      shift
      ;;
    --team-id)
      [[ "$#" -ge 2 && -n "$2" ]] || die "--team-id requires a value."
      team_id="$2"
      shift 2
      ;;
    --team-id=*)
      team_id="${1#*=}"
      shift
      ;;
    --profile)
      [[ "$#" -ge 2 && -n "$2" ]] || die "--profile requires a value."
      profile="$2"
      shift 2
      ;;
    --profile=*)
      profile="${1#*=}"
      shift
      ;;
    --gui)
      gui_mode=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || die "Repository must use the OWNER/REPO format."
[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] \
  || die "Apple Developer team ID must be 10 uppercase letters or digits."
[[ "$profile" =~ ^[A-Za-z0-9._-]+$ ]] \
  || die "Profile may contain only letters, digits, dots, underscores, and hyphens."

if [[ "$gui_mode" != true ]] && [[ ! -t 0 || ! -t 2 ]]; then
  die "An interactive terminal is required; use --gui from an active macOS GUI session for a non-TTY runner."
fi

for tool in gh xcrun security git; do
  command -v "$tool" >/dev/null 2>&1 || die "Required tool not found: $tool"
done

if [[ "$gui_mode" == true ]]; then
  [[ "$(uname -s)" == "Darwin" ]] || die "--gui requires macOS."
  command -v osascript >/dev/null 2>&1 || die "Required tool not found: osascript"
  command -v python3 >/dev/null 2>&1 || die "Required tool not found: python3"
  launchctl print "gui/$(id -u)" >/dev/null 2>&1 \
    || die "--gui requires an active macOS GUI login session."

  if ! dialog_result="$(
    osascript 2>/dev/null <<'APPLESCRIPT'
try
  set dialogResponse to display dialog "OpenWritr will request notarization credentials in secure dialogs." with title "OpenWritr Notarization Setup" buttons {"Cancel", "Continue"} default button "Continue" cancel button "Cancel"
  return button returned of dialogResponse
on error number -128
  return "CANCEL"
end try
APPLESCRIPT
  )"; then
    die "osascript could not display dialogs in the active GUI session."
  fi
  case "$dialog_result" in
    Continue)
      dialog_result=""
      ;;
    CANCEL)
      printf 'Credential setup canceled.\n' >&2
      exit 130
      ;;
    *)
      die "osascript returned an unexpected dialog result."
      ;;
  esac
fi

xcrun --find notarytool >/dev/null 2>&1 || die "notarytool is not available through xcrun."
gh auth status >/dev/null 2>&1 || die "GitHub CLI authentication is required; run 'gh auth login'."

if [[ -L "$RELEASE_ENV_FILE" ]]; then
  die ".release.env must not be a symbolic link."
fi
git -C "$PROJECT_DIR" check-ignore -q -- .release.env \
  || die ".release.env is not ignored by Git."

load_secret_names() {
  if ! secret_names="$(
    gh secret list \
      --repo "$repository" \
      --app actions \
      --json name \
      --jq '.[].name'
  )"; then
    die "Unable to list GitHub Actions secrets for $repository."
  fi
}

secret_exists() {
  local expected="$1"
  local existing

  while IFS= read -r existing; do
    [[ "$existing" == "$expected" ]] && return 0
  done <<< "$secret_names"
  return 1
}

load_secret_names
missing_certificate_secrets=()
for secret_name in MACOS_CERTIFICATE MACOS_CERTIFICATE_PWD; do
  if ! secret_exists "$secret_name"; then
    missing_certificate_secrets+=("$secret_name")
  fi
done

if [[ "${#missing_certificate_secrets[@]}" -gt 0 ]]; then
  printf 'Error: Required certificate secret(s) missing in %s: %s\n' \
    "$repository" "${missing_certificate_secrets[*]}" >&2
  printf 'Configure the existing Developer ID certificate separately; this script never exports private keys.\n' >&2
  exit 1
fi

if [[ "$gui_mode" == true ]]; then
  if ! dialog_result="$(
    osascript 2>/dev/null <<'APPLESCRIPT'
try
  set dialogResponse to display dialog "Apple ID:" default answer "" with title "OpenWritr Notarization Setup" buttons {"Cancel", "Continue"} default button "Continue" cancel button "Cancel"
  return "VALUE" & linefeed & (text returned of dialogResponse)
on error number -128
  return "CANCEL"
end try
APPLESCRIPT
  )"; then
    die "Unable to display the Apple ID dialog."
  fi
  case "$dialog_result" in
    VALUE)
      apple_id=""
      ;;
    VALUE$'\n'*)
      apple_id="${dialog_result#*$'\n'}"
      ;;
    CANCEL)
      printf 'Credential setup canceled.\n' >&2
      exit 130
      ;;
    *)
      die "Unable to read the Apple ID from the dialog."
      ;;
  esac
  dialog_result=""
  [[ -n "$apple_id" ]] || die "Apple ID cannot be empty."

  if ! dialog_result="$(
    osascript 2>/dev/null <<'APPLESCRIPT'
try
  set dialogResponse to display dialog "App-specific password:" default answer "" with title "OpenWritr Notarization Setup" buttons {"Cancel", "Continue"} default button "Continue" cancel button "Cancel" with hidden answer
  return "VALUE" & linefeed & (text returned of dialogResponse)
on error number -128
  return "CANCEL"
end try
APPLESCRIPT
  )"; then
    die "Unable to display the app-specific password dialog."
  fi
  case "$dialog_result" in
    VALUE)
      apple_app_password=""
      ;;
    VALUE$'\n'*)
      apple_app_password="${dialog_result#*$'\n'}"
      ;;
    CANCEL)
      printf 'Credential setup canceled.\n' >&2
      exit 130
      ;;
    *)
      die "Unable to read the app-specific password from the dialog."
      ;;
  esac
  dialog_result=""

  if ! dialog_result="$(
    osascript 2>/dev/null <<'APPLESCRIPT'
try
  set dialogResponse to display dialog "Confirm app-specific password:" default answer "" with title "OpenWritr Notarization Setup" buttons {"Cancel", "Continue"} default button "Continue" cancel button "Cancel" with hidden answer
  return "VALUE" & linefeed & (text returned of dialogResponse)
on error number -128
  return "CANCEL"
end try
APPLESCRIPT
  )"; then
    die "Unable to display the app-specific password confirmation dialog."
  fi
  case "$dialog_result" in
    VALUE)
      apple_app_password_confirmation=""
      ;;
    VALUE$'\n'*)
      apple_app_password_confirmation="${dialog_result#*$'\n'}"
      ;;
    CANCEL)
      printf 'Credential setup canceled.\n' >&2
      exit 130
      ;;
    *)
      die "Unable to read the app-specific password confirmation from the dialog."
      ;;
  esac
  dialog_result=""
else
  printf 'Apple ID: ' >&2
  if ! IFS= read -r apple_id; then
    die "Unable to read Apple ID."
  fi
  [[ -n "$apple_id" ]] || die "Apple ID cannot be empty."

  printf 'App-specific password: ' >&2
  if ! IFS= read -r -s apple_app_password; then
    printf '\n' >&2
    die "Unable to read app-specific password."
  fi
  printf '\nConfirm app-specific password: ' >&2
  if ! IFS= read -r -s apple_app_password_confirmation; then
    printf '\n' >&2
    die "Unable to confirm app-specific password."
  fi
  printf '\n' >&2
fi

[[ -n "$apple_app_password" ]] || die "App-specific password cannot be empty."
[[ "$apple_app_password" == "$apple_app_password_confirmation" ]] \
  || die "App-specific passwords do not match."
apple_app_password_confirmation=""
unset apple_app_password_confirmation

if ! printf '%s' "$apple_id" \
  | gh secret set APPLE_ID --repo "$repository" --app actions >/dev/null; then
  die "Failed to set the APPLE_ID GitHub Actions secret."
fi
if ! printf '%s' "$team_id" \
  | gh secret set APPLE_TEAM_ID --repo "$repository" --app actions >/dev/null; then
  die "Failed to set the APPLE_TEAM_ID GitHub Actions secret."
fi
if ! printf '%s' "$apple_app_password" \
  | gh secret set APPLE_APP_PASSWORD --repo "$repository" --app actions >/dev/null; then
  apple_app_password=""
  unset apple_app_password
  die "Failed to set the APPLE_APP_PASSWORD GitHub Actions secret."
fi

run_notarytool_gui() {
  python3 -c "$(cat <<'PYTHON'
import errno
import fcntl
import os
import re
import select
import signal
import sys
import termios
import time

TIMEOUT_SECONDS = 120.0
PROMPT_PATTERN = re.compile(
    rb"(?i)(?:^|[\r\n])\s*(?:enter\s+)?(?:(?:an?|the|your)\s+)?"
    rb"(?:app(?:lication)?[- ]specific\s+)?password"
    rb"(?:\s+for\s+[^\r\n:]+)?\s*:\s*$"
)
ANSI_PATTERN = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]")


class DriverSignal(Exception):
    def __init__(self, signum):
        self.signum = signum


def wipe(value):
    for index in range(len(value)):
        value[index] = 0


def disable_echo(fd):
    attributes = termios.tcgetattr(fd)
    attributes[3] &= ~(termios.ECHO | termios.ECHONL)
    termios.tcsetattr(fd, termios.TCSANOW, attributes)


def write_all(fd, value):
    view = memoryview(value)
    offset = 0
    while offset < len(view):
        written = os.write(fd, view[offset:])
        if written == 0:
            raise OSError("PTY write returned no bytes")
        offset += written


def status_to_exit_code(status):
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 1


def terminate_and_reap(pid):
    try:
        os.killpg(pid, signal.SIGTERM)
    except ProcessLookupError:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass

    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        try:
            waited_pid, status = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return None
        if waited_pid == pid:
            return status
        time.sleep(0.05)

    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        return os.waitpid(pid, 0)[1]
    except ChildProcessError:
        return None


def read_password(password):
    while True:
        chunk = os.read(0, 4096)
        if not chunk:
            return
        password.extend(chunk)


def run():
    if len(sys.argv) != 4:
        sys.stderr.write("Credential driver received invalid non-secret arguments.\n")
        return 2

    profile, apple_id, team_id = sys.argv[1:]
    password = bytearray()
    master_fd = None
    slave_fd = None
    child_pid = None
    child_status = None
    prompt_buffer = bytearray()
    password_sent = False

    def handle_signal(signum, _frame):
        raise DriverSignal(signum)

    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, handle_signal)

    try:
        read_password(password)
        if not password:
            sys.stderr.write("Credential driver received an empty password.\n")
            return 2

        master_fd, slave_fd = os.openpty()
        disable_echo(slave_fd)
        child_pid = os.fork()
        if child_pid == 0:
            try:
                os.setsid()
                fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)
                os.dup2(slave_fd, 0)
                os.dup2(slave_fd, 1)
                os.dup2(slave_fd, 2)
                if master_fd > 2:
                    os.close(master_fd)
                if slave_fd > 2:
                    os.close(slave_fd)
                os.execvp(
                    "xcrun",
                    [
                        "xcrun",
                        "notarytool",
                        "store-credentials",
                        profile,
                        "--apple-id",
                        apple_id,
                        "--team-id",
                        team_id,
                    ],
                )
            except BaseException:
                os._exit(127)

        os.close(slave_fd)
        slave_fd = None
        deadline = time.monotonic() + TIMEOUT_SECONDS

        while child_status is None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                child_status = terminate_and_reap(child_pid)
                child_pid = None
                sys.stderr.write("notarytool credential setup timed out.\n")
                return 124

            readable, _, _ = select.select([master_fd], [], [], min(0.25, remaining))
            if readable:
                try:
                    chunk = os.read(master_fd, 4096)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    chunk = b""

                if chunk and not password_sent:
                    prompt_buffer.extend(chunk)
                    if len(prompt_buffer) > 8192:
                        del prompt_buffer[:-8192]
                    clean_output = ANSI_PATTERN.sub(b"", bytes(prompt_buffer))
                    if PROMPT_PATTERN.search(clean_output):
                        disable_echo(master_fd)
                        write_all(master_fd, password)
                        write_all(master_fd, b"\n")
                        wipe(password)
                        password_sent = True
                        wipe(prompt_buffer)
                        prompt_buffer.clear()

            waited_pid, status = os.waitpid(child_pid, os.WNOHANG)
            if waited_pid == child_pid:
                child_status = status
                child_pid = None

        if not password_sent:
            sys.stderr.write("notarytool exited before requesting the password.\n")
            exit_code = status_to_exit_code(child_status)
            return exit_code if exit_code != 0 else 1

        exit_code = status_to_exit_code(child_status)
        if exit_code != 0:
            sys.stderr.write("notarytool did not store and validate the Keychain profile.\n")
        return exit_code
    except DriverSignal as error:
        for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            signal.signal(signum, signal.SIG_IGN)
        if child_pid is not None:
            child_status = terminate_and_reap(child_pid)
            child_pid = None
        return 128 + error.signum
    except BaseException:
        sys.stderr.write("Credential driver failed before notarization credentials were stored.\n")
        return 1
    finally:
        wipe(password)
        wipe(prompt_buffer)
        if child_pid is not None:
            terminate_and_reap(child_pid)
        if slave_fd is not None:
            os.close(slave_fd)
        if master_fd is not None:
            os.close(master_fd)


sys.exit(run())
PYTHON
  )" "$profile" "$apple_id" "$team_id"
}

if [[ "$gui_mode" == true ]]; then
  notarytool_status=0
  printf '%s' "$apple_app_password" | run_notarytool_gui || notarytool_status=$?
  apple_app_password=""
  unset apple_app_password
  if [[ "$notarytool_status" -ne 0 ]]; then
    printf 'Error: notarytool credential setup failed.\n' >&2
    exit "$notarytool_status"
  fi
else
  apple_app_password=""
  unset apple_app_password
  printf '\nnotarytool will prompt securely for the app-specific password.\n' >&2
  printf 'Enter the same password again; this script does not pass it to notarytool.\n' >&2
  if ! xcrun notarytool store-credentials "$profile" \
    --apple-id "$apple_id" \
    --team-id "$team_id"; then
    die "notarytool did not store and validate the Keychain profile."
  fi
fi
unset apple_id

load_secret_names
missing_required_secrets=()
for secret_name in \
  MACOS_CERTIFICATE \
  MACOS_CERTIFICATE_PWD \
  APPLE_ID \
  APPLE_TEAM_ID \
  APPLE_APP_PASSWORD; do
  if ! secret_exists "$secret_name"; then
    missing_required_secrets+=("$secret_name")
  fi
done

if [[ "${#missing_required_secrets[@]}" -gt 0 ]]; then
  printf 'Error: Required GitHub Actions secret name(s) not found: %s\n' \
    "${missing_required_secrets[*]}" >&2
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
  die "The stored notarytool Keychain profile could not access submission history."
fi

find_signing_identity() {
  local line
  local fingerprint

  while IFS= read -r line; do
    if [[ "$line" == *"Developer ID Application:"* && "$line" == *"($team_id)"* ]]; then
      read -r _ fingerprint _ <<< "$line"
      if [[ "$fingerprint" =~ ^[[:xdigit:]]{40}$ ]]; then
        printf '%s' "$fingerprint"
        return 0
      fi
    fi
  done < <(security find-identity -v -p codesigning 2>/dev/null)
  return 1
}

signing_identity="$(find_signing_identity || true)"

if [[ -e "$RELEASE_ENV_FILE" ]]; then
  chmod 600 "$RELEASE_ENV_FILE"
fi
umask 077
{
  printf 'NOTARY_PROFILE=%s\n' "$profile"
  if [[ -n "$signing_identity" ]]; then
    printf 'CODE_SIGN_IDENTITY=%s\n' "$signing_identity"
  fi
} > "$RELEASE_ENV_FILE"
chmod 600 "$RELEASE_ENV_FILE"

if [[ -z "$signing_identity" ]]; then
  printf 'Warning: No local Developer ID Application identity for team %s was found.\n' "$team_id" >&2
  printf '.release.env contains only the validated notary profile.\n' >&2
fi

printf 'Notarization credentials configured successfully for %s.\n' "$repository"
printf 'Local configuration written to %s with mode 600.\n' "$RELEASE_ENV_FILE"
