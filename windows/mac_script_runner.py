from __future__ import annotations

import json
import ctypes
import os
import queue
import re
import signal
import subprocess
import sys
import threading
import winreg
if getattr(sys, "frozen", False):
    os.environ["TCL_LIBRARY"] = os.path.join(sys._MEIPASS, "_tcl_data")
    os.environ["TK_LIBRARY"] = os.path.join(sys._MEIPASS, "_tk_data")
import tkinter as tk
from datetime import datetime
from pathlib import Path
from tkinter import filedialog, messagebox, simpledialog, ttk


APP_NAME = "MacScriptRunner"
STATE_DIR = Path(os.environ.get("APPDATA", Path.home())) / APP_NAME
STATE_FILE = STATE_DIR / "state.json"
EMPTY_OUTPUT = "Выберите скрипт и нажмите кнопку запуска."
BG = "#17191d"
SIDEBAR = "#202329"
PANEL = "#1b1e23"
FIELD = "#111317"
BORDER = "#343840"
TEXT = "#f2f3f5"
MUTED = "#9ca2ad"
ACCENT = "#5e9cff"
RED = "#ff625e"

PALETTES = {
    "dark": {"bg": "#17191d", "sidebar": "#202329", "panel": "#1b1e23", "field": "#111317",
             "border": "#343840", "text": "#f2f3f5", "muted": "#9ca2ad", "accent": "#5e9cff", "red": "#ff625e"},
    "light": {"bg": "#f4f4f6", "sidebar": "#e9eaed", "panel": "#ffffff", "field": "#ffffff",
              "border": "#d1d3d8", "text": "#202124", "muted": "#70757d", "accent": "#1769d2", "red": "#c93632"},
}


def resource_path(name: str) -> Path:
    base = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))
    return base / name


