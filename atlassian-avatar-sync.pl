=head1 NAME

atlassian-avatar-sync.pl - copies avatar pictures from JIRA to Confluence or
Bitbucket

=head1 SYSNOPSIS

    perl atlassian-avatar-sync.pl [OPTION] ... URL_CONFLUENCE URL_JIRA [TARGET_USER] ...
    perl atlassian-avatar-sync.pl --bitbucket [OPTION] ... URL_BITBUCKET URL_JIRA [TARGET_USER] ...

=head1 DESCRIPTION

This script copies avatar pictures of user TARGET_USER from URL_JRIA to
URL_CONFLUENCE or URL_BITBUCKET.

If TARGET_USER is not specified, all avatar pictures are copied.

=head1 OPTIONS

=over 4

=item -u USER, --user=UESR

Use USER for authentication of Confluence or Bitbucket.

=item -p PASSWORD, --passowrd=PASSWORD

Use PASSWORD for authentication of Confluence or Bitbucket.

=item -U USER, --jira-user=UESR

Use USER for authentication of JIRA.

=item -P PASSWORD, --jira-passowrd=PASSWORD

Use PASSWORD for authentication of JIRA.

=item -f, --force

Overwrite avatar.

=item -l FILE, --log=FILE

Write log to FILE.

=item --verbose

Print verbosely.

=item --help

Print this help.

=back

=head1 AUTHOR

Takeshi Nakamura <taqueci.n@gmail.com>

=head1 COPYRIGHT

Copyright (C) 2018 Takeshi Nakamura. All Rights Reserved.

=cut

use strict;
use warnings;

use utf8;

use Digest::MD5 qw(md5_hex);
use Getopt::Long qw(:config no_ignore_case no_auto_abbrev gnu_compat);
use HTTP::Request;
use LWP::UserAgent;
use Pod::Usage;
use Term::ReadKey;

PLib::import();

_main(@ARGV) or exit 1;

exit 0;


sub _main {
	local @ARGV = @_;

	my %opt;
	GetOptions(\%opt, '--bitbucket|b', 'force|f', 'user|u=s', 'password|p=s',
			   'jira-user|U=s', 'jira-password|P=s',
			   'log|l=s', 'verbose', 'help') or return 0;

	p_set_log($opt{log}) if defined $opt{log};
	p_set_verbose(1) if $opt{verbose};

	pod2usage(-exitval => 0, -verbose => 2, -noperldoc => 1) if $opt{help};

	unless (@ARGV > 1) {
		p_error("Too few arguments");
		return 0;
	}

	my ($url_to, $url_from, @target) = @ARGV;

	my $to = $opt{bitbucket} ? 'Bitbucket' : 'Confluence';

	print "Authentication for $to $url_to\n" unless $opt{user} &&
		$opt{password};
	my $user = $opt{user} // _read_key("User: ");
	my $passwd = $opt{password} // _read_key("Password: ", 1);

	print "Authentication for JIRA $url_from\n" unless $opt{'jira-user'} &&
		$opt{'jira-password'};
	my $user_from = $opt{'jira-user'} // _read_key("User: ");
	my $passwd_from = $opt{'jira-password'} // _read_key("Password: ", 1);

	my $appl_from = Jira->new($url_from, $user_from, $passwd_from);

	my $appl_to = $opt{bitbucket} ?
		Bitbucket->new($url_to, $user, $passwd) :
		Confluence->new($url_to, $user, $passwd);

	unless (@target > 0) {
		p_verbose("Reading user information from $url_to");
		my $users = $appl_to->all_users or return 0;
		@target = @$users;
	}

	p_verbose("Synchronizing avatars");
	_sync_avatars(\@target, $appl_to, $appl_from, $opt{force}) or return 0;

	p_verbose("Completed!\n");

	return 1;
}

sub _read_key {
	my ($msg, $noecho) = @_;

	print $msg;

	ReadMode 'noecho' if $noecho;
	my $val = ReadLine 0;
	ReadMode 'restore' if $noecho;
	print "\n" if $noecho;

	chomp $val;

	return $val;
}

