# LEAR handheld BLE contract (protocol v2)

This is the interface between the LEAR Chat phone app and the handheld node (ESP32-S3 + SX1262). The handheld firmware implements the GATT server below. The app is the GATT client.

- All 16-bit values are **big-endian**.
- Text is **UTF-8**, at most **144 bytes** per message (bytes, not characters).
- Advertised name starts with **`LEAR`** (for example `LEAR-1A2B`). Advertise the service UUID too if it fits.
- Pairing uses **LE Secure Connections with passkey entry**. The handheld shows a 6-digit passkey on its OLED and the phone's system dialog asks for it. Mark TX, RX, STATUS and VERSION as requiring an encrypted, authenticated link.
- The app requests an ATT MTU of 247. A v2 TX write with a full message is 148 bytes, so the handheld must accept an MTU of at least 151.

## Service and characteristics

| Name | UUID | Properties | Direction |
|---|---|---|---|
| Service | `4c454152-4d45-5348-0001-000000000000` | | |
| TX | `4c454152-4d45-5348-0002-000000000000` | Write (with response) | phone → node |
| RX | `4c454152-4d45-5348-0003-000000000000` | Notify | node → phone |
| STATUS | `4c454152-4d45-5348-0004-000000000000` | Read, Notify | node → phone |
| VERSION | `4c454152-4d45-5348-0005-000000000000` | Read | node → phone |

## TX: send a message (phone → node)

```
v2:  CID_hi CID_lo DST_hi DST_lo  text…   (4 + ≤144 bytes)
v1:  DST_hi DST_lo  text…                 (2 + ≤144 bytes)
```

- **CID** (client ID) is a 16-bit number the phone picks for each message. The node must echo it in every status for that message. The phone never reuses a CID while that message is still open.
- **DST** is the destination node ID.
- Reply to the write (ATT Write Response) only after the message is safely in the node's outgoing queue. If the queue is full, reject the write with an ATT error. The app then shows the message as failed and offers a retry.

## RX: notifications (node → phone)

| First byte | Layout | Meaning |
|---|---|---|
| `0x01` | `0x01 SRC_hi SRC_lo text…` | A message from node SRC |
| `0x02` | `0x02 ID_hi ID_lo state` | Delivery status. ID is the **CID** (v2) or the node's message ID (v1) |

Delivery `state` values:

| Value | Name | Meaning | App shows |
|---|---|---|---|
| 1 | QUEUED | Accepted into the node's outgoing queue | One grey tick |
| 4 | SENT | The first mesh hop sent its hop-by-hop ACK *(new in v2)* | One tick |
| 2 | DELIVERED | **The destination node confirmed receipt end-to-end** | Two ticks |
| 3 | FAILED | Gave up (no route, TTL expired, retries exhausted) | Red, tap to retry |

The app ignores states that move backwards (for example QUEUED after DELIVERED) and a FAILED after DELIVERED. Unknown state values are ignored.

> **Firmware note: DELIVERED must be end-to-end.** In the mesh design this follows (Arregui Almeida et al., *Sensors* 2025, 25, 6036), ACKs are hop-by-hop: each relay confirms only its immediate predecessor. A hop ACK proves only that the next relay has the packet. Report that as **SENT**. Report **DELIVERED** only after an end-to-end acknowledgment from the destination node comes back through the mesh. This needs a small E2E-ACK packet type in the mesh layer, carrying the original mesh messageID back to the origin.

## STATUS (read + notify)

```
NODE_hi NODE_lo  SoC%  queueLength  link
```

- `SoC%`: battery 0–100.
- `queueLength`: messages waiting to go out, 0–255.
- `link`: 0 = no mesh neighbours, 1 = weak, 2 = good. For example, set it from the best neighbour score in the routing table.

Notify on any change and at least every 30 s while a phone is connected.

## VERSION (read)

```
[protocolVersion]     // 0x02 for this document
```

If the characteristic is missing, the app treats the node as **v1**: TX without a CID, statuses carrying the node's own message ID, and QUEUED statuses matched to messages **in the order they were written** (FIFO). v1 still works, but one lost QUEUED notification shifts every later match onto the wrong message, so new firmware should implement v2.

## Recommended firmware behaviour

1. **Store and forward to the phone.** While no phone is connected, keep incoming `0x01` messages (and final statuses) in a small ring buffer and send them as notifications after the phone reconnects and subscribes.
2. **Keep CID mappings across a phone reconnect**, so a message that was QUEUED before the link dropped can still be reported DELIVERED afterwards. Clear them only on reboot.
3. **Security scope.** BLE pairing protects only the phone ↔ handheld hop. The LoRa mesh itself has no encryption or authentication yet (the paper lists this as future work), so treat message content as readable by anyone with a LoRa receiver nearby.
4. **Airtime.** At SF7 / 125 kHz a 144-byte message plus mesh header is about 250 ms on air per hop. Respect the regional duty cycle and frequency-hopping rules (see the paper, section 2.3.2).

## Testing with nRF Connect (before the app)

1. Open nRF Connect, scan, and connect to `LEAR-xxxx`. Enter the passkey from the OLED when Android asks.
2. Under the LEAR service, tap the triple-arrow icon on **RX** and **STATUS** to enable notifications.
3. Read **VERSION**: expect `0x02`.
4. Read **STATUS**: expect 5 bytes, for example `00-01-57-00-02` (node 0001, 87 %, queue 0, link good).
5. Write to **TX** as a byte array (request type: *with response*), for example `00-01-00-02-48-69`: CID 0x0001, to node 0x0002, text `Hi`.
6. Expect RX notifications `02-00-01-01` (QUEUED), then `02-00-01-04` (SENT), then `02-00-01-02` (DELIVERED) once node 0002 acknowledges.
7. Send a message from another handheld and expect `01-SRC_hi-SRC_lo-…text…` on RX.
