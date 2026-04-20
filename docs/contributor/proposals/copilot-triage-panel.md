# Copilot Triage Panel - Design Proposal

**Issue:** #122  
**Author:** Sage  
**Date:** 2026-04-17  
**Status:** Draft

## Executive Summary

Preview what Copilot triage-enriched findings look like before full triage loop (#105) ships. This proposal defines:

1. Per-finding **Copilot Triage** expandable section with AI summary, suggested remediation, confidence, and related findings
2. Top-of-report **Triage Summary** card showing triaged/auto-remediable/manual review counts
3. Schema extension for `CopilotTriage` field
4. HTML mockup fitting existing report-template.html style
5. Implementation phases for Sentinel/Forge

**Constraint:** Mock content only - no real LLM calls during sample generation. When #105 lands, same renderer works opt-in.

---

## User Story

**As a** security engineer reviewing an azure-analyzer report  
**I want to** see AI-powered triage recommendations inline with each finding  
**So that** I can prioritize remediation, understand context, and copy suggested commands without manual investigation

**Acceptance Criteria:**

- [ ] Per-finding expandable "Copilot Triage" panel: 2-sentence summary, suggested remediation command (az/kubectl/pwsh), related-findings links, confidence (High/Medium/Low)
- [ ] Top-of-report "Triage Summary" card: N triaged, M auto-remediable, K needs human review
- [ ] Side-by-side diff with base sample-report.html (linked from README)
- [ ] samples/sample-results-with-triage.json - base dataset + CopilotTriage field
- [ ] Schema doc for CopilotTriage field
- [ ] CHANGELOG entry

---

## Schema Extension

### CopilotTriage Field Specification

```jsonc
{
  "Id": "azqr-nsg-001",
  "Source": "azqr",
  "Category": "Networking",
  "Title": "NSG allows SSH from any source",
  "Severity": "High",
  "Compliant": false,
  "Detail": "Network Security Group allows SSH (port 22) from any source address.",
  "Remediation": "Restrict SSH access to specific IP ranges or use Azure Bastion.",
  "ResourceId": "/subscriptions/.../nsg-frontend",
  "LearnMoreUrl": "https://...",
  
  // NEW: CopilotTriage field (optional, null if triage not run)
  "CopilotTriage": {
    "summary": "This NSG rule exposes port 22 to the internet, creating lateral movement risk if host is compromised.",
    "confidence": "High",  // High | Medium | Low
    "priority": 92,        // 0-100 score (severity × confidence × blast radius)
    "autoRemediable": true,
    "suggestedCommand": "az network nsg rule update --resource-group rg-prod-net --nsg-name nsg-frontend --name allow-ssh --source-address-prefixes 10.0.0.0/8",
    "commandType": "az",   // az | kubectl | pwsh | manual
    "relatedFindings": ["azqr-nsg-003", "defender-001"], // array of Finding.Id
    "tags": ["internet-exposed", "lateral-movement-risk", "auto-fix"],
    "estimatedImpact": "Low",  // deployment impact: None | Low | Medium | High
    "triageTimestamp": "2026-04-17T12:34:56Z",
    "triageModel": "gpt-4o"
  }
}
```

**Field Descriptions:**

- **summary** (string, required): 1-2 sentence AI-generated summary explaining the risk
- **confidence** (enum, required): High | Medium | Low - how confident the triage is
- **priority** (number, required): 0-100 composite score = `(severity_score × 0.5) + (confidence_score × 0.3) + (blast_radius × 0.2)`
- **autoRemediable** (boolean, required): true if suggested command can run unattended
- **suggestedCommand** (string, optional): Shell/CLI command to remediate (escaped for HTML)
- **commandType** (enum, optional): az | kubectl | pwsh | manual
- **relatedFindings** (array, optional): Finding IDs that share common root cause
- **tags** (array, optional): Contextual tags like "internet-exposed", "credential-leak", "compliance-blocker"
- **estimatedImpact** (enum, optional): None | Low | Medium | High - blast radius of remediation
- **triageTimestamp** (ISO8601, optional): When triage was performed
- **triageModel** (string, optional): LLM model used (e.g., "gpt-4o", "claude-opus")

---

## Severity × Confidence Scoring Formula

```
priority_score = (severity_weight × 0.5) + (confidence_weight × 0.3) + (blast_radius × 0.2)

severity_weight:
  Critical = 100
  High     = 75
  Medium   = 50
  Low      = 25
  Info     = 10

confidence_weight:
  High   = 100
  Medium = 60
  Low    = 30

blast_radius (entity count or resource scope):
  Tenant-wide       = 100
  Subscription-wide = 75
  Resource Group    = 50
  Single Resource   = 25
```

**Example:**
- Finding: `Severity=High, Confidence=High, Scope=Single Resource`
- Calculation: `(75 × 0.5) + (100 × 0.3) + (25 × 0.2) = 37.5 + 30 + 5 = 72.5`
- **Priority = 73** (rounded)

---

## HTML Mockup

### 1. Triage Summary Card (Dashboard Tab)

Inject into `tab-dashboard` after `#summary-cards`:

```html
<!-- Copilot Triage Summary Card (only render if triage data exists) -->
<div class="card triage-summary-card" id="triage-summary" style="display:none;">
  <h3>🤖 Copilot Triage Summary</h3>
  <div class="triage-stats">
    <div class="triage-stat">
      <span class="triage-value" id="triage-total">0</span>
      <span class="triage-label">Triaged</span>
    </div>
    <div class="triage-stat">
      <span class="triage-value triage-auto" id="triage-auto">0</span>
      <span class="triage-label">Auto-Remediable</span>
    </div>
    <div class="triage-stat">
      <span class="triage-value triage-manual" id="triage-manual">0</span>
      <span class="triage-label">Needs Review</span>
    </div>
  </div>
  <button class="btn-show-triage" onclick="showTopTriaged()">View Top 10 →</button>
</div>

<style>
.triage-summary-card {
  background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
  color: #fff;
  border: none;
}

.triage-summary-card h3 {
  color: #fff;
  margin-bottom: 1rem;
}

.triage-stats {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 1rem;
  margin-bottom: 1rem;
}

.triage-stat {
  display: flex;
  flex-direction: column;
  align-items: center;
}

.triage-value {
  font-size: 2rem;
  font-weight: 700;
  line-height: 1;
}

.triage-auto {
  color: #4ade80;
}

.triage-manual {
  color: #fbbf24;
}

.triage-label {
  font-size: 0.75rem;
  opacity: 0.9;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  margin-top: 0.25rem;
}

.btn-show-triage {
  background: rgba(255,255,255,0.2);
  border: 1px solid rgba(255,255,255,0.3);
  color: #fff;
  padding: 0.5rem 1rem;
  border-radius: 8px;
  cursor: pointer;
  font-weight: 600;
  width: 100%;
  transition: background 0.2s;
}

.btn-show-triage:hover {
  background: rgba(255,255,255,0.3);
}
</style>
```

### 2. Per-Finding Triage Panel

Add expandable section below each finding row in tables. Insert after Detail/Remediation cells:

```html
<tr class="finding-row" data-finding-id="azqr-nsg-001">
  <td>NSG allows SSH from any source</td>
  <td><span class="badge high">High</span></td>
  <td>azqr</td>
  <td><span class="badge noncompliant">Non-Compliant</span></td>
  <td>Network Security Group allows SSH (port 22) from any source address.</td>
  <td>Restrict SSH access to specific IP ranges or use Azure Bastion.</td>
  <td class="resource-id">/subscriptions/.../nsg-frontend</td>
  <td><a href="https://..." target="_blank">Learn more</a></td>
</tr>

<!-- Copilot Triage Expandable Row (only if CopilotTriage field exists) -->
<tr class="copilot-triage-row" id="triage-azqr-nsg-001" style="display:none;">
  <td colspan="8" class="triage-container">
    <div class="triage-panel">
      <div class="triage-header">
        <span class="triage-icon">🤖</span>
        <h4>Copilot Triage</h4>
        <span class="badge triage-confidence-high">High Confidence</span>
        <span class="badge triage-priority">Priority: 92</span>
      </div>
      
      <div class="triage-body">
        <div class="triage-section">
          <h5>AI Summary</h5>
          <p>This NSG rule exposes port 22 to the internet, creating lateral movement risk if host is compromised.</p>
        </div>
        
        <div class="triage-section triage-command">
          <h5>Suggested Fix <span class="badge badge-auto">Auto-Remediable</span></h5>
          <div class="command-box">
            <code>az network nsg rule update --resource-group rg-prod-net --nsg-name nsg-frontend --name allow-ssh --source-address-prefixes 10.0.0.0/8</code>
            <button class="btn-copy" onclick="copyTriageCommand('azqr-nsg-001')" title="Copy command">📋</button>
          </div>
          <p class="command-note">Impact: <span class="impact-low">Low</span> - Rule update is non-breaking</p>
        </div>
        
        <div class="triage-section triage-related">
          <h5>Related Findings</h5>
          <ul>
            <li><a href="#finding-azqr-nsg-003" onclick="scrollToFinding('azqr-nsg-003')">azqr-nsg-003 - NSG allows RDP from any source</a></li>
            <li><a href="#finding-defender-001" onclick="scrollToFinding('defender-001')">defender-001 - Internet-exposed VM detected</a></li>
          </ul>
        </div>
        
        <div class="triage-tags">
          <span class="tag">internet-exposed</span>
          <span class="tag">lateral-movement-risk</span>
          <span class="tag">auto-fix</span>
        </div>
      </div>
      
      <div class="triage-footer">
        <small>Triaged by gpt-4o on 2026-04-17 12:34 UTC</small>
      </div>
    </div>
  </td>
</tr>

<style>
.copilot-triage-row {
  background: #faf5ff;
  border-left: 4px solid #8b5cf6;
}

.triage-container {
  padding: 1.5rem !important;
}

.triage-panel {
  background: #fff;
  border: 1px solid #e9d5ff;
  border-radius: 12px;
  padding: 1.5rem;
}

.triage-header {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  margin-bottom: 1rem;
  padding-bottom: 1rem;
  border-bottom: 1px solid #e9d5ff;
}

.triage-icon {
  font-size: 1.5rem;
}

.triage-header h4 {
  margin: 0;
  flex: 1;
  font-size: 1.1rem;
}

.triage-confidence-high {
  background: #10b981;
}

.triage-confidence-medium {
  background: #f59e0b;
  color: #1f2937;
}

.triage-confidence-low {
  background: #64748b;
}

.triage-priority {
  background: #8b5cf6;
}

.triage-body {
  display: grid;
  gap: 1.25rem;
}

.triage-section h5 {
  margin: 0 0 0.5rem;
  font-size: 0.9rem;
  color: #6b7280;
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

.triage-section p {
  margin: 0;
  line-height: 1.6;
}

.triage-command {
  background: #f8fafc;
  padding: 1rem;
  border-radius: 8px;
  border: 1px solid #e2e8f0;
}

.command-box {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  background: #1e293b;
  color: #e2e8f0;
  padding: 0.75rem 1rem;
  border-radius: 6px;
  font-family: 'Consolas', 'Monaco', monospace;
  font-size: 0.85rem;
  margin-bottom: 0.5rem;
  overflow-x: auto;
}

.command-box code {
  flex: 1;
  white-space: pre-wrap;
}

.btn-copy {
  background: transparent;
  border: 1px solid rgba(255,255,255,0.2);
  color: #e2e8f0;
  padding: 0.25rem 0.5rem;
  border-radius: 4px;
  cursor: pointer;
  font-size: 1rem;
  transition: all 0.2s;
}

.btn-copy:hover {
  background: rgba(255,255,255,0.1);
  transform: scale(1.1);
}

.command-note {
  font-size: 0.85rem;
  color: #6b7280;
  margin-top: 0.5rem;
}

.impact-low {
  color: #10b981;
  font-weight: 600;
}

.impact-medium {
  color: #f59e0b;
  font-weight: 600;
}

.impact-high {
  color: #dc2626;
  font-weight: 600;
}

.triage-related ul {
  margin: 0;
  padding-left: 1.25rem;
}

.triage-related li {
  margin-bottom: 0.25rem;
}

.triage-related a {
  color: #8b5cf6;
  text-decoration: none;
  font-weight: 500;
}

.triage-related a:hover {
  text-decoration: underline;
}

.triage-tags {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
}

.tag {
  background: #e9d5ff;
  color: #6b21a8;
  padding: 0.25rem 0.75rem;
  border-radius: 999px;
  font-size: 0.75rem;
  font-weight: 600;
}

.triage-footer {
  margin-top: 1rem;
  padding-top: 1rem;
  border-top: 1px solid #e9d5ff;
  color: #9ca3af;
  font-size: 0.8rem;
}

.badge-auto {
  background: #10b981;
  color: #fff;
  margin-left: 0.5rem;
}
</style>
```

### 3. "Ask Copilot" Button per Finding Row

Add interactive trigger button to toggle triage panel:

```html
<td class="triage-actions">
  <button class="btn-triage" onclick="toggleTriage('azqr-nsg-001')" title="Show Copilot triage">
    🤖 Triage
  </button>
</td>

<style>
.btn-triage {
  background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
  color: #fff;
  border: none;
  padding: 0.35rem 0.75rem;
  border-radius: 6px;
  cursor: pointer;
  font-size: 0.8rem;
  font-weight: 600;
  transition: transform 0.2s, box-shadow 0.2s;
}

.btn-triage:hover {
  transform: translateY(-2px);
  box-shadow: 0 4px 12px rgba(102, 126, 234, 0.3);
}

.btn-triage.is-open {
  background: #6b21a8;
}
</style>
```

---

## JavaScript Interaction Notes

### Core Functions

```javascript
// Toggle triage panel visibility
function toggleTriage(findingId) {
  const triageRow = document.getElementById(`triage-${findingId}`);
  const btn = event.currentTarget;
  
  if (triageRow.style.display === 'none') {
    triageRow.style.display = 'table-row';
    btn.classList.add('is-open');
    btn.textContent = '🤖 Hide Triage';
  } else {
    triageRow.style.display = 'none';
    btn.classList.remove('is-open');
    btn.textContent = '🤖 Triage';
  }
}

// Copy triage command to clipboard
function copyTriageCommand(findingId) {
  const finding = model.findings.find(f => f.Id === findingId);
  if (!finding?.CopilotTriage?.suggestedCommand) return;
  
  navigator.clipboard.writeText(finding.CopilotTriage.suggestedCommand)
    .then(() => {
      const btn = event.currentTarget;
      btn.textContent = '✓';
      setTimeout(() => { btn.textContent = '📋'; }, 1500);
    })
    .catch(err => console.error('Copy failed:', err));
}

// Scroll to related finding
function scrollToFinding(findingId) {
  const row = document.querySelector(`[data-finding-id="${findingId}"]`);
  if (row) {
    row.scrollIntoView({ behavior: 'smooth', block: 'center' });
    row.style.background = '#fef3c7';
    setTimeout(() => { row.style.background = ''; }, 2000);
  }
}

// Show top 10 triaged findings modal
function showTopTriaged() {
  const triaged = model.findings
    .filter(f => f.CopilotTriage?.priority)
    .sort((a, b) => b.CopilotTriage.priority - a.CopilotTriage.priority)
    .slice(0, 10);
  
  // Render modal with top 10 (implementation TBD in Phase 2)
  console.log('Top 10 triaged:', triaged);
}

// Render triage summary card on load
function renderTriageSummary() {
  const triaged = model.findings.filter(f => f.CopilotTriage);
  if (triaged.length === 0) return;
  
  const autoFix = triaged.filter(f => f.CopilotTriage.autoRemediable).length;
  const manual = triaged.length - autoFix;
  
  document.getElementById('triage-total').textContent = triaged.length;
  document.getElementById('triage-auto').textContent = autoFix;
  document.getElementById('triage-manual').textContent = manual;
  document.getElementById('triage-summary').style.display = 'block';
}

// Initialize on page load
document.addEventListener('DOMContentLoaded', () => {
  renderTriageSummary();
});
```

---

## Sample Data Generation

**samples/sample-results-with-triage.json** - extends `sample-results.json` with mock triage data:

```jsonc
[
  {
    "Id": "azqr-nsg-001",
    "Source": "azqr",
    "Category": "Networking",
    "Title": "NSG allows SSH from any source",
    "Severity": "High",
    "Compliant": false,
    "Detail": "Network Security Group allows SSH (port 22) from any source address.",
    "Remediation": "Restrict SSH access to specific IP ranges or use Azure Bastion.",
    "ResourceId": "/subscriptions/.../nsg-frontend",
    "LearnMoreUrl": "https://...",
    "CopilotTriage": {
      "summary": "This NSG rule exposes port 22 to the internet, creating lateral movement risk if host is compromised.",
      "confidence": "High",
      "priority": 92,
      "autoRemediable": true,
      "suggestedCommand": "az network nsg rule update --resource-group rg-prod-net --nsg-name nsg-frontend --name allow-ssh --source-address-prefixes 10.0.0.0/8",
      "commandType": "az",
      "relatedFindings": ["azqr-nsg-003", "defender-001"],
      "tags": ["internet-exposed", "lateral-movement-risk", "auto-fix"],
      "estimatedImpact": "Low",
      "triageTimestamp": "2026-04-17T12:34:56Z",
      "triageModel": "gpt-4o"
    }
  },
  {
    "Id": "gitleaks-002",
    "Source": "gitleaks",
    "Category": "Security",
    "Title": "AWS Access Key detected in commit",
    "Severity": "Critical",
    "Compliant": false,
    "Detail": "Hardcoded AWS access key in .github/workflows/deploy.yml:23",
    "Remediation": "Rotate key immediately, use GitHub Secrets.",
    "ResourceId": "martinopedal/azure-analyzer@main",
    "LearnMoreUrl": "https://...",
    "CopilotTriage": {
      "summary": "Leaked AWS key grants full account access. Rotate immediately and audit CloudTrail for unauthorized usage.",
      "confidence": "High",
      "priority": 98,
      "autoRemediable": false,
      "suggestedCommand": null,
      "commandType": "manual",
      "relatedFindings": [],
      "tags": ["credential-leak", "critical-severity", "manual-rotation"],
      "estimatedImpact": "High",
      "triageTimestamp": "2026-04-17T12:35:12Z",
      "triageModel": "gpt-4o"
    }
  }
]
```

---

## Open Questions

1. **Triage Throttling**: Should we limit to top N findings (e.g., top 50 by priority) to avoid LLM cost explosion? Or triage all findings incrementally?
2. **Cache Strategy**: When should triage be recomputed? On every scan, or only when findings change?
3. **UI Overload**: With 1000+ findings, should triage be a separate tab/page instead of inline panels?
4. **Command Validation**: Should we syntax-check `suggestedCommand` before display (e.g., validate `az` commands with AST)?
5. **Telemetry**: Track which triage suggestions users act on? (requires opt-in consent)
6. **Multi-language Commands**: Support kubectl/pwsh/terraform/bicep, or start with `az` only?

---

## Implementation Phases

### Phase 1: Static Mockup (Sentinel/Forge)
**Owner:** Sentinel  
**Timeline:** Sprint 1 (1 week)

- [ ] Create `samples/sample-results-with-triage.json` with 10 mock findings
- [ ] Extend `New-HtmlReport.ps1` to detect `CopilotTriage` field and render panels
- [ ] Add triage CSS to `report-template.html`
- [ ] Add triage JS functions (toggle, copy, scroll)
- [ ] Generate `samples/sample-report-with-copilot-triage.html`
- [ ] Update README with side-by-side screenshot comparison
- [ ] CHANGELOG entry

**Deliverables:**
- Static mockup HTML file
- Schema documentation in this proposal (done ✓)
- Visual diff screenshot in PR

### Phase 2: Live Triage Integration (Forge + #105 dependency)
**Owner:** Forge  
**Timeline:** Sprint 3 (after #105 merges)

- [ ] Orchestrator reads triage loop output (`output/triage-results.json`)
- [ ] Merge triage data with findings in `results.json` (join on `Id`)
- [ ] Pass merged data to `New-HtmlReport.ps1` via `-TriagePath`
- [ ] Add opt-in flag `-EnableTriagePanel` to orchestrator
- [ ] Default: gracefully hide triage UI if `CopilotTriage` field absent

**Deliverables:**
- End-to-end triage flow (scan → LLM triage → report render)
- Opt-in configuration flag

### Phase 3: UX Enhancements (Sentinel)
**Owner:** Sentinel  
**Timeline:** Sprint 4 (polish)

- [ ] "Ask Copilot" prompt builder modal (pre-fill templates per finding type)
- [ ] Top 10 triaged findings quick-access table
- [ ] Bulk command export (copy all auto-remediable commands as shell script)
- [ ] Triage filter: show only auto-remediable, only high-confidence, etc.
- [ ] Dark mode support for triage panels

**Deliverables:**
- Enhanced interactive features
- User testing feedback

### Phase 4: Telemetry & Analytics (Lead decision)
**Owner:** Lead  
**Timeline:** Sprint 5 (opt-in only)

- [ ] Track which commands users copy (hashed, anonymized)
- [ ] Triage accuracy feedback button ("Was this helpful?")
- [ ] Privacy-preserving metrics (no PII/secrets)

**Deliverables:**
- Opt-in telemetry framework
- Privacy impact assessment

---

## Risks & Mitigations

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| LLM hallucinations in `suggestedCommand` | **High** - destructive command | Medium | Add `--dry-run` flag to all auto-gen commands, require user review |
| UI clutter with 1000+ findings | **Medium** - unusable report | High | Default to collapsed, add "Show All Triage" toggle, lazy-load panels |
| Schema bloat (`CopilotTriage` adds 2-5KB per finding) | **Low** - file size | Medium | Gzip HTML output, use sidecar JSON in Phase 5 |
| Triage cost ($0.01-0.10 per finding) | **Medium** - budget | Medium | Throttle to top 100 findings by severity, cache results |

---

## Success Metrics

- **Adoption:** 60% of reports generated with triage enabled by Month 3
- **Utility:** 40% of suggested commands copied/executed by users
- **Accuracy:** <5% "not helpful" feedback on High-confidence triage
- **Performance:** Report generation <10s slower with triage vs. without

---

## Related Work

- **Issue #105**: Copilot triage loop ingestion (dependency)
- **Issue #98**: Wrapper error paths (current branch context)
- **Defender for Cloud**: Similar "recommended actions" UX pattern
- **GitHub Advanced Security**: SARIF triage field precedent

---

## Appendix: Wireframe

```
┌─────────────────────────────────────────────────────────────────┐
│ Azure Analyzer Report                        Generated 2026-04-17│
├─────────────────────────────────────────────────────────────────┤
│ [Dashboard] [Azure] [Identity] [CI/CD] [Compliance] [Cost]      │
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│  ┌───────────────┐  ┌──────────────────────────────────────────┐│
│  │  Compliance   │  │ Total: 247  │ Non-Compliant: 89          ││
│  │               │  │ Compliant: 158 │ High/Critical: 12       ││
│  │      73%      │  └──────────────────────────────────────────┘│
│  └───────────────┘                                               │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────────┐│
│  │ 🤖 Copilot Triage Summary                                   ││
│  │  147 Triaged  │  89 Auto-Remediable  │  58 Needs Review    ││
│  │  [View Top 10 →]                                            ││
│  └──────────────────────────────────────────────────────────────┘│
│                                                                   │
│  Networking Findings (12)                                        │
│  ┌──────────────────────────────────────────────────────────────┐│
│  │ Title              │ Sev  │ Compliant │ Actions              ││
│  ├──────────────────────────────────────────────────────────────┤│
│  │ NSG allows SSH ... │ High │ No        │ [🤖 Triage]         ││
│  ├──────────────────────────────────────────────────────────────┤│
│  │ ┌────────────────────────────────────────────────────────┐  ││
│  │ │ 🤖 Copilot Triage  [High Confidence] [Priority: 92]   │  ││
│  │ │                                                         │  ││
│  │ │ AI Summary:                                            │  ││
│  │ │ This NSG rule exposes port 22 to the internet...      │  ││
│  │ │                                                         │  ││
│  │ │ Suggested Fix [Auto-Remediable]:                       │  ││
│  │ │ $ az network nsg rule update --resource-group...      │  ││
│  │ │ [📋 Copy]  Impact: Low                                 │  ││
│  │ │                                                         │  ││
│  │ │ Related: azqr-nsg-003, defender-001                   │  ││
│  │ │ Tags: internet-exposed, lateral-movement-risk         │  ││
│  │ └────────────────────────────────────────────────────────┘  ││
│  └──────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

---

## Conclusion

This proposal defines a **production-ready mockup** of the Copilot Triage Panel that:

1. ✅ Fits existing report-template.html design language
2. ✅ Supports opt-in activation (graceful degradation when triage absent)
3. ✅ Provides actionable, copy-ready remediation commands
4. ✅ Surfaces related findings and AI confidence
5. ✅ Phases implementation (static mockup → live integration → UX polish)

**Next Steps:**
1. Sentinel reviews proposal, flags schema/UX concerns
2. Forge confirms Phase 2 #105 integration contract
3. Lead approves CHANGELOG/README update scope
4. Sage creates PR with this proposal, awaits rubber-duck gate

**Approval Path:**
- [ ] Sentinel schema review
- [ ] Forge integration feasibility
- [ ] Lead UX/telemetry sign-off
- [ ] 3-model rubber-duck (Opus 4.6 + Goldeneye + GPT-5.3-codex)

