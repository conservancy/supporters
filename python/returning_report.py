#!/usr/bin/env python3

import argparse
import collections
import csv
import datetime
import functools
import os
import sys

import django

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'supporters.settings')
django.setup()
from supporters.models import Date, Payment, Supporter

MONTH_FMT = '%Y-%m'

def parse_arguments(arglist):
    parser = argparse.ArgumentParser(
        prog='returning_report',
        description="Print a CSV report showing Supporters who returned",
    )
    month_date = functools.partial(Date.strptime, fmt=MONTH_FMT)
    parser.add_argument(
        '--start-month', type=month_date, metavar='YYYY-MM',
        default=Payment.objects.order_by('date').first().date,
        help="First month in report")
    parser.add_argument(
        '--end-month', type=month_date, metavar='YYYY-MM',
        default=Date.today(),
        help="Last month in report")
    args = parser.parse_args(arglist)
    if args.end_month < args.start_month:
        parser.error("End month predates start month")
    return args

def report_month(month):
    annuals = collections.Counter(Supporter(name).status(month)
                                  for name in Supporter.iter_entities(['Annual']))
    monthlies = collections.Counter(Supporter(name).status(month)
                                    for name in Supporter.iter_entities(['Monthly']))
    eannuals = collections.Counter(
               min((Supporter(name).months_expired_at_return(month) + 2) // 3, 5)
               for name in Supporter.iter_entities(['Annual']))
    emonthlies = collections.Counter(
                 min((Supporter(name).months_expired_at_return(month) + 2) // 3, 5)
                 for name in Supporter.iter_entities(['Monthly']))
    return ((month.strftime(MONTH_FMT),)
            + ((annuals + monthlies)[Supporter.STATUS_NEW],)
            + ((eannuals + emonthlies)[1],)
            + ((eannuals + emonthlies)[2],)
            + ((eannuals + emonthlies)[3],)
            + ((eannuals + emonthlies)[4],)
            + ((eannuals + emonthlies)[5],))

def main(arglist):
    args = parse_arguments(arglist)
    out_csv = csv.writer(sys.stdout)
    # NOTE: 'Total New' here is the same as 'Total New' from status_report.py
    out_csv.writerow((
        'Month',
        'Total New',
        'Were 0-3mo expired', 'Were 3-6mo expired', 'Were 6-9mo expired',
        'Were 9-12mo expired', 'Were >1yr expired'
    ))
    month = Date.from_pydate(args.start_month)
    while month <= args.end_month:
        out_csv.writerow(report_month(month))
        month = month.round_month_up()

if __name__ == '__main__':
    main(None)
