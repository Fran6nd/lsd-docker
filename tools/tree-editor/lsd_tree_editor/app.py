# app.py -- starting and ending the program
# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
"""`lsd-tree-editor`: the window. `--headless` runs the same session with
no window (the tests use it): it launches a server if asked, waits for a
signal, and removes the server before it exits -- as the window does."""

from __future__ import annotations

import argparse
import signal
import sys
import threading

from .lock import AlreadyRunning
from .server import DEFAULT_IMAGE, ServerError, Session, Setup
from .docker import DockerError

SIGNALS = [getattr(signal, n) for n in ("SIGINT", "SIGTERM", "SIGHUP") if hasattr(signal, n)]


def _arguments(argv):
    p = argparse.ArgumentParser(prog="lsd-tree-editor", description="A behaviour-tree editor for the server's bots.")
    p.add_argument("file", nargs="?", help="a tree file (.bt) to open")
    p.add_argument("--launch", action="store_true", help="launch the server at once")
    p.add_argument("--image", default=None, help=f"the server's image (default: the last used, else {DEFAULT_IMAGE})")
    p.add_argument("--gamemode", default="tdm")
    p.add_argument("--bots", type=int, default=3, help="bots a team")
    p.add_argument("--level", type=int, default=5)
    p.add_argument("--map", choices=["random", "generated"], default="random")
    p.add_argument("--headless", action="store_true", help="no window: for tests and scripts")
    return p.parse_args(argv)


def headless(session: Session, args) -> int:
    stop = threading.Event()
    for s in SIGNALS:
        signal.signal(s, lambda *_: stop.set())
    code = 0
    try:
        if args.launch:
            setup = Setup(image=args.image or DEFAULT_IMAGE, gamemode=args.gamemode, map=args.map,
                          bots_team1=args.bots, bots_team2=args.bots, level=args.level)
            inst = session.launch(setup, lambda text: print(text, flush=True))
            print(f"READY {inst.name} {inst.port}", flush=True)
        else:
            print("READY", flush=True)
        while not stop.wait(0.2):
            pass
    except (ServerError, DockerError) as e:
        print(f"lsd-tree-editor: {e}", file=sys.stderr)
        code = 1
    print("stopping the server...", flush=True)
    problem = session.shutdown()
    if problem:
        print(f"lsd-tree-editor: {problem}", file=sys.stderr)
        return 1
    print("stopped", flush=True)
    return code


def main(argv=None) -> int:
    args = _arguments(sys.argv[1:] if argv is None else argv)
    session = Session()
    try:
        session.start()
    except AlreadyRunning as e:
        print(f"lsd-tree-editor: {e}", file=sys.stderr)
        if not args.headless:
            _tell(str(e))
        return 3
    if args.headless:
        return headless(session, args)

    from PySide6.QtCore import QTimer
    from PySide6.QtWidgets import QApplication
    from .ui import APP_NAME, MainWindow

    app = QApplication(sys.argv[:1])
    app.setApplicationName(APP_NAME)
    app.setQuitOnLastWindowClosed(False)       # the window decides: the server goes first
    window = MainWindow(session)
    if args.image:
        window.image.setEditText(args.image)
    window.gamemode.setCurrentText(args.gamemode)
    window.team1.setValue(args.bots)
    window.team2.setValue(args.bots)
    window.level.setValue(args.level)
    window.map.setCurrentIndex(max(0, window.map.findData(args.map)))
    window.show()
    if args.file:
        window.open_file(args.file)
    if args.launch:
        QTimer.singleShot(0, window.launch)

    # Ctrl-C, kill, a closed terminal: the same end as the window's close button
    for s in SIGNALS:
        signal.signal(s, lambda *_: QTimer.singleShot(0, window.shut_down))
    wake = QTimer()                            # lets Python see a signal while Qt waits
    wake.timeout.connect(lambda: None)
    wake.start(200)

    app.exec()
    problem = session.shutdown()               # done already unless the loop ended some other way
    return 1 if problem else 0


def _tell(text: str) -> None:
    try:
        from PySide6.QtWidgets import QApplication, QMessageBox
        app = QApplication.instance() or QApplication(sys.argv[:1])
        if app.platformName() != "offscreen":
            QMessageBox.warning(None, "LSD tree editor", text)
    except Exception:
        pass
