### 2026-05-13T16:22:58Z: User directive
**By:** martinopedal (via Copilot Coordinator)
**What:** "We need better tests to ensure this won't happen again." Strong reinforcement of the test-rigor + full-consistency directives. The team must guarantee the BUG-1 class (silent hashtable-key drift through a render pipeline that produces empty-but-truthy output) cannot ship again.

**Going-forward rules:**
1. **Fail-first verification is mandatory.** Every regression test added in response to a shipped bug MUST be proven to FAIL against pre-fix code (e.g., git stash the fix, run the test, confirm RED). A test that passes both before AND after the fix proves nothing.
2. **Every shipped bug becomes two tests:**
   - **Instance test** — exact regression (BUG-1's hashtable key)
   - **Class test** — the contract the bug violated (e.g., "any helper returning a hashtable that another module reads MUST have its key surface contract-tested")
3. **Render-output assertions MUST be paired** with non-null/non-empty assertions on the upstream collection the renderer iterates. `@($null) | ForEach-Object` produces visible HTML — a Should -Match against rendered output is not sufficient.
4. **Pester as a required status check** is no longer "nice to have." It must be required on main so tests actually block merge. (Currently only `Analyze (actions)` is required.)
5. **Test sufficiency is reviewed on every shipped bug.** Post-mortem the test suite, not just the code: why didn't the existing suite catch this?