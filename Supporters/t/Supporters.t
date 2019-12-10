# Supporters.t                                            -*- Perl -*-
#   Basic unit tests for Supporters.pm
#
# License: AGPLv3-or-later
#  Copyright info in COPYRIGHT.md, License details in LICENSE.md with this package.
###############################################################################
# FIXME: Untested things: request holds, and fulfill failure
use strict;
use warnings;

use Test::More tests => 353;
use Test::Exception;
use Sub::Override;
use File::Temp qw/tempfile/;

use Scalar::Util qw(looks_like_number reftype);
use POSIX qw(strftime);

# Yes, this may cause tests to fail if you run them near midnight. :)
my $today = strftime "%Y-%m-%d", gmtime;

=pod

Supporters.t is the basic unit tests for Supporters.pm.  It tests the
following things:

=over

=item use command for the module.

=cut

BEGIN { use_ok('Supporters') };


require 't/CreateTestDB.pl';

my $dbh = get_test_dbh();

# Set up test data for ledger-related tests

my($fakeLedgerFH, $fakeLedgerFile) = tempfile("fakeledgerXXXXXXXX", UNLINK => 1);

print $fakeLedgerFH <<FAKE_LEDGER_TEST_DATA_END;
Supporters:Annual 2015-05-04 Whitman-Dick \$-5.00
Supporters:Monthly 2015-05-25 Olson-Margaret \$-10.00
Supporters:Monthly 2015-01-15 Olson-Margaret \$-10.00
Supporters:Monthly 2015-03-17 Olson-Margaret \$-10.00
Supporters:Annual 2015-12-04 Harris-Joan \$-120.00
Supporters:Monthly 2015-04-20 Olson-Margaret \$-10.00
Supporters:Match Pledge 2015-02-26 Whitman-Dick \$-300.00
Supporters:Monthly 2015-02-16 Olson-Margaret \$-10.00
Supporters:Monthly 2015-06-30 Olson-Margaret \$-10.00
Supporters:Annual 2015-03-04 Harris-Joan \$-120.00
Supporters:Annual 2016-01-10  \$-120.00
FAKE_LEDGER_TEST_DATA_END

=item Public-facing methods of the module, as follows:

=over

=item new

=cut

my $sp;

dies_ok { $sp = new Supporters(undef, "test"); }
        "new: dies when dbh is undefined.";
dies_ok { $sp = new Supporters(bless({}, "Not::A::Real::Module"), "test"); }
        "new: dies when dbh is blessed into another module.";

dies_ok { $sp = new Supporters($dbh, "testcmd"); }
        "new: dies when if the command is a string.";

dies_ok { $sp = new Supporters($dbh, [ "testcmd" ], {}); }
        "new: dies when programTypeSearch is an empty hash.";

dies_ok { $sp = new Supporters($dbh, [ "testcmd" ], {monthly => 'test', annual => 'test', dummy => 'test' }); }
        "new: dies when programTypeSearch has stray value.";

dies_ok { $sp = new Supporters($dbh, [ "testcmd" ], {monthly => 'test' }); }
        "new: dies when programTypeSearch key annual is missing .";

dies_ok { $sp = new Supporters($dbh, [ "testcmd" ], {annual => 'test' }); }
        "new: dies when programTypeSearch key monthly is missing .";

my $cmd =  [ "/bin/cat", $fakeLedgerFile ];

$sp = new Supporters($dbh, $cmd, { monthly => '^Supporters:Monthly',
                                  annual => '^Supporters:(?:Annual|Match Pledge)'});

is($dbh, $sp->dbh(), "new: verify dbh set");
is_deeply($sp->ledgerCmd(),  $cmd, "new: verify ledgerCmd set");

=item addSupporter

=cut

dies_ok { $sp->addSupporter({}) }
        "addSupporter: ledger_entity_id required";

my $campbellId;
lives_ok { $campbellId = $sp->addSupporter({ ledger_entity_id => "Campbell-Peter" }); }
         "addSupporter: add works for minimal acceptable settings";

ok( (looks_like_number($campbellId) and $campbellId > 0),
   "addSupporter: add works for minimal acceptable settings");

dies_ok  { $sp->addSupporter({ public_ack => 1, ledger_entity_id => "Whitman-Dick" }) }
         "addSupporter: display_name required";

my $drapperId;
lives_ok { $drapperId = $sp->addSupporter({ display_name => "Donald Drapper",
                               public_ack => 1, ledger_entity_id => "Whitman-Dick" }); }
         "addSupporter: public_ack set to true with a display_name given";

ok( (looks_like_number($drapperId) and $drapperId > $campbellId),
   "addSupporter: add works with public_ack set to true and a display_name given");

my $olsonId;

lives_ok { $olsonId = $sp->addSupporter({ display_name => "Peggy Olson",
                                          public_ack => 0, ledger_entity_id => "Olson-Margaret",
                                          email_address => 'olson@example.net',
                                          email_address_type => 'home' }); }
         "addSupporter: succeeds with email address";

ok( (looks_like_number($olsonId) and $olsonId > $drapperId),
   "addSupporter: add succeeded with email address added.");

my $val = $sp->dbh()->selectall_hashref("SELECT donor_id, email_address_id " .
                                        "FROM donor_email_address_mapping  " .
                                        "WHERE donor_id = " . $sp->dbh->quote($olsonId, 'SQL_INTEGER'),
                                        'donor_id');

ok((defined $val and defined $val->{$olsonId}{email_address_id} and $val->{$olsonId}{email_address_id} > 0),
   "addSupporter: email address mapping is created on addSupporter() w/ email address included");

my $olsonFirstEmailId = $val->{$olsonId}{email_address_id};

my $sterlingId;
lives_ok { $sterlingId = $sp->addSupporter({ display_name => "Roger Sterling",
                                  ledger_entity_id => "Sterling-Roger",
                                  email_address => 'sterlingjr@example.com',
                                  email_address_type => 'home' }) }
         "addSupporter: succeeds with no public_ack setting specified...";

ok( (looks_like_number($sterlingId) and $sterlingId > $olsonId),
   "addSupporter: ... and return value is sane.");

my $harrisId;

lives_ok { $harrisId = $sp->addSupporter({ ledger_entity_id => 'Harris-Joan' }) }
         "addSupporter: set up one more in db (use this one for future test types on addSupporter)...";
ok( (looks_like_number($harrisId) and $harrisId > $sterlingId),
   "addSupporter: ... and return value is sane.");


=item getPublicAck

=cut

my $publicAckVal;

dies_ok { $publicAckVal = $sp->getPublicAck(0); }
        "getPublicAck: fails supporterId invalid";
dies_ok { $publicAckVal = $sp->getPublicAck("String"); }
        "getPublicAck: fails supporterId is string";
dies_ok { $publicAckVal = $sp->getPublicAck(undef); }
        "getPublicAck: fails supporterId is undef";

# Replace _verifyId() to always return true

my $overrideSub = Sub::Override->new( 'Supporters::_verifyId' => sub ($$) { return 1;} );
dies_ok { my $ledgerId = $sp->getPublicAck(0); }
        "getPublicAck: fails when rows are not returned but _verifyId() somehow passed";
$overrideSub->restore;

lives_ok { $publicAckVal = $sp->getPublicAck($olsonId); }
  "getPublicAck: lives when valid id is given for someone who does not want it...";

is($publicAckVal, 0, "getPublicAck: ...and return value is correct.");

lives_ok { $publicAckVal = $sp->getPublicAck($drapperId); }
  "getPublicAck: lives when valid id is given for someone who wants it...";

is($publicAckVal, 1, "getPublicAck: ...and return value is correct.");

lives_ok { $publicAckVal = $sp->getPublicAck($sterlingId); }
  "getPublicAck: lives when valid id is given for someone who is undecided...";

is($publicAckVal, undef, "getPublicAck: ...and return value is correct.");


=item isSupporter

=cut

my $isSupporter;

dies_ok { $isSupporter = $sp->isSupporter(0); }
        "isSupporter: fails when rows are not returned but _verifyId() somehow passed";

