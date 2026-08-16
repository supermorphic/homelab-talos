# SDD ledger — plan: docs/superpowers/plans/2026-08-15-fileflows-qsv-hevc-icq-evaluation.md
Setup: verified linked worktree on branch fileflows-icq-evaluation; fetched origin; rebased identical decision tree onto origin/main 83d9c74.
Baseline: `mise exec -- just ci` passed at 83d9c74 (canonical run 20260815T214306Z-83d9c741ae84-operator-64a3cfb6).
Task 1: review scope ruling — operator kept Task 1 limited to its explicit shared-contract scope; QSV command/proof, manifest/results schemas, and guarded evidence remain assigned to Tasks 2–4.
Task 1: complete (commits 83d9c74..422f3fc, focused 65/65 and offline validator 160/160 passed; reviewer findings deferred by operator to their explicit later tasks).
Task 2: fix round 1/5 (4 addressed, 0 open; commits 6905d6b..f1573d2).
Task 2: complete (commits 422f3fc..f1573d2, review clean).
Task 3: fix round 1/5 (1 addressed, 0 open; commits baeada0..b379c4a).
Task 3: complete (commits f1573d2..b379c4a, review clean).
Task 4: fix round 1/5 (3 addressed, 0 open; commits 61e44a1..22ac31b).
Task 4: complete (commits b379c4a..22ac31b, review clean).
Task 5: fix round 1/5 (2 linked findings addressed, 0 open; commits a7237e7..5690fa2).
Task 5: complete (commits 22ac31b..5690fa2, review clean).
Task 6: fix round 1/5 (1 addressed, 3 open — dispatch/runtime quality run identity mismatch; retained backup unsafe on retry; dispatch accepts impossible UTC values; commits 7b31210..82e014b).
Task 6: fix round 2/5 (3 addressed, 0 open; commits 82e014b..b3e583b).
Task 6: complete (commits 5690fa2..b3e583b, review clean).
Task 7: fix round 1/5 (2 addressed, 0 open; commits 15b729e..02e356c).
Task 7: complete (commits b3e583b..02e356c, review clean).
Task 8: fix round 1/5 (1 addressed, 1 open — runtime hashes earlier valid cohort before validating later malformed final claim; commits 8be0d37..13e1ec5).
Task 8: fix round 2/5 (1 addressed, 0 open; commits 13e1ec5..6b39d87).
Task 8: complete (commits 02e356c..6b39d87, review clean).
Task 9: fix round 1/5 (0 addressed, 7 open — threshold verdict semantics; case/worker cardinality and binding; manifest and resume validation; complete second-node proof; in-range boundary coverage; unrelated finalist assertion; commit d389a27).
Task 9: fix round 1/5 result (6 addressed, 1 open — genuine runmeta manifests include validated `createdAt` before exact identity normalization; commits d389a27..3a90a39).
Task 9: fix round 2/5 (1 addressed, 0 open; commits 3a90a39..4d019ac).
Task 9: complete (commits 6b39d87..4d019ac, review clean).
Task 10: complete (`feat(media): generate ICQ cohort findings`; focused findings/cross-strategy/cross-schema 8/8, offline validator 227/227, and canonical `mise exec -- just ci` passed; external SDD review deferred by operator).