class ScriptRunner(tk.Tk):
    def __init__(self) -> None:
        try:
            ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID("MacScriptRunner.Windows.1")
        except (AttributeError, OSError):
            pass
        super().__init__()
        self.state_data = self.load_state()
        self.title("Script Runner")
        icon = resource_path("AppIcon.ico")
        if icon.exists():
            try: self.iconbitmap(default=str(icon))
            except tk.TclError: pass
        saved_geometry = self.state_data.get("window_geometry", "1100x700")
        self.geometry(saved_geometry if re.fullmatch(r"\d+x\d+(?:[+-]\d+){2}", saved_geometry) else "1100x700")
        self.minsize(900, 560)
        self.protocol("WM_DELETE_WINDOW", self.close_app)
        self.script_paths: list[Path] = []
        self.process: subprocess.Popen | None = None
        self.running_path: Path | None = None
        self.pending_path: Path | None = None
        self.events: queue.Queue[tuple[str, object]] = queue.Queue()
        self.output_by_path: dict[str, str] = self.state_data.setdefault("outputs", {})
        self.notes: dict[str, str] = self.state_data.setdefault("notes", {})
        self.last_runs: dict[str, str] = self.state_data.setdefault("last_runs", {})
        self.statuses: dict[str, int] = self.state_data.setdefault("statuses", {})
        self.selected_path: Path | None = None
        self.font_size = tk.IntVar(value=int(self.state_data.get("font_size", 13)))
        self.wrap_lines = tk.BooleanVar(value=bool(self.state_data.get("wrap_lines", True)))
        self.status_text = tk.StringVar(value="Готово")
        self.theme_mode = tk.StringVar(value=self.state_data.get("theme", "dark"))
        self.folder_text = tk.StringVar(value=self.state_data.get("folder", "Папка не выбрана"))
        self.configure_theme()
        self.build_ui()
        self.reload_scripts()
        self.after(80, self.poll_events)

    @staticmethod
    def load_state() -> dict:
        try:
            return json.loads(STATE_FILE.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}

    def save_state(self) -> None:
        self.state_data.update({
            "folder": self.folder_text.get() if self.folder_text.get() != "Папка не выбрана" else "",
            "font_size": self.font_size.get(), "wrap_lines": self.wrap_lines.get(),
            "theme": self.theme_mode.get(),
            "window_geometry": self.geometry(),
            "pane_ratio": self.current_pane_ratio(),
            "order": [str(p) for p in self.script_paths],
        })
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        STATE_FILE.write_text(json.dumps(self.state_data, ensure_ascii=False, indent=2), encoding="utf-8")

    def system_uses_dark_theme(self) -> bool:
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize") as key:
                return winreg.QueryValueEx(key, "AppsUseLightTheme")[0] == 0
        except OSError:
            return True

    def configure_theme(self) -> None:
        global BG, SIDEBAR, PANEL, FIELD, BORDER, TEXT, MUTED, ACCENT, RED
        mode = self.theme_mode.get() if hasattr(self, "theme_mode") else self.state_data.get("theme", "dark")
        resolved = "dark" if mode == "system" and self.system_uses_dark_theme() else ("light" if mode == "system" else mode)
        colors = PALETTES.get(resolved, PALETTES["dark"])
        BG, SIDEBAR, PANEL, FIELD, BORDER = colors["bg"], colors["sidebar"], colors["panel"], colors["field"], colors["border"]
        TEXT, MUTED, ACCENT, RED = colors["text"], colors["muted"], colors["accent"], colors["red"]
        self.configure(bg=BG)
        style = ttk.Style(self)
        style.theme_use("clam")
        style.configure(".", background=BG, foreground=TEXT, fieldbackground=FIELD,
                        bordercolor=BORDER, lightcolor=BORDER, darkcolor=BORDER,
                        troughcolor=FIELD, focuscolor=ACCENT, font=("Segoe UI", 10))
        style.configure("TFrame", background=BG)
        style.configure("Sidebar.TFrame", background=SIDEBAR)
        style.configure("Panel.TFrame", background=PANEL)
        style.configure("TLabel", background=BG, foreground=TEXT)
        style.configure("Muted.TLabel", foreground=MUTED)
        style.configure("SidebarMuted.TLabel", background=SIDEBAR, foreground=MUTED)
        style.configure("PanelTitle.TLabel", background=PANEL, foreground=TEXT, font=("Segoe UI Semibold", 11))
        style.configure("PanelDot.TLabel", background=PANEL, foreground=ACCENT)
        style.configure("Title.TLabel", font=("Segoe UI Semibold", 11))
        style.configure("TButton", background=BG, foreground=TEXT, padding=(10, 6), relief="flat",
                        borderwidth=0, focusthickness=0, focuscolor=BG)
        style.map("TButton", background=[("active", "#383d46"), ("pressed", "#24272d")])
        style.configure("Icon.TButton", padding=(7, 4), font=("Segoe UI Symbol", 10))
        style.configure("Run.TButton", foreground=ACCENT, padding=(8, 5))
        style.configure("Stop.TButton", foreground=RED, padding=(8, 5))
        borderless_layout = [("Button.padding", {"sticky": "nswe", "children": [
            ("Button.label", {"sticky": "nswe"})
        ]})]
        for button_style in ("TButton", "Icon.TButton", "Run.TButton", "Stop.TButton"):
            style.layout(button_style, borderless_layout)
        style.configure("Treeview", background=SIDEBAR, fieldbackground=SIDEBAR, foreground=TEXT,
                        rowheight=48, borderwidth=0, relief="flat")
        style.map("Treeview", background=[("selected", "#29476f")], foreground=[("selected", "#ffffff")])
        style.configure("Treeview.Heading", background=SIDEBAR, foreground=MUTED, relief="flat",
                        font=("Segoe UI", 9))
        style.map("Treeview.Heading", background=[("active", SIDEBAR)])
        style.configure("TEntry", fieldbackground=FIELD, foreground=TEXT, insertcolor=TEXT, padding=7)
        style.configure("TCheckbutton", background=BG, foreground=TEXT)
        style.configure("TPanedwindow", background=BORDER)
        style.configure("Vertical.TScrollbar", background="#30343b", troughcolor=FIELD, arrowcolor=MUTED)
        if hasattr(self, "output"):
            self.output.configure(bg=FIELD, fg=TEXT, insertbackground=TEXT)
            self.input_entry.configure()
            self.status_dot.configure(style="PanelDot.TLabel")
            self.status_label.configure(style="PanelTitle.TLabel")
            self.count_label.configure(style="SidebarMuted.TLabel")
            self.save_state()

    def build_ui(self) -> None:
        self.rowconfigure(0, weight=1)
        self.columnconfigure(0, weight=1)
        self.split = ttk.Panedwindow(self, orient="horizontal")
        self.split.grid(row=0, column=0, sticky="nsew")
        left = ttk.Frame(self.split, style="Sidebar.TFrame", padding=(8, 10, 7, 8), width=330)
        right = ttk.Frame(self.split, style="Panel.TFrame", padding=(14, 12, 14, 12))
        self.split.add(left, weight=3)
        self.split.add(right, weight=7)
        self._pane_ratio_job = None
        self.after(150, self.apply_pane_ratio)
        left.rowconfigure(0, weight=1)
        left.columnconfigure(0, weight=1)
        self.tree = ttk.Treeview(left, columns=("note", "last"), show="tree", selectmode="browse", height=12)
        self.tree.column("#0", width=338, minwidth=260)
        self.tree.grid(row=0, column=0, sticky="nsew")
        scroll = ttk.Scrollbar(left, command=self.tree.yview)
        scroll.grid(row=0, column=1, sticky="ns")
        self.tree.configure(yscrollcommand=scroll.set)
        self.tree.bind("<<TreeviewSelect>>", self.on_select)
        self.tree.bind("<Double-1>", self.edit_note)
        self.tree.bind("<Button-3>", self.open_editor)
        footer = ttk.Frame(left, style="Sidebar.TFrame")
        footer.grid(row=1, column=0, columnspan=2, sticky="ew", pady=(8, 0))
        self.count_label = ttk.Label(footer, text="0 скриптов", style="SidebarMuted.TLabel")
        self.count_label.pack(side="left")
        ttk.Button(footer, text="Настройки", style="Icon.TButton", command=self.show_settings).pack(side="right")
        ttk.Button(footer, text="Папка", style="Icon.TButton", command=self.choose_folder).pack(side="right", padx=5)
        ttk.Button(footer, text="Обновить", style="Icon.TButton", command=self.reload_scripts).pack(side="right")

        right.rowconfigure(1, weight=1)
        right.columnconfigure(0, weight=1)
        header = ttk.Frame(right, style="Panel.TFrame")
        header.grid(row=0, column=0, sticky="ew", pady=(0, 6))
        self.status_dot = ttk.Label(header, text="●", style="PanelDot.TLabel")
        self.status_dot.pack(side="left")
        self.status_label = ttk.Label(header, textvariable=self.status_text, style="PanelTitle.TLabel")
        self.status_label.pack(side="left", padx=(7, 0))
        self.clear_button = ttk.Button(header, text="Очистить", style="Icon.TButton", command=self.clear_output)
        self.clear_button.pack(side="right")
        self.copy_button = ttk.Button(header, text="Копировать", style="Icon.TButton", command=self.copy_output)
        self.copy_button.pack(side="right", padx=5)
        self.run_button = ttk.Button(header, text="Запустить", style="Run.TButton", command=self.toggle_run)
        self.run_button.pack(side="right")
        self.editor_button = ttk.Button(header, text="Редактор", style="Icon.TButton", command=self.open_editor)
        self.editor_button.pack(side="right", padx=5)
        text_frame = ttk.Frame(right, style="Panel.TFrame")
        text_frame.grid(row=1, column=0, sticky="nsew")
        text_frame.rowconfigure(0, weight=1)
        text_frame.columnconfigure(0, weight=1)
        self.output = tk.Text(text_frame, wrap="word", font=("Cascadia Mono", self.font_size.get()), undo=False,
                              bg=FIELD, fg="#d6d9df", insertbackground=TEXT, selectbackground="#31588b",
                              relief="flat", borderwidth=0, padx=14, pady=14)
        self.output.grid(row=0, column=0, sticky="nsew")
        yscroll = ttk.Scrollbar(text_frame, command=self.output.yview)
        yscroll.grid(row=0, column=1, sticky="ns")
        self.output.configure(yscrollcommand=yscroll.set, state="disabled")
        input_bar = ttk.Frame(right, style="Panel.TFrame")
        input_bar.grid(row=2, column=0, sticky="ew", pady=(6, 0))
        input_bar.columnconfigure(0, weight=1)
        self.input_entry = ttk.Entry(input_bar, font=("Cascadia Mono", self.font_size.get()))
        self.input_entry.grid(row=0, column=0, sticky="ew")
        self.input_entry.bind("<Return>", lambda _e: self.send_input())
        ttk.Button(input_bar, text="Отправить  ➜", command=self.send_input).grid(row=0, column=1, padx=(6, 0))
        self.bind("<Control-r>", lambda _e: self.reload_scripts())
        self.bind("<Control-period>", lambda _e: self.stop_process())
        self.update_controls()

    def apply_pane_ratio(self) -> None:
        self._pane_ratio_job = None
        self.update_idletasks()
        total_width = self.split.winfo_width()
        if total_width > 100:
            ratio = min(0.75, max(0.15, float(self.state_data.get("pane_ratio", 0.30))))
            self.split.sashpos(0, round(total_width * ratio))

    def current_pane_ratio(self) -> float:
        if not hasattr(self, "split") or self.split.winfo_width() <= 100:
            return float(self.state_data.get("pane_ratio", 0.30))
        return self.split.sashpos(0) / self.split.winfo_width()

    def choose_folder(self) -> None:
        folder = filedialog.askdirectory(initialdir=self.folder_text.get() if Path(self.folder_text.get()).is_dir() else None)
        if folder:
            self.folder_text.set(folder)
            self.reload_scripts()
            self.save_state()

    def reload_scripts(self) -> None:
        folder = Path(self.folder_text.get())
        found = list(folder.glob("*.sh")) if folder.is_dir() else []
        order = self.state_data.get("order", [])
        rank = {value: i for i, value in enumerate(order)}
        self.script_paths = sorted(found, key=lambda p: (rank.get(str(p), 10**9), p.name.lower()))
        selected = str(self.selected_path) if self.selected_path else None
        self.tree.delete(*self.tree.get_children())
        for path in self.script_paths:
            last = self.last_runs.get(str(path), "")
            if last:
                try: last = datetime.fromisoformat(last).strftime("%d.%m.%Y %H:%M:%S")
                except ValueError: pass
            note = self.notes.get(str(path), "") or "Без примечания"
            detail = note + (f"   ·   {last}" if last else "")
            self.tree.insert("", "end", iid=str(path), text=f"☰   {path.name}\n      {detail}")
        self.count_label.configure(text=f"{len(self.script_paths)} скриптов")
        if selected and self.tree.exists(selected):
            self.tree.selection_set(selected)
        elif self.script_paths:
            self.tree.selection_set(str(self.script_paths[0]))
            self.on_select()

    def on_select(self, _event=None) -> None:
        selection = self.tree.selection()
        if not selection: return
        self.selected_path = Path(selection[0])
        text = self.output_by_path.get(str(self.selected_path), EMPTY_OUTPUT)
        self.set_output_widget(text)
        code = self.statuses.get(str(self.selected_path))
        self.status_text.set("Выполняется…" if self.running_path == self.selected_path else (f"Завершён, код {code}" if code is not None else "Готово"))
        self.update_controls()

    def update_controls(self) -> None:
        has_selection = self.selected_path is not None and self.selected_path.exists()
        is_running = self.process is not None and self.process.poll() is None
        selected_is_running = is_running and self.running_path == self.selected_path
        self.run_button.configure(
            text="Остановить" if selected_is_running else "Запустить",
            style="Stop.TButton" if selected_is_running else "Run.TButton",
            state="normal" if has_selection else "disabled",
        )
        self.editor_button.configure(state="normal" if has_selection and not selected_is_running else "disabled")
        normal_or_disabled = "disabled" if is_running or not has_selection else "normal"
        self.copy_button.configure(state=normal_or_disabled)
        self.clear_button.configure(state=normal_or_disabled)

    def edit_note(self, _event=None) -> None:
        if not self.selected_path: return
        value = simpledialog.askstring("Примечание", f"Примечание для {self.selected_path.name}:", initialvalue=self.notes.get(str(self.selected_path), ""), parent=self)
        if value is not None:
            self.notes[str(self.selected_path)] = value
            self.save_state(); self.reload_scripts()

    def toggle_run(self) -> None:
        if not self.selected_path:
            return
        if self.process and self.process.poll() is None:
            if self.running_path == self.selected_path:
                self.pending_path = None
            else:
                self.pending_path = self.selected_path
                self.status_text.set("Останавливается предыдущий скрипт…")
            self.stop_process()
        else:
            self.run_script(self.selected_path)

    def bash_executable(self) -> Path | None:
        candidates = [Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe", Path(os.environ.get("LOCALAPPDATA", "")) / "Programs/Git/bin/bash.exe"]
        return next((p for p in candidates if p.exists()), None)

    def run_script(self, path: Path) -> None:
        bash = self.bash_executable()
        if not bash:
            messagebox.showerror(APP_NAME, "Git Bash не найден. Установите Git for Windows.")
            return
        if self.process and self.process.poll() is None: self.stop_process()
        self.running_path = path
        self.last_runs[str(path)] = datetime.now().isoformat()
        command_line = f'$ "{bash}" "{path}"\n\n'
        self.output_by_path[str(path)] = command_line
        self.statuses.pop(str(path), None)
        self.update_controls()
        self.status_text.set("Выполняется…")
        self.set_output_widget(command_line)
        flags = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_NO_WINDOW
        try:
            self.process = subprocess.Popen([str(bash), str(path)], cwd=path.parent, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace", bufsize=1, creationflags=flags)
        except OSError as exc:
            self.running_path = None; self.process = None
            self.append_output(path, f"Ошибка запуска: {exc}\n")
            return
        threading.Thread(target=self.read_process, args=(path, self.process), daemon=True).start()
        self.save_state(); self.reload_scripts()

    def read_process(self, path: Path, proc: subprocess.Popen) -> None:
        assert proc.stdout is not None
        for line in iter(proc.stdout.readline, ""):
            self.events.put(("output", (path, line)))
        code = proc.wait()
        self.events.put(("finished", (path, code, proc)))

    def poll_events(self) -> None:
        try:
            while True:
                kind, payload = self.events.get_nowait()
                if kind == "output":
                    path, text = payload; self.append_output(path, text)
                elif kind == "finished":
                    path, code, proc = payload
                    self.append_output(path, f"\n[Процесс завершён с кодом {code}]\n")
                    self.statuses[str(path)] = code
                    if self.process is proc:
                        self.process = None; self.running_path = None
                        self.update_controls()
                    if self.selected_path == path: self.status_text.set(f"Завершён, код {code}")
                    self.save_state(); self.reload_scripts()
                    if self.pending_path is not None:
                        pending = self.pending_path
                        self.pending_path = None
                        self.run_script(pending)
                elif kind == "force_stop":
                    if self.process and self.process.pid == payload and self.process.poll() is None:
                        self.process.kill()
        except queue.Empty: pass
        self.after(80, self.poll_events)

    def append_output(self, path: Path, text: str) -> None:
        key = str(path); self.output_by_path[key] = self.output_by_path.get(key, "") + text
        if self.selected_path == path:
            self.output.configure(state="normal"); self.output.insert("end", text); self.output.see("end"); self.output.configure(state="disabled")

    def stop_process(self) -> None:
        if not self.process or self.process.poll() is not None: return
        process_id = self.process.pid
        if self.running_path:
            self.append_output(self.running_path, "\n[Остановка процесса…]\n")
        self.status_text.set("Останавливается…")
        self.run_button.configure(state="disabled")
        threading.Thread(target=self.kill_process_tree, args=(process_id,), daemon=True).start()

    def kill_process_tree(self, process_id: int) -> None:
        try:
            result = subprocess.run(
                ["taskkill.exe", "/PID", str(process_id), "/T", "/F"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                creationflags=subprocess.CREATE_NO_WINDOW,
                timeout=10,
                check=False,
            )
            if result.returncode != 0:
                self.events.put(("force_stop", process_id))
        except (OSError, subprocess.TimeoutExpired):
            self.events.put(("force_stop", process_id))

    def force_stop(self) -> None:
        if self.process and self.process.poll() is None: self.process.kill()

    def send_input(self) -> None:
        value = self.input_entry.get()
        if not value or not self.process or not self.process.stdin: return
        try:
            self.process.stdin.write(value + "\n"); self.process.stdin.flush()
            if self.running_path: self.append_output(self.running_path, value + "\n")
            self.input_entry.delete(0, "end")
        except OSError: pass

    def set_output_widget(self, text: str) -> None:
        self.output.configure(state="normal"); self.output.delete("1.0", "end"); self.output.insert("1.0", text); self.output.see("end"); self.output.configure(state="disabled")

    def copy_output(self) -> None:
        self.clipboard_clear(); self.clipboard_append(self.output.get("1.0", "end-1c"))

    def clear_output(self) -> None:
        if self.selected_path:
            self.output_by_path.pop(str(self.selected_path), None); self.statuses.pop(str(self.selected_path), None)
            self.set_output_widget(EMPTY_OUTPUT); self.save_state()

    def open_editor(self, event=None) -> None:
        if event is not None and hasattr(event, "y"):
            item = self.tree.identify_row(event.y)
            if item: self.tree.selection_set(item); self.on_select()
        if not self.selected_path: return
        path = self.selected_path
        editor = tk.Toplevel(self); editor.title(f"Редактор — {path.name}")
        editor.geometry(self.state_data.get("editor_geometry", "850x650")); editor.configure(bg=BG)
        top = ttk.Frame(editor, padding=10); top.pack(fill="x")
        name = ttk.Entry(top); name.insert(0, path.name); name.pack(side="left", fill="x", expand=True)
        text = tk.Text(editor, undo=True, wrap="none", font=("Cascadia Mono", 13), bg=FIELD, fg="#d6d9df",
                       insertbackground=TEXT, selectbackground="#31588b", relief="flat", padx=14, pady=14)
        text.pack(fill="both", expand=True, padx=10, pady=(0, 10))
        try: text.insert("1.0", path.read_text(encoding="utf-8"))
        except OSError as exc: messagebox.showerror(APP_NAME, str(exc), parent=editor); editor.destroy(); return
        def save_editor(_event=None):
            clean = name.get().strip()
            if not clean or clean in (".", "..") or re.search(r'[\\/:*?"<>|]', clean): messagebox.showerror(APP_NAME, "Некорректное имя файла", parent=editor); return
            target = path.with_name(clean)
            if self.running_path == path: messagebox.showerror(APP_NAME, "Сначала остановите скрипт", parent=editor); return
            if target != path and target.exists(): messagebox.showerror(APP_NAME, "Файл с таким именем уже существует", parent=editor); return
            try:
                target.write_text(text.get("1.0", "end-1c"), encoding="utf-8")
                if target != path:
                    path.unlink()
                    for mapping in (self.notes, self.output_by_path, self.last_runs, self.statuses):
                        if str(path) in mapping: mapping[str(target)] = mapping.pop(str(path))
                    self.selected_path = target
                self.save_state(); self.reload_scripts(); editor.title(f"Редактор — {target.name} — сохранено")
            except OSError as exc: messagebox.showerror(APP_NAME, str(exc), parent=editor)
        ttk.Button(top, text="Сохранить", command=save_editor).pack(side="left", padx=(8, 0))
        editor.bind("<Control-s>", save_editor)
        editor.protocol("WM_DELETE_WINDOW", lambda: self.close_child_window(editor, "editor_geometry"))

    def show_settings(self) -> None:
        win = tk.Toplevel(self); win.title("Настройки"); win.resizable(False, False); win.configure(bg=BG)
        win.geometry(self.state_data.get("settings_geometry", "430x210"))
        frame = ttk.Frame(win, padding=18); frame.pack()
        ttk.Label(frame, text="Тема:").grid(row=0, column=0, sticky="w")
        theme_names = {"Системная": "system", "Светлая": "light", "Тёмная": "dark"}
        current_name = next((name for name, value in theme_names.items() if value == self.theme_mode.get()), "Тёмная")
        theme_choice = ttk.Combobox(frame, values=list(theme_names), state="readonly", width=18)
        theme_choice.set(current_name)
        theme_choice.grid(row=0, column=1, padx=10, sticky="ew")
        def change_theme(_event=None):
            self.theme_mode.set(theme_names[theme_choice.get()])
            self.configure_theme()
            win.configure(bg=BG)
        theme_choice.bind("<<ComboboxSelected>>", change_theme)
        ttk.Label(frame, text="Размер текста терминала:").grid(row=1, column=0, sticky="w", pady=(16, 0))
        scale = ttk.Scale(frame, from_=10, to=24, variable=self.font_size, command=lambda _v: self.apply_settings())
        scale.grid(row=1, column=1, padx=10, pady=(16, 0))
        ttk.Checkbutton(frame, text="Переносить длинные строки", variable=self.wrap_lines, command=self.apply_settings).grid(row=2, column=0, columnspan=2, sticky="w", pady=16)
        win.protocol("WM_DELETE_WINDOW", lambda: self.close_child_window(win, "settings_geometry"))

    def close_child_window(self, window: tk.Toplevel, state_key: str) -> None:
        self.state_data[state_key] = window.geometry()
        self.save_state()
        window.destroy()

    def apply_settings(self) -> None:
        size = self.font_size.get(); self.output.configure(font=("Cascadia Mono", size), wrap="word" if self.wrap_lines.get() else "none"); self.input_entry.configure(font=("Cascadia Mono", size)); self.save_state()

    def close_app(self) -> None:
        if self.process and self.process.poll() is None:
            if not messagebox.askyesno(APP_NAME, "Скрипт выполняется. Остановить его и выйти?"): return
            self.process.kill()
        self.save_state(); self.destroy()


if __name__ == "__main__":
    ScriptRunner().mainloop()
