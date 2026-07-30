#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

# 77-feedback-intake.t
#
# Test oracle for blueprint package b25-feedback-intake.
# Covers plugins/butler/scripts/bp-feedback.pl (CLI) and
# plugins/butler/skills/feedback-intake/SKILL.md (skill contract).
#
# Neither implementation exists yet by design: this file is the
# immutable oracle a later implementer works against. It must fail
# for "missing implementation" reasons only, never syntax errors.
#
# AC groups (filled in incrementally; file rewritten to disk after
# each group so partial progress persists even on transient death):
#
#   T-A  run_cli helper + CLI basics / arg parsing / help / exit codes
#   T-B  batch selection: empty -> batch-1; newest open reused;
#        newest closed -> next created (closed left byte-identical);
#        numeric ordering; --batch override onto closed batch
#   T-C  intake of raw input -> corrections/ tree structure
#        (data-dir based, never touches real corrections/)
#   T-D  DECOMPOSED.md structural assertions (no counts, no line
#        numbers; unanchored Basis marker matching; Source not
#        universal; no per-finding Disposition; non-monotonic IDs)
#   T-E  SKILL.md contract: 7-part superset assertions, required
#        literals L22-L33
#   T-F  red-team surface: huge paste, binary input, concurrent
#        writers, symlinked batch dir
#   T-G  proof-on-real-input (SKIP-guarded against real corrections/)
#
# Done-criteria coverage (b25-feedback-intake.md, 13 bullets) tracked
# inline as each group is implemented.

# TODO: T-A
# TODO: T-B
# TODO: T-C
# TODO: T-D
# TODO: T-E
# TODO: T-F
# TODO: T-G

done_testing();
