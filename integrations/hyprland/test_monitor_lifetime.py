#!/usr/bin/env python3
"""Offline regression harness for the patched 0.56.2 sources.

Compile the actual session/factory method bodies, with fake window/output and
renderer boundaries, but real Hyprutils weak pointers and signals. No Wayland
connection, compositor process, display changes or capture requests are made.
This is not an end-to-end hotplug or GPU test. Protocol checks are source contracts.
"""
import argparse
from pathlib import Path
import re
import shlex
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent


def between(text, start, end):
    return text[text.index(start):text.index(end, text.index(start))]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="patched Hyprland 0.56.2 source directory")
    args = parser.parse_args()
    source = args.source.resolve()
    # Refuse stock or differently patched sources: these tests validate the fix,
    # and must never act as a crash reproducer against an unpatched compositor.
    subprocess.run(["git", "apply", "--reverse", "--check", str(HERE / "0001-screenshare-monitor-lifetime.patch")],
                   cwd=source, check=True)
    base = source / "src/managers/screenshare"
    header = (base / "ScreenshareManager.hpp").read_text()
    declarations = between(header, "namespace Screenshare {", "    class CCursorshareSession {")
    declarations += between(header, "    class CScreenshareManager {", "    inline UP<CScreenshareManager>& mgr()")
    declarations += "UP<CScreenshareManager>& mgr();\n}\n"
    # Test-only constructor/registry access; production access remains private.
    declarations = declarations.replace("      private:", "      public:")
    session = (base / "ScreenshareSession.cpp").read_text()
    session = re.sub(r'^#include[^\n]*\n', '', session, flags=re.M)
    # External notification/logging is not under test. Session stop signals are.
    external_events = between(session, "void CScreenshareSession::screenshareEvents(",
                              "const std::vector<DRMFormat>& CScreenshareSession::allowedFormats()")
    session = session.replace(external_events,
                              "void CScreenshareSession::screenshareEvents(bool sharing) { m_sharing = sharing; }\n\n")
    manager = (base / "ScreenshareManager.cpp").read_text()
    factories = between(manager, "UP<CScreenshareSession> CScreenshareManager::newSession(",
                        "UP<CCursorshareSession> CScreenshareManager::newCursorSession(")
    managed = between(manager, "WP<CScreenshareSession> CScreenshareManager::getManagedSession(",
                      "bool CScreenshareManager::isOutputBeingSSd(")
    managed += manager[manager.index("CScreenshareManager::SManagedSession::SManagedSession("):]

    for filename, cls in [("ToplevelExport.cpp", "CToplevelExportFrame"), ("Screencopy.cpp", "CScreencopyFrame")]:
        text = (source / "src/protocols" / filename).read_text()
        constructor = between(text, cls + "::" + cls + "(", "    m_frame = m_session->nextFrame(")
        assert re.search(r'if \(!m_session \|\| !m_session->isActive\(\)\)\s*\{\s*'
                         r'm_resource->sendFailed\(\);\s*return;', constructor), filename
        sharing = text[text.index("void " + cls + "::shareFrame("):]
        assert "!m_frame || m_session.expired() || !m_session->isActive() || !m_session->monitor()" in sharing, filename
    print("Protocol failure-response source contracts: 2 passed", flush=True)

    with tempfile.TemporaryDirectory(prefix="overview-monitor-unit-") as directory:
        tmp = Path(directory)
        (tmp / "production.inc").write_text(declarations + (HERE / "test_support.inc").read_text() +
                                            session + factories + managed)
        flags = shlex.split(subprocess.check_output(["pkg-config", "--cflags", "--libs", "hyprutils", "gtest_main"], text=True))
        binary = tmp / "test"
        subprocess.run(["c++", "-std=c++26", "-g", "-O1", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                        "-I", str(tmp), str(HERE / "test_monitor_lifetime.cpp"), "-o", str(binary), *flags], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
