# שחזור מסד הנתונים המקומי

[English](LOCAL-DB.md)

כל מה שלמטה רץ על נתונים ציבוריים ואינו דורש credentials. אין גישה למסד הפרודקשן של הסדנה
בשום שלב, וגם אין בה צורך.

**אם אתם רק רוצים שזה ירוץ, `./up.sh` משורש הריפו עושה את כל מסלול ב' ומרים את ה-API.** שאר
הדף הזה הוא למי שרוצה את ההיסטוריה המלאה, או להבין מה כל צעד עושה.

שני מסלולים. בוחרים לפי מה שרוצים לעשות.

| | מסלול א' — הדאמפ המלא | מסלול ב' — יום fixture |
| --- | --- | --- |
| מה מקבלים | כל 16 הטבלאות, 13.7 מיליארד שורות | יום אחד של SIRI, כ-5.5 מיליון שורות |
| הורדה | 154.6 GB דחוס | כ-1 GB |
| דיסק אחרי הטעינה | 164 GiB | כ-130 MB |
| זמן שעון | כ-14 שעות על 6 ליבות | כ-10 דקות |
| טוב ל- | החבילה הדיפרנציאלית, נתוני אחסון | עבודה על שאילתות, פיתוח ה-API |

## דרישות מקדימות

- ClickHouse 25.3 ומעלה. בלי root, בלי Docker, בלי מנהל חבילות:
  ```bash
  curl https://clickhouse.com/ | sh      # מניח בינארי סטטי אחד ב-$PWD
  ./clickhouse server                    # מאזין על 9000 (native) ו-8123 (HTTP)
  ```
- `zstd`, `mawk` (או כל awk), `curl`.
- Node 22 ל-API.

להפנות את הסקריפטים לבינארי שלכם אם הוא לא ב-`PATH`:

```bash
export CH_CLIENT="./clickhouse client --port 9000"
export CH_DB=stride
```

## מסלול א' — הדאמפ המלא

הגיבוי של הפרודקשן ציבורי:

```bash
curl -O https://openbus-stride-public.s3.eu-west-1.amazonaws.com/stride_db.sql.zst
```

154,630,881,726 בתים, `pg_dump -n public --no-privileges | zstd -19`.

**הוא מיושן.** ה-`Last-Modified` הוא 14/06/2026 והנתונים בתוכו נגמרים ב-29/05/2026 — ה-DAG
בשם `stride-etl-db-copy-backup-to-s3` רץ לאחרונה ב-2022. זו בעיה תפעולית אמיתית של הפרויקט
(ראו [BENCHMARKS.md §10](BENCHMARKS.md)), ולצרכים שלנו היא פשוט החלון שכל מקרה בדיקה
דיפרנציאלי חייב לשבת בתוכו.

```bash
./scripts/apply-schema.sh
./scripts/load-from-dump.sh stride_db.sql.zst
```

לנתונים חיים מעל הדאמפ, להוסיף את טבלת הנחיתה הגולמית, את לופ ה-ingest ואת ההעשרה:

```bash
./clickhouse client --database stride --multiquery < db/raw.sql
./clickhouse client --database stride --multiquery < ingest/siri.sql
./clickhouse client --database stride --multiquery < ingest/enrich.sql
```

מכאן מסד הנתונים שומר על עצמו עדכני: הפיד נוחת ב-`siri_vehicle_location_raw`, ושישה views
מתרעננים בשרשרת גוזרים ממנו את הטבלאות המוקלדות של ה-API. אחרי backfill, להריץ את
`ingest/enrich-once.sql` במקום לחכות לרענון הבא. **לעשות backfill מהשעה הישנה ביותר קודם** —
ה-`scheduled_start_time` של נסיעה נלקח מהצפייה המוקדמת ביותר בה, ולכן טעינה קדימה נותנת את
אותה תשובה שהלופ החי היה נותן.

מעבר סטרימינג אחד: `split-tables.awk` מנתב כל בלוק `COPY` ל-FIFO ייעודי לכל טבלה, ו-16
תהליכי `clickhouse client` מכניסים במקביל. שום דבר לא מועלה לדיסק בדרך, אז צריך מקום לדאמפ
ועוד כ-164 GiB, לא פי שלושה מזה.

שני דברים שקל לטעות בהם ושהסקריפט מטפל בהם:

- **סדר העמודות מגיע מהסכמה החיה**, ונשאל בזמן ריצה. בלוקי ה-`COPY` של הדאמפ הם ללא כותרות,
  אז רשימת עמודות שנכתבה ביד ונסחפה תיטען בשקט ובאופן שגוי.
- **`--date_time_input_format=best_effort` הכרחי.** PostgreSQL כותב חותמות זמן במיקרו-שניות
  שהפרסר של ClickHouse דוחה כברירת מחדל.

לאימות. ספירות השורות מדויקות וצריכות להתאים עד השורה:

```sql
SELECT table, formatReadableQuantity(sum(rows)), formatReadableSize(sum(data_compressed_bytes))
FROM system.parts WHERE database = 'stride' AND active
GROUP BY table ORDER BY sum(data_compressed_bytes) DESC;
```

| טבלה | שורות | דחוס |
| --- | --- | --- |
| `siri_vehicle_location` | 6,506,195,421 | 111.52 GiB |
| `gtfs_ride_stop` | 4,113,193,845 | 24.57 GiB |
| `siri_ride_stop` | 2,803,456,736 | 21.24 GiB |
| `gtfs_ride` | 114,949,212 | 1.74 GiB |
| `siri_ride` | 110,227,936 | 2.58 GiB |
| `gtfs_stop` | 35,376,512 | 920 MiB |
| `gtfs_stop_mot_id` | 35,376,527 | 407 MiB |
| `gtfs_route` | 6,969,141 | 142 MiB |
| `siri_snapshot` | 2,246,550 | 137 MiB |
| 7 טבלאות קטנות יותר | 60,113 | פחות מ-1 MiB |
| **סך הכל** | **13,728,053,041** | **163.22 GiB** |

זה הדאמפ כפי שנטען, לפני כל projection. ה-ingest הרציף מוסיף לזה משם, וה-projections שלמטה
מתווספים שוב מעל.

להריץ `OPTIMIZE TABLE … FINAL` לפני שסומכים על נתון גודל, אחרת מיזוגים שלא התיישבו מנפחים אותו.

### שני projections, אם רוצים שה-endpoints כבדי ה-join יהיו מהירים

`/siri_ride_stops/list` וכל מה שמסנן טבלה גדולה לפי מפתח זר שהיא אינה ממוינת לפיו צריך סדר
מיון שני. זה שנמדד:

```sql
ALTER TABLE stride.gtfs_ride_stop
  ADD PROJECTION by_ride (SELECT * ORDER BY gtfs_ride_id);
ALTER TABLE stride.gtfs_ride_stop MATERIALIZE PROJECTION by_ride;
```

