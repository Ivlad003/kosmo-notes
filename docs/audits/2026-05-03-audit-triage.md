
# KosmoNotes audit triage: що дійсно треба виправляти

**Date:** 2026-05-03
**Базовий документ:** `docs/audits/2026-05-03-architecture-code-spec-audit.md`
**Мета:** відсортувати знахідки аудиту за реальною вагою — що блокує v1.0, що є продуктовим рішенням, а що можна не чіпати зараз.

---

## TL;DR

Із усього аудиту реально перед релізом v1.0 треба зробити **п'ять речей**, з них три — механічні (≤30 хв сумарно), одна — продуктове рішення без коду, одна — позначити старий план як superseded. Решта — рефакторинг і UX-полірування, що не блокують реліз.

---

## 1. Треба виправити (конкретні баги / невідповідності спеці)

### 1.1. AC-13: timestamps у Markdown експорті

**Статус:** єдине **літерально невиконане** acceptance criterion з оригінального плану.

**Проблема.** `App/Views/Library/SessionExporter.swift:96-121` копіює `transcript.txt` як plain text у `## Transcript` секцію. `Sources/TranscriptionKit/TranscriptStore.swift:45-74` пише `transcript.txt` без timestamps. Спека (`.omc/plans/2026-05-02-kosmonotes-v1-implementation.md:68`) каже, що транскрипт у markdown має бути з `[mm:ss]` мітками.

**Варіанти фіксу:**
- **(а) Швидко:** змінити `TranscriptStore` щоб писати `transcript.txt` у форматі `[mm:ss] text\n`. Найменше коду, але псує `transcript.txt` як просто-читабельний sidecar (його зараз можна вантажити в інші інструменти як plain text).
- **(б) Чистіше:** експортер читає `transcript.jsonl` (де segments вже з часом) і форматує сам. `transcript.txt` залишається human-readable. Більше коду в експортері, але архітектурно правильніше.

**Рекомендація:** варіант (б).

### 1.2. Документаційний дрейф 12.3 vs 14.0

**Статус:** документація бреше про реальний deployment target.

**Проблема.**
- `Package.swift:6-8`, `project.yml:6-8,27,53` pin'ять `.macOS(.v14)`.
- `LSMinimumSystemVersion` = 14.0 → macOS відмовиться запускати бінарник на <14.
- Але `docs/release/v1.0-checklist.md:9-17,23-56` все ще містить рядки про `12.5 Intel` і `<12.3` поведінку.
- `KosmoNotesApp.checkMinimumOS` має модальний шлях для `<12.3` — це dead code, що `CLAUDE.md:98-99` вже сам визнає.

**Що зробити:**
1. Видалити рядки про 12.5 Intel і <12.3 з `docs/release/v1.0-checklist.md`.
2. Видалити мертву `<12.3` гілку з `KosmoNotesApp.checkMinimumOS` (залишити тільки `<14.0` warning, який теж по суті непотрібний бо LSMinimumSystemVersion не дасть запуститись, але хай буде як defensive).
3. Прибрати/переписати згадки 12.3 у design doc — позначити як історичний контекст, не активний контракт.

### 1.3. Застарілий header-коментар у `RecorderState`

**Статус:** не баг, але вводить рев'юєра в оману.

**Проблема.** `App/State/RecorderState.swift:33-38` каже "Whisper-only batch transcription" і "Mic only", а код нижче (`147-172`, `184-205`, `225-239`, `350-368`) підтримує кілька batch-провайдерів, system audio через Core Audio Tap або SCKit, і опційний screen recording.

**Що зробити.** Переписати верхній doc-comment щоб відображав реальність. ~5 хв.

---

## 2. Треба вирішити (продуктове рішення, не код)

### 2.1. Batch vs streaming транскрипція

**Статус:** найважливіше runtime відхилення від оригінальної спеки. Не баг — продуктовий вибір, що ще не зроблений формально.

**Проблема.**
- Оригінальний план (`.omc/plans/2026-05-02-kosmonotes-v1-implementation.md:237-242`) очікує live Deepgram streaming у Meeting режимі.
- `Sources/TranscriptionKit/DeepgramProvider.swift:5-71` і `ReconnectingSession.swift` — повна streaming-інфраструктура, протестована.
- АЛЕ `RecorderState.stop()` (`App/State/RecorderState.swift:342-373`) використовує **batch** провайдера. Власний коментар коду (`343-345`) каже, що streaming не виставлений на поточному capture API.

**Варіанти:**
- **(а) Декларативний:** оголосити "v1.0 = batch transcription. Streaming → v1.1." Оновити implementation plan, прибрати "live Deepgram" з AC. Жодного коду не треба чіпати.
- **(б) Імплементаційний:** дописати streaming у `RecorderState`. Це не годинна задача — треба прокинути PCM-buffer events у TranscriptionSession з CaptureSession, обробити reconnect-логіку у живому recorder UI, додати тести на race conditions при stop/cancel посеред live-стріму.

**Рекомендація:** **(а)**. Batch-шлях покритий тестами, end-to-end працює, це фактичний v1.0. Streaming — гарна v1.1 фіча коли буде ясна продуктова потреба (live transcript у попапі під час мітингу).

---

## 3. Треба прибрати (документаційний борг)

### 3.1. Імплементаційний план застарілий

**Проблема.** `.omc/plans/2026-05-02-kosmonotes-v1-implementation.md:14-23,40-45` каже, що Voice Note / per-process Core Audio Tap / S3 sharing / embeddings deferred у v1.1. Все це вже в коді (див. таблицю в аудиті §"Features implemented…"). Цей документ зараз — головне джерело плутанини: рев'юєр відкриє його і подумає, що половина продукту не існує.

**Варіанти:**
- **(а) Дешево:** додати на початку файлу банер `> SUPERSEDED 2026-05-03 — see CLAUDE.md for current state. This document reflects the original v1.0 scope cut, not what shipped.` Жодних інших змін.
- **(б) Дорого:** переписати під реальність — оновити статуси, додати нові фічі, зрівняти AC з тим, що в коді.

**Рекомендація:** **(а)**. Документ виконав свою роль (планування фази), його зміст історично цінний. Переписувати його під actuals — це створювати фейкову "ретро-планувальну" річ, що буде ще одним джерелом дрейфу.

---

## 4. Можна не чіпати зараз (рефакторинг / UX-полірування)

### 4.1. Розмір `RecorderState` і `AppSettings`

`RecorderState` ~717 рядків робить capture orchestration + transcription selection + cleanup + summary + semantic indexing + cost-cap UI. `AppSettings` — 871 рядків, всі feature-конфіги в одному `@Observable`.

**Чому не зараз:** реальний maintenance-ризик, але не блокує реліз. Код **розуміється**, тільки далі ставатиме важче. Рефакторити коли:
- буде ясно, які межі різати (recording finalization pipeline / transcript cleanup / summary generation як окремі actor'и),
- буде друга людина в репозиторії і кодові ревʼю стануть болючими,
- з'явиться третя feature, що знову потребує `RecorderState.stop()` extension.

**Що зробити для безпеки:** додати `// TODO(v1.1): split RecorderState — see audit 2026-05-03 §C-1` коментар у топі обох файлів, щоб не загубилося.

### 4.2. Silent partial failures у Library / RecorderState

`LibraryState.refresh()` (`119-123`) ловить і print'ить, `LibraryState.semanticHits()` (`201-223`) повертає `[]` на будь-який збій, `RecorderState.indexSemantic` (`640-663`) тихо скіпає.

**Чому не зараз:** UX слабкість, але не баг. Реальний фікс — це окрема фіча: додати `enhancementStatus: ok | partial(reason) | failed(reason)` у session і показувати badge у Library. Це не "аудит-fix", це продуктовий enhancement.

### 4.3. App shell діаграма (MenuBarExtra vs NSStatusItem)

Design doc (`92-100`) показує `MenuBarExtra`, репо використовує `NSStatusItem` + `NSMenu`. Це свідомий вибір під LSUIElement reliability, не баг.

**Що зробити:** один-абзацний апдейт у design doc у §App Shell — "Implementation note: shipped with NSStatusItem, not MenuBarExtra. Reason: LSUIElement reliability under wake-from-sleep." Жодного коду не чіпати.

### 4.4. Release checklist порожній

`docs/release/v1.0-checklist.md` — manual smoke checklist, ще не пройдений на залізі.

**Це не код-fix.** Це окрема активність "сісти з MacBook'ом і пройти scenario'и". Відкладемо до моменту, коли пункти 1-3 з цього документа будуть зроблені.

---

## Порядок виконання

1. **(30 хв код-фіксів)** AC-13 timestamps + видалити `<12.3` dead code + переписати RecorderState header.
2. **(5 хв доку)** Додати banner у старий implementation plan.
3. **(5 хв доку)** Update design doc § app shell з нотою про NSStatusItem.
4. **(15 хв доку)** Видалити 12.5 Intel / <12.3 рядки з release checklist; перерозподілити сценарії під 14.0 / 14.4 / 15.x матрицю.
5. **(розмова)** Узгодити з власником продукту: v1.0 = batch transcription, streaming → v1.1. Записати рішення у §Decision Log design doc'у.
6. **(пройти manual smoke)** Заповнити release checklist на реальному залізі.
7. **(пост-реліз)** TODO-коментарі у `RecorderState` + `AppSettings`, плюс enhancement-status badge у Library — як v1.1 work.

---

## Що НЕ робити

- Не переписувати `RecorderState` / `AppSettings` "за компанію" — це окремий PR і окрема дискусія.
- Не міняти `transcript.txt` формат "поки тут — додам timestamps" — це поламає інші читачі sidecar'а. Експортер форматує сам.
- Не "оновлювати" старий implementation plan під actuals. Banner і forget.
- Не закривати `<14.0` warning в `KosmoNotesApp` поки не перевірено, що LSMinimumSystemVersion гарантовано блокує запуск (теоретично — так, але defensive warning ціна нуль).
