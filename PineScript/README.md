# SMC Multi-Timeframe Intelligence — مؤشر TradingView (Pine Script v6)

ملف المؤشر: [`SMC_Multi_Timeframe_Intelligence.pine`](SMC_Multi_Timeframe_Intelligence.pine)

مؤشر واحد يجمع Market Structure و Smart Money Concepts و Liquidity و FVG و
Order Blocks و Divergence والتحليل متعدد الفريمات، مبني من **11 محرك مستقل**
يمكن تشغيل/إيقاف كل واحد منها من الإعدادات.

> **تنبيه:** هذا المؤشر أداة تحليل وليس توصية مالية. لا يُخرج إشارات
> «BUY / SELL» — بل يعرض **Bullish Confluence / Bearish Confluence** مع عدد
> العوامل المتوافقة فقط. القرار يبقى قرار المتداول.

---

## A. شرح المحركات (Engines)

| # | المحرك | آلية العمل |
|---|--------|-------------|
| 1 | **Swing Engine** | `ta.pivothigh/ta.pivotlow` بطول Pivot مزدوج (Minor + Major). كل Swing مؤكد يُخزَّن في مصفوفات محدودة الحجم (سعر + رقم الشمعة) وتُغذّي بقية المحركات. |
| 2 | **Market Structure** | يصنّف كل Swing إلى HH/HL/LH/LL، ويحتفظ بآخر Swing High و Swing Low **غير مكسور**. كسر المرجع مع اتجاه معاكس = CHOCH، وإلا = BOS. |
| 3 | **Support / Resistance** | لا يرسم كل Pivot — بل يدمج (Cluster) كل Swing يقع ضمن `Sensitivity × ATR` في مستوى واحد يخزّن: السعر، عدد الاختبارات، القوة، آخر اختبار. الرسم يحدث على آخر شمعة فقط. |
| 4 | **Trend Line Engine** | بحث شامل على آخر N Swings لاختيار أفضل زوج نقاط ارتكاز. يُرفض أي خط تخترقه Swing لاحقة أو يكون أقصر من الحد الأدنى. ثم يراقب الكسر. |
| 5 | **Liquidity Engine** | كل Swing High = تجمّع سيولة شرائية (BSL)، وكل Swing Low = سيولة بيعية (SSL). للـSweep وضعان: Wick Sweep و Close Confirmation. |
| 6 | **FVG Engine** | نموذج 3 شموع. كل FVG يحمل: Top / Bottom / Creation Bar / Direction / State مع حالات FRESH → PARTIAL → MITIGATED. |
| 7 | **Order Block Engine** | آخر شمعة معاكسة قبل حركة Displacement أو قبل BOS/CHOCH. لكل OB **Strength Score** + حالات FRESH / TESTED / MITIGATED / INVALIDATED. |
| 8 | **Divergence Engine** | قمم وقيعان RSI مقابل قمم وقيعان السعر → Regular + Hidden، مع خط يربط النقطتين. |
| 9 | **Multi-Timeframe Engine** | نفس آلة حالة Market Structure تُنفَّذ داخل `request.security()` لكل فريم، مع `barmerge.lookahead_off`. |
| 10 | **Object Manager** | كل رسم يُخزَّن في مصفوفة لها سقف؛ عند التجاوز يُحذف الأقدم أولًا، فلا يصطدم المؤشر بحدود TradingView (500 لكل نوع). |
| 11 | **Alert Engine** | 17 `alertcondition()` تغطي كل الأحداث. |

**Confluence Engine:** يحسب كم محرك يتفق داخل نافذة زمنية (Sweep + FVG + OB +
BOS/CHOCH + Divergence) ويعرض `Bullish Confluence 4/5`.

---

## B. شرح الإعدادات

الإعدادات مقسّمة إلى مجموعات: GENERAL · SWINGS · MARKET STRUCTURE ·
SUPPORT & RESISTANCE · TREND LINES · LIQUIDITY · FVG · ORDER BLOCK ·
DIVERGENCE · MTF TABLE · CONFLUENCE · PERFORMANCE.

أهم الإعدادات:

* **Confirm signals on bar close** — عند التفعيل لا يتم تثبيت أي حدث إلا على
  شمعة مغلقة، فيختفي أي وميض (flicker) أثناء الشمعة الحالية.
* **Clean chart mode** — نظام أولويات لمنع الازدحام:
  `BOS/CHOCH ← Sweep ← FVG ← OB ← S/R ← Trend Lines ← Divergence ← Minor Swings`.
  الأقل أولوية يُخفى على الشمعة التي تحمل حدثًا أعلى أولوية.
  **يخفي الرسم فقط — لا يؤثر على التنبيهات أو الـConfluence.**
* **Pivot Length** — طول الـPivot، وهو نفسه مقدار التأخير في التأكيد.
* **Minimum Swing Distance** — يتجاهل الـSwing القريب جدًا من سابقه (0 = معطّل).
* **Sweep confirmation** — `Wick Sweep` (اختراق وإغلاق داخل نفس الشمعة) أو
  `Close Confirmation` (إغلاق خارج المستوى ثم عودة الإغلاق داخله خلال N شمعة).
* **On mitigation** (FVG) — `Keep` / `Hide` / `Delete`.
* **Max Lines / Max Boxes / Max Labels** — سقوف Object Manager.
* **Use last CLOSED HTF bar only** — يجعل جدول الفريمات يقرأ آخر شمعة مغلقة
  من الفريم الأعلى (أبطأ في التحديث، لكنه خالٍ تمامًا من إعادة الرسم).

---

## C. شرح الإشارات

