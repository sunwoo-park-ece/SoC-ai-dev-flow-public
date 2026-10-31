# R7 bounded C09 digital proof

Contract: preserve first pixel (0,0), bits 0..63 including word boundary,
black until valid swap, reset/restart capture and selected-bank isolation.
Reuse the P12A2 AHB BFM and portable VRAM/PLL models without changes.
Coordinates come from a test-owned 800x525 raster driven by the observed pixel
clock and independently modeled two-edge reset release. Check external HS/VS
against it. Memory comes from accepted AHB data phases, never DUT RAM contents.
Bank ownership comes from legal swap acceptance and spec frame wrap, never DUT
front-bank state. Commands are scheduled far from wrap; this is not handshake DV.
The observed production front selector is cross-checked on every pixel edge
against that independent bank state, including blanking; it is not an oracle.

| Fault | Target/mechanism | Activation/reach | Required rejection | Passing control |
|---|---|---|---|---|
| Wrong bank | Isolated checker-input adapter selects observed RAM0 q at first B-front pixel; no DUT or oracle change | FAULT_ACTIVATED logs actual RGB and substituted opposite bank bit at coordinate 0,0 | FAIL_C09_PIXEL, vvp exit 1, negative lane marked expected rejection | FULL phase3 same stimulus without fault |
| Pixel delay | Isolated checker-input adapter delays raw RGB by one sampled pixel | FAULT_ACTIVATED at first 0,0 logs current and prior RGB | FAIL_C09_PIXEL, vvp exit 1, expected rejection | FULL phase3 same stimulus without fault |

No force/deposit/Production mutation, no counter fast-forward. Legal source
clock stop and existing test-only PLL loss hook model lock loss/reacquisition.
Check retained model q during stopped clock, black output during invalidity,
post-restart zero-address capture before first visible pixel. No physical or
actual MAX10 internal-clear guarantee is inferred from the portable model.
Runner must capture commands, hashes and actual exits, validate coverage and
specific negative rejection, and propagate control failure/nonzero guard exit.
