#!/bin/sh
# The one dispatcher behind every development command. build.sh, dev.sh, install.sh and the rest are symlinks to
# this file and run the command they are named after; `spacewise.sh <command> [arguments]` does the same by name.
# All real work, and the argument parsing, is in tool.py.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
called_as=$(basename -- "$0")

case "$called_as" in
    spacewise.sh)
        if [ "$#" -eq 0 ]; then
            echo "usage: spacewise.sh <command> [arguments]" >&2
            echo "commands: setup doctor build sign verify install relaunch dev rollback clean quit status" >&2
            exit 64
        fi
        command=$1
        shift
        ;;
    *.sh)
        command=${called_as%.sh}
        ;;
    *)
        echo "spacewise.sh: do not know which command '$called_as' stands for; call a <command>.sh link" >&2
        exit 64
        ;;
esac

exec /usr/bin/python3 "$here/tool.py" "$command" "$@"
