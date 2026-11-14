import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
from validate_runtime import main, run_probe_command


class RuntimePhaseTests(unittest.TestCase):
    def test_build_phase_does_not_depend_on_simulator_startup(self):
        with tempfile.TemporaryDirectory(prefix='runtime-phase-') as folder:
            root = Path(folder)
            argv = ['validate_runtime.py', '--phase', 'build', '--support', str(root / 'support'),
                    '--output', str(root / 'output')]
            with (patch.object(sys, 'argv', argv), patch.object(sys, 'platform', 'darwin'),
                  patch('validate_runtime.compile_runtime', return_value={}) as compile_runtime,
                  patch('validate_runtime.simulator_probe') as simulator):
                main()
            compile_runtime.assert_called_once()
            simulator.assert_not_called()

    def test_probe_refuses_a_stale_build(self):
        with tempfile.TemporaryDirectory(prefix='runtime-phase-') as folder:
            root = Path(folder)
            (root / 'runtime-compile-manifest.json').write_text(json.dumps({'source_fingerprint': {}}))
            argv = ['validate_runtime.py', '--phase', 'probe', '--support', str(root / 'support'), '--output', str(root)]
            with (patch.object(sys, 'argv', argv), patch.object(sys, 'platform', 'darwin'),
                  patch('validate_runtime.simulator_probe') as simulator):
                with self.assertRaisesRegex(ValueError, 'sources changed'):
                    main()
            simulator.assert_not_called()

    def test_timeout_samples_then_kills_only_the_owned_process_group(self):
        command = ['xcrun', 'simctl', 'spawn', '--standalone', 'owned-device', 'probe']
        process = Mock(pid=31415)
        process.wait.side_effect = [subprocess.TimeoutExpired(command, 90), 0]
        process.poll.return_value = None
        order = []
        with tempfile.TemporaryDirectory(prefix='runtime-timeout-') as folder:
            root = Path(folder)
            with (patch('validate_runtime.subprocess.Popen', return_value=process) as popen,
                  patch('validate_runtime.subprocess.run', side_effect=lambda *a, **kw: order.append('sample')),
                  patch('validate_runtime.signal.SIGKILL', 9, create=True),
                  patch('validate_runtime.os.killpg', side_effect=lambda *a: order.append('kill'), create=True) as killpg):
                with self.assertRaises(subprocess.TimeoutExpired):
                    run_probe_command(command, root, 'engine')
            self.assertTrue(popen.call_args.kwargs['start_new_session'])
            self.assertEqual(order, ['sample', 'kill'])
            killpg.assert_called_once_with(31415, 9)
            self.assertEqual(process.wait.call_args.kwargs, {'timeout': 5})
            recorded = json.loads((root / 'engine-launcher.json').read_text())
            self.assertEqual(recorded['pid'], 31415)
            self.assertEqual(recorded['command'], command)


if __name__ == '__main__':
    unittest.main()
