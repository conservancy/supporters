#!/usr/bin/perl

use strict;
use warnings;

use autodie qw(open close chdir);
use DBI;
use Encode qw(encode decode);

use LaTeX::Encode;

use Supporters;

my $LEDGER_CMD = "/usr/bin/ledger";
if (@ARGV < 2) {
  
  print STDERR "usage: $0 <SUPPORTERS_SQLITE_DB_FILE> <GIVING_LIMIT>\n";
  exit 1;
}
my @typeList = qw/t-shirt-0 t-shirt-1 t-shirt-extra-0 t-shirt-fy2018design-0/;
my %requests = ( soon => {}, now => {} );
%{$requests{now}} =  map( { ($_, {}) }, @typeList);
%{$requests{soon}} =  map( { ($_, {}) }, @typeList);


my($SUPPORTERS_SQLITE_DB_FILE, $GIVING_LIMIT, $VERBOSE, @LEDGER_CMD_LINE) = @ARGV;
foreach my $id (sort { sortFunction($a, $b); } @supporterIds) {
  my $sizeNeeded;
  my $type;
  foreach $type (keys %requests) {
    my $request = $sp->getRequest({ donorId => $id, requestType => $type,
                                    ignoreHeldRequests => 1, ignoreFulfilledRequests => 1 });
    if (defined $request and defined $request->{requestType}) {
      $sizeNeeded = $request->{requestConfiguration};
      last;
    }
  }
  next if not defined $sizeNeeded;   # If we don't need a size, we don't have a request.
  my $amount = $sp->donorTotalGaveInPeriod(donorId => $id);
  if ($amount < $GIVING_LIMIT) {
    $requests{soon}{$type}{$sizeNeeded}++;
  } else {
    $requests{now}{$type}{$sizeNeeded}++;
  }
}

foreach my $key ('now', 'soon') {
  print "\n\nREQUESTS READY FOR FUFILLMENT", uc($key), ":\n";
}
foreach my $type (keys %{$requests{$key}}) {
  if (scalar(keys %{$requests{$key}{$type}}) > 0) {
    print "   $type:\n";
    foreach my $size (keys %{$requests{$key}{$type}}) {
      print "      $size: $request{$key}{$type}{$size}\n";
    }
  }
}
###############################################################################
#
# Local variables:
# compile-command: "perl -c t-shirt-print-need.plx"
# End:

