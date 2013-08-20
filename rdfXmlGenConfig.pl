#!/usr/bin/perl -w

use strict;

#appratus mysql database connection variables
host	=> '130.132.27.5',
db		=> 'NEVP_apparatus_4',
user	=> 'generalUser',
pass	=> 'neVpTcN91!',

#paths
#provide path to where RDF/XML metadata & images and path + filename for logfile.
exportiPlant		=> '/Users/psweeney/Desktop/mysql_XML/images/sink/iPlant/', #/path/to/iPlant/export/directory/
exportSymbiota	=> '/Users/psweeney/Desktop/mysql_XML/images/sink/Symbiota/', #/path/to/Symbiota/export/directory/
logPath			=> '/Users/psweeney/Desktop/mysql_XML/images/sink/iPlant/', #/path/to/logfile/logfile_name

#timezone. use Date::Manip 6.xx abbreviations: http://search.cpan.org/~sbeck/Date-Manip-6.40/lib/Date/Manip/Zones.pod.
timezone	=> 'America/New_York';
