# Аналіз продукту, пакетування та монетизації KosmoNotes

**Дата:** 2026-05-03  
**Аудиторія:** продуктова команда, фаундер, release planning  
**Обсяг:** описати поточний продукт, зіставити реалізований функціонал із ринковою цінністю, запропонувати поділ Lite/Pro, порівняти одноразову покупку з підпискою та обґрунтувати рекомендацію через аналіз конкурентів і болів користувачів.

## Підсумковий висновок

KosmoNotes варто запускати як **гібридний desktop-продукт**: продавати сам застосунок як **одноразові ліцензії Lite і Pro**, а зверху додати **опційний recurring cloud plan або usage credits** для bundled transcription, managed AI та майбутніх hosted features на кшталт sharing чи sync.

Ця модель підходить продукту краще, ніж чиста підписка, з трьох причин.

1. Найсильніша цінність поточного кодбейзу — це **сам desktop-застосунок**: bot-free capture, dictation, voice notes, local library, playback, export і швидкість робочого процесу.
2. Постійні витрати сидять у **cloud transcription і AI usage**, а не в menu-bar shell чи local storage model.
3. Ринок конкурентів уже навчив користувачів двом речам: вони приймають підписки, коли продукт дає зрозумілу hosted, recurring value, і дратуються, коли продукт відчувається як desktop utility з тонкою cloud-обгорткою.

Для цільового сегмента тут — **solo professionals і consultants** — найчистіша комерційна історія така: **купи застосунок один раз, зберігай свої файли локально, підключай власні ключі за бажанням і плати щомісяця лише якщо хочеш hosted convenience або included usage.**

## Що це за продукт насправді

KosmoNotes — це не просто “AI meeting note taker”. У поточному вигляді це **macOS menu-bar capture and recall workspace** для голосової роботи.

Продукт поєднує три завдання в одному застосунку:

1. **Захоплення роботи** — запис зустрічей, короткі диктовки та структуровані voice notes.
2. **Перетворення мовлення на корисний результат** — transcript, summary, actions, formatted notes і chat по попередніх сесіях.
3. **Пошук і повторне використання** — local library, search, playback, waveform thumbnails, export і sharing.

Це важливо, бо змінює логіку пакетування. Такі продукти, як Otter і Fathom, легко читаються як meeting bots із summaries. KosmoNotes ближчий до **desktop productivity system for spoken input**. Його реальні конкуренти лежать одразу в трьох категоріях:

- AI meeting assistants
- desktop dictation tools
- local-first knowledge capture tools

Саме так продукт і варто позиціонувати. Якщо подати його лише як meeting note taker, він виглядатиме запізнілим на ринок. Якщо подати його як **private, bot-free, desktop-native voice workflow tool**, кут позиціонування стає значно гострішим.

## Що реалізовано зараз

Кодова база вже підтримує ширший продуктовий контур, ніж це видно з README та старого implementation plan.

| Напрям | Статус реалізації | Комерційна цінність |
|---|---|---|
| Meeting Mode | Реалізовано | Базовий capture для консультантських і клієнтських дзвінків |
| Dictation Mode | Реалізовано | Щоденний productivity wedge у будь-якому застосунку |
| Voice Note Mode | Реалізовано | Середні за довжиною записи для особистого workflow, підготовки, журналу та task dump |
| Mic + system audio capture | Реалізовано | Краща точність meeting capture, ніж у mic-only tools |
| Per-process audio tap | Реалізовано | Premium control для power users на macOS 14.4+ |
| Optional screen recording | Реалізовано | Сильна історія для recall і review у demo, research і support workflows |
| Transcript + summary pipeline | Реалізовано | Базова цінність “зеконом мені час після зустрічі” |
| Multi-provider AI stack | Реалізовано | Гнучкість BYO-key і привабливість для power users |
| Local library with playback | Реалізовано | Робить продукт корисним і після capture, а не лише під час нього |
| FTS search | Реалізовано | Базова retrieval-функція |
| Optional semantic search | Реалізовано | Сильна premium retrieval feature, хороший кандидат для Pro |
| Chat over sessions | Реалізовано | Перетворює записи на queryable knowledge, а не просто архів |
| Markdown export | Реалізовано | Сильна історія про ownership і portability |
| S3-compatible sharing | Реалізовано | Корисно для consultant delivery workflows |
| Global hotkeys | Реалізовано | Робить продукт швидким і рідним для macOS |

