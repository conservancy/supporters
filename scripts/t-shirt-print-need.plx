#!/usr/bin/perl

use strict;
use warnings;

use autodie qw(open close chdir);
use DBI;
use Encode qw(encode decode);

use LaTeX::Encode;

use Supporters;

my $LEDGER_CMD = "/usr/bin/ledger";
if (@ARGV < 7) {
  
  print STDERR "usage: $0 <SUPPORTERS_SQLITE_DB_FILE> <GIVING_LIMIT> <MONTHLY_SEARCH_REGEX> <ANNUAL_SEARCH_REGEX>  <VERBOSE> <LEDGER_CMD_LINE>\n";
  exit 1;
}
my @typeList = qw/t-shirt-0 t-shirt-1 t-shirt-extra-0 t-shirt-fy2018design-0/;
my %requests = ( soon => {}, now => {} );
%{$requests{now}} =  map { ($_, {}) } @typeList;
%{$requests{soon}} =  map { ($_, {}) } @typeList;
my %monthCounts =  map { ($_, {}) } @typeList;

my($SUPPORTERS_SQLITE_DB_FILE, $GIVING_LIMIT, $MONTHLY_SEARCH_REGEX, $ANNUAL_SEARCH_REGEX,, @LEDGER_CMD_LINE) = @ARGV;

my $dbh = DBI->connect("dbi:SQLite:dbname=$SUPPORTERS_SQLITE_DB_FILE", "", "",
                               { RaiseError => 1, sqlite_unicode => 1 })
  or die $DBI::errstr;

my $sp = new Supporters($dbh, \@LEDGER_CMD_LINE, { monthly => $MONTHLY_SEARCH_REGEX, annual => $ANNUAL_SEARCH_REGEX});
my(@supporterIds) = $sp->findDonor({});
foreach my $id (sort { $a <=> $b } @supporterIds) {
  foreach my $type (keys %{$requests{now}}) {
    my $sizeNeeded;
    my $request = $sp->getRequest({ donorId => $id, requestType => $type,
                                    ignoreHeldRequests => 1, ignoreFulfilledRequests => 1 });
    if (defined $request and defined $request->{requestType}) {
      $sizeNeeded = $request->{requestConfiguration};
      my $amount = $sp->donorTotalGaveInPeriod(donorId => $id);
      my $when = ($amount < $GIVING_LIMIT) ? "soon" : "now";
      if ($when eq 'now') {
        my $month = $request->{requestDate};
        $month =~ s/-\d{2,2}$//;
        $monthCounts{$type}{$month} = 0  if not defined $monthCounts{$type}{$month};
        $monthCounts{$type}{$month}++;
      }
      $requests{$when}{$type}{$sizeNeeded} = 0 unless defined $requests{$when}{$type}{$sizeNeeded};
      $requests{$when}{$type}{$sizeNeeded}++;
      print STDERR "t-shirt-1 in $sizeNeeded wanted $when by $id\n" if ($type eq 't-shirt-1');
    }
  }
}

foreach my $key ('now', 'soon') {
  print "\n\nREQUESTS READY FOR FUFILLMENT ", uc($key), ":\n";
  foreach my $type (keys %{$requests{$key}}) {
    if (scalar(keys %{$requests{$key}{$type}}) > 0) {
      print "   $type:\n";
      foreach my $size (keys %{$requests{$key}{$type}}) {
        print "      $size: $requests{$key}{$type}{$size}\n";
      }
    }
  }
}
print "\n\nWAITING AMOUNT SINCE FOR THOSE WHO ARE READY NOW\n";
foreach my $type  (sort {$a cmp $b } keys %monthCounts) {
  print "   $type: \n" if scalar(keys %{$monthCounts{$type}}) > 0;
  foreach my $month (sort {$a cmp $b } keys %{$monthCounts{$type}}) {
    print "      $month: $monthCounts{$type}{$month}\n";
  }
}

###############################################################################
#
# Local variables:
# compile-command: "perl -c t-shirt-print-need.plx"
# End:

