# Native UIKit run interruption — 43809909587 / ee40679a

GitHub reported the job as failed, but its native-test step retained an unfinished
`in_progress` record with no completion/conclusion. No step was marked failed,
check-run annotations/summary were empty, and no artifacts were uploaded.
The full app/Harness build and packaging step had completed successfully.

The last job record covers05:35:23–05:42:58 UTC within the native-test stage;
the configured36-minute step limit had not elapsed. The retained logs do not
establish a compiler error, memory failure or test outcome.

`run_logged` now mirrors its already-bounded, line-flushed compiler/XCTest output
to Actions stdout as well as the artifact log. This preserves the last events if
the worker disappears before upload. Existing deadlines, cancellation behavior,
strict result checks and source inputs are retained for the next cached run.
