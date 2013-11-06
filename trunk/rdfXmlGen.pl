#!/usr/bin/perl -w
#
# Script to generate RDF/XML interchange documents for NEVP TCN project.
#
# Author: Patrick W. Sweeney, Yale University Herbarium
#
#-----LISCENSE-----
# You may use this software under the terms of the MIT License:
#
# The MIT License (MIT)
# Copyright (c) 2013 Yale Peabody Musuem of Natural History
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy of 
# this software and associated documentation files (the "Software"), to deal in the Software
# without restriction, including without limitation the rights to use, copy, modify, merge, 
# publish, distribute, sublicense, and/or sell copies of the Software, and to permit 
# persons to whom the Software is furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all copies or 
# substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, 
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR 
# PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE 
# FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR 
# OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER 
# DEALINGS IN THE SOFTWARE.
#----------

use strict;
use utf8;
use DBI;
use DBD::mysql;
use CGI qw(:cgi-lib :standard);
use UUID::Tiny;
use File::Copy;
use File::Basename;
use Time::Piece;
use Date::Manip;
use IO::Tee;
use Digest::MD5 qw(md5_hex);
use IPC::System::Simple qw(system capture);
use JSON qw(decode_json);
use LWP::UserAgent;
use HTTP::Request::Common qw(GET);
use FindBin;

binmode STDOUT, ":encoding(UTF-8)";

our %in;
&ReadParse(%in);

my $version = '$Rev$';
$version =~ s{(\$Rev:) ([0-9]*) (\$)}{$2};

my %config = do $FindBin::Bin.'/rdfXmlGenConfig.pl';

my $d = localtime->ymd;
my $t = localtime->hms("");
my $date = $d."-".$t;

#-----make iPlant export directory for batch of exported images and RDF/XML files
mkdir("$config{exportiPlant}$date",0777) unless(-d "$config{exportiPlant}$date" );

#-----open logfile
open (OUTFILELOG, ">>$config{logPath}$date/rdfXmlLog_$date.txt") || die "ERROR: opening $config{logPath}$date/rdfXmlLog_$date.txt\n";

#-----redirect STDERR and STDOUT to log file
open (STDERR, ">>", "$config{logPath}$date/rdfXmlLog_$date.txt");
open (STDOUT, ">>", "$config{logPath}$date/rdfXmlLog_$date.txt");
select( OUTFILELOG );
$| = 1; # turn on buffer autoflush for log output
select(STDOUT);

print STDERR "******Log for $date******\n";

#-----open data outfiles
open (OUTFILESPEC, ">:encoding(utf8)","$config{exportiPlant}$date/rdfSpecimen_$date.xml") || die "ERROR: opening $config{exportiPlant}$date/rdfSpecimen_$date.xml\n";
open (OUTFILESPECSYM, ">:encoding(utf8)","$config{exportSymbiota}/rdfSpecimen_$date.xml") || die "ERROR: opening $config{exportSymbiota}/rdfSpecimen_$date.xml\n";


my $allFiles = IO::Tee->new( \*OUTFILESPEC, \*OUTFILESPECSYM);
my $specimenDataFiles = IO::Tee->new( \*OUTFILESPEC, \*OUTFILESPECSYM);

#-----connect to MYSQL database
my $dbh = DBI->connect("DBI:mysql:".$config{db}.";host=".$config{host}."",$config{user},$config{pass},{mysql_enable_utf8 => 1}) or die "Connection Error: $DBI::errstr\n";

#-----MYSQL query to popluate specimen.scientificName field, when not populated
my $updateSciNamesql = qq{
	UPDATE specimen b
	SET b.ScientificName=CONCAT_WS(" ",IF(b.Genus!="",b.Genus,NULL),IF(b.SpecificEpithet!="",b.SpecificEpithet,NULL),IF(b.InfraspecificEpithet!="" && b.InfraspecificRank!="",CONCAT(b.InfraspecificRank," ",b.InfraspecificEpithet),NULL),IF(b.ScientificNameAuthorship!="",b.ScientificNameAuthorship,NULL))
	WHERE b.ScientificName=""
	};
	
my $sthUpdateSciName = $dbh->prepare($updateSciNamesql);
$sthUpdateSciName->execute;

#-----MYSQL SELECT query to fetch data for export files
my $sql = "
	SELECT
		a.SpecimenId,		#internal DB id for specimen record
		a.Barcode,		#barcode attached to specimen, dwc:catalogNumber for NEVP
		a.ScientificName,		#dwc:scientificName
		a.Family,	#dwc:family
		a.Genus,		#dwc:genus
		a.SpecificEpithet,		#dwc:specificEpithet
		a.InfraspecificRank,		#infraspecificRank
		a.InfraspecificEpithet,		#dwc:infraspecificEpithet
		a.ScientificNameAuthorship,		#dwc:scientificNameAuthorship
		a.IdentificationQualifier,		#dwc:identificationQualifier
		a.RecordNumber,		#dwc:recordNumber
		a.VerbatimEventDate,		#dwc:verbatimEventDate
		a.BeginEventDate,		#beginning collection date
		a.EndEventDate,		#ending collection date
		a.Country,		#dwc:country
		a.County,		#dwc:county
		a.StateProvince,		#dwc:stateProvince
		a.Town,		#dwc:municipality
		a.CreationDate,		#date record created, applies to specimen & image metadata
		a.ModificationDate,		#dcterms:modified, applies to specimen & image metadata
		a.ExportDate,		#date specimen record serialized in RDF/XML format
		a.Checksum,		#md5 hash checksum of image file
		b.ImageRawPath,		#path to image file on apparatus computer
		b.ImageRawName,		#file name of image 
		c.Username,		#username of user capturing specimen data and imaging specimen
		c.Email,		#email of user
		c.WorksplaceURL,		#workplace url of user
		c.UUID,		#UUID of user
		d.CollectionCode,		#dwc:collectionCode for collection housing specimen
		d.BCICollectionId,		#Biological Collections Index LSID for collection housing specimen
		e.InstituteName,		#name of institution, dwc:institutionCode
		f.rights,		#dcterms:rights, used in image RDF/XML document
		f.usage		#xmpRights:UsageTerms, used in image RDF/XML document
		#f.webStatement			#xmpRights:WebStatement, used in image RDF/XML document
	FROM
		specimen a,
		image_raw b,
		`user` c,
		collection d,
		institute e,
		ownership f
	WHERE
		b.ImageRawId=a.RawImage AND 
		c.UserId=a.RecordUser AND 
		(a.ExportDate=\"0000-00-00 00:00:00\" OR a.ExportDate IS NULL) AND 
		d.CollectionId=a.CollectionCode AND
		e.InstituteId=d.InstituteId AND
		f.OwnerId=e.InstituteId AND
		a.MissingInfo=\"0\"
		
		GROUP BY a.SpecimenId";

my $sth = $dbh->prepare($sql);
$sth->execute() or die "SQL Error: $DBI::errstr\n";

#-----get count of records returned
my $resultCount = $sth->rows;

#-----create the RDF/XML documents
#-----headers
print {$allFiles} <<HEADER;
<?xml version=\"1.0\" encoding=\"utf-8\"?>
HEADER

#----header of specimen data file
print {$specimenDataFiles} <<HEADERSPEC;
<rdf:RDF
	xmlns:dwcFP="http://filteredpush.org/ontologies/oa/dwcFP.owl#" 
	xmlns:foaf="http://xmlns.com/foaf/0.1/"
	xmlns:cnt="http://www.w3.org/2011/content#"
	xmlns:oa="http://www.w3.org/ns/oa#"
	xmlns:co="http://purl.org/ontology/co/core#"
	xmlns:oad="http://filteredpush.org/ontologies/oa/oad.rdf#"
	xmlns:dwc="http://rs.tdwg.org/dwc/terms/"
	xmlns:dc="http://purl.org/dc/elements/1.1/"
	xmlns:vivo="http://vivoweb.org/ontology/core#"
	xmlns:obo="http://purl.obolibrary.org/obo/"
	xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
	xmlns:rdfs="http://www.w3.org/2000/01/rdf-schema#"
	xmlns:ac="http://rs.tdwg.org/ac/terms/"
	>
	<rdf:Description rdf:about="urn:uuid:@{ [create_UUID_as_string(UUID_V4)] }/">
        <rdfs:comment xml:lang="en">Document of new NEVP specimen records expressed as OA annotations.</rdfs:comment>
        <co:count xml:type="xsd:integer">$resultCount</co:count>
    </rdf:Description>
HEADERSPEC

#-----loop through records
{
no warnings 'uninitialized';
while (my ($specimenID,$barcode,$scientificName,$family,$genus,$species,$rank,$infraSpecific,
$author,$qualifier,$collectorNumber,$verbatimDate,$beginDate,$endDate,$country,
$county,$state,$town,$createDate,$modificationDate,$exportDate,$checksum,$imagePath,$imageName,$username,
$useremail,$userURL,$userUUID,$collectionCode,$BCIcollectionID,$institution,$rights,$usage) = $sth->fetchrow_array) {

#-----insert taxa into taxon table, if not already present
my $newTaxonResult = getNewTaxonResult($scientificName);		
if (getNewTaxonResult($scientificName) == 1) {
	if ($family eq "") {
		$family = getTNRSFamily($genus,$species);
		};
	if ($rank eq "subspecies") {
		my $insertSciNamesql = qq{
		INSERT INTO taxa_bonap (Family,Genus,SpecificEpithet,SubspecificEpithet,Authorship,BONAP_ID,UUID)
		VALUES ("$family","$genus","$species","$infraSpecific","$author","$collectionCode","@{ [create_UUID_as_string(UUID_V4)] }");
		};
		my $sthInsertSciName = $dbh->prepare($insertSciNamesql);
		$sthInsertSciName->execute;	
	
	} else {
		my $insertSciNamesql = qq{
		INSERT INTO taxa_bonap (Family,Genus,SpecificEpithet,InfraspecificRank,InfraspecificEpithet,Authorship,BONAP_ID,UUID)
		VALUES ("$family","$genus","$species","$rank","$infraSpecific","$author","$collectionCode","@{ [create_UUID_as_string(UUID_V4)] }");
		};
		my $sthInsertSciName = $dbh->prepare($insertSciNamesql);
		$sthInsertSciName->execute;
	}
}

#-----copy image file to export folder

my ($name,$path,$suffix) = fileparse("$imagePath$imageName",qr"\..[^.]*$"); 
$suffix =~ s/\.//g;
my $barcodeFile = $barcode;
$barcodeFile =~ s/\.//g;
my $copyStatus;
my $finalPath;
my $folderName = getFolderName($collectionCode);
my $outputFileMD5;

#----------If HUH add collectionCode prefix to filename
#----------Set final path variable
if ( ( index ($institution, "HUH" ) != -1 ) || ( index ($institution, "Harvard" )  != -1 ) ) {
	$copyStatus = copy("$imagePath$imageName","$config{exportiPlant}$date/$collectionCode$barcodeFile.$suffix");
	$finalPath = "/data.iplantcollaborative.org/iplant/home/shared/NEVP/$folderName/$date/$collectionCode$barcodeFile.$suffix";
	$outputFileMD5 = md5sumFile("$imagePath$imageName","$config{exportiPlant}$date/$collectionCode$barcodeFile.$suffix");
} else {
	$copyStatus = copy("$imagePath$imageName","$config{exportiPlant}$date/$barcodeFile.$suffix");
	$finalPath = "/data.iplantcollaborative.org/iplant/home/shared/NEVP/$folderName/$date/$barcodeFile.$suffix";
	$outputFileMD5 = md5sumFile("$imagePath$imageName","$config{exportiPlant}$date/$barcodeFile.$suffix");
}

#-----get md5 checksum of file
my $fileMD5 = md5sumFile("$imagePath$imageName");

#-----add data to exchange files
	if (-e "$imagePath$imageName") {
	
		if ($copyStatus) {
		
			print OUTFILELOG "target: $imagePath$imageName, image file copied, ";	
		
			my $time = Time::Piece->strptime(localtime->datetime, "%Y-%m-%dT%H:%M:%S");
			$time -= $time->localtime->tzoffset;
			my $timeGMT = $time->datetime."Z";
								
			#-----generate UUID for image
			my $mediaUUID = create_UUID_as_string(UUID_V4);
			my $mediaURI = "urn:uuid:$mediaUUID";
		
			#-----create ISO 8601 'compliant' event date
			my $eventDate = createEventDate($beginDate,$endDate);
			
			#-----create eventRemarks
			my $eventRemarks = eventRemarks($beginDate,$endDate,$verbatimDate);
			
			#-----create ISO 8601 compliant creation and modification dates
			
			my $modificationDateGMT = convertTZ($modificationDate);
			my $createDateGMT = convertTZ($createDate);
		
			#-----create md5 hash of data entry user's email address
			my $useremailMD5 = md5_hex($useremail);
	
			#-----set taxonID
			my $taxonID = gettaxonID($scientificName);
	
			#-----get collector's full name & GUID
			my ($collectorName,$collectorGUID) = getCollector($specimenID);
			
			#-----get family from iPlant TRNS using genus & species
			my $TRNSfamily = getTNRSFamily($genus,$species);
			
			#-----specimen RDF/XML content
			print {$specimenDataFiles} <<DATASPECIMEN;
				<oa:Annotation rdf:about="urn:uuid:@{ [create_UUID_as_string(UUID_V4)] }">
					<oa:hasTarget>
						<oa:SpecificResource rdf:about="urn:uuid:@{ [create_UUID_as_string(UUID_V4)] }">
							<oa:hasSelector>
								<oad:KVPairQuerySelector rdf:about="urn:uuid:@{ [create_UUID_as_string(UUID_V4)] }">
									<dwc:collectionCode>$collectionCode</dwc:collectionCode>
									<dwc:institutionCode>$institution</dwc:institutionCode>
								</oad:KVPairQuerySelector>
							</oa:hasSelector>
							<oa:hasSource rdf:resource="http://filteredpush.org/ontologies/oa/oad.rdf#AnySuchDataset" />
						</oa:SpecificResource>
					 </oa:hasTarget>
					 <oa:hasBody>
						<dwcFP:Occurence rdf:about="urn:uuid:@{ [create_UUID_as_string(UUID_V4)] }">
							<dc:type>PhysicalObject</dc:type>
							<dwcFP:basisOfRecord rdf:resource="http://rs.tdwg.org/dwc/dwctype/PreservedSpecimen"/>
							<dwc:catalogNumber>$barcode</dwc:catalogNumber>
							<dwcFP:hasCollectionByID rdf:resource="$BCIcollectionID"/>
							<dwc:institutionCode>$institution</dwc:institutionCode>
							<dwc:collectionCode>$collectionCode</dwc:collectionCode>
							<dwcFP:hasIdentification>
								<dwcFP:Identification rdf:about="urn:uuid:@{ [create_UUID_as_string(UUID_V4)] }">
									<dwcFP:isFiledUnderNameInCollection>$collectionCode</dwcFP:isFiledUnderNameInCollection>
									<dwc:family>$TRNSfamily</dwc:family>
									<dwc:scientificName>$scientificName</dwc:scientificName>
									<dwc:genus>$genus</dwc:genus>
									<dwc:specificEpithet>$species</dwc:specificEpithet>
									<dwc:infraspecificRank>$rank</dwc:infraspecificRank>
									<dwc:infraspecificEpithet>$infraSpecific</dwc:infraspecificEpithet>
									<dwc:scientificNameAuthorship>$author</dwc:scientificNameAuthorship>
									<dwc:identificationQualifier>$qualifier</dwc:identificationQualifier>
									<dwcFP:usesTaxon>
										<dwcFP:Taxon rdf:about="urn:uuid:$taxonID">
											<dwcFP:hasTaxonID>$taxonID</dwcFP:hasTaxonID>
										</dwcFP:Taxon>						
									</dwcFP:usesTaxon>
								</dwcFP:Identification>
							</dwcFP:hasIdentification>
							<dwc:recordedBy>$collectorName</dwc:recordedBy>
							<dwcFP:hasCollector rdf:resource="$collectorGUID"/>
							<dwc:recordNumber>$collectorNumber</dwc:recordNumber>
							<dwcFP:hasCollectingEvent>
								<dwcFP:Event rdf:about="urn:uuid:@{ [create_UUID_as_string(UUID_V4)] }">
									<dwc:eventDate>$eventDate</dwc:eventDate>
									<dwc:verbatimEventDate>$verbatimDate</dwc:verbatimEventDate>
									<dwc:eventRemarks>$eventRemarks</dwc:eventRemarks>
								</dwcFP:Event>
							</dwcFP:hasCollectingEvent>
							<dwc:country>$country</dwc:country>
							<dwc:stateProvince>$state</dwc:stateProvince>
							<dwc:county>$county</dwc:county>
							<dwc:municipality>$town</dwc:municipality>
							<dc:created>$createDateGMT</dc:created>
							<dwc:modified>$modificationDateGMT</dwc:modified>
							<obo:OBI_0000967>14.4</obo:OBI_0000967>
							<dwcFP:hasAssociatedMedia rdf:resource="$mediaURI"/>
							<ac:hasAccessPoint>
								<rdf:Description rdf:about="urn:uuid:@{ [create_UUID_as_string(UUID_V4)] }">
									<ac:variant>Offline</ac:variant>
									<ac:accessURI>file:/$finalPath</ac:accessURI>
									<dc:format>$suffix</dc:format>
									<ac:hashFunction>MD5</ac:hashFunction>						
									<ac:hashValue>$fileMD5</ac:hashValue>
								</rdf:Description>
							</ac:hasAccessPoint>	
						</dwcFP:Occurence>
					</oa:hasBody>
					<oad:hasEvidence rdf:resource="$mediaURI" />				
					<oad:hasExpectation>
						<oad:Expectation_Insert rdf:about="urn:uuid:@{ [create_UUID_as_string(UUID_V4)] }" />
					</oad:hasExpectation>
					<oa:motivatedBy>
						<oad:transcribing />
					</oa:motivatedBy>  
					<vivo:hasFundingVehicle rdf:resource="http://www.nsf.gov/awardsearch/showAward?AWD_ID=1209149" />
					<oa:annotatedBy>
						<foaf:Person rdf:about="urn:uuid:$userUUID">
							<foaf:mbox_sha1sum>$useremailMD5</foaf:mbox_sha1sum>
							<foaf:name>$username</foaf:name>
							<foaf:workplaceHomepage>$userURL</foaf:workplaceHomepage>
						</foaf:Person>
					</oa:annotatedBy>
					<oa:annotatedAt>$createDateGMT</oa:annotatedAt>
					<oa:serializedBy>
						<foaf:Agent rdf:about="https://sourceforge.net/p/nevp/svn/$version/tree/trunk/rdfXmlGen.pl">
							<foaf:name>rdfXMLGen.pl version $version</foaf:name>
						</foaf:Agent>
					</oa:serializedBy>
					<oa:serializedAt>$timeGMT</oa:serializedAt>
				</oa:Annotation>
DATASPECIMEN

			print OUTFILELOG "data written to file, ";
			
			#-----set specimen.ExportDate 
			updateExportDate($specimenID);
			
			#-----delete original file in workspace directory
			if ( $fileMD5 eq $outputFileMD5 ) {
					#UNCOMMENT LINE BELOW AFTER TESTING
					#unlink "$imagePath$imageName" or warn "Could not delete $imagePath$imageName";
					print OUTFILELOG "original image file deleted.\n";
				} else {
					print OUTFILELOG "original image file not deleted - checksums differ.\n";
				}
			} else {
				print OUTFILELOG "$imagePath$imageName not found.\n";
			}
		}
	}
}
 
#-----closing tags
print {$allFiles} "</rdf:RDF>\n";

#-----close outfiles
close (OUTFILESPEC);
close (OUTFILESPECSYM);
close (OUTFILELOG);

#-----SUBFUNCTIONS

#-----determine if taxon is in BONAP taxa table
sub getNewTaxonResult
{
	my $scientificName = $_[0];
	#-----the MYSQL SELECT query
	my $sql = qq{
	SELECT *
	FROM taxa_bonap a, specimen b
	WHERE
	CONCAT_WS(" ",IF(a.Genus!="",a.Genus,NULL),IF(a.SpecificEpithet!="",a.SpecificEpithet,NULL),IF(a.SubspecificEpithet!="" && a.InfraspecificRank="",CONCAT("subspecies ",a.SubspecificEpithet),NULL),IF(a.InfraspecificRank!="",CONCAT(a.InfraspecificRank," ",a.InfraspecificEpithet), NULL),IF(a.Authorship!="",a.Authorship,NULL))
	=
	?
	};	
	my @row = $dbh->selectrow_array($sql,undef,$scientificName);
 	if (!@row) {
 		my ($newTaxaResult) = 1;
 		return $newTaxaResult;
	} else {
 		my ($newTaxaResult) = 0;
 		return $newTaxaResult;
 	}
}

#-----get family from iPlant TRNS
sub getTNRSFamily
{
	my $genus = $_[0];
	my $species = $_[1];
	my $ua = LWP::UserAgent->new;
	$ua->timeout(5);
	my $req = GET 'http://tnrs.iplantc.org/tnrsm-svc/matchNames?retrieve=best&names='.$genus.'%20'.$species;
	my $res = $ua->request($req);
	if ($res->is_success) {
		my $json = $res->content;
		my $decoded = decode_json($json);
		if ($decoded) {
 			my @items = @{ $decoded->{items}};
			my $TNRSFamily = $items[0]->{"family"};
			return $TNRSFamily;
		} else {
 			my $TNRSFamily = "";
 			return $TNRSFamily;
 		}
 	}
}

#-----get iPlant digitizing institution folder name
sub getFolderName
{
	my $collectionCode = $_[0];
	
	if ($collectionCode =~ /^(A|AMES|ECON|FH|GH|NEBC)$/) {
		my $folder = "HUH";
		return $folder;
	} elsif ($collectionCode =~ /^(YU|CBS|BART|BERK|BSN|CCSU|CCNL|KESC|WCSU)$/) {
		my $folder = "YU";
		return $folder;
	} elsif ($collectionCode =~ /^(VT)$/) {
		my $folder = "VT";
		return $folder;
	} elsif ($collectionCode =~ /^(MASS|HF|WSCH)$/) {
		my $folder = "MASS";
		return $folder;
	} elsif ($collectionCode =~ /^(BRU)$/) {
		my $folder = "BRU";
		return $folder;
	} elsif ($collectionCode =~ /^(NHA)$/) {
		my $folder = "NHA";
		return $folder;
	} else {
		my $folder = "Other";
		return $folder;
	}
}

#-----get md5 hash of image file	
sub md5sumFile
{
  my $file = shift;
  my $hash = "";
  eval{
    open(FILE, $file) or die "sub md5sumFile: can't find file $file\n";
    my $var = Digest::MD5->new;
    $var->addfile(*FILE);
    $hash = $var->hexdigest;
    close(FILE);
  };
  if($@){
    print $@;
    return "";
  }
  unless ($hash) { die "sub md5sumFile: subroutine failed.\n"; }
  return $hash;
}

#-----convert mysql datetime fields to GMT timezone; set input timezone in config file
sub convertTZ
{
	my $inputTime = $_[0];
	my $newTime = UnixDate( Date_ConvTZ( $inputTime, "$config{timezone}", 'Europe/London' ), "%Y-%m-%d %H:%M:%S");
	my $time = Time::Piece->strptime("$newTime", "%Y-%m-%d %H:%M:%S");
	return $time->strftime("%Y-%m-%dT%H:%M:%SZ");
}

#-----create create ISO 8601 'compliant' dwc:eventDate
sub createEventDate
{
	my $beginDate = $_[0];
	my $endDate = $_[1];
	
	if (defined $beginDate) {
		$beginDate =~ s{([0-9]{4})-([0-9]{2})-([0-9]{2}) (00:00:00)}{$1-$2-$3};
	}
	
	if (defined $endDate) {
		$endDate =~ s{([0-9]{4})-([0-9]{2})-([0-9]{2}) (00:00:00)}{$1-$2-$3};  
	}
	
	if (defined $beginDate && defined $endDate) {
		my $eventDate = "$beginDate/$endDate";
		return $eventDate;
	} elsif (defined $beginDate && not defined $endDate) {
		my $eventDate = "$beginDate";
		return $eventDate;
	} elsif (not defined $beginDate && not defined $endDate) {
		my $eventDate = "";
		return $eventDate;
	}
}

#-----populate eventRemarks if verbatimEventDate is populated and beginDate and endDate are not
sub eventRemarks
{
	my $beginDate = $_[0];
	my $endDate = $_[1];
	my $verbatimDate = $_[2];
	
	if ($verbatimDate ne "") {
		if (not defined $beginDate) {
			my $eventRemarks = "verbatim date is ambiguous";
			return $eventRemarks;
		} else {
			my $eventRemarks = "";
			return $eventRemarks;
		}
	} else {
		my $eventRemarks = "";
		return $eventRemarks;	
	}
}

#-----get taxonID
sub gettaxonID
{
	my $scientificName = $_[0];
	#-----the MYSQL SELECT query
	my $sql = qq{
	SELECT a.UUID
	FROM taxa_bonap a, specimen b
	WHERE
	CONCAT_WS(" ",IF(a.Genus!="",a.Genus,NULL),IF(a.SpecificEpithet!="",a.SpecificEpithet,NULL),IF(a.SubspecificEpithet!="" && a.InfraspecificRank="",CONCAT("subspecies ",a.SubspecificEpithet),NULL),IF(a.InfraspecificRank!="",CONCAT(a.InfraspecificRank," ",a.InfraspecificEpithet), NULL),IF(a.Authorship!="",a.Authorship,NULL))
	=
	?
	AND a.UUID!="" LIMIT 1
	};
	my @row = $dbh->selectrow_array($sql,undef,$scientificName);
 	if (!@row) {
 		my ($UUID) = "";
 		return $UUID;
	} else {
 		my ($UUID) = @row;
 		return $UUID;
 	}
}

#-----get collector's full name and GUID
sub getCollector
{
	no warnings 'uninitialized';
	my $specimenID = $_[0];
	#-----the MYSQL SELECT query
	my $sql = qq{
	SELECT c.CollectorFullName,c.CollectorInfo
	FROM specimen a, spec_collector_map b, collector c
	WHERE a.SpecimenId=b.SpecimenId AND b.CollectorId=c.CollectorId AND b.SpecimenId=?
	};
	my @row = $dbh->selectrow_array($sql,undef,$specimenID);
	if (!@row) {
		my ($collectorFullName) = "";
		my ($collectorGUID) = "";
		return ($collectorFullName, $collectorGUID);
	} else {
		#-----check if GUID is from HUH botanists table
		if (index($row[1], "http://") != -1) {
			my ($collectorFullName) = $row[0];
			my ($collectorGUID) = $row[1];
			return ($collectorFullName, $collectorGUID);
		#-----if not, then will have naked UUID generated by apparatus
		} else {
			my ($collectorFullName) = $row[0];
			my ($collectorGUID) = "uri:uuid:".$row[1];
			return ($collectorFullName, $collectorGUID);		
		}
 	}
}

#-----set specimen.ExportDate - the date the record was serialized
sub updateExportDate
{
	my $specimenID = $_[0];
	#-----the MYSQL UPDATE query
	my $sql = qq{
	UPDATE specimen
	SET ExportDate=NOW() WHERE SpecimenId=?
	};
	my @row = $dbh->do($sql,undef,$specimenID);
	unless (@row) { die "sub updateExportDate: subroutine failed.\n"; }
}

#-----escape ampersands in outfiles - needed to ensure XML will validate.
my $outiPlantfile = "$config{exportiPlant}$date/rdfSpecimen_$date.xml";
my $outSymbiotafile = "$config{exportSymbiota}/rdfSpecimen_$date.xml";

escapeAmpersands($outiPlantfile);
escapeAmpersands($outSymbiotafile);

sub escapeAmpersands
{
	my $file = $_[0];
	open FH,"<$file" or die "sub escapeAmpersands: can't open $file for reading";
	my @arr = <FH>;
	close FH;
	foreach(@arr){
        s/&/&amp;/g;
	}
	open FH, ">$file"  or die "sub escapeAmpersands: can't open $file for writing";
	print FH @arr;
	close FH;
}

#-----close DB
$dbh->disconnect ();

#-----END