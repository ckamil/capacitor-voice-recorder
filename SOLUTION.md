# SOLUTION.md

# Root cause: "Session activation failed" wyłącznie na iPadach

## Dekodowanie NSOSStatusErrorDomain 560557684

```
560557684 (decimal)
= 0x21696E74 (hex)
= '!int' (FourCC / ASCII)
= AVAudioSession.ErrorCode.cannotInterruptOthers
```

**Definicja Apple**: *"The system can't activate your audio session because another audio session has higher priority and doesn't allow mixing."*

To jest standardowy kod błędu `AVAudioSession`. iOS zwraca go gdy:
1. Inna sesja audio jest aktywna i nie zezwala na przerwanie (`setActive(true)` nie może jej zdetronizować)
2. Twoja sesja nie może współistnieć z tamtą sesją (mixing jest niemożliwy)

---

## Mechanizm błędu (krok po kroku co się dzieje w iOS)

### Stan wyjściowy w produkcji (v1.5 build 16, commit `c972dcd`)

Kod produkcyjny wykonuje 3-próbową strategię aktywacji:

```
Próba 1: setCategory(.playAndRecord)          → setActive(true) → FAIL 560557684
Próba 2: reset do .ambient → 0.8s delay →
          setCategory(.playAndRecord)          → setActive(true) → FAIL 560557684
Próba 3: reset do .ambient → 0.8s delay →
          setCategory(.playAndRecord, .mixWithOthers) → setActive(true) → FAIL 560557684
→ Zwraca: "Session activation failed after 3 attempts"
```

### Dlaczego wszystkie 3 próby zawodzą — paradoks `.mixWithOthers`

**Próby 1-2 (bez `.mixWithOthers`)**:
- `setActive(true)` prosi iOS: *"Aktywuj moją sesję, nawet jeśli musisz przerwać innym"*
- Na **iPhone** to działa — jest tylko jedna aplikacja na pierwszym planie, iOS przerywa sesje aplikacji w tle
- Na **iPad** z multitaskingiem — inna aplikacja też jest na pierwszym planie, jej sesja jest chroniona → iOS odmawia → **560557684**

**Próba 3 (z `.mixWithOthers`)**:
- `setActive(true)` z `.mixWithOthers` prosi iOS: *"Aktywuj moją sesję, ale NIE przerywaj innym — chcę współistnieć"*
- Inna sesja nie zezwala na mixing (nie ma flagi `.mixWithOthers`) → iOS nie może spełnić żądania współistnienia → **560557684**

**To jest pułapka bez wyjścia**:
- BEZ `.mixWithOthers` → iOS nie może przerwać chronionej sesji foreground na iPadzie
- Z `.mixWithOthers` → iOS nie może miksować z sesją, która nie obsługuje mixingu
- Wynik: ten sam błąd 560557684 w obu przypadkach

### Sekwencja zdarzeń w iOS (diagram)

```
[Inna aplikacja w Split View / Stage Manager]
    └─ AVAudioSession aktywna
    └─ Kategoria: .playback / .playAndRecord (bez .mixWithOthers)
    └─ Status: FOREGROUND (chroniona przez iPadOS)

[CRM App - próba nagrywania]
    └─ setCategory(.playAndRecord)
    └─ setActive(true)
        └─ iOS sprawdza:
            ├─ Czy inna sesja jest aktywna? → TAK
            ├─ Czy inna sesja pozwala na przerwanie? → NIE (foreground na iPad)
            ├─ Czy mogę miksować? → NIE (inna sesja nie ma .mixWithOthers)
            └─ WYNIK: NSOSStatusErrorDomain 560557684 (cannotInterruptOthers)
```

---

## Dlaczego tylko iPad

### iPhone vs iPad — fundamentalna różnica w zarządzaniu sesjami audio

| Aspekt | iPhone | iPad |
|--------|--------|------|
| Aplikacje na pierwszym planie | Zawsze 1 | 2+ (Split View, Slide Over, Stage Manager) |
| Sesja audio innej aplikacji | W tle → można przerwać | Na pierwszym planie → chroniona |
| `setActive(true)` bez mixing | Przerywa sesje w tle → SUKCES | Nie może przerwać foreground → **FAIL** |
| `setActive(true)` z mixing | Współistnieje z sesjami w tle → SUKCES | Inna sesja nie wspiera mixing → **FAIL** |

### iPadOS — polityka audio dla multitaskingu

iPadOS traktuje wszystkie aplikacje w widocznych oknach jako "foreground":
- **Split View**: 2 aplikacje obok siebie — obie foreground
- **Slide Over**: aplikacja w pływającym oknie — foreground
- **Stage Manager** (M-series): wiele okien na pulpicie — wszystkie foreground

