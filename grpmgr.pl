#!/usr/bin/perl
use warnings;
use strict;
use lib qw(blib lib);
use Carp;
use Log::Log4perl qw(get_logger);
use Opsware::NAS::Client;
use Getopt::Long;
use Pod::Usage;
use Data::Dumper;
local $ENV{'PERL_LWP_SSL_VERIFY_HOSTNAME'} = 0;

main();

# Functions

sub main {

    # Source HPNA connection credentials
    my $suser = 'hpna';
    my $spass = 'password';
    my $shost = 'localhost';

    # Destination HPNA connection credentials
    my $duser = 'hpna';
    my $dpass = 'password;
    my $dhost = '10.10.2.54';

    my $help = 0;
    my $man = 0;
    my $src;    # Source HPNA result handle
    my $dst;    # Destination HPNA result handle
    my $dump     = 0;              # dump only
    my $logfile  = 'grpmgr.log';
    my $loglevel = 'INFO';
    my $action;
    my $fargs->{'start'} = '1 day ago';
    $fargs->{'delete_all'} = 1;    #delete all 1 enabled, 0 disabled

    $Data::Dumper::Indent = 0;     # do not prettify dumper output
    $Data::Dumper::Terse  = 1;     # do not print dumper $VARx

    my %states = (
        'migrate_groups'  => \&migrate_groups,
        'migrate_devices' => \&migrate_devices,
        'sync'            => \&sync,
        'delete_all'      => \&delete_all
    );

    while (
        !GetOptions(
            'suser=s'    => \$suser,
            'spass=s'    => \$spass,
            'loglevel=s' => \$loglevel,
            'logfile=s'  => \$logfile,
            'shost=s'    => \$shost,
            'duser=s'    => \$duser,
            'dpass=s'    => \$dpass,
            'dhost=s'    => \$dhost,
            'devadd'     => \$fargs->{'devadd'},
            'start=s'    => \$fargs->{'start'},
            'help|h|?'   => \$help,
            'manual|man' => \$man,
            'action=s'   => \$action
        )
      )
    {
        pod2usage();
    }

    if ( !$suser || !$spass || !$shost || !$duser || !$dpass || !$dhost ) {
        pod2usage();
    }

    pod2usage( 'verbose' => 1 ) if $help;
    pod2usage( 'verbose' => 2 ) if $man;

    my $conf = <<"CONF";
    log4perl.category.GRPMGR           = $loglevel, Logfile
    log4perl.appender.Logfile          = Log::Log4perl::Appender::File
    log4perl.appender.Logfile.filename = $logfile
    log4perl.appender.Logfile.layout   = Log::Log4perl::Layout::PatternLayout
    log4perl.appender.Logfile.layout.ConversionPattern = %d %p> %F{1}:%L %M %m %n
    log4perl.appender.Screen.stderr  = 1
    log4perl.appender.Screen.layout = Log::Log4perl::Layout::SimpleLayout
CONF

    Log::Log4perl::init( \$conf );
    my $logger = get_logger('GRPMGR');

    $fargs->{'src'} = Opsware::NAS::Client->new();
    $fargs->{'dst'} = Opsware::NAS::Client->new();

    #Connect to src hpna
    $src =
      $fargs->{'src'}
      ->login( -username => $suser, -password => $spass, -host => $shost );
    $logger->logcroak( $src->error_message ) if ( !$src->ok );

    #Connect to dst hpna
    $dst =
      $fargs->{'dst'}
      ->login( -username => $duser, -password => $dpass, -host => $dhost );
    $logger->logcroak( $dst->error_message ) if ( !$dst->ok );

    if ($action) {
        $states{$action}->($fargs);
    }
    else {
        $states{'migrate_groups'}->($fargs);
        $states{'migrate_devices'}->($fargs);
    }

    return;
}

sub migrate_groups {

    my $args = shift;
    my $log  = get_logger('GRPMGR');
    my $sr;
    $log->info('Migrating Groups');
    $sr = _exec(
        {
            'nas'   => $args->{'src'},
            'cmd'   => 'list_groups',
            'param' => { 'type' => 'device' }
        }
    );

    $log->logcroak( $sr->error_message ) if ( !$sr->ok );

    my %groups;

    #build source groups id and name list
    foreach ( $sr->result() ) {
        $groups{ $_->deviceGroupID() } = $_;
    }

  GROUP: foreach ( sort values %groups ) {
        my $r;
        my $grpnam  = $_->deviceGroupName();
        my $shared  = $_->shared();
        my $comment = $_->comments();

        $log->trace( 'Group Object: ', Dumper $_ );

        if ( $_->isDynamic() ) {
            $log->error( 'Group', $grpnam, ' is dynamic...skipping' );
            next GROUP;
        }

        if ( $_->isParent() ) {
            $log->debug( 'Creating parent group ', $grpnam );
            $r = _exec(
                {
                    'nas'   => $args->{'dst'},
                    'cmd'   => 'add_parent_group',
                    'param' => {
                        'type'    => 'device',
                        'name'    => $grpnam,
                        'comment' => $comment
                    }
                }
            );

        }
        else {
            $log->debug( 'Adding group ', $grpnam );
            $r = _exec(
                {
                    'nas'   => $args->{'dst'},
                    'cmd'   => 'add_group',
                    'param' => {
                        'name'    => $grpnam,
                        'type'    => 'device',
                        'comment' => $comment,
                        'shared'  => $shared
                    }
                }
            );
        }
    }

    # update parent/child relationships
    $log->info('Setting parent/child relationship');

  RELSHIP: foreach ( sort values %groups ) {
        my $r;
        my $grpnam = $_->deviceGroupName();

        $log->trace( 'Group Object: ', Dumper $_ );

        if ( $_->isDynamic() ) {
            $log->debug( 'Group ', $grpnam, 'is dynamic...skipping' );
            next RELSHIP;
        }
        if (
            $grpnam eq $groups{ $_->parentDeviceGroupID() }->deviceGroupName() )
        {
            $log->debug( 'Group ', $grpnam, ' equals parent...skipping' );
            next RELSHIP;
        }
        if ( $_->parentDeviceGroupID() ) {
            my $pid   = $_->parentDeviceGroupID();
            my $pname = $groups{$pid}->deviceGroupName();

            if ( $pname eq 'Inventory' ) {
                $log->debug('Parent group is Inventory (skipping)');
                next RELSHIP;
            }

            $log->debug( 'Adding ', $grpnam, " to $pname" );

            if ( $groups{$pid}->isParent() ) {
                $r = _exec(
                    {
                        'nas'   => $args->{'dst'},
                        'cmd'   => 'add_group_to_parent_group',
                        'param' => { 'parent' => $pname, 'child' => $grpnam }
                    }
                );
            }
            else {
                $log->debug( 'Parent group for ',
                    $grpnam, ' is not marked as parent (ignore if Inventory)' );
            }
        }
    }

    return;
}

#delete all groups and devices from dst HPNA
#used during development for testing purposes only
#use with caution

sub delete_all {

    my $args = shift;
    my $log  = get_logger('GRPMGR');
    my $sr;

    if ( !$args->{'delete_all'} ) {
        $log->info('Deleting all groups and devices is disabled');
        return;
    }

    $log->info('Deleting all groups');

    $sr = _exec(
        {
            'nas'   => $args->{'dst'},
            'cmd'   => 'list_groups',
            'param' => { 'type' => 'device' }
        }
    );

    $log->trace( 'Groups to be deleted: ', sub { Dumper $sr->result() } );

    foreach my $group ( $sr->result() ) {
        my $name = $group->deviceGroupName();
        $sr = _exec(
            {
                'nas'   => $args->{'dst'},
                'cmd'   => 'del_group',
                'param' => {
                    'name' => $name,
                    'type' => 'device'
                }
            }
        );
    }

    $log->info('Deleting all devices');

    $sr = _exec(
        {
            'nas' => $args->{'dst'},
            'cmd' => 'list_device',
        }
    );

    if ($sr) {
        foreach ( $sr->result() ) {
            my $ip = $_->primaryIpAddress();
            _exec(
                {
                    'nas'   => $args->{'dst'},
                    'cmd'   => 'del_device',
                    'param' => { 'ip' => $ip }
                }
            );
        }
    }
}

sub migrate_devices {

    my $args = shift;
    my $log  = get_logger('GRPMGR');
    my $sr;

    #get the src groups
    $log->info('Listing groups in source NAS');
    $sr = _exec(
        {
            'nas'   => $args->{'src'},
            'cmd'   => 'list_groups',
            'param' => { 'type' => 'device' }
        }
    );

    $log->logcroak( $sr->error_message ) if ( !$sr->ok );

#compare src and destination devices, and update destination with proper group id
  GRP: foreach my $grp ( $sr->result() ) {
        my $r;
        my $grpnam = $grp->deviceGroupName();

        #check if group is parent (cannot contain devices, just other groups)
        if ( $grp->isParent() ) {
            $log->debug(
                "Group [$grpnam] is parent, cannot contain devices skiping...");
            next GRP;
        }
        $log->info("Processing group [$grpnam]");
        $r = _exec(
            {
                'nas'   => $args->{'src'},
                'cmd'   => 'list_device',
                'param' => { 'group' => $grpnam }
            }
        );

        $log->logcroak( $r->error_message() ) if ( !$r->ok() );

        if ( $r->num_results() == 0 ) {    #group is empty
            $log->debug("[$grpnam] is empty skipping...");
            next GRP;
        }

      DEV: foreach my $srcdev ( $r->result() ) {
            my $dr;
            my $ip       = $srcdev->primaryIPAddress();
            my $hostname = $srcdev->hostname();

            $log->trace( 'Device Object: ', Dumper $srcdev);

            if ( $srcdev->managementStatus() != 0 ) {
                $log->debug( $srcdev->hostname(),
                    ' not in active state...skipping' );
                next DEV;    #device not in active state
            }

            #obtain destination device
            $dr = _exec(
                {
                    'nas'   => $args->{'dst'},
                    'cmd'   => 'list_device',
                    'param' => { 'ip' => $ip }
                }
            );

            if ( !$dr->ok() ) {
                $log->error( 'src list dev ip:',
                    $ip, ' hostname: ', $hostname, ' errmsg: ',
                    $dr->error_message );
                next DEV;
            }

            if ( $dr->num_results() == 0 ) {
                if ( $args->{'devadd'} ) {
                    $log->debug("Adding device ip: $ip hostname: $hostname ");
                    my $add = _exec(
                        {
                            'nas'   => $args->{'dst'},
                            'cmd'   => 'add_device',
                            'param' => { 'ip' => $ip }
                        }
                    );
                }
                else {

                    #just complain if device is not in destination hpna
                    $log->error( 'device ', $ip,
                        ' was not found in destination HPNA skipping...' );
                    next DEV;
                }
            }

            #add destination device in group

            my $add = $args->{'dst'}->add_device_to_group(
                'ip'    => $ip,
                'group' => $grpnam
            );
            if ( !$add->ok() ) {
                $log->warn( 'Cannot add device ',
                    $ip, ' to ', $grpnam, ' :', $add->error_message );
                next DEV;
            }
        }
    }
    return;
}

