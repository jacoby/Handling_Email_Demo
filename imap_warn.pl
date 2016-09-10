#!/home/jacoby/perl5/perlbrew/perls/perl-5.20.2/bin/perl

# specialized version of imap_task that handles just warnings. 
# problem with previous attempts is that it kept warning about
# new mail that matched until it was marked it read or deleted

# the goal is to do things once, with a data store independent 
# from IMAP that indicates if the warning has been sent. 

# YAML? JSON? Mongo? We'll try YAML.

use feature qw'say state' ;
use strict ;
use utf8 ;
use warnings ;
use utf8 ;

use Carp ;
use DateTime ;
use DateTime::Duration ;
use DateTime::Format::DateParse ;
use Getopt::Long ;
use IO::Interactive qw{interactive} ;
use IO::Socket::SSL ;
use Mail::IMAPClient ;
use YAML::XS qw{ LoadFile DumpFile } ;

use lib '/home/jacoby/lib' ;
use Locked ;
use Notify qw{ notify } ;
use Pushover ;
use Say qw{ say_message } ;

my @sender ;
my $debug = 0 ;
my $task ;
$task = 'work_alert' ;

GetOptions(
    'debug=i' => \$debug,
    # 'task=s'  => \$task,
    )
    or exit(1) ;

my $config_file = $ENV{HOME} . '/.imap/' . $task . '.yml' ;
croak 'No task set'  if length $task < 1 ;
croak 'No task file' if !-f $config_file ;

my $settings = LoadFile($config_file) ;
$settings->{debug} = $debug ;
$settings->{message} = $settings->{message} ? $settings->{message} : 'You have mail' ;

my $has_spoken = 0 ;

say {interactive} '='x20;
my $warn_file   = $ENV{HOME} . '/.imap_warn.yml' ;
my $warnings = LoadFile($warn_file) ;
check_imap($settings) ;
DumpFile( $warn_file , $warnings ) ;
say {interactive} '-'x20;
exit ;

sub check_imap {
    my $settings = shift ;
    my $client ;
    if ( $settings->{port} == 993 ) {

        my $socket = IO::Socket::SSL->new(
            PeerAddr => $settings->{server},
            PeerPort => $settings->{port},
            )
            or die "socket(): $@" ;

        $client = Mail::IMAPClient->new(
            Socket   => $socket,
            User     => $settings->{username},
            Password => $settings->{password},
            )
            or die "new(): $@" ;
        }
    elsif ( $settings->{port} == 587 ) {
        $client = Mail::IMAPClient->new(
            Server   => $settings->{server},
            User     => $settings->{username},
            Password => $settings->{password},
            )
            or die "new(): $@" ;
        }

    my $dispatch ;
    $dispatch->{'alert'}          = \&alert_and_store_mail ;
    # $dispatch->{'alert'}          = \&alert_mail ;
    # $dispatch->{'delete'}         = \&delete_mail ;
    # $dispatch->{'delete_day_old'} = \&delete_day_old_mail ;
    # $dispatch->{'delete_old'}     = \&delete_old_mail ;
    # $dispatch->{'markread'}       = \&markread_mail ;
    # $dispatch->{'speak'}          = \&speak_mail ;
    $dispatch->{'warn'}           = \&warn_mail ;


    if ( $client->IsAuthenticated() ) {
        say {interactive} 'STARTING' ;

        for my $folder ( keys %{ $settings->{folders} } ) {
            say {interactive} join ' ', ( '+' x 5 ), $folder ;
            $client->select($folder)
                or die "Select '$folder' error: ",
                $client->LastError, "\n" ;

            my $actions = $settings->{folders}->{$folder} ;

            for my $msg ( reverse $client->unseen ) {
                my $from = $client->get_header( $msg, 'From' ) || '' ;
                my $to   = $client->get_header( $msg, 'To' )   || '' ;
                my $cc   = $client->get_header( $msg, 'Cc' )   || '' ;
                my $subject = $client->subject($msg) || '' ;

                say {interactive} 'F: ' . $from ;
                say {interactive} 'S: ' . $subject ;

                # say { interactive } 'T: ' . $to ;
                # say { interactive } 'C: ' . $cc ;

                for my $action ( keys %$actions ) {

                    # say { interactive } '     for action: ' . $action ;

                    for my $key ( @{ $actions->{$action}->{from} } ) {
                        if (   defined $key
                            && $from =~ m{$key}i
                            && $dispatch->{$action} ) {
                            $dispatch->{$action}->( $client, $msg ) ;
                            }
                        }
                    for my $key ( @{ $actions->{$action}->{to} } ) {
                        if ( $to =~ m{$key}i && $dispatch->{$action} ) {
                            $dispatch->{$action}->( $client, $msg ) ;
                            }
                        }
                    for my $key ( @{ $actions->{$action}->{cc} } ) {
                        if ( $cc =~ m{$key}i && $dispatch->{$action} ) {
                            $dispatch->{$action}->( $client, $msg ) ;
                            }
                        }
                    for my $key ( @{ $actions->{$action}->{subject} } ) {
                        my $match = $subject =~ m{$key}i ;
                        if ( $subject =~ m{$key}i && $dispatch->{$action} ) {
                            $dispatch->{$action}->( $client, $msg ) ;
                            }
                        }
                    }
                say {interactive} '' ;
                }

            say {interactive} join ' ', ( '-' x 5 ), $folder ;
            }

   # $client->close() is needed to make deletes delete, put putting before the
   # logout stops the process.
        $client->close ;
        $client->logout() ;
        say {interactive} 'Finishing' ;
        }
    say {interactive} 'Bye' ;
    }

