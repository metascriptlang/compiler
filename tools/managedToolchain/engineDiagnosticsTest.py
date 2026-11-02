import os
import unittest
from unittest import mock

import prepareEngine as pe
import prepareLinuxEngine as pl
import prepareWindowsEngine as pw


HOSTS = ((pe, ""), (pl, ""), (pw, ".exe"))
TOOLS = ("llvm-symbolizer", "llvm-rc")


class DiagnosticsToolsTest(unittest.TestCase):
    def test_each_host_requires_the_symbolizer_and_resource_compiler(self):
        for module, suffix in HOSTS:
            required = module.LLVM_TOOLS if module is pe else module.TOOLS
            for tool in TOOLS:
                with self.subTest(host=module.__name__, tool=tool):
                    self.assertIn(tool + suffix, required)

    def test_layout_verification_refuses_each_missing_support_tool(self):
        for module, suffix in HOSTS:
            for tool in TOOLS:
                missing = tool + suffix
                with self.subTest(host=module.__name__, tool=tool), \
                        mock.patch.object(module.os.path, "isfile",
                                          side_effect=lambda path: os.path.basename(path) != missing), \
                        mock.patch.object(module.os.path, "getsize", return_value=1):
                    with self.assertRaisesRegex(pe.EngineError, "layout: missing bin/" + missing):
                        module.verifyLayout("bundle", "23.1.0")


if __name__ == "__main__":
    unittest.main()
