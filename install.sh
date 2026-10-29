#!/usr/bin/env bash
# BEGIN FILETRUST INSTALL BANNER — from root singature.txt
filetrust_install_banner() {
  local banner_dir banner_version='unknown' banner_line
  banner_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -r "$banner_dir/VERSION" ]]; then
    IFS= read -r banner_version < "$banner_dir/VERSION" || [[ -n $banner_version ]]
    banner_version=${banner_version%$'\r'}
  fi
  cat <<'FILETRUST_BANNER_TOP'
███████╗██╗██╗     ███████╗████████╗██████╗ ██╗   ██╗███████╗████████╗
██╔════╝██║██║     ██╔════╝╚══██╔══╝██╔══██╗██║   ██║██╔════╝╚══██╔══╝
█████╗  ██║██║     █████╗     ██║   ██████╔╝██║   ██║███████╗   ██║
██╔══╝  ██║██║     ██╔══╝     ██║   ██╔══██╗██║   ██║╚════██║   ██║
██║     ██║███████╗███████╗   ██║   ██║  ██║╚██████╔╝███████║   ██║
╚═╝     ╚═╝╚══════╝╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝


Author: Ali Farahpoor
Company: Electra Sphere Innovations (ElectraSI.es)
Location: Barcelona, Spain
Contact: support@filetrust.io

FILETRUST_BANNER_TOP
  printf 'Version: %s %s\n' 'FTUPrice' "$banner_version"
  cat <<'FILETRUST_BANNER_BOTTOM'
Release Date: 25 October 2026

Documentation: https://docs.filetrust.io
Website: https://www.filetrust.io
FILETRUST_BANNER_BOTTOM
  printf '\n'
}
filetrust_install_banner
unset -f filetrust_install_banner
# END FILETRUST INSTALL BANNER
#
# One-command setup for the FileTrust price service.
#
#   ./install.sh             set up and keep it running: installs a service
#                            that starts with the machine and comes back if it
#                            ever stops
#   ./install.sh --no-service  set up only; you start it yourself
#   ./install.sh --user      install the service for this user rather than the
#                            machine (no root needed)
#   ./install.sh --port N    serve on this port instead of 8787
#   ./install.sh --host H    listen on this address instead of 127.0.0.1
#   ./install.sh --price P   the FTU price in USDC to publish, e.g. 0.02
#   ./install.sh --dry-run   show what would happen, change nothing
#   ./install.sh --verbose   show every check, not only what needs doing
#
# There is nothing to compile and nothing to download: the server is one file
# of standard Python. So this script's whole job is the three things that are
# easy to get wrong by hand -- your settings file, the listening address, and
# keeping it running.
#
# Keeping it running is the default, because this service runs on a machine
# nobody is watching. A crash, an out-of-memory kill, a power cut, a reboot:
# in every one of those the service is started again without anybody noticing
# it had stopped. systemd does the work -- Restart=always for a crash,
# WantedBy for a boot -- and this script writes the unit, because a service
# that needs a hand-written unit file is a service that will be missing after
# the first reboot.
#
# About the listening address. The default is 127.0.0.1, which only this
# machine can reach. That is the right default: the Explorer proxies the price
# through its own address, so the service itself never needs to be exposed.
# Pass --host 0.0.0.0 only if something on another machine must call it
# directly, and put it behind something that filters who may.

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="filetrust-ftuprice"
WANT_SERVICE=1
USER_UNIT=0
DRY_RUN=0
VERBOSE=0
WANT_PORT=""
WANT_HOST=""
WANT_PRICE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --service) WANT_SERVICE=1 ;;
    --no-service) WANT_SERVICE=0 ;;
    --user) USER_UNIT=1 ;;
    --port) shift; WANT_PORT="${1:-}" ;;
    --host) shift; WANT_HOST="${1:-}" ;;
    --price) shift; WANT_PRICE="${1:-}" ;;
    --dry-run) DRY_RUN=1 ;;
    --verbose|-v) VERBOSE=1 ;;
    -h|--help) awk 'NR>2 && /^#/ {sub(/^# ?/, ""); print; next} NR>2 {exit}' \
                 "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
