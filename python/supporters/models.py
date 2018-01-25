#!/usr/bin/env python3

import datetime
import operator
import time

from django.db import models

class Date(datetime.date):
    MONTH_MAXDAY = {
        1: 31,
        2: 28,
        3: 31,
        4: 30,
        5: 31,
        6: 30,
        7: 31,
        8: 31,
        9: 30,
        10: 31,
        11: 30,
        12: 31,
    }

    @classmethod
    def from_pydate(cls, date):
        return cls(date.year, date.month, date.day)

    @classmethod
    def strptime(cls, s, fmt):
        time_tuple = time.strptime(s, fmt)
        return cls(*time_tuple[:3])

    def adjust_month(self, delta, day=None):
        if day is None:
            day = self.day
        year_delta, month_delta = divmod(abs(delta), 12)
        op_func = operator.sub if delta < 0 else operator.add
        month = op_func(self.month, month_delta)
        if (month < 1) or (month > 12):
            year_delta += 1
            month = op_func(month, -12)
        year = op_func(self.year, year_delta)
        day = min(day, self.MONTH_MAXDAY[month])
        return type(self)(year, month, day)

    def next_month(self, day=None):
        return self.adjust_month(1, day)

    def next_year(self):
        return self.adjust_month(12)

    def round_month_up(self):
        return self.adjust_month(1, day=1)


class DateField(models.DateField):
    def from_db_value(self, value, expression, connection, context):
        if value is not None:
            value = Date.from_pydate(value)
        return value


class Payment(models.Model):
    date = DateField()
    entity = models.TextField()
    payee = models.TextField()
    program = models.TextField()
    amount = models.TextField()


class Supporter:
    STATUS_NEW = 'New'
    STATUS_ACTIVE = 'Active'
    STATUS_LAPSED = 'Lapsed'
    STATUS_LOST = 'Lost'

    RETURNING_0MO = 'ReturningAfter0-3monthLapse'
    RETURNING_3MO = 'ReturningAfter3-6monthLapse'
    RETURNING_6MO = 'ReturningAfter6-9monthLapse'
    RETURNING_9MO = 'ReturningAfter9-12monthLapse'
    RETURNING_12MO = 'ReturningAfter>12monthLapse'
    RETURNING_NOT = 'NotReturning'

    LOST_THRESHOLD = datetime.timedelta(days=365)
    LAPSED_THRESHOLD = datetime.timedelta()

    def __init__(self, entity):
        self.entity = entity

    @classmethod
    def iter_entities(cls, supporter_types=['Annual', 'Monthly']):
        qset = Payment.objects.only('entity')
        if supporter_types is None:
            pass
        elif not supporter_types:
            qset = qset.none()
        else:
            condition = models.Q()
            for suffix in supporter_types:
                condition |= models.Q(program__endswith=':' + suffix)
            qset = qset.filter(condition)
        seen = set()
        for payment in qset:
            if payment.entity not in seen:
                seen.add(payment.entity)
                yield payment.entity

    def payments(self, as_of_date=None):
        pset = Payment.objects.order_by('date').filter(entity=self.entity)
        if as_of_date is not None:
            pset = pset.filter(date__lte=as_of_date)
        return pset

    def _expose(internal_method):
        def expose_wrapper(self, as_of_date=None, *args, **kwargs):
            return internal_method(self, self.payments(as_of_date), *args, **kwargs)
        return expose_wrapper

    def _supporter_type(self, payments):
        try:
            program = payments.filter(program__isnull=False).reverse()[0].program
        except IndexError:
            return None
        else:
            return program.rsplit(':', 1)[-1]
    supporter_type = _expose(_supporter_type)

    def _calculate_lapse_date(self, last_payment_date, supporter_type):
        if supporter_type == 'Monthly':
            lapse_date = last_payment_date.next_month()
        else:
            lapse_date = last_payment_date.next_year()
        return lapse_date.round_month_up()

    def _lapse_date(self, payments):
        return self._calculate_lapse_date(payments.last().date,
                                          self._supporter_type(payments))
    lapse_date = _expose(_lapse_date)

    def _second_last_lapse_date(self, payments):
        # TODO: find a way without listification - needed due to indexing
        return self._calculate_lapse_date(list(payments)[-2].date,
                                          self._supporter_type(payments))

    def status(self, as_of_date=None):
        if as_of_date is None:
            as_of_date = Date.today()
        payments = self.payments(as_of_date)
        payments_count = payments.count()
        if payments_count == 0:
            return None
        lapse_date = self._lapse_date(payments)
        days_past_due = as_of_date - lapse_date
        if days_past_due >= self.LOST_THRESHOLD:
            return self.STATUS_LOST
        elif days_past_due >= self.LAPSED_THRESHOLD:
            return self.STATUS_LAPSED
        elif as_of_date.adjust_month(-1, 1) < payments.first().date <= as_of_date:
            return self.STATUS_NEW
        else:
            return self.STATUS_ACTIVE

    def months_expired(self, as_of_date=None):
        if as_of_date is None:
            as_of_date = Date.today()
        payments = self.payments(as_of_date)
        payments_count = payments.count()
        if payments_count == 0:
            return None
        lapse_date = self._lapse_date(payments)
        days_past_due = as_of_date - lapse_date

        if as_of_date.adjust_month(-1, 1) < payments.first().date <= as_of_date:
            return self.RETURNING_NOT  # started paying this month so not "returning"

        elif as_of_date.adjust_month(-1, 1) < payments.last().date <= as_of_date:
            # (there are at least 2 payments because first().date != last().date)
            if payments.last().date <= self._second_last_lapse_date(payments):

                # the most recent payment was this month, and it was before or on
                #  the lapse date for the last payment (i.e. it was "on-time") so
                #  this is a normal active subscriber, not a "re-"subscriber
                return self.RETURNING_NOT
            else:
                # the most recent payment was this month, and it was after the lapse
                #  date for the last payment (so this is a "re-"subscriber)

                # let's see how far past due the payment was, and return accordingly
                last_past_due = (payments.last().date
                                 - self._second_last_lapse_date(payments))

                # TODO: use real month boundaries (approximating ok, but not great)
                if last_past_due < datetime.timedelta(days=91):
                    return self.RETURNING_0MO
                elif last_past_due < datetime.timedelta(days=183):
                    return self.RETURNING_3MO
                elif last_past_due < datetime.timedelta(days=274):
                    return self.RETURNING_6MO
                elif last_past_due < datetime.timedelta(days=365):
                    return self.RETURNING_9MO
                else:
                    return self.RETURNING_12MO
        else:
            # supporter lapsed/lost or an annual supporter who paid 2-12 months ago
            return self.RETURNING_NOT
