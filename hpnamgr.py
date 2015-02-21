#!/usr/bin/jython
# $Id: hpnamgr.py,v 1.1 2014/04/21 17:34:32 sas Exp sas $
# $Log: hpnamgr.py,v $
# Revision 1.1  2014/04/21 17:34:32  sas
# Initial revision
#

from com.rendition.api import Session
from com.rendition.api import Result
import getopt, sys, os, logging

def migrate_groups (src, dst) :
	log = logging.getLogger()
	log.info("Migrating groups")	

	result = src.exec("list groups -type device")
	if result.succeeded is False :
		log.debug(result.stackTrace)
		log.critical("Cannot list groups: " + result.returnStatus )
		sys.exit(2)

	group = result.getResultSet()
	group_map = {}

	while group.next() :
		
		id = group.getInt('deviceGroupID')
		name = group.getString('deviceGroupName')
		comment = group.getString("comments")
		shared = group.getInt('shared')
		is_parent = group.getInt('isParent')
		is_dynamic = group.getShort('isDynamic')
		pid = group.getInt('parentDeviceGroupID')

		group_map[id] = {'name' : name, 'parent' : is_parent, 'dynamic': is_dynamic, 'pid' : pid } 
		#group_map['byname'].update( { name: { 'id': id, 'parent' : is_parent, 'dynamic' : is_dynamic ,'pid' : pid } } )

		if is_dynamic == 1 :
			log.debug("Group "+name+" is dynamic skipping...")
			continue

		if is_parent == 1 :
			log.debug("Creating parent group " +name)
			x = dst.exec('add parent group -name "'+ name +'" -type device -comment "'+comment+'"')
			if (x.succeeded is False) :
				log.error(x.returnStatus)
		else :
			log.debug("Creating group " + name)
			x = dst.exec('add group -name "'+ name +'" -type device -comment "'+ comment+'"')
			if ( x.succeeded is False) :
				log.error(x.returnStatus)


	log.info("Setting parent/child relationship")
	
	log.debug('Group object: ', group_map)

	for id in group_map :

		name =  group_map[id]['name']
		pid = group_map[id]['pid']
		pname = group_map[pid]['name']
		is_dynamic = group_map[id]['dynamic']
		pid_isparent = group_map[pid]['parent']

		if is_dynamic == 1 :
			log.debug("Group "+name+" is dynamic skipping...")
			continue

		if pname == name :
			log.debug("Group "+name+" equals parent: "+pname)
			continue

		if pname == 'Inventory' :
			log.debug("Parent group of "+pname+" is Inventory skipping...")
			continue

		if group_map[pid]['parent'] == 1:
			log.info("Adding "+name+" to "+pname)
			x = dst.exec('add group to parent group -parent "'+pname+'" -child "'+name+'"')
			if ( x.succeeded is False) :
				log.error(x.returnStatus)
		else :
			log.debug("Parent group for " +name +" - "+pname+" is not marked as parent (ignore if Inventory)")


def migrate_devices (src, dst, devadd):
	
	log = logging.getLogger()
	log.info('Migrating devices')
	
	result = src.exec("list groups -type device")
	if result.succeeded is False :
		log.debug(result.stackTrace)
		log.critical("Cannot list groups: " + result.returnStatus )
		sys.exit(2)

	group = result.getResultSet()
	while group.next() :
		name = group.getString('deviceGroupName')
		log.debug('Processing group '+name)

		x = src.exec('list device -group "'+name+'"')
		if (x.succeeded is False) :
			log.error(x.returnStatus)

		device = x.getResultSet()
		while device.next() :
			id = device.getInt('deviceID')
			ip = device.getString('primaryIPAddress')
			hostname = device.getString('hostName')
			mgmt_status = device.getShort('managementStatus')

			log.debug('Processing device ip: ' + ip + ' hostname: '+hostname)

			if mgmt_status != 1 :
				log.debug(hostname +' not in management status skipping...')
				continue

			x = dst.exec('list device -ip '+ip)
			if x.succeeded is False :
				log.error('Cannot list device '+ip)
				continue

			if x.resultSetData is None:
				log.error(x.returnStatus)
				if devadd is True :
					x = dst.exec('add device -ip '+ip)
					if x.succeeded is False :
						log.error(x.returnStatus)
				else :
					log.warning('Device '+ip+' was not found in dst skipping...')
					continue
			x = dst.exec('add device to group -ip '+ip+' -group "'+name+'"')
			if x.succeeded is False:
				log.error('Cannot add device ip '+ip+' to '+name+': '+x.returnStatus)
		

def migrate_partitions (src, dst):
	pass

def usage() :
	print '''
Usage: hpnamgr.py [OPTIONS]
	-h , --help     print usage
	-a , --devadd	add missing devices from src to dst
	-q , --quiet    do not print messages to stdout
	-o , --logfile	location for logfile
	-l , --loglevel	critical, error, warning, info, debug
'''

def main () :
	
	#src hpna
	s_username = 'hpna'
	s_password = 'password'
	s_hostname = "localhost"
	
	#dst hpna
	d_username = 'hpna'
	d_password = 'password'
	d_hostname = "localhost"
	
	loglevel = 'debug'
	logfile = 'hpnamgr.log'
	print_out = True
	devadd = False

	LEVELS = {
		'debug': logging.DEBUG,
        'info': logging.INFO,
        'warning': logging.WARNING,
        'error': logging.ERROR,
        'critical': logging.CRITICAL
    }

	try:
		opts, args = getopt.getopt(sys.argv[1:], "haqo:l:", ["help","devadd","quiet","logfile=","loglevel="])
	except getopt.GetoptError, err:
		print str(err) # will print something like "option -a not recognized"
		usage()
		sys.exit(2)
	for o, a in opts:
		if o in ("-h","--help"):
			usage()
			sys.exit()
		elif o in ("-a","--devadd") :
			devadd = True
		elif o in ("-q","--quiet") :
			print_out = False
		elif o in ("-o","--logfile") :
			logfile = a
		elif o in ("-l","--loglevel") :
			loglevel = a
		else :
			assert False,"unhandled option"
	
	src = Session()
	src.open(s_username, s_password, s_hostname)
	
	dst = Session()
	dst.open(d_username, d_password, d_hostname)
	
	loglevel = LEVELS.get(loglevel, logging.NOTSET)
	logging.basicConfig(
		level=loglevel,
		format='%(asctime)s %(name)-12s %(levelname)-8s %(message)s',
		datefmt='%m-%d %H:%M',
        filename=logfile,
        filemode='a')
	
	root = logging.getLogger()

	#print also to stdout if quite is not passed
	if print_out is True:
		stdout = logging.StreamHandler(sys.stdout)
		stdout.setFormatter(logging.Formatter('[%(levelname)s] %(message)s'))
		root.addHandler(stdout)
	
	migrate_groups(src, dst)
	migrate_devices(src , dst, devadd)

if __name__ == "__main__":
	main()



		