sub _sync_avatars {
	my ($target, $appl_to, $appl_from, $force) = @_;
	my $name_to = ref $appl_to;
	my $nerr = 0;

	foreach my $x (@$target) {
		p_verbose("Synchronizing avatar picture of user '$x'");

		p_verbose("Getting avatar from JIRA");
		my $avtr_from = $appl_from->avatar($x);

		unless ($avtr_from) {
			$nerr++;
			next;
		}

		if ($avtr_from->is_default) {
			p_warning("Avatar for user '$x' is not updated because no new one has been uploaded");
			next;
		}

		my $t = $avtr_from->type;

		unless (($t eq 'image/png') || ($t eq 'image/jpeg') ||
				($t eq 'image/gif')) {
			p_warning("Avatar for user '$x' is not updated because image type '$t' is not supported");
			next;
		}

		p_verbose("Getting existing avatar from $name_to");
		my $avtr_to = $appl_to->avatar($x);

		unless ($avtr_to) {
			$nerr++;
			next;
		}

		if ($avtr_from->is_equal($avtr_to) ||
			(!$force && !$avtr_to->is_default)) {
			p_warning("Avatar for user '$x' has already been updated");
			next;
		}

		p_verbose("Setting avatar of $name_to");
		$avtr_to->set_data($avtr_from->type, $avtr_from->data,
						   $avtr_from->path);

		$avtr_to->push or $nerr++;
	}

	return $nerr == 0;
}

# JIRA
package Jira;

INIT { PLib::import() }

sub new {
	my ($class, $url, $user, $passwd) = @_;
	my $self = {url => $url, user => $user, password => $passwd};

	return bless $self, $class;
}

sub avatar {
	my ($self, $id) = @_;

	my $avatar = Avatar::Jira->new($self->{url}, $self->{user},
								   $self->{password}, $id);

	return $avatar->pull ? $avatar : undef;
}

# Confluence
package Confluence;

use JSON;

INIT { PLib::import() }

sub new {
	my ($class, $url, $user, $passwd) = @_;
	my $self = {url => $url, user => $user, password => $passwd};

	return bless $self, $class;
}

sub all_users {
	my $self = shift;
	my $url = $self->{url};

	my $u = "$url/rpc/json-rpc/confluenceservice-v2/getActiveUsers";
	my $req = HTTP::Request->new(POST => $u);

	$req->authorization_basic($self->{user}, $self->{password});
	$req->content_type('application/json');
	$req->content(encode_json([JSON::true]));

	my $ua = LWP::UserAgent->new;
	my $r = $ua->request($req);

	unless ($r->is_success) {
		p_error("Failed to get all users from $url");
		p_log($r->status_line);
		return undef;
	}

	my $c = decode_json($r->content);

	unless (ref($c) eq 'ARRAY') {
		p_error("Failed to get all users from $url");
		p_log($c->{error}->{message});
		return undef;
	}

	return $c;
}

sub avatar {
	my ($self, $id) = @_;

	my $avatar = Avatar::Confluence->new($self->{url}, $self->{user},
										 $self->{password}, $id);

	return $avatar->pull ? $avatar : undef;
}

# Bitbucket
package Bitbucket;

use JSON;

INIT { PLib::import() }

sub new {
	my ($class, $url, $user, $passwd) = @_;
	my $self = {url => $url, user => $user, password => $passwd};

	return bless $self, $class;
}

sub all_users {
	my $self = shift;
	my $url = $self->{url};

	my $start = 0;
	my @users;

	my $ua = LWP::UserAgent->new;

	while (1) {
		my $u = "$url/rest/api/1.0/users?start=$start";
		my $req = HTTP::Request->new(GET => $u);

		$req->authorization_basic($self->{user}, $self->{password});
		$req->content_type('application/json');

		my $r = $ua->request($req);

		unless ($r->is_success) {
			p_error("Failed to get all users from $url");
			p_log($r->status_line);
			return undef;
		}

		my $c = decode_json($r->content);

		push @users, map {$_->{name}} @{$c->{values}};

		last if $c->{isLastPage};

		$start = $c->{nextPageStart};
	}

	return \@users;
}

sub avatar {
	my ($self, $id) = @_;

	my $avatar = Avatar::Bitbucket->new($self->{url}, $self->{user},
										$self->{password}, $id);

	return $avatar->pull ? $avatar : undef;
}

# JIRA avatar
package Avatar::Jira;

use Digest::MD5 qw(md5_hex);
use File::Basename;
use JSON;

INIT { PLib::import() }

sub new {
	my ($class, $url, $user, $passwd, $id) = @_;
	my $self = {url => $url, user => $user, password => $passwd, id => $id};

	return bless $self, $class;
}

sub pull {
	my $self = shift;

	my $path = $self->_path($self->{id}) or return 0;

	return $self->_get($path);
}

