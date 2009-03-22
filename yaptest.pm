
=head1 NAME

yaptest - API calls used by yaptest-*.pl scripts

=cut

package yaptest;

use strict;
use warnings;
use DBI;
use Data::Dumper;
use Carp;
use Parallel::ForkManager;
use File::Temp qw/ tempfile /;
use File::Basename;
use strict;
use Cwd 'abs_path';
use Digest::MD4 qw(md4 md4_hex md4_base64);
use POSIX;
use IO::Pty;
use XML::Simple;
use IPC::SysV qw(IPC_CREAT SEM_UNDO);

$Carp::Verbose = 1;

my $global_test_area = "";
my $global_test_area_id = undef;
my $global_debug = 0;
my $is_child = 0;

BEGIN {
	# Print banner to make output less messy
	our $VERSION = "0.2.1";
	my $message1 = "Starting " . basename($0) ;
	my $message2 = "*  [ Using yaptest v$yaptest::VERSION - http://pentestmonkey.net/projects/yaptest ]  *";
	my $space_count = int((length($message2) - length($message1) - 2) / 2);
	my $extra_space = length($message2) - length($message1) - 2 - 2 * $space_count;
	$message1 = "*" . (" " x $space_count) . "$message1" . (" " x ($space_count + $extra_space)) . "*";
	warn "\n";
	warn "*" x length($message2) . "\n";
	warn "$message1\n";
	warn "$message2\n";
	warn "*" x length($message2) . "\n";
	warn "\n";
}

sub new {
	my $class = shift;
	my $newdbname = shift;
	my $new_config_file = shift;
	my $self = bless {};
	$self->{config} = {};

	if ($ENV{"YAPTEST_DEBUG"}) {
		$global_debug = $ENV{"YAPTEST_DEBUG"};
	}

	# Read in the global yaptest config file if it exists.
	# Setting in here can be overridden by user's own config file later.
	if (-r "/etc/yaptest.conf") {
		$self->set_config('yaptest_config_file', "/etc/yaptest.conf");
		$self->read_config();
	}

	if (defined($newdbname)) {
		# Must use the config file from ~ if we're starting a new DB
		$self->set_config('yaptest_config_file', "$ENV{'HOME'}/.yaptestrc");

	} elsif (defined($ENV{'YAPTEST_CONFIG_FILE'})) {
		# Use the config file pointed to by env var if it's set
		$self->set_config('yaptest_config_file', $ENV{'YAPTEST_CONFIG_FILE'});

	} else {
		# Otherwise use the config file from ~
		$self->set_config('yaptest_config_file', "$ENV{'HOME'}/.yaptestrc");
	}

	# Populate $self->{config}
	if (-e $self->get_config('yaptest_config_file')) {
		$self->read_config();
	} else {
		# Some defaults
		$self->set_config('yaptest_dbuser', 'yaptest_user');
		$self->set_config('yaptest_dbpassword', '');
		$self->set_config('yaptest_debug', '0');
		$self->set_config('yaptest_dbport', '5432');
		$self->set_config('yaptest_dbhost', '127.0.0.1');
		$self->set_config('yaptest_dbtemplate', 'yaptest_template');
		if (-e '/etc/master.passwd') {
			# Use en0 if we're running on OSX
			$self->set_config('yaptest_interface', 'en0');
		} else {
			# Use eth0 if we're running on Linux
			$self->set_config('yaptest_interface', 'eth0');
		}
		$self->set_config('nessusd_ip', '127.0.0.1');
		$self->set_config('nessusd_port', '1241');
		$self->set_config('nessusd_username', 'nessus');
		$self->set_config('nessusd_password', 'nessus');
		$self->set_config('nessus_config_template', '/usr/local/share/yaptest/nessusrc-template');
		$self->write_config();
	}

	# Check if YAPTEST_DBNAME is set.  It is compulsory.
	if ($ENV{"YAPTEST_DBNAME"}) {
		unless ($ENV{"YAPTEST_DBNAME"} =~ /^[a-z0-9_]{1,50}$/) {
			croak "ERROR: Environment variable YAPTEST_DBNAME contains some funny characters: ". $ENV{"YAPTEST_DBNAME"} . ".  Only the characters a-z0-9_ are allowed.\n";
		}
		$self->set_config('yaptest_dbname', $ENV{"YAPTEST_DBNAME"});
	}
	
	# Check option environment variables and use them to override built in default.
	if ($ENV{"YAPTEST_DBTEMPLATE"}) {
		unless ($ENV{"YAPTEST_DBTEMPLATE"} =~ /^[.a-z0-9_]{1,25}$/) {
			croak "ERROR: Environment variable YAPTEST_DBTEMPLATE contains some funny characters: ". $ENV{"YAPTEST_DBTEMPLATE"} . ".  Only the characters .a-z0-9_ are allowed.\n";
		}
		$self->set_config('yaptest_dbtemplate', $ENV{"YAPTEST_DBTEMPLATE"});
	}
	if ($ENV{"YAPTEST_DBHOST"}) {
		unless ($ENV{"YAPTEST_DBHOST"} =~ /^[.a-zA-Z0-9_]{1,25}$/) {
			croak "ERROR: Environment variable YAPTEST_DBHOST contains some funny characters: ". $ENV{"YAPTEST_DBHOST"} . ".  Only the characters .a-zA-Z0-9_ are allowed.\n";
		}
		$self->set_config('yaptest_dbhost', $ENV{"YAPTEST_DBHOST"});
	}
	if ($ENV{"YAPTEST_DBPORT"}) {
		unless ($ENV{"YAPTEST_DBPORT"} =~ /^[0-9]{1,5}$/) {
			croak "ERROR: Environment variable YAPTEST_DBPORT contains some funny characters: ". $ENV{"YAPTEST_DBPORT"} . ".  Only the characters 0-9 are allowed.\n";
		}
		$self->set_config('yaptest_dbport', $ENV{"YAPTEST_DBPORT"});
	}
	if ($ENV{"YAPTEST_DBUSER"}) {
		$self->set_config('yaptest_dbuser', $ENV{"YAPTEST_DBUSER"});
	}
	if ($ENV{"YAPTEST_DBPASSWORD"}) {
		$self->set_config('yaptest_dbpassword', $ENV{"YAPTEST_DBPASSWORD"});
	}

	# If a new database name was specified, create it.
	if ($newdbname) {
		if ($newdbname =~ /[A-Z]/) {
			$newdbname = lc $newdbname;
			print "WARNING: Backend database doesn't support uppercase letters in database name.  Folding to lower case: $newdbname\n";
		}

		unless ($newdbname =~ /^[a-z0-9_]{1,50}$/) {
			croak "ERROR: Envornment new database name contains some funny characters: $newdbname.  Only the characters a-z0-9_ are allowed.\n";
		}
		$self->set_config('yaptest_dbname', $newdbname);
		$self->_createdb();
	} else {
		unless ($self->get_config('yaptest_dbname')) {
			croak "ERROR: Environment variable YAPTEST_DBNAME is not set.  Maybe you need to run 'source env.sh'.\n";
		}
	}
	
	# Connect to database
	$self->_connect(dbname => $self->get_config('yaptest_dbname'));


	if (defined($new_config_file)) {
		# Get full path of new config file
		$new_config_file = abs_path($new_config_file);
		print "Config file: $new_config_file\n";

		# Create new config file
		$self->set_config('yaptest_config_file', $new_config_file);
		$self->write_config();

		# Create env.sh
		$self->create_env_sh();
	}

	if (!defined($newdbname)) {
		# Check test area is valid
		if ($ENV{"YAPTEST_TESTAREA"}) {
			$self->set_test_area($ENV{"YAPTEST_TESTAREA"});
		} elsif (defined($self->get_config('yaptest_test_area'))) {
			$self->set_test_area($self->get_config('yaptest_test_area'));
		}
	}

	return $self;
}

sub create_env_sh {
	my $self = shift;

	# Get full path of new config file
	$self->set_config('yaptest_config_file', abs_path($self->get_config('yaptest_config_file')));

	print "Creating file env.sh\n";
	open (FILE, ">env.sh") or die "ERROR: Can't write to env.sh: $!\n";
	print FILE "YAPTEST_CONFIG_FILE=\"" . $self->get_config('yaptest_config_file') ."\"; export YAPTEST_CONFIG_FILE\n";
	close(FILE);
}

sub write_config {
	my $self = shift;
	print "Writing to config file " . $self->get_config('yaptest_config_file') . "\n";
	open (FILE, ">" . $self->get_config('yaptest_config_file')) or croak "ERROR: Can't write to config file " . $self->get_config('yaptest_config_file') . ": $!\n"; 
	foreach my $key (sort keys %{$self->{config}}) {
		next if $key eq "yaptest_config_file";
		print FILE "$key = " . $self->{config}->{$key} . "\n";
		print "write_config: Saving setting: $key = " . $self->{config}->{$key} . "\n" if $global_debug;
	}
	close(FILE);
}

sub dump_config {
	my $self = shift;
	foreach my $key (sort keys %{$self->{config}}) {
		print "$key => " . $self->{config}->{$key} . "\n";
	}
}

sub read_config {
	my $self = shift;
	open (FILE, "<" . $self->get_config('yaptest_config_file')) or croak "ERROR: Can't read to config file " . $self->get_config('yaptest_config_file') . ": $!\n"; 
	while (<FILE>) {
		chomp;
		my $line = $_;
		next if $line =~ /^#/;
		next unless $line =~ /^\s*(\S+)\s*=\s*(.*?)\s*$/;
		my $key = $1;
		my $value = $2;
		next if $key eq "yaptest_config_file";
		$self->set_config($key, $value);
	}
	close(FILE);
}

sub set_config {
	my $self = shift;
	my $conf_key = shift;
	my $conf_value = shift;
	print "set_config: Setting $conf_key => $conf_value\n" if $global_debug;

	$self->{config}->{$conf_key} = $conf_value;
}