step() { [ "$VERBOSE" = 1 ] && say "$*"; return 0; }
note() { [ "$VERBOSE" = 1 ] && printf '%s\n' "$*"; return 0; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

# ── Python ───────────────────────────────────────────────────────────────────
# Standard library only, so there is no virtual environment and no pip step.
# Anything that can run `python3 -c "import http.server"` can run this service.
step "Checking Python"
command -v python3 >/dev/null 2>&1 || die \
  "python3 is not installed. Install it with your package manager and run this again."
PY_OK="$(python3 -c 'import sys; print(1 if sys.version_info >= (3, 9) else 0)')"
[ "$PY_OK" = 1 ] || die "Python 3.9 or newer is needed. This machine has $(python3 -V 2>&1)."
note "  $(python3 -V 2>&1), standard library is enough"

# ── Your settings file ───────────────────────────────────────────────────────
# The repository ships config.default.json and ignores config.json, so an
# update can never overwrite the price you are publishing. New settings still
# reach you: anything in the default and missing here is added, and nothing you
# have set is touched.
step "Checking your settings file"
DEFAULT_CONFIG="$APP_DIR/config.default.json"
CONFIG="$APP_DIR/config.json"
if [ "$DRY_RUN" = 1 ]; then
  note "  would create or update config.json"
elif [ ! -f "$DEFAULT_CONFIG" ]; then
  note "  this copy ships config.json directly; nothing to merge"
elif [ ! -f "$CONFIG" ]; then
  cp "$DEFAULT_CONFIG" "$CONFIG"
  say "Your settings file"
  echo "  created config.json from the shipped defaults"
else
  FT_CONFIG="$CONFIG" FT_DEFAULT="$DEFAULT_CONFIG" python3 <<'SETTINGS_MERGE'
import json, os
from pathlib import Path

mine = Path(os.environ["FT_CONFIG"])
shipped = Path(os.environ["FT_DEFAULT"])
try:
    current = json.loads(mine.read_text(encoding="utf-8"))
    defaults = json.loads(shipped.read_text(encoding="utf-8"))
except (OSError, ValueError) as exc:
    print(f"  could not read the settings files ({exc}); leaving yours alone")
    raise SystemExit(0)

added = [k for k in defaults if k not in current]
removed = [k for k in current if k not in defaults]
if not added and not removed:
    raise SystemExit(0)
merged = {key: current.get(key, value) for key, value in defaults.items()}
mine.write_text(json.dumps(merged, indent=2) + "\n", encoding="utf-8")
if added:
    print(f"  added {len(added)} new setting(s): " + ", ".join(added[:4]))
if removed:
    print(f"  removed {len(removed)} setting(s) the service no longer reads")
SETTINGS_MERGE
fi

# What you asked for on the command line, written into the settings rather than
# remembered only for this one run. A service started by systemd later has no
# command line of yours to read.
if [ "$DRY_RUN" = 0 ] && { [ -n "$WANT_PORT" ] || [ -n "$WANT_HOST" ] || [ -n "$WANT_PRICE" ]; }; then
  FT_CONFIG="$CONFIG" FT_PORT="$WANT_PORT" FT_HOST="$WANT_HOST" FT_PRICE="$WANT_PRICE" \
  python3 <<'APPLY_ARGS'
import json, os
from pathlib import Path

path = Path(os.environ["FT_CONFIG"])
config = json.loads(path.read_text(encoding="utf-8"))
changed = []
if os.environ.get("FT_HOST"):
    config["host"] = os.environ["FT_HOST"]; changed.append("host")
if os.environ.get("FT_PORT"):
    config["port"] = int(os.environ["FT_PORT"]); changed.append("port")
if os.environ.get("FT_PRICE"):
    config.setdefault("price", {})["ftu_usdc"] = os.environ["FT_PRICE"]
    changed.append("price")
# The address the service tells others to use, kept in step with the one it
# actually listens on, so the two cannot drift apart silently.
config["public_url"] = f"http://{config.get('host', '127.0.0.1')}:{int(config.get('port', 8787))}"
path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
print("  set " + ", ".join(changed))
APPLY_ARGS
fi

HOST="$(python3 -c "import json;print(json.load(open('$CONFIG')).get('host','127.0.0.1'))" 2>/dev/null || echo 127.0.0.1)"
PORT="$(python3 -c "import json;print(int(json.load(open('$CONFIG')).get('port',8787)))" 2>/dev/null || echo 8787)"
PRICE="$(python3 -c "import json;print((json.load(open('$CONFIG')).get('price') or {}).get('ftu_usdc','0'))" 2>/dev/null || echo 0)"

mkdir -p "$APP_DIR/log"

# ── Keeping it running ───────────────────────────────────────────────────────
# Optional, and off by default: a service installed without being asked for is
# a surprise on somebody's machine.
if [ "$WANT_SERVICE" = 1 ]; then
  step "Installing the service"
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "  this machine has no systemd, so nothing can start it for you."
    warn "  start it yourself with: python3 $APP_DIR/server.py"
    WANT_SERVICE=0
  fi
fi

if [ "$WANT_SERVICE" = 1 ]; then
  # Restart=always covers a crash, an out-of-memory kill, and the service
  # simply exiting. StartLimitIntervalSec=0 stops systemd giving up after a
  # burst of failures: a service that gave up and stayed down is the one
  # outcome this is meant to prevent, and a price nobody is watching can be
  # down for days before anyone notices.
  #
  # The boot part is the [Install] target: multi-user.target for the machine,
  # default.target for a single user. Enabling lingering is what makes a user
  # service survive logging out, which is the usual way one of these quietly
  # fails to come back.
  if [ "$USER_UNIT" = 1 ]; then
    UNIT_TARGET="default.target"
  else
    UNIT_TARGET="multi-user.target"
  fi
  # A machine-wide unit installed by root would also run as root, and then
  # write its logs into a directory somebody else owns -- after which that
  # somebody can no longer manage their own install. So it runs as whoever
  # owns the directory, which is whoever installed it.
  RUN_AS=""
  if [ "$USER_UNIT" = 0 ]; then
    DIR_OWNER="$(stat -c '%U' "$APP_DIR" 2>/dev/null || true)"
    DIR_GROUP="$(stat -c '%G' "$APP_DIR" 2>/dev/null || true)"
    if [ -n "${DIR_OWNER:-}" ] && [ "$DIR_OWNER" != "root" ]; then
      RUN_AS="User=$DIR_OWNER
Group=$DIR_GROUP"
    fi
  fi
  UNIT_BODY="[Unit]
Description=FileTrust FTU price service
Documentation=https://github.com/FileTrust/Price-Simulator
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
${RUN_AS:+$RUN_AS
}WorkingDirectory=$APP_DIR
ExecStart=$(command -v python3) -u $APP_DIR/server.py --config $APP_DIR/config.json
Restart=always
RestartSec=5

[Install]
WantedBy=$UNIT_TARGET
"
  if [ "$USER_UNIT" = 1 ]; then
    UNIT_PATH="$HOME/.config/systemd/user/$SERVICE_NAME.service"
    if [ "$DRY_RUN" = 1 ]; then
      note "  would write $UNIT_PATH, enable it, and enable lingering"
    else
      mkdir -p "$(dirname "$UNIT_PATH")"
      printf '%s' "$UNIT_BODY" > "$UNIT_PATH"
      systemctl --user daemon-reload
      systemctl --user enable --now "$SERVICE_NAME" >/dev/null 2>&1 \
        || warn "  could not enable the user service; see: systemctl --user status $SERVICE_NAME"
      # Without this the service stops the moment you log out and does not
      # come back at boot, which looks exactly like it was never installed.
      if command -v loginctl >/dev/null 2>&1; then
        loginctl enable-linger "$USER" >/dev/null 2>&1 \
          || sudo loginctl enable-linger "$USER" >/dev/null 2>&1 \
          || warn "  could not enable lingering; the service will stop when you log out."
      fi
      say "Service"
      echo "  installed for $USER, starts at boot, restarts if it ever stops"
      echo "      systemctl --user status $SERVICE_NAME"
      echo "      journalctl --user -u $SERVICE_NAME -f"
    fi
  else
    UNIT_PATH="/etc/systemd/system/$SERVICE_NAME.service"
    if [ "$DRY_RUN" = 1 ]; then
      note "  would write $UNIT_PATH and enable it"
    else
      if [ "$(id -u)" = 0 ]; then
        printf '%s' "$UNIT_BODY" > "$UNIT_PATH"
        systemctl daemon-reload
        systemctl enable --now "$SERVICE_NAME" >/dev/null 2>&1 \
          || warn "  could not enable the service; see: systemctl status $SERVICE_NAME"
      elif command -v sudo >/dev/null 2>&1; then
        # -n: never stop at a password prompt. Under a launcher there is nobody
        # to type one, and a prompt on a closed stdin reads as a hang.
        printf '%s' "$UNIT_BODY" | sudo -n tee "$UNIT_PATH" >/dev/null 2>&1 \
          && sudo -n systemctl daemon-reload \
          && sudo -n systemctl enable --now "$SERVICE_NAME" >/dev/null 2>&1 \
          || true
        # Say it is installed only if it is. This used to report success
        # whatever sudo did, so an install that never wrote the unit still
        # said "starts at boot" -- and nothing started at boot.
        if [ ! -f "$UNIT_PATH" ]; then
          warn "  NOT installed: writing $UNIT_PATH needs root, and this account"
          warn "  could not get it. Run this again as root, or use --user."
          WANT_SERVICE=0
        fi
      else
        warn "  installing a machine-wide service needs root. Run this again as"
        warn "  root, or with --user to install it for $USER only."
        WANT_SERVICE=0
      fi
      if [ "$WANT_SERVICE" = 1 ]; then
        say "Service"
        echo "  installed, starts at boot, restarts if it ever stops"
        echo "      systemctl status $SERVICE_NAME"
        echo "      journalctl -u $SERVICE_NAME -f"
      fi
    fi
  fi
fi

# ── Does it answer? ──────────────────────────────────────────────────────────
# Asked for a few seconds rather than once: a service systemd has just been
# told to start is usually up within one, and reporting "not running" because
# the question was asked too early is worse than waiting.
if [ "$DRY_RUN" = 0 ]; then
  step "Checking the service answers"
  if python3 - "$HOST" "$PORT" "$WANT_SERVICE" <<'HEALTH' 2>/dev/null; then
import sys, json, time, urllib.request
host, port, just_installed = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
host = "127.0.0.1" if host in ("0.0.0.0", "::") else host
for attempt in range(10 if just_installed else 1):
    try:
        with urllib.request.urlopen(f"http://{host}:{port}/health", timeout=3) as response:
            if json.load(response).get("ok"):
                sys.exit(0)
    except Exception:
        pass
    time.sleep(1)
sys.exit(1)
HEALTH
    say "Ready"
    echo "  the price service is already running on http://$HOST:$PORT"
    echo "  publishing 1 FTU = $PRICE USDC"
    exit 0
  fi
fi

say "Ready"
if [ "$WANT_SERVICE" = 1 ]; then
  warn "  the service was installed but is not answering yet. Check it with:"
  if [ "$USER_UNIT" = 1 ]; then
    echo "      systemctl --user status $SERVICE_NAME"
  else
    echo "      systemctl status $SERVICE_NAME"
  fi
else
  echo "  start it with:"
  echo "      python3 $APP_DIR/server.py"
  echo "  then check it with:"
  echo "      curl http://$HOST:$PORT/health"
  echo "  to have it start with the machine and come back after a crash,"
  echo "  run this again without --no-service"
fi
echo "  publishing 1 FTU = $PRICE USDC  (change it in config.json, or --price)"
