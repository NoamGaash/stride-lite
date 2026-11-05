"""Pulls the handful of rates this deployment is priced on out of AWS's
price-list CSVs. Called by fetch-rates.sh; writes rates.json on stdout."""
import csv, json, sys, os

work, region = sys.argv[1], sys.argv[2]
INSTANCES = ['m7g.large', 'm7g.xlarge', 'm7g.2xlarge', 'c7g.4xlarge', 'c7g.8xlarge']


def rows(name):
    with open(os.path.join(work, name), newline='') as f:
        for _ in range(5):          # the offer files open with a disclaimer block
            f.readline()
        yield from csv.DictReader(f)


def one(it, what):
    vals = {float(v) for v in it}
    if len(vals) != 1:
        sys.exit(f'expected a single rate for {what}, got {sorted(vals)}')
    return vals.pop()


ec2, reserved, ebs, eff = {}, {}, {}, set()
for r in rows('ec2.csv'):
    fam, inst = r['Product Family'], r['Instance Type']
    on_demand_linux = (
        fam == 'Compute Instance' and inst in INSTANCES
        and r['Operating System'] == 'Linux' and r['Tenancy'] == 'Shared'
        and r['Pre Installed S/W'] == 'NA' and r['CapacityStatus'] == 'Used'
    )
    if on_demand_linux and r['TermType'] == 'OnDemand':
        ec2[inst] = float(r['PricePerUnit'])
        eff.add(r['EffectiveDate'])
    elif (on_demand_linux and r['TermType'] == 'Reserved' and r['Unit'] == 'Hrs'
          and r['LeaseContractLength'] == '1yr' and r['PurchaseOption'] == 'No Upfront'
          and r['OfferingClass'] == 'standard'):
        reserved[inst] = float(r['PricePerUnit'])
    elif r['TermType'] != 'OnDemand':
        continue
    elif fam == 'Storage' and r['Volume API Name'] == 'gp3':
        ebs['gb_month'] = float(r['PricePerUnit'])
    elif fam == 'System Operation' and r['Volume API Name'] == 'gp3':
        ebs['iops_month'] = float(r['PricePerUnit'])
    elif fam == 'Provisioned Throughput' and r['Volume API Name'] == 'gp3':
        ebs['throughput_gibps_month'] = float(r['PricePerUnit'])
    elif fam == 'Storage Snapshot' and r['usageType'].endswith('SnapshotUsage'):
        ebs['snapshot_gb_month'] = float(r['PricePerUnit'])

ipv4 = one(
    (r['PricePerUnit'] for r in rows('vpc.csv')
     if r['TermType'] == 'OnDemand' and 'In-use public IPv4' in r['PriceDescription']),
    'public IPv4',
)

s3 = {}
for r in rows('s3.csv'):
    if r['TermType'] != 'OnDemand':
        continue
    d = r['PriceDescription']
    if d == '$0.023 per GB - first 50 TB / month of storage used':
        s3['standard_gb_month'] = float(r['PricePerUnit'])
    elif d == '$0.005 per 1,000 PUT, COPY, POST, or LIST requests':
        s3['put_request'] = float(r['PricePerUnit'])
    elif d == '$0.004 per 10,000 GET and all other requests':
        s3['get_request'] = float(r['PricePerUnit'])

cf_out, cf_req, cf_free = {}, {}, {}
for r in rows('cf.csv'):
    if r['TermType'] != 'OnDemand':
        continue
    fam, desc = r['Product Family'], r['PriceDescription']
    # Egress names its edge region in `From Location`; requests name it in
    # `Location`. Reading the wrong one yields a single blank-keyed rate.
    if fam == 'Data Transfer' and (r['StartingRange'], r['EndingRange']) == ('0', '10240'):
        cf_out[r['From Location']] = float(r['PricePerUnit'])
    elif (fam == 'Request' and 'HTTPS Requests' in desc
          and 'Proxy' not in desc and r['Location']):
        cf_req[r['Location']] = float(r['PricePerUnit'])
    elif 'free each month under CloudFront free tier' in desc:
        key = 'gb_per_month' if r['Unit'] == 'GB' else 'requests_per_month'
        cf_free[key] = int(float(r['EndingRange']))

json.dump({
    '_source': 'AWS Price List bulk API offer files, fetched by scripts/fetch-rates.sh',
    '_effective_date': max(eff),
    'region': region,
    'ec2_instance_hour': ec2,
    'ec2_reserved_1yr_no_upfront_hour': reserved,
    'ebs_gp3': ebs,
    'public_ipv4_hour': ipv4,
    's3': s3,
    'cloudfront_free_tier': cf_free,
    'cloudfront_gb_out': cf_out,
    'cloudfront_https_request': cf_req,
}, sys.stdout, indent=2, sort_keys=True)
print()
