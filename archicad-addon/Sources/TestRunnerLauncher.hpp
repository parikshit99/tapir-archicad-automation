#pragma once

// Tapir > Test Runner...: opens the community test runner's window (tools/community-test-runner).
// The runner writes its own folder to %LOCALAPPDATA%\TapirRunner\runner_folder.txt whenever its
// setup or window runs, so this finds it wherever the tester extracted it.
namespace TestRunnerLauncher {

void Open ();

}
