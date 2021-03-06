#! /bin/bash

# This script installs the Sandstorm Personal Cloud Server on your Linux
# machine. You can run the latest installer directly from the web by doing:
#
#     curl https://install.sandstorm.io | bash
#
# Alternatively, if it makes you feel better, you can download and run the
# script:
#
#     wget https://install.sandstorm.io/install.sh
#     ./install.sh

if test "x$BASH_VERSION" = x; then
  echo "Please run this script using bash, not sh or any other shell." >&2
  exit 1
fi

set -euo pipefail

fail() {
  if [ $# != 0 ]; then
    echo "$@" | fold -s >&2
  fi
  echo "*** INSTALLATION FAILED ***" >&2
  echo "Report bugs at: http://github.com/kentonv/sandstorm" >&2
  exit 1
}

if [ ! -t 1 ]; then
  fail "This script is interactive. Please run it on a terminal."
fi

# Hack: If the script is being read in from a pipe, then FD 0 is not the terminal input. But we
#   need input from the user! We just verified that FD 1 is a terminal, therefore we expect that
#   we can actually read from it instead. However, "read -u 1" in a script results in
#   "Bad file descriptor", even though it clearly isn't bad (weirdly, in an interactive shell,
#   "read -u 1" works fine). So, we clone FD 1 to FD 3 and then use that -- bash seems OK with
#   this.
exec 3<&1

prompt() {
  local VALUE

  # Hack: We read from FD 1 because when reading the script from a pipe, FD 0 is the script, not
  #   the terminal. We checked above that FD 1 is in fact a terminal, thus we can input from it
  #   just fine.
  read -u 3 -p "$1 [$2] " VALUE
  if [ x"$VALUE" == x ]; then
    VALUE=$2
  fi
  echo "$VALUE"
}

prompt-yesno() {
  while true; do
    local VALUE=$(prompt "$@")

    case $VALUE in
      y | Y | yes | YES | Yes )
        return 0
        ;;
      n | N | no | NO | No )
        return 1
        ;;
    esac

    echo "*** Please answer \"yes\" or \"no\"."
  done
}

if [ x"$(uname)" != xLinux ]; then
  fail "Sorry, the Sandstorm server only runs on Linux."
fi

if [ x"$(uname -m)" != xx86_64 ]; then
  fail "Sorry, tha Sandstorm server currently only runs on x86_64 machines."
fi

KVERSION=( $(uname -r | grep -o '^[0-9.]*' | tr . ' ') )

if (( KVERSION[0] < 3 || (KVERSION[0] == 3 && KVERSION[1] < 10) )); then
  echo "Detected Linux kernel version: $(uname -r)"
  if (( KVERSION[0] == 3 && KVERSION[1] < 5 )); then
    fail "Sorry, your kernel is too old to run Sandstorm. We recommend kernel" \
         "version 3.10 or newer (3.5 to 3.9 *might* work)."
  else
    echo "Sandstorm has only been tested on kernel version 3.10 and newer."
    prompt-yesno "We aren't sure if it will work for you. Try anyway?" no || fail
  fi
fi

which curl > /dev/null|| fail "Please install curl(1). Sandstorm uses it to download updates."
which tar > /dev/null || fail "Please install tar(1)."
which xz > /dev/null || fail "Please install xz(1). (Package may be called 'xz-utils'.)"

# ========================================================================================

if [ $(id -u) != 0 ]; then
  if [ "x$(basename $0)" == xbash ]; then
    # Probably ran like "curl https://sandstorm.io/install.sh | bash"
    echo "Re-running script as root..."
    exec sudo bash -euo pipefail -c 'curl -fs https://install.sandstorm.io | bash'
  elif [ "x$(basename $0)" == xinstall.sh -a -e $0 ]; then
    # Probably ran like "bash install.sh" or "./install.sh".
    echo "Re-running script as root..."
    exec sudo bash $0
  fi

  # Don't know how to run the script.  Let the user figure it out.
  fail "This installer needs root privileges."
fi

DIR=$(prompt "Where would you like to put Sandstorm?" /opt/sandstorm)

if [ -e $DIR ]; then
  echo "$DIR already exists. Sandstorm will assume ownership of all contents."
  prompt-yesno "Is this OK?" yes || fail
fi

mkdir -p "$DIR"
cd "$DIR"

# ========================================================================================
# Write config

