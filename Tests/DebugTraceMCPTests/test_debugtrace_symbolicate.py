"""Tests for Tools/debugtrace-symbolicate: python3 -m unittest discover -s Tests/DebugTraceMCPTests

atos is replaced by a stub that answers `fn_<address>`, so these cover which frames are
resolved, against which dSYM, and what is printed when there is none."""
import importlib.machinery
import importlib.util
import io
import json
import os
import stat
import tempfile
import unittest

TOOL = os.path.join(os.path.dirname(__file__), "..", "..", "Tools", "debugtrace-symbolicate")
spec = importlib.util.spec_from_loader("symbolicate", importlib.machinery.SourceFileLoader("symbolicate", TOOL))
sym = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sym)

APP, SYSTEM = "AAAAAAAA-0000-0000-0000-000000000001", "BBBBBBBB-0000-0000-0000-000000000002"


def frame(uuid, offset, name=None, subs=None):
    f = {"binaryUUID": uuid, "offsetIntoBinaryTextSegment": offset, "sampleCount": 1}
    if name:
        f["binaryName"] = name
    if subs:
        f["subFrames"] = subs
    return f


# 27+: a crashDiagnostic with callStackThreads and a binaryInfo table.
NEW = {"crashDiagnostic": {"signal": 5, "exceptionType": 6, "callStackTree": {
    "binaryInfo": [{"uuid": APP, "name": "App"}, {"uuid": SYSTEM, "name": "libsystem"}],
    "callStackThreads": [
        {"threadAttributed": False, "rootFrames": [frame(SYSTEM, 0x10)]},
        {"threadAttributed": True, "rootFrames": [frame(APP, 0x100, subs=[frame(SYSTEM, 0x20)])]}]}},
    "environment": {"applicationBuildVersion": "abc1234"}}

# Before 27: crashDiagnostics, frames carry their own binaryName.
LEGACY = {"crashDiagnostics": [{"diagnosticMetaData": {"appBuildVersion": "def5678", "signal": 11},
    "callStackTree": {"callStacks": [{"threadAttributed": True,
        "callStackRootFrames": frame(APP, 0x200, "App", subs=[frame(SYSTEM, 0x30, "libsystem")])}]}}]}


class SymbolicateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = self.tmp.name
        stub = os.path.join(root, "atos")
        with open(stub, "w") as f:
            f.write('#!/bin/sh\nshift 6\nfor a; do echo "fn_$a"; done\n')
        os.chmod(stub, os.stat(stub).st_mode | stat.S_IXUSR)
        os.environ["DEBUGTRACE_ATOS"] = stub
        self.addCleanup(os.environ.pop, "DEBUGTRACE_ATOS", None)
        self.dsyms = os.path.join(root, "dsyms")

    def slot(self, name, uuid, build, mtime=None):
        directory = os.path.join(self.dsyms, name)
        os.makedirs(directory)
        open(os.path.join(directory, "App.dwarf"), "w").close()
        path = os.path.join(directory, "uuids.json")
        json.dump({"bundleId": "x", "device": "d", "build": build,
                   "uuids": {uuid: {"arch": "arm64", "dwarf": "App.dwarf"}}}, open(path, "w"))
        if mtime:
            os.utime(path, (mtime, mtime))

    def run_report(self, report, show_all=False, known=None):
        path = os.path.join(self.tmp.name, "r.json")
        json.dump({"id": "r", "kinds": ["crash"], "source": "test", "report": report}, open(path, "w"))
        out = io.StringIO()
        sym.render(path, show_all, sym.archive(self.dsyms) if known is None else known, out)
        return out.getvalue()

    def test_new_layout_resolves_only_the_archived_binary(self):
        self.slot("a", APP, "abc1234")
        text = self.run_report(NEW)
        self.assertIn("fn_0x100000100", text)         # vmaddr + offset
        self.assertIn("libsystem +0x20", text)         # no dSYM: name and offset
        self.assertIn("crashed build abc1234", text)
        self.assertNotIn("libsystem +0x10", text)      # the other thread is not blamed
        self.assertIn("unsymbolicated in the blamed thread: libsystem", text)

    def test_all_threads_flag_prints_the_rest(self):
        self.slot("a", APP, "abc1234")
        self.assertIn("libsystem +0x10", self.run_report(NEW, show_all=True))

    def test_legacy_layout(self):
        self.slot("a", APP, "def5678")
        text = self.run_report(LEGACY)
        self.assertIn("fn_0x100000200", text)
        self.assertIn("crashed build def5678", text)
        self.assertIn("signal 11", text)

    def test_no_archive_says_so_and_keeps_offsets(self):
        text = self.run_report(NEW)
        self.assertIn("App +0x100", text)
        self.assertIn("no dSYMs kept", text)

    def test_newest_archive_wins_a_duplicate_uuid(self):
        self.slot("old", APP, "old", mtime=1000)
        self.slot("new", APP, "new", mtime=2000)
        self.assertEqual(sym.archive(self.dsyms)[APP]["build"], "new")

    def test_trace_folder_is_found_by_path_and_id(self):
        folder = os.path.join(self.tmp.name, "trace", "files", "crashes")
        os.makedirs(folder)
        open(os.path.join(folder, "r.json"), "w").write("{}")
        self.assertEqual(len(sym.report_files(os.path.join(self.tmp.name, "trace"))), 1)
        self.assertEqual(sym.report_files(os.path.join(self.tmp.name, "nothing")), [])

    def test_ips_resolves_app_frames_and_keeps_the_devices_own_symbols(self):
        self.slot("a", APP, "abc1234")
        ips = os.path.join(self.tmp.name, "c.ips")
        header = {"app_name": "App", "app_version": "1.0", "build_version": "abc1234", "os_version": "xrOS 27.2"}
        body = {"pid": 7, "captureTime": "t", "faultingThread": 1,
                "exception": {"type": "EXC_BREAKPOINT", "signal": "SIGTRAP"}, "termination": {"indicator": "Trace/BPT trap: 5"},
                "usedImages": [{"uuid": SYSTEM.lower(), "name": "libsystem"}, {"uuid": APP.lower(), "name": "App"}],
                "threads": [{"frames": [{"imageIndex": 0, "imageOffset": 1, "symbol": "idle"}]},
                            {"triggered": True, "frames": [{"imageIndex": 1, "imageOffset": 0x100},
                                                           {"imageIndex": 0, "imageOffset": 0x20, "symbol": "start", "symbolLocation": 8}]}]}
        open(ips, "w").write(json.dumps(header) + "\n" + json.dumps(body))
        out = io.StringIO()
        sym.render_ips(ips, False, sym.archive(self.dsyms), out)
        text = out.getvalue()
        self.assertIn("fn_0x100000100", text)       # the app frame, from the archive
        self.assertIn("start + 8", text)             # the device's own symbol kept
        self.assertIn("EXC_BREAKPOINT, SIGTRAP", text)
        self.assertNotIn("idle", text)               # the other thread, not blamed
        sym.render_ips(ips, True, {}, out)
        self.assertIn("no dSYM kept for this build's binary", out.getvalue())

    def test_a_hang_follows_the_heaviest_branch(self):
        root = frame(APP, 1, subs=[dict(frame(APP, 2), sampleCount=1), dict(frame(APP, 3), sampleCount=9)])
        self.assertEqual([f["offsetIntoBinaryTextSegment"] for f in sym.heaviest(root)], [1, 3])


if __name__ == "__main__":
    unittest.main()