sub _path {
	my ($self, $id) = @_;
	my $url = $self->{url};

	my $u = "$url/rest/api/2/user?username=$id";
	my $req = HTTP::Request->new(GET => $u);

	$req->authorization_basic($self->{user}, $self->{password});

	my $ua = LWP::UserAgent->new;
	my $r = $ua->request($req);

	unless ($r->is_success) {
		p_error("Failed to get avatar URL for user '$id'");
		p_log($r->status_line);
		return undef;
	}
	
	return decode_json($r->content)->{avatarUrls}->{'48x48'};
}

sub _get {
	my ($self, $path) = @_;

	my $req = HTTP::Request->new(GET => $path);

	$req->authorization_basic($self->{user}, $self->{password});

	my $ua = LWP::UserAgent->new;
	my $r = $ua->request($req);

	unless ($r->is_success) {
		p_error("Failed to download avatar picture from $path");
		p_log($r->status_line);
		return 0;
	}

	my $t = $r->content_type;
	my $c = $r->content;

	$self->{type} = $t;
	$self->{data} = $c;
	$self->{path} = $path;

	return 1;
}

sub type {
	return shift->{type};
}

sub data {
	return shift->{data};
}

sub path {
	return shift->{path};
}

sub is_default {
	my $DEFAULT_AVATAR_ID = 10122;

	return shift->{path} =~ /avatarId=$DEFAULT_AVATAR_ID/;
}

sub is_equal {
	my ($self, $avatar) = @_;

	my $t = ref $avatar;

	if ($t eq 'Avatar::Confluence') {
		return md5_hex($self->{path}) eq basename($avatar->path);
	} elsif ($t eq 'Avatar::Bitbucket') {
		return md5_hex($self->{data}) eq md5_hex($avatar->data);
	} else {
		return 0;
	}
}

# Confluence avatar
package Avatar::Confluence;

use Digest::MD5 qw(md5_hex);
use File::Basename;
use JSON;

INIT { PLib::import() }

sub new {
	my ($class, $url, $user, $passwd, $id) = @_;
	my $self = {url => $url, user => $user, password => $passwd, id => $id};

	return bless $self, $class;
}

sub pull {
	my $self = shift;

	my $id = $self->{id};
	my $url = $self->{url};

	my $u = "$url/rest/api/user?username=$id";
	my $req = HTTP::Request->new(GET => $u);

	$req->authorization_basic($self->{user}, $self->{password});

	my $ua = LWP::UserAgent->new;
	my $r = $ua->request($req);

	unless ($r->is_success) {
		p_error("Failed to get information of user '$id'");
		p_log($r->status_line);
		return 0;
	}
	
	my $t = $r->content_type;
	my $c = $r->content;

	$self->{type} = $t;
	$self->{data} = $c;
	$self->{path} = decode_json($r->content)->{profilePicture}->{path};

	return 1;
}

sub push {
	my $self = shift;

	my $url = $self->{url};
	my $id = $self->{id};

	my $u = "$url/rpc/json-rpc/confluenceservice-v2/addProfilePicture";
	my $req = HTTP::Request->new(POST => $u);

	my $name = defined($self->{path}) ?
		basename($self->{path}) : md5_hex($self->{origin});

	my @d = unpack 'C*', $self->{data};

	$req->authorization_basic($self->{user}, $self->{password});
	$req->content_type('application/json');
	$req->content(encode_json([$id, $name, $self->{type}, \@d]));

	my $ua = LWP::UserAgent->new;
	my $r = $ua->request($req);

	unless ($r->is_success) {
		p_error("Failed to update avatar of user '$id'");
		p_log($r->status_line);
		return 0;
	}

	return 1;
}

sub data {
	return shift->{data};
}

sub set_data {
	my ($self, $type, $data, $origin) = @_;

	$self->{type} = $type;
	$self->{data} = $data;
	$self->{path} = undef;
	$self->{origin} = $origin;
}

sub path {
	return shift->{path};
}

sub is_default {
	my $path = shift->{path};
	my $DEFAULT_AVATAR_FILE = 'default.png';

	return defined($path) ? (basename($path) eq $DEFAULT_AVATAR_FILE) : 0;
}

# Bitbucket avatar
package Avatar::Bitbucket;

use Digest::MD5 qw(md5_hex);
use HTTP::Request::Common;
use JSON;

INIT { PLib::import() }

sub new {
	my ($class, $url, $user, $passwd, $id) = @_;
	my $self = {url => $url, user => $user, password => $passwd, id => $id};

	return bless $self, $class;
}