Найсильніший комерційний аргумент тут — не одна конкретна функція, а саме **комбінація**:

- native menu-bar UX
- відсутність meeting bot
- кілька режимів capture
- local library та export
- optional advanced recall features

Такий набір уже виглядає переконливо для людей, чий день складається з дзвінків, follow-up задач і коротких голосових нотаток між зустрічами.

## Найкращий цільовий клієнт

Найкращий перший клієнт — як і раніше **solo professionals / consultants**. Цей сегмент підходить продукту краще, ніж команди або масовий споживчий ринок.

Ця група відчуває біль одразу в чотирьох місцях:

1. Вони проводять велику частину дня в зустрічах, інтерв’ю, discovery calls, coaching calls або project check-ins.
2. Їм потрібен швидкий follow-up: notes, summaries, actions або CRM updates.
3. Для них важливо, як вони виглядають на дзвінках, і вони часто не люблять visible bots.
4. Вони готові платити за personal productivity edge, але не хочуть, щоб їх силоміць заганяли в team-style SaaS workspace.

Найкращі підсегменти:

- consultants і agency leads
- recruiters та interviewers
- coaches і advisors
- freelance developers і PMs
- founders, які проводять багато customer calls

Цим користувачам не потрібен “meeting intelligence”. Їм потрібно **менше адміністративної роботи після розмови**.

## Чого хочуть користувачі і де конкуренти їх дратують

Веб-дослідження показує сталий патерн: користувачі купують не лише quality of notes. Вони купують **довіру, швидкість і соціальний комфорт**.

### 1. Користувачам не подобаються видимі боти на дзвінках

Це один із найчіткіших конкурентних шансів. Позиціонування Granola сильно спирається на те, що продукт **не** заходить у дзвінок як видимий учасник, а community summaries про Granola знову і знову називають це ключовою перевагою. У добірці Aitooldiscovery ця теза звучить прямо: visible bot — це dealbreaker для багатьох професіоналів у client-facing calls.[^granola-reddit]

Otter, навпаки, досі тягне за собою багаж у стилі “assistant joined the meeting”. У тому ж порівнянні Granola виглядає слабшим за Otter у speaker attribution і collaboration, але сильнішим у комфорті під час дзвінка саме тому, що бот не видимий.[^granola-reddit]

**Висновок для KosmoNotes:** “bot-free” треба тримати майже на самому верху value proposition. Для consultant audience це не приємний бонус, а базова вимога довіри.

### 2. Користувачі хочуть справжній trial, а не тісний teaser

Granola хвалять за note quality і meeting flow, але одна критика повторюється постійно: free tier занадто маленький. У community summary про Granola прямо згадуються **25 lifetime meetings** як головний бар’єр для формування звички.[^granola-reddit]

Fathom виграє на протилежному полі. Його найсильніший ринковий актив — не prestige, а відчуття, що free plan досить щедрий, щоб продукт можна було спокійно прийняти у роботу без тривоги. Незалежні огляди описують free tier Fathom як один із найсильніших у категорії.[^fathom-review]

**Висновок для KosmoNotes:** якщо існує Lite, він має бути справді придатним до щоденного використання. Не можна робити Lite кастрованим демо. Користувачу потрібно достатньо простору, щоб повірити у workflow.

### 3. Користувачам потрібні transcript-и, які можна перевірити

Користувачам потрібні не лише “AI notes”. Їм потрібен спосіб підтвердити, що саме було сказано, коли transcript справді важливий.

Огляд Granola підсвічує тут реальну слабкість: **немає audio або video playback**, а отже складніше перевірити спірні місця, іноземну мову чи зіпсовані рядки.[^granola-review] Той самий огляд також згадує слабке speaker attribution у частині сценаріїв і заплутаний early onboarding.[^granola-review]

Otter має протилежну проблему. У нього зріліший transcript workflow, але зовнішні тести все одно фіксують **нестабільну transcription accuracy**, **помилки speaker identification** і слабший output, ніж у частини конкурентів.[^otter-review] Коментарі в ProductManagement thread ще жорсткіші: один користувач пише, що продукт “never captured any transcripts”, а автор треду скаржиться на shrinkflation — менший allowance за ті самі гроші.[^otter-reddit]

**Висновок для KosmoNotes:** playback, transcript seeking і optional screen capture — це не другорядні фішки. Вони відповідають на реальну потребу ринку: “покажи, що насправді сталося”. Це сильна Pro-level value.

### 4. Користувачі ненавидять неясні ліміти і shrinkflation

Це особливо добре видно на прикладі Otter. У ProductManagement thread автор прямо скаржиться, що пропозиція Otter пройшла через “shrinkflation”: менше monthly allowance за ті самі гроші.[^otter-reddit]

Ця тема важлива не лише для Otter. Користувачі приймають usage limits, коли межа зрозуміла і справедлива. Вони дратуються, коли pricing виглядає як рухома мішень.

**Висновок для KosmoNotes:** якщо буде recurring pricing, воно має бути простим. “Includes X transcription credits, then pay as you go” — захищена логіка. “Mystery caps” — погана логіка.

### 5. Користувачі люблять інструменти, що зменшують friction набору тексту весь день, а не лише на зустрічах

Дослідження Wispr Flow показує інше, але дуже важливе бажання: частина користувачів цінує voice tools тому, що ті прибирають keyboard friction упродовж усього дня. У Reddit thread, який було піднято тут, користувачі з ADHD описують Wispr Flow як productivity breakthrough, бо він перетворює рутинне введення нотаток на мовлення замість набору тексту.[^wispr-reddit]

Це важливо для KosmoNotes, бо Dictation Mode — не побічна фіча. Він може бути wedge-функцією, яка заводить користувача в застосунок навіть у ті дні, коли зустрічей небагато.

**Висновок для KosmoNotes:** Dictation Mode треба тримати в ядрі історії про продукт. Він розширює використання за межі формальних meeting scenarios і робить застосунок легшим для щоденного виправдання ціни.

### 6. Користувачі люблять прості інструменти, але не порожні

Fathom отримує хороші оцінки за простий user experience і сильну безкоштовну базу, але огляди все одно відзначають обмеження: немає mobile app, немає file transcription у межах цього review context і менша глибина advanced capabilities порівняно з важчими конкурентами.[^fathom-review]

Це говорить про важливу річ. Простота — добре. Порожнеча — ні. Користувачі хочуть продукт, який виглядає сфокусованим, але має реальну глибину там, де вона справді важлива.

**Висновок для KosmoNotes:** Lite має бути простим. Pro має бути повним. Жоден із них не має виглядати фальшивим.

## Конкурентний зріз

| Продукт | Що подобається користувачам | Що не подобається користувачам | Що це означає для KosmoNotes |
|---|---|---|---|
| Granola | Преміальна якість нотаток, bot-free відчуття, чистий UX, сильний post-meeting workflow | Малий free tier, немає playback, слабке speaker attribution у частині сценаріїв, рання UX-плутанина | Обіграти його на verification, playback, export і ширині щоденного workflow |
| Fathom | Сильний free plan, прості summaries, придатний core experience | Менша глибина advanced features, немає mobile app в огляді, слабше premium positioning | Не намагатися виграти за рахунок “free forever”; вигравати через power-user control і local desktop value |
| Otter | Відомий бренд, collaboration, workspace features, speaker labeling | Visible bot, нестабільний transcript, обмежені мови, frustration через pricing | Не йти в bot-first positioning і не запускати team-workspace-first packaging на старті |
| Wispr Flow | Швидка dictation, all-app productivity, сильна емоційна цінність для heavy keyboard users | Втома від підписки, пошук one-time desktop alternatives | Використати Dictation Mode як wedge, але пов’язати його з capture та recall, щоб продукт був більшим за просто dictation |

## Варіанти пакетування

Є три розумні комерційні форми.

### Варіант A: лише одноразові Lite / Pro

**Форма**

- Lite: дешевший perpetual desktop app
- Pro: дорожчий perpetual desktop app
- без підписки

**Чому це працює**

- Добре відповідає Mac desktop market
- Легко пояснити
- Добре стикується з local-first і BYO-key positioning
- Прибирає SaaS fatigue

**Чому це ламається**

- Важко фінансувати bundled transcription usage в довгу
- Залишає гроші на столі для high-usage customers
- Ускладнює чисте ціноутворення для майбутніх hosted sync/sharing/team features

