#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""inFAMOUS Second Son launcher, Qt Quick edition (PySide6). The default launcher of the packages; the classic
Tk launcher (infamous_launcher.py) ships next to it as "<name> (classic)". Same settings file, same game start
path (infamous_run.prepare/launch), same tlg.ini as the Tk launcher.

    python3 infamous_launcher_qt.py            # needs: pip install PySide6-Essentials
"""
import multiprocessing
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import infamous_run as tlg_run  # noqa: E402


def main():
    multiprocessing.freeze_support()   # packaged: the shader list generator starts worker processes (re-runs this exe)
    args = sys.argv[1:]
    # Same packaged roles as the Tk launcher: preparation scripts and a window-less --play.
    if args[:1] == ['--script'] and len(args) > 1:
        sys.exit(tlg_run.run_script(args[1:]))
    if args[:1] == ['--clear-shader-cache']:
        sys.exit(tlg_run.main(args))
    if args[:1] == ['--play']:
        sys.exit(tlg_run.main(args[1:]))
    if args[:1] == ['--selftest']:  # CI smoke test of the frozen launcher: opens offscreen, touches nothing
        try:
            from qt import selftest
            code = selftest.run()
        except Exception as error:  # never let a windowed exe open an error dialog in CI
            code = 3
            if os.environ.get('ISS_SELFTEST_OUT'):
                Path(os.environ['ISS_SELFTEST_OUT']).write_text(f'selftest FAILED: {error!r}\n', encoding='utf-8')
        sys.exit(code)
    os.environ.setdefault('QT_QUICK_CONTROLS_STYLE', 'Basic')  # we style the controls ourselves
    try:
        from qt.app import App
    except ImportError as error:
        sys.exit(f'PySide6 is missing ({error}). Install it with: pip install PySide6-Essentials\n'
                 f'PySide6 não encontrado. Instale com: pip install PySide6-Essentials')
    code = App().run()
    # Settings are already saved and the game runs on its own: skip the interpreter teardown, where
    # PySide6/QML destructors and leftover threads could keep a closed launcher alive (Windows).
    for stream in (sys.stdout, sys.stderr):   # None in the windowed executable
        if stream is not None:
            stream.flush()
    tlg_run.wait_for_games()   # Linux packages: the game runs from files mounted for this process
    os._exit(code if isinstance(code, int) else 0)


if __name__ == '__main__':
    main()
