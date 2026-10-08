"""Tests for the live-patching tools: python3 -m unittest discover -s Tests/DebugTraceMCPTests

The compiler, the signer and the device are not involved: these cover the parts
that decide what is sent and what the agent is told."""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import tempfile
import unittest

TOOLS = os.path.join(os.path.dirname(__file__), "..", "..", "Tools")


def load(name, path):
    spec = importlib.util.spec_from_loader(name, importlib.machinery.SourceFileLoader(name, path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


inject = load("debugtrace_inject", os.path.join(TOOLS, "debugtrace-inject", "debugtrace-inject"))
mcp = load("debugtrace_mcp_for_inject", os.path.join(TOOLS, "debugtrace-mcp"))

DRIVER_LINE = (
    "builtin-SwiftDriver -- /Applications/Xcode.app/usr/bin/swiftc -module-name Game -O -whole-module-optimization "
    "@{filelist} -Xfrontend -enable-implicit-dynamic -default-isolation\\=MainActor -sdk /SDK -target arm64-apple-xros26.0 "
    "-g -module-cache-path /cache/ModuleCache.noindex -module-cache-path /cache/SwiftExplicitPrecompiledModules "
    "-I /products -Xcc -ivfsstatcache -Xcc /x.sdkstatcache -Xcc -I/products/include -emit-module -emit-module-path /o/Game.swiftmodule "
    "-output-file-map /o/map.json -num-threads 12 -Xfrontend -serialize-debugging-options -working-directory /proj -c"
)


class CompileCommandTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.filelist = os.path.join(self.dir, "Game.SwiftFileList")
        with open(self.filelist, "w") as handle:
            handle.write("/proj/A.swift\n/proj/B.swift\n")

    def commands(self):
        return inject.compile_commands("noise\n" + DRIVER_LINE.format(filelist=self.filelist) + "\nmore noise\n")

    def test_reads_the_module_its_sources_and_working_directory(self):
        [(module, args, cwd, files)] = self.commands()
        self.assertEqual((module, cwd, files), ("Game", "/proj", ["/proj/A.swift", "/proj/B.swift"]))
        # xcodebuild's escaped `=` is unescaped.
        self.assertIn("-default-isolation=MainActor", args)

    def test_a_patch_compile_drops_what_builds_the_apps_products_and_keeps_the_rest(self):
        [(module, args, cwd, files)] = self.commands()
        kept = inject.patch_compile_arguments({"args": args}, module)
        for gone in ("-emit-module", "-emit-module-path", "-output-file-map", "-num-threads", "-c", "-g",
                     "-whole-module-optimization", "-working-directory", "-module-name", "-serialize-debugging-options",
                     "-ivfsstatcache"):
            self.assertNotIn(gone, kept)
        self.assertFalse([a for a in kept if a.startswith("@")])
        for stays in ("-O", "-sdk", "-target", "-I", "-default-isolation=MainActor", "-enable-implicit-dynamic",
                      "-I/products/include"):
            self.assertIn(stays, kept)
        # Only the module cache that survives between builds is kept.
        caches = [kept[i + 1] for i, a in enumerate(kept) if a == "-module-cache-path"]
        self.assertEqual(caches, ["/cache/ModuleCache.noindex"])


class RunSnippetTests(unittest.TestCase):
    def test_leading_imports_are_hoisted_out_of_the_function_body(self):
        source = inject.run_source("App", "import DebugTrace\n@testable import Other\nlet x = 2\nreturn x")
        body = source.split("func __debugtraceRun() -> Any {")[1]
        self.assertNotIn("import", body)
        self.assertIn("import DebugTrace", source.split("func __debugtraceRun")[0])
        self.assertIn("@testable import Other", source.split("func __debugtraceRun")[0])
        self.assertIn("return x", body)

    def test_a_snippet_without_imports_is_unchanged(self):
        source = inject.run_source("App", "return 1 + 1")
        self.assertIn("{\nreturn 1 + 1\n}", source)


class InjectToolTests(unittest.TestCase):
    """The agent-facing tool, with the helper and the app replaced."""

    def setUp(self):
        self._saved = (mcp.resolve, mcp.verified, mcp.request, mcp.run_inject_tool, mcp.app_call)
        self.addCleanup(self.restore)
        self.helper_calls, self.app_calls = [], []
        mcp.resolve = lambda app: {"appName": "Game", "injectDir": "/proj/build/inject", "projectRoot": "/proj"}
        mcp.verified = lambda session: session

    def restore(self):
        mcp.resolve, mcp.verified, mcp.request, mcp.run_inject_tool, mcp.app_call = self._saved

    def wire(self, patches, plan, load_reply=None):
        def helper(session, *command):
            self.helper_calls.append(command)
            return (plan, 0 if plan.get("ok") else 1) if command[0] == "patch" else ({"ok": True}, 0)

        def app(session, name, arguments):
            self.app_calls.append((name, arguments))
            if name == "_patches":
                return 200, {"ok": True, "data": {"patches": patches}}
            return 200, load_reply or {"ok": True, "data": {"output": None}}

        mcp.run_inject_tool, mcp.app_call = helper, app

    def call(self, arguments):
        reply = mcp.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                            "params": {"name": "inject", "arguments": arguments}})
        result = reply["result"]
        return result, json.loads(result["content"][0]["text"]) if result["content"][0]["text"].startswith("{") else None

    def test_an_app_not_launched_for_patching_says_how_to_launch_it(self):
        mcp.resolve = lambda app: {"appName": "Game"}
        result, _ = self.call({})
        self.assertTrue(result["isError"])
        self.assertIn("--inject", result["content"][0]["text"])

    def test_a_relaunched_app_resets_the_live_sources_first(self):
        self.wire([], {"ok": True, "changed": [], "note": "nothing"})
        self.call({})
        self.assertEqual(self.helper_calls[0][0], "reset")

    def test_a_running_patched_app_is_not_reset(self):
        self.wire([{"label": "x"}], {"ok": True, "changed": [], "note": "nothing"})
        self.call({})
        self.assertNotIn("reset", [c[0] for c in self.helper_calls])

    def test_files_and_run_are_passed_to_the_helper(self):
        self.wire([{"label": "x"}], {"ok": True, "changed": []})
        self.call({"files": "A.swift", "run": "return 1"})
        patch = next(c for c in self.helper_calls if c[0] == "patch")
        self.assertIn("A.swift", patch)
        self.assertEqual(patch[patch.index("--run") + 1], "return 1")

    def test_a_rebuild_verdict_is_an_error_and_nothing_is_sent(self):
        plan = {"ok": False, "error": "this change cannot be applied", "rebuildNeeded": True}
        self.wire([], plan)
        result, body = self.call({})
        self.assertTrue(result["isError"])
        self.assertTrue(body["rebuildNeeded"])
        self.assertNotIn("_inject", [name for name, _ in self.app_calls])

    def test_a_patch_is_sent_base64_then_committed_and_summarised(self):
        path = os.path.join(tempfile.mkdtemp(), "p.dylib")
        with open(path, "wb") as handle:
            handle.write(b"\xcf\xfa\xed\xfe patch")
        self.addCleanup(shutil.rmtree, os.path.dirname(path), True)
        plan = {"ok": True, "dylibs": [{"module": "Game", "path": path, "label": "Game: A.swift"}],
                "files": {"A.swift": {"patched": ["Thing.value()"], "added": ["Thing.fresh()"]}},
                "commit": ["/proj/A.swift"], "timings": {"compileMs": 900}}
        self.wire([{"label": "x"}], plan, {"ok": True, "data": {"output": "2m 5s"}})
        result, body = self.call({})
        self.assertFalse(result.get("isError", False))
        name, arguments = next(c for c in self.app_calls if c[0] == "_inject")
        self.assertEqual(arguments["label"], "Game: A.swift")
        import base64
        self.assertEqual(base64.b64decode(arguments["patch"]), b"\xcf\xfa\xed\xfe patch")
        self.assertEqual(body["patched"], ["A.swift: Thing.value()"])
        self.assertEqual(body["added"], ["A.swift: Thing.fresh()"])
        self.assertEqual(body["output"], "2m 5s")
        self.assertIn("loadMs", body["timings"])
        self.assertEqual([c[0] for c in self.helper_calls][-1], "commit")

    def test_a_patch_too_big_for_the_request_is_deflated_and_sizes_itself(self):
        import base64, zlib, random
        # Incompressible bytes would not fit; mangled-name-like text does, as in a real SwiftUI patch.
        names = b"$s7SwiftUI4ViewPAAE" + b"7HypnosV13SettingsTabViewV" * 120_000
        path = os.path.join(tempfile.mkdtemp(), "big.dylib")
        with open(path, "wb") as handle:
            handle.write(names)
        self.addCleanup(shutil.rmtree, os.path.dirname(path), True)
        plan = {"ok": True, "dylibs": [{"module": "Game", "path": path, "label": "Game: S.swift"}], "commit": []}
        self.wire([{"label": "x"}], plan)
        result, body = self.call({})
        self.assertFalse(result.get("isError", False), body)
        _, arguments = next(c for c in self.app_calls if c[0] == "_inject")
        self.assertEqual(arguments["encoding"], "deflate")
        self.assertEqual(arguments["bytes"], len(names))
        self.assertEqual(zlib.decompress(base64.b64decode(arguments["patch"]), -15), names)
        self.assertLess(len(arguments["patch"]), mcp.MAX_PATCH_BASE64)

    def test_a_small_patch_is_never_deflated_so_an_older_runtime_still_takes_it(self):
        path = os.path.join(tempfile.mkdtemp(), "p.dylib")
        with open(path, "wb") as handle:
            handle.write(b"small")
        self.addCleanup(shutil.rmtree, os.path.dirname(path), True)
        self.wire([{"label": "x"}], {"ok": True, "dylibs": [{"module": "G", "path": path, "label": "G"}], "commit": []})
        self.call({})
        _, arguments = next(c for c in self.app_calls if c[0] == "_inject")
        self.assertNotIn("encoding", arguments)

    def test_an_old_runtime_refusing_encoding_is_told_to_relaunch(self):
        import random
        path = os.path.join(tempfile.mkdtemp(), "big.dylib")
        with open(path, "wb") as handle:
            handle.write(b"abcdefgh" * 400_000)
        self.addCleanup(shutil.rmtree, os.path.dirname(path), True)
        self.wire([{"label": "x"}], {"ok": True, "dylibs": [{"module": "G", "path": path, "label": "G"}], "commit": []})
        mcp.app_call = lambda session, name, arguments: (
            (200, {"ok": True, "data": {"patches": [{"label": "x"}]}}) if name == "_patches"
            else (400, {"ok": False, "error": {"code": "invalid_argument", "message": "unknown parameter 'encoding'"}}))
        result, _ = self.call({})
        self.assertTrue(result["isError"])
        self.assertIn("relaunch", result["content"][0]["text"])

    def test_an_edit_that_changes_nothing_compiled_says_so_and_is_recorded(self):
        plan = {"ok": True, "dylibs": [], "commit": ["/proj/A.swift"], "files": {"A.swift": {"hasPatch": False}}}
        self.wire([{"label": "x"}], plan)
        result, body = self.call({})
        self.assertFalse(result.get("isError", False))
        self.assertTrue(body["nothingToPatch"])
        self.assertEqual(body["applied"], [])
        self.assertIn("#if", body["note"])
        self.assertNotIn("_inject", [name for name, _ in self.app_calls])
        self.assertEqual([c[0] for c in self.helper_calls][-1], "commit")

    def test_warnings_reach_the_reply_even_when_nothing_was_patched(self):
        plan = {"ok": True, "dylibs": [], "commit": ["/proj/A.swift"],
                "files": {"A.swift": {"hasPatch": False, "warnings": ["E: its cases were reordered"]}}}
        self.wire([{"label": "x"}], plan)
        _, body = self.call({})
        self.assertTrue(body["nothingToPatch"])
        self.assertEqual(body["warnings"], ["A.swift: E: its cases were reordered"])

    def test_a_refused_load_commits_nothing_and_says_what_was_applied(self):
        path = os.path.join(tempfile.mkdtemp(), "p.dylib")
        with open(path, "wb") as handle:
            handle.write(b"x")
        self.addCleanup(shutil.rmtree, os.path.dirname(path), True)
        plan = {"ok": True, "dylibs": [{"module": "Game", "path": path, "label": "Game: A.swift"}],
                "commit": ["/proj/A.swift"]}
        self.wire([{"label": "x"}], plan, {"ok": False, "error": {"code": "failed_precondition", "message": "refused"}})
        result, body = self.call({})
        self.assertTrue(result["isError"])
        self.assertEqual(body["applied"], [])
        self.assertNotIn("commit", [c[0] for c in self.helper_calls])

    def test_a_missing_endpoint_says_to_link_the_product(self):
        mcp.app_call = lambda session, name, arguments: (404, {"ok": False, "error": {"code": "not_found"}})
        result, _ = self.call({})
        self.assertIn("DebugTraceInject", result["content"][0]["text"])

    def test_aliases_for_files_and_run_are_accepted(self):
        self.wire([{"label": "x"}], {"ok": True, "changed": []})
        self.call({"file": "A.swift", "code": "return 2"})
        patch = next(c for c in self.helper_calls if c[0] == "patch")
        self.assertIn("A.swift", patch)
        self.assertIn("return 2", patch)


