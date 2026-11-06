# CLAUDE.md

Rules for an agent working in this repository. Every one of them exists because it was
broken here, and the failure is named so the rule is not mistaken for style advice.

## The documents are the authority, not your memory of them

`README.md` §"Who decided what" is the record of what the user asked for, what was assumed,
and what was done. It outranks recollection in both directions.

**Before claiming something is required, forbidden, or blocked by the contract, read that
section.** Not a summary of it, the section.

> It was already written there that public-transport data must be byte-for-byte identical
> while internal ids may change. An `Int32` id was nonetheless presented to the user as a
> blocker that ruled out a whole architecture. The documentation was right; the claim
> contradicted it.

**Before explaining why something in this repo is the way it is, read that thing.** A
rationale reconstructed from memory is a guess wearing a fact's clothes.

> A paragraph was written defending an SSH ingress rule on security grounds. The module had
> already attached SSM and no key pair at all, so the rule admitted nobody. The code was
> right; the explanation was invented.

## Every session's decisions go back into the documents

The user's standing requirement: what was asked, what was assumed or inferred, and what was
done all end up in markdown. That is what §"Who decided what" is for, in three lists.

A session that changed the design and left that section untouched is unfinished. So is one
that updated `README.md` and not `README.he.md` — they are a pair, and
`grep -c '^#' README.md README.he.md` should agree.

## A measurement without its scope is not a measurement

Every number in `docs/` carries what it was measured on: the date, the parameters, the row
count, and the machine if that matters. A reader cannot audit `10.8x`; they can audit
`362,974 bytes at limit=500 over a one-minute window on 2026-11-05`.

> The same endpoint compresses 48x unfiltered and 10.8x filtered, because the unfiltered
> query returns junk rows. Without the parameters, both numbers are true and neither is
> useful.

State the opposite too. If a comparison ran on three days of data and the production table
holds four years, say so in the same breath as the result.

## "Verified against production" names its window

The differential suite proves agreement for the cases it ran. It does not prove a field is
populated.

> 27 of 27 endpoints were reported byte-identical while `duration_minutes` was `NULL` for
> every row the enrichment had ever written — the cases all sat inside the dump's window,
> where the value came from the dump. 0 of 220,518 recent rides had it.

When reporting coverage, say which window, and check the fields the enrichment writes `NULL`
into (`ingest/enrich.sql` casts them explicitly — they are easy to find and easy to forget).

## A test for a fix is run against the unfixed code

Revert the change, run the test, keep the failure output, restore. A test that passes either
way is not coverage, and running it is also how weak assertions are found.

> `res.headers['content-encoding']` raised `KeyError` without the fix, which reads as a
> broken test. `.get()` gives `assert None == 'gzip'`, which reads as the regression it is.

Installing whatever is needed to run things is allowed; the session is in a container.

## Where production disagrees with this implementation

Two reasons are legitimate and they are documented differently:

- **Internal to us** — surrogate ids, ETL bookkeeping timestamps. Ours to choose. Note it.
- **A production defect** — fixing it justifies departing from byte-for-byte. Open a finding
  in `docs/FINDINGS.md` and `docs/FINDINGS.he.md` with the measurement attached, and say in
  the README that the divergence is intended.

Anything else is a defect here, whatever the comparison says.