# NB yaptest_user will need createdb privs: update pg_shadow set usecreatedb = true where usename = 'yaptest_user';
sub _createdb {
	my $self = shift;
	my %args = (
			dbname   => $self->get_config('yaptest_dbname'),
			template => $self->get_config('yaptest_dbtemplate'),
			username => $self->get_config('yaptest_dbuser'),
			password => $self->get_config('yaptest_dbpassword'),
			host     => $self->get_config('yaptest_dbhost'),
			port     => $self->get_config('yaptest_dbport'),
			@_
		);
	my $dbh = DBI->connect("dbi:Pg:dbname=" . $args{template} . ";host=" . $args{host} . ";port=" . $args{port}, $args{username}, $args{password}, { RaiseError => 1, AutoCommit => 1 });
	$dbh->{pg_server_prepare} = 0;

	# Can't use prepared statements for CREATE DATABASE, so it's important
	# that the untainting above is effective.
	# TODO: Use db quoting functions
	# TODO: Support postgres 8.2.  Here's how, but I don't fancy patching
	#       the .pm file at runtime.
	# $dbh->do("SET ROLE yaptest_createdb_role");
	# $dbh->do("
	#          CREATE DATABASE " . $args{dbname} . "
	#          OWNER yaptest_createdb_role
	#          TEMPLATE " . $args{template} . "
	# ");
	$dbh->do("
		CREATE DATABASE " . $args{dbname} . "
		OWNER " . $args{username} . "
		TEMPLATE " . $args{template} . "
	");

	$dbh->disconnect;
}

sub _connect {
	my $self = shift;
	my %args = (
			dbname   => $self->get_config('yaptest_dbname'),
			username => $self->get_config('yaptest_dbuser'),
			password => $self->get_config('yaptest_dbpassword'),
			host     => $self->get_config('yaptest_dbhost'),
			port     => $self->get_config('yaptest_dbport'),
			@_
		);
	$self->{dbh}= DBI->connect("dbi:Pg:dbname=" . $args{dbname} . ";host=" . $args{host} . ";port=" . $args{port}, $args{username}, $args{password}, { RaiseError => 1, AutoCommit => 0 });
	$self->{dbh}->{pg_server_prepare} = 0;
}

sub test {
	my $self = shift;
	print "Inserting a MAC...\n";
	$self->insert_mac("1:2:3:4:5:6");

	print "Select MAC id...\n";
	print "ID: " . $self->get_id_of_mac("1:2:3:4:5:6") . "\n";

	print "Inserting an IP...\n";
	$self->insert_ip("1.2.3.4");

	print "Inserting a MAC, IP...\n";
	$self->insert_ip_and_mac("11.22.33.44", "11:22:33:44:55:66");

	printf "Inserting port...\n";
	$self->insert_port(ip => "1.2.3.4", transport_protocol => "tCp", port => 80);

	print "Selecting all MACs\n";
	my $sth2 = $self->get_dbh->prepare("SELECT mac_address from mac_addresses");
	$sth2->execute;
	while (my ($mac_address) = $sth2->fetchrow_array) {
		print "Read MAC: $mac_address\n";
	}
}

sub get_test_area {
	return $global_test_area;
}

sub set_test_area {
	my $self = shift;
	my $test_area = shift;
	print "set_test_area called with test_area $test_area\n" if $global_debug;

	unless ($test_area =~ /^[.a-zA-Z0-9_-]{1,50}$/) {
		croak "ERROR: Test area contains some funny characters: ". $ENV{"YAPTEST_TESTAREA"} . "\n";
	}

	if (defined(my $id = $self->get_id_of_test_area($test_area))) {
		$global_test_area = $test_area;
		$global_test_area_id = $id;
		return 1;
	} else {
		croak "ERROR: Environment variable YAPTEST_TESTAREA doesn't correspond to an existing test area.  Create it first.\n";
	}
}

# $self->insert_test_area("vlan1", "dir/yaptest.conf", "The first VLAN");
sub insert_test_area {
	my $self = shift;
	my %args = @_;
	my $test_area = $args{name};
	my $config_file = $args{config_file};
	my $description = $args{description};
	print "insert_test_area called with test_area $test_area, config file $config_file\n" if $global_debug;

	unless (defined($test_area)) {
		croak "INTERNAL ERROR: insert_test_area called without a test_area.  Bug in code.  Sorry.\n";
	}

	my $id = $self->get_id_of_test_area($test_area);

	if (defined($test_area) and defined($config_file)) {
		# Create test area
		if (defined($id)) {
			warn "WARNING: insert_test_area called for test_area $test_area which already exists\b";
		} else {
			my $sth = $self->get_dbh->prepare("INSERT INTO test_areas (name, description) VALUES (?, ?)");
			$sth->execute($test_area, $description);
			$self->get_dbh->commit;
		
			$id = $self->get_id_of_test_area($test_area);

			$self->set_config('yaptest_test_area', $test_area);
			$self->set_config('yaptest_config_file', $config_file);
			$self->write_config();
			$self->create_env_sh();
		}

	} elsif (defined($test_area) and defined($description)) {
		# Update test area description
		if (defined($id)) {
			my $sth = $self->get_dbh->prepare("UPDATE test_areas SET description = ? WHERE id = ?");
			$sth->execute($description, $id);
			$self->get_dbh->commit;
		} else {
			warn "WARNING: insert_test_area can't update description for $test_area because it doesn't exist\b";
		}
	}

	return $id;
}

sub add_group {
	my $self = shift;
	my %opts = @_;

	# Below we put %opts first so that "username => blah" will overwrite 
	# any username passed.
	$self->insert_credential(%opts, group => 1, username => $opts{group_name});
}

sub add_group_membership {
	my $self = shift;
	my %opts = @_;

	my $group_href = $opts{group};
	my $member_href = $opts{member};

	# Member must be the same type as group.  We'll add this automatically.
	$member_href->{credential_type_name} = $group_href->{credential_type_name};

	# Find cred id of member.  Add if necessary.
	if (defined($member_href->{domain}) and not defined($member_href->{ip_address})) {
		# We were only passed the domain and not an IP.  We need to find the address
		# of a DC for the domain we were passwd and use that.
		my $aref = $self->get_host_info(key => "windows_dc", value => $member_href->{domain});
		unless (@$aref) {
			carp "WARNING: add_group_membership was passwd a domain, but can't find a DC.  Skipping.\n";
			return undef;
		}
		$member_href->{ip_address} = $aref->[0]->{ip_address};
	}
	$member_href->{host_id} = $self->get_id_of_ip($member_href->{ip_address});
	$member_href->{credential_id} = $self->insert_credential(%$member_href);

	# Find cred id of group.  Must already exist.
	$group_href->{gid} = undef; # FIXME
	$group_href->{host_id} = $self->get_id_of_ip($group_href->{ip_address});
	$group_href->{credential_id} = $self->get_credential_id(%$group_href);

	unless (defined($group_href->{credential_id})) {
		print "WARNING: Can't credential_id for the following group.  Skipped.\n";
		print Dumper $group_href;
		return undef;
	}
	
	print "Group:\n" if $global_debug;
	print Dumper $group_href if $global_debug;
	print "Member:\n" if $global_debug;
	print Dumper $member_href if $global_debug;

	# Associate member with group
	my $id = $self->get_groupmem_id(member_id => $member_href->{credential_id}, group_id => $group_href->{credential_id});
	unless (defined($id)) {
		my $sth = $self->get_dbh->prepare("INSERT INTO group_memberships (group_id, member_id) VALUES (?, ?)");
		$sth->execute($group_href->{credential_id}, $member_href->{credential_id});
		$id = $self->get_groupmem_id(member_id => $member_href->{credential_id}, group_id => $group_href->{credential_id});
	}

	return $id;

	# Resolve group to id
	if (defined($opts{group_id})) {
		croak "ERROR: add_group_membership was passed a bad group_id\n" unless defined($self->get_group_name_from_id($opts{group_id}));
	} elsif (defined($opts{group_name})) {
		$opts{group_id} = $self->add_group(group_name => $opts{group_name}, %opts);
	} else {
		croak "ERROR: add_group_membership wasn't passed a group_name or group_id\n";
	}

	# Resolve ip to id
	if (defined($opts{ip_address})) {
		$opts{host_id} = $self->get_id_of_ip($opts{ip_address});
	}

	# Resolve port to id
	if (defined($opts{host_id}) and defined($opts{port}) and defined($opts{transport_protocol})) {
		$opts{port_id} = $self->get_id_of_port(host_id => $opts{host_id}, transport_protocol => $opts{transport_protocol}, port => $opts{port});
	}

	# Check we have a credential (username / host combo)
	if (defined($opts{credential_id})) {
		# TODO check it's valid
	} elsif (defined($opts{username}) and defined($opts{port_id})) {
		$opts{credential_id} = $self->get_credential_id(port_id => $opts{port_id}, username => $opts{username});
	} elsif (defined($opts{username}) and defined($opts{host_id})) {
		# $opts{credential_id} = $self->get_credential_id(host_id => $opts{host_id}, username => $opts{username});
		$opts{credential_id} = $self->insert_credential(host_id => $opts{host_id}, username => $opts{username});
	} else {
		croak "ERROR: add_group_membership couldn't get credential id\n";
	}
	
	return $id;
}

sub get_groupmem_id {
	my $self = shift;
	my %opts = @_;

	my $sth = $self->get_dbh->prepare("SELECT id FROM group_memberships WHERE member_id = ? AND group_id = ?");

	$sth->execute($opts{member_id}, $opts{group_id});
	my ($id) = $sth->fetchrow_array;

	return $id;
}

sub get_group_id_from_name {
	my $self = shift;
	my $name = shift;

	my $sth = $self->get_dbh->prepare("SELECT id FROM credentials WHERE username = ? AND \"group\" IS TRUE");
	$sth->execute($name);
	my ($id) = $sth->fetchrow_array;

	return $id;
}

sub get_group_name_from_id {
	my $self = shift;
	my $id = shift;

	my $sth = $self->get_dbh->prepare("SELECT username FROM credentials WHERE id = ? AND \"group\" IS TRUE");
	$sth->execute($id);
	my ($name) = $sth->fetchrow_array;

	return $name;
}

sub get_test_areas {
	my $self = shift;
	my @test_areas = ();

	my $sth = $self->get_dbh->prepare("SELECT id, name, description FROM test_areas ORDER BY name");
	$sth->execute();

	my $test_areas_aref = [];
        while (my $test_area_href = $sth->fetchrow_hashref) {
		push @$test_areas_aref, $test_area_href;
	}

	return $test_areas_aref;
}

sub insert_os_username {
	my $self = shift;
	my $username = shift;
	my $host = shift;
	print "insert_os_username called with username $username, host $host\n" if $global_debug;

	my $user_id = $self->get_id_of_os_username($username, $host);
	my $host_id = $self->insert_ip($host);

	if (defined($user_id)) {
		return $user_id;
	} else {
		my $sth = $self->get_dbh->prepare("INSERT INTO os_usernames (username, host_id) VALUES (?, ?)");
		$sth->execute($username, $host_id);
		$self->get_dbh->commit;
	
		return $self->get_id_of_os_username($username, $host);
	}
}

sub get_id_of_credential_type {
	my $self = shift;
	my $credential_type = shift;
	print "get_id_of_credential_type called with credential_type $credential_type\n" if $global_debug;

	my $sql = "SELECT id FROM credential_types WHERE name = ?";
	print "get_id_of_credential_type: SQL query: $sql\n" if $global_debug;
	my $sth = $self->get_dbh->prepare($sql);
	$sth->execute($credential_type);
	my ($id) = $sth->fetchrow_array;

	return $id;
}

sub get_id_of_password_hash_type {
	my $self = shift;
	my $password_hash_type = shift;
	print "get_id_of_password_hash_type called with password_hash_type $password_hash_type\n" if $global_debug;

	my $sth = $self->get_dbh->prepare("SELECT id FROM password_hash_types WHERE name = ?");
	$sth->execute($password_hash_type);
	my ($id) = $sth->fetchrow_array;

	return $id;
}

sub insert_password_hash_type {
	my $self = shift;
	my $password_hash_type = shift;
	print "insert_password_hash_type called with type $password_hash_type\n" if $global_debug;

	my $type_id = $self->get_id_of_password_hash_type($password_hash_type);

	if (defined($type_id)) {
		return $type_id;
	} else {
		my $sth = $self->get_dbh->prepare("INSERT INTO password_hash_types (name) VALUES (?)");
		$sth->execute($password_hash_type);
		$self->get_dbh->commit;
	
		return $self->get_id_of_password_hash_type($password_hash_type);
	}
}

sub insert_credential_type {
	my $self = shift;
	my $credential_type = shift;
	print "insert_credential_type called with type $credential_type\n" if $global_debug;

	my $type_id = $self->get_id_of_credential_type($credential_type);

	if (defined($type_id)) {
		return $type_id;
	} else {
		my $sth = $self->get_dbh->prepare("INSERT INTO credential_types (name) VALUES (?)");
		$sth->execute($credential_type);
		$self->get_dbh->commit;
	
		return $self->get_id_of_credential_type($credential_type);
	}
}

sub check_id {
	my $self = shift;
	my $table = shift;
	my $id = shift;
	my $sth = $self->get_dbh->prepare("SELECT id FROM $table WHERE id = ?");
	$sth->execute($id);
	my ($db_id) = $sth->fetchrow_array();

	return $db_id;
}

sub commit {
	my $self = shift;
	$self->get_dbh->commit;
}

# # $y->insert_password(uid => $u, host_id => $h, port_id => $p, credential_type_id => $c, crendential_type_name => $c, domain => $domain, ip_address => $i, port => $p, transport_protocol => $t, username => $username, password => $password, password_hash => $password_hash, password_hash_type => $p, test_area => $test_area)
sub insert_credential {
 	my $self = shift;
 	my %args = @_;

	print "insert_credential passed:\n" if $global_debug;
	print Dumper \%args if $global_debug;
	
	# If we're passed a test_area, use it
	if (defined($args{test_area})) {
		$args{test_area_id} = $self->get_id_of_test_area($args{test_area});
	} else {
		$args{test_area_id} = $global_test_area_id;
	}
	
	# Determine UID - can be null
	if (defined($args{uid})) {
		unless ($args{uid} =~ /^\d+$/) {
			croak "ERROR: Non-numeric UID passed to insert_credential\n";
		}
	} else {
		$args{uid} = undef;
	}

	# Determine host_id - not null
	if (defined($args{host_id})) {
		croak "ERROR: Invalid host_id passed to insert_credential\n" unless defined($self->check_id("hosts", $args{host_id}));
	} elsif (defined($args{ip_address})) {
		$args{host_id} = $self->get_id_of_ip($args{ip_address});
	} else {
		croak "ERROR: Couldn't determine host_id while adding credentials\n";
	}
	
	# Determine port_id - can be null
	if (defined($args{port_id})) {
		croak "ERROR: Invalid port_id passed to insert_credential\n" unless defined($self->check_id("ports", $args{port_id}));
	} elsif (defined($args{host_id}) and defined($args{port} and defined($args{transport_protocol}))) {
		$args{port_id} = $self->insert_port(host_id => $args{host_id}, transport_protocol => $args{transport_protocol}, port => $args{port});
	} else {
		$args{port_id} = undef;
	}
	
	# Determine credential_type_id - not null
	if (defined($args{credential_type_id})) {
		croak "ERROR: Invalid credential_type_id passed to insert_credential\n" unless defined($self->check_id("credential_types", $args{credential_type_id}));
	} elsif (defined($args{credential_type_name})) {
		$args{credential_type_id} = $self->insert_credential_type($args{credential_type_name});
	} else {
		croak "ERROR: Couldn't determine credential_type_id while adding credentials\n";
	}
	
	# Determine domain - can be null
	unless (defined($args{domain})) {
		# Automagically look up domain name if we're adding a Windows username
		# and we already know that the host is a domain controller
		if ($args{credential_type_name} eq "os_windows") {
	        	my $domain_aref = $self->get_host_info(host_id => $args{host_id}, key => "windows_dc");
	                if (@$domain_aref) {
				$args{domain} = $domain_aref->[0]->{value};
	                } else {
				$args{domain} = undef;
	                }
		} else {
			$args{domain} = undef;
		}
	}
	
	# Determine username - can be null
	unless (defined($args{username})) {
		$args{username} = undef;
	}
	
	# Determine password - can be null
	unless (defined($args{password})) {
		$args{password} = undef;
	}
	
	# Determine password_hash - can be null
	unless (defined($args{password_hash})) {
		$args{password_hash} = undef;
	}
	
	# Determine password_hash_type_id - can be null
	if (defined($args{password_hash_type_id})) {
		croak "ERROR: Invalid password_hash_type_id passed to insert_credential\n" unless defined($self->check_id("password_hash_types", $args{password_hash_type_id}));
	} elsif (defined($args{password_hash_type})) {
		$args{password_hash_type_id} = $self->insert_password_hash_type($args{password_hash_type});
	} else {
		$args{password_hash_type} = undef;
	}

	# Assume we're not adding a group unless $args{group} is set
	unless (defined($args{group})) {
		$args{group} = 0;
	}

	# Check if records is already present and should be UPDATEd
	# of if it's new and should be INSERTed.
	
	my $id;

	if (defined($args{password}) and !defined($args{username})) {
		# This strange-looking condition is primarily for snmp community strings
		$id = $self->get_credential_id(
			host_id  => $args{host_id},
			port_id  => $args{port_id},
			domain   => $args{domain},
			password => $args{password},
			password_hash_type_id => $args{password_hash_type_id},
			credential_type_id    => $args{credential_type_id},
		);
	} elsif ($args{credential_type_name} eq "os_unix" and defined($args{group})) {
		$id = $self->get_credential_id(
			host_id  => $args{host_id},
			port_id  => $args{port_id},
			domain   => $args{domain},
			username => $args{username},
			group    => $args{group},
			credential_type_id    => $args{credential_type_id},
		);
	} elsif ($args{credential_type_name} eq "os_unix") {
		$id = $self->get_credential_id(
			host_id  => $args{host_id},
			port_id  => $args{port_id},
			domain   => $args{domain},
			username => $args{username},
			credential_type_id    => $args{credential_type_id},
		);
	# allow a cred with a password hash to overwrite one without
	# e.g. first pwdump import will overwrite info from enum4linux - we don't want both in DB
	} elsif ($args{credential_type_name} eq "os_windows") {
		# check for an enum4linux entry to overwrite
		my $id1 = $self->get_credential_id(
			host_id  => $args{host_id},
			port_id  => $args{port_id},
			domain   => $args{domain},
			username => $args{username},
			password_hash_type_id => undef,
			credential_type_id    => $args{credential_type_id},
		);

		if (defined($id1)) {
			$id = $id1;
		} else {
			# Check for an entry with the corresponding pwd hash type to overwrite
			$id = $self->get_credential_id(
				host_id  => $args{host_id},
				port_id  => $args{port_id},
				domain   => $args{domain},
				username => $args{username},
				password_hash_type_id => $args{password_hash_type_id},
				credential_type_id    => $args{credential_type_id},
			);
		}
	} else {
		$id = $self->get_credential_id(
			host_id  => $args{host_id},
			port_id  => $args{port_id},
			domain   => $args{domain},
			username => $args{username},
			password_hash_type_id => $args{password_hash_type_id},
			credential_type_id    => $args{credential_type_id},
		);
	}

	if (defined($id)) {
		print "insert_credential: Cred is already in DB with ID $id\n" if $global_debug;
		my @set_clauses;
		my @set_values;

		foreach my $field (qw(host_id port_id domain username password password_hash password_hash_type_id credential_type_id uid)) {
			if (defined($args{$field})) {
				push @set_clauses, "$field = ?";
				push @set_values, $args{$field};
			}
		}

		my $set_clause;
		$set_clause = join(", ", @set_clauses);
		my $sql = "UPDATE credentials SET $set_clause WHERE id = ?";
		print "SQL: $sql\n" if $global_debug;
		my $sth = $self->get_dbh->prepare($sql);
		$sth->execute(@set_values, $id);

	} else {
		my $sth = $self->get_dbh->prepare("INSERT INTO credentials (\"group\", host_id, port_id, domain, username, password, password_hash, password_hash_type_id, credential_type_id, uid) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)");
		$sth->execute($args{group}, $args{host_id}, $args{port_id}, $args{domain}, $args{username}, $args{password}, $args{password_hash}, $args{password_hash_type_id}, $args{credential_type_id}, $args{uid});

		$id = $self->get_credential_id(
			host_id => $args{host_id},
			port_id => $args{port_id},
			domain => $args{domain},
			username => $args{username},
			password => $args{password},
			password_hash => $args{password_hash},
			password_hash_type_id => $args{password_hash_type_id},
			credential_type_id => $args{credential_type_id},
			uid => $args{uid}
		);
	}

	$self->commit();
	return $id;
}

sub update_half_hashes {
	my $self = shift;

	my $sth = $self->get_dbh->prepare("
		UPDATE credentials SET 
			hash_half2 = SUBSTR(password_hash, 17, 16), 
			hash_half1 = SUBSTR(password_hash, 1, 16) 
		WHERE (hash_half1 IS NULL OR hash_half2 IS NULL) AND password_hash_type_id IN (
			SELECT id FROM password_hash_types WHERE name = 'lanman'
		)"
	);
	$sth->execute();
	$self->get_dbh->commit;
}

sub get_command_list {
	my $self = shift;
	my $sth = $self->get_dbh->prepare("SELECT id AS command_id, name AS command_template FROM commands ORDER BY command_id");
	$sth->execute();
	my $aref = [];
	while (my $href = $sth->fetchrow_hashref) {
		push @$aref, $href;
	}
	return $aref;
}

sub reset_progress {
	my $self = shift;
	my $command_id = shift;
	my %args = @_;

	my @where_clauses;
	my @where_values;
	if (defined($args{port})) {
		if (ref($args{port}) eq 'ARRAY') {
			if (@{$args{port}}) {
				push @where_clauses, "port IN (" . (join ', ', map {'?'} @{$args{port}}) . ")";
				push @where_values, @{$args{port}};
			}
		} else {
			push @where_clauses, "port = ?";
			push @where_values, $args{port};
		}
	}
	if (defined($args{ip_address})) {
		if (ref($args{ip_address}) eq 'ARRAY') {
			if (@{$args{ip_address}}) {
				push @where_clauses, "ip_address IN (" . (join ', ', map {'?'} @{$args{ip_address}}) . ")";
				push @where_values, @{$args{ip_address}};
			}
		} else {
			push @where_clauses, "ip_address = ?";
			push @where_values, $args{ip_address};
		}
	}
	if (defined($args{test_area})) {
		push @where_clauses, "test_area = ?";
		push @where_values, $args{test_area};
	}

	my $table = $self->progress_table_for_command_id($command_id);
	my $sql;
	if (defined($table)) {
		if ($table eq "host_progress") {
			if (@where_clauses) {
				$sql = "DELETE FROM host_progress WHERE host_progress.id IN (SELECT host_progress.id FROM host_progress JOIN hosts ON host_progress.host_id = hosts.id WHERE command_id = ? AND " . (join " AND ", @where_clauses) . ")";
			} else {
				$sql = "DELETE FROM host_progress WHERE host_progress.id IN (SELECT host_progress.id FROM host_progress JOIN hosts ON host_progress.host_id = hosts.id WHERE command_id = ?)";
			}
		} elsif ($table eq "port_progress") {
			if (@where_clauses) {
				$sql = "DELETE FROM port_progress WHERE port_progress.id IN (SELECT port_progress.id FROM port_progress JOIN ports ON port_progress.port_id = ports.id JOIN hosts ON hosts.id = ports.host_id WHERE command_id = ? AND " . (join " AND ", @where_clauses) . ")";
			} else {
				$sql = "DELETE FROM port_progress WHERE port_progress.id IN (SELECT port_progress.id FROM port_progress JOIN ports ON port_progress.port_id = ports.id JOIN hosts ON hosts.id = ports.host_id WHERE command_id = ?)";
			}
		}
	} else {
		return undef;
	}

	my $sth = $self->get_dbh->prepare($sql);
	$sth->execute($command_id, @where_values);
}

sub progress_table_for_command_id {
	my $self = shift;
	my $command_id = shift;
	my $sth1 = $self->get_dbh->prepare("SELECT 1 FROM host_progress WHERE command_id = ?");
	$sth1->execute($command_id);
	my ($result) = $sth1->fetchrow_array;
	return "host_progress" if defined($result);

	my $sth2 = $self->get_dbh->prepare("SELECT 1 FROM port_progress WHERE command_id = ?");
	$sth2->execute($command_id);
	($result) = $sth2->fetchrow_array;
	return "port_progress" if defined($result);

	return undef;
}

sub get_credential_id {
	my $self = shift;
	my %args = @_;
	print "get_credential_id passed:\n" if $global_debug;
	print Dumper \%args if $global_debug;
	my @where_clauses;
	my @where_values;

	if (defined($args{group_name})) {
		$args{group} = 1;
		$args{username} = $args{group_name};
	}

	if (defined($args{gid})) {
		$args{group} = 1;
		$args{uid} = $args{gid};
	}

	foreach my $field (qw(host_id port_id domain username password password_hash password_hash_type_id credential_type_id uid group)) {
		if (exists($args{$field})) {
			if (defined($args{$field})) {
				push @where_clauses, "\"$field\" = ?";
				push @where_values, $args{$field};
			} else {
				push @where_clauses, "$field IS NULL";
			}
		}	
	}

	my $where_clause;
	if (@where_clauses) {
		$where_clause = "WHERE " . join(" AND ", @where_clauses);
	} else {
		$where_clause = "";
	}
	my $sql = "SELECT id FROM credentials $where_clause";
	print "get_credential_id: SQL: $sql\n" if $global_debug;
	my $sth = $self->get_dbh->prepare($sql);

	$sth->execute(@where_values);
	my ($id) =  $sth->fetchrow_array();
	return $id;
}

sub get_groups {
	my $self = shift;
	my %args = @_;
	print "get_group_members passed:\n" if $global_debug;
	print Dumper \%args if $global_debug;
	my @where_clauses;
	my @where_values;

	foreach my $field (qw(group_ip group_name member_domain member_ip member_name)) {
		if (exists($args{$field})) {
			if (defined($args{$field})) {
				push @where_clauses, "\"$field\" = ?";
				push @where_values, $args{$field};
			}
		}	
	}

	my $where_clause;
	if (@where_clauses) {
		$where_clause = "WHERE " . join(" AND ", @where_clauses);
	} else {
		$where_clause = "";
	}
	my $sql = "SELECT group_ip, group_name, member_domain, member_ip, member_name FROM view_groups $where_clause ORDER BY group_ip, group_name, member_domain, member_ip, member_name";
	print "get_group_members: SQL: $sql\n" if $global_debug;
	my $sth = $self->get_dbh->prepare($sql);

	$sth->execute(@where_values);
	my ($aref) = $sth->fetchall_arrayref;
	return $aref;
}

# if the same password hash is found on multiple boxes and we've
# already cracked one, then fill in the password field for the other boxes.
sub _update_known_passwords {
	my $self = shift;
	my $sth = $self->get_dbh->prepare("
		UPDATE credentials 
		SET password = (
			SELECT c3.password 
			FROM credentials AS c3 
			WHERE c3.password_hash = credentials.password_hash 
			LIMIT 1
		) 
		WHERE credentials.id IN (
			SELECT c2.id FROM credentials AS c1 
			JOIN credentials AS c2 
				ON c1.credential_type_id = c2.credential_type_id AND 
				   c1.password_hash = c2.password_hash 
			WHERE c1.password IS NOT NULL AND c2.password IS NULL
		)
	");
	$sth->execute();
	$self->commit;
}

sub get_credentials {
	my $self = shift;
	my %args = @_;
	print "get_credentials passed:\n" if $global_debug;
	print Dumper \%args if $global_debug;
	my @where_clauses;
	my @where_values;

	# default to current test area
	if (defined($args{test_area_name})) {
		if ($args{test_area_name} eq "all") {
			$args{test_area_name} = undef;
		}
	} else {
		$args{test_area_name} = $global_test_area;
	}

	foreach my $field (qw(host_id port_id password_hash_type_id credential_type_id uid test_area_name credential_type_name ip_address port transport_protocol_name domain username uid password password_hash password_hash_type_name)) {
		if (exists($args{$field})) {
			if (defined($args{$field})) {
				if ($args{$field} eq "NOTNULL") {
					push @where_clauses, "$field IS NOT NULL";
				} elsif ($args{$field} eq "NOTEMPTY") {
					push @where_clauses, "$field != ''";
				} elsif ($args{$field} eq "NULL") {
					push @where_clauses, "$field IS NULL";
				} else {
					push @where_clauses, "$field = ?";
					push @where_values, $args{$field};
				}
			}
		}	
	}

	my $where_clause;
	if (@where_clauses) {
		$where_clause = "WHERE " . join(" AND ", @where_clauses);
	} else {
		$where_clause = "";
	}
	my $sql = "
		SELECT test_area_name, credential_type_name, ip_address, port, transport_protocol_name, domain, uid, username, password, password_hash, password_hash_type_name
		FROM view_credentials
		$where_clause
	";
	print "SQL: $sql\n" if $global_debug;
	my $sth = $self->get_dbh->prepare($sql);

	$sth->execute(@where_values);
	
	my $aref = [];
	while (my $href = $sth->fetchrow_hashref) {
		push @$aref, $href;
	}
	return $aref;
}

sub get_ports_by_credential_type {
	my $self = shift;
	my $type = shift;
	print "get_ports_by_credential_type called with type $type\n" if $global_debug;

	my $sth = $self->get_dbh->prepare("SELECT ip_address, port, transport_protocol, password FROM view_credentials WHERE credential_type_id = ? AND test_area = ?");
	$sth->execute($type, $global_test_area);
	my $aref = $sth->fetchall_arrayref;

	return $aref;
}
 
sub get_id_of_os_username {
	my $self = shift;
	my $username = shift;
	my $host = shift;
	print "get_id_of_os_username called with username $username and host $host\n" if $global_debug;

	my $host_id = $self->insert_ip($host);

	my $sth = $self->get_dbh->prepare("SELECT id FROM credentials WHERE port_id IS NULL AND username = ? AND host_id = ?");
	$sth->execute($username, $host_id);
	my ($id) = $sth->fetchrow_array;

	return $id;
}

sub get_id_of_test_area {
	my $self = shift;
	my $test_area = shift;
	print "get_id_of_test_area called with test_area $test_area\n" if $global_debug;

	my $sth = $self->get_dbh->prepare("SELECT id from test_areas WHERE name = ?");
	$sth->execute($test_area);
	my ($id) = $sth->fetchrow_array;

	return $id;
}

sub get_hostname {
	my $self = shift;
	my $ip = shift;
	my $name_type = shift;

	my $aref = $self->get_hosts(ip_address => $ip, name_type => $name_type);
	if (@$aref) {
		return $aref->[0]->{hostname};
	}

	return undef;
}

sub get_hostnames {
	my $self = shift;
	my $test_area = shift;
	my $ip = shift;

	my $aref = $self->get_hosts(test_area_name => $test_area, ip_address => $ip);
	my %hostnames;
	foreach my $href (@$aref) {
		$hostnames{lc $aref->[0]->{hostname}} = 1;
	}

	return join(",", keys %hostnames);
}

# $self->get_hosts(test_area => $t, ip_address => $i);
sub get_hosts {
	my $self = shift;
	my %args = @_;
	
	my @where_clauses;
	my @supplied_fields;
	if (defined($args{hostname})) {
		push @where_clauses, "hostname = ?";
		push @supplied_fields, "hostname";
	}
	if (defined($args{name_type})) {
		push @where_clauses, "name_type = ?";
		push @supplied_fields, "name_type";
	}
	if (defined($args{ip_address})) {
		push @where_clauses, "ip_address = ?";
		push @supplied_fields, "ip_address";
	}
	if (defined($args{test_area})) {
		push @where_clauses, "test_area_name = ?";
		push @supplied_fields, "test_area";
	}
	my $where_clause;
	if (@supplied_fields) {
		$where_clause = "WHERE " . join(" AND ", @where_clauses);
	} else {
		$where_clause = "";
	}
	my $sth;
	if (defined($args{sqash_names}) and $args{sqash_names}) {
		$sth = $self->get_dbh->prepare("SELECT test_area_name, ip_address, trim(concat(DISTINCT hostname || ', '), ', ') AS hostname FROM view_hosts $where_clause GROUP BY test_area_name, ip_address ORDER BY test_area_name, ip_address");
	} else {
		$sth = $self->get_dbh->prepare("SELECT test_area_name, ip_address, hostname, name_type FROM view_hosts $where_clause ORDER BY test_area_name, ip_address");
	}
	$sth->execute(map { $args{$_} } @supplied_fields);

	my $aref = [];
	while (my $href = $sth->fetchrow_hashref) {
		push @$aref, $href;
	}
	return $aref;
}

# $self->get_host_id(test_area => $t, ip_address => $i);
sub get_host_id {
	my $self = shift;
	my %args = @_;
	
	my @where_clauses;
	my @supplied_fields;
	if (defined($args{ip_address})) {
		push @where_clauses, "ip_address = ?";
		push @supplied_fields, "ip_address";
	}
	if (defined($args{test_area})) {
		push @where_clauses, "test_area_name = ?";
		push @supplied_fields, "test_area";
	}
	my $where_clause;
	if (@supplied_fields) {
		$where_clause = "WHERE " . join(" AND ", @where_clauses);
	} else {
		$where_clause = "";
	}
	my $sth = $self->get_dbh->prepare("SELECT host_id FROM view_hosts $where_clause ORDER BY test_area_name, ip_address");
	$sth->execute(map { $args{$_} } @supplied_fields);

	my ($id) = $sth->fetchrow_array;
	return $id;
}

# $self->get_os_usernames(ip_address => $i, username => $u);
sub get_os_usernames {
	my $self = shift;
	my %args = @_;
	
	my $sth;
	if (defined($args{username}) and !defined($args{ip_address})) {
		$sth = $self->get_dbh->prepare('SELECT test_area, username, ip_address, hostname, name_type FROM view_os_usernames WHERE username = ?');
		$sth->execute($args{username});
	} elsif (!defined($args{username}) and defined($args{ip_address})) {
		$sth = $self->get_dbh->prepare('SELECT test_area, username, ip_address, hostname, name_type FROM view_os_usernames WHERE ip_address = ?');
		$sth->execute($args{ip_address});
	} elsif (defined($args{username}) and defined($args{ip_address})) {
		$sth = $self->get_dbh->prepare('SELECT test_area, username, ip_address, hostname, name_type FROM view_os_usernames WHERE username = ? AND ip_address = ?');
		$sth->execute($args{username}, $args{ip_address});
	} elsif (!defined($args{username}) and !defined($args{ip_address})) {
		$sth = $self->get_dbh->prepare('SELECT test_area, username, ip_address, hostname, name_type FROM view_os_usernames');
		$sth->execute();
	} else {
		croak "This shouldn't happen!\n";
	}

	return $sth->fetchall_arrayref;
}

# $self->get_ports(ip_address => $i, port => $p, test_area => $t);
sub get_ports {
	my $self = shift;
	my %args = @_;
	
	my @where_clauses;
	my @supplied_fields;
	my @select_fields = qw(test_area_name ip_address port transport_protocol);
	my $table = "view_ports";

	if (defined($args{port})) {
		push @where_clauses, "port = ?";
		push @supplied_fields, "port";
	}
	if (defined($args{ip_address})) {
		push @where_clauses, "ip_address = ?";
		push @supplied_fields, "ip_address";
	}
	if (defined($args{transport_protocol})) {
		push @where_clauses, "transport_protocol = ?";
		push @supplied_fields, "transport_protocol";
	}
	if (defined($args{test_area})) {
		push @where_clauses, "test_area_name = ?";
		push @supplied_fields, "test_area";
	}
	if (defined($args{rpc_string})) {
		push @where_clauses, "port_info_key = 'rpcinfo_tcp' AND VALUE ILIKE " . $self->get_dbh->quote("%" . $args{rpc_string} . "%");
		$table = "view_port_info";
	}
	if (defined($args{service_string})) {
		push @where_clauses, "port_info_key = 'nmap_service_name' AND VALUE ILIKE " . $self->get_dbh->quote("%" . $args{service_string} . "%");
		$table = "view_port_info";
		push @select_fields, "value";
	}
	if (defined($args{version_string})) {
		push @where_clauses, "port_info_key = 'nmap_service_version' AND VALUE ILIKE " . $self->get_dbh->quote("%" . $args{version_string} . "%");
		$table = "view_port_info";
		push @select_fields, "value";
	}
	my $where_clause;
	if (@where_clauses) {
		$where_clause = "WHERE " . join(" AND ", @where_clauses);
	} else {
		$where_clause = "";
	}
	my $sql = "SELECT " . join(", ", @select_fields) . " FROM $table $where_clause ORDER BY test_area_name, ip_address, port, transport_protocol";
	print "SQL: $sql\n" if $global_debug;
	my $sth = $self->get_dbh->prepare($sql);
	$sth->execute(map { $args{$_} } @supplied_fields);
	
	# my ($id) = $sth->fetchrow_array;
	# return $id;
	my $aref = [];
	while (my $href = $sth->fetchrow_hashref) {
		push @$aref, $href;
	}
	return $aref;
}

# $self->get_port_id(ip_address => $i, port => $p, test_area => $t);
sub get_port_id {
	my $self = shift;
	my %args = @_;
	
	my @where_clauses;
	my @supplied_fields;
	my @select_fields = qw(port_id);
	my $table = "view_ports";

	if (defined($args{port})) {
		push @where_clauses, "port = ?";
		push @supplied_fields, "port";
	}
	if (defined($args{ip_address})) {
		push @where_clauses, "ip_address = ?";
		push @supplied_fields, "ip_address";
	}
	if (defined($args{transport_protocol})) {
		push @where_clauses, "transport_protocol = ?";
		push @supplied_fields, "transport_protocol";
	}
	if (defined($args{test_area})) {
		push @where_clauses, "test_area_name = ?";
		push @supplied_fields, "test_area";
	}
	if (defined($args{rpc_string})) {
		push @where_clauses, "port_info_key = 'rpcinfo_tcp' AND VALUE ILIKE " . $self->get_dbh->quote("%" . $args{rpc_string} . "%");
		$table = "view_port_info";
	}
	if (defined($args{service_string})) {
		push @where_clauses, "port_info_key = 'nmap_service_name' AND VALUE ILIKE " . $self->get_dbh->quote("%" . $args{service_string} . "%");
		$table = "view_port_info";
		push @select_fields, "value";
	}
	if (defined($args{version_string})) {
		push @where_clauses, "port_info_key = 'nmap_service_version' AND VALUE ILIKE " . $self->get_dbh->quote("%" . $args{version_string} . "%");
		$table = "view_port_info";
		push @select_fields, "value";
	}
	my $where_clause;
	if (@where_clauses) {
		$where_clause = "WHERE " . join(" AND ", @where_clauses);
	} else {
		$where_clause = "";
	}
	my $sql = "SELECT " . join(", ", @select_fields) . " FROM $table $where_clause ORDER BY test_area_name, ip_address, port, transport_protocol";
	print "SQL: $sql\n" if $global_debug;
	my $sth = $self->get_dbh->prepare($sql);
	$sth->execute(map { $args{$_} } @supplied_fields);
	
	my ($id) = $sth->fetchrow_array;
	return $id;
}

# $self->get_port_info_id(ip_address => $i, port => $p, test_area => $t, key => $k, value => $v);
sub get_port_info_id {
	my $self = shift;
	my %args = @_;
	
	my @where_clauses;
	my @supplied_fields;
	my @select_fields = qw(port_info_id);

	if (defined($args{port})) {
		push @where_clauses, "port = ?";
		push @supplied_fields, "port";
	}
	if (defined($args{ip_address})) {
		push @where_clauses, "ip_address = ?";
		push @supplied_fields, "ip_address";
	}
	if (defined($args{transport_protocol})) {
		push @where_clauses, "transport_protocol = ?";
		push @supplied_fields, "transport_protocol";
	}
	if (defined($args{test_area})) {
		push @where_clauses, "test_area_name = ?";
		push @supplied_fields, "test_area";
	}
	if (defined($args{key})) {
		push @where_clauses, "port_info_key = ?";
		push @supplied_fields, "key";
	}
	if (defined($args{value})) {
		push @where_clauses, "value = ?";
		push @supplied_fields, "value";
	}
	my $where_clause;
	if (@where_clauses) {
		$where_clause = "WHERE " . join(" AND ", @where_clauses);
	} else {
		$where_clause = "";
	}
	my $sql = "SELECT port_info_id FROM view_port_info $where_clause";
	print "SQL: $sql\n" if $global_debug;
	my $sth = $self->get_dbh->prepare($sql);
	$sth->execute(map { $args{$_} } @supplied_fields);
	
	my ($id) = $sth->fetchrow_array;
	return $id;
}

# $self->get_host_info_id2(ip_address => $i, test_area => $t, key => $k, value => $v);
sub get_host_info_id2 {
	my $self = shift;
	my %args = @_;
	
	my @where_clauses;
	my @supplied_fields;
	my @select_fields = qw(host_info_id);

	if (defined($args{ip_address})) {
		push @where_clauses, "ip_address = ?";
		push @supplied_fields, "ip_address";
	}
	if (defined($args{test_area})) {
		push @where_clauses, "test_area_name = ?";
		push @supplied_fields, "test_area";
	}
	if (defined($args{key})) {
		push @where_clauses, "host_info_key = ?";
		push @supplied_fields, "key";
	}
	if (defined($args{value})) {
		push @where_clauses, "value = ?";
		push @supplied_fields, "value";
	}
	my $where_clause;
	if (@where_clauses) {
		$where_clause = "WHERE " . join(" AND ", @where_clauses);
	} else {
		$where_clause = "";
	}
	my $sql = "SELECT id FROM view_host_info $where_clause";
	print "SQL: $sql\n" if $global_debug;
	my $sth = $self->get_dbh->prepare($sql);
	$sth->execute(map { $args{$_} } @supplied_fields);
	
	my ($id) = $sth->fetchrow_array;
	return $id;
}

# $self->get_port_info(ip_address => $i, port => $p, test_area => $t);
sub get_port_info {
	my $self = shift;
	my %args = @_;
	my @where_clauses;
	my @supplied_fields;

	if (defined($args{port})) {
		push @where_clauses, "port = ?";
		push @supplied_fields, "port";
	}
	if (defined($args{ip_address})) {
		push @where_clauses, "ip_address = ?";
		push @supplied_fields, "ip_address";
	}
	if (defined($args{value})) {
		push @where_clauses, "value = ?";
		push @supplied_fields, "value";
	}
	if (defined($args{test_area})) {
		push @where_clauses, "test_area_name = ?";
		push @supplied_fields, "test_area";
	}
	if (defined($args{tranport_protocol})) {
		push @where_clauses, "transport_protocol = ?";
		push @supplied_fields, "transport_protocol";
	}
	if (defined($args{port_info_key})) {
		push @where_clauses, "port_info_key = ?";
		push @supplied_fields, "port_info_key";
	}
	my $where_clause = "";
	if (@where_clauses) {
		$where_clause = "WHERE " . join(" AND ", @where_clauses);
	}
	my $sql = "SELECT test_area_name, ip_address, port, transport_protocol, port_info_key, value FROM view_port_info $where_clause ORDER BY test_area_name, ip_address, port, transport_protocol, port_info_key, value";
	print "SQL: $sql\n" if $global_debug;
	my $sth = $self->get_dbh->prepare($sql);
	$sth->execute(map { $args{$_} } @supplied_fields);
	
	my $aref = [];
	while (my $href = $sth->fetchrow_hashref) {
		push @$aref, $href;
	}
	return $aref;
}

sub update_nt_from_lm {
	my $self = shift;
	my $sth = $self->get_dbh->prepare("
		SELECT DISTINCT c1.password AS lmpasword, c2.password_hash AS nthash 
		FROM view_credentials c1 
		JOIN view_credentials c2 ON 
			c1.host_id = c2.host_id AND 
			c1.username = c2.username AND 
			c1.password_hash_type_name = 'lanman' AND
			c2.password_hash_type_name = 'nt'
		WHERE c1.password IS NOT NULL AND c2.password IS NULL
	");
	$sth->execute();
	while (my ($lmpassword, $nthash) = $sth->fetchrow_array()) {
		my $nt_password = $self->_crack_nt_password_from_lm_password($lmpassword, $nthash);
		if (defined($nt_password)) {
			print "Updating database with NT('$nt_password') = $nthash\n";
			$self->update_nt_passwords($nt_password, $nthash);
		}
	}
	$self->commit;
}

sub update_nt_passwords {
	my $self = shift;
	my ($nt_password, $nthash) = @_;

	my $sth = $self->get_dbh->prepare("UPDATE credentials SET password = ? WHERE password_hash = ?");
	$sth->execute($nt_password, $nthash);
}

# Cracking passwords in PERL is not big or clever.  However
# JTR doesn't seem to take a command line option to read its
# rules from a different file.  If it did, we could tell it 
# permute case on all LANMAN passwords to recover the NT
# pasword.
# Computation is limited to 2 ^ length(password), so won't
# take more than 1 second per password, though.
sub _crack_nt_password_from_lm_password {
	my $self = shift;
	my ($lmpassword, $nthash) = @_;

	$lmpassword = uc($lmpassword);
	$nthash = lc($nthash);
	
	foreach my $n (0..2**length($lmpassword)-1) {
	        my $password_perm = _case_permute($lmpassword, $n);
	        my $nthash_perm = md4_hex(_unicode($password_perm));
	
	        if ($nthash eq $nthash_perm) {
	                return $password_perm
	        }
	}

	return undef;
	
}

sub _case_permute {
        my $lmpassword = shift;
        my $n = shift;

        my @chars = split(//, $lmpassword);

        my $password_perm = "";
        foreach my $char (@chars) {
                my $remainder = $n % 2;
                if ($remainder) {
                        $password_perm .= uc($char);
                } else {
                        $password_perm .= lc($char);
                }

                $n = int($n / 2);
        }

        return $password_perm;
}

# Convert string to unicode
sub _unicode {
        my $password = shift;
        my $password_new = "";
        my @chars = split(//, $password);

        foreach my $char (@chars) {
                $password_new .= "$char\x00";
        }

        return $password_new;
}

sub get_password_hash_file {
	my $self = shift;
	my %opts = @_;
	my $count = 0;
	my ($fh, $filename);
	my $hash_type = $opts{password_hash_type_name};

	# First update db to fill in any password where we already
	# cracked the hash
	#$self->_update_known_passwords();

	if ($hash_type eq 'lanman') {
		# select all the hashes we haven't cracked
		my $sth = $self->get_dbh->prepare("
			SELECT c1.username, c1.uid, c1.password_hash AS lmhash, c2.password_hash AS nthash 
			FROM view_credentials c1 
			JOIN view_credentials c2 ON 
				c1.host_id = c2.host_id AND 
				c1.username = c2.username AND 
				c1.password_hash_type_name = 'lanman' AND
				c2.password_hash_type_name = 'nt'
			WHERE c1.password IS NULL
		");
		$sth->execute();
		($fh, $filename) = tempfile("passwd-$hash_type-XXXXX");
		while (my ($username, $uid, $lmhash, $nthash) = $sth->fetchrow_array()) {
			$count++;
			foreach my $field ($username, $uid, $lmhash, $nthash) {
				print $fh (defined($field) ? $field : "") . ":";
			}
			print $fh ":::\n";
		}
	} elsif ($hash_type eq 'nt') {
		# select all the hashes we haven't cracked
		my $sth = $self->get_dbh->prepare("
			SELECT username, uid, password_hash, password_hash
			FROM view_credentials
			WHERE password IS NULL AND
			      password_hash_type_name = 'nt'
		");
		$sth->execute();
		($fh, $filename) = tempfile("passwd-$hash_type-XXXXX");
		while (my ($username, $uid, $lmhash, $nthash) = $sth->fetchrow_array()) {
			$count++;
			foreach my $field ($username, $uid, $lmhash, $nthash) {
				print $fh (defined($field) ? $field : "") . ":";
			}
			print $fh ":::\n";
		}
	} elsif ($hash_type eq 'oracle') {
		# select all the hashes we haven't cracked
		my $sth = $self->get_dbh->prepare("
			SELECT username, password_hash
			FROM view_credentials
			WHERE password IS NULL AND
			      password_hash_type_name = 'oracle'
		");
		$sth->execute();
		($fh, $filename) = tempfile("passwd-$hash_type-XXXXX");
		while (my ($username, $hash) = $sth->fetchrow_array()) {
			$count++;
			$username = "" unless defined($username);
			$hash = "" unless defined($hash);
			print $fh "$username:$hash\n";
		}
	} elsif ($hash_type eq 'mssql') {
		# select all the hashes we haven't cracked
		my $sth = $self->get_dbh->prepare("
			SELECT password_hash
			FROM view_credentials
			WHERE password IS NULL AND
			      credential_type_name = 'mssql'
		");
		$sth->execute();
		($fh, $filename) = tempfile("passwd-$hash_type-XXXXX");
		while (my ($hash) = $sth->fetchrow_array()) {
			$count++;
			$hash = "" unless defined($hash);
			print $fh "$hash\n";
		}
	} else {
		my $sth = $self->get_dbh->prepare("
			SELECT username, password_hash
			FROM view_credentials
			WHERE password IS NULL AND password_hash_type_name = ?
		");
		$sth->execute($hash_type);
		($fh, $filename) = tempfile("passwd-$hash_type-XXXXX");
		while (my ($username, $hash) = $sth->fetchrow_array()) {
			$count++;
			foreach my $field ($username, $hash) {
				print $fh (defined($field) ? $field : "") . ":";
			}
			print $fh "::::::\n";
		}
	}

	close $fh;
	if ($count) {
		return $filename;
	} else {
		return undef;
	}
}

sub get_os_info {
	my $self = shift;
	
	my $sth = $self->get_dbh->prepare("SELECT * FROM view_os");
	$sth->execute;
	my $aref = [];
	while (my $href = $sth->fetchrow_hashref) {
		push @$aref, $href;
	}
	return $aref;
}

sub get_host_info {
	my $self = shift;
	my %args = @_;
	
	my @where_clauses;
	my @supplied_fields;

	if (defined($args{host_id})) {
		push @where_clauses, "host_id = ?";
		push @supplied_fields, "host_id";
	}

	if (defined($args{ip_address})) {
		push @where_clauses, "ip_address = ?";
		push @supplied_fields, "ip_address";
	}

	if (defined($args{key})) {
		push @where_clauses, "key = ?";
		push @supplied_fields, "key";
	}

	if (defined($args{value})) {
		push @where_clauses, "value = ?";
		push @supplied_fields, "value";
	}

	if (defined($args{test_area})) {
		push @where_clauses, "test_area_name = ?";
		push @supplied_fields, "test_area";
	}

	my $where_clause = "";
	if (@where_clauses) {
		$where_clause = "WHERE " . join(" AND ", @where_clauses);
	}

	my $sth = $self->get_dbh->prepare("SELECT test_area_name, ip_address, key, value FROM view_host_info $where_clause");
	$sth->execute(map { $args{$_} } @supplied_fields);
	my $aref = [];
	while (my $href = $sth->fetchrow_hashref) {
		push @$aref, $href;
	}
	return $aref;
}

sub get_issues {
	my $self = shift;
	my %args = @_;
	
	my @where_clauses;
	my @supplied_fields;

	if (defined($args{ip_address})) {
		push @where_clauses, "ip_address = ?";
		push @supplied_fields, "ip_address";
	}

	if (defined($args{port})) {
		push @where_clauses, "port = ?";
		push @supplied_fields, "port";
	}

	if (defined($args{transport_protocol})) {
		push @where_clauses, "transport_protocol_name = ?";
		push @supplied_fields, "transport_protocol_name";
	}

	if (defined($args{test_area_name})) {
		push @where_clauses, "test_area_name = ?";
		push @supplied_fields, "test_area_name";
	}

	if (defined($args{issue})) {
		push @where_clauses, "issue_shortname = ?";
		push @supplied_fields, "issue";
	}

	my $where_clause = "";
	if (@where_clauses) {
		$where_clause = "WHERE " . join(" AND ", @where_clauses);
	}

	my $sth;
	my $aref = [];

	$sth = $self->get_dbh->prepare("SELECT test_area_name, ip_address, port, transport_protocol_name, issue_shortname FROM view_issues $where_clause");
	$sth->execute(map { $args{$_} } @supplied_fields);
	while (my $href = $sth->fetchrow_hashref) {
		push @$aref, $href;
	}
	
	return $aref;
}

sub export_to_xml {
	my $self = shift;
	my $rows_aref = shift;
	my $type = shift;
	my $filename = shift;
	my %export_hash = ();
	my $id = 1;
	$export_hash{yaptest_export}{type} = $type;

	foreach my $row_href (@$rows_aref) {
		my $id_string = "ID" . $id++;
		$export_hash{yaptest_export}{$id_string} = $row_href;
	}

	my $xml = XML::Simple->new->XMLout(\%export_hash, KeepRoot => 1);
	open FILE, ">$filename" or croak "ERROR: Can't open $filename for writing: $!\n";
	print FILE $xml;
	close FILE;
}

sub delete_issues {
	my $self = shift;
	my %args = @_;
	
	my @where_clauses;
	my @supplied_fields;

	if (defined($args{ip_address})) {
		push @where_clauses, "ip_address = ?";
		push @supplied_fields, "ip_address";
	}

	if (defined($args{port})) {
		push @where_clauses, "port = ?";
		push @supplied_fields, "port";
	}

	if (defined($args{transport_protocol})) {
		push @where_clauses, "transport_protocol_name = ?";
		push @supplied_fields, "transport_protocol_name";
	}

	if (defined($args{test_area_name})) {
		push @where_clauses, "test_area_name = ?";
		push @supplied_fields, "test_area_name";
	}

	if (defined($args{issue})) {
		push @where_clauses, "issue = ?";
		push @supplied_fields, "issue";
	}

	my $where_clause = "";
	if (@where_clauses) {
		$where_clause = "WHERE " . join(" AND ", @where_clauses);
	}

	my $sth;

	# if a port was supplied, return only port issues
	if (defined($args{port}) or defined($args{transport_protocol})) {
		$sth = $self->get_dbh->prepare("DELETE FROM issues_to_ports WHERE id IN (SELECT id view_port_issues $where_clause)");
		$sth->execute(map { $args{$_} } @supplied_fields);
	
	# if no port was supplied, return port + host issues
	} else {
		$sth = $self->get_dbh->prepare("DELETE FROM issues_to_ports WHERE id IN (SELECT id FROM view_port_issues $where_clause)");
		$sth->execute(map { $args{$_} } @supplied_fields);

		$sth = $self->get_dbh->prepare("DELETE FROM issues_to_hosts WHERE id IN (SELECT id FROM view_host_issues $where_clause)");
		$sth->execute(map { $args{$_} } @supplied_fields);
	}
}

sub get_hash_file {
	my $self = shift;
	my $count = 0;
	my ($fh, $filename);
	my %args = @_;
	my $hash_type = $args{'password_hash_type_name'};

	# First update db to fill in any password where we already
	# cracked the hash
	$self->_update_known_passwords();

	if ($hash_type eq 'lanman') {
		# select all the hashes we haven't cracked
		my $sth = $self->get_dbh->prepare("
			SELECT DISTINCT hash FROM (
			SELECT hash_half1 AS hash 
			FROM credentials 
			WHERE password_half1 IS NULL AND 
			      password_hash_type_id = (SELECT id FROM password_hash_types WHERE name = 'lanman') 
			
			UNION 
			
			SELECT hash_half2 AS hash
			FROM credentials 
			WHERE password_half2 IS NULL AND 
			      password_hash_type_id = (SELECT id FROM password_hash_types WHERE name = 'lanman')
			)a
		");
		$sth->execute();
		($fh, $filename) = tempfile("passwd-$hash_type-XXXXX");
		while (my ($lmhash) = $sth->fetchrow_array()) {
			$count++;
			print $fh "$lmhash\n";
		}
	}

	if ($hash_type eq 'nt') {
		# select all the hashes we haven't cracked
		my $sth = $self->get_dbh->prepare("
			SELECT DISTINCT password_hash
                        FROM view_credentials
			WHERE password IS NULL AND
	                      password_hash_type_name = 'nt'
		");
		$sth->execute();
		($fh, $filename) = tempfile("passwd-$hash_type-XXXXX");
		while (my ($lmhash) = $sth->fetchrow_array()) {
			$count++;
			print $fh "$lmhash\n";
		}
	}
	close $fh;
	if ($count) {
		return $filename;
	} else {
		return undef;
	}
}

sub parse_john_pot {
	my $self = shift;
	my $filename = shift;
	my $type = shift; # optional
	unless (defined($filename) and open FILE, "<$filename") {
		warn ": Can't read password hashes from $filename: $!\n";
		return;
	}

	my $lookforlanman = 0;
	my $lookfordes = 0;
	my $lookfornt = 0;
	my $lookforbsdmd5 = 0;

	if (defined($type)) {
		$lookforlanman = 1 if ($type eq "lanman");
		$lookfordes = 1 if ($type eq "des");
		$lookfornt = 1 if ($type eq "nt");
		$lookforbsdmd5 = 1 if ($type eq "bsd_md5");
	} else {
		$lookforlanman = 1;
		$lookfordes = 1;
		$lookfornt = 1;
		$lookforbsdmd5 = 1;
	}

	while (<FILE>) {
		chomp;
		my $line = $_;
		if ($lookforlanman and $line =~ /^\$LM\$([a-z0-9A-Z]{16}):(.*)/) {
			my $hash = $1;
			my $password = $2;
			$self->insert_cracked_hash('lanman', $hash, $password);
		}
		if ($lookfordes and $line =~ /^([a-zA-Z0-9\.\/]{13}):(.*)$/) {
			my $hash = $1;
			my $password = $2;
			$self->insert_cracked_hash('des', $hash, $password);
		}
		if ($lookfornt and $line =~ /^\$NT\$([a-fA-F0-9]{32}):(.*)$/) {
			my $hash = $1;
			my $password = $2;
			$self->insert_cracked_hash('nt', $hash, $password);
		}
		if ($lookforbsdmd5 and $line =~ /^(\$1\$[a-zA-Z0-9.\/\$]+):(.*)$/) {
			my $hash = $1;
			my $password = $2;
			$self->insert_cracked_hash('bsd_md5', $hash, $password);
		}
	}
	close FILE;
}

sub parse_checkpwd {
	my $self = shift;
	my $filename = shift;
	unless (open FILE, "<$filename") {
		warn ": Can't read password hashes from $filename: $!\n";
		return;
	}

	my $hash;
	while (<FILE>) {
		chomp;
		my $line = $_;
		if ($line =~ /^Cracking hash (\S+):([0-9A-F]{16})/) {
			my $username = $1;
			$hash = $2;
			$hash =~ s/\x0d//g;
		}
		if ($line =~ /^(\S+) has weak password (.*)$/) {
			my $username = $1;
			my $password = $2;
			$password =~ s/\x0d//g;
			print "Inserting cracked oracle hash $username, $hash, $password\n";
			$self->insert_cracked_hash('oracle', $hash, $password);
		}
	}
	close FILE;
}

sub parse_sql_crack {
	my $self = shift;
	my $filename = shift;
	unless (open FILE, "<$filename") {
		warn ": Can't read password hashes from $filename: $!\n";
		return;
	}

	my $hash;
	while (<FILE>) {
		chomp;
		my $line = $_;
		if ($line =~ /^Cracking hash (\S+)/) {
			$hash = $1;
			$hash =~ s/\x0d//g;
		}
		if ($line =~ /^Case-sensitive password:\s+"(.*)"\s*$/s) {
			my $password = $1;
			$password =~ s/\x0d//g;
			print "Inserting cracked mssql hash $hash, $password\n";
			$self->insert_cracked_hash('mssql', $hash, $password);
		}
	}
	close FILE;
}

sub parse_rt {
	my $self = shift;
	my $filename = shift;
	unless (open FILE, "<$filename") {
		warn ": Can't read password hashes from $filename: $!\n";
		return;
	}

	while (<FILE>) {
		chomp;
		my $line = $_;
		if ($line =~ /^([0-9a-f]{16})\s+.*\s+hex:([0-9a-f]+)/) {
			my $hash = $1;
			my $password_hex = $2;
			my $password = $password_hex;
			$password =~ s/([0-9a-f]{2})/chr(hex($1))/ge;
			$self->insert_cracked_hash('lanman', $hash, $password);
		}
		if ($line =~ /^([0-9a-f]{32})\s+.*\s+hex:([0-9a-f]+)/) {
			my $hash = $1;
			my $password_hex = $2;
			my $password = $password_hex;
			$password =~ s/([0-9a-f]{2})/chr(hex($1))/ge;
			$self->insert_cracked_hash('nt', $hash, $password);
		}
	}
	close FILE;
}

sub insert_cracked_hash {
	my $self = shift;
	my ($type, $hash, $password) = @_;
	print "insert_cracked_hash: Called with: $type, $hash, $password\n" if $global_debug;

	if ($type eq "lanman") {
		print "Updating database with LANMAN('$password') = $hash\n";
		$hash = uc $hash;
		unless ($hash =~ /^([A-F0-9]{16})$/) {
			croak "ERROR: insert_cracked_hash was passed an invalid $type hash: $hash\n";
		}
		# first check that the hash is in the db somehwere
		my $sth0 = $self->get_dbh->prepare("SELECT id FROM credentials WHERE ((password_half1 IS NULL AND hash_half1 = ?) OR (password_half2 IS NULL AND hash_half2 = ?)) AND password_hash_type_id = (SELECT id FROM password_hash_types WHERE name = 'lanman')");
		$sth0->execute($hash, $hash);
		my ($id) = $sth0->fetchrow_array();

		# only if it's in the db, do all the updates - quite expensive
		if (defined($id)) {
			my $sth1 = $self->get_dbh->prepare("UPDATE credentials SET password_half1 = ? WHERE hash_half1 = ? AND password_hash_type_id = (SELECT id FROM password_hash_types WHERE name = 'lanman')");
			$sth1->execute($password, $hash);
			my $sth2 = $self->get_dbh->prepare("UPDATE credentials SET password_half2 = ? WHERE hash_half2 = ? AND password_hash_type_id = (SELECT id FROM password_hash_types WHERE name = 'lanman')");
			$sth2->execute($password, $hash);
			# my $sth3 = $self->get_dbh->prepare("UPDATE credentials SET password = password_half1 || password_half2 WHERE password IS NULL AND NOT hash_half1 IS NULL AND NOT hash_half2 IS NULL AND password_hash_type_id = (SELECT id FROM password_hash_types WHERE name = 'lanman')");
			my $sth3 = $self->get_dbh->prepare("UPDATE credentials SET password = password_half1 || password_half2 WHERE (hash_half2 = ? OR hash_half1 = ?) AND password IS NULL AND NOT hash_half1 IS NULL AND NOT hash_half2 IS NULL AND password_hash_type_id = (SELECT id FROM password_hash_types WHERE name = 'lanman')");
			$sth3->execute($hash, $hash);
			# $self->_update_nt_from_lm();
		}
	} elsif ($type eq "des") {
		print "Updating database with DES_HASH('$password') = $hash\n";
		unless ($hash =~ /^[a-zA-Z0-9\.\/]{13}$/) {
			croak "ERROR: insert_cracked_hash was passed an invalid $type hash: $hash\n";
		}
		my $sth1 = $self->get_dbh->prepare("UPDATE credentials SET password = ? WHERE password_hash = ? AND password_hash_type_id = (SELECT id FROM password_hash_types WHERE name = 'des')");
		$sth1->execute($password, $hash);
	} elsif ($type eq "bsd_md5") {
		print "Updating database with BSD_MD5_HASH('$password') = $hash\n";
		unless ($hash =~ /^\$1\$[a-zA-Z0-9\.\/\$]+/) {
			croak "ERROR: insert_cracked_hash was passed an invalid $type hash: $hash\n";
		}
		my $sth1 = $self->get_dbh->prepare("UPDATE credentials SET password = ? WHERE password_hash = ? AND password_hash_type_id = (SELECT id FROM password_hash_types WHERE name = 'bsd_md5')");
		$sth1->execute($password, $hash);
	} elsif ($type eq "oracle") {
		print "Updating database with ORACLE_HASH('$password') = $hash\n";
		unless ($hash =~ /^[A-F0-9]{16}$/) {
			croak "ERROR: insert_cracked_hash was passed an invalid $type hash: $hash\n";
		}
		my $sth1 = $self->get_dbh->prepare("UPDATE credentials SET password = ? WHERE password_hash = ? AND password_hash_type_id = (SELECT id FROM password_hash_types WHERE name = 'oracle')");
		$sth1->execute($password, $hash);
	} elsif ($type eq "mssql") {
		print "Updating database with MSSQL_HASH('$password') = $hash\n";
		unless ($hash =~ /^[a-f0-9]{92}$/) {
			croak "ERROR: insert_cracked_hash was passed an invalid $type hash: $hash\n";
		}
		my $sth1 = $self->get_dbh->prepare("UPDATE credentials SET password = ? WHERE password_hash = ? AND credential_type_id = (SELECT id FROM credential_types WHERE name = 'mssql')");
		$sth1->execute($password, $hash);
	} elsif ($type eq "nt") {
		print "Updating database with NT('$password') = $hash\n";
		$hash = uc($hash);
		unless ($hash =~ /^[A-F0-9]{32}$/) {
			croak "ERROR: insert_cracked_hash was passed an invalid $type hash: $hash\n";
		}
		my $sth1 = $self->get_dbh->prepare("UPDATE credentials SET password = ? WHERE password_hash = ? AND password_hash_type_id = (SELECT id FROM password_hash_types WHERE name = 'nt')");
		$sth1->execute($password, $hash);
	} else {
		croak "ERROR: insert_cracked_hash was passed an unknown hash type\n";
	}

	$self->commit;
}

# $self->get_type(ip_address => $i, type => $p, test_area => $t);
sub get_icmp {
	my $self = shift;
	my %args = @_;
	
	my @where_clauses;
	my @supplied_fields;
	my $table = "view_icmp";

	if (defined($args{type})) {
		push @where_clauses, "type_info_key = 'rpcinfo_tcp' AND VALUE ILIKE " . $self->get_dbh->quote("%" . $args{rpc_string} . "%");
	}
	if (defined($args{ip_address})) {
		push @where_clauses, "ip_address = ?";
		push @supplied_fields, "ip_address";
	}
	if (defined($args{test_area})) {
		push @where_clauses, "test_area_name = ?";
		push @supplied_fields, "test_area";
	}
	if (defined($args{icmp_name})) {
		push @where_clauses, "icmp_name = ?";
		push @supplied_fields, "icmp_name";
	}
	my $where_clause;
	if (@where_clauses) {
		$where_clause = "WHERE " . join(" AND ", @where_clauses);
	} else {
		$where_clause = "";
	}
	my $sth;
	if (defined($args{squash_names}) and $args{squash_names}) {
		$sth = $self->get_dbh->prepare("SELECT test_area_name, ip_address, trim(concat(DISTINCT host_name || ', '), ', ') AS hostname, icmp_name FROM $table $where_clause GROUP BY test_area_name, ip_address, icmp_name ORDER BY test_area_name, ip_address, icmp_name");
	} else {
		my $sql = "SELECT test_area_name, ip_address, host_name, icmp_name FROM $table $where_clause";
		print "SQL: $sql\n" if $global_debug;
		$sth = $self->get_dbh->prepare($sql);
	}
	$sth->execute(map { $args{$_} } @supplied_fields);
	
	my $aref = [];
	while (my $href = $sth->fetchrow_hashref) {
		push @$aref, $href;
	}
	return $aref;
}

sub print_table {
	my $self = shift;
	my $aref = shift;
	my $max_lines = shift;
	my $line_count = 0;
	my @rows = @{$aref};
	foreach my $row_aref (@rows) {
		print join("\t", map { defined($_) ? $_ : "null" } @{$row_aref}) . "\n";
		$line_count++;
		if (defined($max_lines) and $line_count > $max_lines) {
			print "... some targets not shown ..\n";
			last;
		}
	}
	warn "Total records: " . scalar(@rows) . "\n\n";
}

sub print_table_hashes {
	my $self = shift;
	my $aref = shift;
	my $max_lines = shift;
	my $line_count = 0;
	my @keys = @_;
	my @rows = @{$aref};
	if (scalar(@rows)) {
		unless (scalar(@keys)) {
			@keys = sort keys %{$rows[0]};
		}
		warn join("\t", @keys) . "\n";
		warn join("\t", map { "-" x length($_)} @keys) . "\n";

		foreach my $row_href (@rows) {
			print join("\t", map { defined($row_href->{$_}) ? $row_href->{$_} : "null" } @keys) . "\n";
			$line_count++;
			if (defined($max_lines) and $line_count > $max_lines) {
				print "... some results not shown ..\n";
				last;
			}
		}
	}
	warn "\nTotal records: " . scalar(@rows) . "\n\n";
}

sub print_table_hashes_html {
	my $self = shift;
	my $aref = shift;
	my $max_lines = shift;
	my $line_count = 0;
	my $links = 1;
	my @keys = @_;
	my @rows = @{$aref};
	if (scalar(@rows)) {
		print "<table border=\"1\">\n";
		unless (scalar(@keys)) {
			@keys = sort keys %{$rows[0]};
		}
		print "<tr>\n";
		print "<td>" . join("</td>\n<td>", @keys) . "</td>\n";
		print "</tr>\n";

		foreach my $row_href (@rows) {
			print "<tr>\n";
			foreach my $key (@keys) {
				print "<td>\n";
				print '<a href="yaptest.pl?ip=' . $row_href->{$key} . '">' if ($links and $key eq "ip_address");
				print defined($row_href->{$key}) ? $row_href->{$key} : "null";
				print "</a>\n" if ($links and $key eq "ip_address");
				print "\n";
				print "</td>\n";
			}
			print "</tr>\n";
			$line_count++;
			if (defined($max_lines) and $line_count > $max_lines) {
				print "... some results not shown ..\n";
				last;
			}
		}
		print "</table>\n";
	}
	print "\nTotal records: " . scalar(@rows) . "\n\n";
}

# $id = $self->get_id_of_mac("11:22:33:44:55:66");
sub get_id_of_mac {
	my $self = shift;
	my $mac = shift;
	print "get_id_of_mac called with mac $mac\n" if $global_debug;

	my $sth = $self->get_dbh->prepare("SELECT id from mac_addresses WHERE mac_address = ?");
	$sth->execute($mac);
	my ($id) = $sth->fetchrow_array;

	return $id;
}

# $self->insert_ip("1.2.3.4");
sub insert_ip {
	my $self = shift;
	my $ip = shift;
	print "insert_ip called with ip $ip\n" if $global_debug;

	# Check if valid IP passed incase we were passed a network (e.g. 10.0.0.0/24)
	# PostgreSQL will allow you to add a network, but we don't want to support that.
	my ($cleanip) = $ip =~ /^\s*(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s*$/;
	unless (defined($ip)) {
		print "WARNING: Invalid IP address ignored: \"$ip\"\n";
		return undef;
	}
	$ip = $cleanip;

	my $id = $self->get_id_of_ip($ip);

	if (defined($id)) {
		return $id;
	} else {
		my $sth = $self->get_dbh->prepare("INSERT INTO hosts (ip_address, test_area_id) VALUES (?, ?)");
		$sth->execute($ip, $global_test_area_id);
	
		return $self->get_id_of_ip($ip);
	}
}

sub delete_host {
	my $self = shift;
	my %args = @_;

	# Default test area is the current one
	unless (defined($args{test_area})) {
		$args{test_area} = $global_test_area;
	}

	# Check an ip was supplied
	unless (defined($args{ip_address})) {
		croak "ERROR: delete_ip was not passed an IP\n";
	}
	
	my $sth = $self->get_dbh->prepare("DELETE FROM hosts WHERE ip_address = ? AND test_area_id = (SELECT id FROM test_areas WHERE name = ?)");
	$sth->execute($args{ip_address}, $args{test_area});
}

# $self->insert_mac("11:22:33:44:55:66");
sub insert_mac {
	my $self = shift;
	my $mac = shift;
	print "insert_mac called with mac $mac\n" if $global_debug;

	my $id = $self->get_id_of_mac($mac);

	if (defined($id)) {
		return $id;
	} else {
		my $sth = $self->get_dbh->prepare("INSERT INTO mac_addresses (mac_address) VALUES (?)");
		$sth->execute($mac);
	
		return $self->get_id_of_mac($mac);
	}
}

# $id = $self->insert_ip("1.2.3.4");
sub get_id_of_ip {
	my $self = shift;
	my $ip = shift;

	my $sth = $self->get_dbh->prepare("SELECT id FROM hosts WHERE ip_address = ? AND test_area_id = ?");
	$sth->execute($ip, $global_test_area_id);
	my ($id) = $sth->fetchrow_array;

	return $id;
}

# my $id = $y->associate_interfaces($ip1, $ip2)
sub associate_interfaces {
	my $self = shift;
	my $ip1 = shift;
	my $ip2 = shift;

	# Populate interface table if necessary
	$self->insert_interface($ip1);
	$self->insert_interface($ip2);

	# Get box_id of ip1
	my $box_id1 = $self->get_box_id($ip1);

	# Get box_id of ip2
	my $box_id2 = $self->get_box_id($ip2);

	# Replace all occurences of box_id(ip1) with box_id(ip2)
	my $sth = $self->get_dbh->prepare("UPDATE interfaces SET box_id = ? WHERE box_id = ?");
	$sth->execute($box_id1, $box_id2);
}

sub get_box_id {
	my $self = shift;
	my $ip = shift;

	my $sth = $self->get_dbh->prepare("SELECT interfaces.box_id FROM interfaces JOIN boxes ON interfaces.box_id = boxes.id WHERE ip_address = ? AND test_area_id = ?");
	$sth->execute($ip, $global_test_area_id);
	my ($id) = $sth->fetchrow_array;

	return $id;
}

# my $id = $y->insert_interface($ip)
sub insert_interface {
	my $self = shift;
	my $ip1 = shift;

	my $interface_id1 = $self->get_interface_id($ip1);

	unless (defined($interface_id1)) {
		my $box_id = $self->insert_box();
		my $sth = $self->get_dbh->prepare("INSERT INTO interfaces (box_id, ip_address) VALUES (?, ?)");
		$sth->execute($box_id, $ip1);
		$interface_id1 = $self->get_interface_id($ip1);
	}

	return $interface_id1;
}

# my $id = $y->insert_box
sub insert_box {
	my $self = shift;
	my $sth = $self->get_dbh->prepare("INSERT INTO boxes (test_area_id) VALUES (?)");
	$sth->execute($global_test_area_id);

	# TODO there must be a better way to get this new id
	my $sth2 = $self->get_dbh->prepare("SELECT max(id) FROM boxes");
	$sth2->execute();
	my ($id) = $sth2->fetchrow_array;

	return $id;
}

sub insert_router_icmp_ttl {
	my $self = shift;
	my $ip = shift;
	my $ttl = shift;

	$self->insert_interface($ip);

	my $interface_id1 = $self->get_interface_id($ip);

	my $sth = $self->get_dbh->prepare("UPDATE interfaces SET icmp_ttl = ? WHERE id = ?");
	$sth->execute($ttl, $interface_id1);
}

sub insert_router_hop {
	my $self = shift;
	my $ip = shift;
	my $hop = shift;

	$self->insert_interface($ip);

	my $interface_id1 = $self->get_interface_id($ip);

	my $sth = $self->get_dbh->prepare("UPDATE interfaces SET hop = ? WHERE id = ?");
	$sth->execute($hop, $interface_id1);
}

sub get_router_icmp_ttl {
	my $self = shift;
	my $ip = shift;
	
	my $sth = $self->get_dbh->prepare("SELECT icmp_ttl FROM interfaces JOIN boxes ON interfaces.box_id = boxes.id WHERE ip_address = ? AND test_area_id = ?");
	$sth->execute($ip, $global_test_area_id);

	my ($id) = $sth->fetchrow_array;

	return $id;
}

sub get_router_hop {
	my $self = shift;
	my $ip = shift;
	
	my $sth = $self->get_dbh->prepare("SELECT hop FROM interfaces JOIN boxes ON interfaces.box_id = boxes.id WHERE ip_address = ? AND test_area_id = ?");
	$sth->execute($ip, $global_test_area_id);

	my ($id) = $sth->fetchrow_array;

	return $id;
}

# my $id = $y->insert_toplogoy($prev_hop_ip, $ip)
sub insert_topology {
	my $self = shift;
	my $ip1 = shift;
	my $ip2 = shift;

	my $id1 = $self->insert_interface($ip1);
	my $id2 = $self->insert_interface($ip2);
	
	my $top_id = $self->get_topology_id($id1, $id2);
	unless (defined($top_id)) {
		my $sth = $self->get_dbh->prepare("INSERT INTO topology (prev_hop_interface_id, interface_id) VALUES (?, ?)");
		$sth->execute($id1, $id2);

		$top_id = $self->get_topology_id($id1, $id2);
	}

	return $top_id;
}

sub insert_netmask {
	my $self = shift;
	my $ip = shift;
	my $netmask = shift;

	my $int_id = $self->insert_interface($ip);
	my $sth = $self->get_dbh->prepare("UPDATE interfaces SET netmask = ? WHERE id = ?");
	$sth->execute($netmask, $int_id);

	return 1;
}

sub get_topology_id {
	my $self = shift;
	my $id1 = shift;
	my $id2 = shift;
	
	my $sth = $self->get_dbh->prepare("SELECT id FROM topology WHERE interface_id = ? AND prev_hop_interface_id = ?");
	$sth->execute($id2, $id1);

	my ($id) = $sth->fetchrow_array;

	return $id;
}

sub get_interface_id {
	my $self = shift;
	my $ip = shift;

	my $sth = $self->get_dbh->prepare("SELECT interfaces.id FROM interfaces JOIN boxes ON interfaces.box_id = boxes.id WHERE ip_address = ? AND test_area_id = ?");
	$sth->execute($ip, $global_test_area_id);
	my ($id) = $sth->fetchrow_array;

	return $id;
}

# $self->insert_ip_and_mac("1.2.3.4", "11:22:33:44:55:66");
sub insert_ip_and_mac {
	my $self = shift;
	my $ip = shift;
	my $mac = shift;
	print "insert_ip_and_mac called with ip $ip and mac $mac\n" if $global_debug;

	my $id = $self->get_id_of_ip_and_mac($ip, $mac);

	if (defined($id)) {
		return $id;
	} else {
		my $host_id = $self->insert_ip($ip);
		my $mac_id = $self->insert_mac($mac);
		my $sth = $self->get_dbh->prepare("INSERT INTO hosts_to_mac_addresses (host_id, mac_address_id) VALUES (?, ?)");
		$sth->execute($host_id, $mac_id);
	
		return $self->get_id_of_ip_and_mac($ip, $mac);
	}
}

sub insert_command {
	my $self = shift;
	my $command = shift;
	print "insert_command called with state $command\n" if $global_debug;

	$self->_semaphore_take("command");
	my $id = $self->get_id_of_command($command);

	if (defined($id)) {
		$self->_semaphore_give("command");
		return $id;
	} else {
		my $sth = $self->get_dbh->prepare("INSERT INTO commands (name) VALUES (?)");
		$sth->execute($command);
	
		$self->_semaphore_give("command");
		return $self->get_id_of_command($command);
	}
}

sub insert_state {
	my $self = shift;
	my $state = shift;
	print "insert_state called with state $state \n" if $global_debug;

	my $id = $self->get_id_of_state($state);

	if (defined($id)) {
		return $id;
	} else {
		my $sth = $self->get_dbh->prepare("INSERT INTO progress_states (name) VALUES (?)");
		$sth->execute($state);
	
		return $self->get_id_of_state($state);
	}
}

sub get_id_of_state {
	my $self = shift;
	my $state = shift;

	my $sth = $self->get_dbh->prepare("SELECT id FROM progress_states WHERE name = ?");
	$sth->execute($state);
	my ($id) = $sth->fetchrow_array;

	return $id;
}

sub get_id_of_command {
	my $self = shift;
	my $command = shift;

	my $sth = $self->get_dbh->prepare("SELECT id FROM commands WHERE name = ?");
	$sth->execute($command);
	my ($id) = $sth->fetchrow_array;

	return $id;
}

# $id = $self->get_id_of_ip_and_mac("1.2.3.4", "11:22:33:44:55:66");
sub get_id_of_ip_and_mac {
	my $self = shift;
	my $ip = shift;
	my $mac = shift;
	print "get_id_of_ip_and_mac called with ip $ip and mac $mac\n" if $global_debug;

	my $host_id = $self->get_id_of_ip($ip);
	my $mac_id = $self->get_id_of_mac($mac);

	return undef unless defined($host_id) and defined($mac_id);

	my $sth = $self->get_dbh->prepare("SELECT id from hosts_to_mac_addresses WHERE host_id = ? and mac_address_id = ?");
	my ($id) = $sth->execute($host_id, $mac_id);

	return $id;
}

# @ips = $self->get_all_unscanned_ips()
sub get_all_unscanned_ips {
	my $self = shift;

	# TODO how to not rescan hosts?
	my $sth = $self->get_dbh->prepare("SELECT ip_address FROM hosts WHERE test_area_id = ? ORDER by ip_address"); 
	$sth->execute($global_test_area_id);
	my @ips = map { $_->[0] } @{$sth->fetchall_arrayref};

	return @ips;
}

# $self->insert_port( ip => "1.2.3.4", transport_protocol => "tcp", port => 80);
sub insert_port {
	my $self = shift;
	my %args = @_;
	
	print "insert_port passed:\n" if $global_debug;
	print Dumper \%args if $global_debug;
	croak "yaptest::insert_port: Mandatory options not supplied\n" unless ((defined($args{ip}) or defined($args{host_id})) and defined($args{transport_protocol}) and defined($args{port}));

	my $transport_protocol_id = $self->get_id_of_transport_protocol(uc $args{transport_protocol});
	croak "ERROR: No such transport protocol!\n" unless defined($transport_protocol_id);

	my $host_id;
	if (defined($args{host_id})) {
		$host_id = $args{host_id};
	} else {
		if (defined($args{auto_add_host}) and $args{auto_add_host} eq "1") {
			$host_id = $self->insert_ip($args{ip});
		} else {
	        	$host_id = $self->get_id_of_ip($args{ip});
			unless (defined($host_id)) {
				print "WARNING: Tried to add port to $args{ip}, but host isn't being scanned.  Skipping insert.  Maybe you need to run 'yaptest-hosts.pl add' for this IP.\n";
				return undef;
			}
		}
	}
	my $port_id = $self->get_id_of_port(host_id => $host_id, transport_protocol => $args{transport_protocol}, port => $args{port});

	unless (defined($port_id)) {
		my $sth = $self->get_dbh->prepare("INSERT INTO ports (host_id, transport_protocol_id, port) VALUES (?, ?, ?)");
		$sth->execute($host_id, $transport_protocol_id, $args{port});
		$port_id = $self->get_id_of_port(host_id => $host_id, transport_protocol => $args{transport_protocol}, port => $args{port});
	}

	return $port_id;
}

# $self->get_id_of_icmp( ip => "1.2.3.4", type => 8, code => 0);
sub get_id_of_icmp {
	my $self = shift;
	my %args = @_;

	croak unless defined($args{ip}) and defined($args{type}) and defined($args{code});

	my $host_id = $self->get_id_of_ip($args{ip});
	return undef unless defined($host_id);

	my $sth = $self->get_dbh->prepare("SELECT id FROM icmp WHERE host_id = ? AND icmp_type = ? AND icmp_code = ?");
	$sth->execute($host_id, $args{type}, $args{code});
	my ($id) = $sth->fetchrow_array;

	return $id;
}

# $self->insert_icmp( ip => "1.2.3.4", type => 8, code => 0);
sub insert_icmp {
	my $self = shift;
	my %args = @_;
	print "insert_icmp passed:\n:" if $global_debug;
	print Dumper \%args if $global_debug;
	
	croak unless defined($args{ip}) and defined($args{type}) and defined($args{code});

	my $host_id = $self->insert_ip($args{ip});
	my $icmp_id = $self->get_id_of_icmp(ip => $args{ip}, type => $args{type}, code => $args{code});

	unless (defined($icmp_id)) {
		my $sth = $self->get_dbh->prepare("INSERT INTO icmp (host_id, icmp_type, icmp_code) VALUES (?, ?, ?)");
		$sth->execute($host_id, $args{type}, $args{code});
		$icmp_id = $self->get_id_of_icmp(ip => $args{ip}, type => $args{type}, code => $args{code});
	}

	return $icmp_id;
}

# $id = $self->get_id_of_port(ip => "1.2.3.4", transport_protocol => "tcp", port => 80);
sub get_id_of_port {
	my $self = shift;
	my %args = @_;

	print "get_id_of_port passed:\n" if $global_debug;
	print Dumper \%args if $global_debug;
	croak "yaptest::get_id_of_port: Madatory argument not supplied\n" unless (defined($args{ip}) or defined($args{host_id})) and defined($args{transport_protocol}) and defined($args{port});

	my $transport_protocol_id = $self->get_id_of_transport_protocol(uc $args{transport_protocol});
	croak unless defined($transport_protocol_id);

	my $host_id;
	if (defined($args{host_id})) {
		$host_id = $args{host_id};
	} else {
		$host_id = $self->get_id_of_ip($args{ip});
	}
	return undef unless defined($host_id);

	my $sth = $self->get_dbh->prepare("SELECT id FROM ports WHERE host_id = ? AND transport_protocol_id = ? AND port = ?");
	$sth->execute($host_id, $transport_protocol_id, $args{port});
	my ($id) = $sth->fetchrow_array;

	return $id;
}

# $id = $self->get_id_of_transport_protocol("TCP");
sub get_id_of_transport_protocol {
	my $self = shift;
	my $name = shift;

	my $sth = $self->get_dbh->prepare("SELECT id FROM transport_protocols WHERE name = ?");
	$sth->execute($name);
	my ($id) = $sth->fetchrow_array;

	return $id;
}

# $href = $self->get_all_open_ports_tcp()
# $href->{$host_n}->[80, 443]
sub get_all_open_ports_tcp {
	my $self = shift;
	my %hosts_ports;
	
	my $sth = $self->get_dbh->prepare("
		SELECT hosts.ip_address, ports.port, transport_protocols.name 
		FROM hosts 
		JOIN ports ON hosts.id = ports.host_id 
		JOIN transport_protocols ON transport_protocols.id = ports.transport_protocol_id 
		WHERE transport_protocols.name = 'TCP'
		      AND test_area_id = ?
		ORDER BY hosts.ip_address, ports.port 
	");
	
	$sth->execute($global_test_area_id);
	
	while (my ($ip, $port) = $sth->fetchrow_array) {
		unless (defined($hosts_ports{$ip})) {
			$hosts_ports{$ip} = [];
		}
		
		push @{$hosts_ports{$ip}}, $port;
	}
	
	return \%hosts_ports;
}

# $href = $self->get_all_open_ports_udp()
# $href->{$host_n}->[123, 161]
sub get_all_open_ports_udp {
	my $self = shift;
	my %hosts_ports;
	
	my $sth = $self->get_dbh->prepare("
		SELECT hosts.ip_address, ports.port, transport_protocols.name 
		FROM hosts 
		JOIN ports ON hosts.id = ports.host_id 
		JOIN transport_protocols ON transport_protocols.id = ports.transport_protocol_id 
		WHERE transport_protocols.name = 'UDP'
		      AND test_area_id = ?
		ORDER BY hosts.ip_address, ports.port 
	");
	
	$sth->execute($global_test_area_id);
	
	while (my ($ip, $port) = $sth->fetchrow_array) {
		unless (defined($hosts_ports{$ip})) {
			$hosts_ports{$ip} = [];
		}
		
		push @{$hosts_ports{$ip}}, $port;
	}
	
	return \%hosts_ports;
}

# insert_port_info (ip => $ip, $port => $port, transport_protocol => $trans, port_info_key => $key, port_info_value => $value)
sub insert_port_info {
	my $self = shift;
	my %args = @_;
	
	croak "yaptest::insert_port_info called with incorrect arguments\n" unless defined($args{ip}) and defined($args{port}) and defined($args{transport_protocol}) and defined($args{port_info_key}) and defined($args{port_info_value});

	my $transport_protocol_id = $self->get_id_of_transport_protocol(uc $args{transport_protocol});
	croak "ERROR: No such transport protocol!\n" unless defined($transport_protocol_id);

	my $port_id = $self->insert_port(
						ip => $args{ip},
						port => $args{port},
						transport_protocol => $args{transport_protocol}
						
	);

	# insert_port returns undef if the IP isn't beign scanned
	unless (defined($port_id)) {
		print "WARNING: Tried to add info to a port that isn't in the database.  Skipped $args{ip}:$args{port}/$args{transport_protocol}\n";
		return undef;
	}

	my $port_key_id = $self->insert_port_key($args{port_info_key});

	my $sth_select = $self->get_dbh->prepare("SELECT id FROM port_info WHERE port_id = ? AND key_id = ? AND value = ?");
	$sth_select->execute($port_id, $port_key_id, $args{port_info_value});
	my ($port_info_id) = $sth_select->fetchrow_array;

	# UPDATE
	if (defined($port_info_id)) {
		# do nothing 

		# my $sth_insert = $self->get_dbh->prepare("UPDATE port_info SET value = ? WHERE port_id = ? AND key_id = ?");
		# $sth_insert->execute($args{port_info_value}, $port_id, $port_key_id);

		# $sth_select->execute($port_id, $port_key_id);
		# $port_info_id = $sth_select->fetchrow_array;

	# INSERT
	} else {
		my $sth_insert = $self->get_dbh->prepare("INSERT INTO port_info (port_id, key_id, value) VALUES (?, ?, ?)");
		$sth_insert->execute($port_id, $port_key_id, $args{port_info_value});

		$sth_select->execute($port_id, $port_key_id, $args{port_info_value});
		$port_info_id = $sth_select->fetchrow_array;
	}

	return $port_info_id;
}

# my $id = get_id_of_port_key("amap_protocol_guess");
sub get_id_of_port_key {
	my $self = shift;
	my $key_name = shift;
	print "get_id_of_port_key called with key name $key_name\n" if $global_debug;

	my $sth = $self->get_dbh->prepare("SELECT id FROM port_keys WHERE name = ?");
	$sth->execute($key_name);
	my ($id) = $sth->fetchrow_array;

	return $id;
}

sub insert_port_key {
	my $self = shift;
	my $key_name = shift;
	print "insert_port_key: called with key name $key_name\n" if $global_debug;
	$self->_lock_port_key();

	my $sth = $self->get_dbh->prepare("SELECT id FROM port_keys WHERE name = ?");
	$sth->execute($key_name);
	my ($id) = $sth->fetchrow_array;

	unless (defined($id)) {
		my $sthi = $self->get_dbh->prepare("INSERT INTO port_keys (name) VALUES (?)");
		$sthi->execute($key_name);

		$sth->execute($key_name);
		($id) = $sth->fetchrow_array;
	}
	$self->_unlock_port_key();

	return $id;
}

sub _semaphore_take {
	my $self = shift;
	my $res_name = shift;
	my $res_id = $self->_res_name_to_sem_id($res_name);
	my $id = semget($res_id, 1, 0666 | IPC_CREAT );
	die "ERROR: Could not get create/use semaphore: $!\n" if !defined($id);
	
	my $semnum = 0;
	my $semflag = SEM_UNDO;
	
	# 'take' semaphore
	# wait for semaphore to be zero
	my $semop = 0;
	my $opstring1 = pack("s!s!s!", $semnum, $semop, $semflag);
	
	# Increment the semaphore count
	$semop = 1;
	my $opstring2 = pack("s!s!s!", $semnum, $semop,  $semflag);
	my $opstring = $opstring1 . $opstring2;
	
	semop($id, $opstring) || die "$!";
}

sub _semaphore_give {
	my $self = shift;
	my $res_name = shift;
	my $res_id = $self->_res_name_to_sem_id($res_name);
	my $id = semget($res_id, 1, 0666 | IPC_CREAT );
	die "ERROR: Could not get create/use semaphore: $!\n" if !defined($id);
	
	my $semnum = 0;
	my $semflag = SEM_UNDO;

	# Decrement the semaphore count
	my $semop = -1;
	my $opstring = pack("s!s!s!", $semnum, $semop, $semflag);
	
	semop($id, $opstring) || die "$!";
}

sub _res_name_to_sem_id {
	my $self = shift;
	my $res_name = shift;
	return unpack("N", substr(md4($self->get_config('yaptest_dbname') . $res_name), 0, 4));
}

sub _lock_port_key {
	my $self = shift;
	$self->_semaphore_take("host_port_key"); # will block until no other procs are trying to 
					  # do the same thing.
}

sub _unlock_port_key {
	my $self = shift;
	$self->_semaphore_give("host_port_key");
}

sub _lock_host_key {
	my $self = shift;
	$self->_semaphore_take("host_host_key"); # will block until no other procs are trying to 
					  # do the same thing.
}

sub _unlock_host_key {
	my $self = shift;
	$self->_semaphore_give("host_host_key");
}

# my $ip_aref = get_ips_from_open_port_tcp(111);
sub get_ips_from_open_port_tcp {
	my $self = shift;
	my $port = shift;
	print "get_ip_from_open_port_tcp: called with port = $port\n";
	
	my $sth = $self->get_dbh->prepare("
		SELECT ip_address 
		FROM view_ports 
		WHERE port = ? AND transport_protocol = 'TCP' AND test_area_id = ?
		ORDER BY ip_address
	");
	
	$sth->execute($port, $global_test_area_id);
	
	my $ips_aref = [ map { $_->[0] } @{$sth->fetchall_arrayref} ];
	
	return $ips_aref;
}

# my $ip_aref = get_ips_from_open_port_udp(111);
sub get_ips_from_open_port_udp {
	my $self = shift;
	my $port = shift;
	print "get_ip_from_open_port_udp: called with port = $port\n";
	
	my $sth = $self->get_dbh->prepare("
		SELECT ip_address 
		FROM view_ports 
		WHERE port = ? AND transport_protocol = 'UDP' AND test_area_id = ?
		ORDER BY ip_address
	");
	
	$sth->execute($port, $global_test_area_id);
	
	my $ips_aref = [ map { $_->[0] } @{$sth->fetchall_arrayref} ];
	
	return $ips_aref;
}

# my $ip_port_aref = get_ip_port_from_nmap_service_name("http");
sub get_ip_port_from_nmap_service_name {
	my $self = shift;
	my $service_name  = shift;
	print "get_ip_port_from_nmap_service_name: called with server = $service_name\n";
	
	my $sth = $self->get_dbh->prepare("
		SELECT ip_address, port
		FROM view_port_info 
		WHERE port_info_key = 'nmap_service_name' and value = ? AND test_area_id = ?
		ORDER BY ip_address, port
	");
	
	$sth->execute($service_name, $global_test_area_id);
	
	my $ip_port_aref = [ map { { ip => $_->[0], port => $_->[1] } } @{$sth->fetchall_arrayref} ];
	
	return $ip_port_aref;
}

sub get_ip_port_from_port_range {
	my $self = shift;
	my $low_port = shift;
	my $high_port = shift;
	print "get_ip_port_from_port_range: called with range $low_port..$high_port\n";
	
	my $sth = $self->get_dbh->prepare("
		SELECT DISTINCT ip_address, port
		FROM view_port_info 
		WHERE port >= ? AND port <= ? AND test_area_id = ?
		ORDER BY ip_address, port
	");
	
	$sth->execute($low_port, $high_port, $global_test_area_id);
	
	my $ip_port_aref = [ map { { ip => $_->[0], port => $_->[1] } } @{$sth->fetchall_arrayref} ];
	
	return $ip_port_aref;
}

# my $ip_port_aref = get_ip_port_from_nmap_service_name("http");
sub get_ip_port_from_nmap_service_name_ssl {
	my $self = shift;
	my $service_name  = shift;
	print "get_ip_port_from_nmap_service_name: called with server = $service_name\n";
	
	my $sth = $self->get_dbh->prepare("
select ip_address, port from view_port_info where (ip_address, port, transport_protocol) in (select ip_address, port, transport_protocol from view_port_info where port_info_key = 'nmap_service_tunnel' and value = 'ssl') and port_info_key = 'nmap_service_name' and value = ? and test_area_id = ? order by ip_address, port;
	");
	
	$sth->execute($service_name, $global_test_area_id);
	
	my $ip_port_aref = [ map { { ip => $_->[0], port => $_->[1] } } @{$sth->fetchall_arrayref} ];
	
	return $ip_port_aref;
}

# my $ip_port_aref = get_ip_port_from_nmap_service_name("http");
sub get_ip_port_from_nmap_service_name_nonssl {
	my $self = shift;
	my $service_name  = shift;
	print "get_ip_port_from_nmap_service_name: called with server = $service_name\n";
	
	my $sth = $self->get_dbh->prepare("
select ip_address, port from view_port_info where (ip_address, port, transport_protocol) not in (select ip_address, port, transport_protocol from view_port_info where port_info_key = 'nmap_service_tunnel' and value = 'ssl') and port_info_key = 'nmap_service_name' and value = ? and test_area_id = ? order by ip_address, port;
	");
	
	$sth->execute($service_name, $global_test_area_id);
	
	my $ip_port_aref = [ map { { ip => $_->[0], port => $_->[1] } } @{$sth->fetchall_arrayref} ];
	
	return $ip_port_aref;
}

# my $ip_port_aref = get_ip_port_from_nmap_service_name("http");
sub get_ip_port_from_nmap_tunnel_name {
	my $self = shift;
	my $service_name  = shift;
	print "get_ip_port_from_nmap_tunnel_name: called with tunnel = $service_name\n";
	
	my $sth = $self->get_dbh->prepare("
		SELECT ip_address, port
		FROM view_port_info 
		WHERE port_info_key = 'nmap_service_tunnel' and value = ? AND test_area_id = ?
		ORDER BY ip_address, port
	");
	
	$sth->execute($service_name, $global_test_area_id);
	
	my $ip_port_aref = [ map { { ip => $_->[0], port => $_->[1] } } @{$sth->fetchall_arrayref} ];
	
	return $ip_port_aref;
}

sub get_all_hosts {
	my $self = shift;
	my %hosts_ports;
	
	my $sth = $self->get_dbh->prepare("
	 	SELECT ip_address
		FROM hosts
		WHERE test_area_id = ?
		ORDER BY ip_address
	");
	
	$sth->execute($global_test_area_id);
	
	my $ips_aref = [ map { $_->[0] } @{$sth->fetchall_arrayref} ];
	
	return $ips_aref;
}

sub run_test {
	my $self = shift;
	my %opts = @_;

	my %opt_markups = (
		'::IP::'                 => { output_file_sort_key => 10, db_field_name => 'ip_address'},
		'::IPFILE::'             => { output_file_sort_key => 20, db_field_name => 'ip_address'},
		'::PORT::'               => { output_file_sort_key => 30, db_field_name => 'port'},
		'::PORTFILE::'           => { output_file_sort_key => 40, db_field_name => 'port'},
		'::PORTLIST::'           => { output_file_sort_key => 50, db_field_name => 'port'},
		'::PORTLIST-SPACE::'     => { output_file_sort_key => 60, db_field_name => 'port'},
		'::TRANSPORT_PROTOCOL::' => { output_file_sort_key => 70, db_field_name => 'tranport_protocol'},
		'::USERNAME::'           => { output_file_sort_key => 80, db_field_name => 'username'},
		'::USERNAMEFILE::'       => { output_file_sort_key => 90, db_field_name => 'username'},
		'::PASSWORD::'           => { output_file_sort_key => 80, db_field_name => 'username'},
		'::PASSWORDFILE::'       => { output_file_sort_key => 80, db_field_name => 'username'}
	);

	# incompatible selections
	#
	#  TODO

	my $table           = 'view_ports';
	my $port_info_table = "view_port_info";
	my $host_info_table = "view_host_info";
	my @selected_fields;
	my $need_ip_file = 0;
	my $need_port_list = 0;
	my $port_list_sep;
	my $ssl = undef;

	# Process "parser" option
	my %parser = (); 
	if (defined($opts{parser})) {
		%parser = (parser => $opts{parser});
	}
	
	# Process "max_lines" option
	my $max_lines = $opts{max_lines};
	if (defined($opts{max_lines})) {
		$max_lines = $opts{max_lines};
	} else {
		$max_lines = 0; # meaning no limit
	}
	
	# Process "inactivity_timeout" option
	my $inactivity_timeout = $opts{inactivity_timeout};
	if (defined($opts{inactivity_timeout})) {
		$inactivity_timeout = $opts{inactivity_timeout};
	} else {
		$inactivity_timeout = 0; # meaning no timeout
	}
	
	# Process "timeout" option
	if (defined($opts{timeout})) {
		unless ($opts{timeout} >= 0 and $opts{timeout} < (1 << 31)) {
			croak "ERROR: run_test was passed an invalid timeout parameter: $opts{timeout}\n";
		}
	} else {
		$opts{timeout} = 0; # meaning no timeout
	}
	my $timeout = $opts{timeout};
	
	# Process "command" option
	unless (defined($opts{command})) {
		croak "ERROR: run_test was called without a 'command' option\n";
	}
	my $need_port = 0;
	my $need_ip = 0;
	my $need_port_info = 0;
	my $need_host_info = 0;
	my $need_hostname = 0;
	my $port_info_key = undef;
	my $host_info_key = undef;
	my $need_username = 0;
	my $need_password = 0;
	foreach my $opt_markup (sort {$opt_markups{$a}{output_file_sort_key} <=> $opt_markups{$b}{output_file_sort_key}} keys %opt_markups) {
		print "Processing $opt_markup, command = $opts{command}\n" if $global_debug;
		if ($opts{command} =~ /$opt_markup/ or (defined($opts{output_file}) and $opts{output_file} =~ /$opt_markup/)) { #TODO this won't match ::HOSTINFO-blah::, but it doesn't matter.  why do it?
			$need_ip_file = 1 if $opts{command} =~ /::IPFILE::/;
			if ($opts{command} =~ /::PORTLIST-SPACE::/) {
				$need_port_list = 1;
				$need_port = 1;
				$port_list_sep = " ";
			}
			if ($opts{command} =~ /::PORTLIST::/) {
				$need_port_list = 1;
				$need_port = 1;
				$port_list_sep = ",";
			}
			if ($opts{command} =~ /::PORT::/) {
				$need_port = 1;
			}
			if ($opts{command} =~ /::HOSTINFO-([^:]+)::/) {
				$host_info_key = $1;
				$need_host_info = 1;
				$need_ip = 1;
				push @selected_fields, 'value';
			}
			if ($opts{command} =~ /::PORTINFO-([^:]+)::/) {
				$port_info_key = $1;
				$need_port_info = 1;
				$need_port = 1;
				push @selected_fields, 'value';
			}
			if ($opts{command} =~ /::HOSTNAME::/) {
				$need_hostname = 1;
				push @selected_fields, 'hostname';
			}
			if ($opts{command} =~ /::PORT-\d+::/) {
				$need_port = 1;
				push @selected_fields, 'port';
			}
			if ($opts{command} =~ /::IPFILE::/) {
				$need_ip = 1;
			}
			if ($opts{command} =~ /::IP::/) {
				$need_ip = 1;
			}
			if ($opts{command} =~ /::USERNAME::/) {
				$need_username = 1;
			}
			if ($opts{command} =~ /::USERNAMEFILE::/) {
				$need_username = 1;
			}
			if ($opts{command} =~ /::PASSWORD::/) {
				$need_password = 1;
			}
			if ($opts{command} =~ /::PASSWORDFILE::/) {
				$need_password = 1;
			}
			push @selected_fields, $opt_markups{$opt_markup}{db_field_name};
		}
	}

	print "need_ip: $need_ip\n" if $global_debug;
	print "need_port: $need_port\n" if $global_debug;
	print "need_username: $need_username\n" if $global_debug;
	print "need_password: $need_password\n" if $global_debug;
	if ($need_ip and !$need_port and !$need_username and !$need_password) {
		$table = "view_hosts";
	} elsif ($need_ip and $need_port and !$need_username and !$need_password) {
		$table = "view_ports";
	} elsif ($need_ip and $need_host_info and !$need_port and !$need_username and !$need_password) {
		$table = "view_host_info";
	} elsif ($need_ip and $need_port_info and $need_port and !$need_username and !$need_password) {
		$table = "view_port_info";
	} elsif ($need_username or $need_password) {
		$table = "view_credentials";
	} else {
		croak "ERROR: run_test couldn't figure out which view to use\n";
	}
	# TODO hostname
	
	# Process "output_file" option
	if (defined($opts{output_file})) {
		# TODO check filename is valid
	} else {
		($opts{output_file}) = $opts{command} =~ /^\s*(\S+)[\s.]/;
		unless ($need_ip_file) {
			foreach my $opt_markup (sort {$opt_markups{$a}{output_file_sort_key} <=> $opt_markups{$b}{output_file_sort_key}} keys %opt_markups) {
				if ($opts{command} =~ /$opt_markup/) {
					$opts{output_file} .= '-' . $opt_markup;
				}
			}
		}
		$opts{output_file} .= '.out';
	}
	
	# Process "parallel_processes" option
	if (defined($opts{parallel_processes})) {
		unless (($opts{parallel_processes} + 0 > 0) and ($opts{parallel_processes} + 0 < 1000)) {
			croak "ERROR: run_test received a 'parallel_processes' value that wasn't > 0 and < 1000\n";
		}
	} else {
		$opts{parallel_processes} = 1;
	}
	my $pm = new Parallel::ForkManager($opts{parallel_processes});
	
	my %pid_data;
	$pm->run_on_finish(
		sub { 	
			my ($pid, $exit_code, $ident) = @_;
			$self->set_complete(@{$pid_data{$pid}});
		}
	);

	# Process filter options
	my @where_clauses = ();
	my @where_values = ();
	my @hwhere_clauses = ();
	my @hwhere_values = ();
	for my $fkeyname ("filter", "host_filter") {
		my @tmp_where_clauses;
		my @tmp_where_values;
		next unless defined($opts{$fkeyname});
		my $filter_href = $opts{$fkeyname};

		# If we have ::HOSTINFO-win_domwkg:: in the "command", this implies that we only want
		# rows from view_port_info where host_info_key = win_domwkg
		if (defined($host_info_key)) {
			push @tmp_where_clauses, "key = ?";
			push @tmp_where_values, $host_info_key;
		}

		# If we have ::PORTINFO-ldap_base_dn:: in the "command" this implies that we only want
		# rows from view_port_info where port_info_key = ldap_base_dn
		if (defined($port_info_key)) {
			push @tmp_where_clauses, "port_info_key = ?";
			push @tmp_where_values, $port_info_key;
		}

		# TODO hostname

		foreach my $filter_key (reverse sort keys %$filter_href) {
			if ($filter_key eq "ssl") {
				if ($filter_href->{ssl} == 0) {
					$ssl = 0;
				} elsif ($filter_href->{ssl} == 1) {
					$ssl = 1;
				} else {
					croak "ERROR: run_test was passed an invalid value to the ssl option\n";
				}
				if (defined($ssl)) {
					$table = $port_info_table = 'view_port_info_ssl';
					if ($ssl == 0) {
						push @tmp_where_clauses, 'nmap_service_tunnel is null';
					} elsif ($ssl == 1) {
						push @tmp_where_clauses, 'nmap_service_tunnel = ?';
						push @tmp_where_values, 'ssl';
					} else {
						croak "ERROR: Internal error processing ssl option.  This shouldn't happen.\n";
					}
				} 
			}
	
			if ($filter_key eq "port") {
				$table = "view_ports";
				if (ref($filter_href->{port}) eq 'ARRAY') {
					push @tmp_where_clauses, "port IN (" . (join ', ', map {'?'} @{$filter_href->{port}}) . ")";
					push @tmp_where_values, @{$filter_href->{port}};
				} else {
					my $port = $filter_href->{port};
					if ($port =~ /^\d+$/) {
						push @tmp_where_clauses, "port = ?";
						push @tmp_where_values, $filter_href->{port};
					} elsif ($port =~ /^(\d+)-(\d+)$/) {
						my $port1 = $1;
						my $port2 = $2;
						push @tmp_where_clauses, "port >= ? AND port <= ?";
						push @tmp_where_values, $port1, $port2;
					} else {
						croak "ERROR: run_test was passed an invalid argument for 'port': $port\n";
					}
				}
			}
			if ($filter_key eq "ip") {
				if (ref($filter_href->{ip}) eq 'ARRAY') {
					push @tmp_where_clauses, "ip_address IN (" . (join ', ', map {'?'} @selected_fields) . ")";
					push @tmp_where_values, @{$filter_href->{ip_address}};
				} else {
					push @tmp_where_clauses, "ip_address = ?";
					push @tmp_where_values, $filter_href->{ip_address};
				}
			}
			if ($filter_key eq "transport_protocol") {
				$filter_href->{transport_protocol} = uc($filter_href->{transport_protocol});
				if (ref($filter_href->{transport_protocol}) eq 'ARRAY') {
					push @tmp_where_clauses, "transport_protocol IN (" . (join ', ', map {'?'} @selected_fields) . ")";
					push @tmp_where_values, @{$filter_href->{transport_protocol}};
				} else {
					push @tmp_where_clauses, "transport_protocol = ?";
					push @tmp_where_values, $filter_href->{transport_protocol};
				}
			}
			if ($filter_key eq "port_info") {
				$table = $port_info_table;
				my @port_info = ();
				if (ref($filter_href->{port_info}) eq 'ARRAY') {
					push @port_info, @{$filter_href->{port_info}};
				} else {
					push @port_info, $filter_href->{port_info};
				}
	
				my @pi_where_clauses = ();
				my @pi_where_values = ();
				foreach my $port_info (@port_info) {
					my ($port_info_key, $operator, $value) = $port_info =~ /\s*(\S+)\s+(\S+)\s+(.*)/;
					unless (defined($port_info_key) and defined($operator) and defined($value)) {
						croak "ERROR: run_test was passed an invalid argument to port_info\n";
					}
					$operator = uc($operator);
					unless ($operator eq '=' or $operator eq 'LIKE' or $operator eq 'ILIKE' or $operator eq '>' or $operator eq '<' or $operator eq '<=' or $operator eq '>=') {
						croak "ERROR: run_test was passed an invalid operator in port_info parameter: $operator\n";
					}
					if ($operator eq 'LIKE' or $operator eq 'ILIKE') {
						$value = "%$value%";
					}
					push @pi_where_clauses, "(port_info_key = ? AND value $operator ?)";
					push @pi_where_values, $port_info_key, $value;
				}
				push @tmp_where_clauses, "( " . join(" OR ", @pi_where_clauses) . " )";
				push @tmp_where_values, @pi_where_values;
			}
			if ($filter_key eq "host_info") {
				$table = $host_info_table;
				my @host_info = ();
				if (ref($filter_href->{host_info}) eq 'ARRAY') {
					push @host_info, @{$filter_href->{host_info}};
				} else {
					push @host_info, $filter_href->{host_info};
				}
	
				my @hi_where_clauses = ();
				my @hi_where_values = ();
				foreach my $host_info (@host_info) {
					my ($host_info_key, $operator, $value) = $host_info =~ /\s*(\S+)\s+(\S+)\s+(.*)/;
					unless (defined($host_info_key) and defined($operator) and defined($value)) {
						croak "ERROR: run_test was passed an invalid argument to host_info\n";
					}
					$operator = uc($operator);
					unless ($operator eq '=' or $operator eq 'LIKE' or $operator eq 'ILIKE' or $operator eq '>' or $operator eq '<' or $operator eq '<=' or $operator eq '>=') {
						croak "ERROR: run_test was passed an invalid operator in host_info parameter: $operator\n";
					}
					if ($operator eq 'LIKE' or $operator eq 'ILIKE') {
						$value = "%$value%";
					}
					push @hi_where_clauses, "(key = ? AND value $operator ?)";
					push @hi_where_values, $host_info_key, $value;
				}
				push @tmp_where_clauses, "( " . join(" OR ", @hi_where_clauses) . " )";
				push @tmp_where_values, @hi_where_values;
			}
		}
		if ($fkeyname eq "filter") {
			@where_clauses = @tmp_where_clauses;
			@where_values  = @tmp_where_values;
		}
		if ($fkeyname eq "host_filter") {
			@hwhere_clauses = @tmp_where_clauses;
			@hwhere_values  = @tmp_where_values;
		}
	}

	# Form the clause: ... AND id NOT IN (SELECT <everything we've already scanned>)
	# TODO: NOT IN clauses should be portable, but they're dirty.  Figure out how to write the JOIN.
	my $not_in_clause = "";
	my @command = ();
	my $progress_type = ""; 
	unless (defined($ENV{'YAPTEST_RESUME'} and $ENV{'YAPTEST_RESUME'} eq "0")) {
		$progress_type = $table;
		if ($table eq "view_hosts") {
			$not_in_clause = " AND host_id NOT IN (SELECT host_id FROM view_host_progress WHERE command = ?)";
			@command = ($opts{command});
		} elsif ($table eq "view_host_info" and scalar(grep { $_ eq "key" or $_ eq "value"} @selected_fields)) {
			$not_in_clause = " AND host_info_id NOT IN (SELECT host_info_id FROM view_host_info_progress WHERE command = ?)";
			@command = ($opts{command});
		} elsif ($table eq "view_host_info") {
			$not_in_clause = " AND host_id NOT IN (SELECT host_id FROM view_host_progress WHERE command = ?)";
			@command = ($opts{command});
		} elsif (($table eq "view_port_info" or $table eq "view_port_info_ssl") and scalar(grep { $_ eq "port_info_key" or $_ eq "value"} @selected_fields)) {
			$not_in_clause = " AND port_info_id NOT IN (SELECT port_info_id FROM view_port_info_progress WHERE command = ?)";
			@command = ($opts{command});
		} elsif (($table eq "view_port_info" or $table eq "view_port_info_ssl") and scalar(grep { $_ eq "port"} @selected_fields)) {
			$not_in_clause = " AND port_id NOT IN (SELECT port_id FROM view_port_progress WHERE command = ?)";
			@command = ($opts{command});
		} elsif ($table eq "view_port_info" or $table eq "view_port_info_ssl") {
			$not_in_clause = " AND host_id NOT IN (SELECT host_id FROM view_host_progress WHERE command = ?)";
			@command = ($opts{command});
		} elsif ($table eq "view_ports") {
			if ($need_port) {
				# something like nikto where we select a port and run against a port
				$not_in_clause = " AND port_id NOT IN (SELECT port_id FROM view_port_progress WHERE command = ?)";
			} else {
				# something like nxscan where we select a port, but run against a host
				$not_in_clause = " AND host_id NOT IN (SELECT host_id FROM view_host_progress WHERE command = ?)";
			}
			@command = ($opts{command});
		} elsif ($table eq "view_os_usernames") {
			croak "ERROR: Don't know how to resume a scan that uses view_os_usernames.  Still on the TODO list.  Sorry\n";
		} elsif ($table eq "view_passwords") {
			croak "ERROR: Don't know how to resume a scan that uses view_password.  Still on the TODO list.  Sorry\n";
		} else {
			croak "ERROR: Don't know how to resume a scan that uses $table.  Still on the TODO list.  Sorry\n";
		}
		# TODO hostnames, credentials
		# $not_in_clause = " AND credential_id NOT IN (SELECT credential_id FROM view_credential_progress WHERE command = ?)";
		# $not_in_clause = " AND hostname_id NOT IN (SELECT hostname_id FROM view_hostname_progress WHERE command = ?)";
	}

	# Process host_filter option
	# If the run_test api was passed a "host_filter" we don't apply
	# run_test's "filter" to all hosts, instead we apply it to a subset
	# of hosts.  The following code redefines $table to correspond to
	# the appropriate subset of hosts.
	if (defined($opts{host_filter})) {
		$table = "(
		SELECT * 
		FROM $table 
		WHERE host_id IN (
			SELECT DISTINCT host_id 
			FROM $table 
			WHERE test_area_name = ? " . (@hwhere_clauses ? " AND " . (join(" AND ", @hwhere_clauses)) : "") . "
		)
		) hfilter";
	}

	# Mandate that we always select trans if port is being selected.  We need this later.
	if (scalar(grep { $_ eq 'port'} @selected_fields) and not scalar(grep { $_ eq 'tranport_protocol'} @selected_fields)) {
		push @selected_fields, "transport_protocol";
	}

	my $sql = "SELECT DISTINCT " . (join ', ', @selected_fields) . " FROM $table WHERE test_area_name = ? " . (@where_clauses ? " AND " . (join(" AND ", @where_clauses)) : "") . $not_in_clause;
	print "SQL: $sql\n" if $global_debug;
	my $sth = $self->get_dbh->prepare($sql);
	# TODO sql injection in selected_fields
	if (defined($opts{host_filter})) {
		$sth->execute($global_test_area, @hwhere_values, $global_test_area, @where_values, @command);
	} else {
		$sth->execute($global_test_area, @where_values, @command);
	}
	my $results_aref = $sth->fetchall_arrayref();
	$sth->finish;
	print "Targets for this test are:\n";
	$self->print_table($results_aref, 20);

	# Start tests that run on a single IP, but multiple ports
	# e.g.  amap ip port1 port2 port3 ...
	if ($need_port_list) {

		# Read all ips and ports into a hash indexed by IP.
		# We'll then be able to say:
		#      1.2.3.4 has open ports: @$ports_of{'1.2.3.4'}
		my %ports_of;
		row: foreach my $row_aref (@$results_aref) {
			my $ip;
			my $port;
			my $trans;
			field: foreach my $index (0..(scalar(@selected_fields) - 1)) {
				if ($selected_fields[$index] eq 'ip_address') {
					$ip = $row_aref->[$index];
				}
				if ($selected_fields[$index] eq 'port') {
					$port = $row_aref->[$index];
				}
				if ($selected_fields[$index] eq 'transport_protocol') {
					$trans = $row_aref->[$index];
				}
			}
			$ports_of{$ip}{$port}{$trans} = 1;
		}

		# Run the desired command on each IP in turn
		foreach my $ip (keys %ports_of) {
			my $portlist = join($port_list_sep, sort keys %{$ports_of{$ip}});
			# in case all port have already been completed
			unless (defined($portlist) and $portlist) {
				$self->get_dbh->{InactiveDestroy} = 1;
				$pm->finish;
				next;
			}
			my $command = $opts{command};
			my $output_file = $opts{output_file};
			$command =~ s/::PORTLIST[A-Z-]*::/$portlist/g;
			$command =~ s/::IP::/$ip/g;
			$output_file =~ s/::PORTLIST[A-Z-]*::/$portlist/g;
			$output_file =~ s/::IP::/$ip/g;
			$parser{ip} = $ip;

			if ($output_file =~ /::(IPFILE|PORT|PORTFILE|PORTLIST|TRANSPORT_PROTOCOL)::/) {
				croak "ERROR: Markup specified in output file name.  This isn't supported when using a file of IPs (IPFILE).\n";
			}

			my $child_pid = $pm->start;
			if ($child_pid) {
				$pid_data{$child_pid} = ["ip_with_ports", $opts{command}, $ip, $ports_of{$ip}];
			} else {
				$is_child = 1; # set this so destructor doesn't close db handle
				$self->get_dbh->{InactiveDestroy} = 1;
				$self->del_dbh(); # so we don't accidentially use the db handle
				$self->run_command_save_output($command, $output_file, timeout => $timeout, max_lines => $max_lines, inactivity_timeout => $inactivity_timeout, %parser);
				$pm->finish;
			}
		}
		$pm->wait_all_children;

	# Start tests that run on a file of IP addresses
	# e.g. ike-scan -f ips.txt
	} elsif ($need_ip_file) {
		my $tmp_fh;
		my $tmp_filename;

		# Create a file containing IP addresses
		($tmp_fh, $tmp_filename) = tempfile('yaptest-ips-XXXXX');
		my $count = 0;
		row: foreach my $row_aref (@$results_aref) {
			field: foreach my $index (0..(scalar(@selected_fields) - 1)) {
				if ($selected_fields[$index] eq 'ip_address') {
					my $ip = $row_aref->[$index];
					print $tmp_fh "$ip\n";
					$count++;
					next row;
				}
			}
		}
		close($tmp_fh);
		
		# only run a command if we actually wrote some ips to the file
		if ($count) {
			my $output_file = $opts{output_file};
			my $command = $opts{command};
			$command =~ s/::IPFILE::/$tmp_filename/;
			$parser{ip} = undef;
	
			if ($output_file =~ /::(IP|IPFILE|PORT|PORTFILE|PORTLIST|TRANSPORT_PROTOCOL)::/) {
				croak "ERROR: Markup specified in output file name.  This isn't supported when using a file of IPs (IPFILE).\n";
			}
	
			$self->run_command_save_output($command, $output_file, timeout => $timeout, max_lines => $max_lines, inactivity_timeout => $inactivity_timeout, %parser);
			$self->set_complete("ip_list", $opts{command}, $tmp_filename);
			unlink $tmp_filename;
		}

	# Start tests that run on a single port
	# e.g. nikto -h ip1 -p port1
	#      nikto -h ip1 -p port2
	#      nikto -h ip2 -p port3
	} else {
		my @child_pid = ();
		if ($progress_type eq "view_ports" and scalar(grep { $_ eq "port" or $_ eq "transport_protocol" } @selected_fields)) {
			$progress_type = "single_port";
		} elsif ($progress_type eq "view_ports") {
			$progress_type = "single_port";
		} elsif (($progress_type eq "view_port_info" or $progress_type eq "view_port_info_ssl") and scalar(grep { $_ eq "port_info_key" or $_ eq "value" } @selected_fields)) {
			$progress_type = "single_port_info";
		} elsif ($progress_type eq "view_port_info" or $progress_type eq "view_port_info_ssl") {
			$progress_type = "single_port";
		} elsif (($progress_type eq "view_host_info") and scalar(grep { $_ eq "key" or $_ eq "value" } @selected_fields)) {
			$progress_type = "single_host_info";
		} elsif ($progress_type eq "view_host_info") {
			$progress_type = "single_port";
		} elsif ($progress_type eq "view_hosts") {
			$progress_type = "single_port";
		} else {
			croak "ERROR: Can't determine which progress table to use.  view=$progress_type\n";
		}
		foreach my $row_aref (@$results_aref) {
			my $command = $opts{command};
			my $output_file = $opts{output_file};
			my ($ip, $port, $transport_protocol);
			my @info_args = ();
			foreach my $index (0..(scalar(@selected_fields) - 1)) {
				if ($selected_fields[$index] eq 'ip_address') {
					$ip = $row_aref->[$index];
					$command =~ s/::IP::/$ip/g;
					$output_file =~ s/::IP::/$ip/g;
					$parser{ip} = $ip;
				}
				if ($selected_fields[$index] eq 'value') {
					my $value = $row_aref->[$index];
					if ($command =~ /::PORTINFO-[^:]+::/) {
						$progress_type = "single_port_info";
						$command =~ s/::PORTINFO-[^:]+::/$value/g;
						$output_file =~ s/::PORTINFO-[^:]+::/$value/g;
						@info_args = ($port_info_key, $value)
					}
					if ($command =~ /::HOSTINFO-[^:]+::/) {
						$progress_type = "single_host_info";
						$command =~ s/::HOSTINFO-[^:]+::/$value/g;
						$output_file =~ s/::HOSTINFO-[^:]+::/$value/g;
						@info_args = ($host_info_key, $value)
					}
				}
				# TODO hostnames, creds
				if ($selected_fields[$index] eq 'port') {
					$port = $row_aref->[$index];
					$command =~ s/::PORT::/$port/g;
					while ($command =~ /::PORT-(\d+)::/) {
						my $n = $1;
						$command =~ s/::PORT-\d+::/$port - $n/e;
					}
					$output_file =~ s/::PORT::/$port/g;
					while ($output_file =~ /::PORT-(\d+)::/) {
						my $n = $1;
						$output_file =~ s/::PORT-\d+::/$port - $n/e;
					}
				}
				if ($selected_fields[$index] eq 'transport_protocol') {
					$transport_protocol = $row_aref->[$index];
					$command =~ s/::TRANSPORT_PROTOCOL::/$transport_protocol/g;
					$output_file =~ s/::TRANSPORT_PROTOCOL::/$transport_protocol/g;
				}
			}
				
			my $child_pid = $pm->start;
			if ($child_pid) {
				$pid_data{$child_pid} = [$progress_type, $opts{command}, $ip, $port, $transport_protocol, @info_args];
			} else {
				$is_child = 1; # set this so destructor doesn't close db handle
				$self->get_dbh->{InactiveDestroy} = 1;
				$self->del_dbh(); # so we don't accidentially use the db handle
				$self->run_command_save_output($command, $output_file, timeout => $timeout, max_lines => $max_lines, inactivity_timeout => $inactivity_timeout, %parser);
				$pm->finish;
			}
		}
		$pm->wait_all_children;
	}	

	# TODO command injection in "system" above.
	# TODO optionally store output in database instead of file system
}

sub insert_port_progress {
	my $self = shift;
	my $ip = shift;
	my $port = shift;
	my $trans = shift;
	my $command = shift;
	my $state = shift;

	my $port_id = $self->get_port_id( ip_address => $ip, port => $port, transport_protocol => $trans);
	my $command_id = $self->insert_command($command);
	my $state_id = $self->insert_state("complete");

	my $prog_id = $self->get_port_progress($port_id, $command_id, $state_id);

	unless (defined($prog_id)) {
		my $sth = $self->get_dbh->prepare("INSERT INTO port_progress (port_id, command_id, state_id) VALUES (?, ?, ?)");
		$sth->execute($port_id, $command_id, $state_id);
		$self->get_dbh->commit;
		$prog_id = $self->get_port_progress($port_id, $command_id, $state_id);
	}
	return $prog_id;
}

sub get_port_progress {
	my $self = shift;
	my $port_id = shift;
	my $command_id = shift;
	my $state_id = shift;

	my $sth = $self->get_dbh->prepare("SELECT id FROM port_progress WHERE port_id = ? AND command_id = ? AND state_id = ?");
	$sth->execute($port_id, $command_id, $state_id);
	my ($id) = $sth->fetchrow_array;

	return $id;
}

sub insert_port_info_progress {
	my $self = shift;
	my $ip = shift;
	my $port = shift;
	my $trans = shift;
	my $key = shift;
	my $value = shift;
	my $command = shift;
	my $state = shift;

	my $port_info_id = $self->get_port_info_id( ip_address => $ip, port => $port, transport_protocol => $trans, key => $key, value => $value);
	my $command_id = $self->insert_command($command);
	my $state_id = $self->insert_state("complete");

	my $prog_id = $self->get_port_info_progress($port_info_id, $command_id, $state_id);

	unless (defined($prog_id)) {
		my $sth = $self->get_dbh->prepare("INSERT INTO port_info_progress (port_info_id, command_id, state_id) VALUES (?, ?, ?)");
		$sth->execute($port_info_id, $command_id, $state_id);
		$self->get_dbh->commit;
		$prog_id = $self->get_port_info_progress($port_info_id, $command_id, $state_id);
	}
	return $prog_id;
}

sub get_port_info_progress {
	my $self = shift;
	my $port_info_id = shift;
	my $command_id = shift;
	my $state_id = shift;

	my $sth = $self->get_dbh->prepare("SELECT id FROM port_info_progress WHERE port_info_id = ? AND command_id = ? AND state_id = ?");
	$sth->execute($port_info_id, $command_id, $state_id);
	my ($id) = $sth->fetchrow_array;

	return $id;
}

sub insert_host_info_progress {
	my $self = shift;
	my $ip = shift;
	my $key = shift;
	my $value = shift;
	my $command = shift;
	my $state = shift;

	my $host_info_id = $self->get_host_info_id2( ip_address => $ip, key => $key, value => $value);
	my $command_id = $self->insert_command($command);
	my $state_id = $self->insert_state("complete");

	my $prog_id = $self->get_host_info_progress($host_info_id, $command_id, $state_id);

	unless (defined($prog_id)) {
		my $sth = $self->get_dbh->prepare("INSERT INTO host_info_progress (host_info_id, command_id, state_id) VALUES (?, ?, ?)");
		$sth->execute($host_info_id, $command_id, $state_id);
		$self->get_dbh->commit;
		$prog_id = $self->get_host_info_progress($host_info_id, $command_id, $state_id);
	}
	return $prog_id;
}

sub get_host_info_progress {
	my $self = shift;
	my $host_info_id = shift;
	my $command_id = shift;
	my $state_id = shift;

	my $sth = $self->get_dbh->prepare("SELECT id FROM host_info_progress WHERE host_info_id = ? AND command_id = ? AND state_id = ?");
	$sth->execute($host_info_id, $command_id, $state_id);
	my ($id) = $sth->fetchrow_array;

	return $id;
}

sub insert_host_progress {
	my $self = shift;
	my $ip = shift;
	my $command = shift;
	my $state = shift;

	my $host_id = $self->get_id_of_ip( $ip );
	my $command_id = $self->insert_command($command);
	my $state_id = $self->insert_state("complete");

	my $prog_id = $self->get_host_progress($host_id, $command_id, $state_id);

	unless (defined($prog_id)) {
		my $sth = $self->get_dbh->prepare("INSERT INTO host_progress (host_id, command_id, state_id) VALUES (?, ?, ?)");
		$sth->execute($host_id, $command_id, $state_id);
		$self->get_dbh->commit;
		$prog_id = $self->get_host_progress($host_id, $command_id, $state_id);
	}
	return $prog_id;
}

sub get_host_progress {
	my $self = shift;
	my $host_id = shift;
	my $command_id = shift;
	my $state_id = shift;

	my $sth = $self->get_dbh->prepare("SELECT id FROM host_progress WHERE host_id = ? AND command_id = ? AND state_id = ?");
	$sth->execute($host_id, $command_id, $state_id);
	my ($id) = $sth->fetchrow_array;

	return $id;
}

# Record which commands have been run on which hosts
sub set_complete {
	my $self = shift;
	my $type = shift; # ip_with_ports, ip_list, single_port
	if ($type eq "ip_with_ports") {
		my $command = shift;
		my $ip = shift;
		my $ports_href = shift;
		foreach my $port (keys %{$ports_href}) {
			foreach my $trans (keys %{$ports_href->{$port}}) {
				$self->insert_port_progress($ip, $port, $trans, $command, "complete");
			}
		}
		$self->get_dbh->commit;
	} elsif ($type eq "single_port_info") {
		my $command = shift;
		my $ip = shift;
		my $port = shift;
		my $transport_protocol = shift;
		my $key = shift;
		my $value = shift;
		$self->insert_port_info_progress($ip, $port, $transport_protocol, $key, $value, $command, "complete");
	} elsif ($type eq "single_host_info") {
		# TODO is this going to be called with or without a port - or both?
		my $command = shift;
		my $ip = shift;
		my $port = shift;
		my $transport_protocol = shift;
		my $key = shift;
		my $value = shift;
		$self->insert_host_info_progress($ip, $port, $transport_protocol, $key, $value, $command, "complete");
	} elsif ($type eq "credentials") {
		my $command = shift;
		my $opt_href = shift;
		# TODO
		# $self->insert_host_info_progress($ip, $host_info, $command, "complete");
	} elsif ($type eq "hostname") {
		my $command = shift;
		my $opt_href = shift;
		# TODO
	} elsif ($type eq "ip_list") {
		my $command = shift;
		my $ip_file = shift;
		open (IPS, "<$ip_file") or croak "set_complete: Can't open ips file $ip_file";
		while (<IPS>) {
			chomp $_;
			my $ip = $_;
			$self->insert_host_progress($ip, $command, "complete");
		}
		$self->get_dbh->commit;
	} elsif ($type eq "single_port") {
		my $command = shift;
		my $ip = shift;
		my $port = shift;
		my $transport_protocol = shift;
		if (defined($port)) {
			$self->insert_port_progress($ip, $port, $transport_protocol, $command, "complete");
		} else {
			$self->insert_host_progress($ip, $command, "complete");
		}
	} else {
		croak "ERROR: set_complete couldn't determine progress table to use.  type=$type\n";
	}
}

sub get_config {
	my $self = shift;
	my $conf_item = shift;
	unless (defined($self->{config}->{$conf_item})) {
		print "WARNING: Trying to read unset config setting '$conf_item'\n" if $global_debug;
	}

	return $self->{config}->{$conf_item};
}

# IMPORTANT: Don't communicate with the database from this sub
#            You might be a forked process and sharing a db handle
sub run_command_save_output {
	my $self = shift;
	my $command = shift;
	my $output_file = shift;
	my %opts = @_;

	my $max_lines = undef;
	my $timeout = undef;
	my $inactivity_timeout = undef;

	# Process "max_lines" option
	if (defined($opts{max_lines})) {
		unless ($opts{max_lines} >= 0 and $opts{max_lines} < 1000000) {
			croak "ERROR: run_test was passed an invalid max_lines parameter: $opts{max_lines}\n";
		}
		$max_lines = $opts{max_lines};

		# limit of 0 lines mean no limit
		if ($max_lines == 0) {
			$max_lines = undef;
		}
	}

	# Process "timeout" option
	if (defined($opts{timeout})) {
		unless ($opts{timeout} >= 0 and $opts{timeout} < (1 << 31)) {
			croak "ERROR: run_test was passed an invalid timeout parameter: $opts{timeout}\n";
		}
		$timeout = $opts{timeout};
	}

	# Process "inactivity_timeout" option
	if (defined($opts{inactivity_timeout})) {
		unless ($opts{inactivity_timeout} >= 0 and $opts{inactivity_timeout} < (1 << 31)) {
			croak "ERROR: run_test was passed an invalid inactivity_timeout parameter: $opts{inactivity_timeout}\n";
		}
		$inactivity_timeout = $opts{inactivity_timeout};
	}

	if (defined($timeout) and !$timeout) {
		undef $timeout;
	}

	if (defined($inactivity_timeout) and !$inactivity_timeout) {
		undef $inactivity_timeout;
	}

	if (defined($opts{timeout}) and $opts{timeout} and defined($opts{inactivity_timeout}) and $opts{inavticity_timeout}) {
		croak "ERROR: Arguments timeout and inavitivity_timeout can't be used together\n";
	}

	$output_file = _dont_clobber_file($output_file);
	my $pref = "[PID $$] ";
	print "$pref------------------ Yaptest \"run_test\" executing command ... ---------------------\n";
	print "$pref" . "Command ............. $command\n";
	print "$pref" . "Output File ......... $output_file\n";
	if (defined($timeout) and $timeout) {
		print "$pref" . "Timeout ............. $timeout" . ( $timeout == 0 ? ' (Unlimited)' : "" ) . "\n";
	}
	if (defined($inactivity_timeout) and $inactivity_timeout) {
		print "$pref" . "Inactivity Timeout .. $inactivity_timeout" . ( $inactivity_timeout == 0 ? ' (Unlimited)' : "" ) . "\n";
	}
	print "$pref---------------------------------------------------------------------------------\n";

	my $t;
	if (defined($timeout)) {
		$t = $timeout;
	}

	if (defined($inactivity_timeout)) {
		$t = $inactivity_timeout;
	}

	open (OUT, ">>$output_file") or croak "ERROR: Can't write to file $output_file: $!\n";
	my ($pty, $child_pid) = $self->_do_cmd($command);

	eval {
		local $SIG{ALRM} = sub { kill 9, $child_pid; die "$pref" . "Timeout after $t seconds\n" };

		if (defined($timeout)) {
			alarm $timeout;
		}

		if (defined($inactivity_timeout)) {
			alarm $inactivity_timeout;
		}

		my $lines = 0;
		while (<$pty>) {
			$lines++;
			# TODO could put a callback-style parser in here
			print "$pref$_";
			print OUT $_;

			# Check if we've read the maximum number of lines
			if (defined($max_lines) and $lines >= $max_lines) {
				die "$pref" . "Maximum line count reached: $max_lines\n";
			}

			# Keep resetting the alarm everytime we read a line
			if (defined($inactivity_timeout)) {
				alarm ($inactivity_timeout);
			}
		}

		alarm(0);
	};

	$self->log_command($command, "complete");

	if ($@) {
		print "$@\n";
		print OUT "$@\n";
	}										                        

	# TODO kill $child_pid - amap needs to be persuaded to die more quickly.

	# TODO could store the output in the database - good if multiple systems are
	#      doing the test (e.g. a Linux and Windows host)
	# close (CMD);
	close ($pty);
	close (OUT);

	# run a parser on the output if one was passed.
	if (
		defined($opts{parser}) and 
		not (defined($self->get_config('yaptest_auto_parse')) and $self->get_config('yaptest_auto_parse') eq "0") and 
		not (defined('YAPTEST_AUTO_PARSE') and $ENV{'YAPTEST_AUTO_PARSE'} = "0")
	   ) {
		my $ip = $opts{ip};
	   	if (ref($opts{parser}) eq "ARRAY") {
			foreach my $parser (@{$opts{parser}}) {
		   		my $parse_command = $parser;
				$parse_command =~ s/::IP::/$ip/;
				system("$parse_command $output_file");
			}
		} else {
			my $parser = $opts{parser};
	   		my $parse_command = $opts{parser};
			$parse_command =~ s/::IP::/$ip/;
			system("$parse_command $output_file");
		}
	}
	return $output_file;
}

sub _dont_clobber_file {
	my $output_file = shift;
	my $n = 1;
	my $test_output_file = $output_file;
	while (-e $test_output_file) { 
		$test_output_file = "$output_file.$n";
		$n++;
	}
	$output_file = $test_output_file;

	return $output_file;
}

sub get_hash_types {
	my $self = shift;
	my $hash_type = shift;

	my $sth = $self->get_dbh->prepare("select distinct password_hash_type_name from view_credentials where password_hash is not null");
	$sth->execute();

	return map { $_->[0] } @{$sth->fetchall_arrayref};
}

sub get_hash_count {
	my $self = shift;
	my $hash_type = shift;
	croak "get_hash_count: Called without hash_type\n" unless defined($hash_type);

	my $sth = $self->get_dbh->prepare("select count(1) from view_credentials where password_hash_type_name = ? and password_hash is not null");
	$sth->execute($hash_type);

	my ($count) = $sth->fetchrow_array;
	return $count;
}

sub get_cracked_hash_count {
	my $self = shift;
	my $hash_type = shift;

	my $sth = $self->get_dbh->prepare("select count(1) from view_credentials where password_hash_type_name = ? and password_hash is not null and password is not null");
	$sth->execute($hash_type);

	my ($count) = $sth->fetchrow_array;
	return $count;
}

sub get_uncracked_hash_count {
	my $self = shift;
	my $hash_type = shift;

	my $sth = $self->get_dbh->prepare("select count(1) from view_credentials where password_hash_type_name = ? and password_hash is not null and password is null");
	$sth->execute($hash_type);

	my ($count) = $sth->fetchrow_array;
	return $count;
}

sub get_cracked_hash_percentage {
	my $self = shift;
	my $hash_type = shift;
	return sprintf "%.1f",100 * $self->get_cracked_hash_count($hash_type) / $self->get_hash_count($hash_type);
}
	
sub get_uncracked_hash_percentage {
	my $self = shift;
	my $hash_type = shift;
	return sprintf "%.1f",100 * $self->get_uncracked_hash_count($hash_type) / $self->get_hash_count($hash_type);
}

sub DESTROY {
	my $self = shift;
	unless ($is_child) {
		$self->get_dbh->disconnect;
	}
	undef $self;
}

sub destroy {
	my $self = shift;
	unless ($is_child) {
		$self->get_dbh->disconnect;
	}
	undef $self;
}

sub log_command {
	my $self = shift;
	my $command = shift;
	my $status = shift;
	my $status_id = $self->insert_command_status($status);

	my $sth = $self->get_dbh->prepare("INSERT INTO command_log (command, command_status_id) VALUES (?, ?)");
	$sth->execute($command, $status_id);
	$self->get_dbh->commit;
}

sub insert_command_status {
	my $self = shift;
	my $status = shift;

	my $status_id = $self->get_command_status_id($status);

	unless (defined($status_id)) {
		my $sth = $self->get_dbh->prepare("INSERT INTO command_status (name) VALUES (?)");
		$sth->execute($status);
		$self->get_dbh->commit;
		$status_id = $self->get_command_status_id($status);
	}
	return $status_id;
}

sub get_command_status_id {
	my $self = shift;
	my $status = shift;

	my $sth = $self->get_dbh->prepare("SELECT id FROM command_status WHERE name = ?");
	$sth->execute($status);
	my ($id) = $sth->fetchrow_array;

	return $id;
}

# From Network Programming with PERL
# http://www.modperl.com/perl_networking/sample/ch6.html
# IMPORTANT: Don't communicate with the database from this sub
#            You might be a forked process and sharing a db handle
sub _do_cmd {
	my ($self, $cmd, @args) = @_;
	$self->log_command($cmd . join(" ", @args), "started");
	# print "[+] Running command: $cmd\n" unless $quiet;
	my $pty = IO::Pty->new or die "can't make Pty: $!";
	defined (my $child = fork) or die "Can't fork: $!";
	if ($child) {
		$pty->close_slave();
		return ($pty, $child);
	}
	
	POSIX::setsid();
	my $tty = $pty->slave;
	$pty->make_slave_controlling_terminal();
	close $pty;
	
	STDIN->fdopen($tty,"<")      or die "STDIN: $!";
	STDOUT->fdopen($tty,">")     or die "STDOUT: $!";
	STDERR->fdopen(\*STDOUT,">") or die "STDERR: $!";
	close $tty;
	$| = 1;
	exec $cmd,@args;
	die "ERROR: Is command in your path?: $!";
}

sub insert_hostname {
	my $self = shift;
	my %opts = @_;

	my $name_type_id = $self->insert_hostname_type($opts{type});
	my $name = $opts{hostname};
	my $host_id = $self->get_id_of_ip($opts{ip_address});

	unless (defined($host_id)) {
		carp "insert_hostname: Called with IP that isn't being scanned: " . $opts{ip_address} . "\n";
		return 0;
	}

	my $id = $self->get_hostname_id(type_id => $name_type_id, hostname=> $name, host_id => $host_id);
	unless (defined($id)) {
		my $sth = $self->get_dbh->prepare("INSERT INTO hostnames (name_type, name, host_id) VALUES (?, ?, ?)");
		$sth->execute($name_type_id, $name, $host_id);
		$id = $self->get_hostname_id(type_id => $name_type_id, hostname=> $name);
	}

	return $id;
}

sub insert_hostname_type {
	my $self = shift;
	my $type = shift;

	my $id = $self->get_hostname_type_id($type);
	unless (defined($id)) {
		my $sth = $self->get_dbh->prepare("INSERT INTO hostname_types (name_type) VALUES (?)");
		$sth->execute($type);
		$id = $self->get_hostname_type_id($type);
	}

	return $id;
}

sub get_hostname_type_id {
	my $self = shift;
	my $type = shift;

	my $sth = $self->get_dbh->prepare("SELECT id FROM hostname_types WHERE name_type = ?");
	$sth->execute($type);
	my ($id) = $sth->fetchrow_array;
	return $id;
}

sub get_hostname_id {
	# TODO dynamically build query based on which opts are passed
	my $self = shift;
	my %opts = @_;

	my $sth = $self->get_dbh->prepare("SELECT id FROM hostnames WHERE name = ? AND name_type = ? AND host_id = ?");
	$sth->execute($opts{hostname}, $opts{type_id}, $opts{host_id});
	my $id = $sth->fetchrow_array;
	return $id;
}

sub insert_host_info {
	my $self = shift;
	my %opts = @_;

	my $ip = $opts{ip_address};
	my $host_id = $self->get_id_of_ip($ip);
	unless (defined($host_id)) {
		carp "insert_host_info: Called with IP that isn't being scanned: " . $opts{ip_address} . "\n";
		return 0;
	}

	my $key = $opts{key};
	my $key_id = $self->insert_host_key($key);
	my $value = $opts{value};

	my $id = $self->get_host_info_id($host_id, $key_id);
	if (defined($id)) {
		my $sth = $self->get_dbh->prepare("UPDATE host_info SET value = ? WHERE host_id = ? AND host_key_id = ?");
		$sth->execute($value, $host_id, $key_id);
	} else {
		my $sth = $self->get_dbh->prepare("INSERT INTO host_info (host_id, host_key_id, value) VALUES (?, ?, ?)");
		$sth->execute($host_id, $key_id, $value);
	}

	$id = $self->get_host_info_id($host_id, $key_id);
	return $id;
}

sub get_host_info_id {
	my $self = shift;
	my $host_id = shift;
	my $key_id = shift;

	my $sth = $self->get_dbh->prepare("SELECT id FROM host_info WHERE host_id = ? AND host_key_id = ?");
	$sth->execute($host_id, $key_id);

	my ($id) = $sth->fetchrow_array;
	return $id;
}

sub get_id_of_host_key {
	my $self = shift;
	my $key = shift;

	my $sth = $self->get_dbh->prepare("SELECT id FROM host_keys WHERE name = ?");
	$sth->execute($key);
	my ($id) = $sth->fetchrow_array;

	return $id;
}

sub insert_host_key {
	my $self = shift;
	my $key = shift;
	print "insert_host_key called with key $key\n" if $global_debug;

	$self->_lock_host_key();
	my $id = $self->get_id_of_host_key($key);

	if (defined($id)) {
		$self->_unlock_host_key();
		return $id;
	} else {
		my $sth = $self->get_dbh->prepare("INSERT INTO host_keys (name) VALUES (?)");
		$sth->execute($key);
	
		$self->_unlock_host_key();
		return $self->get_id_of_host_key($key);
	}
}

sub get_issue_host_id {
	my $self = shift;
	my $issue_id = shift;
	my $host_id = shift;
	my $sth = $self->get_dbh->prepare("SELECT id FROM issues_to_hosts WHERE issue_id = ? AND host_id = ?");
	$sth->execute($issue_id, $host_id);
	my ($id) = $sth->fetchrow_array;
	return $id;
}

sub get_issue_port_id {
	my $self = shift;
	my $issue_id = shift;
	my $port_id = shift;
	my $sth = $self->get_dbh->prepare("SELECT id FROM issues_to_ports WHERE issue_id = ? AND port_id = ?");
	$sth->execute($issue_id, $port_id);
	my ($id) = $sth->fetchrow_array;
	return $id;
}

sub get_issue_id {
	my $self = shift;
	my $shortname = shift;
	my $sth = $self->get_dbh->prepare("SELECT id FROM issues WHERE shortname = ?");
	$sth->execute($shortname);
	my ($id) = $sth->fetchrow_array;
	return $id;
}

# $y->insert_issue(name => sql_slammer, ip_address => 1.2.3.4, port => 1434, transport_protocol => UDP)
# $y->insert_issue(name => dcom, ip_address => 1.2.3.4)
# $y->insert_issue(name => double_decode, ip_address => 1.2.3.4, port => 80, transport_protocol => TCP)
# TODO: support description, rating and source fields in issues table.
sub insert_issue {
	my $self = shift;
	my %opts = @_;

	my $ip = $opts{ip_address};
	my $host_id = $self->get_id_of_ip($ip);
	unless (defined($host_id)) {
		carp "insert_issue: Called with IP that isn't being scanned: " . $opts{ip_address} . "\n";
		return 0;
	}

	my $issue_name = $opts{name};
	my $transport_protocol = uc $opts{transport_protocol};
	my $port = $opts{port};

	# Check if issue is already present, insert if not
	my $issue_id = $self->get_issue_id($issue_name);
	unless (defined($issue_id)) {
		my $sth = $self->get_dbh->prepare("INSERT INTO issues (shortname) VALUES (?)");
		$sth->execute($issue_name);
		$issue_id = $self->get_issue_id($issue_name);
	}
	
	# Correlate issue is host / port as appropriate
	if (defined($port)) {
		my $port_id = $self->insert_port(ip => $ip, port => $port, transport_protocol => $transport_protocol);

		my $id = $self->get_issue_port_id($issue_id, $port_id);
		unless (defined($id)) {
			my $sth = $self->get_dbh->prepare("INSERT INTO issues_to_ports (issue_id, port_id) VALUES (?, ?)");
			$sth->execute($issue_id, $port_id);
			$id = $self->get_issue_port_id($issue_id, $port_id);
		}
		return $id;
	} else {
		my $id = $self->get_issue_host_id($issue_id, $host_id);
		unless (defined($id)) {
			my $sth = $self->get_dbh->prepare("INSERT INTO issues_to_hosts (issue_id, host_id) VALUES (?, ?)");
			$sth->execute($issue_id, $host_id);
			$id = $self->get_issue_host_id($issue_id, $host_id);
		}
		return $id;
	}
}

sub del_dbh {
	my $self = shift;
	$self->{dbh} = 0;
}

sub get_dbh {
	my $self = shift;
	unless (defined($self->{dbh}) and $self->{dbh}) {
		$self->_connect;
	}
	return $self->{dbh};
}

sub check_exploit_ok {
	my $self = shift;
	my $run = $self->get_config('exploit_ok');
	unless (defined($run) and $run eq 'yes') {
	        print "ERROR: You have not enabled exploitation for this test\n";
	        print "       Use yaptest-config.pl to set exploit_ok to 'yes'\n";
	        print "       if you want yaptest to automatically exploit targets\n";
		exit 1;
	}
}

sub check_unsafe_ok {
	my $self = shift;
	my $run = $self->get_config('unsafe_ok');
	unless (defined($run) and $run eq 'yes') {
	        print "ERROR: You have not enabled unsafe checks/exploits for this test\n";
	        print "       Use yaptest-config.pl to set unsafe_ok to 'yes'\n";
	        print "       if you want yaptest to automatically run unsafe checks/exploits\n";
		exit 1;
	}
}

sub check_root {
	unless (geteuid == 0) {
		print "ERROR: You need to root to run this\n";
		exit 1;
	}

}

1;