**Вердикт**

Добрий як філософія. Слабкий як повна бізнес-модель, якщо компанія хоче включати transcription minutes або hosted services.

### Варіант B: лише підписка

**Форма**

- monthly або annual tiers
- desktop app у комплекті з usage і cloud features

**Чому це працює**

- Прогнозований recurring revenue
- Легко закладати model costs
- Це звична форма для AI SaaS

**Чому це ламається**

- Поточний продукт відчувається передусім як desktop tool, а не hosted workspace
- Solo professionals втомилися платити щомісяця за кожен utility app
- Важко обґрунтувати проти конкурентів, якщо hosted layer не дає виразно більшої цінності
- Слабо стикується з BYO-key і local ownership messaging

**Вердикт**

Це найгірший fit для поточного продукту. Така модель може запрацювати пізніше, якщо компанія побудує сильний hosted layer. На старті це не найкращий варіант.

### Варіант C: гібрид — desktop license плюс optional recurring cloud

**Форма**

- Lite: одноразова desktop license
- Pro: одноразова desktop license
- optional Cloud plan або credits для bundled transcription, managed AI та майбутніх hosted services

**Чому це працює**

- Розділяє довготривалу app value і змінну cloud cost
- Відповідає реальній архітектурі: local files і desktop UX, але cloud transcription
- Дає користувачам вибір: BYO keys або платити за convenience
- Дає апсел без примусу всіх у SaaS

**Чому це ламається**

- Трохи складніше пояснюється в маркетингу
- Вимагає продуктової дисципліни, щоб cloud tier додавав реальну цінність, а не просто шум у білінгу

**Вердикт**

Це найкращий fit для KosmoNotes.

## Рекомендований поділ Lite / Pro

Поділ має спиратися на одне правило: **Lite мусить доставляти core promise. Pro має поглиблювати workflow, а не відкривати базову функціональну гідність.**

### Lite

Lite має бути тією версією, якою solo consultant може користуватися щодня без відчуття, що його карають.

**Що включити в Lite**

- Meeting Mode
- Dictation Mode
- Voice Note Mode
- mic capture плюс стандартний system-audio capture path
- transcript + summary
- local library
- playback і transcript seek
- basic search
- Markdown export
- global hotkeys
- BYO API keys

**Чому**

Це мінімальна цілісна історія: capture, process, retrieve, export.

Якщо в Lite немає local library, export або корисних capture modes, він перетворюється на teaser замість продукту. Це вдарить по довірі й конверсії.

### Pro

Pro має цілити в людей, які живуть у цьому застосунку і хочуть щільніший professional workflow.

**Що включити в Pro**

- per-process Core Audio Tap
- optional screen recording
- semantic search
- chat over prior sessions
- S3 sharing і delivery workflows
- advanced note templates і workflow settings
- premium provider-routing controls
- майбутні workflow automation features

**Чому**

Це power-user multipliers. Вони дуже важливі для heavy users, але не потрібні, щоб зрозуміти продукт або почати ним користуватись.

### Optional Cloud plan або credits

Recurring layer має покривати саме ті речі, які створюють реальні постійні витрати або service burden:

- bundled transcription minutes
- bundled LLM usage
- managed provider credentials для нетехнічних користувачів
- майбутні hosted sync, backup або share pages
- майбутні team workspace features

Так pricing logic залишається чесною: **desktop features купуються один раз; hosted consumption оплачується в часі.**

## Рекомендований напрямок цін

Точне число треба буде ще валідувати, але структура вже зрозуміла.

### Орієнтовні launch-діапазони

| Пропозиція | Орієнтовний діапазон | Примітка |
|---|---|---|
| Lite | **$49-$79 one-time** | Достатньо низько для спроби, достатньо високо для сигналу про реальну цінність |
| Pro | **$149-$249 one-time** | Преміальна desktop productivity ціна, але психологічно простіша за постійний SaaS |
| Cloud add-on | **$12-$24/month** або usage credits | Має включати або чіткий monthly usage, або прозору prepaid credit logic |

Логіка ціни має збігатися з логікою цінності:

- Lite = “Я хочу сам застосунок”
- Pro = “Я справді спираюся на цей workflow”
- Cloud = “Я хочу bundled usage і convenience”

