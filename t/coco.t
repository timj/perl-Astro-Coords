#!perl

# Test comparison with coco output

use strict;
use Test::More tests => 17;

require_ok('Astro::Coords');
require_ok('Astro::Telescope');
use Time::Piece ':override';

# Force decimal places
Astro::Coords::Angle::Hour->NDP(2);

my $tel = new Astro::Telescope("JCMT");

# Simultaneously test negative zero dec and B1950 to J2000 conversion
my $c = new Astro::Coords( ra => "15h22m33.3",
	                   dec => "-0d13m4.5",
			   type => "B1950");

ok($c, "create object");
print "#J2000: $c\n";
# Make sure we get B1950 back
my ($r1950, $d1950) = $c->radec1950();
is( $r1950->string, "15h22m33.30s","compare B1950 RA");
is( $d1950->string, "-00d13m04.50s","compare B1950 Dec");

# FK5 J2000
is( $c->ra(format=>'s'), "15h25m07.35s", "Check RA 2000");
is( $c->dec(format=>'s'), "-00d23m35.76s", "Check Dec 2000");

# Use midday on Fri Sep 14 2001
$c->telescope( $tel );
my $midday = gmtime(1000468800);
$c->datetime( $midday );
print "# Julian epoch: ". Astro::SLA::slaEpj( $midday->mjd ) ."\n";
print $c->status();

# FK4 1900 epoch 2001 Sep 14
my ($ra, $dec) = $c->radec( 'B1900' );
is( $ra->string, "15h19m59.54s", "Check RA B1900");
is( $dec->string, "-00d02m24.69s", "Check Dec B1900");

# FK4 1950 epoch 2001 Sep 14
($r1950, $d1950) = $c->radec('B1950');
is( $r1950->string, "15h22m33.29s","compare B1950 RA current epoch");
is( $d1950->string, "-00d13m04.64s","compare B1950 Dec current epoch");


# FK5 apparent
is( $c->ra_app(format=>'s'), "15h25m10.93s", "Check geocentric apparent RA");
is( $c->dec_app(format=>'s'), "-00d23m45.19s", "Check geocentric apparent Dec");

# Galactic
my ($glong, $glat) = $c->glonglat();
is( sprintf('%.8f',$glong->degrees), 2.61698924, "Check Galactic longitude");
is( sprintf('%.8f',$glat->degrees), 43.95773251, "Check Galactic latitude");

# Ecliptic coordinates
my ($elong, $elat) = $c->ecllonglat();
is( sprintf('%.6f',$elong->degrees), '228.984550',"Check ecliptic longitude");
is( sprintf('%.8f',$elat->degrees), 17.70075558, "Check ecliptic latitude");

exit;