# ====================================================================
# mark a given mail message as read
sub markread_mail {
    my ( $client, $msg ) = @_ ;
    say {interactive} 'markread' ;
    my @msgs ;
    push @msgs, $msg ;
    $client->see(@msgs) or say {interactive} 'not seen' ;
    }

# ====================================================================
# delete a given mail message
sub delete_mail {
    my ( $client, $msg ) = @_ ;
    say {interactive} 'delete' ;
    my @flags = $client->flags($msg) ;
    my @msgs ;
    push @msgs, $msg ;
    $client->delete_message( \@msgs )
        or say {interactive} 'not deleted' ;
    }

# ====================================================================
# delete a given mail message if older than one day
sub delete_day_old_mail {
    my ( $client, $msg ) = @_ ;
    say {interactive} 'delete_old' ;
    my $from = $client->get_header( $msg, 'From' ) || return ;
    my $to   = $client->get_header( $msg, 'To' )   || return ;
    my $subject = $client->subject($msg) || return ;
    my $date  = $client->get_header( $msg, 'Date' ) || return ;
    my $dt    = DateTime::Format::DateParse->parse_datetime($date) ;
    my $today = DateTime->now() ;
    $dt->set_time_zone('UTC') ;
    $today->set_time_zone('UTC') ;
    my $delta = $today->delta_days($dt)->in_units('days') ;
    say {interactive} join ' | ', ($delta), ( $dt->ymd ), ;

    if ( $delta > 1 ) {
        my @msgs ;
        push @msgs, $msg ;
        $client->delete_message( \@msgs )
            or say {interactive} 'not deleted' ;
        say {interactive} 'DELETING' ;
        }
    }

# ====================================================================
# send to STDOUT without IO::Interactive, for testing
sub warn_mail {
    my ( $client, $msg ) = @_ ;
    say {interactive} 'warn' ;
    my $from = $client->get_header( $msg, 'From' ) || return ;
    my $to   = $client->get_header( $msg, 'To' )   || return ;
    my $subject = $client->subject($msg) || return ;
    my $date  = $client->get_header( $msg, 'Date' ) || return ;
    my $dt    = DateTime::Format::DateParse->parse_datetime($date) ;
    my $today = DateTime->now() ;
    $dt->set_time_zone('UTC') ;
    $today->set_time_zone('UTC') ;
    my $delta = $today->delta_days($dt)->in_units('days') ;
    say $from ;
    say $to ;
    say $subject ;
    say $dt->ymd ;
    say $delta ;
    }

# ====================================================================
# delete a given mail message if older than 30 days
sub delete_old_mail {
    my ( $client, $msg ) = @_ ;
    say {interactive} 'delete_old' ;
    my $from = $client->get_header( $msg, 'From' ) || return ;
    my $to   = $client->get_header( $msg, 'To' )   || return ;
    my $subject = $client->subject($msg) || return ;
    my $date  = $client->get_header( $msg, 'Date' ) || return ;
    my $dt    = DateTime::Format::DateParse->parse_datetime($date) ;
    my $today = DateTime->now() ;
    $dt->set_time_zone('UTC') ;
    $today->set_time_zone('UTC') ;
    my $delta = $today->delta_days($dt)->in_units('days') ;
    say {interactive} join ' | ', ($delta), ( $dt->ymd ), ;

    if ( $delta > 7 ) {
        my @flags = $client->flags($msg) ;
        my @msgs ;
        push @msgs, $msg ;
        $client->delete_message( \@msgs )
            or say {interactive} 'not deleted' ;
        }
    }

