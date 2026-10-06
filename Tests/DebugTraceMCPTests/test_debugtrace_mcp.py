"""Tests for Tools/debugtrace-mcp: python3 -m unittest discover -s Tests/DebugTraceMCPTests"""
import importlib.machinery
import importlib.util
import json
import os
import unittest

PATH = os.path.join(os.path.dirname(__file__), "..", "..", "Tools", "debugtrace-mcp")
spec = importlib.util.spec_from_loader("debugtrace_mcp", importlib.machinery.SourceFileLoader("debugtrace_mcp", PATH))
mcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mcp)


class Recorder:
    """Stands in for the app: records what the call tool would send."""

    def __init__(self):
        self.sent = []
        self._saved = (mcp.resolve, mcp.verified, mcp.request)

    def __enter__(self):
        mcp.resolve = lambda app: {"app": app}
        mcp.verified = lambda session: session
        def request(session, path, body=None):
            self.sent.append((session, path, body))
            return 200, "application/json", json.dumps({"ok": True, "data": {}}).encode()
        mcp.request = request
        return self

    def __exit__(self, *exc):
        mcp.resolve, mcp.verified, mcp.request = self._saved


def call_tool(name, arguments):
    reply = mcp.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                        "params": {"name": name, "arguments": arguments}})
    return reply["result"]


def notes(result):
    return [c["text"] for c in result["content"] if c["text"].startswith("note:")]


class CallArguments(unittest.TestCase):
    def sent_arguments(self, arguments):
        with Recorder() as rec:
            result = call_tool("call", arguments)
        self.assertFalse(result.get("isError"), result)
        (_, path, body), = rec.sent
        self.assertEqual(path, "/_call")
        return body, result

    def test_canonical_form_passes_through_without_a_note(self):
        body, result = self.sent_arguments({"endpoint": "_logs", "arguments": {"level": "error"}})
        self.assertEqual(body, {"name": "_logs", "arguments": {"level": "error"}})
        self.assertEqual(notes(result), [])

    def test_aliases_for_arguments_are_accepted_and_reported(self):
        for alias in ("args", "params", "parameters", "input", "payload", "body"):
            with self.subTest(alias=alias):
                body, result = self.sent_arguments({"endpoint": "_trace", alias: {"upload": True}})
                self.assertEqual(body["arguments"], {"upload": True})
                self.assertIn(f"`{alias}` was accepted as `arguments`", notes(result)[0])

    def test_aliases_for_endpoint_and_app(self):
        body, result = self.sent_arguments({"name": "_info", "bundleId": "pro.example.app"})
        self.assertEqual(body["name"], "_info")
        self.assertEqual(len(notes(result)), 1)
        self.assertIn("`name` was accepted as `endpoint`", notes(result)[0])
        self.assertIn("`bundleId` was accepted as `app`", notes(result)[0])

    def test_flattened_endpoint_arguments_are_treated_as_arguments(self):
        body, result = self.sent_arguments({"endpoint": "_logs", "level": "error", "limit": 5})
        self.assertEqual(body["arguments"], {"level": "error", "limit": 5})
        self.assertIn("top level", notes(result)[0])

    def test_arguments_given_as_a_json_string(self):
        body, result = self.sent_arguments({"endpoint": "_logs", "arguments": '{"level": "error"}'})
        self.assertEqual(body["arguments"], {"level": "error"})
        self.assertIn("JSON string", notes(result)[0])

    def test_no_arguments_sends_an_empty_object(self):
        body, _ = self.sent_arguments({"endpoint": "_info"})
        self.assertEqual(body["arguments"], {})

    def test_both_alias_and_canonical_is_an_error(self):
        with Recorder() as rec:
            result = call_tool("call", {"endpoint": "_logs", "arguments": {"a": 1}, "args": {"b": 2}})
        self.assertTrue(result["isError"])
        self.assertIn("given twice", result["content"][0]["text"])
        self.assertEqual(rec.sent, [])

    def test_flattened_arguments_next_to_arguments_is_an_error(self):
        with Recorder() as rec:
            result = call_tool("call", {"endpoint": "_logs", "arguments": {}, "level": "error"})
        self.assertTrue(result["isError"])
        self.assertIn("inside `arguments`", result["content"][0]["text"])
        self.assertEqual(rec.sent, [])

    def test_bad_argument_types_are_errors_with_hints(self):
        for bad in ("not json", [1, 2], 5):
            with self.subTest(bad=bad), Recorder() as rec:
                result = call_tool("call", {"endpoint": "_logs", "arguments": bad})
                self.assertTrue(result["isError"])
                self.assertIn("hint:", result["content"][0]["text"])
                self.assertEqual(rec.sent, [])

    def test_missing_endpoint_still_says_what_to_do(self):
        with Recorder():
            result = call_tool("call", {})
        self.assertTrue(result["isError"])
        self.assertIn("`endpoint` is required", result["content"][0]["text"])


