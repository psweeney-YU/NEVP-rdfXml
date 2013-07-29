#!/usr/bin/perl -w

use strict;

#appratus mysql database connection variables
host	=> '',
db		=> '',
user	=> '',
pass	=> '',

#paths
#provide path (ending in slash) to where RDF/XML metadata & images and path + filename for logfile.
exportPath		=> '', #/path/to/export/directory/
logFile			=> '', #/path/to/logfile/logfile_name

#timezone. use Date::Manip 6.xx abbreviations: http://search.cpan.org/~sbeck/Date-Manip-6.40/lib/Date/Manip/Zones.pod.
timezone	=> 'America/New_York';
