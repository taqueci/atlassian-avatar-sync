=head1 NAME

confluence-avatar-sync.pl - copies avatar pictures from JIRA to Confluence

=head1 SYSNOPSIS

    perl confluence-avatar-sync.pl [OPTION] ... URL_CONFLUENCE URL_JIRA [TARGET_USER] ...

=head1 DESCRIPTION

This script copies avatar pictures of user TARGET_USER from URL_JRIA to
URL_CONFLUENCE.

If TARGET_USER is not specified, all avatar pictures are copied.

=head1 OPTIONS

=over 4

=item -u USER, --user=UESR

Use USER for authentication of Confluence.

=item -p PASSWORD, --passowrd=PASSWORD

Use PASSWORD for authentication of Confluence.

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
use File::Basename;
use Getopt::Long qw(:config no_ignore_case no_auto_abbrev gnu_compat);
use HTTP::Request;
use JSON;
use LWP::UserAgent;
use Pod::Usage;
use Term::ReadKey;

my $DEFAULT_AVATAR_ID = 10122;
my $DEFAULT_AVATAR_FILE = 'default.png';

my $p_message_prefix = "";
my $p_log_file;
my $p_is_verbose = 0;
my $p_encoding = 'utf-8';

_main(@ARGV) or exit 1;

exit 0;


sub _main {
	local @ARGV = @_;

	my %opt;
	GetOptions(\%opt, 'force|f', 'user|u=s', 'password|p=s',
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

	print "Authentication for Confluence $url_to\n" unless $opt{user} &&
		$opt{password};
	my $user = $opt{user} // _read_key("User: ");
	my $passwd = $opt{password} // _read_key("Password: ", 1);

	print "Authentication for JIRA $url_from\n" unless $opt{'jira-user'} &&
		$opt{'jira-password'};
	my $user_from = $opt{'jira-user'} // _read_key("User: ");
	my $passwd_from = $opt{'jira-password'} // _read_key("Password: ", 1);

	unless (@target > 0) {
		p_verbose("Reading user information from $url_to");
		my $users = _all_users($url_to, $user, $passwd) or return 0;

		@target = @$users;
	}

	p_verbose("Synchronizing avatars");
	_sync_avatars(\@target, $url_to, $user, $passwd,
				  $url_from, $user_from, $passwd_from,
				  $opt{force}) or return 0;

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

sub _all_users {
	my ($url, $user, $passwd) = @_;

	my $u = "$url/rpc/json-rpc/confluenceservice-v2/getActiveUsers";
	my $req = HTTP::Request->new(POST => $u);

	$req->authorization_basic($user, $passwd);
	$req->content_type('application/json');
	$req->content(encode_json([JSON::true]));

	my $ua = LWP::UserAgent->new;
	my $r = $ua->request($req);

	p_log($r->content);

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

sub _sync_avatars {
	my ($target, $url_to, $user_to, $passwd_to,
		$url_from, $user_from, $passwd_from, $force) = @_;
	my $nerr = 0;

	foreach my $x (@$target) {
		p_verbose("Synchronizing avatar picture of user '$x'");

		p_verbose("Getting URL of avatar picture from JIRA");
		my $avatar = _avatar_url($url_from, $user_from, $passwd_from, $x);

		unless ($avatar) {
			$nerr++;
			next;
		}

		if ($avatar =~ /avatarId=$DEFAULT_AVATAR_ID/) {
			p_warning("Avatar for user '$x' is not updated because no new one has been uploaded");
			next;
		}

		p_verbose("Checking existing avatar in Confluence");
		my $fn = _avatar_file_name($avatar);
		my $efn = _existing_file_name($url_to, $user_to, $passwd_to, $x);

		unless ($efn) {
			$nerr++;
			next;
		}

		if (($efn eq $fn) || ((!$force) && ($efn ne $DEFAULT_AVATAR_FILE))) {
			p_warning("Avatar for user '$x' has already been updated");
			next;
		}

		p_verbose("Downloading avatar picture from $avatar");
		my $data = _get_avatar($avatar, $user_from, $passwd_from);

		unless ($data) {
			$nerr++;
			next;
		}

		my $t = $data->{type};

		unless (($t eq 'image/png') || ($t eq 'image/jpeg') ||
				($t eq 'image/gif')) {
			p_warning("Avatar for user '$x' is not updated because image type '$t' is not supported");
			next;
		}

		p_verbose("Setting Confluence avatar");
		_set_avatar($url_to, $user_to, $passwd_to, $x, $fn, $t,
					$data->{content}) or $nerr++;
	}

	return $nerr == 0;
}

sub _avatar_url {
	my ($url, $user, $passwd, $target) = @_;

	my $u = "$url/rest/api/2/user?username=$target";
	my $req = HTTP::Request->new(GET => $u);

	$req->authorization_basic($user, $passwd);

	my $ua = LWP::UserAgent->new;
	my $r = $ua->request($req);

	unless ($r->is_success) {
		p_error("Failed to get avatar URL for user '$target'");
		p_log($r->status_line);
		return 0;
	}
	
	return decode_json($r->content)->{avatarUrls}->{'48x48'};
}

sub _existing_file_name {
	my ($url, $user, $passwd, $target) = @_;

	my $u = "$url/rest/api/user?username=$target";
	my $req = HTTP::Request->new(GET => $u);

	$req->authorization_basic($user, $passwd);

	my $ua = LWP::UserAgent->new;
	my $r = $ua->request($req);

	unless ($r->is_success) {
		p_error("Failed to get information of user '$target'");
		p_log($r->status_line);
		return 0;
	}
	
	return basename decode_json($r->content)->{profilePicture}->{path};
}

sub _get_avatar {
	my ($url, $user, $passwd) = @_;

	my $req = HTTP::Request->new(GET => $url);

	$req->authorization_basic($user, $passwd);

	my $ua = LWP::UserAgent->new;
	my $r = $ua->request($req);

	unless ($r->is_success) {
		p_error("Failed to download avatar picture from $url");
		p_log($r->status_line);
		return undef;
	}

	my $m = $r->content_type;
	my $c = $r->content;

	return {type => $m, content => $c};
}

sub _set_avatar {
	my ($url, $user, $passwd, $target, $name, $type, $data) = @_;

	my $u = "$url/rpc/json-rpc/confluenceservice-v2/addProfilePicture";
	my $req = HTTP::Request->new(POST => $u);

	my @d = unpack 'C*', $data;

	$req->authorization_basic($user, $passwd);
	$req->content_type('application/json');
	$req->content(encode_json([$target, $name, $type, \@d]));

	my $ua = LWP::UserAgent->new;
	my $r = $ua->request($req);

	unless ($r->is_success) {
		p_error("Failed to update avatar of user '$target'");
		p_log($r->status_line);
		return 0;
	}

	return 1;
}

sub _avatar_file_name {
	return md5_hex shift;
}

use Carp;
use Encode;

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
