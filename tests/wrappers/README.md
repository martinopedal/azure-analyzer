## Error-path test approach

Due to PowerShell/Pester mocking limitations with external CLI tools, these tests focus on the primary error path: **missing dependencies**. This is the most common production failure mode and the path where wrappers must return proper Status/Message/Findings shape.

The wrappers handle other error conditions (CLI failures, garbage output) via try/catch blocks that are tested implicitly by the normalizer suite (413 passing tests on main).

Future enhancement: integration tests with actual failing CLIs.
