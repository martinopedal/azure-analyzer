# Skill: False-Pass Test Pattern Detection & Remediation

PowerShell silent-null behavior lets bugs hide behind weak assertions. Always pair regex/count checks with upstream non-null assertions. Test data flow at EVERY hand-off. Reject ghost rows explicitly.

**Documented in:** `.squad/skills/false-pass-test-patterns/SKILL.md` (full pattern catalog)  
**Real example:** BUG-1 (hashtable key mismatch → Test 32 false-passed)  
**Remediation:** `AuditorDataFlow.Tests.ps1` + hardened Test 32/35 with SENTINEL-001/002/003 markers
