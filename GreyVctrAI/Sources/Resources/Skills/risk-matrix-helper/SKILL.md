---
name: risk-matrix-helper
description: Calculate draft initial and residual risk levels from severity and probability inputs using Army/Air Force risk matrix conventions.
---

# Risk Matrix Helper

Help National Guard members organize user-provided hazards, controls, severity, and probability into a draft risk summary. This skill uses JavaScript to calculate risk levels from a public Army/Air Force-style risk matrix, then uses the model to explain the results in plain language.

This skill is a draft helper only. It does not replace DD Form 2977, ATP 5-19, AFI 90-802, AFPAM 90-803, Service policy, local safety guidance, commander risk decisions, supervisor review, or official risk acceptance authority.

## Critical Formatting Rule

If the JSON result includes `result.mobileText`, output that text directly. Do not rewrite it as a Markdown table. Do not add pipe-delimited rows. Do not use columns. The mobile app wraps wide tables into unreadable text.

## Reference Basis

The calculation uses the common Army/Air Force risk assessment matrix pattern:

- Severity: I Catastrophic, II Critical, III Moderate, IV Negligible
- Probability: A Frequent, B Likely, C Occasional, D Seldom, E Unlikely/Rarely
- Risk levels: EH Extremely High, H High, M Medium, L Low

Matrix:

```text
        A   B   C   D   E
I       EH  EH  H   H   M
II      EH  H   H   M   L
III     H   M   M   L   L
IV      M   L   L   L   L
```

## Examples

- "Build a risk matrix for these hazards"
- "Calculate initial and residual risk for this training event"
- "Sort these hazards by residual risk"
- "Flag missing controls in this draft risk assessment"
- "Create a safety brief from these assessed hazards"
- "Use this voice transcript to build a draft risk summary"

## Instructions

When the user asks for risk matrix, hazard assessment, safety risk, or control tracking support:

1. Extract each hazard from the user's typed notes, audio transcript, or non-sensitive photo-derived observations.

2. For each hazard, identify:
   - hazard: short description
   - cause: stated cause, if provided
   - effect: stated effect or consequence, if provided
   - initialSeverity: I, II, III, or IV
   - initialProbability: A, B, C, D, or E
   - controls: list of user-provided controls
   - residualSeverity: I, II, III, or IV, if provided
   - residualProbability: A, B, C, D, or E, if provided
   - owner: if provided
   - status: open, in progress, complete, or unknown
   - notes: if provided

3. If the user gives labels such as "moderate" or "likely", map them to the matching codes:
   - catastrophic = I
   - critical = II
   - moderate = III
   - negligible = IV
   - frequent = A
   - likely = B
   - occasional = C
   - seldom = D
