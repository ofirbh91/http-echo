"""Runtime regression checks; requires Docker. Run separately from offline tests."""
import json
import subprocess
import time
import unittest
import urllib.error
import urllib.request


class ImageSecurityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.container = subprocess.check_output([
            "docker", "run", "--detach", "--read-only", "--cap-drop=ALL",
            "--security-opt=no-new-privileges", "--memory=256m", "--cpus=0.5",
            "--pids-limit=128", "--publish=127.0.0.1::8080",
            "--env=SYNTHETIC_SECRET=validation-secret-only", "http-echo-local:hardened",
        ], text=True).strip()
        cls.addClassCleanup(lambda: subprocess.run(["docker", "rm", "--force", cls.container], capture_output=True))
        port = subprocess.check_output(["docker", "port", cls.container, "8080/tcp"], text=True).strip().rsplit(":", 1)[1]
        cls.url = "http://127.0.0.1:" + port
        cls.client = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        for _ in range(50):
            try:
                cls.client.open(cls.url, timeout=1).close()
                return
            except (urllib.error.URLError, ConnectionError):
                time.sleep(0.2)
        raise AssertionError(subprocess.check_output(["docker", "logs", cls.container], text=True))

    def get(self, path="/", **headers):
        with self.client.open(urllib.request.Request(self.url + path, headers=headers), timeout=5) as response:
            self.assertEqual(response.status, 200)
            return json.load(response)

    def test_echo_contract_and_credentials(self):
        payload = self.get(Authorization="Bearer validation-only", Cookie="session=validation-only", apikey="validation-only")
        self.assertEqual(payload["http"]["method"], "GET")
        self.assertEqual(payload["http"]["originalUrl"], "/")
        self.assertFalse(payload.get("environment"))
        self.assertFalse(payload["request"]["cookies"])
        self.assertTrue({"authorization", "cookie", "apikey"}.isdisjoint(payload["request"]["headers"]))

    def test_file_and_environment_control_headers_are_disabled(self):
        for headers in ({"X-Echo-File": "/etc/passwd"}, {"X-Echo-Env-Body": "SYNTHETIC_SECRET"}):
            payload = self.get(**headers)
            self.assertEqual(payload["http"]["method"], "GET")
            self.assertNotIn("validation-secret-only", json.dumps(payload))

    def test_post_json_still_echoes(self):
        request = urllib.request.Request(self.url + "/", data=b'{"hello":"interview"}', headers={"Content-Type":"application/json"})
        with self.client.open(request, timeout=5) as response:
            payload = json.load(response)
        self.assertEqual(payload["http"]["method"], "POST")
        self.assertEqual(payload["request"]["body"], {"hello": "interview"})

    def test_nonroot_and_readonly(self):
        uid = subprocess.check_output(["docker", "exec", self.container, "node", "-e", "console.log(process.getuid())"], text=True).strip()
        self.assertEqual(uid, "1000")
        result = subprocess.run(["docker", "exec", self.container, "node", "-e", "require('fs').writeFileSync('/app/unexpected-write','x')"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("EROFS", result.stderr)


if __name__ == "__main__":
    unittest.main()
