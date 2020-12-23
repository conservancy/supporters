#!/usr/bin/perl

use strict;
use warnings;

use autodie qw(:all);

use Getopt::Long;
use File::Spec::Functions qw(rel2abs catfile);
use DBI;

use Encode qw(encode decode);
use Supporters;

my($VERBOSE, $supporterId, $requestType, $requestConfig, $SUPPORTERS_SQLITE_DB_FILE) = (0, undef, undef, undef,
                                                                          catfile($ENV{CONSERVANCY_REPOSITORY},
                                                                                  'Financial', 'Ledger', 'supporters.db'));
GetOptions("verbose=i" => \$VERBOSE, "supporterDB=s" => \$SUPPORTERS_SQLITE_DB_FILE,
           'supporterId=i' => \$supporterId, 'requestType=s' => \$requestType, 'requestConfig=s' => \$requestConfig, );


sub UsageAndExit($) {
  print STDERR "usage: $0 [ --supporterId=i --requestyType=STR --requestConfig=STR --supportersDB=PATH_TO_SUPPORTERS_SQLITE_DB_FILE --verbose=N ]\n";
  print STDERR "\n  $_[0]\n";
  exit 2;
}
UsageAndExit("Cannot read supporters db file: $SUPPORTERS_SQLITE_DB_FILE") unless defined $SUPPORTERS_SQLITE_DB_FILE
  and -r $SUPPORTERS_SQLITE_DB_FILE;

my $dbh = DBI->connect("dbi:SQLite:dbname=$SUPPORTERS_SQLITE_DB_FILE", "", "",
                               { RaiseError => 1, sqlite_unicode => 1 })
  or die $DBI::errstr;

my $sp = new Supporters($dbh, [ "none" ]);

if (defined $supporterId) {
  UsageAndExit("$supporterId is not a valid supporter id") unless $sp->_verifyId($supporterId);
} else {
  print "Supporter Id: ";
  my $supporterId = <STDIN>;
  chomp $supporterId;
}

my @requestTypes = $sp->getRequestType();
my %requestTypes;
@requestTypes{@requestTypes} = @requestTypes;
if (defined $requestType) {
  UsageAndExit("requestType must be one of the following: (".  join(", ", @requestTypes) . ")\n")
    unless defined $requestTypes{$requestType};
} else {
  $requestType = "";
  while (not defined $requestTypes{$requestType}) {
    print "Request Type (", join(", ", @requestTypes), "): ";
    $requestType = <STDIN>;
    chomp $requestType;
  }
}

my $configs = $sp->getRequestConfigurations($requestType);
die "problematic  on configs" if (keys %$configs != 1);
my $requestId = (keys(%$configs)) [0];

print "Using request id, $requestId\n";

if (defined $requestConfig) {
  UsageAndExit("requestType, $requestType does not have any valid config options yet you provided requestConfig of $requestConfig")
    if (scalar keys(%{$configs->{$requestId}}) <= 0);
  UsageAndExit("requestConfig must be one of the following: (" . join(", ",
                                                            keys(%{$configs->{$requestId}})) . ")\n")
    unless defined $configs->{$requestId}{$requestConfig};
} else {
  if (scalar keys(%{$configs->{$requestId}}) > 0) {
    while (not defined $requestConfig or not defined $configs->{$requestId}{$requestConfig}) {
      print "Request Config (", join(", ", keys(%{$configs->{$requestId}})), "): ";
      $requestConfig = <STDIN>;
      chomp $requestConfig;
    }
  }
}

if ($requestType) {
  my $requestParamaters;
  if (defined $requestConfig) {
    $requestParamaters = { donorId => $supporterId, requestConfiguration => $requestConfig, requestType => $requestType };
  } else {
    $requestParamaters = { donorId => $supporterId, requestType => $requestType };
  }
  $sp->addRequest($requestParamaters);
}
