# License: AGPLv3-or-later
#  Copyright info in COPYRIGHT.md, License details in LICENSE.md with this package.
package Supporters;

use 5.020002;
use strict;
use warnings;

require Exporter;

our @ISA = qw(Exporter);

# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.

# This allows declaration	use Supporters ':all';
# If you do not need this, moving things directly into @EXPORT or @EXPORT_OK
# will save memory.
our %EXPORT_TAGS = ( 'all' => [ qw(
	
) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(
	
);

our $VERSION = '0.02';

use Scalar::Util qw(looks_like_number blessed reftype);
use List::Util qw(maxstr);

use Mail::RFC822::Address;
use Carp qw(confess);
use Date::Manip::DM5;

######################################################################

=begin new

Create new Supporters object.

Arguments:

=over

=item $dbh

   Scalar references for the database handle from the L<DBI>, already opened
   and pointing to the right database.  This class will take over and control
   the DBI object after C<new()> completes.

=item $ledgerCmd

   A list reference that contains the main ledger command with any necessary
   arguments, for looking up donation data.  The options should be presented
   such that the output is in the form:
         ProgramTag  Date   Entity   Amount

=item $programTypeSearch

   This hash should have two keys: "monthly" and "annual".  The values of the
   hash should be a regular expression that matches the ProgramTag lines for
   categorization of the donations in annual or monthly buckets.


=back

=cut

sub new ($$;$) {
  my $package = shift;
  my($dbh, $ledgerCmd, $programTypeSearch) = @_;

  die "new: second argument must be a list ref for the ledger command line"
    unless (defined $ledgerCmd and ref $ledgerCmd and (reftype($ledgerCmd) eq 'ARRAY'));

  die "new: keys annual and monthly must be the only keys in this hash"
      if defined $programTypeSearch and (not (defined $programTypeSearch->{monthly} and defined $programTypeSearch->{annual}
      and scalar(keys(%$programTypeSearch) == 2)));

  die "new: first argument must be a database handle"
    unless (defined $dbh and blessed($dbh) =~ /DBI/);

  my $self = bless({ dbh => $dbh, ledgerCmd => $ledgerCmd },
                   $package);

  $self->{programTypeSearch} = $programTypeSearch if defined $programTypeSearch;

  # Turn off AutoCommit, and create our own handler that resets the
  # begin_work/commit reference counter.
  $dbh->{RaiseError} = 0;
  $dbh->{HandleError} = sub {
    $self->{__NESTED_TRANSACTION_COUNTER__} = 0;
    confess $_[0];
  };
  $self->{__NESTED_TRANSACTION_COUNTER__} = 0;
  return $self;
}
######################################################################

=begin dbh

Accessor method, returns the database handle currently used by this
Supporters object.

=cut

sub dbh ($) {
  return $_[0]->{dbh};
}
######################################################################

=begin ledgerCmd

Accessor method, returns the ledger command currently used by this Supporters
object.

=cut

sub ledgerCmd ($) {
  return $_[0]->{ledgerCmd};
}
######################################################################
sub addSupporter ($$) {
  my($self, $sp) = @_;

  die "ledger_entity_id required" unless defined $sp->{ledger_entity_id};

  if ($sp->{public_ack}) {
    die "display_name required if public_ack requested" unless defined $sp->{display_name};
  }
  $self->_beginWork;
  my $sth = $self->dbh->prepare(
                      "INSERT INTO     donor(ledger_entity_id, display_name, public_ack, is_supporter)" .
                                    " values(?,                ?,            ?, " .
                                    $self->dbh->quote(1, 'SQL_BOOLEAN') . ')');

  $sth->execute($sp->{ledger_entity_id}, $sp->{display_name}, $sp->{public_ack});
  my $id = $self->dbh->last_insert_id("","","","");
  $sth->finish();

  $self->addEmailAddress($id, $sp->{email_address}, $sp->{email_address_type})
    if defined $sp->{email_address};

  $self->_commit;
  return $id;
}
######################################################################

=begin addAddressType

Adds an address type, or returns the existing one of that name if it already exists.

Arguments:

=over

=item $addressType

  Scalar string that contains the email address type.  die() is called if not defined.

=back

  Returns id of the address type.

=cut

sub addAddressType($$) {
  my($self, $type) = @_;

  die "addAddressType: type argument must be defined" if not defined $type;

  my $val = $self->dbh()->selectall_hashref("SELECT id, name FROM address_type WHERE name = '$type'", 'name');
  return $val->{$type}{id} if (defined $val and defined $val->{$type} and defined $val->{$type}{id});

  my $sth = $self->dbh->prepare("INSERT INTO address_type(name) VALUES(?)");

  $sth->execute($type);
  my $id = $self->dbh->last_insert_id("","","","");
  $sth->finish();

  return $id;
}
######################################################################

=begin addEmailAddress

Arguments:

=over

=item $id

   Valid supporter id number currently in the database.  die() will occur if
   the id number is not in the database already as a supporter id.

=item $emailAddress

   Scalar string that contains an email address.  die() will occur if the
   email address isn't properly formatted.

=item $emailAddressType

  Scalar string that contains the email address type.  This type will be
  created in the database if it does not already exist, so be careful.

=back

Returns the id value of the email_address entry.

=cut

sub addEmailAddress($$$$) {
  my($self, $id, $emailAddress, $emailAddressType) = @_;

  die "addEmailAddress: invalid id, $id" unless $self->_verifyId($id);

  die "addEmailAddress: invalid email address, $emailAddressType"
    unless defined $emailAddressType and Mail::RFC822::Address::valid($emailAddress);

  my $existingEmail = $self->_lookupEmailAddress($emailAddress);

  if (defined $existingEmail) {
    die "addEmailAddress: attempt to add email address that exists, using a different type!"
      if $existingEmail->{type} ne $emailAddressType;

    my $val = $self->dbh()->selectall_hashref("SELECT email_address_id, donor_id " .
                                              "FROM donor_email_address_mapping WHERE " .
                                              "donor_id = " . $self->dbh->quote($id, 'SQL_INTEGER') . " AND " .
                                              "email_address_id = " . $self->dbh->quote($existingEmail->{id}, 'SQL_INTEGER'),
                                              'donor_id');
    return $val->{$id}{email_address_id}
      if (defined $val and defined $val->{$id} and defined $val->{$id}{email_address_id});
  }
  my($sth, $addressId);

  $self->_beginWork();

  if (defined $existingEmail) {
    $addressId = $existingEmail->{id};
  } else {
    my $addressTypeId;
    eval {
      $addressTypeId = $self->addAddressType($emailAddressType);
    };
    if ($@ or not defined $addressTypeId) {
      my $err = $@;
      $err = "addEmailAddress: unable to addAddressType"  if (not defined $err);
      $self->_rollback();
      die $@ if $@;
    }
    $sth = $self->dbh->prepare("INSERT INTO email_address(email_address, type_id, date_encountered)" .
                                  "VALUES(                    ?,            ?,       date('now'))");

    $sth->execute($emailAddress, $addressTypeId);
    $addressId = $self->dbh->last_insert_id("","","","");
    $sth->finish();
  }
  $sth = $self->dbh->prepare("INSERT INTO donor_email_address_mapping" .
                             "(donor_id, email_address_id) " .
                             "VALUES(       ?, ?)");
  $sth->execute($id, $addressId);
  $sth->finish();

  $self->_commit();

  return $addressId;
}
######################################################################

=begin getEmailAddresses

Arguments:

=over

=item $id

   Valid supporter id number currently in the database.  die() will occur if
   the id number is not in the database already as a supporter id.

=back

Returns a hashes, where the keys are the emailAddreses and values a hash with two keys:

=over

=item date_encountered

=item name

=back

=cut

sub getEmailAddresses($$) {
  my($self, $id) = @_;

  die "getEmailAddresses: invalid id, $id" unless $self->_verifyId($id);

  my $val = $self->dbh()->selectall_hashref("SELECT ea.email_address, at.name, ea.date_encountered " .
                                            "FROM donor_email_address_mapping map, address_type at, email_address ea " .
                                            "WHERE at.id = ea.type_id AND ea.id = map.email_address_id AND " .
                                            "map.donor_id = " . $self->dbh->quote($id, 'SQL_INTEGER'),
                                            'email_address');
  foreach my $key (keys %{$val}) { delete $val->{$key}{email_address}; }
  return %{$val};
}
######################################################################

=begin setPreferredEmailAddress

Arguments:

=over

=item $donorId

   Valid supporter id number currently in the database.  die() will occur if
   the id number is not in the database already as a supporter id.


=item $emailAddress

   Scalar string that contains an email address.  undef is returned if the
   email address is not already in the database for this supporter.

=back

Returns the email_address_id of the preferred email address.  undef can be
returned; it means the preferred email address wasn't selected for some reason.

=cut

sub setPreferredEmailAddress($$$) {
  my($self, $donorId, $emailAddress) = @_;

  die "setPreferredEmailAddress: invalid supporter id, $donorId" unless $self->_verifyId($donorId);
  die "setPreferredEmailAddress: email address not defined" unless defined $emailAddress;
  die "setPreferredEmailAddress: invalid email address, $emailAddress"
    unless Mail::RFC822::Address::valid($emailAddress);

  my $ems = $self->dbh()->selectall_hashref("SELECT ea.email_address, ea.id, sem.preferred " .
                                            "FROM email_address ea, donor_email_address_mapping sem " .
                                            "WHERE ea.id = sem.email_address_id AND ".
                                            "sem.donor_id = " . $self->dbh->quote($donorId, 'SQL_INTEGER'),
                                            'email_address');
  # Shortcut: it was already set
  return $ems->{$emailAddress}{id} if (defined $ems->{$emailAddress} and $ems->{$emailAddress}{preferred});

  my $anotherPreferred = 0;
  my $emailAddressId;
  # Iterate over email addresses, finding if any were preferred before, and finding outs too.
  foreach my $em (keys %{$ems}) {
    $anotherPreferred = 1 if $ems->{$em}{preferred};
    $emailAddressId = $ems->{$em}{id} if $em eq $emailAddress;
  }
  return undef if not defined $emailAddressId;

  $self->_beginWork();
  if ($anotherPreferred) {
    $self->dbh->do("UPDATE donor_email_address_mapping " .
                     "SET preferred = " . $self->dbh->quote(0, 'SQL_BOOLEAN') . " " .
                     "WHERE donor_id = " . $self->dbh->quote($donorId, 'SQL_INTEGER'));
  }
  $self->dbh->do("UPDATE donor_email_address_mapping " .
                 "SET preferred = " . $self->dbh->quote(1, 'SQL_BOOLEAN') . " " .
                 "WHERE email_address_id = " . $self->dbh->quote($emailAddressId, 'SQL_INTEGER'));
  $self->_commit;
  return $emailAddressId;
}

######################################################################

=begin setPreferredPostalAddress

Arguments:

=over

=item $donorId

   Valid supporter id number currently in the database.  die() will occur if
   the id number is not in the database already as a supporter id.


=item $postalAddress

   Scalar string that contains an postal Address.  undef is returned if the
   email address is not already in the database for this supporter.

=back

Returns the email_address_id of the preferred email address.  undef can be
returned; it means the preferred email address wasn't selected for some reason.

=cut

sub setPreferredPostalAddress($$$) {
  my($self, $donorId, $postalAddress) = @_;

  die "setPreferredPostalAddress: invalid supporter id, $donorId" unless $self->_verifyId($donorId);
  die "setPreferredPostalAddress: email address not defined" unless defined $postalAddress;

  my $ems = $self->dbh()->selectall_hashref("SELECT ea.formatted_address, ea.id, sem.preferred " .
                                            "FROM postal_address ea, donor_postal_address_mapping sem " .
                                            "WHERE ea.id = sem.postal_address_id AND ".
                                            "sem.donor_id = " . $self->dbh->quote($donorId, 'SQL_INTEGER'),
                                            'formatted_address');
  # Shortcut: it was already set
  return $ems->{$postalAddress}{id} if (defined $ems->{$postalAddress} and $ems->{$postalAddress}{preferred});

  my $anotherPreferred = 0;
  my $postalAddressId;
  # Iterate over email addresses, finding if any were preferred before, and finding outs too.
  foreach my $em (keys %{$ems}) {
    $anotherPreferred = 1 if $ems->{$em}{preferred};
    $postalAddressId = $ems->{$em}{id} if $em eq $postalAddress;
    last if $anotherPreferred;  #FIXME: THIS HAS TO HAPPEN IT IS A BUG NEEDS A TEST .. francois caused bug
  }
  return undef if not defined $postalAddressId;

  $self->_beginWork();
  if ($anotherPreferred) {
    $self->dbh->do("UPDATE donor_postal_address_mapping " .
                     "SET preferred = " . $self->dbh->quote(0, 'SQL_BOOLEAN') . " " .
                     "WHERE donor_id = " . $self->dbh->quote($donorId, 'SQL_INTEGER'));
  }
  $self->dbh->do("UPDATE donor_postal_address_mapping " .
                 "SET preferred = " . $self->dbh->quote(1, 'SQL_BOOLEAN') . " " .
                 "WHERE postal_address_id = " . $self->dbh->quote($postalAddressId, 'SQL_INTEGER'));
  $self->_commit;
  return $postalAddressId;
}
######################################################################

=begin getPreferredEmailAddress

Arguments:

=over

=item $donorId

   Valid supporter id number currently in the database.  die() will occur if
   the id number is not in the database already as a supporter id.


=item $emailAddress

   Scalar string that contains an email address.  undef is returned if the
   email address is not already in the database for this supporter.

=back

Returns the email_address_id of the preferred email address.  undef can be
returned; it means the preferred email address wasn't selected for some reason.

=cut

sub getPreferredEmailAddress($$) {
  my($self, $donorId) = @_;

  die "setPreferredEmailAddress: invalid supporter id, $donorId" unless $self->_verifyId($donorId);

  my $ems = $self->dbh()->selectall_hashref("SELECT email_address FROM email_address em, donor_email_address_mapping sem " .
                                            "WHERE preferred AND sem.email_address_id = em.id AND " .
                                            "sem.donor_id = " . $self->dbh->quote($donorId, 'SQL_INTEGER'),
                                            'email_address');
  my $rowCount = scalar keys %{$ems};
  die "setPreferredEmailAddress: DATABASE INTEGRITY ERROR: more than one email address is preferred for supporter, \"$donorId\""
    if $rowCount > 1;

  if ($rowCount != 1) {
    return undef;
  } else {
    my ($emailAddress) = keys %$ems;
    return $emailAddress;
  }
}
######################################################################

=begin getPreferredPostalAddress

Arguments:

=over

=item $donorId

   Valid supporter id number currently in the database.  die() will occur if
   the id number is not in the database already as a supporter id.


=item $postalAddress

   Scalar string that contains an postalAddress.  undef is returned if the
   postal address is not already in the database for this supporter.

=back

Returns the postal_address_id of the preferred postal address.  undef can be
returned; it means the preferred postal address wasn't selected for some reason.

=cut

sub getPreferredPostalAddress($$) {
  my($self, $donorId) = @_;

  die "setPreferredPostalAddress: invalid supporter id, $donorId" unless $self->_verifyId($donorId);

  my $ems = $self->dbh()->selectall_hashref("SELECT formatted_address FROM postal_address em, donor_postal_address_mapping sem " .
                                            "WHERE preferred AND sem.postal_address_id = em.id AND " .
                                            "sem.donor_id = " . $self->dbh->quote($donorId, 'SQL_INTEGER'),
                                            'formatted_address');
  my $rowCount = scalar keys %{$ems};
  die "setPreferredPostalAddress: DATABASE INTEGRITY ERROR: more than one postal address is preferred for supporter, \"$donorId\""
    if $rowCount > 1;

  if ($rowCount != 1) {
    return undef;
  } else {
    my ($postalAddress) = keys %$ems;
    return $postalAddress;
  }
}
######################################################################
sub _getDonorField($$$) {
  my($self, $field, $donorId) = @_;

  die "get$field: invalid supporter id, $donorId" unless $self->_verifyId($donorId);

  my $results = $self->dbh()->selectall_hashref("SELECT id, $field FROM donor WHERE id = " .
                                                $self->dbh->quote($donorId, 'SQL_INTEGER'),
                                                'id');
  my $rowCount = scalar keys %{$results};
  die "get$field: DATABASE INTEGRITY ERROR: more than one row found when looking up supporter, \"$donorId\""
    if $rowCount > 1;

  if ($rowCount == 1) {
    my ($val) = $results->{$donorId}{$field};
    return $val;
  } else {
    die "get$field: DATABASE INTEGRITY ERROR: $donorId was valid but non-1 row count returned";
  }
}
######################################################################

=begin getLedgerEntityId

Arguments:

=over

=item $donorId

   Valid donor id number currently in the database.  die() will occur if
   the id number is not in the database already as a donor id.

=back

Returns the ledger_entity_id of the donor.  Since the method die()s for an
invalid donor id, undef should never be returned and callers need not test
for it.

=cut

sub getLedgerEntityId ($$) {
  return $_[0]->_getDonorField("ledger_entity_id", $_[1]);
}
######################################################################

=begin getPublicAck

Arguments:

=over

=item $donorId

   Valid donor id number currently in the database.  die() will occur if
   the id number is not in the database already as a donor id.

=back

Returns the a boolean indicating whether or not the donor seeks to be
publicly acknowledged.  undef can be returned if the donor has not specified,
so callers must check for undef.

=cut

sub getPublicAck($$$) {
  return $_[0]->_getDonorField("public_ack", $_[1]);
}
######################################################################

=begin isSupporter

Arguments:

=over

=item $donorId

   Valid donor id number currently in the database.  die() will occur if
   the id number is not in the database already as a donor id.

=back

Returns the a boolean indicating whether or not the donor is a Supporter (as
opposed to an ordinary donor).  undef will not be returned


=cut

sub isSupporter($$$) {
  return $_[0]->_getDonorField("is_supporter", $_[1]);
}
######################################################################

=begin getDisplayName

Arguments:

=over

=item $donorId

   Valid donor id number currently in the database.  die() will occur if
   the id number is not in the database already as a donor id.

=back

Returns the string of the display name for the donor.  undef can be returned
if the donor has not specified, so callers must check for undef.

=cut

sub getDisplayName($$$) {
  return $_[0]->_getDonorField("display_name", $_[1]);
}
######################################################################
sub _setDonorField($$$) {
  my($self, $field, $donorId, $value, $type) = @_;

  die "set$field: invalid supporter id, $donorId" unless $self->_verifyId($donorId);

  $self->_beginWork();
  $self->dbh->do("UPDATE donor " .
                     "SET $field = " . $self->dbh->quote($value, $type) . " " .
                     "WHERE id = " . $self->dbh->quote($donorId, 'SQL_INTEGER'));
  $self->_commit;
  return $value;
}
######################################################################

=begin setPublicAck

Arguments:

=over

=item $donorId

   Valid donor id number currently in the database.  die() will occur if
   the id number is not in the database already as a donor id.

=item $publicAck

   Can be true, false, or undef and will update public acknowledgement bit
   accordingly for donor identified with C<$donorId>.

=back

=cut

sub setPublicAck($$$) {
  return $_[0]->_setDonorField('public_ack', $_[1], $_[2], 'SQL_BOOLEAN');
}
######################################################################

=begin addPostalAddress

Arguments:

=over

=item $id

   Valid supporter id number currently in the database.  die() will occur if
   the id number is not in the database already as a supporter id.

=item $formattedPostalAddress

   Scalar string that contains a multi-line, fully formatted, postal address.

=item $addressType

  Scalar string that contains the address type.  This type will be created in
  the database if it does not already exist, so be careful.

=back

Returns the id value of the postal_address table entry.

=cut

sub addPostalAddress($$$$) {
  my($self, $id, $formattedPostalAddress, $addressType) = @_;

  die "addPostalAddress: invalid id, $id" unless $self->_verifyId($id);
  die "addPostalAddress: the formatted postal address must be defined"
    unless defined $formattedPostalAddress;

  $self->_beginWork();

  my $addressTypeId;
  eval {
    $addressTypeId = $self->addAddressType($addressType);
  };
  if ($@ or not defined $addressTypeId) {
    my $err = $@;
    $err = "addPostalAddress: unable to addAddressType"  if (not defined $err);
    $self->_rollback();
    die $@ if $@;
  }
  my $sth = $self->dbh->prepare("INSERT INTO postal_address(formatted_address, type_id, date_encountered)" .
                                "VALUES(                    ?,             ?,       date('now'))");

  $sth->execute($formattedPostalAddress, $addressTypeId);
  my $addressId = $self->dbh->last_insert_id("","","","");
  $sth->finish();

  $sth = $self->dbh->prepare("INSERT INTO donor_postal_address_mapping" .
                                      "(donor_id, postal_address_id) " .
                                "VALUES(       ?, ?)");
  $sth->execute($id, $addressId);
  $sth->finish();

  $self->_commit();

  return $addressId;
}
######################################################################

=begin getPostalAddresses

Arguments:

=over

=item $id

   Valid supporter id number currently in the database.  die() will occur if
   the id number is not in the database already as a supporter id.

=item $formattedPostalAddress

   Scalar string that contains a multi-line, fully formatted, postal address.

=back

Returns the id value of the postal_address table entry.

=cut

sub getPostalAddresses($) {
  my($self, $id) = @_;

  die "addPostalAddress: invalid id, $id" unless $self->_verifyId($id);

  my $val = $self->dbh()->selectall_hashref("SELECT pa.formatted_address, at.name, pa.date_encountered " .
                                            "FROM donor_postal_address_mapping map, address_type at, postal_address pa " .
                                            "WHERE at.id = pa.type_id AND pa.id = map.postal_address_id AND " .
                                            "map.donor_id = " . $self->dbh->quote($id, 'SQL_INTEGER'),
                                            'formatted_address');
  foreach my $key (keys %{$val}) { delete $val->{$key}{formatted_address}; }
  return %{$val};

}
######################################################################

=begin getRequestType

Arguments:

=over

=item type

   A string describing the request.  Argument is optional.

=back

If type is given, returns a scalar the id value of the request_type entry.
undef is returned if there is no request of that type.

If type is not given, a list of all known request types is returned.

=cut

sub getRequestType($;$) {
  my($self, $type) = @_;

  if (not defined $type) {
     return @{$self->dbh()->selectcol_arrayref("SELECT type, id FROM request_type ORDER BY id", { Columns=>[1] })};
   } else {
     my $val = $self->dbh()->selectall_hashref("SELECT id, type FROM request_type WHERE type = '$type'", 'type');
     return $val->{$type}{id} if (defined $val and defined $val->{$type} and defined $val->{$type}{id});
     return undef;
   }
}
######################################################################

=begin addRequestType

Arguments:

=over

=item type

   A string describing the request.  die()'s if not defined.

=back

Returns the id value of the request_type entry.  If the type already exists,
it is simply returned.

=cut

sub addRequestType($$) {
  my($self, $requestType) = @_;

  die "addRequestType: undefined request type." unless defined $requestType;

  my $requestId = $self->getRequestType($requestType);
  return $requestId if (defined $requestId);

  $self->_beginWork();

  my $sth = $self->dbh->prepare("INSERT INTO request_type(type) VALUES(?)");

  $sth->execute($requestType);
  $requestId = $self->dbh->last_insert_id("","","","");
  $sth->finish();
  $self->_commit();
  return $requestId;
}
######################################################################

=begin getRequestConfigurations

Arguments:

=over

=item type

   A string describing the request_type.

=back

Returns undef if the request_type is not found in the database.  If the reuqest type is 
is no request of that type.

=cut

sub getRequestConfigurations($$) {
  my($self, $type) = @_;

  return undef if not defined $type;
  my $typeId = $self->getRequestType($type);
  return undef if not defined $typeId;

  my %descriptions;
  my $dbData =
    $self->dbh()->selectall_hashref("SELECT description, id FROM request_configuration " .
                                    "WHERE request_type_id = " . $self->dbh->quote($typeId, 'SQL_INTEGER'),
                                    'description');
  foreach my $description (keys %$dbData) {
    $descriptions{$description} = $dbData->{$description}{id};
  }
  return { $typeId => \%descriptions };
}
######################################################################

=begin addRequestConfigurations

Arguments:

=over

=item type

   A string describing the request type.  This will be created if it does not
   already exist, so be careful.

=item descriptionListRef

   A list reference to the list of configuration descriptions to associate
   with this requestId.  Duplicates aren't permitted in this list, and
   die()'s if duplicates exist.

=back

Returns a hash in the form of:

  $requestTypeId => { description => $requestConfigurationId }

=cut

sub addRequestConfigurations($$$) {
  my($self, $requestType, $descriptionListRef) = @_;

  die "addRequestConfigurations: undefined request type." unless defined $requestType;

  $self->_beginWork();

  my $requestId = $self->addRequestType($requestType);

  if (not defined $requestType) {
    $self->_rollback();
    die "addRequestConfigurations: unable to create request configurations";
  }

  my %descriptions;
  my $sth = $self->dbh->prepare("INSERT INTO request_configuration(request_type_id, description) " .
                                                           "VALUES(?,               ?)");
  foreach my $description (@{$descriptionListRef}) {
    if (defined $descriptions{$description}) {
      $self->_rollback();
      die "addRequestConfigurations: attempt to create duplicate request_configuration \"$description\" for requestType, \"$requestType\"";
    }
    $sth->execute($requestId, $description);
    $descriptions{$description} = $self->dbh->last_insert_id("","","","");
  }
  $sth->finish();
  $self->_commit();
  return { $requestId => \%descriptions };
}
my $TODAY = UnixDate(ParseDate("today"), '%Y-%m-%d');
######################################################################

=begin getRequest

Arguments:

=item $parmas

A hash reference, the following keys are considered:

=over

=item donorId

   Valid donor_id number currently in the database.  die() will occur if
   the id number is not in the database already as a supporter id.

=item requestTypeId

   Numeric id of a request_type entry.  This must be a valid id in the
   request_type table, otherwise the method  L<die>()s.

   requestType is ignored if this parameter is set.

=item requestType

   If requestTypeId is not given, requestType will be used.  The type is
   added to the request_type table if it is not present, so be careful.

=item ignoreFulfilledRequests

   Optional boolean argument.  If true, a request that is found will not be
   returned if the request has already been fulfilled.  In other words, it
   forces a return of undef for

=back

=back

Returns:

=over

=item undef

      if the C<$requestType> is not found for C<$donorId> (or, as above,
      the C<$requestType> is found but has been fufilled and
      C<$ignoreFulfilledRequests>.

=item a hash reference

      If found, the has reference will contain at least the following keys:

=over

=item requestType

      Should match the request type in C<$requestType>

=item requestTypeId

      The id from the request_type entry for C<$requestType>

=item requestDate

      The date the request was made, in ISO 8601 format.

=back


Optionally, if these values are not null in the database record, the
following fields may also be included:

=over


=item  notes

       Notes made for the request.

=item  requestConfiguration

       any rquest configuration option given with the request.

=back

If the request has been fufilled, the following keys will also have values:

=over

=item fulfillDate

      The date the request was fufilled, in ISO 8601 format.

=back

If the request is on hold, the following keys will also have values:

=over

=item holdReleaseDate

      The date the request will be held until, in ISO 8601 format.

=item holdDate

      The date the hold was requested, in ISO 8601 format.

=item holder

      The person who is holding the request

=item heldBecause

      Why the person is holding the request.

=back

=back

=cut

sub getRequest($$;$) {
  my($self, $params) = @_;
  my($donorId, $requestType, $requestTypeId, $ignoreFulfilledRequests, $ignoreHeldRequests) =
    ($params->{donorId}, $params->{requestType}, $params->{requestTypeId}, $params->{ignoreFulfilledRequests},
     $params->{ignoreHeldRequests});

  die "getRequest: undefined donorId" unless defined $donorId;
  die "getRequest: donorId, \"$donorId\" not found in supporter database"
    unless $self->_verifyId($donorId);

  my $requestTypeClause = "";
  if (defined $requestTypeId) {
    $requestType = $self->_lookupRequestTypeById($requestTypeId);
    die "getRequest: invalid requestTypeId, \"$requestTypeId\"" unless defined $requestType;
    $requestTypeClause = " AND rt.id = " . $self->dbh->quote($requestTypeId, 'SQL_INTEGER');
  } elsif (defined $requestType) {
    $requestTypeClause = " AND rt.type = " . $self->dbh->quote($requestType);
  } else {
    die "getRequest: undefined requestType" unless defined $requestType;
  }
  my $req = $self->dbh()->selectall_hashref("SELECT r.id, r.request_type_id, r.request_configuration_id, r.date_requested, r.notes, rt.type " .
                                            "FROM request r, request_type rt WHERE r.request_type_id = rt.id AND " .
                                            "r.donor_id = " . $self->dbh->quote($donorId, 'SQL_INTEGER') .
                                            $requestTypeClause,
                                            'type');
  if (defined $requestTypeId) {
    die "getRequest: given requestTypeId, \"$requestTypeId\" was not the one found in the database $req->{$requestType}{'request_type_id'}"
      unless $req->{$requestType}{'request_type_id'} == $requestTypeId;
  } else {
    $requestTypeId = $req->{$requestType}{'request_type_id'};
  }
  return undef unless (defined $req and defined $req->{$requestType} and defined $req->{$requestType}{'id'});

  my $requestId = $req->{$requestType}{'id'};

  my $rsp = {  requestType   => $requestType,
               requestTypeId => $requestTypeId,
               requestId     => $req->{$requestType}{'id'},
               requestDate   => $req->{$requestType}{'date_requested'},
               notes         => $req->{$requestType}{'notes'},
            };
  my $configs = $self->getRequestConfigurations($requestType);
  my $configName;
  foreach my $key (keys %{$configs->{$requestTypeId}}) {
    if ($configs->{$requestTypeId}{$key} == $req->{$requestType}{'request_configuration_id'}) { $configName = $key; last; }
  }
  die("getRequest: discovered database integrity error: request_configuration, \"$req->{$requestType}{request_configuration_id} is " .
      "not valid for requestId, \"$requestId\"") unless defined $configName or (keys %{$configs->{$requestId}} == 0);
  $rsp->{requestConfiguration} = $configName;

  my $fulfillReq = $self->dbh()->selectall_hashref("SELECT id, request_id, date, who, how FROM fulfillment WHERE request_id = " .
                                                   $self->dbh->quote($requestId, 'SQL_INTEGER'),
                                                   'request_id');
  if (defined $fulfillReq and defined $fulfillReq->{$requestId} and defined $fulfillReq->{$requestId}{id}) {
    return undef if $ignoreFulfilledRequests;
    $rsp->{fulfillDate} = $fulfillReq->{$requestId}{date};
    $rsp->{fulfilledBy} = $fulfillReq->{$requestId}{who};
    $rsp->{fulfilledVia} = $fulfillReq->{$requestId}{how};
  }
  my $holdReq = $self->dbh()->selectall_hashref("SELECT id, request_id, hold_date, release_date, who, why " .
                                                "FROM request_hold WHERE request_id = " .
                                                   $self->dbh->quote($requestId, 'SQL_INTEGER'),
                                                   'request_id');
  if (defined $holdReq and defined $holdReq->{$requestId} and defined $holdReq->{$requestId}{id}) {
    return undef if $ignoreHeldRequests and ($TODAY lt $holdReq->{$requestId}{release_date});
    $rsp->{holdDate} = $holdReq->{$requestId}{hold_date};
    $rsp->{holdReleaseDate} = $holdReq->{$requestId}{release_date};
    $rsp->{holder} = $holdReq->{$requestId}{who};
    $rsp->{heldBecause} = $holdReq->{$requestId}{why};
  }
  return $rsp;
}
######################################################################

=begin addRequest

Arguments:

=over

=item $parmas

A hash reference, the following keys are considered:

=over

=item donorId

   Valid donor_id number currently in the database.  die() will occur if
   the id number is not in the database already as a supporter id.

=item requestTypeId

   Numeric id of a request_type entry.  This must be a valid id in the
   request_type table, otherwise the method  L<die>()s.

   requestType is ignored if this parameter is set.

=item requestType

   If requestTypeId is not given, requestType will be used.  The type is
   added to the request_type table if it is not present, so be careful.


=item requestConfigurationId

   Numeric id of a request_configuration entry.  This must be a valid id in
   the request_configuration table, otherwise the method L<die>()s.

=item requestConfiguration

   If requestConfigurationId is not given, requestConfiguration will be used.
   This configuration will be added to the request_configuration table if it
   is not present, so be careful.

=back

=back

Returns the id value of the request entry.

=cut

sub addRequest($$) {
  my($self, $params) = @_;
  die "addRequest: undefined donorId" unless defined $params->{donorId};
  my $donorId = $params->{donorId};
  die "addRequest: donorId, \"$donorId\" not found in supporter database"
    unless $self->_verifyId($donorId);

  $self->_beginWork;
  eval {
    $self->_getOrCreateRequestType($params);
    $self->_getOrCreateRequestConfiguration($params) if (defined $params->{requestConfiguration} or
                                                        defined $params->{requestConfigurationId});
  };
  if ($@ or not defined $params->{requestTypeId}) {
    my $err = $@;
    $err = "addRequest: unable to create requestType"  if (not defined $err);
    $self->_rollback();
    die $@ if $@;
  }

  # After those two calls above, I know I have requestTypeId and
  # requestConfigurationId are accurate.  Note that
  # $params->{requestConfigurationId} can be undef, which is permitted in the
  # database schema.

  my $sth = $self->dbh->prepare("INSERT INTO request(donor_id, request_type_id, request_configuration_id, notes, date_requested) " .
                                             "VALUES(?,            ?,               ?,                        ?,      date('now'))");
  $sth->execute($donorId, $params->{requestTypeId}, $params->{requestConfigurationId}, $params->{notes});
  my $id = $self->dbh->last_insert_id("","","","");
  $self->_commit;
  return $id;
}
######################################################################

=begin fulfillRequest

Arguments:

=over

=item $parmas

A hash reference, the following keys are considered:

=over

=item donorId

   Valid donor_id number currently in the database.  die() will occur if
   the id number is not in the database already as a supporter id.

=item requestType

   requestType of the request to be fulfilled.  die() will occur if this is
   undefined.  undef is returned if there is no unfulfilled request of
   requestType in the database for supporter identified by
   C<$params->{donorId}>

=item who

   A scalar string representing the person that fulfilled the request.  die()
   will occur if C<$params->{who}> is not defined.

=item how

   A scalar string describing how the request was fulfilled.  It can safely be
   undefined.

=back

=back

Returns the id value of the fulfillment entry.  Note that value may be a
fulfillment id from a previous fulfillment (i.e., the request may have
already been fulfilled).

undef can be returned.  Currently, undef is only returned if the request is
on hold.

=cut

sub fulfillRequest($$) {
  my($self, $params) = @_;
  die "fulfillRequest: undefined donorId" unless defined $params->{donorId};
  my $donorId = $params->{donorId};
  die "fulfillRequest: donorId, \"$donorId\" not found in supporter database"
    unless $self->_verifyId($donorId);
  die "fulfillRequest: undefined who" unless defined $params->{who};
  die "fulfillRequest: both requestType and requestTypeId undefined"
    unless defined $params->{requestType} or defined $params->{requestTypeId};

  my $req = $self->getRequest($params);
  return undef if not defined $req;
  my $requestId = $req->{requestId};
  return undef if not defined $requestId;

  my $fulfillLookupSql = "SELECT id, request_id FROM fulfillment WHERE request_id = " .
                        $self->dbh->quote($requestId, 'SQL_INTEGER');

  my $fulfillRecord = $self->dbh()->selectall_hashref($fulfillLookupSql, "request_id");
  if (not defined $fulfillRecord or not defined $fulfillRecord->{$requestId}) {
    # First check if request is held.  If it's held, it cannot be fulfilled.
    my $holdReq = $self->dbh()->selectall_hashref("SELECT id, request_id, release_date " .
                                                "FROM request_hold WHERE request_id = " .
                                                   $self->dbh->quote($requestId, 'SQL_INTEGER'),
                                                  'request_id');
    return undef
      if (defined $holdReq and defined $holdReq->{$requestId} and defined $holdReq->{$requestId}{id}
          and $TODAY lt $holdReq->{$requestId}{release_date});

    # Ok, it's not on hold, so go ahead and fulfill it.
    $self->_beginWork;
    my $sth = $self->dbh->prepare("INSERT INTO fulfillment(request_id, who, how, date) " .
                                                   "VALUES(?         , ?  , ?  , date('now'))");

    $sth->execute($requestId, $params->{who}, $params->{how});
    $sth->finish;
    $self->_commit;
    $fulfillRecord = $self->dbh()->selectall_hashref($fulfillLookupSql, "request_id");
  }
  return $fulfillRecord->{$requestId}{id};
}

######################################################################

=begin fulfillFailure

FIXME better docs

Convert a requests  fulfillment to a mere hold becuase a fulfillment failed.

=cut

sub fulfillFailure($$) {
  my($self, $params) = @_;
  die "fulfillFailure: undefined donorId" unless defined $params->{donorId};
  my $donorId = $params->{donorId};
  die "fulfillFailure: donorId, \"$donorId\" not found in supporter database"
    unless $self->_verifyId($donorId);
  die "fulfillFailure: both why required"
    unless defined $params->{why};
  die "fulfillFailure: both requestType and requestTypeId undefined"
    unless defined $params->{requestType} or defined $params->{requestTypeId};

  my $req = $self->getRequest($params);
  return undef if not defined $req;
  my $requestId = $req->{requestId};
  return undef if not defined $requestId;

  my $fulfillLookupSql = "SELECT id, request_id, date, who, how FROM fulfillment WHERE request_id = " .
                        $self->dbh->quote($requestId, 'SQL_INTEGER');

  my $fulfillRecord = $self->dbh()->selectall_hashref($fulfillLookupSql, "request_id");

  return undef
    if (not defined $fulfillRecord or not defined $fulfillRecord->{$requestId});

  $self->_beginWork;

  my $reason = "because $params->{why}, fulfillment failed on " . $fulfillRecord->{$requestId}{date} . " (which was attempted via " .
    $fulfillRecord->{$requestId}{how} . ')';

  my $holdId = $self->holdRequest({donorId => $donorId, requestType => $req->{requestType},
                                   who => $fulfillRecord->{$requestId}{who},
                                   heldBecause => $reason, holdReleaseDate => '9999-12-31'});

  die "fulfillFailure: failed to create hold request for fulfillment" unless defined $holdId;

  my $sth = $self->dbh->prepare("UPDATE request_hold SET hold_date = ?  WHERE id = ?");
  $sth->execute($fulfillRecord->{$requestId}{date}, $holdId);
  $sth->finish;

  $sth = $self->dbh->prepare("DELETE FROM fulfillment WHERE id = ?");
  $sth->execute($fulfillRecord->{$requestId}{id});
  $sth->finish;

  $self->_commit;
  return $holdId;
}
######################################################################

=begin holdRequest

Arguments:

=item $parmas

A hash reference, the following keys are considered:

=over

=item donorId

   Valid donor_id number currently in the database.  die() will occur if
   the id number is not in the database already as a supporter id.

=item requestType / requestTypeId

   If one or both of these parameters is defined, they are used as arguments
   to C<getRequest()> method.  die()'s if neither is defined.

=item who

   For adding a hold request, the string indicating who put the request on hold.

=item holdReleaseDate

   For adding a hold request, contain an ISO 8601 formatted date for the
   date to release the hold.  die() may occur if not in ISO-8601 format.

=item heldBecause

   For adding a hold request, the string indicating reason the request is on hold.


=back

Returns:

Id of the hold request.  This could be the id of a different hold with
different details.  See FIXME note in the test code for holdRequest() for
more detials.

=cut

sub holdRequest($$) {
  my($self, $params) = @_;
  die "holdRequest: undefined donorId" unless defined $params->{donorId};
  my $donorId = $params->{donorId};
  die "holdRequest: donorId, \"$donorId\" not found in supporter database"
    unless $self->_verifyId($donorId);
  foreach my $key (qw/who holdReleaseDate heldBecause/) {
    die "holdRequest: required parameter undefined: \"$key\"" unless defined $params->{$key};
  }
  die "holdRequest: requestType and requestTypeId are all undefined"
    unless defined $params->{requestType} or defined $params->{requestTypeId};

  my $req = $self->getRequest($params);
  return undef if not defined $req;
  my $requestId = $req->{requestId};
  return undef if not defined $requestId;

  my $holdLookupSql = "SELECT id, request_id FROM request_hold WHERE request_id = " .
                        $self->dbh->quote($requestId, 'SQL_INTEGER');

  my $holdRecord = $self->dbh()->selectall_hashref($holdLookupSql, "request_id");
  if (not defined $holdRecord or not defined $holdRecord->{$requestId}) {
    $self->_beginWork;
    my $sth = $self->dbh->prepare("INSERT INTO " .
                                  "request_hold(request_id, who, why, release_date, hold_date) " .
                                        "VALUES(?,           ?,   ?  , ?  ,         date('now'))");

    $sth->execute($requestId, $params->{who}, $params->{heldBecause}, $params->{holdReleaseDate});
    $sth->finish;
    $self->_commit;
    $holdRecord = $self->dbh()->selectall_hashref($holdLookupSql, "request_id");
  }
  return $holdRecord->{$requestId}{id};
}
######################################################################

=begin releaseRequestHold

Arguments:

=item $parmas

A hash reference, the following keys are considered:

=over

=item donorId

   Valid donor_id number currently in the database.  die() will occur if
   the id number is not in the database already as a supporter id.

=item requestType / requestTypeId

   If one or both of these parameters is defined, they are used as arguments
   to C<getRequest()> method.  die()'s if neither is defined.

=back

Returns:

If the release has been successful, returns the id of the hold request that
is now released.  Otherwise, undef is returned.

Note that the release can also be "unsuccessful" if the request wasn't on
hold in the first place.

=cut


sub releaseRequestHold($$) {
  my($self, $params) = @_;
  die "holdRequest: undefined donorId" unless defined $params->{donorId};
  my $donorId = $params->{donorId};
  die "holdRequest: donorId, \"$donorId\" not found in supporter database"
    unless $self->_verifyId($donorId);
  die "holdRequest: requestType and requestTypeId are all undefined"
    unless defined $params->{requestType} or defined $params->{requestTypeId};

  my $req = $self->getRequest($params);
  return undef if not defined $req;
  my $requestId = $req->{requestId};
  return undef if not defined $requestId;

  my $holdLookupSql = "SELECT id, request_id, release_date FROM request_hold WHERE request_id = " .
                        $self->dbh->quote($requestId, 'SQL_INTEGER');

  my $holdRecord = $self->dbh()->selectall_hashref($holdLookupSql, "request_id");
  return undef if (not defined $holdRecord or not defined $holdRecord->{$requestId});

  # If this has already been released, just return the release id again.
  return $holdRecord->{$requestId}{id} if defined $holdRecord->{$requestId}{release_date} and
    $holdRecord->{$requestId}{release_date} le $TODAY;
  $self->_beginWork;
  my $sth = $self->dbh->prepare("UPDATE request_hold SET release_date = date('now') WHERE id = ?");

  $sth->execute($holdRecord->{$requestId}{id});
  $sth->finish;
  $self->_commit;
  return $holdRecord->{$requestId}{id};
}
######################################################################

=begin findDonor

Arguments:

=over

=item $parmas

A hash reference, the following keys are considered, and are "anded" together
-- in that the donor sought must have all these criteria to be found.

If no criteria are given, all donors are returned.

=over

=item emailAddress

   A string containing an email_address from email_address table.

=item ledgerEntityId

   A string containing a ledger_entity_id from the donor table.
   undefined.  undef is returned if there is no unfulfilled request of
   requestType in the database for supporter identified by
   C<$params->{donorId}>

=back

=back

Returns a list of donorIds that meets the criteria, or none if not found.

=cut

sub findDonor($$) {
  my($self, $params) = @_;

  unless (defined $params->{ledgerEntityId} or defined $params->{emailAddress}) {
    my $rr = $self->dbh()->selectall_hashref("SELECT id FROM donor", 'id');
    return keys %$rr;
  }

  my @donorIds;
  if (not defined $params->{emailAddress}) {
    my $ledgerEntityId = $params->{ledgerEntityId};
    # Simple case: just lookup without a join.
    my $val = $self->dbh()->selectall_hashref("SELECT id, ledger_entity_id from donor where ledger_entity_id = " .
                                              $self->dbh->quote($ledgerEntityId),
                                              "ledger_entity_id");
    # As Connor MacLeod said,  "There can be only one!"
    #  (because of  "ledger_entity_id" varchar(300) NOT NULL UNIQUE,)
    push(@donorIds, $val->{$ledgerEntityId}{id})
      if (defined $val and defined $val->{$ledgerEntityId} and defined $val->{$ledgerEntityId}{id});
  } else {
    my $sql = "SELECT d.id from donor d, email_address ea, donor_email_address_mapping eam " .
              "WHERE eam.email_address_id = ea.id AND d.id = eam.donor_id AND " .
              "ea.email_address = " . $self->dbh->quote($params->{emailAddress});

    $sql .= " AND d.ledger_entity_id = " . $self->dbh->quote($params->{ledgerEntityId})
      if (defined $params->{ledgerEntityId});

    my $val = $self->dbh()->selectall_hashref($sql, 'id');
    push(@donorIds, keys %{$val}) if (defined $val);
  }
  return(@donorIds);
}
######################################################################
# FIXME: docs

sub emailOk($$;$) {
  my($self, $donorId, $additionalTest) = @_;

  confess "lastGave: donorId, \"$donorId\" not found in supporter database"
    unless $self->_verifyId($donorId);

  my $contactSetting;

  my $req = $self->getRequest({donorId => $donorId,
                               requestType => 'contact-setting'});
  $contactSetting =$req->{requestConfiguration}
    if defined $req and defined $req->{requestConfiguration};

  my $answer = ((not defined $contactSetting) or
                      ($contactSetting eq 'no-paper-but-email-ok'));
#  if (defined $additionalTest and defined $contactSetting) {
#    $answer = ($answer or ($contactSetting eq $additionalTest));
#  }
  return $answer;
}

sub paperMailOk($$) {
  my($self, $donorId) = @_;

  confess "lastGave: donorId, \"$donorId\" not found in supporter database"
    unless $self->_verifyId($donorId);

  my $contactSetting;

  my $req = $self->getRequest({donorId => $donorId,
                               requestType => 'contact-setting'});
  $contactSetting =$req->{requestConfiguration}
    if defined $req and defined $req->{requestConfiguration};
  return ((not defined $contactSetting) or
                 ($contactSetting eq 'no-email-but-paper-ok'));
}


######################################################################

=begin donorLastGave

Arguments:

=over

=item $self

Current object.

=item $donorId

   Valid donor id number currently in the database.  die() will occur if
   the id number is not in the database already as a donor id.

=back

Returns an ISO 8601 formatted date of their last donation.  undef will be
returned if the donor has never given (which should rarely be the case, but
it could happen).

=cut

sub donorLastGave($$) {
  my($self, $donorId) = @_;

  confess "lastGave: donorId, \"$donorId\" not found in supporter database"
    unless $self->_verifyId($donorId);

  $self->_readLedgerData() if not defined $self->{ledgerData};

  my $ledgerEntityId = $self->getLedgerEntityId($donorId);

  if (not defined $self->{ledgerData}{$ledgerEntityId} or
      not defined $self->{ledgerData}{$ledgerEntityId}{__LAST_GAVE__} or
      $self->{ledgerData}{$ledgerEntityId}{__LAST_GAVE__} eq '1975-01-01') {
    return undef;
  } else {
    return $self->{ledgerData}{$ledgerEntityId}{__LAST_GAVE__};
  }
}
######################################################################

=begin donorFirstGave

Arguments:

=over

=item $self

Current object.

=item $donorId

   Valid donor id number currently in the database.  die() will occur if
   the id number is not in the database already as a donor id.

=back

Returns an ISO 8601 formatted date of their first donation.  undef will be
returned if the donor has never given (which should rarely be the case, but
it could happen).

=cut

sub donorFirstGave($$) {
  my($self, $donorId) = @_;

  confess "donorFirstGave: donorId, \"$donorId\" not found in supporter database"
    unless $self->_verifyId($donorId);

  $self->_readLedgerData() if not defined $self->{ledgerData};

  my $ledgerEntityId = $self->getLedgerEntityId($donorId);

  if (not defined $self->{ledgerData}{$ledgerEntityId} or
      not defined $self->{ledgerData}{$ledgerEntityId}{__FIRST_GAVE__} or
      $self->{ledgerData}{$ledgerEntityId}{__FIRST_GAVE__} eq '9999-12-31') {
    return undef;
  } else {
    return $self->{ledgerData}{$ledgerEntityId}{__FIRST_GAVE__};
  }
}

######################################################################

=begin donorTotalGaveInPeriod

Arguments:

=over

=item $self

Current object.

=item a list of arguments, which must be even and will be interpreted as a
 hash, with the following keys relevant:

=item donorId

   This mandatory key must have a value of a Valid donor id number currently
   in the database.  die() will occur if the id number is not in the database
   already as a donor id.

=item startDate

   This optional key, if given, must contain an ISO 8601 formatted date for the start
   date of the period.  die() may occur if not in ISO-8601 format.

=item endDate

   This optional key, if given, must contain an ISO 8601 formatted date for the start
   date of the period.  die() may occur if not in ISO-8601 format.

=back

All other hash keys given generate a die().

=back

=cut

sub donorTotalGaveInPeriod($$) {
  my $self = shift @_;

  confess "donorTotalGaveInPeriod: arguments not in hash format" unless (scalar(@_) % 2) == 0;
  my(%args) = @_;

  my $donorId = $args{donorId};  delete $args{donorId};

  confess "donorTotalGaveInPeriod: donorId, \"$donorId\" not found in supporter database"
    unless $self->_verifyId($donorId);

  # FIXME: Does not handle address before the Common Era
  my $startDate = '0000-01-01';
  if (defined $args{startDate}) { $startDate = $args{startDate}; delete $args{startDate}; }

  # FIXME: Year 10,000 problem!

  my $endDate = '9999-12-31';
  if (defined $args{endDate}) { $endDate = $args{endDate}; delete $args{endDate}; }

  my(@argKeys) = keys %args;
  confess("Unknown arugments: ".  join(", ", @argKeys)) if @argKeys > 0;

  foreach my $date ($startDate, $endDate) {
    confess "donorTotalGaveInPeriod: invalid date in argument list, \"$date\""
      unless $date =~ /^\d{4,4}-\d{2,2}-\d{2,2}/;
    # FIXME: check better for ISO-8601.
  }
  $self->_readLedgerData() if not defined $self->{ledgerData};

  my $entityId = $self->getLedgerEntityId($donorId);
  my $amount = 0.00;

  foreach my $date (keys %{$self->{ledgerData}{$entityId}{donations}}) {
    next if $date =~ /^__/;
    $amount += $self->{ledgerData}{$entityId}{donations}{$date}
      if $date ge $startDate and $date le $endDate;
  }
  return $amount;
}

######################################################################

=begin getType

FIXME DOCS

=cut

sub getType ($$) {
  my($self, $donorId) = @_;

  confess "donorFirstGave: donorId, \"$donorId\" not found in supporter database"
    unless $self->_verifyId($donorId);

  return undef unless $self->isSupporter($donorId);
  $self->_readLedgerData() if not defined $self->{ledgerData};

  my $entityId = $self->getLedgerEntityId($donorId);

  return undef unless defined $self->{ledgerData}{$entityId};
  return $self->{ledgerData}{$entityId}{__TYPE__};
}
######################################################################

=begin supporterExpirationDate

Arguments:

=over

=item $self

Current object.

=item $donorId

   Valid donor id number currently in the database.  die() will occur if
   the id number is not in the database already as a donor id.

=back

Returns an ISO 8601 of the expriation date for the supporter identified by
donorId.  Returns undef if the donor is not a supporter or if the donor has
given no donations at all.

Formula for expiration dates currently is as follows:

For annuals, consider donations in the last year only.  The expiration date
is one year from the last donation if the total in the last year >= $120.00

For monthlies, see if they gave $10 or more in the last 60 days.  If they
did, their expiration is 60 days from then.

=cut


my $ONE_YEAR_AGO = UnixDate(DateCalc(ParseDate("today"), "- 1 year"), '%Y-%m-%d');
my $SIXTY_DAYS_AGO = UnixDate(DateCalc(ParseDate("today"), "- 60 days"), '%Y-%m-%d');

sub supporterExpirationDate($$) {
  my($self, $donorId) = @_;

  confess "donorFirstGave: donorId, \"$donorId\" not found in supporter database"
    unless $self->_verifyId($donorId);

  return undef unless $self->isSupporter($donorId);
  $self->_readLedgerData() if not defined $self->{ledgerData};


  my $entityId = $self->getLedgerEntityId($donorId);

  return undef unless defined $self->{ledgerData}{$entityId};

  my $expirationDate;

  my $type = $self->{ledgerData}{$entityId}{__TYPE__};
  if ($type eq 'Monthly') {
    my(@tenOrMore);
    foreach my $date (keys %{$self->{ledgerData}{$entityId}{donations}}) {
      next if $date =~ /^__/;
      push(@tenOrMore, $date) unless ($self->{ledgerData}{$entityId}{donations}{$date} < 10.00);
    }
    $expirationDate = UnixDate(DateCalc(maxstr(@tenOrMore), "+ 60 days"), '%Y-%m-%d')
      if (scalar(@tenOrMore) > 0);

  } elsif ($type eq 'Annual') {
    my($earliest, $total) = (undef, 0.00);
    foreach my $date (sort { $b cmp $a} keys %{$self->{ledgerData}{$entityId}{donations}}) {
      next if $date =~ /^__/;
      $total += $self->{ledgerData}{$entityId}{donations}{$date};
      unless ($total < 120.00) {
        $earliest = $date;
        last;
      }
    }
    $expirationDate = UnixDate(DateCalc($earliest, "+ 1 year"), '%Y-%m-%d')
      if defined $earliest;
  } else {
    confess "supporterExpirationDate: does not function on  $type";
  }
  return $expirationDate;
}
######################################################################

=back

=head1 Non-Public Methods

These methods are part of the internal implementation are not recommended for
use outside of this module.

=over

=item _readLedgerData

=cut

sub _readLedgerData($) {
  my($self) = @_;

  my @cmd = @{$self->{ledgerCmd}};
  my %amountTable;

  open(ALL, "-|", @cmd) or confess "unable to run command ledger command: @cmd: $!";
  while (my $line = <ALL>) {
    next if $line =~ /^\s*$/;
    warn "Invalid line in @cmd output:\n    $line"
      unless $line =~ /^\s*([^\d]+)\s+([\d\-]+)\s+(\S*)\s+\$\s*(\-?\s*[\d,\.]+)\s*$/;
    my($type, $date, $entityId, $amount) = ($1, $2, $3, $4);
    next unless defined $entityId and $entityId !~ /^\s*$/;
    if (defined $self->{programTypeSearch}) {
      if ($type =~ /$self->{programTypeSearch}{annual}/) {
        $type = 'Annual';
      } elsif ($type =~ /$self->{programTypeSearch}{monthly}/) {
        $type = 'Monthly';
      }
    }
    die "Unknown type $type for $entityId from $line" if $type !~ /^(Monthly|Annual)$/ and defined $self->{programTypeSearch};
    $amount =~ s/,//; $amount = abs($amount);
    if (defined $amountTable{$entityId}{donations}{$date}) {
      $amountTable{$entityId}{donations}{$date} += $amount;
    }  else {
      $amountTable{$entityId}{donations}{$date} = $amount;
    }
    unless (defined $amountTable{$entityId}{__TOTAL__}) {
      $amountTable{$entityId}{__TOTAL__} = 0.00;
      $amountTable{$entityId}{__LAST_GAVE__} = '1975-01-01';
      $amountTable{$entityId}{__FIRST_GAVE__} = '9999-12-31';
    }
    $amountTable{$entityId}{__TOTAL__} += $amount;
    if ($date gt $amountTable{$entityId}{__LAST_GAVE__}) {
      # Consider the "type" of the donor to be whatever type they were at last donation
      $amountTable{$entityId}{__TYPE__} = $type;
      $amountTable{$entityId}{__LAST_GAVE__} = $date;
    }
    $amountTable{$entityId}{__FIRST_GAVE__} = $date
      if $date lt $amountTable{$entityId}{__FIRST_GAVE__};
  }
  close ALL; die "error($?) running command, @cmd: $!" unless $? == 0;
  $self->{ledgerData} = \%amountTable;
}

=item DESTROY

=cut

sub DESTROY {
  my $self = shift;
  return unless defined $self;

  # Force rollback if we somehow get destroy'ed while counter is up
  if (defined $self->{__NESTED_TRANSACTION_COUNTER__} and $self->{__NESTED_TRANSACTION_COUNTER__} > 0) {
    my $errorStr = "SUPPORTERS DATABASE ERROR: Mismatched begin_work/commit pair in API implementation";
    if (not defined $self->{dbh}) {
      $errorStr .= "... and unable to rollback or commit work.  Database may very well be inconsistent!";
    } else {
      # Rollback if we didn't call commit enough;  commit if we called commit too often.
      ($self->{__NESTED_TRANSACTION_COUNTER__} > 0) ? $self->_rollback() : $self->_commit();
      $self->{dbh}->disconnect();
    }
    $self->{__NESTED_TRANSACTION_COUNTER__} = 0;
    die $errorStr;
  }
  delete $self->{__NESTED_TRANSACTION_COUNTER__};
  $self->{dbh}->disconnect() if defined $self->{dbh} and blessed($self->{dbh}) =~ /DBI/;
}


=item _verifyId()

Parameters:

=over

=item $self: current object.

=item $id: A scalar numeric argument that is the to lookup


=back

Returns: scalar boolean, which is true iff. the $id is valid and already in the supporter database.


=cut


sub _verifyId($$) {
  my($self, $id) = @_;

  confess "_verifyId(): called with a non-numeric id" unless defined $id and looks_like_number($id);

  my $val = $self->dbh()->selectall_hashref("SELECT id FROM donor WHERE id = " .
                                            $self->dbh->quote($id, 'SQL_INTEGER'), 'id');
  return (defined $val and defined $val->{$id});

}

=item _lookupRequestTypeById()

Parameters:

=over

=item $self: current object.

=item $requestTypeId: A scalar numeric argument that is the request type id to  lookup


=back

Returns: scalar, which is the request_type found iff. the C<$requestTypeId> is valid and
already in the supporter database's request_type table.

Die if the C<$requestTypeId> isn't a number.

=cut


sub _lookupRequestTypeById($$) {
  my($self, $requestTypeId) = @_;

  die "_verifyRequestTypeId() called with a non-numeric id" unless defined $requestTypeId and looks_like_number($requestTypeId);

  my $val = $self->dbh()->selectall_hashref("SELECT id, type FROM request_type WHERE id = " .
                                            $self->dbh->quote($requestTypeId, 'SQL_INTEGER'), 'id');
  if (defined $val and defined $val->{$requestTypeId}) {
    return $val->{$requestTypeId}{type};
  } else {
    return undef;
  }
}
######################################################################

=item _lookupDeliveryError()

Parameters:

=over

=item $self: current object.

=item $errorName: A scalar string argument that is the error

=back

Returns: undef if the error code does not exist in the delivery_error table,
otherwise returns the id for the entry in the delivery_table

=cut

sub _lookupDeliveryError($$) {
}

######################################################################

=item _lookupEmailAddress()

Parameters:

=over

=item $self: current object.

=item $emailAdress: A scalar string argument that is the email_adress


=back

Returns: undef if the email address is not found, otherwise a hash with the following values:

=over

=item emailAddress: The email address as given

=item id: The email_adress.id

=item type: The email_adress type

=item dateEncountered: The date_encountered of this email address.

=back

=cut


sub _lookupEmailAddress($$) {
  my($self, $emailAddress) = @_;

  die "_lookupEmailAddressId() called with undef" unless defined $emailAddress;

  my $val = $self->dbh()->selectall_hashref("SELECT ea.id, ea.email_address, at.name, ea.date_encountered " .
                                            "FROM email_address ea, address_type at " .
                                            "WHERE ea.type_id = at.id AND " .
                                            "email_address = " . $self->dbh->quote($emailAddress),
                                            'email_address');
  if (defined $val and defined $val->{$emailAddress}) {
    return { id => $val->{$emailAddress}{id}, emailAddress => $val->{$emailAddress}{email_address},
             type => $val->{$emailAddress}{name},  dateEncountered => $val->{$emailAddress}{date_encountered}};
  } else {
    return undef;
  }
}

=item _getOrCreateRequestType

Arguments:

=over

=item $params (hash reference)

This hash reference usually contains other paramaters, too, but this method
looks only at the keys C<requestType> and C<requestTypeId>.  If
C<requestTypeId> is set, it simply deletes the C<requestType> parameter and
verifies c<reuqestTypeId> is in the request_type table.

=cut

sub _getOrCreateRequestType($$) {
  my($self, $params) = @_;

  if (not defined $params->{requestTypeId}) {
    $params->{requestTypeId} = $self->addRequestType($params->{requestType});
  } else {
    my $id = $params->{requestTypeId};
    die "_getOrCreateRequestType(): invalid requestTypeId, \"$id\""
      unless defined $self->_lookupRequestTypeById($id);
  }
  delete $params->{requestType};
}

=item _getOrCreateRequestConfiguration

Arguments:

=over

=item $params (hash reference)

This hash reference usually contains other paramaters, too, but this method
looks only at the keys C<requestTypeId>, C<requestConfiguration> and
C<requestConfigurationId>.  If C<requestConfigurationId> is set, it simply
deletes the C<requestConfiguration> parameter and verifies c<reuqestTypeId>
is in the request_type table.

=cut

sub _getOrCreateRequestConfiguration($$) {
  my($self, $params) = @_;

  die "_getOrCreateRequestConfiguration: requestTypeId is required" unless defined $params->{requestTypeId};
  my $requestTypeId = $params->{requestTypeId};
  die "_getOrCreateRequestConfiguration: requestTypeId must be a number" unless looks_like_number($requestTypeId);

  my $val = $self->dbh()->selectall_hashref("SELECT id, type FROM request_type WHERE id = " .
                                            $self->dbh->quote($requestTypeId, 'SQL_INTEGER'), 'id');
  die "_getOrCreateRequestConfiguration: unknown requestTypeId, \"$requestTypeId\""
    unless (defined $val and defined $val->{$requestTypeId} and defined $val->{$requestTypeId}{type});
  my $requestType =  $val->{$requestTypeId}{type};

  my $existingRequestConfig =  $self->getRequestConfigurations($requestType);

  die "_getOrCreateRequestConfiguration: requestTypeId is unknown" unless (keys(%$existingRequestConfig) == 1);

  if (not defined $params->{requestConfigurationId}) {
    die "_getOrCreateRequestConfiguration: requestConfiguration is not defined" unless defined $params->{requestConfiguration};
    if (defined $existingRequestConfig->{$requestTypeId}{$params->{requestConfiguration}}) {
      $params->{requestConfigurationId} = $existingRequestConfig->{$requestTypeId}{$params->{requestConfiguration}};
    } else {
      $existingRequestConfig = $self->addRequestConfigurations($requestType, [ $params->{requestConfiguration} ]);
      $params->{requestConfigurationId} = $existingRequestConfig->{$requestTypeId}{$params->{requestConfiguration}};
    }
  } else {
    my $id = $params->{requestConfigurationId};
    die "_getOrCreateRequestConfiguration(): called with a non-numeric requestConfigurationId, \"$id\""
      unless defined $id and looks_like_number($id);
    my $found = 0;
    foreach my $foundId (values %{$existingRequestConfig->{$requestTypeId}}) { if ($foundId == $id) { $found = 1; last; } }
    die "_getOrCreateRequestType(): given requestConfigurationId, \"$id\", is invalid"
       unless defined $found;
  }
  delete $params->{requestConfiguration};
  return $params->{requestConfigurationId};
}

=item _beginWork()

Parameters:

=over

=item $self: current object.

=back

Returns: None.

This method is a reference counter to keep track of nested begin_work()/commit().


=cut

sub _beginWork($) {
  my($self) = @_;

  if ($self->{__NESTED_TRANSACTION_COUNTER__} < 0) {
    die "_beginWork: Mismatched begin_work/commit pair in API implementation";
    $self->{__NESTED_TRANSACTION_COUNTER__} = 0;
  }
  $self->dbh->begin_work() if ($self->{__NESTED_TRANSACTION_COUNTER__}++ == 0);
}

=item _commit()

Parameters:

=over

=item $self: current object.

=back

Returns: None.

This method is a reference counter to keep track of nested begin_work()
transactions to verify we don't nest $self->dbh->begin_work()

=cut

sub _commit($) {
  my($self) = @_;

  if ($self->{__NESTED_TRANSACTION_COUNTER__} < 0) {
    die "_commit: Mismatched begin_work/commit pair in API implementation";
    $self->{__NESTED_TRANSACTION_COUNTER__} = 0;
  }
  $self->dbh->commit() if (--$self->{__NESTED_TRANSACTION_COUNTER__} == 0);
}

=item _rollback()

Parameters:

=over

=item $self: current object.

=back

Returns: None.

This method resets the reference counter entirely and calls $dbh->rollback.

=cut

sub _rollback($) {
  my($self) = @_;

  $self->{__NESTED_TRANSACTION_COUNTER__} = 0;
  $self->dbh->rollback();
}

=back

=cut

1;
__END__

=head1 NAME

Supporters - Simple database of supporters of an organation.

=head1 SYNOPSIS

  use Supporters;

=head1 DESCRIPTION

Supporters is an extremely lightweight alternative to larger systems like
CiviCRM to manage a database of Supporters.  The module assumes a setup that
works with Ledger-CLI to find the actual amounts donated.

=head2 EXPORT

None by default.

=head1 AUTHOR

Bradley M. Kuhn, E<lt>bkuhn@ebb.org<gt>

=head1 COPYRIGHT AND LICENSE

See COPYRIGHT.md and LICENSE.md in the main distribution of this software.

License: AGPLv3-or-later

=cut

###############################################################################
#
# Local variables:
# compile-command: "perl -c Supporters.pm"
# End:
