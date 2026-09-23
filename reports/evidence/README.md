# Public Engineering Evidence

| Evidence | Requirements | Result | Verified source | Summary |
|---|---|---|---|---|
| `P10-HEX-S6-EV-01` | S6 six-by-seven HEX functional scope | CONDITIONAL_PASS | `128fc195` base + recorded acceptance-app hash | [P10 HEX S6 board acceptance](p10-hex-s6/summary.md) |
| `P08B-VGA-EV-01` | `VGA-001..006` | CONDITIONAL_PASS | `f28e95df2eafcb939e04ffaca728c44f74c90612` | [VGA HW clear / W1C](vga-hwclear/summary.md) |
| `P08B-G0-EV-01` | firmware trap endpoint | STOP | historical source snapshot | [Gate 0](p08b_gate0/summary.md) |

`CONDITIONAL_PASS` above is limited to owner-accepted P08B VGA functional scope. It is not a release, static CDC result, external I/O timing sign-off, electrical approval, or an independently logged programmer-to-board identity.

`P10-HEX-S6-EV-01` is likewise limited to the documented P10 HEX compile/pin,
firmware-driven board-observation scope. It does not close `STA-002`, ADC/VGA,
PLL, CDC, tracker items outside that scope, or analog transient measurement.
