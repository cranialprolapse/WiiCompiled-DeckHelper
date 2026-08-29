#!/usr/bin/env python3
import os
import shutil
import glob
import fcntl
import struct
import re
import shlex
import subprocess
import threading
import time
import signal
import tkinter as tk
import webbrowser
from tkinter import filedialog, messagebox, ttk
from pathlib import Path

HERE = Path(__file__).resolve().parent
BACKEND = HERE / "Wiicompile DeckHelper.sh"
ACTION_LOG = HERE / "Work" / "last-action.log"
APP_TITLE = "WiiCompiled DeckHelper 1.0.0"
STATE_DIR = Path.home() / ".config/wiicompile-deckhelper"
DARK_STATE = STATE_DIR / "dark_mode"
VIEW_CONSOLE_STATE = STATE_DIR / "view_console"
BACKGROUND_PID_STATE = STATE_DIR / "background_build_pid"
BACKGROUND_ACTION_STATE = STATE_DIR / "background_build_action"
CONTROLLER_DEBUG_LOG = HERE / "Work" / "controller-input.log"


def steam_running_at_startup():
    """Detect the user's Steam client once, before controller backends start.

    Steam changes how the Deck controls are exposed: with Steam closed the
    kernel hid-steam input device is normally available directly; with Steam
    open the client may replace it with uinput/virtual devices.  Keep this a
    startup snapshot so the input model cannot silently change mid-dialog.
    """
    names = {"steam", "steamwebhelper", "steamservice"}
    uid = os.getuid()
    for proc in glob.glob('/proc/[0-9]*'):
        try:
            status = Path(proc, 'status').read_text(errors='ignore')
            m = re.search(r'^Uid:\s+(\d+)', status, re.M)
            if not m or int(m.group(1)) != uid:
                continue
            comm = Path(proc, 'comm').read_text(errors='ignore').strip().lower()
            if comm in names or comm.startswith('steamwebhelper'):
                return True
            cmdline = Path(proc, 'cmdline').read_bytes().replace(b'\0', b' ').decode('utf-8', 'ignore').lower()
            if '/steam' in cmdline and ('steamwebhelper' in cmdline or 'steam -' in cmdline or cmdline.rstrip().endswith('/steam')):
                return True
        except (OSError, ValueError):
            continue
    return False


class LinuxEvdevInput:
    """Semantic Linux evdev reader for Deck/native and Steam virtual gamepads.

    Unlike joydev, evdev reports BTN_SELECT and BTN_DPAD_* as actual Linux
    input codes, so the physical Deck View button cannot alias a D-pad index.
    """
    EV_KEY = 0x01
    EV_ABS = 0x03
    BTN_SOUTH = 0x130
    BTN_EAST = 0x131
    BTN_SELECT = 0x13A
    BTN_DPAD_UP = 0x220
    BTN_DPAD_DOWN = 0x221
    BTN_DPAD_LEFT = 0x222
    BTN_DPAD_RIGHT = 0x223
    ABS_X = 0x00
    ABS_Y = 0x01
    ABS_HAT0X = 0x10
    ABS_HAT0Y = 0x11
    DEADZONE = 16000
    EVENT_STRUCT = struct.Struct('llHHi')

    def __init__(self, steam_running=False):
        self.steam_running = bool(steam_running)
        self.devices = {}
        self.device_names = {}
        self.axis_state = {}
        self.button_state = {}
        self.select_last_pressed = 0.0
        self.last_scan = 0.0
        self.debug_log = CONTROLLER_DEBUG_LOG

    def _debug(self, message):
        try:
            self.debug_log.parent.mkdir(parents=True, exist_ok=True)
            with self.debug_log.open('a', encoding='utf-8') as fh:
                fh.write(f"{time.time():.3f} {message}\n")
        except OSError:
            pass

    @staticmethod
    def _ioc(direction, type_, nr, size):
        return (direction << 30) | (size << 16) | (type_ << 8) | nr

    def _device_name(self, fd):
        try:
            buf = bytearray(256)
            # EVIOCGNAME(len) = _IOC(_IOC_READ, 'E', 0x06, len)
            request = self._ioc(2, ord('E'), 0x06, len(buf))
            fcntl.ioctl(fd, request, buf, True)
            return bytes(buf).split(b'\0', 1)[0].decode('utf-8', 'replace') or 'unknown'
        except OSError:
            return 'unknown'

    def _looks_like_controller(self, name):
        n = name.lower()
        if 'motion sensor' in n or 'keyboard' in n or 'mouse' in n:
            return False
        native = ('steam deck' in n or 'neptune' in n)
        virtual = ('steam virtual gamepad' in n or 'steam controller' in n or
                   'x-box' in n or 'xbox' in n or 'gamepad' in n)
        return (native or virtual) if self.steam_running else (native or virtual)

    def _scan(self):
        now = time.monotonic()
        if now - self.last_scan < 2.0:
            return
        self.last_scan = now
        paths = set(glob.glob('/dev/input/event*'))
        for path in list(self.devices):
            if path not in paths:
                try:
                    os.close(self.devices.pop(path))
                except OSError:
                    pass
                self.device_names.pop(path, None)
        for path in sorted(paths):
            if path in self.devices:
                continue
            try:
                fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
                name = self._device_name(fd)
                if not self._looks_like_controller(name):
                    os.close(fd)
                    continue
                self.devices[path] = fd
                self.device_names[path] = name
                self._debug(f"EVDEV_OPEN mode={'steam-open' if self.steam_running else 'steam-closed'} path={path} name={name!r}")
            except OSError as exc:
                # Permission failures are useful diagnostics, but avoid filling
                # the log with every ordinary non-controller event node.
                if getattr(exc, 'errno', None) in (13,):
                    self._debug(f"EVDEV_DENIED path={path} error={exc}")

    def has_devices(self):
        self._scan()
        return bool(self.devices)

    def poll(self):
        self._scan()
        actions = []
        for path, fd in list(self.devices.items()):
            while True:
                try:
                    data = os.read(fd, self.EVENT_STRUCT.size)
                except BlockingIOError:
                    break
                except OSError:
                    try:
                        os.close(fd)
                    except OSError:
                        pass
                    self.devices.pop(path, None)
                    self.device_names.pop(path, None)
                    break
                if len(data) != self.EVENT_STRUCT.size:
                    break
                _sec, _usec, event_type, code, value = self.EVENT_STRUCT.unpack(data)
                self._debug(f"EVDEV path={path} type={event_type} code={code} value={value}")
                if event_type == self.EV_KEY:
                    pressed = bool(value)
                    self.button_state[(path, code)] = pressed
                    if not pressed:
                        continue
                    if code == self.BTN_SELECT:
                        self.select_last_pressed = time.monotonic()
                    elif code == self.BTN_SOUTH:
                        actions.append('activate')
                    elif code == self.BTN_EAST:
                        actions.append('back_candidate')
                    elif code == self.BTN_DPAD_UP:
                        actions.append('up')
                    elif code == self.BTN_DPAD_DOWN:
                        actions.append('down')
                    elif code == self.BTN_DPAD_LEFT:
                        actions.append('left')
                    elif code == self.BTN_DPAD_RIGHT:
                        actions.append('right')
                elif event_type == self.EV_ABS and code in (self.ABS_X, self.ABS_Y, self.ABS_HAT0X, self.ABS_HAT0Y):
                    state = -1 if value <= -self.DEADZONE else (1 if value >= self.DEADZONE else 0)
                    key = (path, code)
                    previous = self.axis_state.get(key, 0)
                    self.axis_state[key] = state
                    if state == 0 or state == previous:
                        continue
                    if code in (self.ABS_Y, self.ABS_HAT0Y):
                        actions.append('up' if state < 0 else 'down')
                    else:
                        actions.append('left' if state < 0 else 'right')
        if 'back_candidate' in actions:
            # Match the proven Tk/Steam-Input safety chord: hold D-pad Left + B.
            # Native Deck input may expose the D-pad either as BTN_DPAD_LEFT or
            # as a negative X/HAT axis, so accept either representation.
            left_button_held = any(
                code == self.BTN_DPAD_LEFT and pressed
                for (_path, code), pressed in self.button_state.items()
            )
            left_axis_held = any(
                code in (self.ABS_X, self.ABS_HAT0X) and state < 0
                for (_path, code), state in self.axis_state.items()
            )
            actions = [
                ('exit_chord' if (left_button_held or left_axis_held) else 'back')
                if action == 'back_candidate' else action
                for action in actions
            ]
        return actions



