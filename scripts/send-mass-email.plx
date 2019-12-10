#!/usr/bin/perl

use strict;
use warnings;

use autodie qw(open close);
use DBI;

use Date::Manip::DM5;
use Supporters;
use Encode qw(encode decode);
use Email::MIME::RFC2047::Encoder;
use utf8;

my $encoder = Email::MIME::RFC2047::Encoder->new();

my $TODAY = UnixDate(ParseDate("today"), '%Y-%m-%d');

if (@ARGV < 5) {
  print STDERR "usage: $0 <SUPPORTERS_SQLITE_DB_FILE> <FROM_ADDRESS> <EMAIL_CONTENTS_FILE> <MONTHLY_SEARCH_REGEX> <ANNUAL_SEARCH_REGEX>  <VERBOSE> <LEDGER_CMD_LINE> <LEDGER_COMMAND_LINE>\n";
  exit 1;
}

my($SUPPORTERS_SQLITE_DB_FILE, $FROM_ADDDRESS, $EMAIL_CONTENTS_FILE, $MONTHLY_SEARCH_REGEX, $ANNUAL_SEARCH_REGEX, $VERBOSE,
   @LEDGER_CMD_LINE) = @ARGV;
$VERBOSE = 0 if not defined $VERBOSE;

my $dbh = DBI->connect("dbi:SQLite:dbname=$SUPPORTERS_SQLITE_DB_FILE", "", "",
                               { RaiseError => 1, sqlite_unicode => 1 })
  or die $DBI::errstr;

my $sp = new Supporters($dbh, \@LEDGER_CMD_LINE, { monthly => $MONTHLY_SEARCH_REGEX, annual => $ANNUAL_SEARCH_REGEX});

open(EMAIL, "<", $EMAIL_CONTENTS_FILE);
my(@emailLines) = <EMAIL>;
close EMAIL;

my(@supporterIds) = $sp->findDonor({});
foreach my $id (@supporterIds) {
  my $donorType = $self->getType($id);
  my $expiresOn = $sp->supporterExpirationDate($id);
  my $isLapsed = ( (not defined $expiresOn) or $expiresOn lt $TODAY);

  my $amount = $sp->donorTotalGaveInPeriod(donorId => $id);
  my $lastGaveDate = $sp->donorLastGave($id);
  my $firstGaveDate = $sp->donorFirstGave($id);
  my $nineMonthsSinceFirstGave = UnixDate(DateCalc(ParseDate($firstGaveDate), "+ 9 months"), '%Y-%m-%d');


  # invalid email address
  my @invalidEmailAddresses = qw//;
  next if ($id ~~ @invalidEmailAddresses);
  next unless $sp->emailOk($id);
  my %emails;
  my $email = $sp->getPreferredEmailAddress($id);
  if (defined $email) {
    $emails{$email} = {};
  } else {
    %emails = $sp->getEmailAddresses($id);
  }
  my(@emails) = keys(%emails);

  my $fullEmailLine = "";
  my $emailTo = join(' ', @emails);
  my $displayName = $sp->getDisplayName($id);
  foreach my $email (@emails) {
    $fullEmailLine .= ", " if ($fullEmailLine ne "");
    my $line = "";
    if (defined $displayName) {
      $line .= $encoder->encode_phrase($displayName) . " ";
    }
    $line .= "<$email>";
    $fullEmailLine .= $line;
  }
  open(SENDMAIL, "|-", "/usr/lib/sendmail -f \"$FROM_ADDDRESS\" -oi -oem -- \'$emailTo\'");


  print SENDMAIL "To: $fullEmailLine\n";
  print SENDMAIL @emailLines;
  close SENDMAIL;

  print STDERR "Emailed $emailTo with $id who expires on $expiresOn\n" if ($VERBOSE);
}
###############################################################################
#
# Local variables:
# compile-command: "perl -c send-mass-email.plx"
# End:

