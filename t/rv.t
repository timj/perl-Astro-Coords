#!perl

# Test radial velocity calculations
# compare with rv application

use strict;
use Test::More tests => 30;
use DateTime;

require_ok('Astro::Coords');
require_ok('Astro::Telescope');


# telescope
my $tel = new Astro::Telescope( 'JCMT' );

my $dt = DateTime->new( year => 2001, month => 9, day => 14, time_zone => 'UTC');
is( $dt->jd, 2452166.5, "Check JD");

# create coordinate object
my $c = new Astro::Coords( ra => '15 22 33.30',
			   dec => '-00 14 04.5',
			   type => 'B1950');

$c->telescope( $tel );
$c->datetime( $dt );

# Check the header information
# J2000
my ($ra,$dec) = $c->radec;
$ra->str_delim( " " );
$ra->str_ndp( 2 );
$dec->str_delim( " " );
$dec->str_ndp( 2 );
# Confirmed with COCO
is( $ra->string, "15 25 07.37", "check RA(2000)");
is( $dec->string, "-00 24 35.76", "check Dec(2000)");

# Apparent
($ra,$dec) = $c->apparent;
$ra->str_delim( " " );
$ra->str_ndp( 2 );
$dec->str_delim( " " );
$dec->str_ndp( 2 );
# Confirmed with COCO
is( $ra->string, "15 25 10.95", "check RA(app)");
is( $dec->string, "-00 24 45.16", "check Dec(app)");

# Galactic
my ($long, $lat) = $c->glonglat;
is( sprintf('%.4f',$long->degrees), 2.5993, "check Galactic longitude");
is( sprintf('%.4f',$lat->degrees), '43.9470', "check Galactic latitude");

# Ecliptic
($long, $lat) = $c->ecllonglat;
is( sprintf('%.4f',$long->degrees), 228.9892, "check Ecliptic longitude");
is( sprintf('%.4f',$lat->degrees), 17.6847, "check Ecliptic latitude");

# For epoch [could test the entire run every 30 minutes]

my $el = $c->el( format => 'deg' );
is( sprintf( '%.1f', ( 90 - $el)), 38.8,'Check zenith distance');

is( sprintf('%.2f',$c->verot), -0.24,
    'Obs velocity wrt to the Earth geocentre in dir of target');
is( sprintf('%.2f',$c->vhelio), 23.38, 'Obs velocity wrt the Sun in direction of target');
is( sprintf('%.2f',$c->vlsrk),  10.13, 'Obs velocity wrt LSRK in direction of target');
is( sprintf('%.2f',$c->vlsrd), 11.66, 'Obs velocity wrt LSRD in direction of target');
is( sprintf('%.2f',$c->vgalc), 4.48, 'Obs velocity wrt Galaxy in direction of target');
is( sprintf('%.2f',$c->vlg), 13.59, 'Obs velocity wrt Local Group in direction of target');

is( $c->vdiff( 'LSRK', 'LSRD'), ($c->vlsrk - $c->vlsrd), "diff of two velocity frames");

# Now compare this with some calculations found on a random web page
# RA 3h27.6m, Dec=-63°18'47"
# Verified with RV
$c = new Astro::Coords( 
		       ra => '3h27m36',
		       dec => '-63 18 47',
		       epoch => 1975.0,
		       type => 'B1975',
		       name => 'k Ret',
		      );

$dt = new DateTime( year => 1975, month => 1, day => 3,
		    hour => 19,	time_zone => 'UTC' );
$c->datetime( $dt );
$tel = new Astro::Telescope( 'Name' => 'test',
			     'Long' => Astro::Coords::Angle->new( '20 48 42' )->radians,
			     'Lat'  => Astro::Coords::Angle->new( '-32 22 42' )->radians,
			     Alt => 0);
isa_ok( $tel, 'Astro::Telescope' );
$c->telescope( $tel );

is( sprintf('%.2f', $c->vhelio), 7.97, 'Heliocentric velocity');


# Radial velocity and doppler correction
$c = new Astro::Coords( ra => '16 43 52',
			dec => '-00 24 3.5',
			type => 'J2000',
			redshift => 2 );

is($c->redshift, 2, 'Check redshift');
is($c->vdefn, 'REDSHIFT', 'check velocity definition');
is($c->vframe, 'HEL', 'check velocity frame');
is($c->rv, 599584.916, 'check optical velocity');

is( sprintf('%.4f',$c->doppler), '0.3333', 'check doppler correction');

$c = new Astro::Coords( ra => '16 43 52',
			dec => '-00 24 3.5',
			type => 'J2000',
			rv => 20, vdefn => 'RADIO',
			vframe => 'LSR'
		      );

is($c->vdefn, 'RADIO', 'check velocity definition');
is($c->vframe, 'LSRK', 'check velocity frame');
is($c->rv, 20, 'check velocity');
is($c->obsvel, (20 + $c->vlsrk), "velocity between observer and target");
print "# Doppler correction : ". $c->doppler. "\n";