# Replace _verifyId() to always return true

$overrideSub = Sub::Override->new( 'Supporters::_verifyId' => sub ($$) { return 1;} );
dies_ok { my $ledgerId = $sp->isSupporter(0); }
        "isSupporter: fails when rows are not returned but _verifyId() somehow passed";
$overrideSub->restore;

lives_ok { $isSupporter = $sp->isSupporter($olsonId); }
  "isSupporter: lives when valid id...";

is($isSupporter, 1, "isSupporter: ...and return value is correct.");

=item getDisplayName

=cut

my $displayNameVal;

dies_ok { $displayNameVal = $sp->getDisplayName(0); }
        "getDisplayName: fails when rows are not returned but _verifyId() somehow passed";

# Replace _verifyId() to always return true

$overrideSub = Sub::Override->new( 'Supporters::_verifyId' => sub ($$) { return 1;} );
dies_ok { $displayNameVal = $sp->getDisplayName(0); }
        "getDisplayName: fails when rows are not returned but _verifyId() somehow passed";
$overrideSub->restore;

lives_ok { $displayNameVal = $sp->getDisplayName($olsonId); }
  "getDisplayName: lives when valid id is given for someone who does not want it...";

is($displayNameVal, "Peggy Olson", "getDisplayName: ...and return value is correct.");

lives_ok { $displayNameVal = $sp->getDisplayName($drapperId); }
  "getDisplayName: lives when valid id is given for someone who wants it...";

is($displayNameVal, "Donald Drapper", "getDisplayName: ...and return value is correct.");

lives_ok { $displayNameVal = $sp->getDisplayName($campbellId); }
  "getDisplayName: lives when valid id is given for someone who is undecided...";

is($displayNameVal, undef, "getDisplayName: ...and return value is correct.");


=item getLedgerEntityId

=cut

dies_ok { my $ledgerId = $sp->getLedgerEntityId(0); }
        "getLedgerEntityId: fails when rows are not returned but _verifyId() somehow passed";

# Replace _verifyId() to always return true

$overrideSub = Sub::Override->new( 'Supporters::_verifyId' => sub ($$) { return 1;} );
dies_ok { my $ledgerId = $sp->getLedgerEntityId(0); }
        "getLedgerEntityId: fails when rows are not returned but _verifyId() somehow passed";
$overrideSub->restore;

my $olsonLedgerEntity;
lives_ok { $olsonLedgerEntity = $sp->getLedgerEntityId($olsonId); }
  "getLedgerEntityId: lives when valid id is given...";

is($olsonLedgerEntity, "Olson-Margaret",  "getLedgerEntityId: ...and return value is correct.");

=item setPublicAck

=cut

dies_ok { $sp->setPublicAck(0); }        "setPublicAck: fails supporterId invalid";
dies_ok { $sp->setPublicAck("String"); } "setPublicAck: fails supporterId is string";
dies_ok {  $sp->setPublicAck(undef); }   "setPublicAck: fails supporterId is undef";

is($sp->getPublicAck($olsonId), 0, "setPublicAck: 1 failed calls changed nothing.");
is($sp->getPublicAck($drapperId), 1, "setPublicAck: 1 failed calls changed nothing.");
is($sp->getPublicAck($sterlingId), undef, "setPublicAck: 1 failed calls changed nothing.");

lives_ok { $sp->setPublicAck($olsonId, undef); }
  "setPublicAck: lives when valid id is given for undefining...";
is($sp->getPublicAck($olsonId), undef, "setPublicAck: ...and suceeds in changing value.");

lives_ok { $sp->setPublicAck($drapperId, 0); }
  "setPublicAck: lives when valid id is given for off...";
is($sp->getPublicAck($drapperId), 0, "setPublicAck: ...and suceeds in changing value.");

lives_ok { $sp->setPublicAck($sterlingId, 1); }
  "setPublicAck: lives when valid id is given for on...";
is($sp->getPublicAck($sterlingId), 1, "setPublicAck: ...and suceeds in changing value.");

=item addEmailAddress

=cut

$val = $sp->dbh()->selectall_hashref("SELECT id, name FROM address_type WHERE name = 'home'", 'name');

ok((defined $val and defined $val->{home}{id} and $val->{home}{id} > 0),
   "addSupporter/addEmailAddress: emailAddressType was added when new one given to addSupporter");

my $emailAddressTypeHomeId = $val->{home}{id};

dies_ok { $sp->addEmailAddress(undef, 'drapper@example.org', 'paypal'); }
        "addEmailAddress: dies for undefined id";
dies_ok { $sp->addEmailAddress("String", 'drapper@example.org', 'paypal'); }
        "addEmailAddress: dies for non-numeric id";
dies_ok { $sp->addEmailAddress($drapperId, undef, 'work') }
         "addEmailAddress: email address undefined fails";
dies_ok { $sp->addEmailAddress($drapperId, 'drapper@ex@ample.org', 'work') }
         "addEmailAddress: email address with extra @ fails to add.";

# Verify that the addressType wasn't added when the Email address is invalid
# and the address type did not already exist.

$val = $sp->dbh()->selectall_hashref("SELECT id, name FROM address_type WHERE name = 'work'", 'name');

ok((not defined $val or not defined $val->{'name'}),
   "addEmailAddress: type is not added with email address is bad");

my $sameOlsonId;
dies_ok { $sameOlsonId = $sp->addEmailAddress($olsonId, 'olson@example.net', 'paypal') }
         "addEmailAddress: fails adding existing email address with mismatched type.";

lives_ok { $sameOlsonId = $sp->addEmailAddress($olsonId, 'olson@example.net', 'home') }
         "addEmailAddress: succeeds when adding email that already exists...";

is($sameOlsonId, $olsonFirstEmailId, "addEmailAddress: ... and returns same id.");

my $drapperEmailId;

lives_ok { $drapperEmailId = $sp->addEmailAddress($drapperId, 'drapper@example.org', 'work') }
         "addEmailAddress: inserting a valid email address works";
ok((looks_like_number($drapperEmailId) and $drapperEmailId > 0), "addEmailAddress: id returned is sane.");

my $olsonEmailId2;

dies_ok { $olsonEmailId2 = $sp->addEmailAddress($olsonId, 'drapper@example.org', 'paypal') }
         "addEmailAddress: fails when adding the same email address for someone else, but as a different type";

my $drapperEmailId2;
lives_ok { $drapperEmailId2 = $sp->addEmailAddress($drapperId, 'everyone@example.net', 'paypal') }
         "addEmailAddress: inserting a second valid email address works";
ok((looks_like_number($drapperEmailId2) and $drapperEmailId2 > 0 and $drapperEmailId != $drapperEmailId2),
   "addEmailAddress: id returned is sane and is not same as previous id.");

lives_ok { $olsonEmailId2 = $sp->addEmailAddress($olsonId, 'everyone@example.net', 'paypal') }
         "addEmailAddress: binding known email address to another person works...";
ok((looks_like_number($olsonEmailId2) and $olsonEmailId2 > 0 and $olsonEmailId2 == $drapperEmailId2),
   "addEmailAddress: ... and id returned is sane and is same.");

=item addAddressType

=cut

#  This test cheats a bit -- it assumes that the database is assigning serials starting with 1

ok($sp->addAddressType('work') > $emailAddressTypeHomeId,
   "addEmailAddress: verify addEmailAddress added the addressType underneath");

dies_ok { $sp->addAddressType(undef); } "addAddressType: dies for undef";

my $paypalPayerAddressType;

ok($paypalPayerAddressType = $sp->addAddressType("paypal payer"), "addAddressType: basic add works");

my $same;

ok($same = $sp->addAddressType("paypal payer"), "addAddressType: lookup works");

ok($same == $paypalPayerAddressType, "addAddressType: lookup returns same as the basic add");

=item addEmailError

=cut

# Add an "undeliverable" delivery_error type

$val = 1;
lives_ok { $val =  $sp->_lookupDeliveryError("undeliverable"); },
  "_lookupDeliveryError: succeeds for unknown error ...";

is($val, undef, "_lookupDeliveryError: ... but returns undef");

my $sth = $sp->dbh->prepare("INSERT INTO delivery_error(error) VALUES(?)"); $sth->execute("undeliverable"); $sth->finish;
my $undeliverableId = $sp->dbh->last_insert_id("","","delivery_error","");

$val = -1;
lives_ok { $val =  $sp->_lookupDeliveryError("undeliverable"); },
  "_lookupDeliveryError: succeeds for known error ...";
is($val, $undeliverable, "_lookupDeliveryError: ... and returns proper id number");

dies_ok { $sp->addEmailError(undef); }
        "addEmailError: undef argument dies.";

dies_ok { $sp->addEmailError({}); }  "addEmailError: dies if donorId not specified.";

dies_ok { $sp->addEmailError({emailAddress => undef}); }  "addEmailError: dies if emailAddress is undef.";

$val = 1;
lives_ok { $val = $sp->addEmailError({emailAddress => 'nobody@example.com', errorCode => 'undeliverable', dateEncountered => '2017-11-22' }); }
  "addEmailError: succeeds to run if emailAddress not in database with all other valid args....";
is($val, undef, "... but returns undef in that situation.");

dies_ok { $sp->addEmailError({emailAddress => 'everyone@example.net', errorCode => 'invalidErrorcode',
                            dateEncountered => '2017-11-22' }); }
  "addEmailError: dies if errorCode given is invalid.";

$val = -1;
lives_ok { $val = $sp->addEmailError({emailAddress => 'everyone@example.net', errorCode => 'undeliverable', dateEncountered => '2017-11-22' })  }
  "addEmailError: succeeds when all options are valid but comment is missing";

is($val > 0,  "addEmailError: ... and returns a value greater than 0.");

$val = $sp->dbh()->selectrow_hashref("SELECT delivery_error_code_id, email_address_id, date_encountered, comments " .
                                        "FROM email_error_log  " .
                                        "WHERE email_address_id = " . $sp->dbh->quote($olsonEmailId2, 'SQL_INTEGER'));

ok((defined $val and defined $val->{email_address_id} and $val->{date_encountered} eq '2017-11-22'
    and not defined $val->{comments} and $val->{delivery_error_code_id} == $undeliverableId),
   "addSuporter: error log entry created without comment");

$val = -1;
lives_ok {$val = $sp->addEmailError({emailAddress => 'drapper@example.org', errorCode => 'undeliverable', dateEncountered => '2017-11-25', comments => "seems he has no email address" }) }
  "addEmailError: succeeds for valid email address and other options, including comment";

is($val > 0, "addEmailError: ... and returns > 0 in that situation.");

$val = $sp->dbh()->selectrow_hashref("SELECT delivery_error_code_id, email_address_id, date_encountered, comments " .
                                        "FROM email_error_log  " .
                                        "WHERE email_address_id = " . $sp->dbh->quote($drapperEmailId, 'SQL_INTEGER'));

ok((defined $val and defined $val->{email_address_id} and $val->{date_encountered} eq '2017-11-25'
    and $val->{comments} eq "seems he has no email address" and
    $val->{delivery_error_code_id} == $undeliverableId),
   "addSuporter: error log entry created with comment added");

=cut

=item addPostalAddress

=cut

dies_ok { $sp->addPostalAddress(undef, "405 Madison Avenue\nNew York, NY 10000\nUSA", 'office'); }
        "addPostalAddress: dies for undefined id";
dies_ok { $sp->addPostalAddress("String", "405 Madison Avenue\nNew York, NY 10000\nUSA", 'office'); }
        "addPostalAddress: dies for non-numeric id";
dies_ok { $sp->addPostalAddress($drapperId, undef, 'work') }
         "addPostalAddress: postal address undefined fails";

# Verify that the addressType wasn't added when the Email address is invalid
# and the address type did not already exist.

$val = $sp->dbh()->selectall_hashref("SELECT id, name FROM address_type WHERE name = 'office'", 'name');

ok((not defined $val or not defined $val->{'name'}),
   "addPostalAddress: type is not added when other input paramaters are invalid");

my $drapperPostalId;

lives_ok { $drapperPostalId = $sp->addPostalAddress($drapperId,
                                                    "405 Madison Avenue\nNew York, NY 10000\nUSA", 'office'); }
         "addPostalAddress: addPostalAddress of a valid formatted_address works.";
ok((looks_like_number($drapperPostalId) and $drapperPostalId > 0), "addPostalAddress: id returned is sane.");

=item addRequestType/getRequestType

=cut

dies_ok { $sp->addRequestType(undef); }
        "addRequestType: undef argument dies.";

my $tShirt0RequestTypeId;

ok( (not defined $sp->getRequestType('t-shirt-0')), "getRequestType: returns undef when not found");

lives_ok { $tShirt0RequestTypeId = $sp->addRequestType('t-shirt-0'); }
  "addRequestType: succeeds on add";

ok( (defined $tShirt0RequestTypeId and looks_like_number($tShirt0RequestTypeId) and $tShirt0RequestTypeId > 0),
    "addRequestType: id is a number");

my @allRequestsList = $sp->getRequestType();

is_deeply(\@allRequestsList, ['t-shirt-0' ], "getRequestType: no argument returns full list of request types (1)");

my $testSameRequestType;

lives_ok { $testSameRequestType = $sp->addRequestType('t-shirt-0'); }
  "addRequestType: succeeds on add when type already exists";

is $tShirt0RequestTypeId, $testSameRequestType,
    "addRequestType: lookup first of existing request type before adding.";

=item addRequestConfigurations

=cut

dies_ok { $sp->addRequestConfigurations(undef, undef); } "addRequestConfigurations: undef type dies";

is_deeply({ $tShirt0RequestTypeId => {} },
          $sp->addRequestConfigurations('t-shirt-0'),
          "addRequestConfigurations: existing requestType with no configuration yields same");

my @sizeList = qw/LadiesS LadiesM LadiesL LadiesXL MenS MenM MenL MenXL Men2XL/;

my $tShirt0Data;

dies_ok { $sp->addRequestConfigurations('t-shirt-1', [ @sizeList, 'Men2XL']) }
  "addRequestConfigurations: dies with duplicate items on configuration list.";

is($sp->{__NESTED_TRANSACTION_COUNTER__}, 0, "addRequestConfigurations: assure proper beginWork/commit matching.");

is_deeply($sp->getRequestConfigurations('t-shirt-1'), undef,
          "addRequestConfigurations/getRequestConfigurations: add fails with undefined configuration list");

lives_ok { $tShirt0Data = $sp->addRequestConfigurations('t-shirt-0', \@sizeList) }
  "addRequestConfigurations: existing requestType with configuration runs.";

is( keys %{$tShirt0Data}, ($tShirt0RequestTypeId),
    "addRequestConfigurations: reuses same requestTypeId on add of configurations");

is($sp->{__NESTED_TRANSACTION_COUNTER__}, 0, "addRequestConfigurations: assure proper beginWork/commit matching.");

my $cnt = 0;
foreach my $size (@sizeList) {
  ok( (defined $tShirt0Data->{$tShirt0RequestTypeId}{$size} and
       looks_like_number($tShirt0Data->{$tShirt0RequestTypeId}{$size}) and
       $tShirt0Data->{$tShirt0RequestTypeId}{$size} > 0),
      sprintf "addRequestConfigurations: item %d added correctly", $cnt++);
}


=item addRequest

=cut

dies_ok { $sp->addRequest({}); }  "addRequest: dies if donorId not specified.";

dies_ok { $sp->addRequest({ donorId => $drapperId }); }
        "addRequest: dies if requestTypeId / requestType not specified.";

dies_ok { $sp->addRequest({ donorId => 0, requestTypeId => $tShirt0RequestTypeId }); }
        "addRequest: dies if donorId invalid.";

dies_ok { $sp->addRequest({ donorId => $drapperId, requestTypeId => 0 }); }
        "addRequest: dies if requestTypeId invalid.";

