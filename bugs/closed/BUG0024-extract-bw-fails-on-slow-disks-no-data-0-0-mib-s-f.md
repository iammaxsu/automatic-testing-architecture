---
id: BUG0024
status: closed
created: 2026-05-18
closed: 2026-05-19
os:
  - Ubuntu 26.04 LTS
related_requirements: [LOG012, LOG015]
related_bugs: []
---

# BUG0024 — extract_bw fails on slow disks no data 0.0 MiB/s for RND4K patterns

## Symptom

extract_bw() in disk_test.sh uses sed regex [KMG]B\/s for the SI-unit side of fio output, which only matches uppercase K/M/G. fio outputs (NNNkB/s) with lowercase k for slow disks (per SI convention). Whole sed pattern fails -> empty output -> summary shows "no data", result.json marks pattern as SKIPPED, HTML shows 0.0 MiB/s.

## Fix

Fix: rewrite extract_bw to (a) parse IEC and SI unit prefixes including lowercase k, (b) canonicalise to MiB/s and MB/s regardless of input scale. Closed 2026-05-19 — extract_bw rewritten with case-insensitive K/M/G/T parsing and unit canonicalisation. Verified on adlink-mecs-6110 (Ubuntu 26.04): RND4KQ1T1 Read 0.523 MiB/s, Write 1.099 MiB/s; SEQ tests unchanged.
