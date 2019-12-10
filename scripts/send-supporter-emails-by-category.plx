#!/usr/bin/perl

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
my $FORTY_FIVE_DAYS_AGO = UnixDate(ParseDate("45 days ago"), '%Y-%m-%d');
my $SIXTY_DAYS_AGO = UnixDate(ParseDate("60 days ago"), '%Y-%m-%d');
my $NINETY_DAYS_AGO = UnixDate(ParseDate("90 days ago"), '%Y-%m-%d');
my $ONE_AND_HALF_YEARS_AGO = UnixDate(ParseDate("18 months ago"), '%Y-%m-%d');
my $NINE_MONTHS_AGO = UnixDate(ParseDate("9 months ago"), '%Y-%m-%d');
my $FIFTEEN_MONTHS_AGO = UnixDate(ParseDate("15 months ago"), '%Y-%m-%d');
my $THREE_TWENTY_DAYS_AGO = UnixDate(ParseDate("320 days ago"), '%Y-%m-%d');
my $END_LAST_YEAR = '2017-12-31';

if (@ARGV < 5) {
  print STDERR "usage: $0 <SUPPORTERS_SQLITE_DB_FILE> <FROM_ADDRESS> <EMAIL_TEMPLATE_SUFFIX> <BAD_ADDRESS_LIST_FILE> <MONTHLY_SEARCH_REGEX> <ANNUAL_SEARCH_REGEX>  <VERBOSE> <LEDGER_CMD_LINE> <LEDGER_COMMAND_LINE>\n";
  exit 1;
}

my($SUPPORTERS_SQLITE_DB_FILE, $FROM_ADDDRESS, $EMAIL_TEMPLATE_SUFFIX, $BAD_ADDRESS_LIST_FILE, $MONTHLY_SEARCH_REGEX, $ANNUAL_SEARCH_REGEX, $VERBOSE,
   @LEDGER_CMD_LINE) = @ARGV;
$VERBOSE = 0 if not defined $VERBOSE;

my $dbh = DBI->connect("dbi:SQLite:dbname=$SUPPORTERS_SQLITE_DB_FILE", "", "",
                               { RaiseError => 1, sqlite_unicode => 1 })
  or die $DBI::errstr;

my $sp = new Supporters($dbh, \@LEDGER_CMD_LINE, { monthly => $MONTHLY_SEARCH_REGEX, annual => $ANNUAL_SEARCH_REGEX});

my %groupLines;
foreach my $group (1 .. 3) {
  $groupLines{$group} = [];
  open(my $emailFH, "<", "group-${group}" . $EMAIL_TEMPLATE_SUFFIX);
  @{$groupLines{$group}} = <$emailFH>;
  close $emailFH;
}

my %skip = ();
sub update_skips {
  my $skips = shift;
  my $source_filename = shift;
  open(my $skipFH, '<', $source_filename) or
    die "couldn't open skip file $source_filename: $!";
  while (my $email = <$skipFH>) {
    chomp $email;
    $skips->{$email} = $source_filename;
  }
  close $skipFH;
}
if (defined $BAD_ADDRESS_LIST_FILE) {
  update_skips(\%skip, $BAD_ADDRESS_LIST_FILE);
}

my %groupCounts;
for my $ii (0 .. 5) { $groupCounts{$ii} = 0; }

