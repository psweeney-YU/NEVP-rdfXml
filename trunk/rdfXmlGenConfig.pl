#!/usr/bin/perl -w

use strict;

#appratus mysql database connection variables
host	=> '130.132.27.5',
db		=> 'NEVP_apparatus_4',
user	=> 'generalUser',
pass	=> 'neVpTcN91!',

#paths
#provide locations to where RDF/XML data and log file should be written. Path is terminated with filename.
specimenDataOutfile		=> '/Users/psweeney/Desktop/mysql_XML/rdfSpecimen',
imageDataOutfile		=> '/Users/psweeney/Desktop/mysql_XML/rdfImage',
logFile					=> '/Users/psweeney/Desktop/mysql_XML/rdfXmlLog',
