# Real-world validation fixtures

Real judicial-opinion text (US government works, public domain) sourced from
the open web, used to validate incitez beyond eyecite's curated test corpus —
on messy real prose, with AI judgment of the result.

## cunningham_v_cornell_2025.txt

- **Case:** Cunningham v. Cornell Univ., No. 23-1007 (U.S. 2025)
- **Source:** Cornell Legal Information Institute,
  https://www.law.cornell.edu/supremecourt/text/23-1007 (fetched 2026-06-12)
- **Content:** citation-bearing sentences/clauses extracted verbatim from the
  opinion (full case cites, short forms, supra-style party refs, an 1872
  Wallace-reporter cite, and a 29 U.S.C. statutory cite). Markdown artifacts
  (links, italics, escaped brackets) stripped to plain text.
- **Validation result (2026-06-12):** incitez and pinned eyecite agree
  **23/23** — identical types, reporters, volumes, pages, pins, years, and
  antecedents. AI judgment: every citation a careful reader would find IS
  found; no false positives. One shared limitation (en-dash pin ranges) was
  surfaced here and then SURPASSED — see docs/principled_divergences.md §3.
