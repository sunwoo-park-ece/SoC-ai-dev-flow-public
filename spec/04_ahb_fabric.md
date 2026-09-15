# AHB-Style Fabric Contract

The active data fabric has one CPU master and three logical targets: DMEM, VGA/VRAM, and the AHB-to-APB bridge. No arbiter is required.

- Address selection is qualified by an active transfer.
- The selected target is retained from address phase to data phase and across wait states.
- Read data, ready, and response are returned from the retained data-phase target.
- Canonical range and size checks prevent physical implementation aliases from becoming architectural addresses.
- Invalid or unmapped transfers complete with the project's two-cycle ERROR response.
- An error completion cancels the following address phase so a failed request cannot create an unintended side effect.

The interface supports the single-transfer behavior required by the SoC; it does not claim full AHB-Lite feature coverage or burst support.