29.87 GiB וכשעתיים בנייה על 6 ליבות. זה הופך חיפוש של 4.35 שניות ל-0.015 שניות, בקריאה של 3
granules מתוך 328,980. אינדקס דילוג `bloom_filter` הוא הכלי הלא נכון כאן ומגיע רק ל-1.22
שניות — הנימוק והמספרים ב-[BENCHMARKS.md](BENCHMARKS.md#is-clickhouse-a-bad-fit-because-of-joins-measured-answer-no).

לתקצב projections כשמצטטים אחסון. נמדד, כל השלושה:

| טבלה | Projection | גודל | מי צריך אותו |
| --- | --- | --- | --- |
| `gtfs_ride_stop` | `by_ride` | 29.88 GiB | endpoints כבדי join |
| `siri_ride_stop` | `by_gtfs_stop` | 19.33 GiB | `/stop_arrivals/list` |
| `siri_ride_stop` | `by_siri_ride` | 18.95 GiB | `/siri_ride_stops/list` |
| `siri_ride` | `by_natural_key` | 0.87 GiB | חיפוש הנסיעה ב-enrichment |

163.98 GiB בסיס ועוד 69.04 GiB של projections הם **233.02 GiB** — ה-projections הם 30% מזה.
`siri_ride_stop` צריכה שניים כי היא מסוננת לפי מפתח זר אחר בכל אחד משני endpoints ואינה ממוינת
לפי אף אחד; כל חיפוש יורד מ-44 שניות ל-0.016. `siri_ride` צריכה אחד כי ה-enrichment שואל
"אילו מהנסיעות האלה כבר קיימות" בכל רענון, ובלעדיו השאלה הזאת בונה set של 6.83 GiB.

`by_gtfs_stop` הוא זה שאפשר לדלג עליו. הוא משרת רק את `/stop_arrivals/list`, שאינו יכול
להחזיר שורה מהפרודקשן לשום קלט — ראו [FINDINGS.he.md](FINDINGS.he.md) — אז ויתור עליו חוסך
19.33 GiB ואינו משנה דבר שניתן להבחין בו. כל הארבעה נמצאים ב-
[`db/projections.sql`](../db/projections.sql).

## מסלול ב' — יום fixture אחד

בלי דאמפ. ה-snapshots הגולמיים של SIRI ציבוריים ו-ClickHouse קורא אותם מ-S3 ישירות, בלי שום
קוד אפליקטיבי באמצע:

```sql
SELECT count()
FROM s3('https://openbus-stride-public.s3.eu-west-1.amazonaws.com/stride-siri-requester/2026/05/20/08/{00..59}.br',
        NOSIGN, 'JSONEachRow', 'response String');
```

`NOSIGN` אינו אופציונלי — בלעדיו ClickHouse מסרב להשתמש ב-credentials של השרת לשאילתת משתמש.

ליום fixture טעון, לריפו של הסדנה עצמה יש את מאקרו ה-ingest:

```bash
git clone https://github.com/hasadna/open-bus-stride-clickhouse
just data-ingest-backfill 2026 05 20 08
```

## להריץ את ה-API מולו

```bash
cd api
npm ci
CH_URL=http://127.0.0.1:8123 CH_DB=stride npm start   # מאזין על 8080
curl 'http://127.0.0.1:8080/siri_routes/list?limit=2'
```

```bash
npm test                                  # בדיקות יחידה על בניית SQL, בלי מסד נתונים
npx vitest run tests/differential.test.ts # משווה מול ה-API החי של הפרודקשן
```

החבילה הדיפרנציאלית פונה ל-`https://open-bus-stride-api.hasadna.org.il`, שהוא שירות פרודקשן
של מלכ"ר ולא סביבת בדיקות. היא מרווחת בקשות ב-`DIFF_DELAY_MS` (400 מילישניות כברירת מחדל)
ושומרת על רשימת מקרים קטנה. בבקשה להשאיר את זה ככה.

## לשמור על המכונה שלכם שמישה

`up.sh` כבר מריץ את ClickHouse תחת התקרות שב-`ingest/local.xml` ו-`ingest/local-users.xml`,
ולכן אין צורך לעשות כלום אם משתמשים בו. מה שלמטה הוא ההסבר למה הן שם, ומה לעשות בטעינה ידנית.

הטעינה המלאה היא עבודה חסומת-I/O שתפיל תחנת עבודה אם נותנים לה. מה שעבד, אחרי ניסיון ראשון
שרווה את ה-NVMe ב-97.6% ניצולת:

```bash
taskset -c 18-23 nice -n 19 ./scripts/load-from-dump.sh stride_db.sql.zst
```

`taskset` הוא זה שמשנה: הוא תקרה קשיחה על עץ התהליכים שאף ספירת threads פנימית לא יכולה
לעבור. `ionice` לא עושה כלום על מתזמן I/O מסוג `none`, וזה מה שיש ל-NVMe בדרך כלל — אז מצמצמים
בתוך ClickHouse במקום:

```xml
<clickhouse>
  <max_local_read_bandwidth_for_server>83886080</max_local_read_bandwidth_for_server>
  <max_local_write_bandwidth_for_server>41943040</max_local_write_bandwidth_for_server>
</clickhouse>
```

ותקרת ה-CPU יושבת בפרופיל, כי אין הגבלת CPU ברמת השרת:

```xml
<clickhouse>
  <profiles><default><max_threads>6</max_threads></default></profiles>
</clickhouse>
```

אל תורידו גם את `background_pool_size`: שתי בדיקות שפיות פנימיות
(`number_of_free_entries_in_pool_to_execute_mutation` = 20 ו-
`..._to_execute_optimize_entire_partition` = 25) מסרבות להעלות את השרת אם ה-pool קטן מהן.
