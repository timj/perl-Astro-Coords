#!perl
use strict;
use Test::More tests => 12;

require_ok('Astro::Coords::Angle');
require_ok('Astro::Coords::Angle::Hour');

my $ang = new Astro::Coords::Angle( '-00:30:2.0456', units => 'sex',
				    range => '2PI'
 );
isa_ok($ang,"Astro::Coords::Angle");

is("$ang", "359d29m57.95s", "default stringification 0 to 2PI");

$ang->str_delim(":");
is("$ang", "359:29:57.95", "colon separated stringification 0 to 2PI");

$ang->range( 'PI' );
is("$ang","-00:30:02.05","Revert to -PI to PI");

$ang = new Astro::Coords::Angle( 45, units => 'deg', range => '2PI' );

is( $ang->degrees, 45, "render back in degrees");

$ang->str_delim("dms");
$ang->str_ndp( 5 );
is( "$ang", "45d00m00.00000s", "dms stringification");

is( $ang->arcsec, (45 * 60 * 60 ), 'arcsec');


# use string form to recreate to test parser
my $ang2 = new Astro::Coords::Angle( $ang->string, units=>'sex',range=>'PI');
is($ang2->degrees, $ang->degrees, "compare deg to string to deg");


my $ra = new Astro::Coords::Angle::Hour( '12h13m45.6s', units => 'sex',
				    range => 'PI'
 );

is("$ra", '-11h46m14.4s', "hour angle -12 to +12");
isa_ok( $ra, "Astro::Coords::Angle::Hour");
