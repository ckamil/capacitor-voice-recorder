# Plan testów — live audio streaming (przypadki brzegowe)

Skupiony na trudnych przypadkach: brak dostępu do serwera, słaby/przerywany zasięg, cykl życia
aplikacji, różnice urządzeń (encodeMode iOS).

> **Zasada nadrzędna (kryterium FAIL dla KAŻDEGO testu):** streaming jest **additywny** — kanoniczne
> nagranie (plik z HTTP upload, lista nagrań, `/recordings/{id}/play`) MUSI być zawsze kompletne i
> odtwarzalne niezależnie od dowolnej awarii streamu. Jeśli jakikolwiek scenariusz uszkodzi nagranie
> kanoniczne albo zawiesi/zcrashuje apkę → blocker.

---

## 0. Przygotowanie i narzędzia obserwacji

**Włączenie:** `recording.streaming_enabled=1`, endpoint `wss://<tenant>/ws-audio`.
Tryb iOS: `recording.streaming_ios_encode_mode` = `file_tail` (domyślny) | `software` | `hardware`.

### Obserwacja po stronie serwera (SSH `root@10.70.70.61`, env `ahd|rs.friendlysol.com`)
- Plik: `find /crm2015/storage/audio/<env>/<person>_<uuid>/ -type f -printf "%s\t%p\n"`
- Integralność (parser ADTS): liczba ramek, **śr. rozmiar ramki — ~180 B = realne audio, ~11 B = cisza**, `clean_end`
- `ffprobe audio.aac` (codec/sampleRate/duration); `ffmpeg -v error -i audio.aac -f null -` (0 = brak błędów dekodowania)
- `meta.json`: `device`, `location`, `encodeMode`, `recordingId`
- Logi: `grep "RecordingStream" /crm2015/storage/logs/<env>/laravel-*.log` → `end` (bytes/lastSeq), `gap`, `onError`

### Obserwacja po stronie aplikacji
Event `recordingStreamEvent` (logowany przez `loggerService` → lokalne logi + Rollbar):
`connecting` / `connected` / `reconnecting` (attempt, backoffMs) / `disconnected` (code) /
`dropped` (droppedFrames) / `error` / `finished` (framesSent, bytesSent, reconnects).

### Symulacja warunków sieciowych
- iOS **Network Link Conditioner** (Ustawienia → Developer): „Very Bad Network", „100% Loss", „High Latency".
- **Airplane mode** toggle w trakcie nagrania.
- **Charles/Proxyman**: throttle, cut connection.
- Serwerowo: `supervisorctl stop <ws>`, `systemctl stop nginx`, blokada portu, zły `streaming_path`.

### Parametry referencyjne (defaulty)
`maxBufferSeconds=10`, reconnect backoff `1s→8s` (`maxAttempts=0` = bez limitu),
`pingIntervalMs=20000`, `requireReachability=true`. Limity serwera: 4 h / 500 MB / 3 połączenia per person.

---

## A. Baseline
| # | Scenariusz | Oczekiwane |
|---|---|---|
| A1 | Happy path iPhone (60 s, `file_tail`) | plik ~180 B/ramkę, `clean_end=true`, `end bytes≈framesSent`, 0 `onError`/`gap`; meta z device/location/encodeMode; nagranie kanoniczne pełne |
| A2 | Happy path iPad | jw. |
| A3 | Android | jw. (encodeMode=file_tail) |

## B. Brak dostępu do serwera
| # | Scenariusz | Jak wykonać | Oczekiwane |
|---|---|---|---|
| B1 | Serwer WS down całe nagranie | `supervisorctl stop` WS, nagraj 30 s | nagranie kanoniczne pełne; app: `connecting`→`error/reconnecting` z backoffem; brak/pusty backup; brak crasha |
| B2 | Serwer pada w trakcie | dobra sieć 15 s → `stop` → 30 s → stop | backup ~15 s (+ bufor ≤10 s), potem urwany; `disconnected`+`reconnecting`; nagranie pełne |
| B3 | Serwer wraca w trakcie | jak B2 + `start` po 20 s | po reconnect `connected`, ramki dopisywane; **brak duplikatów** (dedup `seq`), plik NIE reotwarty (idempotentny `start`) |
| B4 | nginx down | `systemctl stop nginx` | jak B1 (502/refused); nagranie pełne |
| B5 | Zły URL/ścieżka | `streaming_path=/zle` | `error`, brak streamu, plik kanoniczny OK |
| B6 | 502 (okno restartu) | restart WS w trakcie | krótka przerwa, reconnect, utrata tylko poza buforem |

## C. Słaby / przerywany zasięg
| # | Scenariusz | Jak wykonać | Oczekiwane |
|---|---|---|---|
| C1 | Dropout < bufor | NLC „100% Loss" 5 s | **zero utraty**; bufor pokrywa; brak luki `seq`, brak `dropped` |
| C2 | Dropout > bufor | NLC „100% Loss" 30 s | `dropped`(droppedFrames), **luka `seq`** (najstarsze odrzucone), plik dalej **poprawny ADTS**; nagranie pełne |
| C3 | Wysoka latencja / niska przepustowość | „Very Bad Network" / throttle 64 kbps | brak back-pressure na nagranie; stream nadąża lub dropuje najstarsze |
| C4 | Airplane toggle | airplane 20 s w trakcie | `requireReachability`: brak prób offline; po powrocie `reconnecting`→`connected` |
| C5 | Flapping | loss/ok co 5 s przez 1 min | wiele `reconnecting`/`connected`; brak duplikatów/crasha; `finished.reconnects`>0 |
| C6 | WiFi→LTE | przełącz sieć | reconnect na nowym łączu, ciągłość |

## D. Autoryzacja
| # | Scenariusz | Oczekiwane |
|---|---|---|
| D1 | Token nieważny | serwer zamyka w `onOpen`; brak katalogu/pliku; `error`; nagranie kanoniczne OK |
| D2 | Token wygasa w trakcie | reconnect z nowym tokenem lub zamknięcie; brak crasha; plik kanoniczny OK |
| D3 | Brak `Authorization` przez nginx | sprawdź `proxy_set_header Authorization`; bez nagłówka serwer zamyka |

## E. Cykl życia aplikacji/OS
| # | Scenariusz | Oczekiwane |
|---|---|---|
| E1 | Tło | stream działa w tle (tryb `audio`); plik rośnie; reconnect w tle |
| E2 | Zablokowany ekran | nagranie + stream kontynuują (proximity start z lockiem) |
| E3 | Przerwanie rozmową | pauza/wznowienie per polityka interruption; brak ramek w pauzie; po wznowieniu `seq`/timestamp ciągłe |
| E4 | Prezentacja z wideo (audio mix) | stream nieprzerwany (`.mixWithOthers`); **tu sprawdź encodeMode (różnice iPhone)** |
| E5 | App killed / crash | nagranie kanoniczne do momentu killa (bg-task); backup do ostatnich sflushowanych ramek; brak osieroconego uchwytu na serwerze (TTL/`onClose`) |

## F. Matryca encodeMode (iOS) — rdzeń problemu iPhone
Dla każdego: **iPhone17,1 i iPad14,5**, 30 s; sprawdź śr. rozmiar ramki + `meta.json.encodeMode`.
| # | encodeMode | iPhone | iPad |
|---|---|---|---|
| F1 | `file_tail` (default) | ~180 B (audio) ✅ | ~180 B ✅ |
| F2 | `software` | ~180 B ✅ | ~180 B ✅ |
| F3 | `hardware` | **~11 B (cisza)** — potwierdzenie buga | ~180 B ✅ |

## G. Limity zasobów i współbieżność
| # | Scenariusz | Oczekiwane |
|---|---|---|
| G1 | Bardzo długie nagranie | po 4 h / 500 MB handler dropuje + log + close; nagranie kanoniczne nieprzerwane |
| G2 | Dysk serwera pełny | `fwrite` faili → log + close; **brak wpływu na chat/dispatch** i nagranie |
| G3 | Per-person cap | >3 równoczesnych połączeń usera → odrzucane; istniejące działają |
| G4 | Obciążenie współdzielonego loopa | chat/dispatch (Pusher) płynne podczas streamu; brak floodu `onError` (uwaga APP_DEBUG) |

## H. Integralność meta + korelacja
| # | Sprawdzenie |
|---|---|
| H1 | `meta.json`: `device` (model/os/app/bateria/dysk), `location` (gdy fix), `encodeMode`, `recordingId` = uuid aplikacji |
| H2 | Katalog `<person>_<uuid>` — uuid zgodny z `recordings.uuid` (po sync) |
| H3 | `dropped`/`gap` poprawnie w evencie i logu serwera |

---

## Kolejność prowadzenia
1. **F (encodeMode)** — rdzeń, oba urządzenia; ustal docelowy tryb (`file_tail`).
2. **A → B → C** (sieć) — większość „dziwnych przypadków".
3. **E** (lifecycle) — najbliżej realnego użycia w terenie.
4. Dla każdego testu zapisz: app event log, serwerowy `end`/`gap`/`onError`, rozmiar+`ffprobe`+parser
   pliku backupu, oraz **potwierdzenie kompletności nagrania kanonicznego**.

## Skrypt weryfikacyjny (parser ADTS, serwer)
```bash
F=/crm2015/storage/audio/<env>/<person>_<uuid>/audio.aac
python3 - "$F" <<'PY'
import sys
d=open(sys.argv[1],'rb').read(); n=len(d); i=fr=0; sizes=[]
while i+7<=n:
    if d[i]==0xFF and (d[i+1]&0xF6)==0xF0:
        fl=((d[i+3]&3)<<11)|(d[i+4]<<3)|((d[i+5]>>5)&7)
        if fl<7 or i+fl>n: i+=1; continue
        fr+=1; sizes.append(fl); i+=fl
    else: i+=1
avg=sum(sizes)/fr if fr else 0
print(f"frames={fr} bytes={sum(sizes)} avg_frame={avg:.1f}B clean_end={i==n}")
print("AUDIO" if avg>15 else "CISZA/EMPTY (avg<=15B)")
PY
```