writeConfig() {
  while [ $# -gt 0 ]; do
    eval echo "$1=\$$1"
    shift
  done
}

# TODO(someday): Ask what channel to use. Currently there is only one channel.
CHANNEL=dev

if [ -e sandstorm.conf ]; then
  echo "Found existing sandstorm.conf. Using it."
  . sandstorm.conf
  if [ "${SERVER_USER:+set}" != set ]; then
    fail "Existing config does not set SERVER_USER. Please fix or delete it."
  fi
  if [ "${UPDATE_CHANNEL:-none}" != none ]; then
    CHANNEL=$UPDATE_CHANNEL
  fi
else
  SERVER_USER=$(prompt "Local user account to run server under:" sandstorm)

  while [ "x$SERVER_USER" = xroot ]; do
    echo "Sandstorm cannot run as root!"
    SERVER_USER=$(prompt "Local user account to run server under:" sandstorm)
  done

  if ! id "$SERVER_USER" > /dev/null 2>&1; then
    if prompt-yesno "User account '$SERVER_USER' doesn't exist. Create it?" yes; then
      adduser --system --group "$SERVER_USER"

      echo "Note: Sandstorm's storage will only be accessible to the group '$SERVER_USER'."

      if [ x"$SUDO_USER" != x ]; then
        if prompt-yesno "Add user '$SUDO_USER' to group '$SERVER_USER'?" no; then
          usermod -a -G "$SERVER_USER" "$SUDO_USER"
          echo "Added. Don't forget that group changes only apply at next login."
        fi
      fi
    fi
  else
    echo "Note: Sandstorm's storage will only be accessible to the group '$(id -gn $SERVER_USER)'."
  fi

  PORT=$(prompt "Server main HTTP port:" "3000")

  while [ "$PORT" -lt 1024 ]; do
    echo "Ports below 1024 require root privileges. Sandstorm does not run as root."
    echo "To use port $PORT, you'll need to set up a reverse proxy like nginx that "
    echo "forwards to the internal higher-numbered port. The Sandstorm git repo "
    echo "contains an example nginx config for this."
    PORT=$(prompt "Server main HTTP port:" 3000)
  done

  MONGO_PORT=$(prompt "MongoDB port:" "$((PORT + 1))")
  if prompt-yesno "Expose to localhost only?" yes; then
    BIND_IP=127.0.0.1
    SS_HOSTNAME=localhost
  else
    BIND_IP=0.0.0.0
    SS_HOSTNAME=$(hostname -f)
  fi
  BASE_URL=$(prompt "URL users will enter in browser:" "http://$SS_HOSTNAME:$PORT")

  echo "If you want to be able to send e-mail invites and password reset messages, "
  echo "enter a mail server URL of the form 'smtp://user:pass@host:port'.  Leave "
  echo "blank if you don't care about these features."
  MAIL_URL=$(prompt "Mail URL:" "")

  if prompt-yesno "Automatically keep Sandstorm updated?" yes; then
    UPDATE_CHANNEL=$CHANNEL
  else
    UPDATE_CHANNEL=none
  fi

  writeConfig SERVER_USER PORT MONGO_PORT BIND_IP BASE_URL MAIL_URL UPDATE_CHANNEL > sandstorm.conf

  echo
  echo "Config written to $PWD/sandstorm.conf."
fi

# ========================================================================================
# Download

echo "Finding latest build for $CHANNEL channel..."
BUILD=$(curl -fs "https://install.sandstorm.io/$CHANNEL?from=0&type=install")

if [[ ! 12345 =~ ^[0-9]+$ ]]; then
  fail "Server returned invalid build number: $BUILD"
fi

do-download() {
  rm -rf sandstorm-$BUILD
  local URL="https://dl.sandstorm.io/sandstorm-$BUILD.tar.xz"
  echo "Downloading: $URL"
  curl -f "$URL" | tar Jxo

  if [ ! -e "sandstorm-$BUILD" ]; then
    fail "Bad package -- did not contain sandstorm-$BUILD directory."
  fi
}

if [ -e sandstorm-$BUILD ]; then
  echo "sandstorm-$BUILD is already present. Should I use it or re-download?"
  if ! prompt-yesno "Use existing copy?" yes; then
    do-download
  fi
else
  do-download
fi

# ========================================================================================
# Setup

GROUP=$(id -g $SERVER_USER)

# Make var directories.
mkdir -p var/{log,pid,mongo} var/sandstorm/{apps,grains,downloads}

# Set ownership of files.  We want the dirs to be root:sandstorm but the contents to be
# sandstorm:sandstorm.
chown -R $SERVER_USER:$GROUP var/{log,pid,mongo} var/sandstorm/{apps,grains,downloads}
chown root:$GROUP var/{log,pid,mongo} var/sandstorm/{apps,grains,downloads}
chmod -R g=rwX,o= var/{log,pid,mongo} var/sandstorm/{apps,grains,downloads}

# Don't allow listing grain IDs directly.  (At the moment, this is faux security since
# an attacker could just read the database, but maybe that will change someday...)
chmod g-r var/sandstorm/grains

# Create useful symlinks.
ln -sfT sandstorm-$BUILD latest
ln -sfT latest/sandstorm sandstorm

if [ -e /etc/init.d/sandstorm ]; then
  echo "WARNING: You already have a \"sandstorm\" service. Answering \"yes\" "
  echo "  here will replace it."
fi

if prompt-yesno "Start sandstorm at system boot?" yes; then
  if [ -e /etc/init.d/sandstorm ]; then
    if prompt-yesno "Shut down existing sandstorm service now?" yes; then
      service sandstorm stop || true
    fi
  fi

  cat > /etc/init.d/sandstorm << __EOF__
#! /bin/bash
### BEGIN INIT INFO
# Provides:          sandstorm
# Required-Start:    \$local_fs \$remote_fs \$networking \$syslog
# Required-Stop:     \$local_fs \$remote_fs \$networking \$syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: starts Sandstorm personal cloud server
### END INIT INFO

DESC="Sandstorm server"
DAEMON=$PWD/sandstorm

# The Sandstorm runner supports all the common init commands directly.
# We use -a to set the program name to make help text look nicer.
# This requires bash, though.
exec -a "service sandstorm" \$DAEMON "\$@"
__EOF__
  chmod +x /etc/init.d/sandstorm

  update-rc.d sandstorm defaults

  service sandstorm start

  echo "Setup complete. Your server should be running."
  echo "To learn how to control the server, run:"
  echo "  sudo service sandstorm help"
else
  echo "Setup complete. To start your server now, run:"
  echo "  sudo $PWD/sandstorm start"
  echo "To learn how to control the server, run:"
  echo "  sudo $PWD/sandstorm help"
fi
