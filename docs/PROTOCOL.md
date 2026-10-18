# Protocol reconciliation

Sources: the upstream [ear-web control implementation](https://github.com/radiance-project/ear-web) and static analysis notes for Nothing X 3.10.0. APK package `com.nothing.smartcenter`, version code 3100009, base SHA-256 `d58259729b96b405bb5344800f8f66da57d9050fd285757de9b5f3a3ce3cd60d`. Static analysis is evidence of implementation, not proof of support on every firmware. No APK code, proprietary app binary or decompiled source is distributed here. The command table below records the observations used by this implementation.

Upstream was inspected at commit `d076e1371572fbf0a14b441f9b3cafbf9a237e04`. Bundled `models.json` derives from `res/js/control.js`'s `FASTPAIR_MODELS`; `ear_config_file.json` is the upstream firmware catalogue, and `model_rules.json` records native routing rules derived from upstream behavior and device research. Upstream logo credit belongs to DerrenGoneDigital; that logo, product photographs and the Ndot font are not bundled.

## Framing

SOF 55, control u16LE, command u16LE, payload length u16LE, operation/FSN u8, payload, optional CRC u16LE. Control bit 0x20 requires CRC-16/MODBUS over header+payload, initialized FFFF with reflected polynomial A001. Low five control bits are response status, zero for success. Device type occupies control bits 8–11; byte 2 is not a version byte. The decoder accepts audio frame types 1 and 6. The 0x40 flag is retained as supplied. Receive buffers support one maximum 65,545-byte frame. Split/coalesced RFCOMM reads do not define packet boundaries.

Host requests start with the web's control 0x0160. B170 firmware queries fall back to native control 0x0660, then generic control 0x0160 with endpoint 6 substituted only for otherwise-empty query payloads. Route selection uses read-only handshake, battery and firmware requests; no setter is used as a probe. Replies correlate by normalized command `command & 0x7FFF` and FSN. FSN cycles 0–253. Both E0xx raw pushes and 60xx normalized pushes parse correctly. CRC-less frames are accepted only when the control flag explicitly omits CRC; corrupt CRC-bearing frames are rejected.

## Implemented target commands

All offsets are payload-relative. Empty getters are omitted from the payload column.

| Setting | Get / set decimal | Payload / parsing |
| --- | --- | --- |
| Protocol handshake | 49153 | Empty query before setting reads; no guessed activation mask |
| Battery | 49159 | Count then endpoint/packed-byte pairs; endpoints 2,3,4,6; low 7 bits percent, high bit charging |
| Firmware | 49218 | UTF-8 string |
| ANC | 49182 / 61455 | Get `03`; set `01 mode 00`; parse triples by type 1 current/type 2 remembered level |
| EQ | 49183 / 61456 | Set `preset 00`; 0 balanced,1 vocals,2 treble,3 bass,5 saved custom |
| Advanced EQ enable | 49228 / 61519 | Set `enabled 00`; UI choice 6 never goes to the ordinary EQ setter |
| Bass | 49230 / 61521 | `enabled wireLevel`; priority device UI levels 1–5 map to 2–10 |
| Wear setting | 49166 / 61444 | Count-prefixed feature/value records; locate feature 1; set `01 01 enabled` |
| Low latency | 49217 / 61504 | Set `01 00` on or `02 00` off |
| Ring | 61442 | Endpoint/enabled; B171 endpoints 2/3, B170 endpoint 6 |
| Ear tip fit | 61460; push 57357 | Set `01`; left/right results 0 good,1 adjust,2 unavailable |
| Spatial | 49231 / 61522 | B170 `00 00` off, `01 00` fixed, `01 01` tracked |
| Runtime exclusion | 49250 | B170 boolean status, queried around affected edits |
| Dual enable | 49191 / 61466 | One-byte enabled |
| Supported features | 49165 | Payload byte 1 bit 0x40 gates multipoint list/host actions |
| Dual list | 49192 | Page u16LE starting 0; total/current/count header; advance response current+1 until total |
| Dual host connection | 61467 | Enabled + six MAC bytes in received wire order; re-read list |
| Preferred codec | 49193 / 61468 | Set `index 00`; 0 AAC,1 LHDC,2 LDAC; firmware gates available choices |
| Mimi saved profile | 49186 / 61461 | B171 set `enabled 00`; enabling blocked with LDAC |
| Audiodo saved profile | 49242 / 61532 | B170 firmware >= *.*.1.75; one-byte enabled |
| UTC | 61450 | Epoch seconds u32LE |

Multipoint flags use nibble equality to 1. A name length with bit 7 set consumes exactly 31 bytes and displays a truncated label. Push 57358/24590 carries connected + MAC + needUpdate; needUpdate triggers a list refresh. List requests are capped at 20 pages. Device read-back remains authoritative.

## Differences and remaining uncertainties

| Web source | Resolution / limit |
| --- | --- |
| `res/js/bluetooth_socket.js:29`, `:38`, `:167` | APK Message establishes 16-bit control/length, optional CRC and status checking. Swift follows APK; the web assumes one packet per read. |
| `res/js/nothing_connected.js:145`; `res/js/control.js:51`, `:59`, `:402`, `:410` | Seven-byte Fast Pair model record and all four IDs match. Identification still assumes the model packet is the first pushed record on that service. |
| `res/js/bluetooth_socket.js:398`, `:402`, `:359` | APK ANC get selector `03` and typed triples replace the web's empty getter and fixed second-byte parser. Mode bytes 5/7/3/1/2/4 agree. |
| `res/js/bluetooth_socket.js:1126`, `:1132` | Locate wear feature 1 rather than assuming it is the first record. |
| `res/js/bluetooth_socket.js:1193` | APK uses u32LE UTC, replacing web big-endian output. |
| `res/js/bluetooth_socket.js:1311`, `:1313`, `:1346` | APK uses u16LE page indexes, not the web's one-byte accumulated-device count. Runtime list support, flags and truncation follow APK. |
| `res/js/bluetooth_socket.js:1408`, `:1556` | Mimi uses the APK two-byte integer builder. Codec currently uses the legacy APK two-byte form, but the current Flutter setter width is unresolved; web uses one byte. Read-back and explicit rejection detect failures. |
| `res/js/bluetooth_socket.js:473`; `res/js/eq_two.js:20`; `res/js/spatial_audio.js:77` | Keep static Bass/Advanced exclusions; consult APK runtime exclusion for ordinary preset conflicts. No automatic disabling of another user setting. |
| `res/js/bluetooth_socket.js:1163`, `:1174` | Web limits Personalized ANC to B155. The completed APK report confirms B171 isSupportPersonalANC=false and B170 inherits false. Both remain hidden; shared serializers do not grant capability. |
| `res/js/smart_dial.js:1`; `res/js/smart_knob.js:1` | Endpoint-4 case controls are unrelated to B170 endpoint-6 roller/button. All gesture editing remains deferred. |
| `res/js/bluetooth_socket.js:75`, `:962`; `res/js/versionUtils.js:45` | Read firmware before selecting config. 100 ms pacing is inherited from web, not a measured device timing requirement. |

Audiodo saved-profile wire commands are web-only evidence; the APK confirms the firmware capability but its current Aspen/Dart wire path remains unresolved. The generic/native B170 frame routes are implemented as read-only firmware fallbacks; hardware still needs to establish which route each firmware accepts. The initial C001 query matches the target native protocol activation entry points. No speculative notification-registration/activation payload is sent. Whether newer firmware requires additional activation, and transport behavior during sleep, reboots or long logical multi-frame exchanges, need device captures. Ring has no decoded readback state; the app displays requested ring state and always makes Stop available. Profile creation/calibration and graph editing remain outside scope.

## Built-in EQ editing

Custom values use C044 / F041, response 16452. Payload is count:u8, totalGain:f32LE, then count packed 13-byte records containing filter:u8, gain:f32LE, frequency:f32LE, Q:f32LE. Filter 0 is low shelf, 1 peak, 2 high shelf. The existing JS `createEQPacket` adds three trailing zero bytes per band after all records. APK `SimpleEQEntity.obtainDataPacket` uses packed records without that padding; Hushbar sends the APK layout and accepts either reply layout. A frozen JS vector checks the canonical payload with the nine padding bytes removed.

Current bundled B171 parameters are low 140 Hz/Q 0.8, mid 980 Hz/Q 0.7, high 3400 Hz/Q 1. B170 uses 3500 Hz for high. These are demo defaults; live editing reads first and preserves received parameters, including firmware-specific differences. UI gains are -6 through +6 dB, matching the shared Custom EQ range. Custom edits compensate total gain with `-max(0, gains)`.

Advanced values use C04D / F050, response 16461. The GET selector is `FF 00`, following the APK's u16LE builder. Value layout is profile:u8, count:u8, totalGain:f32LE, then packed 13-byte bands. Default centers are 55, 110, 220, 440, 1320, 3300, 6600 and 13200 Hz, with Q 1 and model total gain -6 dB. The editor preserves profile, filter, total gain, frequency, Q and band count from reads. It retains 1–8 read bands, without adding/removing bands or implementing B192's third driver. Advanced enable remains separate F04F; UI selection 6 is never sent as an F010 preset.

The pure codec rejects malformed/truncated lengths, non-finite floats and invalid ranges without replacing good state. Writes occur on slider release. The session serializes them with other edits, checks acknowledgements, reads back the corresponding values and restores only edited fields on failure. Confirmation tolerates float rounding. Reset changes gains to zero; it does not discard read-back tuning metadata. Byte vectors, round trips, malformed replies, dependency gates and rollback have Swift Testing coverage. Actual F041/F050 interoperability still requires live-device validation.
