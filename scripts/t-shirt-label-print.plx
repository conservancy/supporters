#!/usr/bin/perl
# License: AGPL-3.0-or-later

use strict;
use warnings;

use autodie qw(open close chdir);
use DBI;
use Encode qw(encode decode);

use LaTeX::Encode;

use Supporters;

my $LEDGER_CMD = "/usr/local/bin/ledger";

if (@ARGV < 9) {
  print STDERR "usage: $0 <SUPPORTERS_SQLITE_DB_FILE> <GIVING_LIMIT> <T-SHIRT-STYLE> <SIZE_COUNTS> <OUTPUT_DIRECTORY > <MONTHLY_SEARCH_REGEX> <ANNUAL_SEARCH_REGEX>  <VERBOSE> <LEDGER_CMD_LINE>\n";
  exit 1;
}

my($SUPPORTERS_SQLITE_DB_FILE, $GIVING_LIMIT, $T_SHIRT_STYLE, $SIZE_COUNTS, $OUTPUT_DIRECTORY, $MONTHLY_SEARCH_REGEX, $ANNUAL_SEARCH_REGEX, $VERBOSE, @LEDGER_CMD_LINE) = @ARGV;
$VERBOSE = 0 if not defined $VERBOSE;

open(SIZE_COUNTS, "<", $SIZE_COUNTS);

