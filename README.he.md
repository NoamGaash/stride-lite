# stride-lite

[English](README.md) · [איך זה עובד](docs/DESIGN.he.md) · **[מה זה גילה על הפרודקשן](docs/FINDINGS.he.md)** · [עלות ופריסה](docs/DEPLOYMENT.he.md) · [מפת דרכים](ROADMAP.he.md) · [מדידות](docs/BENCHMARKS.md) (אנגלית) · [הרצה מקומית](docs/LOCAL-DB.he.md) · [requester נוסף ל-SIRI](docs/REQUESTER.he.md) · [מי החליט מה](docs/DECISIONS.he.md)

מימוש מחדש, מאפס, של ה-backend של
[Open Bus Stride](https://github.com/hasadna/open-bus-stride-api)
על ClickHouse.

אותו חוזה API, בית אחר בית.

חלק קטן מהאחסון.

בלי Airflow.

זה ניסוי, לא הצעה למיזוג.

הוא קיים כדי לענות על שאלה אחת במספרים ולא בדעות:
**איך היה נראה, ומה היה עולה, ה-backend של נתוני התחבורה הציבורית בישראל אם היו בונים אותו היום?**

> 🤖 רוב העבודה בריפו הזה נעשתה על ידי Claude (סוכן AI) בעבודה עם
> [@NoamGaash](https://github.com/NoamGaash).
> מה התבקש, מה הסוכן בחר ומה הוא עשה מופרדים ב-[docs/DECISIONS.he.md](docs/DECISIONS.he.md).
> כל מספר נמדד וניתן לשחזור לפי [docs/LOCAL-DB.he.md](docs/LOCAL-DB.he.md).

## התחלה מהירה

```bash
./up.sh
```

זה הכל. הסקריפט מוריד את הבינארי של ClickHouse, מריץ אותו תחת תקרת זיכרון, הגבלות I/O ושש
ליבות, יוצר את 16 הטבלאות, מתקין את שרשראות ה-ingest וה-enrichment, טוען שעתיים של SIRI חי
מ-S3, ומרים את ה-API על :8080. מאותו רגע מסד הנתונים מתעדכן לבדו, בלי scheduler ובלי worker.

`./up.sh 6` טוען שש שעות במקום שעתיים; `./up.sh 0` לא טוען היסטוריה כלל ורק מתקדם קדימה.

`/docs` הוא ה-Swagger UI של ה-API, ו-`/openapi.json` ה-spec שלו: זה של הפרודקשן, וכל פילטר
מסומן `x-lookup: indexed` או `scan`. הסימון נקרא מ-`db/schema.sql` ומ-`db/projections.sql`,
כך שהוא אומר מה מסד הנתונים באמת מוצא בלי קריאה מלאה.

בלי Docker, בלי root, בלי credentials — הנתונים ציבוריים.

תקרות המשאבים יושבות ב-[`deploy/local/local.xml`](deploy/local/local.xml), והן שם כי מכונת הייחוס של
הפרויקט היא תחנת עבודה של מישהו. על שרת ייעודי — להעלות אותן.

השחזור המלא, כולל הדאמפ של 13.7 מיליארד השורות, ב-[docs/LOCAL-DB.he.md](docs/LOCAL-DB.he.md).

## לתרום

לפתוח את הריפו ב-dev container שלו (`.devcontainer/`). הוא מביא Node, ‏Hurl, ‏Terraform, את
ה-CLI של AWS ואת הבינארי של ClickHouse בגרסאות של ה-CI, ולא מריץ כלום עד `./up.sh`.

כל בדיקה רצה ב-CI, ב-[`.github/workflows/ci.yml`](.github/workflows/ci.yml), ושם כל צעד אומר
מה הוא מוכיח; מקומית מריצים את אותה פקודה. בדיקה לתיקון מוצגת נכשלת בלי התיקון לפני שהיא
נכנסת.

## איפה זה עומד

**27 מתוך 27 endpoints מחזירים את אותו JSON כמו הפרודקשן**, כולל ה-ids, כי בתוך חלון ההשוואה
שני המסדים מחזיקים את אותן שורות תחת אותם מזהים.

נבדק ב-25.11.2026 מול הפריסה ב-AWS עם [`scripts/check-production.sh`](scripts/check-production.sh):
- 54 מתוך 54 מקרים עברו: 48 דיפרנציאליים, 5 על זמני נסיעה ו-1 על כיסוי;
- ה-snapshot החדש ביותר של SIRI היה בן דקות;
- אף refresh לא נכשל.

| | |
| --- | --- |
| endpoints שתואמים לפרודקשן | **27 מתוך 27** |
| בדיקות דיפרנציאליות | 48, מכסות כל endpoint ב-spec הפומבי |
| שדות שהוחרגו מההשוואה | 2, לשניהם נימוק נמדד |
| בדיקות יחידה | 188, בלי מסד נתונים |
| שורות קוד ב-API | ‏2,790 TypeScript |

בדיקת כיסוי נכשלת אם ה-spec הפומבי יצמיח endpoint שהחבילה לא מכסה, כך ש-"27 מתוך 27" לא יכול
להפוך בשקט ל-27 מתוך 28.

**שלושה דברים שהמספר הזה לא טוען:**

- **ל-`/gtfs_rides_agg/list` אין בסיס השוואה בפרודקשן.** הפרודקשן עונה לו ב-statement timeout —
  נמדד ב-86 שניות ושוב ב-103 על יום אחד — ולכן המקרה בודק רק שהמימוש הזה עונה. הנתונים שמאחוריו
  מאומתים דרך `/gtfs_rides_agg/group_by`, שקורא את אותו אגרגט וכן עונה.
- **שני שדות של `/siri_velocity_aggregation` מוחרגים.** הממוצע הנע שלו משתמש בחלון `ROWS` מעל
  `ORDER BY` עם תיקו, ולכן תוכן החלון תלוי בסדר הפיזי. שלוש קריאות זהות למימוש הזה החזירו שלושה
  ערכים שונים, כלומר גם הפרודקשן אינו יכול להיות יציב.
- **`/stop_arrivals/list` תואם בכך ששני הצדדים מחזירים ריק.** זה החוזה היחיד שעוד אפשר לדרוש
  ממנו, והסיבה ב-[FINDINGS.he.md](docs/FINDINGS.he.md).

## עבודה פתוחה

- **חבילת ההשוואה בודקת רק את החלון ששני המסדים מחזיקים מהדאמפ הציבורי**, 01/01/2025 עד
  29/05/2026: בפרודקשן אין שום דבר ישן יותר, והדאמפ נגמר שם. יום שהבנייה הזאת קלטה בעצמה עוד
  לא מושווה; קבוצת מקרים שנייה על יום כזה היא מה שסוגר את זה.
- **הקישור בין SIRI ל-GTFS וזמני הנסיעה שהושלמו לאחור עוד לא הושוו לפרודקשן נסיעה מול
  נסיעה.** [`ingest/gtfs-link.sql`](ingest/gtfs-link.sql) מעתיק את
  `siri/update_rides_gtfs.py` של ה-upstream, ו-[`ingest/duration-history.sql`](ingest/duration-history.sql)
  משלים את זמני הנסיעה שהפרודקשן הפסיק למדוד בנובמבר 2024
  ([open-bus-stride-etl#22](https://github.com/hasadna/open-bus-stride-etl/issues/22)). ביום
  עדכני שיעורי הקישור תואמים את הפרודקשן (71% לפי journey ו-98.5% לפי מסלול, מול 73% ו-98%),
  וזו התאמה, לא הוכחה.
- **עוד לא מופה אילו בקשות איטיות ולמה**
  ([#36](https://github.com/NoamGaash/stride-lite/issues/36)). `/route_timetable/list` הוא
  המקרה הבולט: שתי בקשות בלי cache לשרת ב-AWS ב-25.11.2026 לקחו 6.5 ו-1.3 שניות.
- **הדיסק מלא ב-88%: 46 מתוך 369 GB פנויים** בשרת ב-AWS ב-25.11.2026. התוכנית היא לשמור פחות,
  לא להגדיל את הדיסק: סוגי העמודות של `siri_vehicle_location`
  ([#28](https://github.com/NoamGaash/stride-lite/issues/28)), projections שכל אחד משרת
  endpoint אחד ([#29](https://github.com/NoamGaash/stride-lite/issues/29)), וטבלת הנחיתה
  `siri_vehicle_location_raw`, שאף אחד לא מנקה אחרי ההעשרה.

עוד ב-[ROADMAP.he.md](ROADMAP.he.md).

## מבנה

```
up.sh             פקודה אחת: בינארי, שרת, סכמה, ingest, enrichment, API
Dockerfile        ה-image היחיד: ה-API, הסכמה וה-jobs
api/              שירות TypeScript והבדיקות שלו
db/               schema.sql (16 הטבלאות), views.sql, projections.sql, migrations/
ingest/           siri.sql (ingest), enrich.sql (שרשרת 6 צעדים), gtfs-link.sql (SIRI → GTFS),
                  duration-history.sql (משכים היסטוריים), catchup.sh, gtfs.sh, backfill.sh
scripts/          כלים שרצים בכל מקום: apply-schema.sh, migrate.sh, first-load.sh,
                  backup.sh, gtfs-archive.sh, naim-rt-request.sh, check-production.sh, ...
tests/            בדיקות של כל אלה
deploy/aws/       השרת ב-AWS: Terraform, יחידות systemd, cron, bootstrap, deploy.sh והבדיקות שלו
deploy/hasadna/   README בלבד: מה נמצא ב-hasadna-iac ומה ב-hasadna-k8s
deploy/local/     הגדרות ClickHouse לתחנת עבודה, ש-up.sh משתמש בהן
docs/             תכנון, החלטות, ממצאים, מדידות, פריסה, הרצה מקומית
```

כל מה שספציפי לסביבה אחת נמצא תחת `deploy/<environment>/`, ומגיע לשאר הקוד כמשתנה סביבה
(`CH_URL`, `API_URL`, `ARCHIVE_BUCKET` וכו'). `tests/boundary.sh` מכשיל את ה-CI אם מזהה חשבון,
דומיין או נתיב של שרת מופיעים מחוץ לתיקייה הזו. כך fork שמגדיר ערכים משלו עובד מקצה לקצה,
והוצאה של סביבה משימוש היא מחיקה של התיקייה שלה.

## הסתייגויות

- **GTFS צריך cron, SIRI לא.** ClickHouse קורא מ-S3 לבדו אבל אינו יודע לקרוא zip מרובה-קבצים,
  אז את פיד ה-GTFS מוריד סקריפט shell פעם ביום. זו העבודה המתוזמנת היחידה מחוץ למסד הנתונים.
- **61 שורות בדקה שנמדדה עדיין נבדלות** מהפרודקשן ב-`siri_ride__scheduled_start_time`, ברכב
  אחד עם journey ref מסוג סנטינל, והסיבה אינה מובנת.
- **PostgreSQL מנצח בשאילתה אחת** — סינון צר של `line_ref` יחד עם תיבה גיאוגרפית, 0.017
  שניות מול 0.063-0.090. אינדקסי B-tree על `lon`/`lat` הם הכלי הנכון שם, וסגירת הפער עם
  skip indexes היא עבודה שלא נעשתה.
- **הקלט היחיד שלא כומת בהערכת ה-AWS הוא נפח התעבורה.** כל מחיר מגיע מקובצי התמחור של AWS
  עצמה, מופק מחדש על ידי `deploy/aws/bin/fetch-rates.sh` לתוך [deploy/aws/rates.json](deploy/aws/rates.json),
  וחישוב ודיסק הם 96% מהחשבון. egress מעל הטרהבייט החינמי של CloudFront דורש נתון תעבורה
  אמיתי, והחשבונית מראה אפס על egress בתוך ה-free tier, ולכן קיים `deploy/aws/bin/measure-cost.py`.
  מה שהפרויקט משלם היום דווח בפרטי ואינו בריפו הזה.
- **ה-projections הם 30% מהנפח, כפי שנמדד.** ארבעה מהם מביאים את הסך הכל מ-163.98 GiB
  ל-**233.02 GiB**: `gtfs_ride_stop.by_ride` ב-29.88, `siri_ride_stop.by_gtfs_stop` ב-19.33,
  `siri_ride_stop.by_siri_ride` ב-18.95 ו-`siri_ride.by_natural_key` ב-0.87. `siri_ride_stop`
  צריכה שניים כי היא מסוננת לפי מפתח זר אחר בכל אחד משני endpoints ואינה ממוינת לפי אף אחד.
  אחד מהארבעה, `by_gtfs_stop`, מיותר: הוא משרת רק את `/stop_arrivals/list`, שאינו יכול להחזיר
  שורה מהפרודקשן כלל.
- הריפו הזה לא עונה על השאלות שבאמת מכריעות מיגרציה: מי מתחזק, מה קורה בשלוש לפנות בוקר,
  ומה נשבר במעבר בין ספקים. אלה הכרעות של המתחזקים, ומדידות לא מכריעות אותן.

## רישיון

MIT. הנתונים ציבוריים, מתפרסמים על ידי משרד התחבורה ונאספים על ידי
[הסדנה לידע ציבורי](https://www.hasadna.org.il/).
