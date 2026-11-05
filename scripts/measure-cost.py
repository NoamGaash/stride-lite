#!/usr/bin/env python3
"""Prices a measured run of the deployment, which the AWS bill will not do.

CloudFront's always-free tier covers the first 1 TB and 10 million requests a
month. A few days of real traffic almost certainly fits inside it, so Cost
Explorer reports zero for the CDN and the one number worth measuring --- how
much egress this API actually produces --- never appears on the invoice.

So: collect the usage from CloudWatch, then price it from infra/rates.json,
and report the projected month both with the free tier and without it. The
second figure is the one that says whether the free tier is a ceiling the
project will hit.

    measure-cost.py collect --distribution E123 --instance i-abc --days 3 > usage.json
    measure-cost.py price usage.json

`collect` needs AWS credentials with read access to CloudWatch and EC2;
`price` needs nothing and is pure arithmetic over the JSON.
"""
import argparse, datetime as dt, json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
RATES = os.path.join(HERE, os.pardir, 'infra', 'rates.json')
HOURS_PER_MONTH = 730.0
GIB = 1024 ** 3


def aws(*args):
    out = subprocess.run(['aws', *args], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f'aws {" ".join(args)} failed:\n{out.stderr.strip()}')
    return json.loads(out.stdout)


def metric_sum(namespace, name, dimensions, start, end, region):
    dims = [{'Name': k, 'Value': v} for k, v in dimensions.items()]
    res = aws(
        'cloudwatch', 'get-metric-statistics', '--namespace', namespace,
        '--metric-name', name, '--dimensions', json.dumps(dims),
        '--start-time', start.isoformat(), '--end-time', end.isoformat(),
        '--period', '86400', '--statistics', 'Sum',
        '--region', region, '--output', 'json',
    )
    return sum(p['Sum'] for p in res.get('Datapoints', []))


def collect(args):
    end = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    start = end - dt.timedelta(days=args.days)
    hours = args.days * 24.0

    # CloudFront publishes its metrics to us-east-1 whatever the distribution
    # serves, and only for the Global region dimension.
    cf_dims = {'DistributionId': args.distribution, 'Region': 'Global'}
    bytes_out = metric_sum('AWS/CloudFront', 'BytesDownloaded', cf_dims, start, end, 'us-east-1')
    requests = metric_sum('AWS/CloudFront', 'Requests', cf_dims, start, end, 'us-east-1')

    inst = aws('ec2', 'describe-instances', '--instance-ids', args.instance,
               '--region', args.region, '--output', 'json')['Reservations'][0]['Instances'][0]
    volumes = aws('ec2', 'describe-volumes', '--region', args.region, '--output', 'json',
                  '--filters', f'Name=attachment.instance-id,Values={args.instance}')['Volumes']

    # An instance that was stopped during the window overstates its hours here.
    # CloudWatch does not publish a "was running" metric, so the honest move is
    # to report the assumption rather than to infer it.
    json.dump({
        'window': {'from': start.isoformat(), 'to': end.isoformat(), 'hours': hours},
        'cloudfront': {'bytes_downloaded': bytes_out, 'requests': requests,
                       'edge_region': args.edge_region},
        'ec2': {'instance_type': inst['InstanceType'], 'running_hours': hours,
                'running_hours_is_assumed': True},
        'ebs': {'gb': sum(v['Size'] for v in volumes)},
        'ipv4': {'hours': hours if inst.get('PublicIpAddress') else 0.0},
        's3': {'get_requests': 0, 'put_requests': 0},
    }, sys.stdout, indent=2)
    print()