my %sizeCounts;
while (my $line = <SIZE_COUNTS>) {
  next if ($line =~ /^\s*#/ or $line =~ /^\s*$/);
  if ($line =~ /^\s*(\S+)\s+(\d+)\s*/) {
    my($size, $count) = ($1, $2, $3);
    $sizeCounts{$size} = $count;
  } else {
    die "invalid line $line in $SIZE_COUNTS file";
  }
}
close SIZE_COUNTS;

open(LIST, ">checklist-ready-to-send.tex") or die "unable to open list: $!";
open(LABELS, ">labels-ready-to-send.tex") or die "unable to open labels: $!";

print LIST <<LIST_HEADER
\\documentclass[letterpaper, 10pt]{letter}
\\usepackage{units}
\\usepackage{color}
\\usepackage{wasysym}
\\usepackage{latexsym}
\\usepackage{amsfonts}
\\usepackage{amssymb}
\\usepackage[T1]{fontenc}
\\begin{document}
\\vspace{-15in}

\\begin{tabular}{|l|l|l|l|l|} \\hline
LIST_HEADER
;


my $dbh = DBI->connect("dbi:SQLite:dbname=$SUPPORTERS_SQLITE_DB_FILE", "", "",
                               { RaiseError => 1, sqlite_unicode => 1 })
  or die $DBI::errstr;

my $sp = new Supporters($dbh, \@LEDGER_CMD_LINE, { monthly => $MONTHLY_SEARCH_REGEX, annual => $ANNUAL_SEARCH_REGEX});
my(@supporterIds) = $sp->findDonor({});

my $overallCount = 0;
my %lines;

sub sortFunction($$) {
  my $lastGaveDate0 = $sp->donorLastGave($_[0]);
  my $lastGaveDate1 = $sp->donorLastGave($_[1]);
  my $ledgerEntityId0 = $sp->getLedgerEntityId($_[0]);
  my $ledgerEntityId1 = $sp->getLedgerEntityId($_[1]);
  my $type0 = $sp->{ledgerData}{$ledgerEntityId0}{__TYPE__};
  my $type1 = $sp->{ledgerData}{$ledgerEntityId1}{__TYPE__};
  if ( (defined $type0 and $type0 =~ /month/i) or (defined $type1 and $type1 =~ /month/i)) {
    return ($_[0] <=> $_[1]);
  } else {
    return ($lastGaveDate0 cmp $lastGaveDate1);
  }
}
my @typeList;
my @oldTypeList;
if ($T_SHIRT_STYLE eq 'fy2018design') {
  @typeList = qw/t-shirt-fy2018design-0/;
  @oldTypeList = qw/t-shirt-0 t-shirt-1 t-shirt-extra-0 t-shirt-extra-1/;
} elsif ($T_SHIRT_STYLE == 0) {
  @typeList = qw/t-shirt-0 t-shirt-extra-0/; 
} elsif ($T_SHIRT_STYLE == 1) {
  @oldTypeList = qw/t-shirt-0 t-shirt-extra-0/;
  @typeList = qw/t-shirt-1 t-shirt-extra-1/; 
} else {
  die "Unknown t-shirt style given: $T_SHIRT_STYLE";
}

foreach my $id (sort { sortFunction($a, $b); } @supporterIds) {
  my $sizeNeeded;
  foreach my $type (@typeList) {
    my $request = $sp->getRequest({ donorId => $id, requestType => $type,
                                    ignoreHeldRequests => 1, ignoreFulfilledRequests => 1 });
    if (defined $request and defined $request->{requestType}) {
      $sizeNeeded = $request->{requestConfiguration};
      last;
    }
  }
  next if not defined $sizeNeeded;   # If we don't need a size, we don't have a request.

  my $shirtCount = 1;  # Count 1 for the one we're about to send and...
  foreach my $oldType (@oldTypeList) {
    # ... cound each one off the old list
    $shirtCount++ if (defined $sp->getRequest({ donorId => $id, requestType => $oldType}));
  }
  my $amount = $sp->donorTotalGaveInPeriod(donorId => $id);
  if ($amount < ($GIVING_LIMIT * $shirtCount)) {
    print "Skipping $id request for $sizeNeeded because donor has requested $shirtCount shirts, only gave $amount and giving limit is $GIVING_LIMIT\n" if $VERBOSE;
    next;
  }

  my $postalAddress = $sp->getPreferredPostalAddress($id);
  if (not defined $postalAddress) {
    my(@postalAddresses) = $sp->getPostalAddresses($id);
    $postalAddress = $postalAddresses[0];
  }
  my $latexPostal = latex_encode($postalAddress);
  $latexPostal =~ s/\\unmatched\{0141\}/\L{}/g;
  $latexPostal =~ s/\\unmatched\{0142\}/\l{}/g;
  if ($latexPostal =~ /unmatched/) {
    print "Skipping $id request for $sizeNeeded because the address has characters the post office will not accept\n  Address was: ", encode('UTF-8', $postalAddress), "\n and became\n$latexPostal\n"  if $VERBOSE;
    next;
  }

  { no strict;  no warnings; $sizeCounts{$sizeNeeded}--; }
  if ($sizeCounts{$sizeNeeded} < 0) {
    print STDERR "Skipping $id request for $sizeNeeded because we are out.\n" if $VERBOSE;
    next;
  }
  $overallCount++;
  $lines{$sizeNeeded}{labels} = "" unless defined $lines{$sizeNeeded}{labels};
  $lines{$sizeNeeded}{checklist} = [] unless defined $lines{$sizeNeeded}{checklist};
  $lines{$sizeNeeded}{labels} .= '\mlabel{}{TO: \\\\ ' . join(' \\\\ ', split('\n', $latexPostal)) . "}\n";
  my $shortLatexPostal = latex_encode(sprintf('%-30.30s', join(" ", reverse split('\n', $postalAddress))));
  $shortLatexPostal =~ s/\\unmatched\{0141\}/\L{}/g;
  $shortLatexPostal =~ s/\\unmatched\{0142\}/\l{}/g;
  push(@{$lines{$sizeNeeded}{checklist}}, '{ $\Box$} &' . sprintf("%-3d  & %5s & %-30s  & %s ",
                                                  $id, encode('UTF-8', $sp->getLedgerEntityId($id)),
                                                  encode('UTF-8', $sizeNeeded),
                                                  $shortLatexPostal) .
                                                    '\\\\ \hline' . "\n");
}
my $lineCount = 0;
foreach my $size (sort { $a cmp $b } keys %lines) {
  foreach my $line (@{$lines{$size}{checklist}}) {
    if ($lineCount++ > 40) {
      $lineCount = 0;
      print LIST "\n\n", '\end{tabular}',"\n\\pagebreak\n\\begin{tabular}{|l|l|l|l|l|} \\hline\n";
    }
    print LIST $line;
  }
  print LABELS $lines{$size}{labels};
  delete $lines{$size}{labels};
}

print LIST "\n\n", '\end{tabular}',"\n";
print LIST "FINAL INVENTORY EXPECTED\n\\begin{tabular}{|l|l|} \\hline\n";
print STDERR "Total Shirts: $overallCount\n" if $VERBOSE;

my %needList;
foreach my $size (sort keys %sizeCounts) {
  if ($sizeCounts{$size} < 0) {
    $needList{$size} = abs($sizeCounts{$size});
    $sizeCounts{$size} = 0;
  }
  print LIST "$size & $sizeCounts{$size}\\\\\n";
}
my $overallNeed = 0;
if (scalar(keys %needList) > 0) {
  print LIST "\\hline \n\n", '\end{tabular}',"\n\n\\bigskip\n\n";
  print LIST "T-SHIRTS NEEDED\n\\begin{tabular}{|l|l|} \\hline\n";
  foreach my $size (sort keys %needList) {
    print LIST "$size & $needList{$size}\\\\\n";
    $overallNeed += $needList{$size};
  }
}
print LIST "\\hline \n\n", '\end{tabular}',"\n\n\nOVERALL SENDING COUNT: $overallCount",
  "\n\nOVERAL NEED COUNT: $overallNeed\n", '\end{document}', "\n";
close LIST;
close LABELS;

open(my $yamlFH, '>', 'address.yml');
use YAML::Tiny;
my $yaml = YAML::Tiny->new(\@allAddresses);
$yaml->write('address.yml');

###############################################################################
#
# Local variables:
# compile-command: "perl -c t-shirts-label-print.plx"
# End:

