# Configurable teams verification — 28 November 2026

Implemented user-owned Agent create/edit/disable, per-member model configuration,
admission snapshots, sequential handoff and parallel workers followed by coordinator
aggregation. PostgreSQL now has 15 tables. Backup preceded the local additive upgrade;
legacy-run price backfill and fresh/upgrade schema parity are covered by tests.

Validation:
- 48 PostgreSQL-backed cases passed with no skips (4.61 s final run). Provider calls
  are mocked at HTTP transport in this suite; 8 cases cover the team extension.
- Frontend vue-tsc and Vite production build passed.
- Changed Python modules pass Ruff E4/E7/E9/F checks. The broader inherited Ruff
  rules report existing FastAPI Depends/default patterns and style findings; this
  is not a claim of a clean full-rule repository lint run.
- UI created two profiles, selected separate models, chose parallel mode, sent the
  task and displayed per-member outputs, price versions and all three charges.
- Real DeepSeek run: task 14f4f4e1-7c3b-47ff-8623-45618b8921bd,
  two workers used deepseek-flash and deepseek-v4-pro; coordinator used flash.
  Request intervals overlapped by 1.602227 s; task elapsed 8.412413 s.
  Calls: .000937 + .0009655 + .001945 = .0038475 USD at demonstration rates.
  All three amounts independently recalculated with Decimal.

Limits: one configured provider endpoint, at most four simultaneous members per
team, shared soft budget (in-flight calls can overshoot), single API process,
no automatic retry or crash resume. Same-task snapshot/price consistency and
snapshot immutability are enforced through application creation paths, not database
triggers. No claim of measured provider-side compute concurrency or general speedup.

Artifacts reside outside the source tree in outputs/MDS5120-report/evidence:
parallel-live.json, parallel-independent-check.json, team-tests.txt, team-build.txt
and UI captures. Earlier attachment/index evidence remains a separate baseline.
The updated English report adds team relationships, normalization qualifications,
concurrency semantics and independent live verification in Appendices C–E.