class OtherTools(unittest.TestCase):
    def test_unknown_parameter_gets_a_did_you_mean_and_the_valid_list(self):
        with Recorder() as rec:
            result = call_tool("trace", {"nte": "x"})
        self.assertTrue(result["isError"])
        text = result["content"][0]["text"]
        self.assertIn("unknown parameter `nte`", text)
        self.assertIn("did you mean `note`", text)
        self.assertIn("valid parameters:", text)
        self.assertEqual(rec.sent, [])

    def test_trace_accepts_app_alias_and_reports_it(self):
        with Recorder() as rec:
            # request() returns a bare ok reply, so the trace tool fails after normalising:
            # what matters here is that the alias reached it as `app`.
            call_tool("trace", {"bundleId": "pro.example.app", "note": "n"})
        self.assertEqual(rec.sent[0][0], {"app": "pro.example.app"})

    def test_apps_takes_no_parameters(self):
        result = call_tool("apps", {"x": 1})
        self.assertTrue(result["isError"])
        self.assertIn("valid parameters: none", result["content"][0]["text"])

    def test_help_rejects_arguments_with_the_valid_names(self):
        result = call_tool("help", {"arguments": {}})
        self.assertTrue(result["isError"])
        self.assertIn("app, endpoint", result["content"][0]["text"])

    def test_non_object_tool_arguments(self):
        reply = mcp.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                            "params": {"name": "apps", "arguments": [1]}})
        self.assertTrue(reply["result"]["isError"])


ZONE = r"""Browsing for _debugtrace._tcp.local
_debugtrace._tcp                                PTR     Spatial\032Home\032\195\169._debugtrace._tcp
Spatial\032Home\032\195\169._debugtrace._tcp   SRV     0 0 8643 ixPhone.local. ; Replace with unicast FQDN of target host
Spatial\032Home\032\195\169._debugtrace._tcp   TXT     "txtvers=1" "bundleId=pro.example.home" "name=Spatial Home" "keyId=k1" "build=abc1234"
Half._debugtrace._tcp                           SRV     0 0 8644 avp.local. ; no TXT yet
_other._tcp                                     PTR     Nope._other._tcp
Nope._other._tcp                                SRV     0 0 1 x.local.
Nope._other._tcp                                TXT     "a=b"
"""


class Discovery(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.keys = tempfile.mkdtemp()
        self._saved_dir = mcp.KEY_DIR
        mcp.KEY_DIR = self.keys

    def tearDown(self):
        mcp.KEY_DIR = self._saved_dir

    def ledger(self, key_id, **record):
        with open(os.path.join(self.keys, f"{key_id}.json"), "w") as handle:
            json.dump(record, handle)

    def test_parses_complete_services_only(self):
        services = mcp.parse_zone(ZONE)
        self.assertEqual(len(services), 1)
        service, = services
        self.assertEqual(service["instance"], "Spatial Home é")
        self.assertEqual((service["host"], service["port"]), ("ixPhone.local", 8643))
        self.assertEqual(service["txt"]["bundleId"], "pro.example.home")
        self.assertEqual(service["txt"]["name"], "Spatial Home")

    def test_txt_values_with_quotes_and_equals(self):
        zone = 'A._debugtrace._tcp SRV 0 0 1 h.local.\nA._debugtrace._tcp TXT "name=say \\"hi\\"" "x=a=b"'
        service, = mcp.parse_zone(zone)
        self.assertEqual(service["txt"]["name"], 'say "hi"')
        self.assertEqual(service["txt"]["x"], "a=b")

    def test_ledger_token_makes_a_service_attachable(self):
        self.ledger("k1", device="ixPhone", commandToken="tok")
        session, = mcp.discovered_sessions(mcp.parse_zone(ZONE))
        self.assertTrue(session["attachable"])
        self.assertEqual(session["token"], "tok")
        self.assertEqual(session["url"], "http://ixPhone.local:8643")
        self.assertEqual(session["device"], "ixPhone")
        self.assertNotIn("token", mcp.describe(session))

    def test_unknown_or_tokenless_builds_are_listed_but_not_attachable(self):
        session, = mcp.discovered_sessions(mcp.parse_zone(ZONE))
        self.assertFalse(session["attachable"])
        self.assertIn("ledger", session["reason"])
        self.ledger("k1", device="ixPhone")
        session, = mcp.discovered_sessions(mcp.parse_zone(ZONE))
        self.assertFalse(session["attachable"])
        self.assertIn("no command token", session["reason"])

    def test_key_ids_cannot_escape_the_ledger(self):
        self.assertIsNone(mcp.ledger_record("../../etc/passwd"))
        self.assertIsNone(mcp.ledger_record(None))

    def test_a_session_record_wins_over_its_own_advertisement(self):
        saved = (mcp.session_records, mcp.recent_discoveries)
        try:
            mcp.session_records = lambda: [{"bundleId": "pro.example.home", "url": "http://ixphone:8643", "consoleLog": "/x"}]
            mcp.recent_discoveries = lambda: [
                {"bundleId": "pro.example.home", "url": "http://ixPhone.local:8643", "attachable": True},
                {"bundleId": "pro.example.other", "url": "http://ixPhone.local:8644", "attachable": False},
            ]
            sessions = mcp.all_sessions()
            self.assertEqual([s.get("consoleLog") for s in sessions], ["/x", None])
            self.assertEqual(len(mcp.live_sessions()), 1)
        finally:
            mcp.session_records, mcp.recent_discoveries = saved


if __name__ == "__main__":
    unittest.main()
