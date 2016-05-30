# grpmgr


Migrates static groups from SRC to DST NA host and assignes the devices to the proper groups.
It could also migrate non existing devices (just creates a record for device with ip) if they
do not exist in destination host.

If started with state 'sync' it will synchronise devices between src and dst HPNA. By default it gets a delta
of added or deleted devices in src hpna since certain date (e.g 2 days ago). It is used after migration has been done
to keep dst HPNA in sync with src until testing is ongoing and before the src hpna is phased out.


# synopsis
```
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

```