OLD = """import Foundation
struct Thing {
    var base = 1
    func value() -> Int { base }
    var label: String { "a" }
    private func secret(_ x: Int) -> Int { x }
}
final class Engine {
    private var speed = 2.0
    func tick(dt: Double, _ n: Int) -> String { "tick" }
    init() {}
    init(speed: Double) { self.speed = speed }
}
extension Thing {
    func double() -> Int { value() * 2 }
}
func greeting() -> String { "hello v1" }
"""


class RefusalHintTests(unittest.TestCase):
    def test_an_unnamed_call_blames_other_files_and_points_at_files(self):
        problems = [{"file": "RAVESubtitles.swift", "decl": "X", "reason": "r"}, {"file": "MouseHitTarget.swift", "decl": "Y", "reason": "r"}]
        hint = inject.refusal_hint(problems, named=False)
        self.assertIn("Pass `files`", hint)
        self.assertIn("RAVESubtitles.swift", hint)
        self.assertIn("new type", hint)

    def test_a_named_call_does_not_blame_anyone(self):
        hint = inject.refusal_hint([{"file": "A.swift", "decl": "X", "reason": "r"}], named=True)
        self.assertNotIn("someone else", hint)
        self.assertIn("new type", hint)


@unittest.skipUnless(shutil.which("xcrun"), "needs Xcode's toolchain")
class RewriterTests(unittest.TestCase):
    """The SwiftSyntax tool: what it replaces, what it copies, what it refuses."""

    @classmethod
    def setUpClass(cls):
        cls.tool = inject.rewriter()

    def run_rewriter(self, new, old=None, built=None):
        import subprocess
        directory = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, directory, True)
        paths = {name: os.path.join(directory, name) for name in ("old.swift", "new.swift", "out.swift")}
        for name, text in (("old.swift", OLD if old is None else old), ("new.swift", new)):
            with open(paths[name], "w") as handle:
                handle.write(text)
        extra = []
        if built is not None:
            paths["built.swift"] = os.path.join(directory, "built.swift")
            with open(paths["built.swift"], "w") as handle:
                handle.write(built)
            extra = ["--built", paths["built.swift"]]
        done = subprocess.run([self.tool, "--old", paths["old.swift"], "--new", paths["new.swift"], "--module", "App",
                               "--source-file", "Model.swift", "--out", paths["out.swift"]] + extra,
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        with open(paths["out.swift"]) as handle:
            return json.loads(done.stdout), handle.read()

    def test_only_what_changed_is_replaced(self):
        new = OLD.replace("{ base }", "{ base * 100 }").replace('"hello v1"', '"hello v2"').replace('"a"', '"b"')
        report, patch = self.run_rewriter(new)
        self.assertEqual(sorted(report["patched"]), ["Thing.label", "Thing.value()", "greeting()"])
        self.assertEqual(report["unchanged"], 3)
        self.assertEqual(report["unpatchable"], [])
        self.assertIn("@_dynamicReplacement(for: value())", patch)
        self.assertIn('@_private(sourceFile: "Model.swift") import App', patch)
        self.assertNotIn("secret", patch)
        self.assertNotIn("double", patch)

    def test_comments_and_whitespace_are_not_changes(self):
        report, patch = self.run_rewriter(OLD.replace("func value() -> Int { base }",
                                                      "// note\n    func value() -> Int {\n        base  // x\n    }"))
        self.assertEqual(report["patched"], [])
        self.assertFalse(report["hasPatch"])

    def test_a_new_method_is_copied_and_a_changed_signature_is_new_not_an_edit(self):
        report, patch = self.run_rewriter(OLD.replace("func value() -> Int { base }",
                                                      "func value() -> Int { base }\n    func fresh(_ x: Int) -> Int { x }"))
        self.assertEqual(report["added"], ["Thing.fresh(_:)"])
        self.assertEqual(report["patched"], [])
        self.assertIn("func fresh", patch)
        self.assertNotIn("_dynamicReplacement(for: fresh", patch)

    def test_a_method_an_earlier_patch_added_can_be_changed_again(self):
        fresh = OLD.replace("func value() -> Int { base }",
                            "func value() -> Int { fresh(1) }\n    func fresh(_ x: Int) -> Int { x }")
        later = fresh.replace("func fresh(_ x: Int) -> Int { x }", "func fresh(_ x: Int) -> Int { x + 1 }")
        report, patch = self.run_rewriter(later, old=fresh, built=OLD)
        self.assertTrue(report["cumulative"])
        self.assertEqual(report["unpatchable"], [])
        # The new body is copied, never named as a replacement target the app doesn't have...
        self.assertIn("func fresh(_ x: Int) -> Int { x + 1 }", patch)
        self.assertNotIn("_dynamicReplacement(for: fresh", patch)
        # ...and the earlier-patched caller is restated so it reaches this copy.
        self.assertIn("@_dynamicReplacement(for: value())", patch)
        self.assertEqual(report["patched"], ["Thing.value()"])
        self.assertEqual(report["added"], ["Thing.fresh(_:)"])

    def test_without_an_earlier_added_method_the_patch_is_not_cumulative(self):
        report, _ = self.run_rewriter(OLD.replace('"hello v1"', '"hello v2"'), built=OLD)
        self.assertFalse(report["cumulative"])
        self.assertEqual(report["patched"], ["greeting()"])

    def test_labels_make_the_selector(self):
        report, patch = self.run_rewriter(OLD.replace('"tick"', '"tock"'))
        self.assertEqual(report["patched"], ["Engine.tick(dt:_:)"])
        self.assertIn("@_dynamicReplacement(for: tick(dt:_:))", patch)

    def test_what_a_patch_cannot_do_is_refused_by_name(self):
        for change, expect in ((("var base = 1", "var base = 2"), "Thing.var base"),
                               (("var base = 1", "var base = 1\n    var extra = 3"), "Thing.var extra"),
                               (("init(speed: Double) { self.speed = speed }", "init(speed: Double) { self.speed = speed * 2 }"), "Engine.init"),
                               (("final class Engine", "final class Engine: Sendable"), "Engine header")):
            report, _ = self.run_rewriter(OLD.replace(*change))
            self.assertTrue([p for p in report["unpatchable"] if expect in p["decl"]], (change, report["unpatchable"]))

    def test_a_new_top_level_type_comes_along_whole_and_is_not_a_refusal(self):
        helper = "\nprivate enum Beep {\n    static let hz = 1568.0\n    static func play() { print(hz) }\n    init() {}\n}\n"
        report, patch = self.run_rewriter(OLD.replace('"hello v1"', '"hello v2"') + helper)
        self.assertEqual(report["unpatchable"], [])
        self.assertEqual(report["patched"], ["greeting()"])
        self.assertEqual(report["added"], ["Beep"])
        # Once, as the type itself: not again as methods added to an extension of it.
        self.assertEqual(patch.count("static func play()"), 1)
        self.assertNotIn("extension Beep", patch)

    def test_a_new_type_nested_in_an_existing_one_comes_along_as_a_member(self):
        nested = "func value() -> Int { base }\n    private struct Ring {\n        var width: Int { 4 }\n        var gap = 2\n    }"
        report, patch = self.run_rewriter(OLD.replace("func value() -> Int { base }", nested))
        self.assertEqual(report["unpatchable"], [])
        self.assertEqual(report["added"], ["Thing.Ring"])
        self.assertIn("extension Thing {", patch)
        self.assertEqual(patch.count("struct Ring"), 1)

    def test_a_new_static_or_typed_let_is_carried_and_a_new_var_is_not(self):
        report, patch = self.run_rewriter(OLD.replace(
            "var base = 1", "var base = 1\n    static let edge = 48.0\n    let inset: Double = edge * 2\n    private let tint: Int = 7"))
        self.assertEqual(report["unpatchable"], [])
        self.assertEqual(sorted(report["added"]), ["Thing.edge", "Thing.inset (as a computed property)",
                                                    "Thing.tint (as a computed property)"])
        self.assertIn("static let edge = 48.0", patch)
        self.assertIn("var inset: Double { edge * 2 }", patch)
        self.assertIn("var tint: Int { 7 }", patch)
        # A let without a type can't become a computed property, and a var can't be a constant.
        for line in ("let plain = 3", "var count: Int = 3"):
            report, _ = self.run_rewriter(OLD.replace("var base = 1", "var base = 1\n    " + line))
            self.assertEqual(len(report["unpatchable"]), 1, line)
            self.assertIn("new stored property", report["unpatchable"][0]["reason"])

    def test_a_changed_type_header_says_to_use_a_new_type_instead(self):
        report, _ = self.run_rewriter(OLD.replace("final class Engine", "final class Engine: Sendable"))
        [problem] = [p for p in report["unpatchable"] if "Engine header" in p["decl"]]
        self.assertIn("new type", problem["reason"])

    def test_accepted_edits_that_change_nothing_are_warned_about(self):
        report, _ = self.run_rewriter("enum E { case x\n case y\n func f() -> Int { 1 } }".replace("enum E", "enum E"),
                                      old="enum E { case y\n case x\n func f() -> Int { 1 } }")
        self.assertEqual(report["unpatchable"], [])
        self.assertTrue([w for w in report["warnings"] if "reordered" in w])
        report, _ = self.run_rewriter("struct S { @MainActor func f() -> Int { 1 } }", old="struct S { func f() -> Int { 1 } }")
        self.assertTrue([w for w in report["warnings"] if "does nothing" in w])
        self.assertFalse(report["hasPatch"])
        report, patch = self.run_rewriter("struct S { func f() async -> Int { 1 } }", old="struct S { func f() -> Int { 1 } }")
        self.assertEqual(report["added"], ["S.f()"])
        self.assertTrue([w for w in report["warnings"] if "still calls the old one" in w])

    def test_a_plain_body_edit_has_no_warnings(self):
        report, _ = self.run_rewriter(OLD.replace('"hello v1"', '"hello v2"'))
        self.assertEqual(report["warnings"], [])

    def test_a_new_or_removed_enum_case_is_refused_with_advice(self):
        report, _ = self.run_rewriter("enum E { case x\n case y\n case z }", old="enum E { case x\n case y }")
        self.assertIn("cases are fixed", report["unpatchable"][0]["reason"])

    def test_an_added_member_does_not_renumber_the_initializers(self):
        report, _ = self.run_rewriter(OLD.replace("var base = 1", "var base = 1\n    var extra = 3"))
        self.assertEqual([p["decl"] for p in report["unpatchable"]], ["Thing.var extra"])


if __name__ == "__main__":
    unittest.main()


class Scope(unittest.TestCase):
    def test_only_modules_built_for_dynamic_replacement_are_patchable(self):
        self.assertTrue(inject.replaceable({"args": ["-O", "-Xfrontend", "-enable-implicit-dynamic"]}))
        self.assertFalse(inject.replaceable({"args": ["-O", "-enable-testing"]}))

    def test_app_scope_patches_only_the_app_module(self):
        state = {"scope": "app", "appModule": "Game"}
        dynamic = {"args": ["-Xfrontend", "-enable-implicit-dynamic"]}
        self.assertTrue(inject.replaceable(dynamic, "Game", state))
        # A package whose record is left over from an all-scope build.
        self.assertFalse(inject.replaceable(dynamic, "VoxelRender", state))


IFCONFIG_OLD = """import Foundation
#if canImport(AppKit)
import AppKit
struct Mac { func name() -> String { "mac" } }
#else
struct Other { func name() -> String { "other" } }
#endif
struct Shared {
    #if os(visionOS)
    func label() -> String { "vision" }
    #else
    func label() -> String { "flat" }
    #endif
    func value() -> Int {
        #if DEBUG
        return 1
        #else
        return 2
        #endif
    }
}
"""


class BuildConfigurationFromArguments(unittest.TestCase):
    def test_target_conditions_and_language_mode(self):
        config = inject.build_configuration({"args": [
            "-target", "arm64-apple-xros26.0-simulator", "-D", "DEBUG", "-DSWIFT_PACKAGE", "-swift-version", "5",
            "-enable-upcoming-feature", "ExistentialAny", "-I", "/p", "-F/f"]}, [6, 4])
        self.assertEqual((config["os"], config["arch"], config["environment"]), ("visionOS", "arm64", "simulator"))
        self.assertEqual(config["conditions"], ["DEBUG", "SWIFT_PACKAGE"])
        self.assertEqual(config["features"], ["ExistentialAny"])
        self.assertEqual(config["languageVersion"], [5, 10])   # Swift 5 mode on a 6.x compiler
        self.assertEqual((config["importPaths"], config["frameworkPaths"]), (["/p"], ["/f"]))

    def test_mac_catalyst_and_ios(self):
        config = inject.build_configuration({"args": ["-target", "arm64-apple-ios18.0-macabi"]}, [6])
        self.assertEqual((config["os"], config["environment"]), ("iOS", "macCatalyst"))


@unittest.skipUnless(shutil.which("xcrun"), "needs Xcode's toolchain")
class RewriterIfConfigTests(unittest.TestCase):
    """#if reduced to the branch the app was compiled with."""

    @classmethod
    def setUpClass(cls):
        import subprocess
        cls.tool = inject.rewriter()
        sdk = subprocess.run(["xcrun", "--sdk", "xros", "--show-sdk-path"], capture_output=True, text=True).stdout.strip()
        cls.config = inject.build_configuration(
            {"args": ["-target", "arm64-apple-xros26.0", "-sdk", sdk, "-swift-version", "6", "-D", "DEBUG"]}, [6, 4])

    def run_rewriter(self, new, config=True):
        import subprocess
        directory = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, directory, True)
        paths = {name: os.path.join(directory, name) for name in ("old.swift", "new.swift", "out.swift", "b.json")}
        for name, text in (("old.swift", IFCONFIG_OLD), ("new.swift", new)):
            with open(paths[name], "w") as handle:
                handle.write(text)
        with open(paths["b.json"], "w") as handle:
            json.dump(self.config, handle)
        command = [self.tool, "--old", paths["old.swift"], "--new", paths["new.swift"], "--module", "App",
                   "--source-file", "Q.swift", "--out", paths["out.swift"]] + (["--config", paths["b.json"]] if config else [])
        done = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        with open(paths["out.swift"]) as handle:
            return json.loads(done.stdout), handle.read()

    def test_active_branches_are_patched(self):
        new = IFCONFIG_OLD.replace('"vision"', '"vision 2"').replace('"other"', '"other 2"').replace("return 1", "return 10")
        report, patch = self.run_rewriter(new)
        self.assertEqual(sorted(report["patched"]), ["Other.name()", "Shared.label()", "Shared.value()"])
        self.assertEqual(report["unpatchable"], [])
        self.assertIn('"vision 2"', patch)
        self.assertIn("return 10", patch)
        self.assertNotIn("#if", patch)
        self.assertNotIn("import AppKit", patch)   # canImport(AppKit) is false on visionOS

    def test_a_change_only_in_an_inactive_branch_patches_nothing(self):
        new = IFCONFIG_OLD.replace('"flat"', '"flat 2"').replace('"mac"', '"mac 2"').replace("return 2", "return 20")
        report, _ = self.run_rewriter(new)
        self.assertFalse(report["hasPatch"])
        self.assertEqual(report["unpatchable"], [])

    def test_without_a_configuration_a_changed_if_is_refused(self):
        report, _ = self.run_rewriter(IFCONFIG_OLD.replace('"vision"', '"vision 2"'), config=False)
        self.assertTrue(report["unpatchable"])