Sesja audio aplikacji foreground ma **wyższy priorytet** niż sesja aplikacji, która próbuje ją przerwać. iOS chroni użytkownika przed niechcianym przerwaniem audio w widocznej aplikacji.

Na **iPhone** ten problem nie istnieje, bo w momencie otwarcia CRM app, poprzednia aplikacja przechodzi do tła i jej sesja audio staje się "przerywalna".

---

## Dlaczego nie reprodukuje się lokalnie

### Brakujące warunki środowiskowe przy testach deweloperskich

1. **Brak konkurujących sesji audio**: Deweloper uruchamia CRM jako jedyną aplikację, bez Split View / Stage Manager
2. **Brak "ciepłej" sesji WebView**: W produkcji użytkownicy przeglądają prezentacje Keynote z audio/wideo w WebView tuż przed nagrywaniem — WebKit utrzymuje własną sesję audio
3. **Czyste środowisko**: Po restarcie iPad / reinstalacji app nie ma osieroconych sesji audio
4. **Brak typowego flow użytkownika**: Produkcyjni użytkownicy mają specyficzny wzorzec pracy:
   - Otwierają prezentację w WebView (audio/wideo)
   - Przechodzą do klienta
   - Próbują nagrywać rozmowę
   - WebKit's sesja audio wciąż aktywna w tle procesu

### Warunki konieczne do wystąpienia błędu

Wszystkie muszą być spełnione jednocześnie:
1. **Urządzenie**: iPad (dowolny model)
2. **Inna aktywna sesja audio**: Z innej aplikacji w multitaskingu LUB z WKWebView w tej samej aplikacji
3. **Ta sesja nie ma `.mixWithOthers`**: Większość aplikacji audio nie ustawia tej flagi
4. **iPad multitasking aktywny**: Inna aplikacja widoczna (Split View / Slide Over / Stage Manager)

---

## Warunki środowiskowe wywołujące błąd

### Źródło #1: WKWebView w tej samej aplikacji (najbardziej prawdopodobne)

Aplikacja CRM używa WebView do prezentacji Keynote z audio/wideo (`AMA-306 - Keynote presentation in app`). WKWebView zarządza własną sesją `AVAudioSession` wewnątrz procesu:

- Użytkownik ogląda prezentację z dźwiękiem → WebKit aktywuje sesję `.playback`
- Zamyka prezentację, otwiera formularz nagrywania
- WebKit's sesja audio **nie jest dezaktywowana automatycznie** — pozostaje aktywna
- CRM próbuje `setActive(true)` dla `.playAndRecord` → konflikt z sesją WebKit → 560557684

To wyjaśnia dlaczego błąd występuje bez widocznego Split View — konflikt jest **wewnątrz procesu aplikacji**.

### Źródło #2: Inna aplikacja w multitaskingu

Typowe aplikacje produkcyjne na iPadach handlowców:
- **Microsoft Teams / Zoom**: Kategoria `.playAndRecord` — aktywna podczas lub po rozmowie
- **Safari z YouTube / mediami**: Kategoria `.playback`
- **Muzyka / Podcasts**: Kategoria `.playback`
- **Mail z podglądem wideo**: Kategoria `.playback`

### Źródło #3: iPadOS 26 + Stage Manager na M-series

iPad Air M3 generuje 28/90 (31%) wszystkich błędów. Przyczyny:
- **Stage Manager domyślnie włączony** na chipach M-series → więcej okien = więcej sesji audio
- **iPadOS 26**: Nowa wersja systemu z potencjalnie surowszymi regułami izolacji audio między oknami Stage Manager
- **Więcej RAM = więcej otwartych aplikacji**: M3 z 8GB RAM utrzymuje więcej aplikacji w pamięci z aktywnymi sesjami audio

### Dlaczego `isOtherAudioPlaying` nie jest wiarygodnym wskaźnikiem

Logi z produkcji mogą nie pokazywać `isOtherAudioPlaying: true`, mimo że inna sesja blokuje. Dzieje się tak ponieważ:
- `isOtherAudioPlaying` zwraca `true` tylko gdy inna aplikacja **aktywnie odtwarza dźwięk**
- Sesja audio może być **aktywna ale wstrzymana** (np. Teams po zakończeniu rozmowy, ale sesja niezamknięta)
- Taka "zombie" sesja wciąż blokuje `setActive(true)`, ale `isOtherAudioPlaying` zwraca `false`

---

# Jak odtworzyć błąd

## Scenariusz 1: WKWebView wewnętrzny konflikt (najbardziej prawdopodobny)

**Dlaczego to jest #1**: Aplikacja CRM sama tworzy konkurującą sesję audio przez WebView z prezentacjami. Nie wymaga drugiej aplikacji.