## Одноразова покупка чи підписка

Правильна відповідь не в тому, щоб “обрати щось одне”. Правильна відповідь — оцінювати кожну частину цінності тим способом, який відповідає її природі.

| Частина продукту | Найкраща форма ціни | Чому |
|---|---|---|
| Desktop shell, capture UX, local library, export | One-time | Довготривала software value, низька marginal cost |
| Screen recall, semantic retrieval, power-user controls | One-time Pro | Вища продуктова цінність, але все ще переважно локальна |
| Transcription і LLM usage | Recurring або credits | Змінна собівартість, usage-based burden |
| Hosted sync/sharing/team features | Recurring | Постійна service value |

Саме тому hybrid model сильніша за ідеологію. Вона узгоджує ціну, витрати та очікування користувача.

## Рекомендоване позиціонування

KosmoNotes не варто виводити на ринок із фронтальним меседжем “AI notes”. Цей ринок уже переповнений і дедалі більше commoditized.

Краще вести комунікацію через гостріше речення:

> **Bot-free Mac voice workspace для consultants і heavy meeting users. Записуйте дзвінки, диктування та voice notes; зберігайте library локально; платіть щомісяця лише якщо хочете bundled cloud usage.**

Таке формулювання робить чотири корисні речі.

1. Відділяє продукт від meeting bots.
2. Пояснює, чому Dictation Mode органічно належить цьому продукту.
3. Підтримує one-time desktop pricing.
4. Залишає місце для optional cloud upsell, не роблячи базовий продукт неповним.

## Стратегічні застереження

### 1. Не можна перебільшувати privacy

Застосунок local-first у зберіганні, export і retrieval, але transcription досі cloud-based. Це реальна сильна сторона з реальною межею. Повідомлення має бути чесним: **local library і bot-free capture, але не повністю on-device transcription privacy.**

### 2. Не можна занадто рано форсувати team-SaaS packaging

Поточний продукт найсильніший як personal professional tool. Якщо починати pricing із workspace seats, admin controls і team tax, це послабить привабливість для найкращого першого клієнта.

### 3. Не можна калічити Lite

Якщо Lite виглядатиме непридатним до реальної роботи, користувачі підуть порівнювати його з generous free offering у Fathom або з one-time Mac alternatives. Lite має стояти на власних ногах.

### 4. Не можна ховати Dictation Mode

Dictation розширює щоденне використання продукту за межі meetings. Це одна з найкращих причин, чому користувач триматиме застосунок відкритим щодня.

## Фінальна рекомендація

Найкращий комерційний план такий:

1. **Запустити Lite і Pro як one-time desktop licenses.**
2. **Залишити core product local-first і BYO-key friendly.**
3. **Додати optional Cloud plan або credits лише для bundled transcription, AI usage і майбутніх hosted services.**
4. **Позиціонувати продукт як bot-free desktop voice workspace, а не як ще одного AI meeting bot.**

Якщо це виконати добре, у KosmoNotes буде кращий шанс, ніж у plain subscription launch. Така модель відповідає кодовій базі, відповідає цільовому користувачу і прямо відповідає на найвидиміші роздратування ринку.

## Джерела

[^granola-review]: tl;dv, “Granola AI Review: My Honest Thoughts After 20+ Meetings (2026)” — https://tldv.io/blog/granola-review/
[^granola-reddit]: AI Tool Discovery, “Granola AI Reddit Review 2026: What the Community Actually Thinks” — https://www.aitooldiscovery.com/guides/granola-ai-reddit
[^fathom-review]: The Business Dive, “My Honest Fathom Review After Using It For +3 Months (2026)” — https://thebusinessdive.com/fathom-review
[^otter-review]: The Business Dive, “Otter AI Review | My Brutal Honest Take (2026)” — https://thebusinessdive.com/otter-ai-review
[^otter-reddit]: Reddit, “Is Otter.AI worth it for meeting minutes?” — https://www.reddit.com/r/ProductManagement/comments/1866ags/is_otterai_worth_it_for_meeting_minutes/
[^wispr-reddit]: Reddit, “Just tried Wispr Flow, and it’s amazing” — https://www.reddit.com/r/ProductivityApps/comments/1ltsj2q/just_tried_wispr_flow_and_its_amazing/
