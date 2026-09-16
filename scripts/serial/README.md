# SoC final demo serial scripts

## Frame format

All bring-up test frames use the same lightweight serial frame.

```text
SOF(0x7E) TYPE LEN PAYLOAD CHECKSUM EOF(0x0A)
CHECKSUM = (TYPE + LEN + sum(PAYLOAD)) & 0xFF
```

The current full demo keeps this lightweight outer frame, but LoRa traffic now
uses AES-GCM protected payloads inside `SECURE_C2R` / `SECURE_R2C` frames.
PC-to-SoC waypoint input over UART1 remains plaintext because it is a local
debug/control link.

Secure LoRa payload:

```text
TYPE = 0x30 SECURE_C2R or 0xB0 SECURE_R2C
PAYLOAD = NONCE_DIR[31:0] | SEQ_HI[31:0] | SEQ_LO[31:0] |
          LEN[15:0] | CIPHERTEXT[16B] | TAG[16B]

AES-GCM AAD = A5 5A | NONCE_DIR | SEQ_HI | SEQ_LO | LEN
IV          = NONCE_DIR | SEQ_HI | SEQ_LO
```

## RC car LoRa peer simulator

Run this on the PC port connected to the RC-side LoRa module.

```bash
python3 rc_lora_peer_sim.py --port COM7 --baud 115200 --response-delay 0.25 --inter-byte-delay 0
```

If SoC repeats `MODE_CHANGE` and HEX shows a mode-sync error, keep the default
response delay or increase it:

```bash
python3 rc_lora_peer_sim.py --port COM7 --baud 115200 \
  --response-delay 0.3 --inter-byte-delay 0
```

The response delay is intentional. A real LoRa module may still be busy
immediately after receiving an RF packet.

Do not add inter-byte delay for the tested LoRa modules. They may treat a UART
gap inside one frame as a packet boundary and transmit a partial RF packet. Send
all bytes of one frame back-to-back, then wait before the next frame if needed.
The SoC UART0/UART1 RX paths now have FIFO, so byte pacing is not required for
SoC-side overrun avoidance.

WSL examples may need Linux tty names instead of Windows COM names.

```bash
python3 rc_lora_peer_sim.py --port /dev/ttyS10 --baud 115200
```

The script decrypts and responds to:

- AES-GCM `MODE_CHANGE` -> AES-GCM `MODE_ACK`
- AES-GCM `MANUAL_CMD` -> plaintext lightweight `MANUAL_ACK`
- AES-GCM `WAYPOINT_CMD` -> AES-GCM `WAYPOINT_ACK`
- AES-GCM `TELEMETRY_REQ` -> generated AES-GCM `TELEMETRY_DATA`

Telemetry values are generated from the SoC `request_id` as a signed-centimeter
test path for the VGA RC-car map. In SoC `SW[1:0]=2'b01`, `x_est/y_est` move
around a visible 10 m x 5 m demo-space trajectory with `(480,240)` as the start
point on the VGA display.

## PC to SoC waypoint sender

Run this on the PC port connected to SoC UART1. Before sending, set the SoC
switches to `SW[1:0]=2'b11`, which means waypoint mode with PC coordinate input.

```bash
python3 pc_to_soc_waypoint.py --port COM10 --x 100 --y 200
```

WSL example:

```bash
python3 pc_to_soc_waypoint.py --port /dev/ttyS6 --x 100 --y 200
```

By default the frame is sent once. Use `--repeat N` only when intentionally
testing repeated waypoint packets.