my(@supporterIds) = $sp->findDonor({});
foreach my $id (@supporterIds) {
  next unless $sp->isSupporter($id);
  my $donorType = lc($sp->getType($id));
  my $expiresOn = $sp->supporterExpirationDate($id);
  my $isLapsed = ( (not defined $expiresOn) or $expiresOn lt $TODAY);

  my $amount = $sp->donorTotalGaveInPeriod(donorId => $id);
  my $lastGaveDate = $sp->donorLastGave($id);
  my $firstGaveDate = $sp->donorFirstGave($id);
  my $nineMonthsSinceFirstGave = UnixDate(DateCalc(ParseDate($firstGaveDate), "+ 9 months"), '%Y-%m-%d');
  my $group = 0;
  # staff testing code:

  if (not $sp->emailOk($id)) {
    print "NOT-SENT: SUPPORTER $id: has requested no email contact\n";
    $groupCounts{$group}++;
    next;
  }
  # if ($lastGaveDate le $END_LAST_YEAR) {
  #   $group = 1;
  # } elsif ($lastGaveDate gt $END_LAST_YEAR) {
  #   $group = 0;
  # if ( ($donorType eq 'monthly' and $lastGaveDate lt $SIXTY_DAYS_AGO ) or
  #      ($donorType eq 'annual' and $lastGaveDate lt $THREE_TWENTY_DAYS_AGO) )
  #      {
  #   $group = 1;
  if ($donorType eq 'monthly' and $lastGaveDate ge $NINETY_DAYS_AGO) {
    $group = 1;
  } elsif ( ($donorType eq 'monthly' and $lastGaveDate ge $NINETY_DAYS_AGO) or
            $donorType eq 'annual' and $lastGaveDate ge $FIFTEEN_MONTHS_AGO) {
    $group = 2;
  } elsif ( ($donorType eq 'monthly' and $lastGaveDate lt $NINETY_DAYS_AGO) or
            $donorType eq 'annual' and $lastGaveDate lt $FIFTEEN_MONTHS_AGO) {
    $group = 3;
  # } elsif ($donorType eq 'annual' and $lastGaveDate ge $THREE_TWENTY_DAYS_AGO) {
  #   $group = 3;
  # } elsif ( ($donorType eq 'annual' and $lastGaveDate le $ONE_AND_HALF_YEARS_AGO) or
  #           ($donorType eq 'monthly' and $lastGaveDate le $NINE_MONTHS_AGO) ) {
  #   $group = 4;
  # } elsif ($donorType eq 'monthly' and $lastGaveDate gt $NINE_MONTHS_AGO
  #         and $lastGaveDate le $FORTY_FIVE_DAYS_AGO) {
  #   $group = 5;
  } else {
    die "Supporter $id: not in a group, $donorType who last gave on $lastGaveDate";
  }
  if ($group <= 0) {
    print "NOT-SENT: SUPPORTER $id: Fit in no specified group: Type: $donorType, Last Gave: $lastGaveDate\n";
    $groupCounts{0}++;
    next;
  }
  # Staff testing code 
   # next unless ($id == 20 or $id == 34);  # $id == 26
   # $group = 3 if $id == 34;
  my %emails;
  
  my $email = $sp->getPreferredEmailAddress($id);
  if (defined $email) {
    $emails{$email} = {};
  } else {
    %emails = $sp->getEmailAddresses($id);
  }
  my @badEmails;
  foreach $email (keys %emails) {
    if (defined $skip{$email}) {
      delete $emails{$email};
      push(@badEmails, $email);
    }
  }
  if (scalar(keys %emails) <= 0) {
    print "NOT-SENT: SUPPORTER $id: these email address(es) is/were bad: ",
      join(",", @badEmails), "\n";
      $groupCounts{0}++;
    next;
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
  print "SENT: SUPPORTER $id: Group $group: ", join(",", @emails), "\n";

  open(my $sendmailFH, "|-", '/usr/lib/sendmail', '-f', $FROM_ADDDRESS, '-oi', '-oem', '--',
       @emails);


  print $sendmailFH "To: $fullEmailLine\n";
  print $sendmailFH @{$groupLines{$group}};
  close $sendmailFH;
  usleep(60000);
  $groupCounts{$group}++;
}
print "\n\n";
my $totalSent = 0;
foreach my $group (sort keys %groupCounts) {
  print "TOTAL IN GROUP $group: $groupCounts{$group}\n";
  $totalSent += $groupCounts{$group} if $group > 0;
}
print "\n\nTOTAL EMAILS SENT: $totalSent\n";

###############################################################################
#
# Local variables:
# compile-command: "perl -c send-mass-email.plx"
# End:

