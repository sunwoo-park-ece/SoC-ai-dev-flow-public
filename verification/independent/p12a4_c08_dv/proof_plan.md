# C08 independent portable DV

Contract: VGA spec sections 3.2.1–4 and DIAG AC01–08. No physical signoff.
Production lane uses exact canonical RTL and an externally controlled open PLL
model. No internal force/deposit/seed. Reference transactions originate at
accepted external address phases, collect sampled RAM commands through terminal
global completion, and predict decode/response from contract and external
reset/lock/known idle or busy stimulus. Bank begins at reset front=0; this
focused lane does not swap. Prior CDC regression covers natural swaps.

Proof map: AC01/02/06 loss stimulus -> expected saturated event history ->
COUNT checks including real 65536 episodes, stopped clocks and pending reset.
AC03/04 interface transactions -> per-ID response, port address/data/bank/count
checks; qualified disagreement sensitivity in isolated observation fixture.
AC05/07 status bus samples -> count/fault pre-update, selective writes and
retention; set-vs-clear collision requires isolated fixture because ordinary
FB completion and STATUS write cannot coincide on this one data-phase slave.
FW raw snapshots -> no-progress, report-before-clear, lease and pre-SWAP tests.

Mutation matrix (all isolated source copies in fresh local runs):

| Fault | Layer/mechanism/isolation | Expected rejection | Reach/control/limit |
|---|---|---|---|
| count +2 | copied DUT arithmetic only | COUNT | explicit loss, original control; digital only |
| sticky set omitted | copied DUT sticky assignment | FAULT | injected observed command + sampled lock-low; fixture only |
| CPU observed command early/duplicate/wrong address/data/bank | copied monitor-input adapter controlled by TB; actual RAM/functional cone unchanged | fault must set, FAULT if omitted | adapter activation trace plus quiet/loss-free/excluded controls; not physical mismatch |
| port observation wrong data | scoreboard input adapter only | PORT_DATA | unchanged DUT, activation trace, passing same transfer |
| wrong STATUS-read oracle | checker input self-test | READ_COUNT | unchanged DUT, intentional wrong external expectation |
| dropped transaction trace | guard-input copy | GUARD_TRACE | raw log untouched; parent must exit nonzero |
| driver clear mask wrong | isolated driver copy | FW_CLEAR_MASK | explicit API call, original control |

Each new checker has passing and targeted negative input. Runner requires
specific assertion IDs and activation, checks real source pre/post equality,
and preserves target/guard/final separately. Missing/incorrect rejection is FAIL.
Remaining unsupported bins are EVIDENCE_INSUFFICIENT, never inferred PASS.

Additional isolated semantic controls used by the runner:
port bank inversion -> PORT_BANK; CPU word address +1 -> PORT_ADDRESS;
CPU command omission -> COMMAND_COUNT; reserved STATUS bit -> RESERVED;
remove saturation guard -> READ_COUNT after 65536 real loss episodes.
Each is a copied source, original Production passing control, same external
stimulus, and exact rejection required after successful compile. They test the
external observer, not the independence of the on-DUT diagnostic comparator.
The normal FB pipeline has five CPU writes (four initial plus one after recovery).
A first development guard mistakenly expected four; original guard FAIL retained.

The Production oracle predicts only conservatively settled recovery (40 clocks)
and clear-busy intervals; full arbitrary recovery/ownership is delegated to the
unchanged prior CDC regression. The explicit monitor input adapter injects early
and repeated observed commands. No physical RAM command is added by that adapter.
An additional sticky-clear adapter tests set dominance on the same edge; this is
an otherwise unreachable synthetic FB-completion/STATUS-W1C overlap, fixture only.
Do not claim separate address/data/timing monitor discriminator sensitivity from
one combined fault. Analog edge-near behavior and minimum pulse width remain unproven.

## Isolated comparator discriminator fixtures
Planned copied monitor-only adapters synthesize one OKAY observation and one
CPU command at the final error transaction while keeping the real external
ERROR and zero physical port writes. Matching adapter control must keep fault=0.
Change only observed address (monitor=2), data (=3), early timing (=4), duplicate
multiplicity (=5), or bank (=6); expected FAULT becomes 1, witnessed through
STATUS. Each fixture prints its mode/activation; independent bus oracle continues
to check actual ERROR/zero side effects. This tests comparator sensitivity, not
Production mismatch coverage, and cannot prove independent response/WE logic.

## Oracle adversarial review
The initial checker allowed observed ERROR-wait to set expected rejection. That
could accept a falsely rejected valid write. Remove that feedback: only external
address, reset/lock/recovery setup and reference busy state predict rejection.
Count ERROR-wait as an observation, assert its independently predicted legality.
Isolated false-error decode mutant must now fail ERROR_UNEXPECTED, proving that
a valid write cannot silently become an expected ERROR. Earlier runs are
superseded for the response-oracle claim and remain retained.

Two-cycle ERROR is also independently asserted: exactly one local wait cycle
before accepted ERROR, irrespective of global stall. An isolated always-ready
response mutant must fail ERROR_SEQUENCE, rather than pass a premature error.