class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(APP_TITLE)
        self.geometry("900x760")
        self.minsize(760, 620)
        self.configure(padx=0, pady=0)
        # Route the title-bar X through the exact same active-install guard as
        # the in-app Close button. Tk's default WM_DELETE_WINDOW behavior
        # destroys the window immediately, which previously orphaned builds.
        self.protocol("WM_DELETE_WINDOW", self.on_close)

        STATE_DIR.mkdir(parents=True, exist_ok=True)
        if not DARK_STATE.exists():
            DARK_STATE.write_text("on")
        self.dark_var = tk.BooleanVar(value=DARK_STATE.read_text().strip().lower() != "off")
        # Console visibility is intentionally session-only. Always begin hidden
        # so a previous run cannot surprise the user with an open terminal.
        VIEW_CONSOLE_STATE.write_text("off")
        self.view_console_var = tk.BooleanVar(value=False)
        self.action_running = False
        self.active_process = None
        self.active_action = None
        self.console_viewer_process = None
        self.action_started_at = None
        self.closing_after_cancel = False
        self.external_background_pid = None
        # RC20: use the keyboard events Steam Input already
        # delivers to Tk on Steam Deck (D-pad=arrows, A=Return, B=Escape).
        # This intentionally avoids /dev/input permissions, joydev ordering,
        # virtual-device duplication, and extra controller dependencies.
        self.controller_combo_active = None
        self.controller_combo_original = None
        # Steam normally translates Deck controls into Tk keyboard events.
        # When Steam is closed (including DeckHelper's own shortcut-edit window),
        # poll the native Deck evdev presentation as a narrow fallback.
        self.native_controller = LinuxEvdevInput(steam_running=False)
        self._native_controller_was_active = False

        self.style = ttk.Style(self)
        try:
            self.style.theme_use("clam")
        except Exception:
            pass

        self._build_ui()
        self.apply_theme()
        self._setup_controller_navigation()
        self.after(80, self._poll_native_controller_fallback)
        self.after(100, self.startup)

    def _build_ui(self):
        # Scrollable main viewport. This is intentionally a real Canvas-backed
        # scroll area so the Deck UI can keep comfortable spacing without
        # hiding Build/Steam controls below an unreachable fold.
        shell = ttk.Frame(self, style="Root.TFrame")
        shell.pack(fill="both", expand=True)

        self.main_canvas = tk.Canvas(
            shell,
            highlightthickness=0,
            borderwidth=0
        )
        self.main_scrollbar = ttk.Scrollbar(
            shell,
            orient="vertical",
            command=self.main_canvas.yview
        )
        self.main_canvas.configure(yscrollcommand=self.main_scrollbar.set)

        self.main_scrollbar.pack(side="right", fill="y")
        self.main_canvas.pack(side="left", fill="both", expand=True)

        self.content = ttk.Frame(self.main_canvas, style="Root.TFrame")
        self.content_window = self.main_canvas.create_window(
            (0, 0), window=self.content, anchor="nw"
        )

        def sync_scrollregion(event=None):
            self.main_canvas.configure(scrollregion=self.main_canvas.bbox("all"))

        def sync_content_width(event):
            self.main_canvas.itemconfigure(self.content_window, width=event.width)

        self.content.bind("<Configure>", sync_scrollregion)
        self.main_canvas.bind("<Configure>", sync_content_width)

        def wheel_scroll(event):
            if getattr(event, "num", None) == 4:
                self.main_canvas.yview_scroll(-3, "units")
            elif getattr(event, "num", None) == 5:
                self.main_canvas.yview_scroll(3, "units")
            elif getattr(event, "delta", 0):
                direction = -1 if event.delta > 0 else 1
                self.main_canvas.yview_scroll(direction * 3, "units")
            return "break"

        # KDE/X11 commonly uses Button-4/5; MouseWheel covers other Tk setups.
        # ttk.Combobox has a class-level wheel binding that changes the selected
        # value before bind_all() runs.  Comboboxes therefore get an earlier
        # widget-level binding below so wheel input always scrolls the page and
        # never silently changes installer settings.
        self.bind_all("<Button-4>", wheel_scroll)
        self.bind_all("<Button-5>", wheel_scroll)
        self.bind_all("<MouseWheel>", wheel_scroll)

        # Replace ttk's class-level wheel bindings too. A widget binding alone
        # is not sufficiently defensive across Tk/KDE builds because the class
        # binding can still move the readonly selection. For DeckHelper, wheel
        # input over a combobox *always* belongs to the page. Choices change
        # only by deliberate click/keyboard interaction.
        for sequence in ("<Button-4>", "<Button-5>", "<MouseWheel>"):
            self.bind_class("TCombobox", sequence, wheel_scroll)

        def make_combobox_wheel_safe(combo):
            combo.bind("<Button-4>", wheel_scroll)
            combo.bind("<Button-5>", wheel_scroll)
            combo.bind("<MouseWheel>", wheel_scroll)

        header = ttk.Frame(self.content, style="Root.TFrame")
        header.pack(fill="x", padx=18, pady=(10, 10))

        title = ttk.Label(header, text="WiiCompiled DeckHelper", style="Title.TLabel")
        title.pack()
        ttk.Label(
            header,
            text="Native Mario Kart Wii setup for Steam Deck",
            style="Subtitle.TLabel"
        ).pack(pady=(0, 1))
        ttk.Label(
            header,
            text="1.0.0  •  maintained by cranialprolapse",
            style="Detail.TLabel"
        ).pack(pady=(0, 0))

        # Top-right dark mode switch.
        topbar = ttk.Frame(self.content, style="Root.TFrame")
        topbar.place(relx=1.0, x=-18, y=12, anchor="ne")
        self.dark_toggle = ttk.Checkbutton(
            topbar,
            text="Dark Mode",
            variable=self.dark_var,
            command=self.toggle_dark_mode,
            style="Switch.TCheckbutton"
        )
        self.dark_toggle.pack()

        self.game_var = tk.StringVar(value="Checking for verified PAL Mario Kart Wii…")
        self.game_detail_var = tk.StringVar(value="")
        self.save_var = tk.StringVar(value="Not scanned yet")
        self.status_var = tk.StringVar(value="Starting…")
        self.sgdb_key_var = tk.StringVar(value="")
        self.auto_art_var = tk.BooleanVar(value=True)

        gamef = self._card("GAME")
        self.game_label = ttk.Label(
            gamef, textvariable=self.game_var,
            wraplength=730, justify="left", style="Body.TLabel"
        )
        self.game_label.pack(anchor="w", padx=14, pady=(4, 2))
        ttk.Label(
            gamef, textvariable=self.game_detail_var,
            wraplength=730, justify="left", style="Detail.TLabel"
        ).pack(anchor="w", padx=14, pady=(0, 10))

        mig = self._card("SAVE & MII MIGRATION")
        self.save_label = ttk.Label(mig, textvariable=self.save_var, style="Body.TLabel")
        self.save_label.pack(anchor="w", padx=14, pady=(4, 6))
        r = ttk.Frame(mig, style="Card.TFrame")
        r.pack(fill="x", padx=12, pady=(0, 10))
        self.scan_btn = ttk.Button(
            r, text="Scan for Saves + Miis",
            command=self.scan_migration,
            style="Secondary.TButton"
        )
        self.scan_btn.pack(side="left", expand=True, fill="x", padx=(0, 6), ipady=1)
        self.import_btn = ttk.Button(
            r, text="Import Detected Data",
            command=self.import_data,
            style="Secondary.TButton"
        )
        self.import_btn.pack(side="left", expand=True, fill="x", padx=(6, 0), ipady=1)

        sysf = self._card("SYSTEM")
        sr = ttk.Frame(sysf, style="Card.TFrame")
        sr.pack(fill="x", padx=12, pady=(0, 10))
        self.verify_btn = ttk.Button(
            sr, text="Verify / Repair Dependencies",
            command=lambda: self.run_terminal("verify", "Verify / Repair Dependencies"),
            style="Secondary.TButton"
        )
        self.verify_btn.pack(side="left", expand=True, fill="x", padx=(0, 6), ipady=1)
        self.repair = ttk.Combobox(
            sr, state="readonly",
            values=("Ask before sudo", "Auto repair with sudo", "No sudo / check only")
        )
        self.repair.current(0)
        self.repair.bind("<<ComboboxSelected>>", self.set_repair_mode)
        make_combobox_wheel_safe(self.repair)
        self.repair.pack(side="left", expand=True, fill="x", padx=(6, 0), ipady=1)

        art = self._card("STEAM ARTWORK")
        ttk.Label(
            art,
            text="When “Add to Steam” is selected, DeckHelper automatically adds the shortcut and applies GameTDB + SteamGridDB artwork.",
            wraplength=730, justify="left", style="Detail.TLabel"
        ).pack(anchor="w", padx=14, pady=(0, 6))

        ar = ttk.Frame(art, style="Card.TFrame")
        ar.pack(fill="x", padx=12, pady=(0, 7))
        self.sgdb_entry = ttk.Entry(ar, textvariable=self.sgdb_key_var, show="•")
        self.sgdb_entry.pack(fill="x", pady=(0, 7))

        api_buttons = ttk.Frame(ar, style="Card.TFrame")
        api_buttons.pack(fill="x")
        ttk.Button(
            api_buttons, text="Save API Key",
            command=self.save_sgdb_key,
            style="Secondary.TButton"
        ).pack(side="left", expand=True, fill="x", padx=(0, 5))
        ttk.Button(
            api_buttons, text="Get Free API Key",
            command=lambda: webbrowser.open("https://www.steamgriddb.com/profile/preferences/api"),
            style="Ghost.TButton"
        ).pack(side="left", expand=True, fill="x", padx=(5, 0))

        ar2 = ttk.Frame(art, style="Card.TFrame")
        ar2.pack(fill="x", padx=12, pady=(0, 10))
        ttk.Label(
            ar2,
            text="Artwork is automatic whenever Steam integration is enabled.",
            style="Detail.TLabel"
        ).pack(anchor="w")

        build = self._card("BUILD")
        br = ttk.Frame(build, style="Card.TFrame")
        br.pack(fill="x", padx=12, pady=(0, 8))
        self.base_btn = ttk.Button(
            br, text="Install Base Game",
            command=lambda: self.run_terminal("build-base", "Build Base Mario Kart Wii"),
            style="Secondary.TButton"
        )
        self.base_btn.pack(side="left", expand=True, fill="x", padx=(0, 6), ipady=2)

        self.both_btn = ttk.Button(
            build, text="Install Base + Retro Rewind",
            command=lambda: self.run_terminal("build-both", "Install Base + Retro Rewind"),
            style="Primary.TButton"
        )
        self.both_btn.pack(fill="x", padx=12, pady=(0, 8), ipady=5)

        self.resume_btn = ttk.Button(
            build,
            text="Resume Previous Installation",
            command=lambda: self.run_terminal("resume-install", "Resume Previous Installation"),
            style="Secondary.TButton"
        )
        self.resume_btn.pack(fill="x", padx=12, pady=(0, 8), ipady=2)
        self.resume_btn.configure(state="disabled")

        self.repair_steam_btn = ttk.Button(
            build,
            text="Repair Steam Shortcuts + Artwork",
            command=lambda: self.run_terminal(
                "repair-steam",
                "Repair Steam Shortcuts + Artwork"
            ),
            style="Secondary.TButton"
        )
        self.repair_steam_btn.pack(fill="x", padx=12, pady=(0, 8), ipady=2)

        console_row = ttk.Frame(build, style="Card.TFrame")
        console_row.pack(fill="x", padx=12, pady=(0, 8))
        self.console_toggle = ttk.Button(
            console_row,
            text="Hide Console" if self.view_console_var.get() else "View Console",
            command=self.toggle_view_console,
            style="Secondary.TButton",
        )
        self.console_toggle.pack(fill="x", ipady=2)

        self.steam_mode_var = tk.StringVar(value="Add to Steam")
        steam_row = ttk.Frame(build, style="Card.TFrame")
        steam_row.pack(fill="x", padx=12, pady=(0, 10))
        ttk.Label(
            steam_row,
            text="Steam Integration",
            style="Body.TLabel"
        ).pack(side="left", padx=(0, 8))

        self.steam_combo = ttk.Combobox(
            steam_row,
            textvariable=self.steam_mode_var,
            state="readonly",
            values=[
                "Add to Steam",
                "Do Not Add to Steam",
            ],
            width=28,
        )
        self.steam_combo.pack(side="right", fill="x", expand=True)
        self.steam_combo.bind("<<ComboboxSelected>>", self.set_steam_mode)
        make_combobox_wheel_safe(self.steam_combo)

        bottom = ttk.Frame(self.content, style="Root.TFrame")
        bottom.pack(fill="x", padx=18, pady=(10, 4))
        ttk.Button(
            bottom, text="Browse for Game…",
            command=self.browse_game,
            style="Ghost.TButton"
        ).pack(side="left", padx=(0, 6))
        ttk.Button(
            bottom, text="Scan for Game",
            command=self.scan_game_again,
            style="Ghost.TButton"
        ).pack(side="left", padx=(0, 6))
        ttk.Button(
            bottom, text="Close",
            command=self.on_close,
            style="Ghost.TButton"
        ).pack(side="right")

        status_card = ttk.Frame(self.content, style="Status.TFrame")
        status_card.pack(fill="x", padx=18, pady=(5, 16))
        self.progress = ttk.Progressbar(status_card, mode="determinate", maximum=100)
        self.progress.pack(fill="x", padx=10, pady=(7, 3))
        ttk.Label(
            status_card,
            textvariable=self.status_var,
            style="Status.TLabel"
        ).pack(anchor="w", padx=10, pady=(0, 6))

    def _poll_native_controller_fallback(self):
        """Use native Deck input only while Steam is not providing Desktop input."""
        try:
            steam_open = steam_running_at_startup()
            if not steam_open:
                actions = self.native_controller.poll()
                for action in actions:
                    self._dispatch_controller_action(action)
                self._native_controller_was_active = True
            else:
                self._native_controller_was_active = False
        except Exception as exc:
            try:
                CONTROLLER_DEBUG_LOG.parent.mkdir(parents=True, exist_ok=True)
                with CONTROLLER_DEBUG_LOG.open('a', encoding='utf-8') as fh:
                    fh.write(f"{time.time():.3f} NATIVE_FALLBACK_ERROR {exc!r}\n")
            except OSError:
                pass
        finally:
            try:
                self.after(80, self._poll_native_controller_fallback)
            except tk.TclError:
                pass

    def _setup_controller_navigation(self):
        # RC20 controller path: Steam Input's Desktop layout
        # already gives Tk exactly what DeckHelper needs on real Deck hardware:
        # D-pad -> arrow keys, A -> Return, B -> Escape. B is contextual only: it
        # in Tk itself and intercept selector key bindings before ttk can mutate
        # a combobox just because the user is navigating past it.
        self.bind_all("<Up>", lambda e: self._controller_key_action("up"))
        self.bind_all("<Down>", lambda e: self._controller_key_action("down"))
        self.bind_all("<Right>", lambda e: self._controller_key_action("right"))
        self.bind_all("<Return>", lambda e: self._controller_key_action("activate"))
        # Safe main-window exit chord: hold D-pad Left, then press B. Both are
        # keyboard events confirmed on Deck hardware (Left + Escape), unlike View.
        # B by itself remains inert on the main window.
        self._controller_left_held = False
        self.bind_all("<KeyPress-Left>", self._controller_left_press)
        self.bind_all("<KeyRelease-Left>", self._controller_left_release)
        self.bind_all("<Escape>", self._controller_escape_press)

        for combo in (self.repair, self.steam_combo):
            combo.bind("<Up>", lambda e: self._controller_key_action("up"), add=False)
            combo.bind("<Down>", lambda e: self._controller_key_action("down"), add=False)
            combo.bind("<KeyPress-Left>", self._controller_left_press, add=False)
            combo.bind("<Right>", lambda e: self._controller_key_action("right"), add=False)
            combo.bind("<Return>", lambda e: self._controller_key_action("activate"), add=False)
            combo.bind("<Escape>", lambda e: self._controller_key_action("back"), add=False)
            # Block the native keyboard popup shortcuts as well. Mouse/touch can
            # still open the dropdown normally.
            combo.bind("<Alt-Down>", lambda e: "break", add=False)
            combo.bind("<F4>", lambda e: "break", add=False)


    def _controller_left_press(self, event=None):
        # Navigate normally on the initial Left press, then remember that Left
        # is physically held so Left+B can request the normal guarded close.
        if not self._controller_left_held:
            self._controller_left_held = True
            self._dispatch_controller_action("left")
        return "break"

    def _controller_left_release(self, event=None):
        self._controller_left_held = False
        return "break"

    def _controller_escape_press(self, event=None):
        if self._controller_scope() is self and self._controller_left_held:
            self._controller_left_held = False
            self._dispatch_controller_action("exit_chord")
            return "break"
        return self._controller_key_action("back")

    def _controller_key_action(self, action):
        # Steam Input's Desktop layout already translates the physical Deck
        # controls into normal keyboard events before Tk sees them. Keep the
        # controller path at that layer: arrows navigate, A/Return activates,
        # and B/Escape backs out or closes.
        self._dispatch_controller_action(action)
        return "break"

    def _dispatch_controller_action(self, action):
        if action in ("up", "down", "left", "right"):
            self._controller_direction(action)
        elif action == "activate":
            self._controller_activate()
        elif action == "back":
            self._controller_back()
        elif action == "exit_chord":
            self.on_close()

    def _controller_scope(self):
        try:
            focus = self.focus_get()
            if focus is not None:
                return focus.winfo_toplevel()
        except tk.TclError:
            pass
        return self

    def _controller_widgets(self):
        scope = self._controller_scope()
        widgets = []
        interactive = (ttk.Button, ttk.Combobox, ttk.Checkbutton, ttk.Entry)

        def walk(parent):
            for child in parent.winfo_children():
                if isinstance(child, interactive):
                    try:
                        state = str(child.cget("state")) if "state" in child.keys() else "normal"
                        if child.winfo_ismapped() and state != "disabled":
                            widgets.append(child)
                    except tk.TclError:
                        pass
                walk(child)
        walk(scope)
        return widgets

    def _ensure_controller_focus_visible(self, widget):
        if widget.winfo_toplevel() is not self:
            return
        try:
            self.update_idletasks()
            total = max(1, self.content.winfo_height())
            top = widget.winfo_rooty() - self.content.winfo_rooty()
            bottom = top + widget.winfo_height()
            y0, y1 = self.main_canvas.yview()
            view_top, view_bottom = y0 * total, y1 * total
            margin = 35
            if top < view_top + margin:
                self.main_canvas.yview_moveto(max(0.0, (top - margin) / total))
            elif bottom > view_bottom - margin:
                visible = max(1, view_bottom - view_top)
                target = max(0, bottom + margin - visible)
                self.main_canvas.yview_moveto(min(1.0, target / total))
        except tk.TclError:
            pass

    @staticmethod
    def _controller_center(widget):
        return (
            widget.winfo_rootx() + widget.winfo_width() / 2.0,
            widget.winfo_rooty() + widget.winfo_height() / 2.0,
        )

    def _controller_direction(self, direction):
        # While a selector has explicitly been opened with A, only vertical
        # input changes its candidate value. Outside that mode, ALL four D-pad
        # directions are navigation only and never mutate a control.
        widgets = self._controller_widgets()
        if not widgets:
            return
        self.update_idletasks()
        current = self.focus_get()
        if current not in widgets:
            target = widgets[0]
            target.focus_set()
            self._ensure_controller_focus_visible(target)
            return

        cx, cy = self._controller_center(current)
        current_h = max(1, current.winfo_height())
        candidates = []
        for widget in widgets:
            if widget is current:
                continue
            x, y = self._controller_center(widget)
            dx, dy = x - cx, y - cy
            other_h = max(1, widget.winfo_height())

            if direction in ("left", "right"):
                # Horizontal input is STRICTLY same-row navigation.  RC19.5's
                # weighted geometry could decide that a diagonally lower widget
                # was 'more right', which made the interface feel random.
                # Consider two controls to share a row only when their vertical
                # centers overlap within roughly half of their combined height.
                same_row_tolerance = max(10.0, (current_h + other_h) * 0.55)
                if abs(dy) > same_row_tolerance:
                    continue
                if direction == "left" and dx < -2:
                    candidates.append((-dx, abs(dy), widget))
                elif direction == "right" and dx > 2:
                    candidates.append((dx, abs(dy), widget))
            else:
                # Vertical input is likewise strictly vertical: only controls
                # above/below are eligible.  Prefer the nearest visual row, then
                # the control in that row whose horizontal center is closest.
                if direction == "up" and dy < -2:
                    candidates.append((-dy, abs(dx), widget))
                elif direction == "down" and dy > 2:
                    candidates.append((dy, abs(dx), widget))

        if not candidates:
            return
        target = min(candidates, key=lambda item: item[:2])[2]
        target.focus_set()
        self._ensure_controller_focus_visible(target)

    def _controller_combo_begin(self, widget):
        # A on a selector opens a real controller-friendly choice list instead
        # of silently cycling the combobox value. All choices are visible at
        # once, which mirrors Steam's settings UX much better on Deck.
        values = list(widget.cget("values"))
        if not values:
            return

        popup = tk.Toplevel(self)
        popup.title("Choose option")
        popup.transient(self)
        popup.resizable(False, False)
        # Match the active DeckHelper palette instead of exposing Tk/KDE's
        # default bright Toplevel background around the selector choices.
        popup_bg = "#1b2838" if self.dark_var.get() else "#ffffff"
        popup.configure(background=popup_bg, padx=14, pady=14)
        popup.protocol("WM_DELETE_WINDOW", popup.destroy)
        popup.bind("<Escape>", lambda e: (popup.destroy(), "break")[1])

        ttk.Label(popup, text="Choose an option", style="Section.TLabel").pack(anchor="w", pady=(0, 8))
        current = widget.current()
        buttons = []

        def choose(index):
            widget.current(index)
            widget.event_generate("<<ComboboxSelected>>")
            try:
                popup.grab_release()
            except tk.TclError:
                pass
            popup.destroy()
            widget.focus_set()

        for index, value in enumerate(values):
            label = str(value)
            if index == current:
                label = f"✓  {label}"
            button = ttk.Button(
                popup,
                text=label,
                style="ControllerChoice.TButton",
                command=lambda i=index: choose(i),
            )
            button.pack(fill="x", pady=3, ipadx=18, ipady=5)
            buttons.append(button)

        popup.update_idletasks()
        width = max(300, popup.winfo_reqwidth())
        height = popup.winfo_reqheight()
        x = self.winfo_rootx() + max(0, (self.winfo_width() - width) // 2)
        y = self.winfo_rooty() + max(0, (self.winfo_height() - height) // 2)
        popup.geometry(f"{width}x{height}+{x}+{y}")
        popup.grab_set()
        target = buttons[current] if 0 <= current < len(buttons) else buttons[0]
        target.focus_set()

    def _controller_combo_step(self, direction):
        # Retained as a no-op compatibility hook. RC19.7 uses a visible popup
        # choice list instead of hidden in-place combobox scrolling.
        return

    def _controller_combo_finish(self, commit):
        self.controller_combo_active = None
        self.controller_combo_original = None


    def _controller_activate(self):
        widget = self.focus_get()
        if isinstance(widget, (ttk.Button, ttk.Checkbutton)):
            try:
                widget.invoke()
            except tk.TclError:
                pass
        elif isinstance(widget, ttk.Combobox):
            self._controller_combo_begin(widget)
        elif isinstance(widget, ttk.Entry):
            widget.focus_set()

    def _controller_back(self):
        scope = self._controller_scope()
        if scope is not self:
            try:
                scope.event_generate("<Escape>")
            except tk.TclError:
                pass
            return
        # RC19.16: B/Escape is intentionally inert on the main window. It is
        # only Back/Cancel when a child dialog/popup is active. This prevents a
        # normal controller press from ever exiting DeckHelper or interrupting
        # an installation. The title-bar X / explicit Close path remains guarded.
        return

    def _card(self, heading):
        outer = ttk.Frame(self.content, style="Card.TFrame")
        outer.pack(fill="x", padx=18, pady=6)
        ttk.Label(outer, text=heading, style="Section.TLabel").pack(anchor="w", padx=14, pady=(9, 3))
        return outer

    def apply_theme(self):
        dark = self.dark_var.get()

        if dark:
            # Steam-inspired body: deep blue/charcoal panels with Steam blue accent.
            bg = "#171d25"
            card = "#1b2838"
            card2 = "#22384a"
            fg = "#d6d7d8"
            sub = "#8f98a0"
            border = "#2a475e"
            accent = "#66c0f4"
            accent_active = "#7fd0ff"
            controller_focus_bg = "#66c0f4"
            controller_focus_fg = "#10212d"
            primary_bg = "#287aa9"
            primary_fg = "#eaf6ff"

            # Keep every normal control inside the same Steam-like dark palette.
            # Bright native-looking fields/buttons were visually harsh against the
            # dark cards, especially on a handheld display.
            control_bg = "#22384a"
            control_fg = "#e5e8eb"
            control_border = "#2a475e"
            control_hover = "#2d4d66"
            control_pressed = "#1a2d3b"
            control_disabled = "#1b2b38"
            control_disabled_fg = "#687783"
            progress_trough = "#101820"
        else:
            bg = "#f3f4f6"
            card = "#ffffff"
            card2 = "#f8f9fb"
            fg = "#1b1f24"
            sub = "#5f6670"
            border = "#d7dbe0"
            accent = "#2f6fed"
            accent_active = "#4a82ef"
            controller_focus_bg = "#2f6fed"
            controller_focus_fg = "#ffffff"
            primary_bg = accent
            primary_fg = "#ffffff"
            control_bg = "#ffffff"
            control_fg = "#1b1f24"
            control_border = "#b9c0c7"
            control_hover = "#f7f8fa"
            control_pressed = "#e3e6ea"
            control_disabled = "#e8eaed"
            control_disabled_fg = "#8a9097"
            progress_trough = "#d7dce0"

        self.configure(bg=bg)
        if hasattr(self, "main_canvas"):
            self.main_canvas.configure(bg=bg)

        self.style.configure(
            "ControllerChoice.TButton",
            background=control_bg, foreground=control_fg,
            borderwidth=1, relief="raised",
            bordercolor=control_border, lightcolor=control_hover, darkcolor=control_border,
            padding=(12, 8),
        )
        self.style.map(
            "ControllerChoice.TButton",
            background=[("pressed", control_pressed), ("focus", controller_focus_bg), ("active", control_hover)],
            foreground=[("focus", controller_focus_fg)],
            bordercolor=[("focus", accent_active)],
            lightcolor=[("focus", accent_active)],
            darkcolor=[("focus", accent_active)],
        )
        # B's exit hint should look like a Steam toast, not a native light-mode
        # notification floating over the dark interface.
        self.style.configure(
            "ControllerHint.TLabel",
            background=card2,
            foreground=accent if dark else fg,
            borderwidth=1, relief="solid",
            bordercolor=border,
            font=("TkDefaultFont", 10, "bold"),
        )
        self.style.configure("Root.TFrame", background=bg)
        self.style.configure("Card.TFrame", background=card, relief="flat")
        self.style.configure("Status.TFrame", background=card2, relief="flat")

        self.style.configure("Title.TLabel", background=bg, foreground=fg, font=("Sans", 22, "bold"))
        self.style.configure("Subtitle.TLabel", background=bg, foreground=sub, font=("Sans", 10))
        self.style.configure("Section.TLabel", background=card, foreground=sub, font=("Sans", 10, "bold"))
        self.style.configure("Body.TLabel", background=card, foreground=fg, font=("Sans", 10))
        self.style.configure("Detail.TLabel", background=card, foreground=sub, font=("Sans", 9))
        self.style.configure("Status.TLabel", background=card2, foreground=sub, font=("Sans", 10))

        # Main Steam-blue action.
        self.style.configure(
            "Primary.TButton",
            background=primary_bg, foreground=primary_fg,
            borderwidth=0, focusthickness=0,
            font=("Sans", 11, "bold"), padding=(10, 6)
        )
        self.style.map(
            "Primary.TButton",
            background=[
                ("disabled", control_disabled),
                ("pressed", accent_active),
                ("focus", accent_active),
                ("active", accent_active),
            ],
            foreground=[("disabled", control_disabled_fg), ("focus", "#10212d" if dark else "#ffffff")]
        )

        # Secondary/ghost controls follow the active palette rather than
        # falling back to bright platform-native widgets in dark mode.
        self.style.configure(
            "Secondary.TButton",
            background=control_bg, foreground=control_fg,
            borderwidth=1, relief="raised",
            bordercolor=control_border, lightcolor=control_hover,
            darkcolor=control_border,
            font=("Sans", 10), padding=(10, 7)
        )
        self.style.map(
            "Secondary.TButton",
            background=[
                ("disabled", control_disabled),
                ("pressed", control_pressed),
                ("focus", controller_focus_bg),
                ("active", control_hover),
            ],
            foreground=[("disabled", control_disabled_fg), ("focus", controller_focus_fg)],
            bordercolor=[("focus", accent_active)],
            lightcolor=[("focus", accent_active)],
            darkcolor=[("focus", accent_active)]
        )

        self.style.configure(
            "Ghost.TButton",
            background=control_bg, foreground=control_fg,
            borderwidth=1, relief="raised",
            bordercolor=control_border, lightcolor=control_hover,
            darkcolor=control_border,
            font=("Sans", 10), padding=(8, 5)
        )
        self.style.map(
            "Ghost.TButton",
            background=[
                ("disabled", control_disabled),
                ("pressed", control_pressed),
                ("focus", controller_focus_bg),
                ("active", control_hover),
            ],
            foreground=[("disabled", control_disabled_fg), ("focus", controller_focus_fg)],
            bordercolor=[("focus", accent_active)],
            lightcolor=[("focus", accent_active)],
            darkcolor=[("focus", accent_active)]
        )

        # Checkboxes still visually belong to the dark cards.
        self.style.configure(
            "Body.TCheckbutton",
            background=card, foreground=fg,
            font=("Sans", 10)
        )
        self.style.map(
            "Body.TCheckbutton",
            background=[("focus", controller_focus_bg), ("active", card)],
            foreground=[("focus", controller_focus_fg), ("active", fg)]
        )
        self.style.configure(
            "Switch.TCheckbutton",
            background=bg, foreground=sub,
            font=("Sans", 9)
        )
        self.style.map(
            "Switch.TCheckbutton",
            background=[("focus", controller_focus_bg), ("active", bg)],
            foreground=[("focus", controller_focus_fg), ("active", fg)]
        )

        self.style.configure(
            "TCombobox",
            fieldbackground=control_bg,
            background=control_bg,
            foreground=control_fg,
            arrowcolor=control_fg,
            bordercolor=control_border,
            lightcolor=control_hover,
            darkcolor=control_border,
            padding=5
        )
        self.style.map(
            "TCombobox",
            fieldbackground=[("focus", controller_focus_bg), ("readonly", control_bg), ("disabled", control_disabled)],
            background=[("focus", controller_focus_bg), ("readonly", control_bg), ("active", control_hover)],
            foreground=[("focus", controller_focus_fg), ("readonly", control_fg), ("disabled", control_disabled_fg)],
            selectbackground=[("focus", controller_focus_bg), ("readonly", control_bg)],
            selectforeground=[("focus", controller_focus_fg), ("readonly", control_fg)],
            arrowcolor=[("focus", controller_focus_fg), ("readonly", control_fg), ("disabled", control_disabled_fg)],
            bordercolor=[("focus", accent_active)]
        )

        # The pop-down list is a Tk Listbox rather than a ttk element, so style
        # it separately or KDE/Tk can leave a bright white menu in dark mode.
        self.option_add("*TCombobox*Listbox.background", control_bg)
        self.option_add("*TCombobox*Listbox.foreground", control_fg)
        self.option_add("*TCombobox*Listbox.selectBackground", accent)
        self.option_add("*TCombobox*Listbox.selectForeground", "#10212d" if dark else "#ffffff")

        self.style.configure(
            "TEntry",
            fieldbackground=control_bg,
            background=control_bg,
            foreground=control_fg,
            bordercolor=control_border,
            lightcolor=control_border,
            darkcolor=control_border,
            insertcolor=control_fg,
            selectbackground=accent,
            selectforeground="#10212d" if dark else "#ffffff",
            padding=5
        )
        self.style.map(
            "TEntry",
            fieldbackground=[("focus", controller_focus_bg), ("disabled", control_disabled)],
            foreground=[("focus", controller_focus_fg), ("disabled", control_disabled_fg)],
            bordercolor=[("focus", accent_active)]
        )

        # Light bar with Steam-blue fill instead of an all-dark progress widget.
        self.style.configure(
            "Horizontal.TProgressbar",
            troughcolor=progress_trough,
            background=accent,
            bordercolor=control_border,
            lightcolor=accent,
            darkcolor=accent
        )

    def toggle_dark_mode(self):
        DARK_STATE.write_text("on" if self.dark_var.get() else "off")
        self.apply_theme()

    def _console_viewer_is_open(self):
        return self.console_viewer_process is not None and self.console_viewer_process.poll() is None

    def _open_console_viewer(self):
        """Open a detachable live view of the current hidden action log."""
        if self._console_viewer_is_open():
            return
        p = self.active_process
        own_running = p is not None and p.poll() is None
        attached_running = self._background_process_alive()
        if not own_running and not attached_running:
            return
        try:
            ACTION_LOG.parent.mkdir(parents=True, exist_ok=True)
            ACTION_LOG.touch(exist_ok=True)
            log_q = shlex.quote(str(ACTION_LOG))
            cmd = (
                'clear; '
                'echo "============================================================"; '
                'echo "           WiiCompiled DeckHelper - Live Console"; '
                'echo "============================================================"; '
                'echo; echo "This window only follows installer output."; '
                'echo "Closing it will NOT stop the installation."; echo; '
                f'exec tail -n 200 -F {log_q}'
            )
            self.console_viewer_process = subprocess.Popen([
                "konsole", "--title", f"{APP_TITLE} - Live Console",
                "-e", "bash", "-lc", cmd
            ])
        except Exception as e:
            self.console_viewer_process = None
            self.view_console_var.set(False)
            VIEW_CONSOLE_STATE.write_text("off")
            self._update_console_button()
            messagebox.showerror(APP_TITLE, f"Could not open live console:\n{e}")

    def _close_console_viewer(self):
        p = self.console_viewer_process
        self.console_viewer_process = None
        if p is None or p.poll() is not None:
            return
        try:
            p.terminate()
        except Exception:
            pass

    def _update_console_button(self):
        try:
            self.console_toggle.configure(
                text="Hide Console" if self.view_console_var.get() else "View Console"
            )
        except Exception:
            pass

    def toggle_view_console(self):
        enabled = not self.view_console_var.get()
        self.view_console_var.set(enabled)
        VIEW_CONSOLE_STATE.write_text("on" if enabled else "off")
        self._update_console_button()
        if enabled:
            self._open_console_viewer()
        else:
            self._close_console_viewer()

    def set_action_busy(self, yes):
        self.action_running = bool(yes)
        state = "disabled" if yes else "normal"
        for widget in (self.base_btn, self.both_btn, self.resume_btn, self.repair_steam_btn):
            try: widget.configure(state=state)
            except Exception: pass

        # Installation choices are immutable once an action starts. In
        # particular, Steam Integration must never change halfway through a
        # compile because later shortcut/artwork phases read the same choice.
        try:
            self.steam_combo.configure(state="disabled" if yes else "readonly")
        except Exception:
            pass

    def call(self, action, arg=None):
        cmd = ["bash", str(BACKEND), "--action", action]
        if arg is not None:
            cmd.append(str(arg))
        return subprocess.run(
            cmd,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
        )

    def busy(self, yes, text):
        self.status_var.set(text)
        if yes:
            pass
        else:
            if self.progress["value"] < 100:
                self.progress["value"] = 0

    def startup(self):
        # RC19: a detached installation is far cheaper to identify than a ROM
        # scan. Reattach first so reopening DeckHelper after Continue in
        # Background feels immediate instead of waiting on storage discovery.
        if self._background_process_alive():
            self.progress["value"] = 5
            self.status_var.set("Reattaching to active installation…")
            self.refresh()
            self._attach_background_installation()
            return

        self.progress["value"] = 5
        self.busy(True, "Scanning for verified PAL Mario Kart Wii…")
        def work():
            self.call("startup-detect")
            self.after(0, self.finish_startup)
        threading.Thread(target=work, daemon=True).start()

    def finish_startup(self):
        self.refresh()
        self.progress["value"] = 100
        self.busy(False, "Ready")
        self.after(500, lambda: self.progress.configure(value=0))
        # A build could have been backgrounded between startup checks. This is
        # intentionally a second cheap guard, not a prerequisite ROM scan.
        self._attach_background_installation()

    def _background_process_alive(self):
        pid = self.external_background_pid
        if pid is None and BACKGROUND_PID_STATE.exists():
            try:
                pid = int(BACKGROUND_PID_STATE.read_text().strip())
            except Exception:
                pid = None
        if not pid or pid <= 1:
            return False
        try:
            cmdline = Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode("utf-8", "replace")
            if str(BACKEND) not in cmdline or "--action" not in cmdline:
                return False
            os.kill(pid, 0)
            self.external_background_pid = pid
            return True
        except Exception:
            return False

    def _clear_background_state(self):
        self.external_background_pid = None
        for state in (BACKGROUND_PID_STATE, BACKGROUND_ACTION_STATE):
            try:
                state.unlink(missing_ok=True)
            except Exception:
                pass

    def _attach_background_installation(self):
        if not self._background_process_alive():
            self._clear_background_state()
            return
        try:
            action = BACKGROUND_ACTION_STATE.read_text().strip()
        except Exception:
            action = "build-both"
        self.active_action = action if action else "build-both"
        self.set_action_busy(True)
        self.status_var.set("Reattached to installation running in background")
        if self.view_console_var.get():
            self._open_console_viewer()
        self.after(500, self._poll_attached_background)

    def _poll_attached_background(self):
        if not self._background_process_alive():
            action = self.active_action
            self._clear_background_state()
            self.active_action = None
            self.set_action_busy(False)
            self.refresh()
            # A successful installer clears active_build_state. If it remains,
            # startup recovery can turn the preserved compiler state into a
            # resume checkpoint without pretending the failed job succeeded.
            if (STATE_DIR / "active_build_state").exists():
                try:
                    self.call("startup-detect")
                    self.refresh()
                except Exception:
                    pass
                self.status_var.set("Background installation stopped · resume may be available")
            else:
                self.progress["value"] = 100
                self.status_var.set("100% · Complete")
            return

        action = self.active_action or "build-both"
        compiler = self._compiler_progress_from_log(action)
        if compiler is not None:
            pct, stage, current, total = compiler
            self.progress["value"] = pct
            self.status_var.set(f"{pct}% · {stage} · {current}/{total} · background")
        else:
            try:
                r = self.call("progress-status")
                line = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else "0|Working..."
                pct_s, msg = line.split("|", 1)
                pct = max(0, min(100, int(pct_s)))
                self.progress["value"] = pct
                self.status_var.set(f"{pct}% · {msg} · background")
            except Exception:
                self.status_var.set("Installation is still running in background")
        self.after(500, self._poll_attached_background)

    def refresh(self):
        r = self.call("status")
        data = {}
        for line in r.stdout.splitlines():
            if ": " in line:
                k, v = line.split(": ", 1)
                data[k] = v

        game = data.get("Game", "Not selected")
        verified = data.get("Game verified", "NO") == "YES"
        sha256 = data.get("Game SHA256", "")
        game_id = data.get("Game ID", "RMCP01")

        if game.startswith("/") and verified:
            self.game_var.set(f"✓ VERIFIED  ·  Mario Kart Wii PAL ({game_id})")
            fingerprint = (sha256[:12] + "…" + sha256[-8:]) if len(sha256) > 24 else sha256
            self.game_detail_var.set(
                game + (f"   ·   SHA-256 {fingerprint}" if fingerprint else "")
                + "   ·   ID / size / SHA-1 / SHA-256 match"
            )
        elif game.startswith("/"):
            sha1 = data.get("Game SHA1", "")
            size = data.get("Game size", "")
            game_id = data.get("Game ID", "")
            self.game_var.set("Game selected — verification not confirmed")
            detail = game
            if game_id or size or sha1:
                short_sha1 = (sha1[:12] + "…") if sha1 else "?"
                detail += f"\nDetected: ID {game_id or '?'} · Size {size or '?'} · SHA-1 {short_sha1}"
            self.game_detail_var.set(detail)
        elif game == "Not selected":
            self.game_var.set("No verified PAL image detected")
            self.game_detail_var.set("Use Scan for Game or Browse for Game…")
        else:
            self.game_var.set(game)
            self.game_detail_var.set("")

        rr = data.get("Retro Rewind save", "NO")
        mii = data.get("Mii data", "NO")
        save_source = data.get("Retro Rewind source", "")
        mii_source = data.get("Mii source", "")
        summary = (
            f"Retro Rewind save: {'✓ Found' if rr == 'YES' else 'Not found'}    "
            f"Mii data: {'✓ Found' if mii == 'YES' else 'Not found'}"
        )
        def compact_source(path):
            if not path:
                return ""
            # Keep the useful source identity visible without letting long
            # Flatpak/Dolphin paths consume half the Deck screen.
            lower = path.lower()
            if "wheelwizard" in lower:
                source = "Wheel Wizard"
            elif "dolphin" in lower:
                source = "Dolphin"
            elif "retrorewind" in lower or "retrowfc" in lower:
                source = "Retro Rewind"
            else:
                source = "Detected"
            tail = "/".join(Path(path).parts[-4:])
            if len(tail) > 64:
                tail = "…" + tail[-63:]
            return f"{source}: {tail}"

        details = []
        if save_source:
            details.append("Save · " + compact_source(save_source))
        if mii_source:
            details.append("Miis · " + compact_source(mii_source))
        self.save_var.set(summary + ("\n" + "    ".join(details) if details else ""))

        steam_label = data.get("Steam integration mode", "ADD TO STEAM / NO ART")
        self.steam_mode_var.set({
            "ADD TO STEAM + COVER ART": "Add to Steam",
            "ADD TO STEAM / NO ART": "Add to Steam",
            "DO NOT ADD TO STEAM": "Do Not Add to Steam",
        }.get(steam_label, "Add to Steam"))
        self.auto_art_var.set(data.get("SteamGridDB auto art", "ON") == "ON")
        # Dependency health badge. This probe is read-only and never invokes sudo.
        try:
            dep_probe = self.call("dependency-probe")
            if dep_probe.returncode == 0:
                self.verify_btn.configure(
                    text="Verify / Repair Dependencies   ✓ VERIFIED"
                )
            else:
                self.verify_btn.configure(
                    text="Verify / Repair Dependencies"
                )
        except Exception:
            self.verify_btn.configure(
                text="Verify / Repair Dependencies"
            )

        resume_available = data.get("Resume available", "NO") == "YES"
        try:
            self.resume_btn.configure(state="normal" if resume_available and not self.action_running else "disabled")
        except Exception:
            pass

        repair = data.get("Dependency repair", "")
        if "ASK" in repair:
            self.repair.current(0)
        elif "AUTO" in repair:
            self.repair.current(1)
        else:
            self.repair.current(2)

    def scan_migration(self):
        self.busy(True, "Scanning for Retro Rewind saves and Mii data…")
        def work():
            self.call("scan-migration")
            self.after(0, self.scan_done)
        threading.Thread(target=work, daemon=True).start()

    def scan_done(self):
        self.refresh()
        self.busy(False, "Save/Mii scan complete")

    def import_data(self):
        # RC19.15: keep the save-import confirmation inside DeckHelper's Steam-like
        # visual language instead of dropping to Tk/KDE's bright native yes/no box.
        dlg = tk.Toplevel(self)
        dlg.title("Import Save + Miis")
        dlg.transient(self)
        dlg.resizable(False, False)
        result = {"value": False}

        popup_bg = "#1b2838" if self.dark_var.get() else "#ffffff"
        dlg.configure(background=popup_bg)
        body = ttk.Frame(dlg, style="Card.TFrame", padding=18)
        body.pack(fill="both", expand=True)

        ttk.Label(
            body,
            text="Import detected save + Mii data?",
            style="Body.TLabel",
            font=("Sans", 11, "bold"),
        ).pack(anchor="w")
        ttk.Label(
            body,
            text=("DeckHelper will copy the detected Retro Rewind save and Mii data "
                  "into WiiCompiled.\nExisting WiiCompiled destination files are backed up first."),
            style="Detail.TLabel",
            justify="left",
            wraplength=500,
        ).pack(anchor="w", pady=(7, 14))

        row = ttk.Frame(body, style="Card.TFrame")
        row.pack(fill="x")

        def choose(value):
            result["value"] = value
            try:
                dlg.grab_release()
            except tk.TclError:
                pass
            dlg.destroy()

        import_button = ttk.Button(
            row,
            text="Import Detected Data",
            command=lambda: choose(True),
            style="Primary.TButton",
        )
        import_button.pack(side="left", expand=True, fill="x", padx=(0, 6), ipady=2)
        ttk.Button(
            row,
            text="Cancel",
            command=lambda: choose(False),
            style="Ghost.TButton",
        ).pack(side="left", expand=True, fill="x", padx=(6, 0), ipady=2)

        # B/Escape is safe and contextual inside this dialog: cancel only.
        dlg.bind("<Escape>", lambda e: (choose(False), "break")[1])
        dlg.protocol("WM_DELETE_WINDOW", lambda: choose(False))
        dlg.update_idletasks()
        width = max(460, dlg.winfo_reqwidth())
        height = dlg.winfo_reqheight()
        x = self.winfo_rootx() + max(0, (self.winfo_width() - width) // 2)
        y = self.winfo_rooty() + max(0, (self.winfo_height() - height) // 2)
        dlg.geometry(f"{width}x{height}+{x}+{y}")
        dlg.grab_set()
        import_button.focus_set()
        self.wait_window(dlg)

        if result["value"]:
            self.run_terminal("import", "Import Save + Miis")

    def save_sgdb_key(self):
        key = self.sgdb_key_var.get().strip()
        if not key:
            messagebox.showwarning(APP_TITLE, "Paste your SteamGridDB API key first.")
            return
        r = self.call("set-sgdb-key", key)
        if r.returncode == 0:
            self.sgdb_key_var.set("")
            messagebox.showinfo(APP_TITLE, "SteamGridDB API key saved locally.")
            self.refresh()
        else:
            messagebox.showerror(APP_TITLE, "Could not save the SteamGridDB API key.")

    def set_auto_art(self):
        self.call("set-sgdb-auto", "on" if self.auto_art_var.get() else "off")
        self.refresh()


    def scan_game_again(self):
        if getattr(self, "proc", None) is not None:
            return

        self.busy(True, "Scanning for game image…")

        def work():
            return self.call("scan-game")

        def done(result):
            self.busy(False, "Ready")
            self.refresh()
            if result.returncode == 0:
                messagebox.showinfo(
                    APP_TITLE,
                    "Verified PAL Mario Kart Wii image found."
                )
            else:
                messagebox.showinfo(
                    APP_TITLE,
                    "No verified PAL Mario Kart Wii image was found. "
                    "You can copy/download it later and use Scan for Game again."
                )

        threading.Thread(
            target=lambda: self.after(0, done, work()),
            daemon=True
        ).start()

    def browse_game(self):
        downloads = Path.home() / "Downloads"
        start_dir = downloads if downloads.is_dir() else Path.home()
        p = ""

        # SteamOS Desktop Mode is KDE Plasma. Prefer its own file chooser so
        # the dialog follows the desktop theme, sizing, places/sidebar and
        # accessibility behavior instead of Tk's small light dialog.
        if shutil.which("kdialog"):
            try:
                result = subprocess.run(
                    [
                        "kdialog",
                        "--title", "Select Mario Kart Wii",
                        "--getopenfilename", str(start_dir),
                        "WiiCompiled game images (*.iso *.gcm *.gcz *.ciso *.wbfs *.wia *.rvz)"
                    ],
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL
                )
                if result.returncode == 0:
                    p = result.stdout.strip()
                else:
                    return
            except Exception:
                p = ""

        if not p:
            p = filedialog.askopenfilename(
                title="Select Mario Kart Wii",
                initialdir=str(start_dir),
                filetypes=(
                    ("WiiCompiled game images", "*.iso *.gcm *.gcz *.ciso *.wbfs *.wia *.rvz"),
                    ("All files", "*")
                )
            )

        if not p:
            return

        if Path(p).suffix.lower() not in (".iso", ".gcm", ".gcz", ".ciso", ".wbfs", ".wia", ".rvz"):
            messagebox.showerror(
                APP_TITLE,
                "Please select a WiiCompiled-supported image (.iso, .gcm, .gcz, .ciso, .wbfs, .wia, or .rvz)."
            )
            return

        state = Path.home() / ".config/wiicompile-deckhelper/game_path"
        state.parent.mkdir(parents=True, exist_ok=True)
        state.write_text(p)
        self.busy(True, "Verifying selected game image…")
        self.update_idletasks()
        result = self.call("verify-selected")
        self.refresh()
        if result.returncode == 0:
            self.busy(False, "Verified PAL Mario Kart Wii image")
        elif result.returncode == 3:
            self.busy(False, "Supported WiiCompiled container selected")
            messagebox.showinfo(
                APP_TITLE,
                "This container format is supported by WiiCompiled. "
                "DeckHelper could not pre-hash the logical disc because dolphin-tool "
                "is not available, so WiiCompiled will validate the image during install."
            )
        else:
            self.busy(False, "Selected image did not match the tested PAL disc")
            messagebox.showerror(
                APP_TITLE,
                "That image did not match the tested PAL Mario Kart Wii disc."
            )

    def set_steam_mode(self, event=None):
        choice = self.steam_mode_var.get()
        mode = {
            "Add to Steam": "art",
            "Do Not Add to Steam": "off",
        }.get(choice, "off")
        self.call("set-steam-mode", mode)
        self.refresh()

    def set_repair_mode(self, _evt=None):
        wanted = self.repair.current()
        for _ in range(3):
            s = self.call("status").stdout
            if (wanted == 0 and "ASK BEFORE SUDO" in s) or \
               (wanted == 1 and "AUTO REPAIR WITH SUDO" in s) or \
               (wanted == 2 and "NO SUDO / CHECK ONLY" in s):
                break
            self.call("cycle-sudo")
        self.refresh()

    def _visible_terminal(self, action, label):
        """Run an action visibly when requested or when interaction is expected."""
        self.progress["value"] = 0
        self.set_action_busy(True)
        backend_q = shlex.quote(str(BACKEND))
        action_q = shlex.quote(action)
        label_q = shlex.quote(label)

        cmd = (
            f'backend={backend_q}; '
            'clear; '
            'echo "============================================================"; '
            'echo "                 WiiCompiled DeckHelper"; '
            'echo "============================================================"; '
            'echo; '
            f'echo {label_q}; echo; '
            f'bash "$backend" --action {action_q}; rc=$?; '
            'echo; '
            f'if [ $rc -eq 0 ]; then '
            f'echo "[OK] {label} finished successfully."; '
            'echo; echo "This window will close automatically."; sleep 2; '
            'else '
            f'echo "[FAIL] {label} exited with code $rc."; '
            'echo "Check the Work folder inside WiiCompiled DeckHelper"; '
            'echo; '
            'echo "Press any key to close this window..."; '
            'IFS= read -r -n 1 _; '
            'fi; '
            'exit $rc'
        )

        try:
            p = subprocess.Popen([
                "konsole", "--title", f"{APP_TITLE} - {label}",
                "-e", "bash", "-lc", cmd
            ])
            self.status_var.set(label + "…")
            self.poll_process(p, label, False, action=action)
        except Exception as e:
            self.set_action_busy(False)
            messagebox.showerror(APP_TITLE, f"Could not open Konsole:\n{e}")

    def _show_error_terminal(self, label):
        """Expose captured output only after a silent action has failed."""
        try:
            ACTION_LOG.parent.mkdir(parents=True, exist_ok=True)
            log_q = shlex.quote(str(ACTION_LOG))
            label_q = shlex.quote(label)
            cmd = (
                'clear; '
                'echo "============================================================"; '
                'echo "                 WiiCompiled DeckHelper"; '
                'echo "============================================================"; '
                'echo; '
                f'echo "[FAIL] {label} needs attention."; '
                'echo; '
                f'if [ -f {log_q} ]; then cat {log_q}; '
                'else echo "No captured action log was found."; fi; '
                'echo; echo "Full log: Work/wiicompile-deckhelper.log"; '
                'echo; echo "Press any key to close this window..."; '
                'IFS= read -r -n 1 _'
            )
            subprocess.Popen([
                "konsole", "--title", f"{APP_TITLE} - Error",
                "-e", "bash", "-lc", cmd
            ])
        except Exception as e:
            messagebox.showerror(
                APP_TITLE,
                f"{label} failed.\n\nCould not open the error console:\n{e}"
            )

    def _run_hidden(self, action, label):
        """Run normal work invisibly while the GUI progress bar is updated."""
        # Snapshot install-time Steam behavior before disabling the selector.
        # The backend receives this immutable value in its environment, so even
        # an external state-file edit cannot flip shortcut/artwork behavior in
        # the middle of a build.
        env = os.environ.copy()
        if action in {"build-base", "build-retro", "build-both", "repair-steam"}:
            steam_snapshot = (
                "art" if self.steam_mode_var.get() == "Add to Steam" else "off"
            )
            env["WIICOMPILED_STEAM_MODE_SNAPSHOT"] = steam_snapshot
            # Keep persisted state aligned with the deliberately selected mode
            # before the action begins.
            self.call("set-steam-mode", steam_snapshot)

        self.set_action_busy(True)
        try:
            ACTION_LOG.parent.mkdir(parents=True, exist_ok=True)
            log_handle = open(ACTION_LOG, "w", encoding="utf-8", errors="replace")
            p = subprocess.Popen(
                ["bash", str(BACKEND), "--action", action],
                stdout=log_handle,
                stderr=subprocess.STDOUT,
                text=True,
                start_new_session=True,
                env=env
            )
            self.active_process = p
            self.active_action = action
            self.external_background_pid = None
            BACKGROUND_PID_STATE.write_text(str(p.pid))
            BACKGROUND_ACTION_STATE.write_text(action)
            self.action_started_at = time.monotonic()
            self.status_var.set(label + "…")
            if self.view_console_var.get():
                self._open_console_viewer()
            self.poll_process(p, label, True, log_handle, action=action)
        except Exception as e:
            try:
                log_handle.close()
            except Exception:
                pass
            self.set_action_busy(False)
            messagebox.showerror(APP_TITLE, f"Could not start {label}:\n{e}")

    def run_terminal(self, action, label):
        if self.action_running and action in {"build-base", "build-retro", "build-both", "repair-steam"}:
            messagebox.showinfo(APP_TITLE, "A WiiCompiled build is already running.")
            return

        # Verify can become interactive only when SteamOS package repair is
        # needed. Probe first; if the machine is already healthy, keep it quiet.
        if action == "verify":
            try:
                probe = self.call("dependency-probe")
                if probe.returncode != 0:
                    self._visible_terminal(action, label)
                    return
            except Exception:
                # If the preflight itself cannot be trusted, expose the terminal
                # rather than risking a hidden sudo/password prompt.
                self._visible_terminal(action, label)
                return

        # Install/repair/import work always runs as the same detached backend.
        # View Console is now just a live log viewer, so it can be opened or
        # closed at any point without starting, restarting, or killing the job.
        self.progress["value"] = 0
        self._run_hidden(action, label)

    def _compiler_progress_from_log(self, action):
        """Read only genuine Ninja build counters from hidden output."""
        try:
            if not ACTION_LOG.exists():
                return None

            size = ACTION_LOG.stat().st_size
            with ACTION_LOG.open("rb") as f:
                if size > 196608:
                    f.seek(size - 196608)
                text = f.read().decode("utf-8", errors="replace")

            # Ninja emits build steps like:
            #   [173/195] Building CXX object ...
            #   [194/195] Linking CXX executable ...
            # Do not accept arbitrary [number/number] strings: curl/download
            # counters can be huge and previously produced nonsense progress.
            ansi = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
            step_re = re.compile(
                r"^\s*\[(\d+)/(\d+)\]\s+(?:Building|Linking|Generating)\b"
            )
            newest = None
            for raw in text.splitlines():
                line = ansi.sub("", raw)
                m = step_re.match(line)
                if not m:
                    continue
                current, total = int(m.group(1)), int(m.group(2))
                if total <= 0 or current < 0 or current > total or total > 20000:
                    continue
                newest = (current, total)

            if newest is None:
                return None
            current, total = newest

            base_pos = text.rfind("Building Base Mario Kart Wii")
            retro_pos = text.rfind("Building Retro Rewind")
            is_retro = retro_pos > base_pos and retro_pos >= 0
            fraction = max(0.0, min(1.0, current / total))

            if action == "build-both":
                if is_retro:
                    local_pct = 35 + fraction * (86 - 35)
                    pct = 48 + local_pct * 0.48
                    stage = "Retro Rewind compilation"
                else:
                    local_pct = 18 + fraction * (86 - 18)
                    pct = local_pct * 0.48
                    stage = "Base compilation"
            elif action == "build-base":
                pct = 18 + fraction * (86 - 18)
                stage = "Base compilation"
            else:
                pct = fraction * 100
                stage = "Compiling"

            return int(round(pct)), stage, current, total
        except Exception:
            return None

    def poll_process(self, p, label, hidden=False, log_handle=None, action=None):
        pct = 0
        msg = "Working..."
        try:
            r = self.call("progress-status")
            line = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else "0|Working..."
            pct_s, msg = line.split("|", 1)
            pct = max(0, min(100, int(pct_s)))
        except Exception:
            pass

        # For hidden builds, prefer the real compiler counter whenever present.
        compiler = self._compiler_progress_from_log(action) if hidden and action else None
        if compiler is not None:
            compile_pct, stage, current, total = compiler
            # Never move the visible bar backwards if another phase has already
            # advanced farther than the compile-derived estimate.
            pct = max(pct, compile_pct)
            msg = f"{stage} · {current}/{total}"

        self.progress["value"] = pct
        if msg:
            elapsed = ""
            if self.action_started_at is not None:
                secs = max(0, int(time.monotonic() - self.action_started_at))
                elapsed = f" · {secs // 60}:{secs % 60:02d}"
            self.status_var.set(f"{pct}% · {msg}{elapsed}")

        if p.poll() is None:
            self.after(
                500,
                lambda: self.poll_process(
                    p, label, hidden, log_handle, action
                )
            )
        else:
            self.set_action_busy(False)
            if p is self.active_process:
                self._close_console_viewer()
                self.active_process = None
                self.active_action = None
                self.action_started_at = None
                self._clear_background_state()
            if log_handle is not None:
                try:
                    log_handle.flush()
                    log_handle.close()
                except Exception:
                    pass

            self.refresh()
            if p.returncode == 0:
                self.progress["value"] = 100
                if action == "release-validation":
                    self.status_var.set("✓ RC validation passed · report saved in Work")
                    messagebox.showinfo(
                        APP_TITLE,
                        "Release candidate validation passed.\n\n"
                        "Report: Work/release-test-report.txt"
                    )
                else:
                    self.status_var.set("100% · Complete")
                    self.after(1200, lambda: self.progress.configure(value=0))
                    self.after(1200, lambda: self.status_var.set("Ready"))
            else:
                # End Installation deliberately terminates the backend.  Its
                # cleanup worker owns the resulting UX, so do not race it with
                # a bogus generic failure console for SIGTERM/exit 143.
                if self.closing_after_cancel:
                    self.status_var.set("Installation ended")
                    return
                self.status_var.set(f"{label} needs attention")
                if hidden:
                    self._show_error_terminal(label)

    def _active_build_close_choice(self):
        dlg = tk.Toplevel(self)
        dlg.title("Installation still running")
        dlg.transient(self)
        dlg.grab_set()
        dlg.resizable(False, False)
        result = {"value": "cancel"}
        delete_var = tk.BooleanVar(value=True)

        body = ttk.Frame(dlg, style="Card.TFrame", padding=18)
        body.pack(fill="both", expand=True)
        ttk.Label(
            body,
            text="A WiiCompiled installation is still running.",
            style="Body.TLabel",
            font=("Sans", 11, "bold")
        ).pack(anchor="w")
        ttk.Label(
            body,
            text=("Continue in Background leaves the installer running.\n"
                  "Reopen DeckHelper and it will reconnect immediately. End Installation stops it."),
            style="Detail.TLabel",
            justify="left"
        ).pack(anchor="w", pady=(7, 10))

        ttk.Checkbutton(
            body,
            text="Delete compiled installation data",
            variable=delete_var,
            style="Switch.TCheckbutton"
        ).pack(anchor="w", pady=(0, 3))
        ttk.Label(
            body,
            text=("Checked by default: remove incomplete compiled output and build progress.\n"
                  "Uncheck to preserve progress so DeckHelper can resume it later."),
            style="Detail.TLabel",
            justify="left"
        ).pack(anchor="w", pady=(0, 14))

        row = ttk.Frame(body, style="Card.TFrame")
        row.pack(fill="x")
        def choose(value):
            if value == "end":
                result["value"] = "end-delete" if delete_var.get() else "end-keep"
            else:
                result["value"] = value
            dlg.destroy()
        dlg.bind("<Escape>", lambda e: choose("cancel"))
        ttk.Button(row, text="Continue in Background", command=lambda: choose("background"), style="Primary.TButton").pack(side="left", padx=(0, 6))
        ttk.Button(row, text="End Installation", command=lambda: choose("end"), style="Secondary.TButton").pack(side="left", padx=6)
        ttk.Button(row, text="Cancel", command=lambda: choose("cancel"), style="Ghost.TButton").pack(side="right", padx=(6, 0))
        dlg.protocol("WM_DELETE_WINDOW", lambda: choose("cancel"))
        dlg.update_idletasks()
        x = self.winfo_rootx() + max(0, (self.winfo_width() - dlg.winfo_reqwidth()) // 2)
        y = self.winfo_rooty() + max(0, (self.winfo_height() - dlg.winfo_reqheight()) // 2)
        dlg.geometry(f"+{x}+{y}")
        self.wait_window(dlg)
        return result["value"]

    def _end_active_installation(self, cleanup_mode="delete"):
        p = self.active_process
        attached_pid = self.external_background_pid if self._background_process_alive() else None
        action = self.active_action or "build"
        if cleanup_mode == "keep":
            self.status_var.set("Stopping installation and preserving progress for resume…")
        else:
            self.status_var.set("Stopping installation and deleting compiled progress…")
        self.closing_after_cancel = True

        def worker():
            target_pid = p.pid if p is not None and p.poll() is None else attached_pid
            if target_pid is not None:
                try:
                    os.killpg(target_pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                except Exception:
                    try: p.terminate()
                    except Exception: pass
                deadline = time.monotonic() + 3.0
                while time.monotonic() < deadline:
                    if p is not None:
                        if p.poll() is not None:
                            break
                    else:
                        try:
                            os.kill(target_pid, 0)
                        except ProcessLookupError:
                            break
                        except Exception:
                            break
                    time.sleep(0.1)
                still_alive = False
                if p is not None:
                    still_alive = p.poll() is None
                else:
                    try:
                        os.kill(target_pid, 0)
                        still_alive = True
                    except Exception:
                        still_alive = False
                if still_alive:
                    try: os.killpg(target_pid, signal.SIGKILL)
                    except Exception:
                        try:
                            if p is not None: p.kill()
                        except Exception: pass
                if p is not None:
                    try: p.wait(timeout=2)
                    except Exception: pass
                self._clear_background_state()
            cleanup_result = None
            try:
                cleanup_result = self.call("cleanup-interrupted", f"{action}:{cleanup_mode}")
            except Exception as e:
                cleanup_result = e

            def finish_close():
                # RC16 swallowed cleanup failures and closed the GUI, which made
                # a failed flock look like a successful delete. Never silently
                # claim deletion again.
                if hasattr(cleanup_result, "returncode") and cleanup_result.returncode == 0:
                    self.destroy()
                    return
                if cleanup_mode == "delete":
                    details = getattr(cleanup_result, "stdout", str(cleanup_result))
                    messagebox.showerror(
                        APP_TITLE,
                        "The installation stopped, but compiled-data cleanup did not complete.\n\n"
                        "DeckHelper has left the data in place rather than risking a partial delete.\n\n"
                        + (details[-1800:] if details else "No cleanup output was captured.")
                    )
                self.destroy()

            self.after(0, finish_close)

        threading.Thread(target=worker, daemon=True).start()

    def _action_is_active(self):
        p = self.active_process
        return bool(self.action_running or (p is not None and p.poll() is None) or self._background_process_alive())

    def on_close(self):
        if self._action_is_active():
            choice = self._active_build_close_choice()
            if choice == "cancel":
                return
            if choice == "background":
                self._close_console_viewer()
                self.destroy()
                return
            if choice in {"end-delete", "end-keep"}:
                self._close_console_viewer()
                self._end_active_installation("delete" if choice == "end-delete" else "keep")
                return
        self._close_console_viewer()
        self.call("cleanup")
        self.destroy()

if __name__ == "__main__":
    App().mainloop()
