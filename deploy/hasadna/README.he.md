# התשתית של הסדנה

שום דבר לא נפרס מהתיקייה הזו. הסדנה מריצה את הפרויקטים שלה משני ריפויים משלה, שבהם
המתחזקים שלה עוברים על כל שינוי:

| מה | איפה |
|---|---|
| שרת ה-ClickHouse (Kamatera, רשת פנימית בלבד), ההגדרות שלו ובאקט הגיבוי | [hasadna-iac](https://github.com/hasadna/hasadna-iac), `modules/openbus/stride_lite.tf` ([#5](https://github.com/hasadna/hasadna-iac/pull/5)) |
| ה-API, המיגרציות וה-ingest, כ-images ש-ArgoCD מסנכרן | [hasadna-k8s](https://github.com/hasadna/hasadna-k8s), `apps/openbus` |

ה-image נבנה מהריפו הזה ב-CI. עותקים של הקבצים האלה לא נשמרים כאן בכוונה, כי הם היו מתרחקים
ממה שהסדנה מריצה בפועל.

## מה ה-image קורא

| משתנה | בשביל |
|---|---|
| `CH_URL`, `CH_USER`, `CH_PASSWORD`, `CH_DB` | ה-API (`api/src/ch.ts`) |
| `CH_CLIENT` | הסקריפטים, למשל `clickhouse client --host … --user … --password …` |
| `BACKUP_URL` | `scripts/first-load.sh` משחזר ממנו לתוך DB ריק |
| `ARCHIVE_BUCKET` | `scripts/gtfs-archive.sh`, `scripts/naim-rt-request.sh` |
| `API_URL` | `scripts/check-production.sh` |