# ====================================================================
# send to STDOUT without IO::Interactive, for testing
sub alert_and_store_mail {
    my ( $client, $msg ) = @_ ;
    say {interactive} 'alert and store' ;
    my $date = $client->get_header( $msg, 'Date' ) || 'NONE' ;
    my $from = $client->get_header( $msg, 'From' ) || 'NONE' ;
    my $to   = $client->get_header( $msg, 'To' )   || 'NONE' ;
    my $subject = $client->subject($msg) || 'NONE' ;
    my $key = join '||' , $from , $subject , $date ;
    $key =~ s{\s+}{ }g ;
    my $title =  'Mail From: ' . $from ;
    chomp $title ;
    chomp $subject ;

    return if $warnings->{$key} ;
    $warnings->{$key} = 1 ;

    $from =~ s{\"}{}gx ;
    if ( is_locked() ) {
        pushover(
            {   title   => $title ,
                message => $subject
                }
            ) ;
        }
    else {
        say {interactive} $title  ;
        say {interactive} $subject ;
        say {interactive} defined $warnings->{$key} ? 1 : 0 ;
        say {interactive} 'has spoken: ' . $has_spoken ;
        if ( ! $has_spoken ) {
            say_message( { message => $settings->{message} , title => '' } ) ;
            }
        notify(
            {   title   => $title ,
                message => $subject ,
                icon    => '/home/jacoby/Dropbox/Photos/Icons/mail.png' ,
                }
            ) ;
        }
    $has_spoken = 1 ;
    return ;
    }

# ====================================================================
# alert that a given mail message
sub alert_mail {
    my ( $client, $msg ) = @_ ;
    say {interactive} 'alert' ;
    my $from = $client->get_header( $msg, 'From' ) || 'NONE' ;
    my $to   = $client->get_header( $msg, 'To' )   || 'NONE' ;
    my $subject = $client->subject($msg) || 'NONE' ;
    $from =~ s{\"}{}gx ;
    if ( is_locked() ) {
        pushover(
            {   title   => 'Mail From: ' . $from,
                message => $subject
                }
            ) ;
        }
    else {
        notify(
            {   title   => 'Mail From: ' . $from,
                message => $subject
                }
            ) ;
        }
    }

# ======================================================================
# audible alert
sub speak_mail {
    my ( $client, $msg ) = @_ ;
    say {interactive} 'speak' ;
    my $from = $client->get_header( $msg, 'From' ) || exit ;
    my $to   = $client->get_header( $msg, 'To' )   || exit ;
    my $subject = $client->subject($msg) || exit ;
    $from =~ s{\"}{}gx ;
    if ( !is_locked() ) {
        say_message(
            {   title   => 'Mail From: ' . $from,
                message => $subject
                }
            ) ;
        }
    }
#
# # ======================================================================
# # Handles the actual notification, using Linux's notify-send
# sub notify {
#     my $obj   = shift ;
#     my $title = $obj->{ title } ;
#     my $body  = $obj->{ message } ;
#     $body = $body || '' ;
#     my $icon = $ENV{ HOME } . '/Pictures/Icons/icon_black_muffin.alpha.png' ;
#     `notify-send "$title" "$body" -i $icon  ` ;
#     }

# ====================================================================
#
# Pull credentials from a configuration file
#
# ====================================================================
sub get_credentials {
    my ( $protocol, $identity ) = @_ ;
    my %config_files ;
    my %config_vals ;
    my %config ;

    # $config_files{ imap } = '.imap_identities' ;
    # $config_files{ smtp } = '.smtp_identities' ;

    $config_vals{imap} = [ qw{
            key server port username password directory
            }
            ] ;
    my $stat = ( stat "$ENV{HOME}/$config_files{$protocol}" )[2] ;
    my $hex_stat = sprintf '%04o', $stat ;

    if ( $hex_stat != 100600 ) {
        say 'You should ensure that this file is not executable,' ;
        say ' and not world or group-readable or -writable.' ;
        exit ;
        }

    if (   -f "$ENV{HOME}/$config_files{$protocol}"
        && -r "$ENV{HOME}/$config_files{$protocol}" ) {
        if ( open my $fh, '<', "$ENV{HOME}/$config_files{$protocol}" ) {
            while (<$fh>) {
                chomp $_ ;
                next if length == 0 ;
                next if !/\w/ ;
                $_ = ( split m{\#}mx, $_ )[0] ;
                my @creds = split m{\s*,\s*}mx, $_ ;
                next if scalar @creds < 6 ;
                for my $i ( 1 .. $#creds ) {
                    my $key  = $creds[0] ;
                    my $val  = $creds[$i] ;
                    my $key2 = $config_vals{$protocol}[$i] ;
                    $config{$key}{$key2} = $val ;
                    }
                }
            close $fh ;
            }
        my $href = $config{$identity} ;
        return %$href ;
        }
    else {
        say "No Configuration" ;
        exit ;
        }
    exit ;
    }