def price(args):
    usage = json.load(open(args.usage))
    rates = json.load(open(RATES))
    hours = usage['window']['hours']
    to_month = HOURS_PER_MONTH / hours

    inst_type = usage['ec2']['instance_type']
    inst_rate = rates['ec2_instance_hour'][inst_type]
    gb = usage['ebs']['gb']
    edge = usage['cloudfront'].get('edge_region', 'Middle East')

    lines = [
        (f'EC2 {inst_type}', usage['ec2']['running_hours'] * inst_rate),
        (f'EBS gp3, {gb} GB', gb * rates['ebs_gp3']['gb_month'] * hours / HOURS_PER_MONTH),
        ('Public IPv4', usage['ipv4']['hours'] * rates['public_ipv4_hour']),
        ('S3 requests',
         usage['s3']['get_requests'] * rates['s3']['get_request']
         + usage['s3']['put_requests'] * rates['s3']['put_request']),
    ]
    fixed = sum(v for _, v in lines)

    out_gb = usage['cloudfront']['bytes_downloaded'] / GIB
    reqs = usage['cloudfront']['requests']
    month_gb, month_reqs = out_gb * to_month, reqs * to_month
    free = rates['cloudfront_free_tier']
    gb_rate, req_rate = rates['cloudfront_gb_out'][edge], rates['cloudfront_https_request'][edge]

    billable_gb = max(0.0, month_gb - free['gb_per_month'])
    billable_reqs = max(0.0, month_reqs - free['requests_per_month'])
    cdn_billed = billable_gb * gb_rate + billable_reqs * req_rate
    cdn_gross = month_gb * gb_rate + month_reqs * req_rate

    w = 34
    print(f"Measured over {hours:.0f} h ({hours / 24:.1f} days), rates effective "
          f"{rates['_effective_date']}, {rates['region']}\n")
    print('Observed window'.ljust(w), 'USD')
    for name, v in lines:
        print(f'  {name.ljust(w - 2)} {v:8.2f}')
    print(f"  {'CloudFront (after free tier)'.ljust(w - 2)} "
          f"{cdn_billed * hours / HOURS_PER_MONTH:8.2f}")
    print(f"  {'total'.ljust(w - 2)} {fixed + cdn_billed * hours / HOURS_PER_MONTH:8.2f}")

    per_day = (fixed + cdn_billed * hours / HOURS_PER_MONTH) / (hours / 24)
    print(f"\nPer day{'':<27} {per_day:8.2f}")
    print(f"Projected month{'':<19} {fixed * to_month + cdn_billed:8.2f}")

    print(f"\nCloudFront traffic, projected to a month")
    print(f"  {'egress'.ljust(w - 2)} {month_gb:8.1f} GiB"
          f"   ({month_gb / free['gb_per_month'] * 100:.1f}% of the free 1 TB)")
    print(f"  {'requests'.ljust(w - 2)} {month_reqs / 1e6:8.1f} M  "
          f" ({month_reqs / free['requests_per_month'] * 100:.1f}% of the free 10M)")
    print(f"  {'cost if there were no free tier'.ljust(w - 2)} {cdn_gross:8.2f}  <-- the number"
          f" the bill hides")
    if billable_gb or billable_reqs:
        print('\n  The free tier is already exceeded at this traffic level.')
    else:
        headroom = free['gb_per_month'] / month_gb if month_gb else float('inf')
        print(f'\n  Free tier not reached. Traffic can grow {headroom:.1f}x before egress is billed.')


parser = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
sub = parser.add_subparsers(dest='cmd', required=True)

c = sub.add_parser('collect', help='read usage from CloudWatch (needs credentials)')
c.add_argument('--distribution', required=True, help='CloudFront distribution id')
c.add_argument('--instance', required=True, help='EC2 instance id')
c.add_argument('--days', type=int, default=3)
c.add_argument('--region', default='eu-west-1')
c.add_argument('--edge-region', default='Middle East',
               help="CloudFront pricing region the viewers are in")
c.set_defaults(func=collect)

p = sub.add_parser('price', help='price a usage.json (no credentials needed)')
p.add_argument('usage')
p.set_defaults(func=price)

args = parser.parse_args()
args.func(args)