sub pull {
	my $self = shift;

	my $id = $self->{id};
	my $url = $self->{url};

	my $u = "$url/users/$id/avatar.png";
	my $req = HTTP::Request->new(GET => $u);

	$req->authorization_basic($self->{user}, $self->{password});

	my $ua = LWP::UserAgent->new;
	my $r = $ua->request($req);

	unless ($r->is_success) {
		p_error("Failed to download avatar picture from $url");
		p_log($r->status_line);
		return 0;
	}

	my $t = $r->content_type;
	my $c = $r->content;

	$self->{type} = $t;
	$self->{data} = $c;

	return 1;
}

sub push {
	my $self = shift;

	my $url = $self->{url};
	my $id = $self->{id};

	my $u = "$url/rest/api/1.0/users/$id/avatar.png";
	my $req = POST $u, Content_Type => 'multipart/form-data',
		Content => [avatar => $self->{data}];

	$req->authorization_basic($self->{user}, $self->{password});
	$req->header('X-Atlassian-Token' => 'no-check');

	my $ua = LWP::UserAgent->new;
	my $r = $ua->request($req);

	unless ($r->is_success) {
		p_error("Failed to update avatar of user '$id'");
		p_log($r->status_line);
		return 0;
	}

	return 1;
}

sub data {
	return shift->{data};
}

sub set_data {
	my ($self, $type, $data, $origin) = @_;

	$self->{type} = $type;
	$self->{data} = $data;
	$self->{path} = undef;
	$self->{origin} = $origin;
}

sub path {
	return undef;
}

sub is_default {
	my $DEFAULT_AVATAR_MD5 = 'b1c94647deb67e378c7d72e6a467c2b5';

	return md5_hex(shift->{data}) eq $DEFAULT_AVATAR_MD5;
}

# Library
package PLib;

use Carp;
use Encode;

my $p_message_prefix;
my $p_log_file;
my $p_is_verbose;
my $p_encoding;

INIT {
	$p_message_prefix = "";
	$p_is_verbose = 0;
	$p_encoding = 'utf-8';
}

sub import {
	my @EXPORT = qw(p_message p_warning p_error p_verbose p_log
					p_set_encoding p_set_message_prefix p_set_log
					p_set_verbose p_exit p_error_exit p_slurp);

	my $caller = caller;

	no strict 'refs';
	foreach my $func (@EXPORT) {
		*{"${caller}::$func"} = \&{"PLib::$func"};
	}
}

sub p_decode {
	return decode($p_encoding, shift);
}

sub p_encode {
	return encode($p_encoding, shift);
}

sub p_message {
	my @msg = ($p_message_prefix, @_);

	print STDERR map {p_encode($_)} @msg, "\n";
	p_log(@msg);
}

sub p_warning {
	my @msg = ("*** WARNING ***: ", $p_message_prefix, @_);

	print STDERR map {p_encode($_)} @msg, "\n";
	p_log(@msg);
}

sub p_error {
	my @msg = ("*** ERROR ***: ", $p_message_prefix, @_);

	print STDERR map {p_encode($_)} @msg, "\n";
	p_log(@msg);
}

sub p_verbose {
	my @msg = @_;

	print STDERR map {p_encode($_)} @msg, "\n" if $p_is_verbose;
	p_log(@msg);
}

sub p_log {
	my @msg = @_;

	return unless defined $p_log_file;

	open my $fh, '>>', $p_log_file or die "$p_log_file: $!\n";
	print $fh map {p_encode($_)} @msg, "\n";
	close $fh;
}

sub p_set_encoding {
	$p_encoding = shift;
}

sub p_set_message_prefix {
	my $prefix = shift;

	defined $prefix or croak 'Invalid argument';

	$p_message_prefix = $prefix;
}

sub p_set_log {
	my $file = shift;

	defined $file or croak 'Invalid argument';

	$p_log_file = $file;
}

sub p_set_verbose {
	$p_is_verbose = (!defined($_[0]) || ($_[0] != 0));
}

sub p_exit {
	my ($val, @msg) = @_;

	print STDERR map {p_encode($_)} @msg, "\n";
	p_log(@msg);

	exit $val;
}

sub p_error_exit {
	my ($val, @msg) = @_;

	p_error(@msg);

	exit $val;
}

sub p_slurp {
	my ($file, $encoding) = @_;
	my $fh;

	$encoding //= $p_encoding;

	unless (open $fh, $file) {
		p_error("$file: $!");
		return undef;
	}

	local $/ = undef;

	my $content = <$fh>;

	close $fh;

	return decode $encoding, $content;
}