**Kroki**:
1. Otwórz CRM na iPadzie
2. Przejdź do sekcji z prezentacjami Keynote / WebView
3. Odtwórz prezentację zawierającą **audio lub wideo z dźwiękiem** — poczekaj aż dźwięk zacznie grać
4. **Zatrzymaj prezentację** (pauza lub zamknij) — ale **nie zamykaj aplikacji**
5. Natychmiast (w ciągu 5-10 sekund) przejdź do formularza nagrywania
6. Kliknij "Rozpocznij nagrywanie"

**Oczekiwany wynik**: `Session activation failed` z kodem 560557684

**Mechanizm**: WebKit's wewnętrzna sesja `.playback` pozostaje aktywna po zatrzymaniu prezentacji. Nie ma API do jawnego zamknięcia sesji WebKit z poziomu natywnego kodu.

**Uwaga**: Jeśli nie masz prezentacji z audio, otwórz w WKWebView dowolną stronę z auto-play wideo (np. embed YouTube).

## Scenariusz 2: Split View z aplikacją audio

**Dlaczego to jest #2**: Typowy scenariusz produkcyjny — handlowiec ma Teams/Zoom obok CRM.

**Kroki**:
1. Otwórz **Microsoft Teams** (lub Zoom, lub Spotify, lub YouTube w Safari)
2. **Rozpocznij odtwarzanie audio** — rozmowa w Teams, muzyka w Spotify, wideo w YouTube
3. **Wstrzymaj audio** (pauza) — ale **nie zamykaj aplikacji**
4. Otwórz CRM w **Split View** obok Teams/Spotify
5. W CRM przejdź do formularza nagrywania
6. Kliknij "Rozpocznij nagrywanie"

**Oczekiwany wynik**: `Session activation failed` z kodem 560557684

**Mechanizm**: Teams/Zoom utrzymuje sesję `.playAndRecord` aktywną nawet po wstrzymaniu rozmowy. Spotify/YouTube utrzymuje sesję `.playback`. Obie blokują nową sesję `.playAndRecord`.

**Wariacja (Stage Manager)**: Na iPad z M-series, użyj Stage Manager zamiast Split View — otwórz Teams i CRM w osobnych oknach Stage Manager.

## Scenariusz 3: "Zombie" sesja po przerwaniu systemowym

**Dlaczego to jest #3**: Wyjaśnia sporadyczne przypadki bez oczywistego źródła konfliktu.

**Kroki**:
1. Otwórz CRM na iPadzie — **nie w Split View**
2. Otwórz **FaceTime** lub **Telefon** i zainicjuj rozmowę (lub poproś kogoś o telefon)
3. **Odbierz rozmowę** — system aktywuje sesję `.playAndRecord` dla rozmowy
4. **Zakończ rozmowę** — wróć do CRM
5. Natychmiast (w ciągu 5-15 sekund) kliknij "Rozpocznij nagrywanie"

**Oczekiwany wynik**: `Session activation failed` z kodem 560557684

**Mechanizm**: Po zakończeniu rozmowy telefonicznej, system iOS nie zawsze natychmiast dezaktywuje sesję audio telefonii. Przez kilka sekund "zombie" sesja systemu blokuje aktywację nowej sesji `.playAndRecord`. Ten window jest krótki (5-15s), co wyjaśnia sporadyczność.

**Wariacja**: Zamiast rozmowy — aktywuj i dezaktywuj Siri (przytrzymaj przycisk Home/Power). Siri używa `.playAndRecord` i może zostawiać "zombie" sesję.

---

# Podsumowanie

| Pytanie | Odpowiedź |
|---------|-----------|
| Co oznacza 560557684? | `AVAudioSession.ErrorCode.cannotInterruptOthers` — iOS nie może aktywować sesji bo inna chroniona sesja jest aktywna |
| Dlaczego `.mixWithOthers` nie pomaga? | Paradoks: bez flagi iOS nie może przerwać chronionej sesji; z flagą iOS nie może miksować z sesją która nie wspiera mixingu |
| Dlaczego `currentInputs: []`? | Sesja nie została aktywowana → brak ustalonej trasy audio → brak wejść w `currentRoute` |
| Dlaczego tylko iPad? | Multitasking (Split View / Stage Manager) utrzymuje wiele aplikacji na foreground z chronionymi sesjami audio. iPhone = 1 foreground app |
| Co zmieniło się w iPadOS 26? | Stage Manager domyślnie na M-series + prawdopodobnie surowsza izolacja audio między oknami |
| Dlaczego nie reprodukuje się lokalnie? | Brak konkurujących sesji audio. Kluczowy trigger: WebView z audio/wideo lub inna aplikacja w multitaskingu |