is($sp->{__NESTED_TRANSACTION_COUNTER__}, 0, "addRequest: assure proper beginWork/commit matching.");

my $emailListRequestId;

lives_ok { $emailListRequestId =
             $sp->addRequest({ donorId => $drapperId, requestType => "join-announce-email-list" }); }
        "addRequest: succeeds with a requestType but no configuration parameter.";

ok( (defined $emailListRequestId and looks_like_number($emailListRequestId) and $emailListRequestId > 0),
    "addRequest: id returned on successful addRequest() is a number");

my $joinEmailListRequestId = $sp->getRequestType("join-announce-email-list");
ok((defined $joinEmailListRequestId and looks_like_number($joinEmailListRequestId) and $joinEmailListRequestId > 0),
   "addRequest: underlying call to addRequestType works properly, per getRequestType");

@allRequestsList = $sp->getRequestType();

is_deeply(\@allRequestsList, ['t-shirt-0', 'join-announce-email-list'],
          "getRequestType: no argument returns full list of request types (2)");

my $tshirtSmallRequestId;

lives_ok { $tshirtSmallRequestId =
             $sp->addRequest({ donorId => $drapperId, requestType => "t-shirt-small-only",
                               requestConfiguration => 'Small',
                               notes => 'he probably needs a larger size but this shirt has none'}); }
        "addRequest: succeeds with a requestType and requestConfiguration and a note.";

ok( (defined $tshirtSmallRequestId and looks_like_number($tshirtSmallRequestId) and $tshirtSmallRequestId > 0),
    "addRequest: successful call returns an integer id.");

@allRequestsList = $sp->getRequestType();

is_deeply(\@allRequestsList, ['t-shirt-0', 'join-announce-email-list', 't-shirt-small-only' ],
          "getRequestType: no argument returns full list of request types (3)");

my $tShirt0RequestId;

lives_ok { $tShirt0RequestId =
             $sp->addRequest({ donorId => $drapperId, requestTypeId => $tShirt0RequestTypeId,
                               requestConfigurationId => $tShirt0Data->{$tShirt0RequestTypeId}{'MenL'} }); }
        "addRequest: succeeds with a requestTypeId and requestConfigurationId with no a note.";

ok( (defined $tShirt0RequestId and looks_like_number($tShirt0RequestId) and $tShirt0RequestId > 0),
    "addRequest: another successful call returns an integer id.");

my $olsonTShirtRequest;

lives_ok { $olsonTShirtRequest =
             $sp->addRequest({ donorId => $olsonId, requestTypeId => $tShirt0RequestTypeId,
                               requestConfigurationId => $tShirt0Data->{$tShirt0RequestTypeId}{'LadiesXL'} }); }
        "addRequest: different donor succeeds with a requestTypeId and requestConfigurationId with no a note....";

ok( (defined $olsonTShirtRequest and looks_like_number($olsonTShirtRequest) and $olsonTShirtRequest > 0
    and $olsonTShirtRequest != $tShirt0RequestTypeId and $olsonTShirtRequest != $tshirtSmallRequestId),
    "addRequest: ... and successful call returns an integer id that's different from others.");

=item holdRequest

=cut

my $drapperTShirt0HoldId;
my $newHoldId;

dies_ok { $drapperTShirt0HoldId = $sp->holdRequest(requestType => "t-shirt-0", who => 'joe',
                                                    heldBecause => "will see him soon and give t-shirt in person" ); }
     "holdRequest: dies if donorId not specified";

dies_ok { $drapperTShirt0HoldId = $sp->holdRequest(donorId => $drapperId + 1000,
                                            requestType => "t-shirt-0", who => 'joe',
                                            heldBecause => "will see him soon and give t-shirt in person"); }
     "holdRequest: dies if donorId not found in database";

dies_ok { $drapperTShirt0HoldId = $sp->holdRequest(donorId => $drapperId,  who => 'joe',
                                                    heldBecause => "in-person delivery" ); }
     "holdRequest: dies if requestType not specified";

dies_ok { $drapperTShirt0HoldId = $sp->holdRequest( { donorId => $drapperId,
                                                   requestType => "t-shirt-0",
                                                    heldBecause => "in-person delivery" }); }
     "holdRequest: dies if who not specified";

lives_ok { $drapperTShirt0HoldId = $sp->holdRequest( { donorId => $drapperId,
                                            requestType => "t-shirt-0", who => 'joe', holdReleaseDate => '9999-12-31',
                                                    heldBecause => "in-person delivery planned" }); }
     "holdRequest: succeeds for existing request...";

ok( (defined $drapperTShirt0HoldId and looks_like_number($drapperTShirt0HoldId) and $drapperTShirt0HoldId > 0),
    "holdRequest: ... and id returned on successful holdRequest() is a number");

lives_ok { $val = $sp->dbh()->selectall_hashref("SELECT id, hold_date, release_date, who, request_id, why FROM request_hold", 'id'); }
         "holdRequest: sql command in  database for entry succeeds.";
is_deeply($val, { $drapperTShirt0HoldId => { id => $drapperTShirt0HoldId, hold_date => $today,
                                             release_date => '9999-12-31',
                                             why => 'in-person delivery planned', who => 'joe',
                                         request_id => $tShirt0RequestId } },
          "holdRequest: database entry from successful return is correct");

my $badHold;
lives_ok { $badHold = $sp->holdRequest( { donorId => $drapperId, who => 'john', holdReleaseDate => '1983-01-05',
                                                   requestType => "does-not-exist",
                                                    heldBecause => "in-person delivery" }); }
     "holdRequest: attempt to hold a request never made does not die...";

ok( (not defined $badHold),
     "holdRequest: ... but, rather, returns undef.");

is($sp->getRequestType("does-not-exist"), undef,
     "holdRequest: requestType not created when holdRequest fails.");

my $reHoldId;

# FIXME: Do the following two tests really exhibit the behavior we actually
#        want?  The API caller might be receiving unexpected results here,
#        because as the two tests below show, it's possible, when attempting
#        to hold a request that is already held, that you're returned an id
#        for a hold that has different details (other than the requestType,
#        of course).
 

lives_ok { $reHoldId = $sp->holdRequest( { donorId => $drapperId, holdReleaseDate => '2112-05-15',
                                            requestType => "t-shirt-0", who => 'peggy',
                                                    heldBecause => "will leave in his office." }); }
     "holdRequest: attempt to hold an already-held request lives ...";

is_deeply($reHoldId, $drapperTShirt0HoldId, "holdRequest: ... but returns the id of the old hold request.");
my $holdRequest;

lives_ok { $newHoldId = $sp->holdRequest( { donorId => $olsonId, holdReleaseDate => '2048-05-15',
                                            requestTypeId => $tShirt0RequestTypeId, who => 'john',
                                                    heldBecause => "will delivery at conference" }); }
     "holdRequest: succeeds for existing request, using requestTypeId";

ok( (defined $newHoldId and looks_like_number($newHoldId) and $newHoldId > 0 and ($newHoldId != $drapperTShirt0HoldId)),
    "holdRequest: id returned on successful holdRequest() is a number and is not the one returned by previous");


=item fulfillRequest

=cut


my $fulfillRequestId;


dies_ok { $fulfillRequestId = $sp->fulfillRequest( { requestType => "t-shirt-small-only", who => 'joe',
                                                    how => "in-person delivery" }); }
     "fulfillRequest: dies if donorId not specified";

dies_ok { $fulfillRequestId = $sp->fulfillRequest( { donorId => $drapperId + 1000,
                                            requestType => "t-shirt-small-only", who => 'joe',
                                                    how => "in-person delivery" }); }
     "fulfillRequest: dies if donorId not found in database";

dies_ok { $fulfillRequestId = $sp->fulfillRequest( { donorId => $drapperId,  who => 'joe',
                                                    how => "in-person delivery" }); }
     "fulfillRequest: dies if requestType not specified";