| الإشارة | المعنى |
|---------|--------|
| **BOS ↑ / ↓** | كسر آخر Swing مؤكد **في اتجاه** الترند الحالي → استمرار. |
| **CHOCH ↑ / ↓** | أول كسر **عكس** الترند الحالي → تغيّر محتمل في البنية. |
| **BSL SWEEP** | السعر اخترق تجمّع سيولة فوق Swing High ثم عاد للإغلاق تحته → اصطياد سيولة المشترين (إشارة هبوطية). |
| **SSL SWEEP** | السعر اخترق سيولة تحت Swing Low ثم عاد للإغلاق فوقه → اصطياد سيولة البائعين (إشارة صعودية). |
| **FVG** | عدم توازن بين 3 شموع. `FRESH` لم يُلمس · `PARTIAL` دخله السعر · `MITIGATED` امتلأ. |
| **OB** | آخر شمعة معاكسة قبل حركة قوية. الرقم بجانبه = Strength Score (Displacement + Volume + BOS). |
| **REG BULL / REG BEAR** | دايفرجنس عادي → إشارة انعكاس محتمل. |
| **HID BULL / HID BEAR** | دايفرجنس خفي → إشارة استمرار الترند. |
| **TL Break ↑ / ↓** | كسر خط ترند تم بناؤه من نقطتي ارتكاز مؤكدتين على الأقل. |

---

## D. القيود والتأخير الطبيعي (مهم)

هذه ليست عيوبًا في الكود، بل طبيعة عمل Pine Script:

1. **تأخير الـPivot** — أي Pivot يحتاج اكتمال `Pivot Length` شمعة على يمينه
   قبل أن يوجد أصلًا. لذلك الـSwings و Market Structure و S/R و Trend Lines
   و Liquidity Levels و Divergence كلها **متأخرة بمقدار Pivot Length شمعة**.
   هذا هو الثمن المقابل لعدم إعادة الرسم (Non-Repainting).
2. **BOS / CHOCH قد يظهر متأخرًا** — إذا كُسر المستوى أثناء نافذة تأكيد
   الـPivot، تظهر الإشارة لحظة تأكيد الـPivot لا لحظة الكسر الفعلي.
3. **الشمعة الحالية** — مع إيقاف "Confirm on bar close" قد تظهر إشارة ثم تختفي
   قبل إغلاق الشمعة. مع تفعيله لا يحدث ذلك إطلاقًا.
4. **جدول MTF** — مع `lookahead_off` تكون قيمة الفريم الأعلى للشمعة **الجارية**
   غير نهائية (لا تسريب مستقبلي، لكنها تتغيّر حتى تغلق شمعة الفريم الأعلى).
   خيار "Use last CLOSED HTF bar only" يزيل هذا تمامًا مقابل تأخير شمعة واحدة.
5. **فريم أقل من فريم الشارت** — لا يُقرأ، ويُعرض `n/a` في الجدول.
6. **Volume** — بعض الرموز (خاصة الفوركس) لا توفر Volume حقيقيًا، عندها يُحيَّد
   عامل الحجم في Strength Score إلى 1.0 بدل تعطيل المحرك.
7. **حدود الكائنات** — TradingView يسمح بـ500 Line/Box/Label كحد أقصى؛ لهذا
   كل الرسومات تمر عبر Object Manager. رفع السقوف كثيرًا يبطئ الشارت.

---

## E. مراجعة الكود (ما تم فحصه فعليًا)

تمت مراجعة الملف بأدوات فحص ثابتة (static checks) للنقاط التالية:

* **Compile Errors** — فحص توازن الأقواس، المسافات البادئة (مضاعفات 4، بلا Tabs)،
  عدم وجود Block فارغ، عدم وجود استخدام لمتغيّر قبل تعريفه، وعدم وجود
  Naming Conflicts (لا تكرار في أسماء المتغيّرات أو الدوال العامة).
* **Array Errors** — كل حلقة `for` على مصفوفة محميّة بشرط `array.size() > 0`
  (لأن `for i = 0 to -1` في Pine يعمل تنازليًا ويسبب خطأ Index). الحذف من
  المصفوفات يتم بالتكرار التنازلي فقط.
* **Runtime Errors** — `ta.atr()` مغلّف بـ`nz()` لأنه `na` في أول الشموع؛ كل
  عمليات حذف الرسومات تمر عبر دوال `delLbl/delLn/delBx` الآمنة ضد `na`؛
  التحويلات إلى `int` صريحة لتفادي اختلاف أنواع `math.min/max`.
* **Object Limit Errors** — كل رسم مُسجَّل في مصفوفة لها سقف، والأقدم يُحذف أولًا.
* **Repainting / Future Leak** — لا يوجد `lookahead_on`، ولا أي إزاحة سالبة،
  ولا استخدام لنقطة مستقبلية في رسم الخطوط. كل الـPivots مؤكدة.
* **MTF Errors** — الفريم الأقل من فريم الشارت يُستبدل بفريم الشارت (طلب رخيص)
  ويُعرض `n/a`؛ عدد استدعاءات `request.security()` ثابت = 5.
* **Duplicate Signals** — `msTopBrk/msBotBrk` يمنعان تكرار BOS على نفس المستوى،
  `obDuplicate()` يمنع تكرار الـOrder Blocks المتداخلة، وشرط
  `score > lastScore` يمنع تكرار عنوان الـConfluence على كل شمعة.

> **لم يتم تشغيل الكود على TradingView** — لا يوجد مترجم Pine Script خارج
> منصة TradingView، لذلك المراجعة أعلاه ثابتة (static) ومنطقية فقط. يُرجى
> لصق الكود في Pine Editor والتحقق من التجميع قبل الاعتماد عليه.

---

## التركيب

1. افتح TradingView → **Pine Editor**.
2. الصق محتوى `SMC_Multi_Timeframe_Intelligence.pine`.
3. **Save** ثم **Add to chart**.