sub sync {
    my $args = shift;
    my $log  = get_logger('GRPMGR');
    my $sr;
    my $dr;

    $log->info('Sync devices between different HPNA servers');

    #get devid of newly discovered devices
    my $discovered = _get_dev_by_event(
        {
            'nas'   => $args->{'src'},
            'param' => {
                'start' => $args->{'start'},
                'type'  => 'Driver Discovery Success'
            }
        }
    );

    my $added = _get_dev_by_event(
        {
            'nas'   => $args->{'src'},
            'param' => {
                'start' => $args->{'start'},
                'type'  => 'Device Added'
            }
        }
    );

    my $changed = _get_dev_by_event(
        {
            'nas' => $args->{'src'},
            'param' => {
                'start' => $args->{'start'},
                'type' => 'Device Configuration Change'
            }
        }
    );

    my %ids = { %{$discovered}, %{$added}, %{$changed} };

    if (scalar keys %ids ) {
        $log->info('Processing ', scalar %ids, ' number of sync triggering events');
        $sr = _exec(
            {
                'nas'   => $args->{'src'},
                'cmd'   => 'list_device',
                'param' => { 'ids' => join( q{,}, values %ids ) }
           }
        );
    } else {
        $log->debug('No events to trigger sync found');
    }

    

  DEV: foreach my $srcdev ( $sr->result() ) {
        
        my $sip = $srcdev->primaryIPAddress();
        
        #get object for destination device
        $dr = _exec(
            {
                'nas'   => $args->{'dst'},
                'cmd'   => 'list_device',
                'param' => { 'ip' => $sip }
            }
        );

        #destination device not found, create it
        if ( $dr->num_results == 0 ) {

            $log->debug('device not found create new');
            $dr = _exec(
                {
                    'nas' => $args->{'dst'},
                    'cmd' => 'add_device',
                    'param' => { 'ip' => $sip}
                }
            );
            next DEV if ($dr->error_message());

            #get object for destination device after creation
            $dr = _exec(
                {
                    'nas' => $args->{'dst'},
                    'cmd' => 'list_device',
                    'param' => { 'ip' => $sip}
                }
            );
        
            next DEV if ($dr->num_results() == 0);

        }

        #compare src and dst device and generate mod_device parameters
        my $dstdev = $dr->result()->[0];
        my $diff = _is_different( $srcdev, $dstdev );

        #modify destination device if different
        if ( $diff->{'diff'}) {
            
            $log->debug('device', $srcdev,' is different');
            
            #normalize accessMethods
            if ($diff->{'param'}->{'accessmethods'}) {
                $diff->{'param'}->{'accessmethods'} =~ s/CLI\+:?//;
                $diff->{'param'}->{'accessmethods'} =~ s/commstr:?//;
                $diff->{'param'}->{'accessmethods'} =~ s/SFTP:?//;
                $diff->{'param'}->{'accessmethods'} =~ s/:/,/g;
            }
             $diff->{'param'}->{'ip'} = $sip;
            _exec(
                {
                    'nas' => $args->{'dst'},
                    'cmd' => 'mod_device',
                    'param' => $diff->{'param'}
                }
            );
        }

        #sync primary custom fields
        # TODO: sync extended custom fields
        my $custfields = {
        'deviceCustom1' => 'deviceCustom1', 
        'deviceCustom2' => 'deviceCustom2', 
        'deviceCustom3' => 'deviceCustom3', 
        'deviceCustom4' => 'deviceCustom4', 
        'deviceCustom5' => 'deviceCustom5', 
        'deviceCustom6' => 'deviceCUstom6'
        };

        $diff = _is_different($srcdev, $dstdev, $custfields);

        if ($diff->{'diff'}) {
            my @customnames;
            my @customvalues;

            while (my ($i, $j) = each %{ $diff->{'param'} }) {
                push @customnames,$i;
                push @customnames,$j;
            }
            $diff->{'param'}->{'ip'} = $sip;
            _exec(
                {
                    'nas' => $args->{'dst'},
                    'cmd' => 'mod_device',
                    'param' => {
                        'customnames' => join( q{,}, @customnames),
                        'customvalues' => join( q{,}, @customvalues)
                    }

                }
            );
        }
        else {
            next DEV;
        }

    }

    my $deleted = _get_dev_by_event(
        {
            'nas'   => $args->{'src'},
            'param' => {
                'start' => $args->{'start'},
                'type'  => 'Device Deleted'
            }
        }
    );

    if (scalar keys %{$deleted}) {
        foreach my $ip (keys %{$deleted}) {
            $dr = _exec(
                {
                    'nas' => $args->{'dst'},
                    'cmd' => 'del_device',
                    'param' => { 'ip' => $ip}
                }
            );
        }
    }
}

sub migrate_partitions {
    ...;
}

##########################################################
# get list of device ip matching event type and startdate
# Input: anonmous hash with the following keys:
# nas - reference to NA connection handler
# startdate - startdate for the event lookup (DEFAULT: 1 day ago)
# type - the type of the event to look for (DEFAULT: Driver Discovery Success)
# Returns:
# array reference that contains the device ids associated with the events
sub _get_dev_by_event {
    my $args = shift;
    my $r;
    my $log = get_logger('GRPMGR');
    my %output;

    $log->debug( sub { Dumper $args->{'param'} } );
    if ( !$args ) {
        $log->error('_get_dev_by_event() called without arguments');
        return;
    }

    $r = _exec(
        {
            'nas'   => $args->{'nas'},
            'cmd'   => 'list_event',
            'param' => $args->{'param'}
        }
    );

    if ( !$r->ok ) {
        return;
    }
   
    foreach ( $r->result() ) {
        my $ip;
        my $id;
        my $dev;

        if ($_->eventDeviceID()) {
            $dev = _exec(
                {
                    'nas' => $args->{'nas'},
                    'cmd' => 'list_device_id',
                    'param' => {'id' => $dev->deviceID()}
                }
            );
            if ($dev->num_results() > 0) {
                $ip = $dev->results()->[0]->primaryIPAddress();
                $id = $dev->results()->[0]->deviceID();
            } 
        } else {
            $_->eventText() =~ m{
                Primary[ ]IP:[ ]
                (?<ip>\S+)?
            }xsgmi ; #deleted events don't have device id, extract ip from eventText

            if ($+{'ip'}) {
                $ip = $+{'ip'};
                $id = undef;
            }            
        }

         $output{$ip} = $id ;

    }

    $log->debug( scalar each %output, ' event(s) found' );
    return \%output;

}

sub _exec {
    my $args = shift;
    my $log  = get_logger('GRPMGR');
    my $c    = $args->{'cmd'};
    my $p    = $args->{'param'};
    my $res;

    $log->debug( $c, ' ', sub { Dumper $p} );

    if ( !$p ) {
        $res = $args->{'nas'}->$c();
    }
    else {
        $res = $args->{'nas'}->$c( $args->{'param'} );
    }

    if ( $res->ok ) {
        return $res;
    }
    else {
        $log->error( $res->error_message );
    }

    return;
}

sub _is_different {
    my ($s, $d, $f) = @_;

    if (!$f) {
        #fields to param mapping
        $f = {
        'primaryIpAddress' => 'ip' ,
        'accessMethods' => 'accessmethods', 
        'comments' =>  'comment',
        'consoleIPAddress' =>  'consoleip',
        'hostName' => 'hostname', 
        'geographicalLocation' => 'location', 
        'model' => 'model', 
        'nATIPAddress' => 'natip', 
        'managementStatus' => 'status', 
        'tFTPServerIPAddress' => 'tftpserverip', 
        'vendor' => 'vendor', 
        'deviceCustom1' => undef, 
        'deviceCustom2' => undef, 
        'deviceCustom3' => undef, 
        'deviceCustom4' => undef, 
        'deviceCustom5' => undef, 
        'deviceCustom6' => undef
    };

    }

    my $log = get_logger('GRPMGR');
    $log->debug('compare devices ids src: ', 
        $s->deviceID(), ' dst: ', $d->deviceID());
  
    my %param;
    my $result; 
    
    while (my ($i, $j) =  each %{$f}) {
        if ($j) {
            if ($s->$i() ne $d->$i()) {
                $param{$j} = $s->$i();
            }
        }
    }
    
    if (%param) {
        return {'diff' => 1,'param' => \%param };
    }

    return;
}

__END__

=head1 NAME

grpmgr.pl -- dump/import hpna groups

=head1 SYNOPSIS

grpmgr.pl [options]

 Options:

    --help              This help message
    --manual            Complete manual page includig usage examples
    --shost=IP|Name     The SRC NAS Server HOST (default: localhost)
    --suser=Name        A user on the SRC NAS server (default: admin)
    --spass="secret"    The password for the SRC NAS user (no default)
    --dhost=IP|Name     The DST NAS Server HOST (default: localhost)
    --duser=Name        A user on the DST NAS server (default: admin)
    --dpass="secret"    The password for the DST NAS user (no default)
    --devadd            Add device if not found in destination NAS
    --loglevel          FATAL, ERROR, WARNING, INFO, DEBUG
    --logfile           Logfile to store messages (Default: grpmgr.log use '-' for STDOUT)
    --action            migrate_groups, migrate_devices, sync
                        migrate_groups - connect to src and dst HPNA and migrates the groups
                        migrate_devices - connect to src and dst hpna and migrate devices
                        sync - gets devices from src hpna, and syncs them in dst na (use with --startdate)
    --start             start date for sync events lookup (Default: 1day)
    Display only events after this date. 

    Values for this option may be in one of the following formats: 
    YYYY-MM-DD HH:MM:SS e.g. 2002-09-06 12:30:00 
    YYYY-MM-DD HH:MM e.g. 2002-09-06 12:30 
    YYYY-MM-DD e.g. 2002-09-06 
    YYYY/MM/DD e.g. 2002/09/06 
    YYYY:MM:DD:HH:MM e.g. 2002:09:06:12:30 
    Or, one of: now, today, yesterday, tomorrow 

    Or, in the format: <number> <time unit> <designator> e.g. 3 days ago 
    <number> is a positive integer. 
    <time unit> is one of: seconds, minutes, hours, days, weeks, months,years;. 
    <designator> is one of: ago, before, later, after. 


=head1 DESCRIPTION

Migrates static groups from SRC to DST NA host and assignes the devices to the proper groups.
It could also migrate non existing devices (just creates a record for device with ip) if they
do not exist in destination host.

If started with state 'sync' it will synchronise devices between src and dst HPNA. By default it gets a delta
of added or deleted devices in src hpna since certain date (e.g 2 days ago). It is used after migration has been done
to keep dst HPNA in sync with src until testing is ongoing and before the src hpna is phased out.

=head1 AUTHOR

Aleksandar Zhelyazkov (sasz@hp.com)

=head1 COPYRIGHT AND LICENSE

(2014) Hewlett-Packard Co.

=head1 VERSION

1.4

=cut