dies_ok { $fulfillRequestId = $sp->fulfillRequest( { donorId => $drapperId,
                                                   requestType => "t-shirt-small-only",
                                                    how => "in-person delivery" }); }
     "fulfillRequest: dies if who not specified";

my $req;
lives_ok { $req = $sp->getRequest({donorId => $drapperId, requestType => "t-shirt-small-only" }); }
        "getRequest: success after failed fulfillRequest attempts...";

is($req->{requestType}, "t-shirt-small-only", "getRequest: ... with correct type");
is($req->{requestDate}, $today, "getRequest: ... and correct request date.");
is($req->{fulfillDate}, undef, "getRequest: ... but no fulfillDate.");

lives_ok { $fulfillRequestId = $sp->fulfillRequest( { donorId => $drapperId,
                                            requestType => "t-shirt-small-only", who => 'joe',
                                                    how => "in-person delivery" }); }
     "fulfillRequest: succeeds for existing request";

ok( (defined $fulfillRequestId and looks_like_number($fulfillRequestId) and $fulfillRequestId > 0),
    "fulfillRequest: id returned on successful fulfillRequest() is a number");

lives_ok { $val = $sp->dbh()->selectall_hashref("SELECT id, date, who, how, request_id FROM fulfillment", 'id'); }
         "fulfillRequest: sql command in  database for entry succeeds.";
is_deeply($val, { $fulfillRequestId => { id => $fulfillRequestId, date => $today,
                                         how => 'in-person delivery', who => 'joe',
                                         request_id => $tshirtSmallRequestId } },
          "fulfillRequest: databse entry from successful return is correct");

my $badFR;
lives_ok { $badFR = $sp->fulfillRequest( { donorId => $drapperId, who => 'john',
                                                   requestType => "does-not-exist",
                                                    how => "in-person delivery" }); }
     "fulfillRequest: attempt to fulfill a request never made does not die...";

ok( (not defined $badFR),
     "fulfillRequest: ... but, rather, returns undef.");

is($sp->getRequestType("does-not-exist"), undef,
     "fulfillRequest: requestType not created when fulfillRequest fails.");


my $lookedUpFulfillmentId;

lives_ok { $lookedUpFulfillmentId = $sp->fulfillRequest( { donorId => $drapperId,
                                            requestType => "t-shirt-small-only", who => 'peggy',
                                                    how => "left in his office." }); }
     "fulfillRequest: attempt to fulfill an already-fulfill request does not die ...";

is($lookedUpFulfillmentId, $fulfillRequestId,
     "fulfillRequest: ... but, rather, returns the same value from the previous fulfillRequest() call.");


my $newFRID;
lives_ok { $newFRID = $sp->fulfillRequest( { donorId => $drapperId,
                                            requestTypeId => $tShirt0RequestTypeId, who => 'john',
                                                    how => "mailed" }); }
     "fulfillRequest: returns properly for an existing request, using requestTypeId for lookup, when the request his held...";

is($newFRID, undef, "fulfillRequest: .... but undef is returned when attempting to fulfill a held request.");

=item getRequest

=cut

dies_ok { $sp->getRequest({} ); }  "getRequest: dies if donorId not specified.";

dies_ok { $sp->getRequest({ donorId => 0, requestType => "t-shirt-small-only" }); } "getRequest: dies if donorId invalid.";

dies_ok { $sp->getRequest({ donorId => $drapperId, requestType => undef}); }
        "getRequest: dies if requestType not specified.";

my $tt;
lives_ok { $tt = $sp->getRequest({ donorId => $drapperId, requestType => 'this-one-is-not-there' }); }
        "getRequest: returns normally with non-existent request.";

is($tt, undef, "getRequest: returns undef for valid supporter and on-existent request.");

lives_ok { $tt = $sp->getRequest({donorId => $drapperId, requestType => 't-shirt-small-only' }); }
         "getRequest: succeeds with valid parameters, using requestType.";

is($tt->{requestType}, 't-shirt-small-only', "getRequest: requestType is correct.");
is($tt->{fulfillDate}, $today, "getRequest: fulfilled request is today.");
is($tt->{requestDate}, $today, "getRequest: request date is today.");
is($tt->{requestConfiguration}, 'Small', "getRequest: configuration is correct.");
is($tt->{notes}, 'he probably needs a larger size but this shirt has none',
   "getRequest: notes are correct.");

lives_ok { $tt = $sp->getRequest({donorId => $drapperId, requestType => 't-shirt-small-only', ignoreFulfilledRequests => 1}); }
         "getRequest: succeeds for lookup criteria that are known to return nothing ....";

is($tt, undef, 'getRequest: .... and undef is indeed returned');

lives_ok { $tt = $sp->getRequest({donorId => $drapperId, requestTypeId => $tShirt0RequestTypeId } ); }
         "getRequest: succeeds with valid parameters, using requestTypeId.";

is($tt->{requestType}, 't-shirt-0', "getRequest: requestType is correct.");
is($tt->{requestDate}, $today, "getRequest: request date is today.");
is($tt->{requestConfiguration}, 'MenL', "getRequest: configuration is correct.");
is($tt->{holdReleaseDate}, '9999-12-31', "getRequest: releaseDate is correct.");
is($tt->{holdDate}, $today, "getRequest: holdDate is correct.");
is($tt->{holder}, 'joe', "getRequest: holder is correct.");
is($tt->{heldBecause}, 'in-person delivery planned', "getRequest: heldBecause is correct.");
is($tt->{notes}, undef,    "getRequest: notes are undef when null in database.");

lives_ok { $tt = $sp->getRequest({donorId => $drapperId, requestTypeId => $tShirt0RequestTypeId,
                                  ignoreHeldRequests => 1}); }
         "getRequest: succeeds for lookup criteria, including ignoreHeldRequests, that are known to return nothing ....";
is($tt, undef, 'getRequest: .... and undef is indeed returned');


lives_ok { $tt = $sp->getRequest({ donorId => $drapperId,  requestType => "join-announce-email-list" }); }
         "getRequest: succeeds with valid parameters.";

is($tt->{requestType}, "join-announce-email-list", "getRequest: requestType is correct.");
is($tt->{requestDate}, $today, "getRequest: request date is today.");
is($tt->{requestConfiguration}, undef, "getRequest: configuration is undefined when there is none.");
is($tt->{notes}, undef,    "getRequest: notes are undef when null in database.");


=item releaseRequestHold

=cut

my $releasedHoldId;

lives_ok { $releasedHoldId = $sp->releaseRequestHold({ donorId => $drapperId, requestType => 't-shirt-0' }); }
  "releaseRequestHold: release of a known held request succeeds...";
is($releasedHoldId, $drapperTShirt0HoldId, "releaseRequestHold: ... & returns same hold id as holdRequest() call did");
lives_ok { $req = $sp->getRequest({ donorId => $drapperId, requestType => 't-shirt-0'}) }
  "releaseRequestHold: lookup of request after release succeeds....";
is($req->{holdReleaseDate}, $today, "... and the release date is today.");

lives_ok { $releasedHoldId = $sp->releaseRequestHold({ donorId => $drapperId, requestType => 't-shirt-0' }); }
  "releaseRequestHold: release again of the same a hold request also succeeds...";
is($releasedHoldId, $drapperTShirt0HoldId, "releaseRequestHold: ... & also returns same hold id as holdRequest() call did");
lives_ok { $req = $sp->getRequest({ donorId => $drapperId, requestType => 't-shirt-0'}) }
  "releaseRequestHold: lookup of request after second release succeeds....";
is($req->{holdReleaseDate}, $today, "... and the release date is still set to today.");


lives_ok { $newFRID = $sp->fulfillRequest( { donorId => $drapperId,
                                            requestTypeId => $tShirt0RequestTypeId, who => 'john',
                                                    how => "mailed" }); }
     "fulfillRequest: succeeds once the request is no longer on hold...";

ok( (defined $newFRID and looks_like_number($newFRID) and $newFRID > 0 and ($newFRID != $fulfillRequestId)),
    "....id returned on successful fulfillRequest() is a number and is not the one returned by previous");

