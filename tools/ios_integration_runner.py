"""Run Flutter iOS integration results through XCTest, not VM-service discovery."""
from pathlib import Path
import subprocess
import time


def run_integration(flutter, root, device, entrypoint, defines, log, timeout):
    deadline = time.monotonic() + timeout
    commands = [
        [flutter, 'build', 'ios', '--simulator', '--debug', '--no-pub',
         '--target', entrypoint,
         '--dart-define=INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=true',
         *[f'--dart-define={value}' for value in defines]],
        ['xcodebuild', 'test', '-workspace', 'ios/Runner.xcworkspace',
         '-scheme', 'Runner', '-configuration', 'Debug',
         '-destination', f'platform=iOS Simulator,id={device}',
         '-parallel-testing-enabled', 'NO',
         '-only-testing:RunnerTests/IosIntegrationTests',
         'CODE_SIGNING_ALLOWED=NO'],
    ]
    for command in commands:
        result = subprocess.run(command, cwd=Path(root), stdout=log,
                                stderr=subprocess.STDOUT, check=False,
                                timeout=max(1, deadline - time.monotonic()))
        if result.returncode:
            return result.returncode
    return 0
