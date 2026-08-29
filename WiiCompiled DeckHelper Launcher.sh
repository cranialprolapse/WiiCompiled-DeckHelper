#!/usr/bin/env bash
set -u
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GUI="$HERE/WiiCompiled DeckHelper GUI.py"
BACKEND="$HERE/Wiicompile DeckHelper.sh"

chmod +x "$GUI" "$BACKEND" 2>/dev/null || true

if python3 -c 'import tkinter' >/dev/null 2>&1; then
  exec python3 "$GUI"
fi

if command -v kdialog >/dev/null 2>&1; then
  if kdialog --title "WiiCompiled DeckHelper" --yesno \
    "The graphical dashboard cannot start because Python Tk support is missing.

DeckHelper can still run in the terminal.

Open the terminal interface instead?"; then
    exec konsole --hold -e bash "$BACKEND"
  fi
  exit 1
fi

exec konsole --hold -e bash "$BACKEND"