lives_ok { $tt = $sp->getRequest({donorId => $drapperId, requestTypeId => $tShirt0RequestTypeId } ); }
         "getRequest: succeeds with valid parameters, using requestTypeId.";

is($tt->{requestType}, 't-shirt-0', "getRequest: requestType is correct.");
is($tt->{requestDate}, $today, "getRequest: request date is today.");
is($tt->{requestConfiguration}, 'MenL', "getRequest: configuration is correct.");
is($tt->{holdReleaseDate}, $today, "getRequest: holdReleaseDate is correct.");
is($tt->{holdDate}, $today, "getRequest: holdDate is correct.");
is($tt->{holder}, 'joe', "getRequest: holder is correct.");
is($tt->{heldBecause}, 'in-person delivery planned', "getRequest: heldBecause is correct.");
is($tt->{fulfillDate}, $today, "getRequest: fulfilled request is today.");
is($tt->{notes}, undef,    "getRequest: notes are undef when null in database.");

=item getRequestConfigurations

=cut

my $tShirtSmallOnlyRequestId;
lives_ok { $tShirtSmallOnlyRequestId = $sp->getRequestType('t-shirt-small-only'); }
  "addRequest: added request type";

my $tShirtSmallOnlyData = $sp->getRequestConfigurations('t-shirt-small-only');

is(scalar keys %{$tShirtSmallOnlyData->{$tShirtSmallOnlyRequestId}}, 1,
   "addRequest: just one configuration added correctly");

ok( (defined $tShirtSmallOnlyData->{$tShirtSmallOnlyRequestId}{'Small'} and
       looks_like_number($tShirtSmallOnlyData->{$tShirtSmallOnlyRequestId}{'Small'}) and
       $tShirtSmallOnlyData->{$tShirtSmallOnlyRequestId}{'Small'} > 0),
      "addRequest: configuration added correctly");

is undef, $sp->getRequestConfigurations(undef), "getRequestConfigurations: undef type returns undef";

is undef, $sp->getRequestConfigurations('Hae2Ohlu'), "getRequestConfigurations: non-existent type returns undef";

is_deeply $tShirt0Data,
          $sp->getRequestConfigurations('t-shirt-0'),
          "getRequestConfigurations: lookup of previously added items is same";


=item setPreferredEmailAddress/getPreferredEmailAddress

=cut

dies_ok { $sp->setPreferredEmailAddress(undef, 'drapper@example.org'); }
        "setPreferredEmailAddress: dies for undefined id";
dies_ok { $sp->setPreferredEmailAddress("String", 'drapper@example.org'); }
        "setPreferredEmailAddress: dies for non-numeric id";
dies_ok { $sp->setPreferredEmailAddress($drapperId, undef) }
         "setPreferredEmailAddress: email address undefined fails";
dies_ok { $sp->setPreferredEmailAddress($drapperId, 'drapper@ex@ample.org') }
         "setPreferredEmailAddress: email address with extra @ fails to add.";

dies_ok { $sp->getPreferredEmailAddress(undef); }
        "getPreferredEmailAddress: dies for undefined id";
dies_ok { $sp->getPreferredEmailAddress("String"); }
        "getPreferredEmailAddress: dies for non-numeric id";

my $ret;

lives_ok { $ret = $sp->setPreferredEmailAddress($drapperId, 'drapper@example.com') }
         "setPreferredEmailAddress: email address not found in database does not die....";
is($ret, undef, "setPreferredEmailAddress: ....but returns undef");

lives_ok { $ret = $sp->getPreferredEmailAddress($drapperId) }
         "getPreferredEmailAddress: no preferred does not die....";
is($ret, undef, "getPreferredEmailAddress: ....but returns undef");

lives_ok { $ret = $sp->setPreferredEmailAddress($drapperId, 'drapper@example.org') }
         "setPreferredEmailAddress: setting preferred email address succeeds....";

ok( (defined $ret and looks_like_number($ret) and $ret == $drapperEmailId),
      "setPreferredEmailAddress: ... and returns correct email_address_id on success");

is($sp->{__NESTED_TRANSACTION_COUNTER__}, 0, "setPreferredEmailAddress: assure proper beginWork/commit matching.");

lives_ok { $ret = $sp->getPreferredEmailAddress($drapperId) }
         "getPreferredEmailAddress: lookup of known preferred email address succeeds... ";
is($ret, 'drapper@example.org', "getPreferredEmailAddress: ....and returns the correct value.");

=item getEmailAddresses

=cut

my %emailAddresses;

dies_ok { %emailAddresses = $sp->getEmailAddresses(0); }
        "getEmailAddresses: fails with 0 donorId";

dies_ok { %emailAddresses = $sp->getEmailAddresses("String"); }
        "getEmailAddresses: fails with string donorId";

dies_ok { %emailAddresses = $sp->getEmailAddresses(undef); }
        "getEmailAddresses: fails with string donorId";

lives_ok { %emailAddresses = $sp->getEmailAddresses($olsonId); }
         "getEmailAddresses: 1 lookup of addresses succeeds...";

is_deeply(\%emailAddresses, {'everyone@example.net' => { 'date_encountered' => $today, 'name' => 'paypal' },
                            'olson@example.net' => { 'date_encountered' => $today, 'name' => 'home' }},
          "getEmailAddresses: ... and returns correct results.");

lives_ok { %emailAddresses = $sp->getEmailAddresses($drapperId); }
         "getEmailAddresses: 2 lookup of addresses succeeds...";

is_deeply(\%emailAddresses, {'everyone@example.net' => { 'date_encountered' => $today, 'name' => 'paypal' },
                            'drapper@example.org' => { 'date_encountered' => $today, 'name' => 'work' }},
          "getEmailAddresses: ... and returns correct results.");

lives_ok { %emailAddresses = $sp->getEmailAddresses($sterlingId); }
         "getEmailAddresses: 3 lookup of addresses succeeds...";

is_deeply(\%emailAddresses, {'sterlingjr@example.com' => { 'name' => 'home', 'date_encountered' => $today }},
          "getEmailAddresses: ... and returns correct results.");

lives_ok { %emailAddresses = $sp->getEmailAddresses($campbellId); }
         "getEmailAddresses:  lookup of *empty* addresses succeeds...";

is_deeply(\%emailAddresses, {},
          "getEmailAddresses: ... and returns correct results.");


=item setPreferredEmailAddress/getPreferredEmailAddress

=cut

=item getPostalAddress

=cut

# Add additional postal address.

my $drapperHomePostalId;

lives_ok { $drapperHomePostalId = $sp->addPostalAddress($drapperId,
                                                    "112 Main Street \nLong Island, NY 11000\nUSA", 'home'); }
         "addPostalAddress: addPostalAddress of a valid formatted_address works.";
ok((looks_like_number($drapperHomePostalId) and $drapperHomePostalId > 0), "addPostalAddress: id returned is sane.");

# Force home address to have an old date

$dbh->do("UPDATE postal_address SET date = '1000-01-01' WHERE id = " . $sp->dbh->quote($drapperHomePostalId));



=item findDonor

=cut

my @lookupDonorIds;

lives_ok { @lookupDonorIds = $sp->findDonor({}); }
        "findDonor: no search criteria succeeds and...";

my(%vals);
@vals{@lookupDonorIds} = @lookupDonorIds;

is_deeply(\%vals, { $campbellId => $campbellId, $sterlingId => $sterlingId, $harrisId => $harrisId,
                    $olsonId => $olsonId, $drapperId => $drapperId },
          "findDonor: ... and returns all donorIds.");

lives_ok { @lookupDonorIds = $sp->findDonor({ledgerEntityId => "NotFound" }); }
        "findDonor: 1 lookup of known missing succeeds ...";

is(scalar(@lookupDonorIds), 0, "findDonor: ... but finds nothing.");

lives_ok { @lookupDonorIds = $sp->findDonor({emailAddress => "nothingthere" }); }
        "findDonor: 2 lookup of known missing succeeds ...";

is(scalar(@lookupDonorIds), 0, "findDonor: ... but finds nothing.");

lives_ok { @lookupDonorIds = $sp->findDonor({emailAddress => 'drapper@example.org', ledgerEntityId => "NOTFOUND" }); }
       "findDonor: 1 and'ed criteria succeeds   ...";

is(scalar(@lookupDonorIds), 0, "findDonor: ... but finds nothing.");

lives_ok { @lookupDonorIds = $sp->findDonor({emailAddress => 'NOTFOUND', ledgerEntityId => "Whitman-Dick" }); }
       "findDonor: 2 and'ed criteria succeeds   ...";

is(scalar(@lookupDonorIds), 0, "findDonor: ... but finds nothing.");

lives_ok { @lookupDonorIds = $sp->findDonor({emailAddress => 'drapper@example.org', ledgerEntityId => "Whitman-Dick" }); }
       "findDonor: 1 valid multiple criteria succeeds   ...";

is_deeply(\@lookupDonorIds, [$drapperId], "findDonor: ... and finds right entry.");

lives_ok { @lookupDonorIds = $sp->findDonor({emailAddress => 'everyone@example.net', ledgerEntityId => "Whitman-Dick" }); }
       "findDonor: 2 valid multiple criteria succeeds   ...";

is_deeply(\@lookupDonorIds, [$drapperId], "findDonor: ... and finds right entry.");

lives_ok { @lookupDonorIds = $sp->findDonor({emailAddress => 'everyone@example.net', ledgerEntityId => "Olson-Margaret" }); }
       "findDonor: 3 valid multiple criteria succeeds   ...";

is_deeply(\@lookupDonorIds, [$olsonId], "findDonor: ... and finds right entry.");

lives_ok { @lookupDonorIds = $sp->findDonor({emailAddress => 'everyone@example.net'}); }
       "findDonor: single criteria find expecting multiple records succeeds...";

%vals = ();
@vals{@lookupDonorIds} = @lookupDonorIds;

is_deeply(\%vals, { $olsonId => $olsonId, $drapperId => $drapperId }, "findDonor: ... and finds the right entires.");



=item donorLastGave

=cut

dies_ok { $sp->donorLastGave(undef); } "donorLastGave(): dies with undefined donorId";
dies_ok { $sp->donorLastGave("str"); } "donorLastGave(): dies with non-numeric donorId";
dies_ok { $sp->donorLastGave(0);     } "donorLastGave(): dies with non-existent id";

my $date;

lives_ok { $date = $sp->donorLastGave($drapperId) } "donorLastGave(): check for known annual donor success...";

is($date, '2015-05-04',  "donorLastGave(): ...and returned value is correct. ");

lives_ok { $date = $sp->donorLastGave($olsonId) } "donorLastGave(): check for known monthly donor success...";

is($date, '2015-06-30', "donorLastGave(): ...and returned value is correct. ");

=item donorFirstGave

=cut

dies_ok { $sp->donorFirstGave(undef); } "donorFirstGave(): dies with undefined donorId";
dies_ok { $sp->donorFirstGave("str"); } "donorFirstGave(): dies with non-numeric donorId";
dies_ok { $sp->donorFirstGave(0);     } "donorFirstGave(): dies with non-existent id";

lives_ok { $date = $sp->donorFirstGave($drapperId) } "donorFirstGave(): check for known annual donor success...";

is($date, '2015-02-26',  "donorFirstGave(): ...and returned value is correct. ");

lives_ok { $date = $sp->donorFirstGave($olsonId) } "donorFirstGave(): check for known monthly donor success...";

is($date, '2015-01-15', "donorFirstGave(): ...and returned value is correct. ");

=item donorTotalGaveInPeriod

=cut

dies_ok { $sp->donorTotalGaveInPeriod(donorId => undef); } "donorTotalGaveInPeriod(): dies with undefined donorId";
dies_ok { $sp->donorTotalGaveInPeriod(donorId => "str"); } "donorTotalGaveInPeriod(): dies with non-numeric donorId";
dies_ok { $sp->donorTotalGaveInPeriod(donorId => 0);     } "donorTotalGaveInPeriod(): dies with non-existent id";

foreach my $arg (qw/startDate endDate/) {
  dies_ok { $sp->donorTotalGaveInPeriod(donorId => $drapperId, $arg => '2015-1-5'); }
    "donorTotalGaveInPeriod():  dies with non ISO-8601 string in $arg";
}
dies_ok { $sp->donorTotalGaveInPeriod(donorId => $drapperId, wrong => ''); }
  "donorTotalGaveInPeriod(): dies if given an argument that is not recognized";

my $amount;

lives_ok { $amount = $sp->donorTotalGaveInPeriod(donorId => $drapperId) }
   "donorTotalGaveInPeriod(): total for a donor with no period named succeeds...";

is($amount, 305.00,  "donorTotalGaveInPeriod(): ...and returned value is correct. ");

lives_ok { $amount = $sp->donorTotalGaveInPeriod(donorId => $olsonId, startDate => '2015-02-17',
                                               endDate => '2015-06-29') }
         "donorTotalGaveInPeriod(): check for total with both start and end date succeeds...";

is($amount, 30.00,  "donorTotalGaveInPeriod(): ...and returned value is correct. ");

lives_ok { $amount = $sp->donorTotalGaveInPeriod(donorId => $harrisId, startDate => '2015-12-04'); }
         "donorTotalGaveInPeriod(): check for total with just a start date succeeds...";

is($amount, 120.00,  "donorTotalGaveInPeriod(): ...and returned value is correct. ");

lives_ok { $amount = $sp->donorTotalGaveInPeriod(donorId => $olsonId, endDate => '2015-02-16'); }
         "donorTotalGaveInPeriod(): check for total with just a end date succeeds...";

is($amount, 20.00,  "donorTotalGaveInPeriod(): ...and returned value is correct. ");

=item donorDonationOnDate

# FIXME: way to lookup donation on a date.

=cut

=item supporterExpirationDate

=cut

dies_ok { $sp->supporterExpirationDate(undef); } "supporterExpirationDate(): dies with undefined donorId";
dies_ok { $sp->supporterExpirationDate("str"); } "supporterExpirationDate(): dies with non-numeric donorId";
dies_ok { $sp->supporterExpirationDate(0);     } "supporterExpirationDate(): dies with non-existent id";

lives_ok { $date = $sp->supporterExpirationDate($drapperId) } "supporterExpirationDate(): check for known annual donor success...";

is($date, '2016-02-26',  "supporterExpirationDate(): ...and returned value is correct. ");

lives_ok { $date = $sp->supporterExpirationDate($olsonId) } "supporterExpirationDate(): check for known monthly donor success...";

is($date, '2015-08-29', "supporterExpirationDate(): ...and returned value is correct. ");

lives_ok { $date = $sp->supporterExpirationDate($sterlingId) } "supporterExpirationDate(): check for never donation success...";

is($date, undef, "supporterExpirationDate(): ...and returned undef.");

lives_ok { $date = $sp->supporterExpirationDate($harrisId) } "supporterExpirationDate(): same donation amount in year...";

is($date, '2016-12-04', "supporterExpirationDate(): ...returns the latter date.");

$dbh->do("UPDATE donor SET is_supporter = 0 WHERE id = " . $sp->dbh->quote($campbellId));

lives_ok { $date = $sp->supporterExpirationDate($campbellId) } "supporterExpirationDate(): check for no supporter success...";

is($date, undef, "supporterExpirationDate(): ...and returned undef.");

=back

=item Internal methods used only by the module itself.

=over

=item _verifyId

=cut

ok( $sp->_verifyId($drapperId), "_verifyId: id just added exists");

dies_ok { $sp->_verifyId(undef); } "_verifyId: dies for undefined id";
dies_ok { $sp->_verifyId("String") } "_verifyId: dies for non-numeric id";

# This is a hacky way to test this; but should work
ok(not ($sp->_verifyId($drapperId + 10)), "_verifyId: non-existent id is not found");

=item _lookupEmailAddress

=cut

dies_ok { $sp->_lookupEmailAddress(undef); } "_lookupEmailAddressId: dies for undefined email_address";

is_deeply($sp->_lookupEmailAddress('drapper@example.org'),
          { emailAddress => 'drapper@example.org', id => $drapperEmailId, type => 'work', dateEncountered => $today },
    "_lookupEmailAddressId: 1 returns email Id for known item");

is_deeply($sp->_lookupEmailAddress('everyone@example.net'),
          { emailAddress => 'everyone@example.net', id => $olsonEmailId2, type => 'paypal', dateEncountered => $today },
    "_lookupEmailAddressId: 2 returns email id for known item");

is($sp->_lookupEmailAddress('drapper@example.com'), undef,
    "_lookupEmailAddressId: returns undef for unknown item.");

$sp = undef;

sub ResetDB($) {
  $_[0]->disconnect() if defined $_[0];
  my $tempDBH = get_test_dbh();
  my $tempSP = new Supporters($tempDBH, [ "testcmd" ]);
  return ($tempDBH, $tempSP);
}

my($tempDBH, $tempSP) = ResetDB($dbh);

=item _getOrCreateRequestType

=cut

dies_ok { $tempSP->_getOrCreateRequestType({ }); }
   "_getOrCreateRequestType: dies on empty hash";

dies_ok { $tempSP->_getOrCreateRequestType({ requestTypeId => "NoStringsPlease" }); }
   "_getOrCreateRequestType: dies for string request id";

dies_ok { $tempSP->_getOrCreateRequestType({ requestTypeId => 0 }); }
   "_getOrCreateRequestType: dies for non-existant requestTypeId";

my %hh = ( requestType => 'test-request' );
lives_ok { $tempSP->_getOrCreateRequestType(\%hh); }
   "_getOrCreateRequestType: succeeds with just requestType";

my $rr;
lives_ok { $rr = $tempSP->getRequestType("test-request"); }
   "_getOrCreateRequestType: lookup of a request works after _getOrCreateRequestType";

is_deeply(\%hh, { requestTypeId => $rr },
   "_getOrCreateRequestType: lookup of a request works after _getOrCreateRequestType");

%hh = ( requestTypeId => $rr, requestType => 'this-arg-matters-not' );

lives_ok { $tempSP->_getOrCreateRequestType(\%hh); }
   "_getOrCreateRequestType: lookup of existing requestType suceeds.";

is_deeply(\%hh, { requestTypeId => $rr },
   "_getOrCreateRequestType: deletes requestType if both are provided.");

dies_ok { $tempSP->_lookupRequestTypeById(undef); }
        "_lookupRequestTypeById: dies for undefined requestTypeId";

dies_ok { $tempSP->_lookupRequestTypeById("NoStringsPlease"); }
        "_lookupRequestTypeById: dies for a string requestTypeId";

ok( (not $tempSP->_lookupRequestTypeById(0)), "_lookupRequestTypeById: returns false for id lookup for 0");

# Assumption here: that id number one more than the last added would never be in db.
ok( (not $tempSP->_lookupRequestTypeById($rr + 1)),
    "_lookupRequestTypeById: returns false for id one greater than last added");

is($tempSP->_lookupRequestTypeById($rr), "test-request",
    "_lookupRequestTypeById: returns proper result for id known to be in database");

=item _getOrCreateRequestConfiguration

=cut

dies_ok { $tempSP->_getOrCreateRequestConfiguration({ }); }
   "_getOrCreateRequestConfiguration: dies on empty hash";

dies_ok { $tempSP->_getOrCreateRequestConfiguration({ requestConfigurationId => "NoStringsPlease" }); }
   "_getOrCreateRequestConfiguration: dies for string requestConfigurationId";

dies_ok { $tempSP->_getOrCreateRequestConfiguration({ requestConfigurationId => 0 }); }
   "_getOrCreateRequestConfiguration: dies for non-existant requestConfigurationId";

dies_ok { $tempSP->_getOrCreateRequestConfiguration({ requestTypeId => "NoStringsPlease" }); }
   "_getOrCreateRequestConfiguration: dies for string request id";

dies_ok { $tempSP->_getOrCreateRequestConfiguration({ requestTypeId => 0 }); }
   "_getOrCreateRequestConfiguration: dies for non-existant requestTypeId";

dies_ok { $tempSP->_getOrCreateRequestConfiguration({ requestTypeId => $rr,
                                                      requestConfigurationId => "NoStringsPlease" }); }
   "_getOrCreateRequestConfiguration: dies for string requestConfigurationId with valid requestTypeId";

%hh = ( requestConfiguration => 'test-request-config' );
dies_ok { $tempSP->_getOrCreateRequestConfiguration(\%hh); }
   "_getOrCreateRequestConfiguration: fails with just requestConfiguration.";

$val = $tempSP->dbh()->selectall_hashref("SELECT id, description FROM request_configuration", 'description');

ok((defined $val and (keys(%$val) == 0)),
   "_getOrCreateRequestConfiguration: no request_configuration record added for failed attempts");

%hh = ( requestTypeId => $rr, requestConfiguration => 'test-request-config' );
lives_ok { $tempSP->_getOrCreateRequestConfiguration(\%hh); }
   "_getOrCreateRequestConfiguration: succeeds with requestConfiguration and requestType";

my($fullConfig, $rc);
lives_ok { $fullConfig =  $tempSP->getRequestConfigurations('test-request'); }
   "getRequestConfigurations: succeeds after successful _getOrCreateRequestConfiguration()";

$rc = $fullConfig->{$rr}{'test-request-config'};

is_deeply(\%hh, { requestTypeId => $rr, requestConfigurationId => $rc },
   "_getOrCreateRequestConfiguration: modification of paramater argument was correct after successful add");

is_deeply $fullConfig,
  { 1 => { 'test-request-config' => 1 } },
   "_getOrCreateRequestConfiguration: lookup of a request configuration works after _getOrCreateRequestConfiguration";

%hh = (requestTypeId => $rr, requestConfiguration => "test-request-config");
lives_ok { $tempSP->_getOrCreateRequestConfiguration(\%hh); }
   "_getOrCreateRequestConfiguration: looks up one previously added by _getOrCreateRequestConfiguration()";

is_deeply(\%hh, { requestTypeId => $rr, requestConfigurationId => $rc },
   "_getOrCreateRequestConfiguration: lookup of a request works after _getOrCreateRequestConfiguration");

%hh = ( requestTypeId => $rr, requestConfigurationId => $rc, requestConfiguration => 'this-arg-matters-not' );

lives_ok { $tempSP->_getOrCreateRequestConfiguration(\%hh); }
   "_getOrCreateRequestConfiguration: lookup of existing requestConfigurationId succeeds, ignoring requestConfiguration parameter.";

is_deeply(\%hh, { requestTypeId => $rr, requestConfigurationId => $rc },
   "_getOrCreateRequestConfiguration: deletes requestTypeConfiguration if both are provided.");

=back

=item Database weirdness tests

=cut

($tempDBH, $tempSP) = ResetDB($tempDBH);
$tempDBH->do("DROP TABLE email_address;");

dies_ok { $tempSP->addSupporter({ display_name => "Roger Sterling",
                                  public_ack => 0, ledger_entity_id => "Sterling-Roger",
                                  email_address => 'sterlingjr@example.com',
                                  email_address_type => 'home' }) }
        "addSupporter: dies when email_address table does not exist & email adress given";


$tempDBH->disconnect; $tempDBH = reopen_test_dbh();

$val = $tempDBH->selectall_hashref("SELECT id FROM donor;", 'id');

ok( (defined $val and reftype $val eq "HASH" and keys(%{$val}) == 0),
    "addSupporter: fails if email_address given but email cannot be inserted");

$tempDBH->disconnect; $tempDBH = reopen_test_dbh();



=back

=cut

$tempDBH->disconnect;
1;
###############################################################################
#
# Local variables:
# compile-command: "perl -c Supporters.t && cd ..; make clean; perl Makefile.PL && make &&  make test TEST_VERBOSE=1"
# End:

